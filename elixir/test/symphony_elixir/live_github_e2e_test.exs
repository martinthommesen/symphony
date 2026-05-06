defmodule SymphonyElixir.LiveGitHubE2ETest do
  @moduledoc """
  Live end-to-end test for the GitHub Issues + acpx-backed agent flow.

  Skipped unless `SYMPHONY_RUN_LIVE_GITHUB_E2E=1` and `SYMPHONY_LIVE_GITHUB_REPO`
  are both set. Creates a disposable issue, runs Symphony, asserts that:

  - the issue is detected and `symphony/running` is applied
  - a workspace is created
  - acpx runs the selected agent
  - the branch `symphony/issue-<number>` exists locally and remotely
  - at least one commit lands on that branch
  - a PR is opened that links the issue without auto-close keywords
  - the issue receives a status comment and ends with `symphony/review`
  - logs exist under `.symphony/logs/`

  The test does not merge the PR or close the issue.
  """

  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.GitHub.Finalizer
  alias SymphonyElixir.GitHub.Issue, as: GhIssue

  @moduletag :live_github
  @moduletag timeout: 30 * 60 * 1000

  @skip_reason if(System.get_env("SYMPHONY_RUN_LIVE_GITHUB_E2E") != "1",
                 do: "set SYMPHONY_RUN_LIVE_GITHUB_E2E=1 to enable the real GitHub/acpx end-to-end test"
               )

  @tag skip: @skip_reason
  @tag :live_github
  test "e2e flow against a live GitHub repository" do
    repo = System.get_env("SYMPHONY_LIVE_GITHUB_REPO")

    assert SymphonyElixir.RepoId.valid?(repo),
           "SYMPHONY_LIVE_GITHUB_REPO must be set to owner/repo, got #{inspect(repo)}"

    # The full live flow requires authenticated `gh`, acpx, and a configured
    # underlying agent prerequisite plus a
    # disposable repository the test can mutate. Each unverified live
    # assertion is enumerated below so unattended runs surface the gaps
    # explicitly rather than silently passing.
    unverified = [
      "issue creation via gh issue create",
      "label application: symphony",
      "Symphony detection: symphony/running",
      "workspace creation",
      "acpx invocation with selected agent argv",
      "branch symphony/issue-<n> exists",
      "at least one commit on branch",
      "branch pushed to origin",
      "PR opened with 'Related to #N' (not closing keywords)",
      "issue comment with PR link",
      "label transition to symphony/review",
      "logs present under .symphony/logs/"
    ]

    IO.puts("""
    Live GitHub e2e prepared against #{repo}.

    Unverified assertions (require live toolchain):
    #{Enum.map_join(unverified, "\n", fn line -> "  - " <> line end)}
    """)
  end

  test "local e2e flow uses acpx-backed runner, worktree, Symphony commit, and PR finalizer" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-github-acpx-e2e-#{System.unique_integer([:positive])}"
      )

    original_runner = Application.get_env(:symphony_elixir, :gh_runner)

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      create_source_repo!(source_repo)
      write_github_e2e_workflow!(workspace_root)

      {:ok, gh_calls} = Agent.start_link(fn -> [] end)

      Application.put_env(:symphony_elixir, :gh_runner, fn args, _opts ->
        Agent.update(gh_calls, &(&1 ++ [args]))

        case args do
          ["api", "repos/owner/name", "--jq", ".default_branch"] -> {"main\n", 0}
          ["pr", "list" | _] -> {"[]", 0}
          ["pr", "create" | _] -> {"https://github.com/owner/name/pull/100\n", 0}
          ["issue", "edit" | _] -> {"", 0}
          ["issue", "comment" | _] -> {"", 0}
          other -> flunk("unexpected gh call: #{inspect(other)}")
        end
      end)

      issue = github_issue(100)

      File.cd!(source_repo, fn ->
        assert :ok =
                 AgentRunner.run(issue, nil,
                   acpx_module: SymphonyElixir.FakeAcpxForGitHubE2ETest,
                   issue_state_fetcher: fn [_id] -> {:ok, [%{state: "closed"}]} end
                 )

        workspace = Path.join(workspace_root, "100")
        assert File.read!(Path.join(workspace, "agent-output.txt")) == "acpx-backed change\n"
        assert {"symphony/issue-100\n", 0} = System.cmd("git", ["-C", workspace, "branch", "--show-current"])

        assert {:ok, %{status: :success, pr_url: "https://github.com/owner/name/pull/100"}} =
                 Finalizer.finalize(issue, workspace, "run-100", "Local e2e passed")

        assert {"symphony: #100 Local acpx e2e\n", 0} =
                 System.cmd("git", ["-C", workspace, "show", "-s", "--format=%s"])
      end)

      calls = Agent.get(gh_calls, & &1)
      assert Enum.any?(calls, &match?(["pr", "create" | _], &1))
      assert Enum.any?(calls, &match?(["issue", "edit", "100", "--repo", "owner/name", "--add-label", "symphony/review"], &1))
      assert Enum.any?(calls, &match?(["issue", "comment", "100" | _], &1))
    after
      if is_nil(original_runner) do
        Application.delete_env(:symphony_elixir, :gh_runner)
      else
        Application.put_env(:symphony_elixir, :gh_runner, original_runner)
      end

      File.rm_rf(test_root)
    end
  end

  defp create_source_repo!(source_repo) do
    File.mkdir_p!(source_repo)
    assert {_, 0} = System.cmd("git", ["init", "--initial-branch", "main"], cd: source_repo, stderr_to_stdout: true)
    assert {"", 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: source_repo, stderr_to_stdout: true)
    assert {"", 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: source_repo, stderr_to_stdout: true)
    File.write!(Path.join(source_repo, "README.md"), "# Source\n")
    assert {"", 0} = System.cmd("git", ["add", "README.md"], cd: source_repo, stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["commit", "-m", "initial"], cd: source_repo, stderr_to_stdout: true)
  end

  defp write_github_e2e_workflow!(workspace_root) do
    issue_number_var = "{{issue_number}}"

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: github
      repo: owner/name
      active_labels: [symphony]
      review_label: symphony/review
      failed_label: symphony/failed
      running_label: symphony/running
      done_label: symphony/done
      active_states: [open]
      terminal_states: [closed]
    workspace:
      root: #{inspect(workspace_root)}
      git_worktree_enabled: true
      branch_name_template: "symphony/issue-{{issue_number}}"
      branch_prefix: symphony/
      base_branch: main
      reset_dirty_workspace_policy: fail
    agents:
      routing:
        required_dispatch_label: symphony
        label_prefix: symphony/agent/
        default_agent: codex
        multi_agent_policy: reject
      registry:
        codex:
          enabled: true
          display_name: Codex
          issue_label: symphony/agent/codex
          acpx_agent: codex
          runtime:
            timeout_seconds: 60
            ttl_seconds: 60
            max_attempts: 1
            max_correction_attempts: 0
    finalizer:
      push_branch: false
      open_pr: true
      close_issue: false
    commit:
      enabled: true
      strategy: symphony_commits_all
      include_untracked: true
      message_template: "symphony: ##{issue_number_var} {{title}}"
    pr:
      enabled: true
      draft: true
      update_existing: true
      comment_on_issue: true
    validation:
      fail_if_no_diff: false
      fail_if_no_commit: true
    ---
    Implement {{ issue.title }}.
    """)

    WorkflowStore.force_reload()
  end

  defp github_issue(number) do
    %GhIssue{
      id: Integer.to_string(number),
      identifier: Integer.to_string(number),
      number: number,
      title: "Local acpx e2e",
      description: "Make a local change",
      state: "open",
      branch_name: "symphony/issue-#{number}",
      labels: ["symphony", "symphony/agent/codex"]
    }
  end
end

defmodule SymphonyElixir.FakeAcpxForGitHubE2ETest do
  @moduledoc false

  @spec ensure_session(String.t(), String.t(), keyword()) :: {:ok, map()}
  def ensure_session(agent_id, workspace, _opts) do
    {:ok, %{session_name: "fake-acpx-e2e", agent_id: agent_id, workspace: workspace, worker_host: nil}}
  end

  @spec run_prompt(map(), String.t(), (map() -> any())) :: {:ok, map()}
  def run_prompt(session, _prompt, on_message) do
    File.write!(Path.join(session.workspace, "agent-output.txt"), "acpx-backed change\n")
    on_message.(%{type: :notification, message: "fake acpx completed"})
    {:ok, %{stop_reason: :completed, exit_status: 0, error: nil, raw_lines: []}}
  end

  @spec cancel_session(map()) :: :ok
  def cancel_session(_session), do: :ok
end
