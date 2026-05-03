defmodule SymphonyElixir.Copilot.Autopilot do
  @moduledoc """
  Spawns the GitHub Copilot CLI in autonomous (`--autopilot --yolo`) mode.

  The runner owns:

  - argv construction (no shell strings, no shell interpolation)
  - process spawn via `Port`
  - stdout/stderr streaming into the orchestrator's status pipeline
  - JSONL parsing when `output_format: json`
  - turn / read / stall timeouts
  - termination on completion, timeout, manual stop, or error
  - secret redaction on every log/status path
  """

  require Logger

  alias SymphonyElixir.{Config, Redaction}

  @port_line_bytes 1_048_576

  @typedoc """
  Stop reasons surfaced to the orchestrator.
  """
  @type stop_reason ::
          :completed
          | :timeout
          | :stalled
          | :killed
          | :error
          | :issue_closed
          | :issue_blocked

  @type result :: %{
          stop_reason: stop_reason(),
          exit_status: integer() | nil,
          mode: String.t(),
          permission_mode: String.t(),
          output_format: String.t(),
          messages: [map()],
          raw_lines: [String.t()],
          error: term() | nil
        }

  @doc """
  Build the argv list passed to `copilot` for autopilot mode.
  Public so tests can assert on it without spawning a process.
  """
  @spec build_argv(map(), String.t()) :: [String.t()]
  def build_argv(copilot, prompt) when is_map(copilot) and is_binary(prompt) do
    base =
      [
        "--autopilot",
        "--max-autopilot-continues=#{copilot.max_autopilot_continues}"
      ]

    base =
      case copilot.permission_mode do
        "yolo" -> base ++ ["--yolo"]
        _ -> base
      end

    base =
      if copilot.no_ask_user, do: base ++ ["--no-ask-user"], else: base

    base =
      case copilot.output_format do
        "json" -> base ++ ["--output-format=json"]
        "text" -> base ++ ["--output-format=text"]
        _ -> base
      end

    base ++
      Enum.flat_map(copilot.deny_tools, fn tool ->
        ["--deny-tool=#{tool}"]
      end) ++
      ["-p", prompt]
  end

  @doc """
  Run a single Copilot autopilot turn.

  `prompt` is rendered upstream by `PromptBuilder` and passed via argv.
  `workspace` becomes the process `cwd`.
  """
  @spec run(Path.t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(workspace, prompt, opts \\ []) when is_binary(workspace) and is_binary(prompt) do
    copilot = Config.settings!().copilot
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)

    case validate_workspace(workspace) do
      :ok ->
        argv = build_argv(copilot, prompt)
        Logger.info("Starting copilot autopilot in #{workspace}")
        do_run(workspace, argv, copilot, on_message)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_run(workspace, argv, copilot, on_message) do
    executable = System.find_executable(copilot.command)

    case executable do
      nil ->
        {:error, {:copilot_not_found, copilot.command}}

      bin ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(bin)},
            [
              :binary,
              :exit_status,
              :hide,
              :stderr_to_stdout,
              {:cd, String.to_charlist(workspace)},
              {:args, Enum.map(argv, &String.to_charlist/1)},
              {:line, @port_line_bytes}
            ]
          )

        loop(port, copilot, on_message, %{
          messages: [],
          raw_lines: [],
          buffer: "",
          last_read_at: monotonic_now(),
          deadline_at: monotonic_now() + copilot.turn_timeout_ms
        })
    end
  end

  defp loop(port, copilot, on_message, acc) do
    timeout = compute_receive_timeout(copilot, acc)

    receive do
      {^port, {:data, {:eol, line}}} ->
        # Prepend any buffered :noeol chunks so multi-chunk lines (> 1 MB) are
        # assembled correctly before redaction and JSONL parsing. Reset buffer.
        full_line = Redaction.redact(acc.buffer <> line)
        on_message.({:line, full_line})
        acc = handle_line(full_line, acc, copilot, on_message)
        loop(port, copilot, on_message, %{acc | buffer: "", last_read_at: monotonic_now()})

      {^port, {:data, {:noeol, partial}}} ->
        # Accumulate partial data; do NOT redact yet — tokens may span chunks.
        loop(port, copilot, on_message, %{acc | buffer: acc.buffer <> partial, last_read_at: monotonic_now()})

      {^port, {:exit_status, status}} ->
        finalize_result(:completed, status, copilot, acc)
    after
      timeout ->
        cond do
          monotonic_now() >= acc.deadline_at ->
            kill_port(port)
            finalize_result(:timeout, nil, copilot, acc)

          stall_triggered?(copilot.stall_timeout_ms, acc.last_read_at) ->
            kill_port(port)
            finalize_result(:stalled, nil, copilot, acc)

          true ->
            loop(port, copilot, on_message, acc)
        end
    end
  end

  # `stall_timeout_ms == 0` disables stall detection entirely, matching the
  # legacy codex-side semantics. Any positive value enforces the bound.
  @doc false
  @spec stall_triggered?(non_neg_integer(), integer()) :: boolean()
  def stall_triggered?(0, _last_read_at), do: false

  def stall_triggered?(stall_timeout_ms, last_read_at) when is_integer(stall_timeout_ms) do
    stall_timeout_ms > 0 and monotonic_now() - last_read_at >= stall_timeout_ms
  end

  defp compute_receive_timeout(copilot, acc) do
    deadline_remaining = max(acc.deadline_at - monotonic_now(), 0)

    candidates =
      if copilot.stall_timeout_ms > 0 do
        stall_remaining = max(copilot.stall_timeout_ms - (monotonic_now() - acc.last_read_at), 0)
        [copilot.read_timeout_ms, deadline_remaining, stall_remaining]
      else
        [copilot.read_timeout_ms, deadline_remaining]
      end

    Enum.min(candidates)
  end

  defp handle_line(line, acc, copilot, on_message) do
    raw_lines = [line | acc.raw_lines]

    case copilot.output_format do
      "json" ->
        case Jason.decode(line) do
          {:ok, decoded} ->
            on_message.({:json, decoded})
            %{acc | messages: [decoded | acc.messages], raw_lines: raw_lines}

          {:error, _} ->
            %{acc | raw_lines: raw_lines}
        end

      _ ->
        %{acc | raw_lines: raw_lines}
    end
  end

  defp finalize_result(:completed, 0, copilot, acc) do
    {:ok,
     %{
       stop_reason: :completed,
       exit_status: 0,
       mode: copilot.mode,
       permission_mode: copilot.permission_mode,
       output_format: copilot.output_format,
       messages: Enum.reverse(acc.messages),
       raw_lines: Enum.reverse(acc.raw_lines),
       error: nil
     }}
  end

  defp finalize_result(:completed, status, copilot, acc) do
    {:ok,
     %{
       stop_reason: :error,
       exit_status: status,
       mode: copilot.mode,
       permission_mode: copilot.permission_mode,
       output_format: copilot.output_format,
       messages: Enum.reverse(acc.messages),
       raw_lines: Enum.reverse(acc.raw_lines),
       error: {:copilot_exit, status}
     }}
  end

  defp finalize_result(reason, status, copilot, acc) when reason in [:timeout, :stalled, :killed] do
    {:ok,
     %{
       stop_reason: reason,
       exit_status: status,
       mode: copilot.mode,
       permission_mode: copilot.permission_mode,
       output_format: copilot.output_format,
       messages: Enum.reverse(acc.messages),
       raw_lines: Enum.reverse(acc.raw_lines),
       error: reason
     }}
  end

  defp kill_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    drain(port, 1_000)
  end

  defp drain(port, timeout) do
    receive do
      {^port, _msg} -> drain(port, timeout)
    after
      timeout -> :ok
    end
  end

  defp validate_workspace(workspace) do
    cond do
      not File.dir?(workspace) -> {:error, {:workspace_not_dir, workspace}}
      true -> :ok
    end
  end

  defp monotonic_now, do: System.monotonic_time(:millisecond)
end
