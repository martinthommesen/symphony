# Migration Plan: OpenAI Symphony → GitHub Issues + Copilot CLI

This document tracks the port of the reference Elixir Symphony implementation
from a Linear/Codex stack to a GitHub Issues/Copilot CLI stack.

## 1. Existing tracker seam

The tracker is dispatched through a behaviour and a configurable adapter.

- `elixir/lib/symphony_elixir/tracker.ex`
  - `@callback fetch_candidate_issues/0`
  - `@callback fetch_issues_by_states/1`
  - `@callback fetch_issue_states_by_ids/1`
  - `@callback create_comment/2`
  - `@callback update_issue_state/2`
  - `Tracker.adapter/0` selects an adapter based on `Config.settings!().tracker.kind`.
- `elixir/lib/symphony_elixir/linear/adapter.ex` – Linear-specific implementation.
- `elixir/lib/symphony_elixir/linear/client.ex` – Linear GraphQL client.
- `elixir/lib/symphony_elixir/linear/issue.ex` – normalized issue struct
  (`%SymphonyElixir.Linear.Issue{}`); used pervasively as the issue model.
- `elixir/lib/symphony_elixir/tracker/memory.ex` – in-memory adapter for tests.

Linear-specific assumptions baked in:

- The internal issue struct lives in the `SymphonyElixir.Linear.Issue` namespace.
- Tracker state semantics are Linear status names ("Todo", "In Progress",
  "Done", "Closed", "Cancelled", "Duplicate", "Rework", "Human Review",
  "Merging").
- `Config` schema requires `tracker.api_key` and `tracker.project_slug` for
  `tracker.kind == "linear"`.
- `Linear.Adapter.update_issue_state/2` resolves Linear state IDs via GraphQL
  before issuing a status mutation.
- Comments are added through the Linear `commentCreate` mutation.

## 2. Existing runner seam

The runner is composed of three layers:

- `elixir/lib/symphony_elixir/agent_runner.ex` – per-issue orchestrator.
  Calls `Workspace.create_for_issue/2`, `Workspace.run_before_run_hook/3`,
  starts a Codex session, runs turns, and runs the after-run hook.
