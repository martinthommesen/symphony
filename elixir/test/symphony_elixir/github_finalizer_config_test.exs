defmodule SymphonyElixir.GitHubFinalizerConfigTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.GitHub.Finalizer
  alias SymphonyElixir.GitHub.Issue, as: GhIssue

  setup do
    original_runner = Application.get_env(:symphony_elixir, :gh_runner)

    on_exit(fn ->
      if is_nil(original_runner) do
        Application.delete_env(:symphony_elixir, :gh_runner)
      else
        Application.put_env(:symphony_elixir, :gh_runner, original_runner)
      end
    end)

    :ok
  end

  test "symphony commit strategy creates commits and configured draft PRs" do
    workspace = git_workspace!()
    File.write!(Path.join(workspace, "feature.txt"), "implemented\n")
    write_github_workflow!(workspace, commit_strategy: "symphony_commits_all")

    {:ok, gh_calls} = Agent.start_link(fn -> [] end)

    Application.put_env(:symphony_elixir, :gh_runner, fn args, _opts ->
      Agent.update(gh_calls, &(&1 ++ [args]))

      case args do
        ["api", "repos/owner/name", "--jq", ".default_branch"] ->
          {"main\n", 0}

        ["pr", "list" | _] ->
          {"[]", 0}

        ["pr", "create" | _] ->
          {"https://github.com/owner/name/pull/77\n", 0}

        ["issue", "edit" | _] ->
          {"", 0}

        other ->
          flunk("unexpected gh call: #{inspect(other)}")
      end
    end)

    issue = issue(42, "Add feature")

    assert {:ok, %{status: :success, pr_url: "https://github.com/owner/name/pull/77"}} =
             Finalizer.finalize(issue, workspace, "run-42", "Done")

    assert {"symphony: #42 Add feature\n", 0} = System.cmd("git", ["-C", workspace, "show", "-s", "--format=%s"])
    assert {"Symphony Bot <symphony@example.com>\n", 0} = System.cmd("git", ["-C", workspace, "show", "-s", "--format=%an <%ae>"])

    calls = Agent.get(gh_calls, & &1)
    create_args = Enum.find(calls, &match?(["pr", "create" | _], &1))

    assert "--draft" in create_args
    assert Enum.member?(create_args, "Symphony: Add feature via acpx")
    assert Enum.member?(create_args, "Run run-42 for #42 on symphony/issue-42")
    refute Enum.any?(calls, &match?(["issue", "comment" | _], &1))
    assert Enum.any?(calls, &match?(["issue", "edit", "42", "--repo", "owner/name", "--add-label", "symphony/review"], &1))
  end

  test "no_commit strategy honors fail_if_no_commit without creating a PR" do
    workspace = git_workspace!()
    write_github_workflow!(workspace, commit_strategy: "no_commit", fail_if_no_commit: true)

    {:ok, gh_calls} = Agent.start_link(fn -> [] end)

    Application.put_env(:symphony_elixir, :gh_runner, fn args, _opts ->
      Agent.update(gh_calls, &(&1 ++ [args]))

      case args do
        ["api", "repos/owner/name", "--jq", ".default_branch"] -> {"main\n", 0}
        ["issue", "edit" | _] -> {"", 0}
        ["issue", "comment" | _] -> {"", 0}
        other -> flunk("unexpected gh call: #{inspect(other)}")
      end
    end)

    issue = issue(43, "No commit")

    assert {:ok, %{status: :failed, reason: :no_commits, pr_url: nil}} =
             Finalizer.finalize(issue, workspace, "run-43", "No changes")

    calls = Agent.get(gh_calls, & &1)
    refute Enum.any?(calls, &match?(["pr", _ | _], &1))
    assert Enum.any?(calls, &match?(["issue", "edit", "43", "--repo", "owner/name", "--add-label", "symphony/failed"], &1))
  end

  defp git_workspace! do
    workspace = Path.join(System.tmp_dir!(), "symphony-finalizer-#{System.unique_integer([:positive])}")
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)

    assert {_, 0} = System.cmd("git", ["init", "--initial-branch", "main"], cd: workspace, stderr_to_stdout: true)
    assert {"", 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace, stderr_to_stdout: true)
    assert {"", 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace, stderr_to_stdout: true)
    File.write!(Path.join(workspace, "README.md"), "# Test\n")
    assert {"", 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["commit", "-m", "initial"], cd: workspace, stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["checkout", "-b", "symphony/issue-42"], cd: workspace, stderr_to_stdout: true)

    workspace
  end

  defp write_github_workflow!(workspace, opts) do
    commit_strategy = Keyword.fetch!(opts, :commit_strategy)
    fail_if_no_commit = Keyword.get(opts, :fail_if_no_commit, false)
    workflow_file = Application.fetch_env!(:symphony_elixir, :workflow_file_path)
    issue_number_var = "{{issue_number}}"

    File.write!(workflow_file, """
    ---
    tracker:
      kind: github
      repo: owner/name
    workspace:
      root: #{inspect(workspace)}
    finalizer:
      push_branch: false
      open_pr: true
      close_issue: false
    commit:
      enabled: true
      strategy: #{commit_strategy}
      include_untracked: true
      message_template: "symphony: ##{issue_number_var} {{title}}"
      author_name: Symphony Bot
      author_email: symphony@example.com
    pr:
      enabled: true
      draft: true
      update_existing: true
      title_template: "Symphony: {{title}} via acpx"
      body_template: "Run {{run_id}} for ##{issue_number_var} on {{branch}}"
      comment_on_issue: false
    validation:
      fail_if_no_commit: #{fail_if_no_commit}
    ---
    You are an agent for this repository.
    """)

    WorkflowStore.force_reload()
  end

  defp issue(number, title) do
    %GhIssue{
      id: "I_#{number}",
      identifier: "##{number}",
      number: number,
      title: title,
      description: "Body",
      state: "open",
      branch_name: "symphony/issue-42",
      labels: ["symphony", "symphony/agent/codex"]
    }
  end
end
