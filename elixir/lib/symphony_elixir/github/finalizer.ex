defmodule SymphonyElixir.GitHub.Finalizer do
  @moduledoc """
  Owns post-Copilot GitHub state: branch validation, optional auto-commit,
  branch push, PR create/update, issue comment, and label transition.

  Symphony, not Copilot, performs these operations. Copilot is denied
  `git push`, `gh pr`, and `gh issue` patterns by default.
  """

  alias SymphonyElixir.{Config, GitHub.Adapter, GitHub.CLI, Redaction}
  alias SymphonyElixir.GitHub.Issue, as: GhIssue

  require Logger

  @type result :: %{
          status: :success | :failed,
          pr_url: String.t() | nil,
          branch: String.t(),
          summary: String.t(),
          reason: term() | nil
        }

  @doc """
  Run the full finalizer for `issue` after a Copilot run.

  `run_summary` is a short string Copilot emitted (or any other summary
  the runner has). `run_id` is opaque to GitHub but is included in the PR
  body for traceability.
  """
  @spec finalize(GhIssue.t(), Path.t(), String.t(), String.t()) :: {:ok, result()} | {:error, term()}
  def finalize(%GhIssue{} = issue, workspace, run_id, run_summary)
      when is_binary(workspace) and is_binary(run_id) and is_binary(run_summary) do
    settings = Config.settings!()
    finalizer = settings.finalizer
    tracker = settings.tracker
    repo = tracker.repo

    with :ok <- ensure_git_repo(workspace),
         :ok <- ensure_on_expected_branch(workspace, issue.branch_name),
         {:ok, change_state} <- detect_changes(workspace, issue.branch_name),
         {:ok, change_state} <- maybe_auto_commit(workspace, change_state, issue.number, finalizer) do
      if change_state.commits == 0 do
        mark_failed(repo, issue, tracker, "No commits produced by Copilot run.")

        {:ok,
         %{
           status: :failed,
           pr_url: nil,
           branch: issue.branch_name,
           summary: "No commits produced",
           reason: :no_commits
         }}
      else
        do_publish(repo, issue, workspace, run_id, run_summary, finalizer, tracker)
      end
    else
      {:error, reason} ->
        Logger.error("Finalizer failed for issue #{issue.number}: #{inspect(reason)}")
        mark_failed(repo, issue, tracker, "Finalizer error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_publish(repo, issue, workspace, run_id, run_summary, finalizer, tracker) do
    with :ok <- maybe_push_branch(workspace, issue.branch_name, finalizer),
         {:ok, pr_url} <- maybe_open_or_update_pr(repo, issue, run_id, run_summary, finalizer) do
      :ok = comment_on_issue(repo, issue, pr_url, run_summary)
      :ok = Adapter.transition_to(repo, issue.number, "review", tracker)
      :ok = maybe_close_issue(repo, issue, finalizer)

      {:ok,
       %{
         status: :success,
         pr_url: pr_url,
         branch: issue.branch_name,
         summary: run_summary,
         reason: nil
       }}
    end
  end

  defp maybe_close_issue(_repo, _issue, %{close_issue: false}), do: :ok

  defp maybe_close_issue(repo, issue, _finalizer) do
    case CLI.run([
           "issue",
           "close",
           Integer.to_string(issue.number),
           "--repo",
           CLI.assert_repo!(repo)
         ]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("issue close failed for ##{issue.number}: #{inspect(reason)}")
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Workspace validation
  # ---------------------------------------------------------------------------

  defp ensure_git_repo(workspace) do
    if File.dir?(Path.join(workspace, ".git")) do
      :ok
    else
      {:error, {:not_a_git_repo, workspace}}
    end
  end

  defp ensure_on_expected_branch(workspace, expected) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true) do
      {output, 0} ->
        actual = String.trim(output)

        if actual == expected do
          :ok
        else
          {:error, {:wrong_branch, %{expected: expected, actual: actual}}}
        end

      {output, status} ->
        {:error, {:git_failed, status, Redaction.redact(output)}}
    end
  end

  defp detect_changes(workspace, branch) do
    {dirty_output, dirty_status} =
      System.cmd("git", ["-C", workspace, "status", "--porcelain"], stderr_to_stdout: true)

    if dirty_status != 0 do
      {:error, {:git_status_failed, Redaction.redact(dirty_output)}}
    else
      uncommitted = dirty_output |> String.trim() |> (&(&1 != "")).()

      commits =
        case count_commits_ahead(workspace, branch) do
          {:ok, count} -> count
          _ -> 0
        end

      {:ok, %{uncommitted: uncommitted, commits: commits}}
    end
  end

  defp count_commits_ahead(workspace, branch) do
    base = resolve_default_base(workspace)

    case System.cmd("git", ["-C", workspace, "rev-list", "--count", "#{base}..#{branch}"], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {n, _} -> {:ok, n}
          _ -> {:ok, 0}
        end

      _ ->
        {:ok, 0}
    end
  end

  # Resolve the default branch reference once per call. Tries, in order:
  #
  # 1. `git symbolic-ref refs/remotes/origin/HEAD` (works when the local
  #    clone has a tracking HEAD set on origin)
  # 2. `gh api repos/<repo>` `.default_branch`
  # 3. `origin/main` (GitHub's modern default)
  #
  # Repos using `master`, `trunk`, or any custom default branch get the
  # right base via 1 or 2, so the finalizer no longer falsely reports
  # "no commits produced" on non-`main` repositories.
  defp resolve_default_base(workspace) do
    with :error <- resolve_via_symbolic_ref(workspace),
         :error <- resolve_via_gh_api() do
      "origin/main"
    else
      {:ok, base} -> base
    end
  end

  defp resolve_via_symbolic_ref(workspace) do
    case System.cmd("git", ["-C", workspace, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], stderr_to_stdout: true) do
      {output, 0} ->
        case String.trim(output) do
          "refs/remotes/" <> rest -> {:ok, rest}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp resolve_via_gh_api do
    repo = Config.settings!().tracker.repo

    if is_binary(repo) do
      case CLI.run(["api", "repos/#{CLI.assert_repo!(repo)}", "--jq", ".default_branch"]) do
        {:ok, output} ->
          case String.trim(output) do
            "" -> :error
            branch -> {:ok, "origin/#{branch}"}
          end

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp maybe_auto_commit(_workspace, %{uncommitted: false} = state, _number, _finalizer), do: {:ok, state}

  defp maybe_auto_commit(_workspace, state, _number, %{auto_commit_uncommitted: false}), do: {:ok, state}

  defp maybe_auto_commit(workspace, state, number, _finalizer) do
    with {_, 0} <- System.cmd("git", ["-C", workspace, "add", "-A"], stderr_to_stdout: true),
         {_, 0} <-
           System.cmd("git", ["-C", workspace, "commit", "-m", "symphony: implement issue ##{number}"], stderr_to_stdout: true) do
      {:ok, %{state | uncommitted: false, commits: state.commits + 1}}
    else
      {output, status} -> {:error, {:auto_commit_failed, status, Redaction.redact(output)}}
    end
  end

  # ---------------------------------------------------------------------------
  # Push, PR, comment
  # ---------------------------------------------------------------------------

  defp maybe_push_branch(_workspace, _branch, %{push_branch: false}), do: :ok

  defp maybe_push_branch(workspace, branch, _finalizer) do
    case System.cmd("git", ["-C", workspace, "push", "--set-upstream", "origin", branch], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_push_failed, status, Redaction.redact(output)}}
    end
  end

  defp maybe_open_or_update_pr(_repo, _issue, _run_id, _summary, %{open_pr: false}), do: {:ok, nil}

  # credo:disable-for-next-line
  defp maybe_open_or_update_pr(repo, issue, run_id, summary, _finalizer) do
    title = "Symphony: #{issue.title}"
    body = pr_body(issue, run_id, summary)
    repo = CLI.assert_repo!(repo)

    case existing_pr(repo, issue.branch_name) do
      {:ok, %{"number" => number, "url" => url}} when is_integer(number) ->
        case CLI.run([
               "pr",
               "edit",
               Integer.to_string(number),
               "--repo",
               repo,
               "--title",
               title,
               "--body",
               body
             ]) do
          {:ok, output} -> {:ok, first_url(output) || url || ""}
          {:error, reason} -> {:error, reason}
        end

      {:ok, nil} ->
        case CLI.run([
               "pr",
               "create",
               "--repo",
               repo,
               "--head",
               issue.branch_name,
               "--title",
               title,
               "--body",
               body
             ]) do
          {:ok, output} -> {:ok, output |> String.trim() |> first_url() || ""}
          {:error, {:gh_exit, _status, output}} -> {:error, {:pr_create_failed, output}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Detect an existing PR via `gh pr list --head <branch>`. This is more
  # robust than string-matching `gh pr create` error output, which varies
  # across `gh` versions and locales.
  defp existing_pr(repo, branch) do
    case CLI.run([
           "pr",
           "list",
           "--repo",
           repo,
           "--head",
           branch,
           "--state",
           "all",
           "--json",
           "number,url",
           "--limit",
           "1"
         ]) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, [pr | _]} when is_map(pr) -> {:ok, pr}
          {:ok, _} -> {:ok, nil}
          {:error, reason} -> {:error, {:gh_decode_error, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp first_url(text) when is_binary(text) do
    case Regex.run(~r{https?://[^\s]+}, text) do
      [url] -> url
      _ -> nil
    end
  end

  defp pr_body(issue, run_id, summary) do
    """
    Related to ##{issue.number}

    Run ID: #{run_id}
    Branch: #{issue.branch_name}

    Summary
    -------
    #{summary}

    This pull request was prepared by Symphony with GitHub Copilot CLI in
    autopilot mode. Please review the diff before merging.
    """
  end

  defp comment_on_issue(repo, issue, pr_url, summary) do
    body =
      [
        "Symphony run completed.",
        if(pr_url && pr_url != "", do: "PR: #{pr_url}", else: nil),
        "Summary: #{summary}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    case CLI.run([
           "issue",
           "comment",
           Integer.to_string(issue.number),
           "--repo",
           CLI.assert_repo!(repo),
           "--body",
           body
         ]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("issue comment failed for ##{issue.number}: #{inspect(reason)}")
        :ok
    end
  end

  defp mark_failed(repo, issue, tracker, message) do
    case Adapter.transition_to(repo, issue.number, "failed", tracker) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("transition_to failed for ##{issue.number}: #{inspect(reason)}")
    end

    body = "Symphony run failed: #{message}\n\nLabel `#{tracker.failed_label}` applied. Remove the label or set `tracker.retry_failed: true` to retry."

    case CLI.run([
           "issue",
           "comment",
           Integer.to_string(issue.number),
           "--repo",
           CLI.assert_repo!(repo),
           "--body",
           body
         ]) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end
end