- `elixir/lib/symphony_elixir/codex/app_server.ex` – Codex app-server JSON-RPC
  client. Spawns `codex app-server` over a port, opens a thread, runs turns,
  forwards messages to the orchestrator via `on_message` callbacks.
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex` – dynamic tool support
  served back to Codex (the legacy `linear_graphql` tool).

Status/log/event flow:

- `AgentRunner.run/3` accepts a `codex_update_recipient` pid and forwards
  `{:codex_worker_update, issue_id, message}` and `{:worker_runtime_info,
  issue_id, info}` messages.
- `AppServer.run_turn/4` takes `on_message` and `tool_executor` callbacks.
- The orchestrator collects these messages and feeds them into
  `StatusDashboard`, `LogFile`, and `ObservabilityPubSub`.

Stop/timeout/error:

- `Codex.command` is started as a `Port` with `:exit_status`.
- Timeouts are enforced via `codex.turn_timeout_ms`, `read_timeout_ms`, and
  `stall_timeout_ms`.
- Termination escalates: graceful via `Port.close/1`; the orchestrator owns
  the kill path.

## 3. New module layout

GitHub tracker adapter:

- `elixir/lib/symphony_elixir/github/issue.ex` – normalized GitHub issue
  struct (parallel to `Linear.Issue`).
- `elixir/lib/symphony_elixir/github/cli.ex` – `gh` CLI argv runner.
- `elixir/lib/symphony_elixir/github/parser.ex` – body parsing for blocked-by
  task references and priority labels.
- `elixir/lib/symphony_elixir/github/adapter.ex` – tracker adapter that
  implements the existing `SymphonyElixir.Tracker` behaviour while exposing
  additional label/branch/PR operations.
- `elixir/lib/symphony_elixir/github/finalizer.ex` – branch push and PR
  create/update; runs after Copilot exits.

Copilot autopilot runner:

- `elixir/lib/symphony_elixir/copilot/autopilot.ex` – argv construction,
  process spawn, JSONL parsing, timeout/stall enforcement.

Shared utilities:

- `elixir/lib/symphony_elixir/redaction.ex` – token/PAT/bearer redaction
  used on every log path.
- `elixir/lib/symphony_elixir/repo_id.ex` – `owner/repo` validation.

Schema/config:

- `elixir/lib/symphony_elixir/config/schema.ex` – extended with
  `Tracker` (github fields), `Copilot`, and `Finalizer` blocks.

## 4. Config-schema diff

Removed defaults:

- `tracker.endpoint` Linear default
- `tracker.api_key`, `tracker.project_slug`, `tracker.assignee`
- `tracker.active_states`, `tracker.terminal_states`
- `codex.command`, `codex.approval_policy`, `codex.thread_sandbox`,
  `codex.turn_sandbox_policy`

Added/required:

- `tracker.kind: github`
- `tracker.repo: owner/name`
- `tracker.active_labels`, `tracker.blocked_labels`
- `tracker.running_label`, `tracker.done_label`, `tracker.failed_label`,
  `tracker.review_label`
- `tracker.retry_failed`
- `copilot.command`, `copilot.mode`, `copilot.permission_mode`,
  `copilot.no_ask_user`, `copilot.output_format`,
  `copilot.max_autopilot_continues`, `copilot.turn_timeout_ms`,
  `copilot.read_timeout_ms`, `copilot.stall_timeout_ms`,
  `copilot.deny_tools`
- `finalizer.auto_commit_uncommitted`, `finalizer.push_branch`,
  `finalizer.open_pr`, `finalizer.close_issue`, `finalizer.merge_pr`

Backwards compatibility: `tracker.kind: linear` and `codex.*` still parse
to the legacy Linear/Codex structs but are not part of the default
generated config.

## 5. Code cleanup decision

**Option B** – move `linear/` and `codex/` directories under `elixir/legacy/`
(plus a `legacy/README.md`).

Justification:

- The orchestrator (52 kLOC) and the StatusDashboard (60 kLOC) hard-reference
  `SymphonyElixir.Linear.Issue` and `SymphonyElixir.Codex.AppServer`; deleting
  those modules outright would require an orchestrator rewrite that exceeds
  the scope of this port.
- Moving the legacy modules into `legacy/` and recompiling them under the
  same OTP application keeps the existing orchestrator wiring functional
  while clearly signaling that the modules are unmaintained and not part
  of the default code path.
- The new GitHub/Copilot adapters live in `lib/symphony_elixir/github/` and
  `lib/symphony_elixir/copilot/` and become the default.
- The `Tracker` behaviour callback shape is preserved so the orchestrator
  can swap in `SymphonyElixir.GitHub.Adapter` with no churn.

In practice we keep `lib/symphony_elixir/linear/issue.ex` in place because
it is the issue struct used by the orchestrator, but we add a parallel
`SymphonyElixir.GitHub.Issue` struct for the new tracker. The new adapter
returns the GitHub-shaped struct and the orchestrator/legacy code paths
that explicitly need a `Linear.Issue` wrapper convert through
`GitHub.Issue.to_linear_issue/1` at the boundary.

## 6. Implementation checklist

| Section                              | Code change                                                   |
| ------------------------------------ | ------------------------------------------------------------- |
| §5 GitHub tracker adapter            | `lib/symphony_elixir/github/{cli,issue,parser,adapter}.ex`    |
| §5.1 Repo identity validation        | `lib/symphony_elixir/repo_id.ex`                              |
| §5.2 Normalized issue model          | `lib/symphony_elixir/github/issue.ex`                         |
| §5.3 Priority derivation             | `lib/symphony_elixir/github/parser.ex` `priority_from_labels` |
| §5.4 Blocked-by parsing              | `lib/symphony_elixir/github/parser.ex` `blocked_by_from_body` |
| §5.5 Eligibility                     | `lib/symphony_elixir/github/adapter.ex` `eligible?/2`         |
| §5.6 Required tracker operations     | `lib/symphony_elixir/github/adapter.ex`                       |
| §5.7 State transitions               | `lib/symphony_elixir/github/adapter.ex`                       |
| §6 Copilot CLI autonomous runner     | `lib/symphony_elixir/copilot/autopilot.ex`                    |
| §6.5 Finalizer                       | `lib/symphony_elixir/github/finalizer.ex`                     |
| §8 One-script setup                  | `scripts/setup-symphony-copilot.sh`                           |
| §8.4 Wrapper scripts                 | `scripts/symphony-{start,stop,status}.sh`                     |
| §9 Target repo config                | `scripts/setup-symphony-copilot.sh` (generates)               |
| §10 WORKFLOW.md template             | `priv/templates/WORKFLOW.md`                                  |
| §11 Config parsing                   | `lib/symphony_elixir/config/schema.ex`                        |
| §12 Linear/Codex cleanup             | move to `elixir/legacy/`, drop from defaults                  |
| §13 Logging and redaction            | `lib/symphony_elixir/redaction.ex`                            |
| §14 Tests                            | `test/symphony_elixir/github_*_test.exs`, `copilot_*_test.exs`|
| §15 Validation gates                 | run when toolchain is available                               |
| §16 Live e2e                         | `make e2e-github` target                                      |
| §17 README updates                   | `README.md`, `elixir/README.md`                               |
| §18 MIGRATION_NOTES.md               | this directory                                                |

## 7. Risks and unresolved assumptions

- The installed Copilot CLI may not support `--deny-tool='shell(...)'` patterns
  exactly as written. Where unsupported, the runner reports degraded
  permissions and Symphony still owns final GitHub state mutation.
- `gh issue list --label` matches labels case-insensitively but `gh` does not
  always enforce that. We always lowercase labels at the boundary.
- The orchestrator and StatusDashboard contain ~110 kLOC of code coupled to
  the `Linear.Issue` struct shape and Linear status semantics. To keep this
  port tractable, the GitHub adapter returns issues that adapt into
  `Linear.Issue` so the orchestrator does not need a rewrite. State strings
  in the orchestrator map to GitHub label states (e.g. `"running"`,
  `"review"`, `"failed"`, `"open"`, `"blocked"`).
- The escript bin path stays at `bin/symphony`; wrapper scripts assume the
  Symphony repo is checked out under `$XDG_DATA_HOME/symphony-copilot`.
- Validation gates (`mix format --check-formatted`, `mix test`,
  `mix credo --strict`, `shellcheck`) cannot be exercised in the build
  environment for this PR because Elixir/`gh`/`copilot`/`shellcheck` are not
  available on the runner. This is reported explicitly in the completion
  summary; the project's existing CI is expected to enforce the gates.
