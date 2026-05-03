defmodule SymphonyElixir.GitHubConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  test "github tracker defaults parse cleanly" do
    config = %{
      "tracker" => %{"kind" => "github", "repo" => "owner/name"},
      "copilot" => %{"command" => "copilot"}
    }

    assert {:ok, settings} = Schema.parse(config)
    assert settings.tracker.kind == "github"
    assert settings.tracker.repo == "owner/name"
    assert settings.tracker.active_labels == ["symphony"]
    assert settings.tracker.blocked_labels == ["symphony/blocked"]
    assert settings.tracker.running_label == "symphony/running"
    assert settings.tracker.review_label == "symphony/review"
    assert settings.tracker.failed_label == "symphony/failed"
    assert settings.tracker.done_label == "symphony/done"
    assert settings.tracker.retry_failed == false
    # Defaults must match the github-adapter-derived state strings so
    # orchestrator dispatch (active_states) and continuation (terminal_states)
    # actually fire under the generated default config.
    assert settings.tracker.active_states == ["open"]
    assert settings.tracker.terminal_states == ["closed"]
  end

  test "copilot defaults are autopilot/yolo/json with sane timeouts" do
    config = %{"tracker" => %{"kind" => "github", "repo" => "owner/name"}}

    assert {:ok, settings} = Schema.parse(config)
    assert settings.copilot.command == "copilot"
    assert settings.copilot.mode == "autopilot"
    assert settings.copilot.permission_mode == "yolo"
    assert settings.copilot.output_format == "json"
    assert settings.copilot.max_autopilot_continues == 10
    assert settings.copilot.turn_timeout_ms == 3_600_000
    assert settings.copilot.read_timeout_ms == 5_000
    assert settings.copilot.stall_timeout_ms == 300_000

    assert "shell(git push)" in settings.copilot.deny_tools
    assert "shell(gh pr)" in settings.copilot.deny_tools
    assert "shell(gh issue)" in settings.copilot.deny_tools
  end

  test "finalizer defaults preserve no auto-merge / no auto-close" do
    config = %{}

    assert {:ok, settings} = Schema.parse(config)
    assert settings.finalizer.auto_commit_uncommitted == true
    assert settings.finalizer.push_branch == true
    assert settings.finalizer.open_pr == true
    assert settings.finalizer.close_issue == false
    assert settings.finalizer.merge_pr == false
  end

  test "invalid copilot mode is rejected" do
    config = %{"copilot" => %{"command" => "copilot", "mode" => "nope"}}

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
    assert message =~ "copilot.mode"
  end

  test "invalid permission_mode is rejected" do
    config = %{"copilot" => %{"command" => "copilot", "permission_mode" => "lol"}}

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
    assert message =~ "copilot.permission_mode"
  end
end
