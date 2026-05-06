# credo:disable-for-this-file
defmodule SymphonyElixir.GitHub.Finalizer do
  @moduledoc """
  Owns post-agent GitHub state: branch validation, optional auto-commit,
  branch push, PR create/update, issue comment, and label transition.

  Symphony, not the selected coding agent, performs these operations unless
  configuration explicitly delegates them.
  """

  alias SymphonyElixir.{Config, Git, GitHub.Adapter, GitHub.CLI, Redaction, StructuredLogger}
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
  Run the full finalizer for `issue` after an agent run.

  `run_summary` is a short agent summary. `run_id` is opaque to GitHub but is
  included in the PR body for traceability.
  """
  @spec finalize(GhIssue.t(), Path.t(), String.t(), String.t()) :: {:ok, result()} | {:error, term()}
  def finalize(%GhIssue{} = issue, workspace, run_id, run_summary)
      when is_binary(workspace) and is_binary(run_id) and is_binary(run_summary) do
    settings = Config.settings!()
    finalizer = settings.finalizer
    commit = settings.commit
    pr = settings.pr
    tracker = settings.tracker
    repo = tracker.repo

    with :ok <- ensure_git_repo(workspace),
         :ok <- ensure_on_expected_branch(workspace, issue.branch_name),
         {:ok, change_state} <- detect_changes(workspace, issue.branch_name),
         :ok <- enforce_change_limits(workspace, commit),
         {:ok, change_state} <- maybe_auto_commit(workspace, change_state, issue, commit, finalizer) do
      if change_state.commits == 0 do
        maybe_fail_for_no_commits(repo, issue, tracker, Config.settings!().validation)
      else
        do_publish(repo, issue, workspace, run_id, run_summary, finalizer, tracker, pr)
      end
    else
      {:error, reason} ->
        Logger.error("Finalizer failed for issue #{issue.number}: #{inspect(reason)}")
        log_error(issue, "finalizer_failed", reason)
        mark_failed(repo, issue, tracker, "Finalizer error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_publish(repo, issue, workspace, run_id, run_summary, finalizer, tracker, pr) do
    with :ok <- maybe_push_branch(workspace, issue.branch_name, finalizer),
         {:ok, pr_url} <- maybe_open_or_update_pr(repo, issue, run_id, run_summary, finalizer, pr) do
      :ok = maybe_comment_on_issue(repo, issue, pr_url, run_summary, pr)
      :ok = Adapter.transition_to(repo, issue.number, "review", tracker)
      :ok = maybe_close_issue(repo, issue, pr, finalizer)

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

  defp maybe_close_issue(_repo, _issue, _pr, %{close_issue: false}), do: :ok
  defp maybe_close_issue(_repo, _issue, %{close_issue_on_merge: false}, %{close_issue: false}), do: :ok

  defp maybe_close_issue(repo, issue, _pr, _finalizer) do
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
    if File.exists?(Path.join(workspace, ".git")) do
      :ok
    else
      {:error, {:not_a_git_repo, workspace}}
    end
  end

  defp ensure_on_expected_branch(workspace, expected) do
    case Git.cmd(["-C", workspace, "rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true) do
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
      Git.cmd(["-C", workspace, "status", "--porcelain"], stderr_to_stdout: true)

    if dirty_status != 0 do
      {:error, {:git_status_failed, Redaction.redact(dirty_output)}}
    else
      uncommitted = dirty_output |> String.trim() |> (&(&1 != "")).()

      commits = count_commits_ahead(workspace, branch)

      {:ok, %{uncommitted: uncommitted, commits: commits}}
    end
  end

  defp count_commits_ahead(workspace, branch) do
    base = resolve_default_base(workspace)

    case Git.cmd(["-C", workspace, "rev-list", "--count", "#{base}..#{branch}"], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {n, _} -> n
          _ -> 0
        end

      _ ->
        0
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
    case Git.cmd(["-C", workspace, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], stderr_to_stdout: true) do
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

    with true <- is_binary(repo),
         {:ok, output} <- CLI.run(["api", "repos/#{CLI.assert_repo!(repo)}", "--jq", ".default_branch"]),
         branch <- String.trim(output),
         true <- branch != "" do
      {:ok, "origin/#{branch}"}
    else
      _ -> :error
    end
  end

  defp enforce_change_limits(_workspace, %{max_changed_files: nil, max_diff_size: nil}), do: :ok

  defp enforce_change_limits(workspace, commit) do
    case enforce_changed_file_limit(workspace, commit.max_changed_files) do
      :ok -> enforce_diff_size_limit(workspace, commit.max_diff_size)
      {:error, _reason} = error -> error
    end
  end

  defp enforce_changed_file_limit(_workspace, nil), do: :ok

  defp enforce_changed_file_limit(workspace, max_changed_files) when is_integer(max_changed_files) do
    case Git.cmd(["-C", workspace, "status", "--porcelain"], stderr_to_stdout: true) do
      {output, 0} ->
        count = output |> String.split("\n", trim: true) |> length()

        if count <= max_changed_files do
          :ok
        else
          {:error, {:too_many_changed_files, count, max_changed_files}}
        end

      {output, status} ->
        {:error, {:git_status_failed, status, Redaction.redact(output)}}
    end
  end

  defp enforce_diff_size_limit(_workspace, nil), do: :ok

  defp enforce_diff_size_limit(workspace, max_diff_size) when is_integer(max_diff_size) do
    case Git.cmd(["-C", workspace, "diff", "--stat", "--patch"], stderr_to_stdout: true) do
      {output, 0} ->
        size = byte_size(output)

        if size <= max_diff_size do
          :ok
        else
          {:error, {:diff_too_large, size, max_diff_size}}
        end

      {output, status} ->
        {:error, {:git_diff_failed, status, Redaction.redact(output)}}
    end
  end

  defp maybe_auto_commit(_workspace, %{uncommitted: false} = state, _issue, _commit, _finalizer), do: {:ok, state}

  defp maybe_auto_commit(_workspace, state, _issue, %{enabled: false}, _finalizer), do: {:ok, state}

  defp maybe_auto_commit(_workspace, state, _issue, %{strategy: strategy}, _finalizer)
       when strategy in ["agent_commits", "no_commit"],
       do: {:ok, state}

  defp maybe_auto_commit(_workspace, state, _issue, _commit, %{auto_commit_uncommitted: false}), do: {:ok, state}

  defp maybe_auto_commit(workspace, state, issue, commit, _finalizer) do
    add_args = if commit.include_untracked, do: ["add", "-A"], else: ["add", "-u"]
    message = render_commit_message(commit.message_template, issue)

    with {_, 0} <- Git.cmd(["-C", workspace] ++ add_args, stderr_to_stdout: true),
         :ok <- maybe_set_commit_author(workspace, commit),
         :ok <- maybe_run_pre_commit_hooks(workspace, commit),
         {_, 0} <- Git.cmd(commit_args(workspace, message, commit), stderr_to_stdout: true) do
      {:ok, %{state | uncommitted: false, commits: state.commits + 1}}
    else
      {:error, reason} -> {:error, reason}
      {output, status} -> {:error, {:auto_commit_failed, status, Redaction.redact(output)}}
    end
  end

  defp render_commit_message(nil, issue), do: "symphony: implement issue ##{issue.number}"

  defp render_commit_message(template, issue) when is_binary(template) do
    template
    |> String.replace("{{issue_number}}", Integer.to_string(issue.number))
    |> String.replace("{{number}}", Integer.to_string(issue.number))
    |> String.replace("{{title}}", issue.title || "")
    |> String.replace("{{branch}}", issue.branch_name || "")
  end

  defp maybe_set_commit_author(_workspace, %{author_name: nil, author_email: nil}), do: :ok

  defp maybe_set_commit_author(workspace, commit) do
    case maybe_git_config(workspace, "user.name", commit.author_name) do
      :ok -> maybe_git_config(workspace, "user.email", commit.author_email)
      {:error, _reason} = error -> error
    end
  end

  defp maybe_git_config(_workspace, _key, nil), do: :ok

  defp maybe_git_config(workspace, key, value) do
    case Git.cmd(["-C", workspace, "config", key, value], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_config_failed, status, Redaction.redact(output)}}
    end
  end

  defp maybe_run_pre_commit_hooks(_workspace, %{run_pre_commit_hooks: false}), do: :ok

  defp maybe_run_pre_commit_hooks(workspace, _commit) do
    case System.cmd("sh", ["-lc", "pre-commit run --all-files"], cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:pre_commit_failed, status, Redaction.redact(output)}}
    end
  end

  defp commit_args(workspace, message, commit) do
    args = ["-C", workspace, "commit", "-m", message]
    args = if commit.sign_commits, do: args ++ ["--gpg-sign"], else: args
    if commit.allow_empty, do: args ++ ["--allow-empty"], else: args
  end

  defp maybe_fail_for_no_commits(repo, issue, tracker, validation) do
    if validation.fail_if_no_commit do
      mark_failed(repo, issue, tracker, "No commits produced by agent run.")

      {:ok,
       %{
         status: :failed,
         pr_url: nil,
         branch: issue.branch_name,
         summary: "No commits produced",
         reason: :no_commits
       }}
    else
      {:ok,
       %{
         status: :success,
         pr_url: nil,
         branch: issue.branch_name,
         summary: "No commits produced",
         reason: :no_commits
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Push, PR, comment
  # ---------------------------------------------------------------------------

  defp maybe_push_branch(_workspace, _branch, %{push_branch: false}), do: :ok

  defp maybe_push_branch(workspace, branch, _finalizer) do
    case Git.cmd(["-C", workspace, "push", "--set-upstream", "origin", branch], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_push_failed, status, Redaction.redact(output)}}
    end
  end

  defp maybe_open_or_update_pr(_repo, _issue, _run_id, _summary, _finalizer, %{enabled: false}), do: {:ok, nil}
  defp maybe_open_or_update_pr(_repo, _issue, _run_id, _summary, %{open_pr: false}, _pr), do: {:ok, nil}

  defp maybe_open_or_update_pr(repo, issue, run_id, summary, _finalizer, pr) do
    title = render_template(pr.title_template || "Symphony: {{title}}", issue, run_id, summary)
    body = render_template(pr.body_template || default_pr_body_template(pr), issue, run_id, summary)
    repo = CLI.assert_repo!(repo)

    case existing_pr(repo, issue.branch_name) do
      {:ok, %{"number" => number, "url" => url}} when is_integer(number) and pr.update_existing ->
        with {:ok, url} <- edit_existing_pr(repo, number, title, body, url),
             :ok <- apply_pr_metadata(repo, number, pr) do
          {:ok, url}
        end

      {:ok, %{"number" => _number, "url" => url}} ->
        {:ok, url || ""}

      {:ok, nil} ->
        create_new_pr(repo, issue.branch_name, title, body, pr)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp edit_existing_pr(repo, number, title, body, fallback_url) do
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
      {:ok, output} -> {:ok, first_url(output) || fallback_url || ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_new_pr(repo, branch_name, title, body, pr) do
    args = [
      "pr",
      "create",
      "--repo",
      repo,
      "--head",
      branch_name,
      "--title",
      title,
      "--body",
      body
    ]

    args = if pr.draft, do: args ++ ["--draft"], else: args

    case CLI.run(args) do
      {:ok, output} ->
        url = output |> String.trim() |> first_url() || ""

        with {:ok, number} <- pr_number_from_url(url),
             :ok <- apply_pr_metadata(repo, number, pr) do
          {:ok, url}
        else
          :no_url -> {:ok, url}
        end

      {:error, {:gh_exit, _status, output}} ->
        {:error, {:pr_create_failed, output}}
    end
  end

  defp apply_pr_metadata(_repo, _number, %{reviewers: [], team_reviewers: [], assignees: [], labels: [], milestone: nil, request_review: false}), do: :ok

  defp apply_pr_metadata(repo, number, pr) do
    args =
      ["pr", "edit", Integer.to_string(number), "--repo", repo]
      |> append_multi("--add-reviewer", pr.reviewers)
      |> append_multi("--add-assignee", pr.assignees)
      |> append_multi("--add-label", pr.labels)
      |> append_optional("--milestone", pr.milestone)

    case CLI.run(args) do
      {:ok, _} -> maybe_request_team_reviewers(repo, number, pr)
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_request_team_reviewers(_repo, _number, %{team_reviewers: []}), do: :ok

  defp maybe_request_team_reviewers(repo, number, pr) do
    args =
      ["pr", "edit", Integer.to_string(number), "--repo", repo]
      |> append_multi("--add-reviewer", pr.team_reviewers)

    case CLI.run(args) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_multi(args, _flag, []), do: args
  defp append_multi(args, flag, values), do: args ++ Enum.flat_map(values, &[flag, &1])

  defp append_optional(args, _flag, nil), do: args
  defp append_optional(args, _flag, ""), do: args
  defp append_optional(args, flag, value), do: args ++ [flag, value]

  defp pr_number_from_url(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)}, url, capture: :all_but_first) do
      [number] -> {:ok, String.to_integer(number)}
      _ -> :no_url
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

  defp default_pr_body_template(pr) do
    issue_line = if pr.include_issue_link, do: "Related to #" <> "{{issue_number}}\n\n", else: ""

    issue_line <>
      """
      Run ID: {{run_id}}
      Branch: {{branch}}

      Summary
      -------
      {{summary}}

      This pull request was prepared by Symphony after an acpx-backed agent run.
      Please review the diff before merging.
      """
  end

  defp render_template(template, issue, run_id, summary) do
    template
    |> String.replace("{{issue_number}}", Integer.to_string(issue.number))
    |> String.replace("{{number}}", Integer.to_string(issue.number))
    |> String.replace("{{title}}", issue.title || "")
    |> String.replace("{{branch}}", issue.branch_name || "")
    |> String.replace("{{run_id}}", run_id)
    |> String.replace("{{summary}}", summary)
  end

  defp maybe_comment_on_issue(_repo, _issue, _pr_url, _summary, %{comment_on_issue: false}), do: :ok

  defp maybe_comment_on_issue(repo, issue, pr_url, summary, _pr) do
    comment_on_issue(repo, issue, pr_url, summary)
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
    log_error(issue, "github_issue_failed", message)

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

  defp log_error(issue, event_type, reason) do
    StructuredLogger.log_named("errors", %{
      event_type: event_type,
      severity: "error",
      issue_id: issue.id,
      issue_number: issue.number,
      branch_name: issue.branch_name,
      message: inspect(reason),
      payload: %{
        reason: inspect(reason),
        issue_labels: issue.labels
      }
    })
  end
end
