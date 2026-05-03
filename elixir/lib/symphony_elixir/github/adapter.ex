defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub Issues tracker adapter.

  Implements the `SymphonyElixir.Tracker` behaviour and adds GitHub-specific
  operations needed by the orchestrator and finalizer.

  Canonical externally-visible state for an issue is its set of labels plus
  the GitHub issue state. The label semantics are configured in the
  `tracker` block of `WORKFLOW.md`/`config.yml`.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, GitHub.CLI, GitHub.Issue, GitHub.Parser, RepoId}
  alias SymphonyElixir.Linear.Issue, as: LinearIssue

  require Logger

  # ---------------------------------------------------------------------------
  # Tracker behaviour
  # ---------------------------------------------------------------------------

  @impl true
  def fetch_candidate_issues do
    with {:ok, repo} <- repo_setting(),
         tracker <- tracker_settings(),
         {:ok, issues} <- list_open_issues_with_label(repo, tracker.active_labels) do
      candidates =
        issues
        |> Enum.filter(&eligible?(&1, tracker))
        |> Enum.map(&Issue.to_linear_issue(&1, label_state(&1, tracker)))

      {:ok, candidates}
    end
  end

  @impl true
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    states =
      state_names
      |> Enum.map(&String.downcase/1)
      |> MapSet.new()

    with {:ok, repo} <- repo_setting(),
         tracker <- tracker_settings(),
         {:ok, open_issues} <- list_open_issues_with_label(repo, tracker.active_labels),
         {:ok, closed_issues} <- maybe_list_closed_issues(repo, tracker.active_labels, states) do
      filtered =
        (open_issues ++ closed_issues)
        |> Enum.map(&{&1, label_state(&1, tracker)})
        |> Enum.filter(fn {_issue, state} -> MapSet.member?(states, state) end)
        |> Enum.map(fn {issue, state} -> Issue.to_linear_issue(issue, state) end)

      {:ok, filtered}
    end
  end

  defp maybe_list_closed_issues(repo, active_labels, states) do
    # The closed-issue REST endpoint is only worth hitting when the caller
    # asked for terminal states. The orchestrator's startup terminal
    # cleanup needs this path so workspaces for closed issues get pruned.
    if MapSet.member?(states, "closed") do
      list_closed_issues(repo, List.wrap(active_labels))
    else
      {:ok, []}
    end
  end

  @impl true
  def fetch_issue_states_by_ids(ids) when is_list(ids) do
    with {:ok, repo} <- repo_setting() do
      tracker = tracker_settings()

      results =
        ids
        |> Enum.uniq()
        |> Enum.map(&fetch_issue_for_id(repo, &1, tracker))
        |> Enum.reject(&is_nil/1)

      {:ok, results}
    end
  end

  @impl true
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, repo} <- repo_setting(),
         number when is_integer(number) <- parse_issue_number(issue_id) do
      case CLI.run(["issue", "comment", Integer.to_string(number), "--repo", repo, "--body", body]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, {:invalid_issue_id, issue_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, repo} <- repo_setting(),
         number when is_integer(number) <- parse_issue_number(issue_id) do
      tracker = tracker_settings()
      transition_to(repo, number, state_name, tracker)
    else
      :error -> {:error, {:invalid_issue_id, issue_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List Symphony-managed issues for the operations cockpit.

  Returns open issues with any active label plus closed issues whose
  labels include any Symphony state label. The result is shaped as
  Linear-style structs so existing presenters can consume it.
  """
  @spec list_managed_issues() :: {:ok, [SymphonyElixir.Linear.Issue.t()]} | {:error, term()}
  def list_managed_issues do
    with {:ok, repo} <- repo_setting() do
      tracker = tracker_settings()

      with {:ok, open_issues} <- list_open_issues_with_label(repo, tracker.active_labels),
           {:ok, closed_issues} <- list_closed_issues(repo, List.wrap(tracker.active_labels)) do
        managed =
          (open_issues ++ closed_issues)
          |> Enum.map(fn issue ->
            Issue.to_linear_issue(issue, label_state(issue, tracker))
          end)

        {:ok, managed}
      end
    end
  end

  @doc """
  Add the first configured `blocked_labels` to `issue_id`. Returns
  `{:error, :unsupported}` when no blocked labels are configured.
  """
  @spec block_issue(String.t()) :: :ok | {:error, term()}
  def block_issue(issue_id) when is_binary(issue_id) do
    with {:ok, repo} <- repo_setting(),
         number when is_integer(number) <- parse_issue_number(issue_id) do
      tracker = tracker_settings()

      case List.wrap(tracker.blocked_labels) do
        [label | _] -> add_labels(repo, number, [label])
        _ -> {:error, :unsupported}
      end
    else
      :error -> {:error, {:invalid_issue_id, issue_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Remove all configured `blocked_labels` from `issue_id`.
  """
  @spec unblock_issue(String.t()) :: :ok | {:error, term()}
  def unblock_issue(issue_id) when is_binary(issue_id) do
    with {:ok, repo} <- repo_setting(),
         number when is_integer(number) <- parse_issue_number(issue_id) do
      tracker = tracker_settings()

      case List.wrap(tracker.blocked_labels) do
        [] -> {:error, :unsupported}
        labels -> remove_labels(repo, number, labels)
      end
    else
      :error -> {:error, {:invalid_issue_id, issue_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reset Symphony status labels so the orchestrator re-claims the issue on
  the next poll: removes `running`, `review`, `failed`, `done`.
  """
  @spec mark_for_retry(String.t()) :: :ok | {:error, term()}
  def mark_for_retry(issue_id) when is_binary(issue_id) do
    with {:ok, repo} <- repo_setting(),
         number when is_integer(number) <- parse_issue_number(issue_id) do
      tracker = tracker_settings()

      remove_labels(repo, number, [
        tracker.running_label,
        tracker.review_label,
        tracker.failed_label,
        tracker.done_label
      ])
    else
      :error -> {:error, {:invalid_issue_id, issue_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # GitHub-specific public operations
  # ---------------------------------------------------------------------------

  @doc """
  Add `labels` to issue `number` in `repo`.
  """
  @spec add_labels(String.t(), integer(), [String.t()]) :: :ok | {:error, term()}
  def add_labels(_repo, _number, []), do: :ok

  def add_labels(repo, number, labels) when is_list(labels) do
    args =
      ["issue", "edit", Integer.to_string(number), "--repo", CLI.assert_repo!(repo)] ++
        Enum.flat_map(labels, fn label -> ["--add-label", label] end)

    case CLI.run(args) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Remove `labels` from issue `number` in `repo`.
  """
  @spec remove_labels(String.t(), integer(), [String.t()]) :: :ok | {:error, term()}
  def remove_labels(_repo, _number, []), do: :ok

  def remove_labels(repo, number, labels) when is_list(labels) do
    args =
      ["issue", "edit", Integer.to_string(number), "--repo", CLI.assert_repo!(repo)] ++
        Enum.flat_map(labels, fn label -> ["--remove-label", label] end)

    case CLI.run(args) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Create a label if it does not exist. Idempotent.
  """
  @spec ensure_label(String.t(), String.t()) :: :ok | {:error, term()}
  def ensure_label(repo, label) when is_binary(label) do
    case CLI.run_lenient(["label", "create", label, "--repo", CLI.assert_repo!(repo), "--force"]) do
      {0, _} -> :ok
      {_, output} -> {:error, {:gh_label_create, output}}
    end
  end

  @doc """
  Eligibility check for one issue against the tracker config.

  Default rules:

  - `state == "open"`
  - has at least one configured `active_label`
  - has none of the `blocked_labels`
  - does not have running/done/failed/review labels
  """
  @spec eligible?(Issue.t(), map()) :: boolean()
  def eligible?(%Issue{} = issue, tracker) do
    label_set = MapSet.new(issue.labels)
    state = String.downcase(issue.state || "")

    active_labels = List.wrap(tracker.active_labels)

    cond do
      state != "open" -> false
      active_labels != [] and not has_any?(label_set, active_labels) -> false
      has_any?(label_set, tracker.blocked_labels) -> false
      MapSet.member?(label_set, tracker.running_label) -> false
      MapSet.member?(label_set, tracker.review_label) -> false
      MapSet.member?(label_set, tracker.done_label) -> false
      not tracker.retry_failed and MapSet.member?(label_set, tracker.failed_label) -> false
      true -> true
    end
  end

  @doc """
  Determine the orchestrator-visible state string for `issue`.

  Returns one of: `"running"`, `"review"`, `"failed"`, `"done"`,
  `"blocked"`, `"closed"`, or `"open"`.
  """
  @spec label_state(Issue.t(), map()) :: String.t()
  def label_state(%Issue{} = issue, tracker) do
    label_set = MapSet.new(issue.labels)
    state = String.downcase(issue.state || "")

    cond do
      state == "closed" -> "closed"
      MapSet.member?(label_set, tracker.running_label) -> "running"
      MapSet.member?(label_set, tracker.review_label) -> "review"
      MapSet.member?(label_set, tracker.failed_label) -> "failed"
      MapSet.member?(label_set, tracker.done_label) -> "done"
      has_any?(label_set, tracker.blocked_labels) -> "blocked"
      true -> "open"
    end
  end

  @doc """
  Fetch a single GitHub issue by number.
  """
  @spec fetch_issue(String.t(), integer()) :: {:ok, Issue.t()} | {:error, term()}
  def fetch_issue(repo, number) when is_integer(number) do
    repo = CLI.assert_repo!(repo)

    case CLI.api("repos/#{repo}/issues/#{number}") do
      {:ok, payload} when is_map(payload) ->
        case Issue.from_gh_payload(payload) do
          %Issue{} = issue -> {:ok, issue}
          nil -> {:error, :not_an_issue}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List issue comments.
  """
  @spec list_comments(String.t(), integer()) :: {:ok, [map()]} | {:error, term()}
  def list_comments(repo, number) when is_integer(number) do
    repo = CLI.assert_repo!(repo)
    path = "repos/#{repo}/issues/#{number}/comments?per_page=100"

    # Use --paginate with --slurp; without --slurp gh writes one JSON array
    # per page concatenated together, which is not valid JSON for issues
    # with more than 100 comments.
    case CLI.run(["api", "--paginate", "--slurp", path]) do
      {:ok, body} -> decode_slurped_issues(body)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Transition labels for an issue based on a logical state name.
  """
  @spec transition_to(String.t(), integer(), String.t(), map()) :: :ok | {:error, term()}
  def transition_to(repo, number, target, tracker)
      when target in ["running", "review", "failed", "done", "open"] do
    {add, remove} = transition_label_delta(target, tracker)

    with :ok <- add_labels(repo, number, add),
         :ok <- remove_labels(repo, number, remove) do
      :ok
    end
  end

  def transition_to(_repo, _number, target, _tracker), do: {:error, {:unsupported_state, target}}

  # Public for tests; do not depend on this from production callers.
  @doc false
  @spec transition_delta_for_test(String.t(), map()) :: {[String.t()], [String.t()]}
  def transition_delta_for_test(state, tracker), do: transition_label_delta(state, tracker)

  defp transition_label_delta("running", tracker) do
    {[tracker.running_label], []}
  end

  # Successful retries must clear `failed_label` so the issue does not end
  # up tagged with both `failed` and `review`/`done` simultaneously, which
  # would block future redispatches when `retry_failed` is later disabled.
  defp transition_label_delta("review", tracker) do
    {[tracker.review_label], [tracker.running_label, tracker.failed_label]}
  end

  defp transition_label_delta("failed", tracker) do
    {[tracker.failed_label], [tracker.running_label]}
  end

  defp transition_label_delta("done", tracker) do
    {[tracker.done_label], [tracker.running_label, tracker.failed_label]}
  end

  defp transition_label_delta("open", tracker) do
    {[],
     [
       tracker.running_label,
       tracker.review_label,
       tracker.done_label,
       tracker.failed_label
     ]}
  end

  # ---------------------------------------------------------------------------
  # Listing helpers
  # ---------------------------------------------------------------------------

  defp list_open_issues_with_label(repo, []), do: list_open_issues(repo, [])

  defp list_open_issues_with_label(repo, labels) when is_list(labels) do
    list_open_issues(repo, labels)
  end

  defp list_open_issues(repo, labels), do: list_issues_for_state(repo, labels, "open")

  defp list_closed_issues(repo, labels), do: list_issues_for_state(repo, labels, "closed")

  defp list_issues_for_state(repo, labels, state) when state in ["open", "closed"] do
    # Use `gh api --paginate` so repos with >200 candidate issues are not
    # silently truncated. The REST endpoint returns full issue payloads
    # (including `pull_request` for PRs, which `Issue.from_gh_payload/1`
    # filters out).
    repo = CLI.assert_repo!(repo)

    base_path = "repos/#{repo}/issues?state=#{state}&per_page=100"

    path =
      case labels do
        [] -> base_path
        labels -> base_path <> "&labels=" <> URI.encode(Enum.join(labels, ","))
      end

    # `--slurp` collects every paginated page into a single outer JSON
    # array (one element per page) without relying on string-boundary
    # heuristics. Each element is itself an array of issue payloads, so
    # we flatten one level after decoding.
    case CLI.run(["api", "--paginate", "--slurp", path]) do
      {:ok, body} ->
        case decode_slurped_issues(body) do
          {:ok, decoded} ->
            issues =
              decoded
              |> Enum.map(&Issue.from_gh_payload/1)
              |> Enum.reject(&is_nil/1)

            {:ok, issues}

          {:error, reason} ->
            {:error, {:gh_decode_error, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_slurped_issues(body) when is_binary(body) do
    case String.trim(body) do
      "" ->
        {:ok, []}

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, pages} when is_list(pages) ->
            {:ok,
             Enum.flat_map(pages, fn
               page when is_list(page) -> page
               _ -> []
             end)}

          {:ok, _} ->
            {:ok, []}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp fetch_issue_for_id(repo, id, tracker) do
    case parse_issue_number(id) do
      :error ->
        nil

      number ->
        case fetch_issue(repo, number) do
          {:ok, issue} ->
            Issue.to_linear_issue(issue, label_state(issue, tracker))

          {:error, reason} ->
            Logger.warning("github fetch_issue failed for #{number}: #{inspect(reason)}")
            nil
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Settings helpers
  # ---------------------------------------------------------------------------

  defp tracker_settings, do: Config.settings!().tracker

  defp repo_setting do
    case Config.settings!().tracker.repo do
      repo when is_binary(repo) ->
        case RepoId.validate(repo) do
          {:ok, repo} -> {:ok, repo}
          {:error, _} -> {:error, {:invalid_repo, repo}}
        end

      _ ->
        {:error, :missing_github_repo}
    end
  end

  defp parse_issue_number(value) when is_integer(value), do: value

  defp parse_issue_number("#" <> rest), do: parse_issue_number(rest)

  defp parse_issue_number(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _ -> :error
    end
  end

  defp parse_issue_number(_), do: :error

  defp has_any?(label_set, labels) do
    Enum.any?(List.wrap(labels), fn label -> MapSet.member?(label_set, label) end)
  end

  # Helper for tests / external callers that already have a Linear-shaped issue
  # back from the orchestrator and need to look up its number.
  @doc false
  @spec linear_to_number(LinearIssue.t()) :: integer() | :error
  def linear_to_number(%LinearIssue{id: id}) when is_binary(id), do: parse_issue_number(id)
  def linear_to_number(_), do: :error

  # Re-exported for tests
  @doc false
  @spec priority_from_labels([String.t()]) :: String.t() | nil
  def priority_from_labels(labels), do: Parser.priority_from_labels(labels)
end
