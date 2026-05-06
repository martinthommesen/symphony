defmodule SymphonyElixir.AgentRunner.Acpx do
  @moduledoc """
  The only production agent execution module.

  Spawns acpx as a subprocess, parses its JSON output stream,
  and surfaces events to the orchestrator.
  """

  require Logger

  alias SymphonyElixir.{Acpx.CommandBuilder, Config, Redaction, StructuredLogger}

  @port_line_bytes 1_048_576
  @session_ready_timeout_ms 30_000
  @status_timeout_ms 30_000

  @type session :: %{
          session_name: String.t(),
          agent_id: String.t(),
          workspace: String.t(),
          worker_host: String.t() | nil
        }

  @type result :: %{
          stop_reason: atom(),
          exit_status: integer() | nil,
          agent_id: String.t(),
          messages: [map()],
          raw_lines: [String.t()],
          error: term() | nil
        }

  @spec run(String.t(), String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(agent_id, workspace, prompt, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)

    with {:ok, session} <- ensure_session(agent_id, workspace, opts) do
      run_prompt(session, prompt, on_message)
    end
  end

  @spec ensure_session(String.t(), String.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def ensure_session(agent_id, workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    session_name = Keyword.get(opts, :session_name, default_session_name())
    executable = CommandBuilder.executable()

    argv = CommandBuilder.ensure_session(agent_id, workspace, session_name)

    case spawn_acpx(executable, argv, workspace, worker_host) do
      {:ok, port} ->
        case await_session_ready(port) do
          :ok ->
            stop_port(port)

            {:ok,
             %{
               session_name: session_name,
               agent_id: agent_id,
               workspace: workspace,
               worker_host: worker_host
             }}

          {:error, reason} ->
            kill_port(port)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec run_prompt(session(), String.t(), (map() -> any())) :: {:ok, result()} | {:error, term()}
  def run_prompt(session, prompt, on_message) do
    agent_id = session.agent_id
    workspace = session.workspace
    session_name = session.session_name
    worker_host = session.worker_host

    prompt_path =
      Path.join(System.tmp_dir!(), "symphony_prompt_#{System.unique_integer([:positive])}.md")

    File.write!(prompt_path, prompt)

    try do
      executable = CommandBuilder.executable()
      argv = CommandBuilder.prompt(agent_id, workspace, session_name, prompt_path)
      started_at = System.monotonic_time(:millisecond)

      log_agent_run_start(session, executable, argv)

      case spawn_acpx(executable, argv, workspace, worker_host) do
        {:ok, port} ->
          wrapped_on_message = build_wrapped_on_message(port, on_message, session)
          result = stream_output(port, agent_id, wrapped_on_message)
          stop_port(port)
          log_agent_run_finish(session, executable, argv, started_at, result)
          result

        {:error, reason} ->
          log_agent_run_error(session, executable, argv, started_at, reason)
          {:error, reason}
      end
    after
      File.rm(prompt_path)
    end
  end

  @spec cancel_session(session()) :: :ok | {:error, term()}
  def cancel_session(session) do
    executable = CommandBuilder.executable()
    argv = CommandBuilder.cancel(session.agent_id, session.workspace, session.session_name)

    case spawn_acpx(executable, argv, session.workspace, session.worker_host) do
      {:ok, port} ->
        drain(port, 5_000)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec session_status(session()) :: {:ok, map()} | {:error, term()}
  def session_status(session) do
    executable = CommandBuilder.executable()
    argv = CommandBuilder.status(session.agent_id, session.workspace, session.session_name)

    case spawn_acpx(executable, argv, session.workspace, session.worker_host) do
      {:ok, port} ->
        result = collect_json_output(port)
        stop_port(port)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- private --

  defp spawn_acpx(executable, argv, workspace, nil) do
    bin = System.find_executable(executable)

    if is_nil(bin) do
      Logger.error("acpx executable not found: #{executable}")
      {:error, {:acpx_not_found, executable}}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(bin)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:cd, String.to_charlist(workspace)},
            {:args, Enum.map(argv, &String.to_charlist/1)},
            {:line, @port_line_bytes}
          ]
        )

      {:ok, port}
    end
  end

  defp spawn_acpx(executable, argv, _workspace, worker_host) when is_binary(worker_host) do
    alias SymphonyElixir.SSH
    command = Enum.join([executable | Enum.map(argv, &shell_escape/1)], " ")
    SSH.start_port(worker_host, command, line: @port_line_bytes)
  end

  defp stream_output(port, agent_id, on_message) do
    timeout_ms = Config.agent_timeout_ms(agent_id)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    loop(port, on_message, %{
      messages: [],
      raw_lines: [],
      buffer: "",
      last_read_at: System.monotonic_time(:millisecond),
      deadline_at: deadline
    })
  end

  defp loop(port, on_message, acc) do
    timeout = compute_timeout(acc)

    receive do
      {^port, {:data, {:eol, line}}} ->
        acc = process_line(line, acc, on_message)
        loop(port, on_message, %{acc | last_read_at: System.monotonic_time(:millisecond)})

      {^port, {:data, {:noeol, partial}}} ->
        loop(port, on_message, %{
          acc
          | buffer: acc.buffer <> partial,
            last_read_at: System.monotonic_time(:millisecond)
        })

      {^port, {:exit_status, status}} ->
        acc = flush_buffer(acc, on_message)
        finalize_result(:completed, status, acc)
    after
      timeout ->
        now = System.monotonic_time(:millisecond)

        cond do
          now >= acc.deadline_at ->
            kill_port(port)
            acc = flush_buffer(acc, on_message)
            finalize_result(:timeout, nil, acc)

          stall_triggered?(acc, now) ->
            kill_port(port)
            acc = flush_buffer(acc, on_message)
            finalize_result(:stalled, nil, acc)

          true ->
            loop(port, on_message, acc)
        end
    end
  end

  defp process_line(line, acc, on_message) do
    full_line = acc.buffer <> line
    redacted = Redaction.redact(full_line)
    on_message.({:line, redacted})

    acc =
      case Jason.decode(redacted) do
        {:ok, decoded} ->
          on_message.({:json, decoded})
          %{acc | messages: [decoded | acc.messages], raw_lines: [redacted | acc.raw_lines]}

        {:error, reason} ->
          if protocol_message_candidate?(redacted) do
            Logger.warning("Malformed JSON from acpx: #{inspect(reason)} line=#{String.slice(redacted, 0, 200)}")
          end

          %{acc | raw_lines: [redacted | acc.raw_lines]}
      end

    %{acc | buffer: ""}
  end

  defp flush_buffer(%{buffer: ""} = acc, _on_message), do: acc

  defp flush_buffer(acc, on_message) do
    process_line("", acc, on_message)
  end

  defp stall_triggered?(acc, now) do
    stall_ms = Config.agent_stall_timeout_ms()
    stall_ms > 0 and now - acc.last_read_at >= stall_ms
  end

  defp compute_timeout(acc) do
    deadline_remaining = max(acc.deadline_at - System.monotonic_time(:millisecond), 0)
    stall_ms = Config.agent_stall_timeout_ms()

    candidates =
      if stall_ms > 0 do
        stall_remaining = max(stall_ms - (System.monotonic_time(:millisecond) - acc.last_read_at), 0)
        [5_000, deadline_remaining, stall_remaining]
      else
        [5_000, deadline_remaining]
      end

    Enum.max([Enum.min(candidates), 100])
  end

  defp finalize_result(:completed, 0, acc) do
    {:ok,
     %{
       stop_reason: :completed,
       exit_status: 0,
       agent_id: "acpx",
       messages: Enum.reverse(acc.messages),
       raw_lines: Enum.reverse(acc.raw_lines),
       error: nil
     }}
  end

  defp finalize_result(:completed, status, acc) do
    {:ok,
     %{
       stop_reason: :error,
       exit_status: status,
       agent_id: "acpx",
       messages: Enum.reverse(acc.messages),
       raw_lines: Enum.reverse(acc.raw_lines),
       error: {:acpx_exit, status}
     }}
  end

  defp finalize_result(reason, _status, acc) when reason in [:timeout, :stalled, :killed] do
    {:ok,
     %{
       stop_reason: reason,
       exit_status: nil,
       agent_id: "acpx",
       messages: Enum.reverse(acc.messages),
       raw_lines: Enum.reverse(acc.raw_lines),
       error: reason
     }}
  end

  defp await_session_ready(port, pending_line \\ "") do
    receive do
      {^port, {:data, {:eol, line}}} ->
        complete = pending_line <> line

        case Jason.decode(complete) do
          {:ok, %{"ready" => true}} ->
            :ok

          {:ok, %{"error" => error}} ->
            Logger.error("acpx session startup error: #{inspect(error)}")
            {:error, {:acpx_session_error, error}}

          _ ->
            await_session_ready(port, "")
        end

      {^port, {:data, {:noeol, partial}}} ->
        await_session_ready(port, pending_line <> partial)

      {^port, {:exit_status, status}} ->
        Logger.error("acpx session exited before ready: status=#{status}")
        {:error, {:acpx_session_exit, status}}
    after
      @session_ready_timeout_ms ->
        {:error, :acpx_session_timeout}
    end
  end

  defp collect_json_output(port, pending_line \\ "") do
    receive do
      {^port, {:data, {:eol, line}}} ->
        complete = pending_line <> line

        case Jason.decode(complete) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, reason} -> {:error, {:json_decode_error, reason}}
        end

      {^port, {:data, {:noeol, partial}}} ->
        collect_json_output(port, pending_line <> partial)

      {^port, {:exit_status, 0}} ->
        {:ok, %{}}

      {^port, {:exit_status, status}} ->
        {:error, {:acpx_exit, status}}
    after
      @status_timeout_ms ->
        {:error, :acpx_status_timeout}
    end
  end

  defp build_wrapped_on_message(port, on_message, session) do
    os_pid = port_os_pid(port)

    fn
      {:json, decoded} ->
        event = translate_acpx_event(decoded, session, os_pid)
        log_acpx_event(session, decoded)
        on_message.(event)

      {:line, _text} ->
        :ok
    end
  end

  defp log_agent_run_start(session, executable, argv) do
    StructuredLogger.log_named("agent-runs", agent_run_event(session, executable, argv, "agent_run_started", "started", nil, nil))
  end

  defp log_agent_run_finish(session, executable, argv, started_at, {:ok, result}) do
    duration_ms = System.monotonic_time(:millisecond) - started_at
    exit_status = Map.get(result, :exit_status)

    StructuredLogger.log_named(
      "agent-runs",
      agent_run_event(session, executable, argv, "agent_run_finished", "finished", exit_status, duration_ms)
    )
  end

  defp log_agent_run_error(session, executable, argv, started_at, reason) do
    duration_ms = System.monotonic_time(:millisecond) - started_at

    StructuredLogger.log_named(
      "agent-runs",
      agent_run_event(session, executable, argv, "agent_run_failed", "failed: #{inspect(reason)}", nil, duration_ms)
    )
  end

  defp agent_run_event(session, executable, argv, event_type, message, exit_code, duration_ms) do
    %{
      run_id: session.session_name,
      agent_id: session.agent_id,
      acpx_session_name: session.session_name,
      workspace_path: session.workspace,
      event_type: event_type,
      severity: "info",
      message: message,
      payload: %{
        agent_execution_backend: "acpx",
        selected_agent: session.agent_id,
        spawned_executable: executable,
        direct_agent_spawn: false,
        argv: Enum.map(argv, &Redaction.redact/1),
        cwd: session.workspace,
        environment_keys: System.get_env() |> Map.keys() |> Enum.sort(),
        exit_code: exit_code,
        duration_ms: duration_ms,
        stdout_stderr_capture_policy: Config.settings!().logging.raw_stdout_stderr_capture
      }
    }
  end

  defp log_acpx_event(session, decoded) do
    StructuredLogger.log_named("acpx-events", %{
      run_id: session.session_name,
      agent_id: session.agent_id,
      acpx_session_name: session.session_name,
      workspace_path: session.workspace,
      event_type: "acpx_event",
      severity: "info",
      message: "acpx event",
      payload: decoded
    })
  end

  defp port_os_pid(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, pid} -> to_string(pid)
      _ -> nil
    end
  end

  defp kill_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    drain(port, 1_000)
  end

  defp stop_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp drain(port, timeout) do
    receive do
      {^port, _msg} -> drain(port, timeout)
    after
      timeout -> :ok
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_session_name do
    "symphony-#{System.unique_integer([:positive])}"
  end

  defp protocol_message_candidate?(data) when is_binary(data) do
    data
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp protocol_message_candidate?(_), do: false

  # -- event translation --

  defp translate_acpx_event(%{"method" => "thread/started", "params" => params}, session, os_pid) do
    thread_id = get_in(params, ["thread", "id"]) || session.session_name

    base_event(:session_started, session, os_pid)
    |> Map.merge(%{
      session_id: "#{thread_id}-init",
      thread_id: thread_id
    })
  end

  defp translate_acpx_event(%{"method" => "turn/started", "params" => params}, session, os_pid) do
    turn_id = get_in(params, ["turn", "id"]) || "unknown"

    base_event(:session_started, session, os_pid)
    |> Map.merge(%{
      session_id: "#{session.session_name}-#{turn_id}",
      thread_id: session.session_name,
      turn_id: turn_id
    })
  end

  defp translate_acpx_event(%{"method" => "turn/completed"} = payload, session, os_pid) do
    base_event(:turn_completed, session, os_pid)
    |> Map.merge(%{
      payload: payload,
      usage: extract_usage(payload)
    })
  end

  defp translate_acpx_event(%{"method" => "turn/failed", "params" => params}, session, os_pid) do
    base_event(:turn_failed, session, os_pid)
    |> Map.merge(%{
      payload: params,
      reason: get_in(params, ["error", "message"]) || "turn failed"
    })
  end

  defp translate_acpx_event(%{"method" => "turn/cancelled", "params" => params}, session, os_pid) do
    base_event(:turn_cancelled, session, os_pid)
    |> Map.merge(%{payload: params})
  end

  defp translate_acpx_event(
         %{"method" => "item/commandExecution/requestApproval"} = payload,
         session,
         os_pid
       ) do
    base_event(:approval_auto_approved, session, os_pid)
    |> Map.merge(%{
      payload: payload,
      decision: "acceptForSession"
    })
  end

  defp translate_acpx_event(
         %{"method" => "item/tool/requestUserInput"} = payload,
         session,
         os_pid
       ) do
    base_event(:tool_input_auto_answered, session, os_pid)
    |> Map.merge(%{
      payload: payload,
      answer: "non-interactive"
    })
  end

  defp translate_acpx_event(
         %{"method" => "account/rateLimits/updated", "params" => params},
         session,
         os_pid
       ) do
    base_event(:notification, session, os_pid)
    |> Map.merge(%{
      payload: params,
      rate_limits: get_in(params, ["rateLimits"]),
      message: params
    })
  end

  defp translate_acpx_event(%{"method" => method} = payload, session, os_pid)
       when is_binary(method) do
    base_event(:notification, session, os_pid)
    |> Map.merge(%{
      payload: payload,
      message: payload
    })
  end

  defp translate_acpx_event(decoded, session, os_pid) do
    base_event(:notification, session, os_pid)
    |> Map.merge(%{
      payload: decoded,
      message: decoded
    })
  end

  defp base_event(event, session, os_pid) do
    %{
      event: event,
      timestamp: DateTime.utc_now(),
      session_id: session.session_name,
      agent_app_server_pid: os_pid
    }
  end

  defp extract_usage(payload) when is_map(payload) do
    Map.get(payload, "usage") ||
      get_in(payload, ["params", "usage"]) ||
      get_in(payload, ["params", "tokenUsage"])
  end
end
