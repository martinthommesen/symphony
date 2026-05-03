defmodule SymphonyElixir.GitHub.AdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHub.Adapter
  alias SymphonyElixir.GitHub.Issue

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
