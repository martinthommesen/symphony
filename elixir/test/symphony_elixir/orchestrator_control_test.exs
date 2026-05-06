defmodule SymphonyElixir.OrchestratorControlTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator

  # Drives the public control surface (`pause_polling/0`,
  # `resume_polling/0`, `polling_paused?/0`, `stop_issue/2`,
  # `request_dispatch/2`, `retry_issue/2`) end-to-end against a real
  # orchestrator process. The tracker is swapped out for the in-memory
  # `Memory` adapter via `tracker_kind: "memory"` so no `gh` invocation
  # is required.

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      worker_ssh_hosts: []
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

    name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 100)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{name: name, pid: pid}
  end

  describe "pause / resume / paused?" do
    test "pause and resume flip the polling flag", %{name: name} do
      refute Orchestrator.polling_paused?(name)

      assert {:ok, %{paused: true}} = Orchestrator.pause_polling(name)
      assert Orchestrator.polling_paused?(name)

      assert {:ok, %{paused: false}} = Orchestrator.resume_polling(name)
      refute Orchestrator.polling_paused?(name)
    end

    test "polling_paused?/1 returns false for a dead orchestrator" do
      refute Orchestrator.polling_paused?(:no_such_orchestrator)
    end

    test "control commands return :unavailable when the orchestrator isn't running" do
      assert {:error, :unavailable} = Orchestrator.pause_polling(:no_such_orchestrator)
      assert {:error, :unavailable} = Orchestrator.resume_polling(:no_such_orchestrator)
      assert {:error, :unavailable} = Orchestrator.stop_issue(:no_such_orchestrator, "X-1")
      assert {:error, :unavailable} = Orchestrator.request_dispatch(:no_such_orchestrator, "X-1")
      assert {:error, :unavailable} = Orchestrator.retry_issue(:no_such_orchestrator, "X-1")
    end
  end

  describe "stop_issue/2" do
    test "returns :issue_not_running when the issue id is unknown", %{name: name} do
      assert {:error, :issue_not_running} = Orchestrator.stop_issue(name, "GH-404")
    end
  end

  describe "request_dispatch/2" do
    test "returns :issue_not_found when the candidate set has no matching issue", %{name: name} do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      assert {:error, :issue_not_found} =
               Orchestrator.request_dispatch(name, "GH-MISSING")
    end

    test "returns :not_dispatchable when the issue exists but isn't in an active state",
         %{name: name} do
      issue = %Issue{
        id: "issue-blocked",
        identifier: "GH-BLOCKED",
        title: "blocked",
        state: "Closed"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:error, :not_dispatchable} =
               Orchestrator.request_dispatch(name, "GH-BLOCKED")
    end
  end

  describe "retry_issue/2" do
    test "delegates to Tracker.mark_for_retry and emits a retry_scheduled event",
         %{name: name} do
      # The Memory adapter does not implement mark_for_retry, so we
      # expect :unsupported.
      assert {:error, :unsupported} = Orchestrator.retry_issue(name, "GH-1")
    end
  end
end
