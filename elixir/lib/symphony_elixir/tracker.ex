defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}

  @doc """
  Optional. Returns all issues currently managed by Symphony — at minimum
  open candidates plus issues bearing any of `running/review/failed/blocked/done`
  labels. Adapters that cannot enumerate this should return
  `{:error, :unsupported}`.
  """
  @callback list_managed_issues() :: {:ok, [term()]} | {:error, term()}

  @doc """
  Apply a tracker-side "block" semantics (e.g. add the configured `blocked`
  label) to `issue_id`. Adapters that cannot represent blocking should
  return `{:error, :unsupported}`.
  """
  @callback block_issue(String.t()) :: :ok | {:error, term()}

  @doc """
  Reverse a previous `block_issue/1`.
  """
  @callback unblock_issue(String.t()) :: :ok | {:error, term()}

  @doc """
  Mark `issue_id` for retry: clear failed/done/review labels and remove
  `running` so the orchestrator picks it up again.
  """
  @callback mark_for_retry(String.t()) :: :ok | {:error, term()}

  # Must come after all referenced @callback declarations.
  @optional_callbacks [
    list_managed_issues: 0,
    block_issue: 1,
    unblock_issue: 1,
    mark_for_retry: 1
  ]

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec list_managed_issues() :: {:ok, [term()]} | {:error, term()}
  def list_managed_issues do
    a = adapter()

    if function_exported?(a, :list_managed_issues, 0) do
      a.list_managed_issues()
    else
      {:error, :unsupported}
    end
  end

  @spec block_issue(String.t()) :: :ok | {:error, term()}
  def block_issue(issue_id) do
    a = adapter()

    if function_exported?(a, :block_issue, 1) do
      a.block_issue(issue_id)
    else
      {:error, :unsupported}
    end
  end

  @spec unblock_issue(String.t()) :: :ok | {:error, term()}
  def unblock_issue(issue_id) do
    a = adapter()

    if function_exported?(a, :unblock_issue, 1) do
      a.unblock_issue(issue_id)
    else
      {:error, :unsupported}
    end
  end

  @spec mark_for_retry(String.t()) :: :ok | {:error, term()}
  def mark_for_retry(issue_id) do
    a = adapter()

    if function_exported?(a, :mark_for_retry, 1) do
      a.mark_for_retry(issue_id)
    else
      {:error, :unsupported}
    end
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      "linear" -> SymphonyElixir.Linear.Adapter
      "github" -> SymphonyElixir.GitHub.Adapter
      _ -> SymphonyElixir.GitHub.Adapter
    end
  end
end
