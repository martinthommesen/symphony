defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single issue in its workspace through acpx.

  This module is the orchestration wrapper around the single production
  agent runner: SymphonyElixir.AgentRunner.Acpx.
  """

  require Logger

  alias SymphonyElixir.{
    Acpx.CommandBuilder,
    AgentRunner.Acpx,
    Config,
    Git,
    IssueLabelRouter,
    PromptBuilder,
    SelfCorrection,
    StructuredLogger,
    Tracker,
    Workspace
  }

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, agent_update_recipient \\ nil, opts \\ []) do
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case IssueLabelRouter.resolve(issue) do
      {:ok, agent_id, _labels} ->
        case run_on_worker_host(issue, agent_id, agent_update_recipient, opts, worker_host) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
            log_error(issue, "agent_run_failed", reason)
            raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
        end

      {:error, reason} ->
        Logger.error("Agent routing failed for #{issue_context(issue)}: #{inspect(reason)}")
        log_error(issue, "agent_routing_failed", reason)
        raise RuntimeError, "Agent routing failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, agent_id, agent_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} agent_id=#{agent_id} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(agent_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_agent_turns(agent_id, workspace, issue, agent_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp agent_message_handler(recipient, issue) do
    fn message ->
      send_agent_update(recipient, issue, message)
    end
  end

  defp send_agent_update(recipient, %{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:agent_worker_update, issue_id, message})
    :ok
  end

  defp send_agent_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defmodule TurnContext do
    @moduledoc false
    defstruct [
      :session,
      :agent_id,
      :workspace,
      :issue,
      :recipient,
      :opts,
      :state_fetcher,
      :turn,
      :max_turns,
      :attempt
    ]
  end

  defp run_agent_turns(agent_id, workspace, issue, agent_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    acpx_module = Keyword.get(opts, :acpx_module, Acpx)

    with {:ok, session} <- acpx_module.ensure_session(agent_id, workspace, worker_host: worker_host) do
      try do
        ctx = %TurnContext{
          session: session,
          agent_id: agent_id,
          workspace: workspace,
          issue: issue,
          recipient: agent_update_recipient,
          opts: opts,
          state_fetcher: issue_state_fetcher,
          turn: 1,
          max_turns: max_turns,
          attempt: 1
        }

        do_run_agent_turns(ctx)
      after
        :ok
      end
    end
  end

  defp do_run_agent_turns(%TurnContext{} = ctx) do
    prompt = build_turn_prompt(ctx)
    run_prompt_with_recovery(ctx, prompt)
  end

  defp run_prompt_with_recovery(%TurnContext{} = ctx, prompt) do
    acpx_module = Keyword.get(ctx.opts, :acpx_module, Acpx)

    case acpx_module.run_prompt(
           ctx.session,
           prompt,
           agent_message_handler(ctx.recipient, ctx.issue)
         ) do
      {:ok, %{stop_reason: :completed, exit_status: 0}} ->
        case run_validation(ctx) do
          :ok ->
            Logger.info("Completed agent run for #{issue_context(ctx.issue)} agent_id=#{ctx.agent_id} workspace=#{ctx.workspace} turn=#{ctx.turn}/#{ctx.max_turns}")

            handle_turn_completion(ctx)

          {:error, failure_class, validation_result} ->
            recover_or_fail(ctx, prompt, failure_class, validation_result)
        end

      {:ok, result} when is_map(result) ->
        recover_or_fail(ctx, prompt, Map.get(result, :error) || Map.get(result, :stop_reason), result)

      {:error, reason} ->
        recover_or_fail(ctx, prompt, reason, %{})
    end
  end

  defp recover_or_fail(%TurnContext{} = ctx, prompt, reason, result) do
    failure_class = SelfCorrection.classify(reason)
    recovery_context = recovery_context(ctx, failure_class)
    recovery = SelfCorrection.recover(failure_class, recovery_context)
    action = recovery_action(recovery)
    :ok = SelfCorrection.log_recovery_decision(recovery_context, action, recovery)

    case recovery do
      {:retry, _recovery_reason, recovery_opts} ->
        maybe_cancel_session(ctx, recovery_opts)
        apply_recovery_options(ctx, recovery_opts)
        maybe_backoff(ctx, recovery_opts)
        ctx = maybe_refresh_workspace(ctx, recovery_opts)

        next_prompt =
          if Keyword.get(recovery_opts, :corrective_prompt, false) do
            SelfCorrection.build_corrective_prompt(prompt, failure_class, recovery_context,
              command: Map.get(result, :command),
              exit_code: Map.get(result, :exit_status),
              logs: format_result_logs(result)
            )
          else
            prompt
          end

        run_prompt_with_recovery(%{ctx | attempt: ctx.attempt + 1}, next_prompt)

      {:skip, skip_reason} ->
        Logger.info("Skipping agent run retry for #{issue_context(ctx.issue)}: #{skip_reason}")
        :ok

      {:fail, fail_reason} ->
        {:error, {failure_class, fail_reason}}
    end
  end

  defp handle_turn_completion(%TurnContext{} = ctx) do
    case continue_with_issue?(ctx.issue, ctx.state_fetcher) do
      {:continue, refreshed_issue} when ctx.turn < ctx.max_turns ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{ctx.turn}/#{ctx.max_turns}")

        do_run_agent_turns(%TurnContext{ctx | issue: refreshed_issue, turn: ctx.turn + 1, attempt: 1})

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")
        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_turn_prompt(%TurnContext{turn: 1} = ctx) do
    workflow_prompt = PromptBuilder.build_prompt(ctx.issue, ctx.opts)
    runtime_context = runtime_prompt_context(ctx)

    """
    #{runtime_context}

    ---
    Workflow instructions:

    #{workflow_prompt}
    """
    |> String.trim()
  end

  defp build_turn_prompt(%TurnContext{turn: turn_number, max_turns: max_turns}) do
    """
    Continuation guidance:

    - The previous agent turn completed normally, but the issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp runtime_prompt_context(%TurnContext{} = ctx) do
    settings = Config.settings!()

    payload = %{
      issue: %{
        id: issue_value(ctx.issue, :id),
        number: issue_number(ctx.issue),
        identifier: issue_value(ctx.issue, :identifier),
        title: issue_value(ctx.issue, :title),
        body: issue_value(ctx.issue, :description),
        labels: issue_labels(ctx.issue)
      },
      selected_agent_id: ctx.agent_id,
      workspace_path: ctx.workspace,
      branch_name: issue_value(ctx.issue, :branch_name),
      repo: settings.tracker.repo,
      commit_policy: Map.from_struct(settings.commit),
      pr_policy: Map.from_struct(settings.pr),
      validation_policy: Map.from_struct(settings.validation),
      allowed_actions: [
        "modify files in the workspace",
        "run local validation commands",
        "summarize blockers with evidence"
      ],
      forbidden_actions: [
        "spawn coding-agent executables directly",
        "write secrets to disk or logs",
        "create or update pull requests unless Symphony config delegates PR ownership",
        "move GitHub issue labels unless Symphony config delegates label ownership"
      ]
    }

    """
    Symphony runtime context:

    ```json
    #{Jason.encode!(payload, pretty: true)}
    ```
    """
    |> String.trim()
  end

  defp run_validation(%TurnContext{} = ctx) do
    validation = Config.settings!().validation

    case run_validation_commands(ctx.workspace, validation_commands(validation)) do
      :ok -> check_diff_policy(ctx.workspace, validation)
      {:error, _failure_class, _result} = error -> error
      {:error, _reason} = error -> error
    end
  end

  defp validation_commands(validation) do
    [
      validation.test_command,
      validation.typecheck_command,
      validation.lint_command
      | validation.commands
    ]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
  end

  defp run_validation_commands(_workspace, []), do: :ok

  defp run_validation_commands(workspace, commands) do
    Enum.reduce_while(commands, :ok, fn command, :ok ->
      case System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true) do
        {_output, 0} ->
          {:cont, :ok}

        {output, status} ->
          {:halt,
           {:error, :validation_failed,
            %{
              command: command,
              exit_status: status,
              raw_lines: String.split(output, "\n", trim: true)
            }}}
      end
    end)
  end

  defp check_diff_policy(workspace, validation) do
    if validation.fail_if_no_diff do
      case Git.cmd(["-C", workspace, "status", "--porcelain"], stderr_to_stdout: true) do
        {"", 0} ->
          {:error, :no_changes, %{raw_lines: ["git status --porcelain returned no changes"]}}

        {_output, 0} ->
          :ok

        {output, status} ->
          {:error, :validation_failed,
           %{
             command: "git status --porcelain",
             exit_status: status,
             raw_lines: String.split(output, "\n", trim: true)
           }}
      end
    else
      :ok
    end
  end

  defp maybe_cancel_session(ctx, recovery_opts) do
    if Keyword.get(recovery_opts, :cancel_session, false) do
      acpx_module = Keyword.get(ctx.opts, :acpx_module, Acpx)
      _ = acpx_module.cancel_session(ctx.session)
    end

    :ok
  end

  defp maybe_refresh_workspace(ctx, recovery_opts) do
    if Keyword.get(recovery_opts, :fresh_workspace, false) do
      acpx_module = Keyword.get(ctx.opts, :acpx_module, Acpx)
      worker_host = Map.get(ctx.session, :worker_host)
      _ = Workspace.remove(ctx.workspace, worker_host)

      with {:ok, workspace} <- Workspace.create_for_issue(ctx.issue, worker_host),
           {:ok, session} <- acpx_module.ensure_session(ctx.agent_id, workspace, worker_host: worker_host) do
        %{ctx | workspace: workspace, session: session}
      else
        {:error, reason} ->
          Logger.warning("Fresh workspace recovery failed for #{issue_context(ctx.issue)}: #{inspect(reason)}")
          ctx
      end
    else
      ctx
    end
  end

  defp apply_recovery_options(ctx, recovery_opts) do
    with :ok <- maybe_run_installer_repair(recovery_opts),
         :ok <- maybe_run_doctor(recovery_opts),
         :ok <- maybe_stash_workspace(ctx.workspace, recovery_opts),
         :ok <- maybe_fetch_workspace(ctx.workspace, recovery_opts),
         :ok <- maybe_rebase_workspace(ctx.workspace, recovery_opts) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Recovery action failed for #{issue_context(ctx.issue)}: #{inspect(reason)}")
        :ok
    end
  end

  defp maybe_run_installer_repair(recovery_opts) do
    if Keyword.get(recovery_opts, :installer_repair, false) do
      run_repo_script("scripts/install-symphony.sh", ["--install-missing"])
    else
      :ok
    end
  end

  defp maybe_run_doctor(recovery_opts) do
    if Keyword.get(recovery_opts, :doctor, false) do
      run_repo_script("scripts/symphony-doctor.sh", [])
    else
      :ok
    end
  end

  defp maybe_stash_workspace(workspace, recovery_opts) do
    if Keyword.get(recovery_opts, :stash, false) do
      run_git(workspace, ["stash", "push", "--include-untracked", "-m", "symphony-recovery-stash"])
    else
      :ok
    end
  end

  defp maybe_fetch_workspace(workspace, recovery_opts) do
    if Keyword.get(recovery_opts, :fetch, false) or Keyword.get(recovery_opts, :rebase, false) do
      run_git(workspace, ["fetch", "--all", "--prune"])
    else
      :ok
    end
  end

  defp maybe_rebase_workspace(workspace, recovery_opts) do
    if Keyword.get(recovery_opts, :rebase, false) do
      run_git(workspace, ["rebase", Config.settings!().workspace.base_branch])
    else
      :ok
    end
  end

  defp run_repo_script(script, args) do
    with {:ok, repo_root} <- repo_root(),
         path <- Path.join(repo_root, script),
         true <- File.exists?(path) do
      case System.cmd(path, args, cd: repo_root, stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {script, status, String.trim(output)}}
      end
    else
      false -> {:error, {:script_not_found, script}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repo_root do
    case Git.cmd(["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_repo_root_failed, status, String.trim(output)}}
    end
  end

  defp run_git(workspace, args) do
    case Git.cmd(["-C", workspace] ++ args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_recovery_failed, args, status, String.trim(output)}}
    end
  end

  defp maybe_backoff(ctx, recovery_opts) do
    backoff = Keyword.get(recovery_opts, :backoff, 0)

    if Keyword.get(ctx.opts, :sleep_backoff, true) and is_integer(backoff) and backoff > 0 do
      Process.sleep(backoff)
    end

    :ok
  end

  defp recovery_action({:retry, _reason, opts}) do
    cond do
      Keyword.get(opts, :installer_repair, false) -> :repair_and_retry
      Keyword.get(opts, :cancel_session, false) -> :cancel_and_retry
      Keyword.get(opts, :stash, false) -> :stash_and_retry
      Keyword.get(opts, :fresh_workspace, false) -> :repair_and_retry
      true -> :retry
    end
  end

  defp recovery_action({:skip, _reason}), do: :skip
  defp recovery_action({:fail, _reason}), do: :fail

  defp recovery_context(%TurnContext{} = ctx, failure_class) do
    %{
      run_id: ctx.session.session_name,
      issue_id: issue_value(ctx.issue, :id),
      issue_number: issue_number(ctx.issue),
      issue_labels: issue_labels(ctx.issue),
      selected_agent: ctx.agent_id,
      selected_acpx_argv: CommandBuilder.prompt(ctx.agent_id, ctx.workspace, ctx.session.session_name, "[prompt-file]"),
      acpx_session_name: ctx.session.session_name,
      workspace_path: ctx.workspace,
      branch_name: issue_value(ctx.issue, :branch_name),
      failure_class: failure_class,
      attempt: ctx.attempt
    }
  end

  defp issue_value(issue, key), do: Map.get(issue, key)

  defp issue_number(issue) when is_map(issue) do
    case Map.get(issue, :number) do
      nil -> nil
      number -> to_string(number)
    end
  end

  defp issue_labels(issue) do
    issue
    |> Map.get(:labels, [])
    |> Enum.map(&to_string/1)
  end

  defp format_result_logs(result) do
    result
    |> Map.get(:raw_lines, [])
    |> Enum.take(-50)
    |> Enum.join("\n")
  end

  defp continue_with_issue?(%{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp log_error(issue, event_type, reason) do
    StructuredLogger.log_named("errors", %{
      event_type: event_type,
      severity: "error",
      issue_id: issue_value(issue, :id),
      issue_number: issue_number(issue),
      branch_name: issue_value(issue, :branch_name),
      message: inspect(reason),
      payload: %{reason: inspect(reason), issue_labels: issue_labels(issue)}
    })
  end
end
