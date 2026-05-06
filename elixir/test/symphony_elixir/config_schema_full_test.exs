defmodule SymphonyElixir.Config.SchemaFullTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  test "parses full workflow config with all sections" do
    config = %{
      "tracker" => %{
        "kind" => "github",
        "repo" => "owner/repo",
        "active_labels" => ["symphony"],
        "blocked_labels" => ["blocked"],
        "running_label" => "running",
        "review_label" => "review",
        "done_label" => "done",
        "failed_label" => "failed",
        "retry_failed" => true
      },
      "polling" => %{
        "interval_ms" => 5000,
        "github_state_refresh_interval_ms" => 10_000,
        "max_issues_per_poll" => 50
      },
      "workspace" => %{
        "root" => "/tmp/symphony",
        "prefix" => "issue-",
        "ttl_hours" => 24,
        "hooks" => %{
          "after_create" => "echo created",
          "before_run" => "echo running",
          "after_run" => "echo done",
          "before_remove" => "echo removing",
          "timeout_ms" => 30_000
        }
      },
      "worker" => %{
        "max_concurrent" => 5,
        "ssh" => %{
          "enabled" => true,
          "hosts" => ["host1", "host2"],
          "max_per_host" => 2
        }
      },
      "agent" => %{
        "max_turns" => 20,
        "max_retry_backoff_ms" => 300_000,
        "max_concurrent_agents_by_state" => %{"open" => 3},
        "stall_timeout_ms" => 300_000
      },
      "acpx" => %{
        "executable" => "acpx",
        "approve_mode" => "approve-all",
        "sandbox" => "default",
        "args" => ["--verbose"]
      },
      "agents" => %{
        "routing" => %{
          "default_agent" => "codex",
          "required_label_prefix" => "symphony/agent/",
          "multi_agent_policy" => "reject",
          "label_aliases" => %{"ai" => "codex"}
        },
        "registry" => %{
          "codex" => %{
            "enabled" => true,
            "display_name" => "Codex",
            "issue_label" => "symphony/agent/codex",
            "acpx_agent" => "codex",
            "timeout_seconds" => 3600
          }
        }
      },
      "commit" => %{
        "enabled" => true,
        "strategy" => "agent_commits",
        "message_template" => "{{identifier}}: {{title}}",
        "author_name" => "Symphony",
        "author_email" => "symphony@example.com",
        "sign_commits" => false,
        "allow_empty" => false,
        "include_untracked" => false,
        "max_changed_files" => 100,
        "max_diff_size" => 100_000,
        "run_pre_commit_hooks" => false,
        "commit_only_after_validation" => false
      },
      "pr" => %{
        "enabled" => true,
        "draft" => false,
        "update_existing" => true,
        "title_template" => "Symphony: {{title}}",
        "body_template" => "Fixes {{identifier}}",
        "include_issue_link" => true,
        "reviewers" => ["alice"],
        "team_reviewers" => ["team-a"],
        "assignees" => ["bob"],
        "labels" => ["symphony"],
        "milestone" => "v1.0",
        "request_review" => true,
        "auto_merge" => false,
        "close_issue_on_merge" => true,
        "comment_on_issue" => true,
        "include_logs_summary" => false
      },
      "validation" => %{
        "commands" => ["mix test"],
        "test_command" => "mix test",
        "typecheck_command" => "mix dialyzer",
        "lint_command" => "mix credo",
        "max_retries" => 2,
        "include_logs_in_corrective_prompt" => true,
        "fail_if_no_diff" => true,
        "fail_if_no_commit" => false,
        "fail_if_pr_cannot_be_created" => false
      },
      "self_correction" => %{
        "enabled" => true,
        "max_correction_attempts" => 3,
        "correction_prompt_template" => "Fix this: {{details}}",
        "retry_backoff_ms" => 5000,
        "classify_failures" => true,
        "retry_on_stall" => true,
        "retry_on_acpx_crash" => true,
        "retry_on_validation_failure" => true,
        "retry_on_no_changes" => true,
        "retry_on_pr_creation_failure" => true,
        "retry_on_merge_conflict" => true,
        "retry_on_dependency_missing" => true
      },
      "logging" => %{
        "level" => "debug",
        "directory" => "/tmp/symphony/logs",
        "ndjson_enabled" => true,
        "text_logs_enabled" => false,
        "event_retention_days" => 30,
        "redact_secrets" => true,
        "raw_acpx_event_capture" => false,
        "raw_stdout_stderr_capture" => false,
        "max_log_size_bytes" => 10_000_000,
        "compress_old_logs" => true,
        "tui_audit_log" => false
      },
      "finalizer" => %{
        "auto_commit_uncommitted" => true,
        "push_branch" => true,
        "open_pr" => true,
        "close_issue" => false,
        "merge_pr" => false
      },
      "hooks" => %{
        "after_create" => "echo created",
        "before_run" => "echo run",
        "after_run" => "echo done",
        "before_remove" => "echo remove",
        "timeout_ms" => 60_000
      },
      "observability" => %{
        "dashboard_enabled" => true,
        "refresh_ms" => 1000,
        "render_interval_ms" => 16
      },
      "server" => %{
        "port" => 4000,
        "host" => "127.0.0.1"
      }
    }

    assert {:ok, settings} = Schema.parse(config)

    # Commit
    assert settings.commit.enabled == true
    assert settings.commit.strategy == "agent_commits"
    assert settings.commit.message_template == "{{identifier}}: {{title}}"
    assert settings.commit.author_name == "Symphony"
    assert settings.commit.sign_commits == false

    # PR
    assert settings.pr.enabled == true
    assert settings.pr.draft == false
    assert settings.pr.reviewers == ["alice"]
    assert settings.pr.milestone == "v1.0"

    # Validation
    assert settings.validation.commands == ["mix test"]
    assert settings.validation.max_retries == 2
    assert settings.validation.fail_if_no_diff == true

    # Finalizer
    assert settings.finalizer.auto_commit_uncommitted == true
    assert settings.finalizer.close_issue == false

    # Logging
    assert settings.logging.level == "debug"
    assert settings.logging.ndjson_enabled == true
    assert settings.logging.compress_old_logs == true

    # Hooks (top-level)
    assert settings.hooks.after_create == "echo created"
    assert settings.hooks.timeout_ms == 60_000

    # Observability
    assert settings.observability.dashboard_enabled == true
    assert settings.observability.refresh_ms == 1000

    # Server
    assert settings.server.port == 4000
    assert settings.server.host == "127.0.0.1"
  end

  test "parse normalizes agent registry keys to strings" do
    config = %{
      "tracker" => %{"kind" => "memory"},
      "agents" => %{
        "routing" => %{"default_agent" => "codex"},
        "registry" => %{
          codex: %{"enabled" => true, "acpx_agent" => "codex"}
        }
      }
    }

    assert {:ok, settings} = Schema.parse(config)
    assert Map.has_key?(settings.agents.registry, "codex")
  end

  test "parse fails on invalid validation max_retries" do
    config = %{
      "tracker" => %{"kind" => "memory"},
      "validation" => %{"max_retries" => -1}
    }

    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(config)
  end

  test "parse fails on invalid observability refresh_ms" do
    config = %{
      "tracker" => %{"kind" => "memory"},
      "observability" => %{"refresh_ms" => 0}
    }

    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(config)
  end

  test "parse fails on invalid server port" do
    config = %{
      "tracker" => %{"kind" => "memory"},
      "server" => %{"port" => -1}
    }

    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(config)
  end

  test "parse fails on invalid hooks timeout_ms" do
    config = %{
      "tracker" => %{"kind" => "memory"},
      "hooks" => %{"timeout_ms" => 0}
    }

    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(config)
  end
end
