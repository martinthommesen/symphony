defmodule SymphonyElixir.GitHub.AdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHub.Adapter
  alias SymphonyElixir.GitHub.Issue
  alias SymphonyElixir.Workflow

  # Test helpers for the gh-CLI-driven mutation tests below. They
  # configure a tracker schema in WORKFLOW.md (so `repo_setting/0` and
  # `tracker_settings/0` resolve), install a stub `:gh_runner` that
  # captures every argv passed to `gh`, and tear both down on exit.
  defp setup_gh_stub(parent, opts \\ []) do
    repo_value =
      case Keyword.get(opts, :repo, "owner/repo") do
        :unset -> "null"
        nil -> "null"
        value when is_binary(value) -> "\"#{value}\""
      end

    blocked_labels =
      case Keyword.get(opts, :blocked_labels, ["symphony/blocked"]) do
        nil -> "[]"
        [] -> "[]"
        list -> "[" <> Enum.map_join(list, ", ", &"\"#{&1}\"") <> "]"
      end

    workflow_path =
      Path.join(System.tmp_dir!(), "symphony-gh-adapter-#{System.unique_integer([:positive])}.md")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: github
      repo: #{repo_value}
      active_labels: ["symphony"]
      blocked_labels: #{blocked_labels}
      running_label: "symphony/running"
      review_label: "symphony/review"
      done_label: "symphony/done"
      failed_label: "symphony/failed"
    polling:
      interval_ms: 30000
    workspace:
      root: "#{Path.join(System.tmp_dir!(), "symphony_workspaces_test")}"
    ---
    Test prompt
    """)

    previous_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(workflow_path)

    if Process.whereis(SymphonyElixir.WorkflowStore),
      do: SymphonyElixir.WorkflowStore.force_reload()

    runner = fn args, opts ->
      send(parent, {:gh_called, args, opts})

      response = Keyword.get(opts, :test_response)

      response ||
        case Process.get(:gh_response) do
          nil -> {"", 0}
          fun when is_function(fun, 1) -> fun.(args)
          {body, status} -> {body, status}
        end
    end

    previous_runner = Application.get_env(:symphony_elixir, :gh_runner)
    Application.put_env(:symphony_elixir, :gh_runner, runner)

    ExUnit.Callbacks.on_exit(fn ->
      if previous_runner do
        Application.put_env(:symphony_elixir, :gh_runner, previous_runner)
      else
        Application.delete_env(:symphony_elixir, :gh_runner)
      end

      File.rm(workflow_path)
      Workflow.set_workflow_file_path(previous_path)

      if Process.whereis(SymphonyElixir.WorkflowStore),
        do: SymphonyElixir.WorkflowStore.force_reload()
    end)

    :ok
  end

  defp tracker_settings(overrides \\ %{}) do
    base = %{
      kind: "github",
      repo: "owner/repo",
      active_labels: ["symphony"],
      blocked_labels: ["symphony/blocked"],
      running_label: "symphony/running",
      done_label: "symphony/done",
      failed_label: "symphony/failed",
      review_label: "symphony/review",
      retry_failed: false
    }

    Map.merge(base, overrides)
  end

  defp issue(state, labels) do
    %Issue{
      number: 1,
      identifier: "#1",
      title: "t",
      description: "",
      state: state,
      labels: labels,
      assignees: [],
      branch_name: "symphony/issue-1"
    }
  end

  describe "eligible?/2" do
    test "open issue with active label is eligible" do
      assert Adapter.eligible?(issue("open", ["symphony"]), tracker_settings())
    end

    test "closed issues are not eligible" do
      refute Adapter.eligible?(issue("closed", ["symphony"]), tracker_settings())
    end

    test "issues without an active label are not eligible" do
      refute Adapter.eligible?(issue("open", ["random"]), tracker_settings())
    end

    test "issues with a blocked label are not eligible" do
      refute Adapter.eligible?(issue("open", ["symphony", "symphony/blocked"]), tracker_settings())
    end

    test "issues with the running label are not eligible (cross-instance lock)" do
      refute Adapter.eligible?(issue("open", ["symphony", "symphony/running"]), tracker_settings())
    end

    test "issues with the review label are not eligible" do
      refute Adapter.eligible?(issue("open", ["symphony", "symphony/review"]), tracker_settings())
    end

    test "issues with the done label are not eligible" do
      refute Adapter.eligible?(issue("open", ["symphony", "symphony/done"]), tracker_settings())
    end

    test "issues with the failed label are not eligible by default" do
      refute Adapter.eligible?(issue("open", ["symphony", "symphony/failed"]), tracker_settings())
    end

    test "issues with the failed label are eligible when retry_failed is true" do
      assert Adapter.eligible?(issue("open", ["symphony", "symphony/failed"]), tracker_settings(%{retry_failed: true}))
    end

    test "empty active_labels disables label gating instead of rejecting all issues" do
      assert Adapter.eligible?(issue("open", []), tracker_settings(%{active_labels: []}))
      assert Adapter.eligible?(issue("open", ["random"]), tracker_settings(%{active_labels: []}))
      refute Adapter.eligible?(issue("closed", []), tracker_settings(%{active_labels: []}))
      refute Adapter.eligible?(issue("open", ["symphony/blocked"]), tracker_settings(%{active_labels: []}))
    end
  end

  describe "label_state/2" do
    test "running label takes precedence" do
      assert Adapter.label_state(issue("open", ["symphony", "symphony/running"]), tracker_settings()) == "running"
    end

    test "review wins over done" do
      assert Adapter.label_state(issue("open", ["symphony", "symphony/review", "symphony/done"]), tracker_settings()) ==
               "review"
    end

    test "blocked is detected from blocked_labels" do
      assert Adapter.label_state(issue("open", ["symphony", "symphony/blocked"]), tracker_settings()) == "blocked"
    end

    test "closed state always wins" do
      assert Adapter.label_state(issue("closed", ["symphony", "symphony/running"]), tracker_settings()) == "closed"
    end

    test "default open state" do
      assert Adapter.label_state(issue("open", ["symphony"]), tracker_settings()) == "open"
    end
  end

  describe "block_issue/1" do
    test "adds the first configured blocked label and shells out to gh" do
      :ok = setup_gh_stub(self())
      Process.put(:gh_response, {"", 0})

      assert :ok = Adapter.block_issue("42")

      assert_receive {:gh_called, args, _opts}
      assert "issue" in args
      assert "edit" in args
      assert "42" in args
      assert "--add-label" in args
      assert "symphony/blocked" in args
    end

    test "returns :unsupported when no blocked labels are configured" do
      :ok = setup_gh_stub(self(), blocked_labels: [])
      assert {:error, :unsupported} = Adapter.block_issue("42")
      refute_receive {:gh_called, _args, _opts}, 50
    end

    test "returns :invalid_issue_id for non-numeric input" do
      :ok = setup_gh_stub(self())
      assert {:error, {:invalid_issue_id, "GH-not-a-number"}} = Adapter.block_issue("GH-not-a-number")
      refute_receive {:gh_called, _args, _opts}, 50
    end

    test "propagates :gh_timeout from the CLI layer" do
      :ok = setup_gh_stub(self())

      Process.put(:gh_response, fn _args ->
        Process.sleep(20)
        {"", 0}
      end)

      previous_timeout = Application.get_env(:symphony_elixir, :gh_cli_timeout_ms)
      Application.put_env(:symphony_elixir, :gh_cli_timeout_ms, 5)

      try do
        assert {:error, :gh_timeout} = Adapter.block_issue("42")
      after
        if previous_timeout do
          Application.put_env(:symphony_elixir, :gh_cli_timeout_ms, previous_timeout)
        else
          Application.delete_env(:symphony_elixir, :gh_cli_timeout_ms)
        end
      end
    end
  end

  describe "unblock_issue/1" do
    test "removes every configured blocked label" do
      :ok = setup_gh_stub(self(), blocked_labels: ["symphony/blocked", "needs-info"])
      Process.put(:gh_response, {"", 0})

      assert :ok = Adapter.unblock_issue("42")

      assert_receive {:gh_called, args, _opts}
      assert "--remove-label" in args
      assert "symphony/blocked" in args
      assert "needs-info" in args
    end

    test "returns :unsupported when no blocked labels are configured" do
      :ok = setup_gh_stub(self(), blocked_labels: [])
      assert {:error, :unsupported} = Adapter.unblock_issue("42")
    end

    test "returns :invalid_issue_id for non-numeric input" do
      :ok = setup_gh_stub(self())
      assert {:error, {:invalid_issue_id, "x"}} = Adapter.unblock_issue("x")
    end
  end

  describe "mark_for_retry/1" do
    test "removes failed/done/review/running labels in a single gh edit call" do
      :ok = setup_gh_stub(self())
      Process.put(:gh_response, {"", 0})

      assert :ok = Adapter.mark_for_retry("42")

      assert_receive {:gh_called, args, _opts}
      assert "--remove-label" in args
      assert "symphony/running" in args
      assert "symphony/review" in args
      assert "symphony/failed" in args
      assert "symphony/done" in args
    end

    test "returns :invalid_issue_id for non-numeric input" do
      :ok = setup_gh_stub(self())
      assert {:error, {:invalid_issue_id, "abc"}} = Adapter.mark_for_retry("abc")
    end
  end

  describe "list_managed_issues/0" do
    test "returns :missing_github_repo when no repo is configured" do
      # `setup_gh_stub` sets an empty repo when blocked_labels are
      # explicitly disabled — repurpose that branch to test the early
      # `repo_setting()` failure path.
      :ok = setup_gh_stub(self(), repo: :unset)
      assert {:error, :missing_github_repo} = Adapter.list_managed_issues()
    end
  end

  describe "transition_delta_for_test/2" do
    test "review removes both running and failed labels so retries don't double-tag" do
      tracker = tracker_settings()
      {add, remove} = Adapter.transition_delta_for_test("review", tracker)
      assert add == [tracker.review_label]
      assert tracker.running_label in remove
      assert tracker.failed_label in remove
    end

    test "done removes both running and failed labels" do
      tracker = tracker_settings()
      {_add, remove} = Adapter.transition_delta_for_test("done", tracker)
      assert tracker.running_label in remove
      assert tracker.failed_label in remove
    end

    test "running adds the running label without removals" do
      tracker = tracker_settings()
      {add, remove} = Adapter.transition_delta_for_test("running", tracker)
      assert add == [tracker.running_label]
      assert remove == []
    end

    test "failed swaps running for failed" do
      tracker = tracker_settings()
      {add, remove} = Adapter.transition_delta_for_test("failed", tracker)
      assert add == [tracker.failed_label]
      assert remove == [tracker.running_label]
    end
  end
end
