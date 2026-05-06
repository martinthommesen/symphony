# Self-Correction

When an agent run fails, `SymphonyElixir.SelfCorrection` classifies the failure and decides whether to retry, repair, or give up.

## Failure Classes

| Class | Typical Cause |
|-------|---------------|
| `:dependency_missing` | Required tool or binary not installed. |
| `:auth_missing` | Missing API token or SSH key. |
| `:acpx_missing` | acpx binary not found on `$PATH`. |
| `:acpx_adapter_error` | acpx adapter misconfiguration (bad API key). |
| `:acpx_session_error` | Session crashed or timed out. |
| `:agent_stalled` | No output for longer than `agent.stall_timeout_ms`. |
| `:agent_cancelled` | Operator cancelled the session. |
| `:validation_failed` | Lint or type-check failed. |
| `:tests_failed` | Test suite failed. |
| `:no_changes` | Agent finished but produced no diff. |
| `:no_commit` | Agent finished but did not commit. |
| `:dirty_worktree` | Workspace has uncommitted changes. |
| `:branch_conflict` | Git branch merge conflict. |
| `:push_failed` | Git push rejected. |
| `:pr_create_failed` | PR creation failed. |
| `:pr_update_failed` | PR update failed. |
| `:ambiguous_agent_labels` | Multiple agent labels on one issue. |
| `:unsupported_agent` | Label points to an agent not in the registry. |
| `:config_invalid` | `WORKFLOW.md` front matter is invalid. |
| `:workspace_corrupt` | Workspace directory is unreadable. |
| `:unknown_failure` | Anything that does not match the above. |

## Recovery Actions

`recover/2` returns one of:

* `{:retry, reason, opts}` – retry with optional backoff, corrective prompt, stash, rebase, etc.
* `{:fail, reason}` – stop processing this issue.
* `{:skip, reason}` – skip this issue for now.

## Configuration

```yaml
self_correction:
  enabled: true
  max_correction_attempts: 2
  retry_backoff_ms: 5000
  retry_on_stall: true
  retry_on_acpx_crash: true
  retry_on_validation_failure: true
  retry_on_no_changes: true
  retry_on_pr_creation_failure: true
  retry_on_merge_conflict: true
  retry_on_dependency_missing: true
```

| Setting | Meaning |
|---------|---------|
| `enabled` | Master switch.  When `false`, every failure becomes `{:fail, "self-correction disabled"}`. |
| `max_correction_attempts` | How many retries per issue before giving up. |
| `retry_backoff_ms` | Delay between retry attempts. |
| `retry_on_*` | Per-class toggles.  If `false`, that class is treated as terminal. |

## Corrective Prompts

For retryable failures, `build_corrective_prompt/4` appends context to the original prompt:

```
---
Self-correction context (attempt 2):
Failure: tests_failed
Details: 3 tests failed in test/symphony_elixir/foo_test.exs
```

This gives the agent enough context to fix its own mistakes on the next attempt.

## Logging

Every recovery decision is logged with structured context:

```
Self-correction decision: run_id=abc issue=42 agent=codex class=tests_failed attempt=1/2 action=recover outcome=retry reason="tests failed: building corrective prompt" opts=[corrective_prompt: true, backoff: 5000]
```
