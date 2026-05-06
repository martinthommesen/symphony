defmodule SymphonyElixir.SelfCorrection do
  @moduledoc """
  Failure classification and bounded self-correction for the orchestrator.

  The classifier maps errors to known failure classes. The recovery engine
  decides whether to retry, repair, or fail based on configured policies.

  All recovery attempts are logged with structured context.
  """

  require Logger

  alias SymphonyElixir.{Config, Redaction, StructuredLogger}

  @type failure_class ::
          :dependency_missing
          | :auth_missing
          | :acpx_missing
          | :acpx_adapter_error
          | :acpx_session_error
          | :agent_stalled
          | :agent_cancelled
          | :validation_failed
          | :tests_failed
          | :no_changes
          | :no_commit
          | :dirty_worktree
          | :branch_conflict
          | :push_failed
          | :pr_create_failed
          | :pr_update_failed
          | :ambiguous_agent_labels
          | :unsupported_agent
          | :config_invalid
          | :workspace_corrupt
          | :unknown_failure
          | :skip

  @type recovery_action ::
          :retry
          | :repair_and_retry
          | :cancel_and_retry
          | :stash_and_retry
          | :reset_and_retry
          | :reinstall_and_retry
          | :fail
          | :skip

  @type recovery_result ::
          {:retry, String.t(), keyword()}
          | {:fail, String.t()}
          | {:skip, String.t()}

  @type context :: %{
          run_id: String.t(),
          issue_id: String.t() | nil,
          issue_number: String.t() | nil,
          issue_labels: [String.t()],
          selected_agent: String.t() | nil,
          selected_acpx_argv: [String.t()],
          acpx_session_name: String.t() | nil,
          workspace_path: String.t() | nil,
          branch_name: String.t() | nil,
          failure_class: failure_class(),
          attempt: pos_integer()
        }

  # -- failure classification --

  @doc """
  Classify an error into a known failure class.
  """
  @spec classify(term()) :: failure_class()
  def classify(error) do
    classify_by_shape(error)
  end

  defp classify_by_shape({:acpx_not_found, _}), do: :acpx_missing
  defp classify_by_shape({:acpx_exit, _}), do: :acpx_adapter_error
  defp classify_by_shape({:acpx_session_error, %{} = details}), do: classify_acpx_session_error(details)
  defp classify_by_shape({:acpx_session_exit, _}), do: :acpx_adapter_error
  defp classify_by_shape(:acpx_session_timeout), do: :agent_stalled
  defp classify_by_shape({:acpx_session_error, _}), do: :acpx_session_error
  defp classify_by_shape({:error, :missing_linear_api_token}), do: :auth_missing
  defp classify_by_shape({:error, :missing_linear_project_slug}), do: :config_invalid
  defp classify_by_shape({:error, {:invalid_workflow_config, _}}), do: :config_invalid
  defp classify_by_shape({:error, {:unsupported_tracker_kind, _}}), do: :config_invalid
  defp classify_by_shape({:error, {:path_canonicalize_failed, _, _}}), do: :workspace_corrupt
  defp classify_by_shape({:error, :no_dispatch_label}), do: :unsupported_agent
  defp classify_by_shape({:error, :blocked}), do: :skip
  defp classify_by_shape({:error, :running}), do: :skip
  defp classify_by_shape({:error, :review}), do: :skip
  defp classify_by_shape({:error, :failed}), do: :skip
  defp classify_by_shape({:error, {:ambiguous_agents, _}}), do: :ambiguous_agent_labels
  defp classify_by_shape({:error, {:unsupported_agent, _}}), do: :unsupported_agent
  defp classify_by_shape({:error, :no_labels}), do: :unsupported_agent
  defp classify_by_shape(class) when class in [:validation_failed, :tests_failed, :no_changes], do: class
  defp classify_by_shape(%RuntimeError{message: message}), do: classify_runtime_error(message)
  defp classify_by_shape(_), do: :unknown_failure

  defp classify_runtime_error(message) do
    cond do
      String.contains?(message, "stalled") -> :agent_stalled
      String.contains?(message, "cancelled") -> :agent_cancelled
      true -> :unknown_failure
    end
  end

  defp classify_acpx_session_error(%{"code" => code, "message" => message}) do
    cond do
      String.contains?(message, "initialize") or String.contains?(message, "startup") ->
        :acpx_adapter_error

      String.contains?(message, "timeout") or String.contains?(message, "stall") ->
        :agent_stalled

      code == -32_600 or code == -32_603 ->
        :acpx_session_error

      true ->
        :acpx_adapter_error
    end
  end

  defp classify_acpx_session_error(_), do: :acpx_session_error

  # -- recovery decisions --

  @doc """
  Decide the recovery action for a classified failure.

  Returns `{:retry, reason, opts}`, `{:fail, reason}`, or `{:skip, reason}`.
  """
  @spec recover(failure_class(), context(), map() | nil) :: recovery_result()
  def recover(failure_class, context, config_override \\ nil) do
    config =
      config_override || Config.settings!().self_correction

    cond do
      not config.enabled ->
        return_fail("self-correction disabled")

      context.attempt > config.max_correction_attempts ->
        return_fail("max correction attempts (#{config.max_correction_attempts}) reached")

      true ->
        do_recover(failure_class, context, config)
    end
  end

  defp do_recover(failure_class, context, config) do
    dispatch_recover(failure_class, context, config)
  end

  defp dispatch_recover(:dependency_missing, _ctx, cfg) do
    maybe_retry(cfg.retry_on_dependency_missing, "dependency missing: attempting repair",
      installer_repair: true,
      doctor: true,
      backoff: cfg.retry_backoff_ms
    )
  end

  defp dispatch_recover(:auth_missing, _ctx, _cfg) do
    return_fail("auth missing: requires operator action")
  end

  defp dispatch_recover(:acpx_missing, _ctx, cfg) do
    maybe_retry(cfg.retry_on_acpx_crash, "acpx missing: attempting reinstall",
      installer_repair: true,
      doctor: true,
      backoff: cfg.retry_backoff_ms
    )
  end

  defp dispatch_recover(:acpx_adapter_error, _ctx, cfg) do
    maybe_retry(cfg.retry_on_acpx_crash, "acpx adapter error: retrying with backoff", backoff: cfg.retry_backoff_ms)
  end

  defp dispatch_recover(:acpx_session_error, _ctx, cfg) do
    maybe_retry(cfg.retry_on_acpx_crash, "acpx session error: retrying", backoff: cfg.retry_backoff_ms)
  end

  defp dispatch_recover(:agent_stalled, _ctx, cfg) do
    maybe_retry(cfg.retry_on_stall, "agent stalled: cancelling and retrying", cancel_session: true, backoff: cfg.retry_backoff_ms)
  end

  defp dispatch_recover(:agent_cancelled, _ctx, _cfg) do
    return_fail("agent cancelled: not retrying cancellation")
  end

  defp dispatch_recover(:validation_failed, _ctx, cfg) do
    maybe_retry(cfg.retry_on_validation_failure, "validation failed: building corrective prompt", corrective_prompt: true, backoff: cfg.retry_backoff_ms)
  end

  defp dispatch_recover(:tests_failed, _ctx, cfg) do
    maybe_retry(cfg.retry_on_validation_failure, "tests failed: building corrective prompt", corrective_prompt: true, backoff: cfg.retry_backoff_ms)
  end

  defp dispatch_recover(:no_changes, _ctx, cfg) do
    maybe_retry(cfg.retry_on_no_changes, "no changes: requesting concrete changes", corrective_prompt: true, backoff: cfg.retry_backoff_ms)
  end

  defp dispatch_recover(:no_commit, _ctx, _cfg) do
    return_fail("no commit: not retrying")
  end

  defp dispatch_recover(:dirty_worktree, _ctx, cfg) do
    return_retry("dirty worktree: applying stash policy", stash: true, backoff: cfg.retry_backoff_ms)
  end

  defp dispatch_recover(:branch_conflict, _ctx, cfg) do
    maybe_retry(cfg.retry_on_merge_conflict, "branch conflict: fetching and rebasing", rebase: true, backoff: cfg.retry_backoff_ms)
  end

  defp dispatch_recover(:push_failed, _ctx, cfg) do
    return_retry("push failed: fetching and retrying", fetch: true, backoff: cfg.retry_backoff_ms)
  end

  defp dispatch_recover(:pr_create_failed, _ctx, cfg) do
    maybe_retry(cfg.retry_on_pr_creation_failure, "PR creation failed: retrying", backoff: cfg.retry_backoff_ms)
  end

  defp dispatch_recover(:pr_update_failed, _ctx, cfg) do
    maybe_retry(cfg.retry_on_pr_creation_failure, "PR update failed: retrying", backoff: cfg.retry_backoff_ms)
  end

  defp dispatch_recover(:ambiguous_agent_labels, _ctx, _cfg) do
    return_fail("ambiguous agent labels: add failed label and comment")
  end

  defp dispatch_recover(:unsupported_agent, _ctx, _cfg) do
    return_fail("unsupported agent: add failed label and comment")
  end

  defp dispatch_recover(:config_invalid, _ctx, _cfg) do
    return_fail("invalid config: fix WORKFLOW.md")
  end

  defp dispatch_recover(:workspace_corrupt, _ctx, cfg) do
    return_retry("workspace corrupt: creating fresh workspace", fresh_workspace: true, backoff: cfg.retry_backoff_ms)
  end

  defp dispatch_recover(:unknown_failure, ctx, cfg) do
    if ctx.attempt < cfg.max_correction_attempts do
      return_retry("unknown failure: retrying", backoff: cfg.retry_backoff_ms)
    else
      return_fail("unknown failure: max attempts reached")
    end
  end

  defp dispatch_recover(:skip, _ctx, _cfg) do
    {:skip, "issue state is not dispatchable"}
  end

  defp dispatch_recover(_, _ctx, _cfg) do
    return_fail("unclassified failure: not retrying")
  end

  defp maybe_retry(true, reason, opts), do: return_retry(reason, opts)
  defp maybe_retry(false, reason, _opts), do: return_fail("#{reason}: retry disabled")

  @doc """
  Log a structured recovery decision.
  """
  @spec log_recovery_decision(context(), recovery_action(), recovery_result()) :: :ok
  def log_recovery_decision(context, action, result) do
    {outcome, reason, opts} =
      case result do
        {:retry, r, o} -> {"retry", r, o}
        {:fail, r} -> {"fail", r, []}
        {:skip, r} -> {"skip", r, []}
      end

    Logger.info(
      "Self-correction decision: " <>
        "run_id=#{context.run_id} " <>
        "issue=#{context.issue_number || "nil"} " <>
        "agent=#{context.selected_agent || "nil"} " <>
        "class=#{context.failure_class} " <>
        "attempt=#{context.attempt}/#{Config.settings!().self_correction.max_correction_attempts} " <>
        "action=#{action} " <>
        "outcome=#{outcome} " <>
        "reason=#{reason} " <>
        "opts=#{inspect(opts)}"
    )

    StructuredLogger.log_named("orchestrator", %{
      run_id: context.run_id,
      issue_number: context.issue_number,
      issue_id: context.issue_id,
      agent_id: context.selected_agent,
      acpx_session_name: context.acpx_session_name,
      workspace_path: context.workspace_path,
      branch_name: context.branch_name,
      event_type: "self_correction_decision",
      severity: event_severity(outcome),
      message: reason,
      payload: %{
        issue_labels: context.issue_labels,
        selected_agent: context.selected_agent,
        selected_acpx_argv: Enum.map(Map.get(context, :selected_acpx_argv, []), &Redaction.redact/1),
        failure_class: context.failure_class,
        recovery_action: action,
        attempt_number: context.attempt,
        result: outcome,
        next_action: next_action(result),
        opts: Map.new(opts)
      }
    })

    :ok
  end

  @doc """
  Build a corrective prompt for retry attempts.
  """
  @spec build_corrective_prompt(String.t(), failure_class(), context(), keyword()) :: String.t()
  def build_corrective_prompt(original_prompt, failure_class, context, opts \\ []) do
    template =
      Config.settings!().self_correction.correction_prompt_template || default_correction_template()

    details =
      case failure_class do
        :validation_failed ->
          command = Keyword.get(opts, :command, "unknown")
          exit_code = Keyword.get(opts, :exit_code, "unknown")
          logs = Keyword.get(opts, :logs, "")
          "Validation failed.\nCommand: #{command}\nExit code: #{exit_code}\nLogs:\n#{logs}"

        :tests_failed ->
          command = Keyword.get(opts, :command, "unknown")
          exit_code = Keyword.get(opts, :exit_code, "unknown")
          logs = Keyword.get(opts, :logs, "")
          "Tests failed.\nCommand: #{command}\nExit code: #{exit_code}\nLogs:\n#{logs}"

        :no_changes ->
          "The previous turn produced no code changes. Please make concrete, meaningful changes to address the issue."

        :agent_stalled ->
          "The agent stalled. Resume from the current workspace state."

        _ ->
          "Retry after failure: #{failure_class}. Attempt #{context.attempt}."
      end

    template
    |> String.replace("{{ original_prompt }}", original_prompt)
    |> String.replace("{{ failure_class }}", to_string(failure_class))
    |> String.replace("{{ attempt }}", to_string(context.attempt))
    |> String.replace("{{ details }}", details)
  end

  defp default_correction_template do
    """
    {{ original_prompt }}

    ---
    Self-correction context (attempt {{ attempt }}):
    Failure: {{ failure_class }}
    {{ details }}
    """
  end

  defp return_retry(reason, opts), do: {:retry, reason, opts}
  defp return_fail(reason), do: {:fail, reason}

  defp event_severity("fail"), do: "error"
  defp event_severity(_outcome), do: "info"

  defp next_action({:retry, _reason, _opts}), do: "retry"
  defp next_action({:skip, _reason}), do: "skip"
  defp next_action({:fail, _reason}), do: "fail"
end
