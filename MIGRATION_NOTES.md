# Migration Notes: Linear/Codex → GitHub Issues/Copilot CLI

## Tracker mapping (Linear → GitHub Issues)

| Linear concept             | GitHub equivalent                                      |
| -------------------------- | ------------------------------------------------------ |
| `LINEAR_API_KEY` env var   | authenticated `gh` CLI                                 |
| `tracker.project_slug`     | `tracker.repo` (`owner/name`)                          |
| Workflow status: `Todo`    | label `symphony` on an open issue                      |
| Workflow status: `Running` | label `symphony/running`                               |
| Workflow status: `Done`    | label `symphony/done` (opt-in)                         |
| Workflow status: `Failed`  | label `symphony/failed`                                |
| Workflow status: `Review`  | label `symphony/review`                                |
| Workflow status: `Blocked` | label `symphony/blocked`                               |
| `inverseRelations` blocks  | unchecked task-list items (`- [ ] #N`)                 |
| Linear comments            | issue comments via `gh issue comment`                  |
| Linear branchName          | `symphony/issue-<number>` (deterministic)              |

The Linear-only workflow statuses `Rework`, `Human Review`, and `Merging` are
removed. Use labels and PR review state instead.

## Runner mapping (Codex → Copilot CLI)

| Codex concept                                | Copilot equivalent                                    |
| -------------------------------------------- | ----------------------------------------------------- |
| `codex app-server` (JSON-RPC over stdio)     | `copilot --autopilot --yolo` (argv, JSONL stdout)     |
| `codex.approval_policy`                      | `copilot.permission_mode` (`yolo` by default)         |
| `codex.thread_sandbox`                       | n/a — Copilot does not sandbox                        |
| `codex.turn_sandbox_policy`                  | enforced via orchestration: `cwd`, deny tools, finalizer validation |
| `codex.turn_timeout_ms`                      | `copilot.turn_timeout_ms` (same default)              |
| `codex.read_timeout_ms`                      | `copilot.read_timeout_ms` (same default)              |
| `codex.stall_timeout_ms`                     | `copilot.stall_timeout_ms` (same default)             |

## Why `--autopilot --yolo` is the default

The reference Copilot CLI v1 default for unattended completion is autopilot
plus `--yolo`. Symphony's existing supervision model is built on hard
guardrails *outside* the agent process, so the agent itself should not
re-prompt the operator. We pair `--yolo` with:

- a per-issue isolated workspace (`cwd` restriction)
- argv-only command construction (no shell interpolation)
- `--deny-tool='shell(git push)'` and friends (where supported)
- finalizer validation before any push or PR
- redaction of tokens from every log path
- `tracker.repo` validated as `owner/repo`

`--yolo` is **not** a sandbox; the orchestration layer is.

## Why ACP is not the default

`copilot --acp --stdio` is preview and assumes long-lived editor sessions.
Symphony's polling model creates short, single-issue sessions. Autopilot is
a closer fit for unattended completion.

ACP can be enabled by setting `copilot.mode: acp`, but the Symphony Elixir
runner does not yet implement an ACP client. Setting `mode: acp` fails
config validation with `:copilot_acp_mode_not_implemented` until ACP support
ships.

## What Symphony owns vs. what Copilot owns

Copilot may:

- inspect the repository
- edit files inside the workspace
- run tests
- create local commits
- emit a completion summary on stdout

Symphony owns:

- pushing the branch
- creating or updating the pull request
- linking the PR to the issue (`Related to #N`, never auto-close keywords)
- commenting on the issue
- transitioning issue labels
- enforcing timeouts and stop reasons

## Security implications

`--yolo` grants Copilot broad access inside its `cwd`. The hard security
controls are:

1. Workspace isolation via the orchestrator's per-issue workspace.
2. Argv-only invocation; no shell interpolation of user/issue data.
3. Validation of the `owner/repo` identifier before every `gh` call.
4. Deny-tool patterns for `git push`, `gh pr`, and `gh issue` where the
   installed Copilot CLI version supports them.
5. Finalizer checks the working branch and changed paths before push.
6. No auto-merge. No auto-close (`finalizer.merge_pr` and
   `finalizer.close_issue` default to `false`).
7. Token redaction on stdout, stderr, status output, and shell errors.

## Config migration

Old (Linear/Codex):

```yaml
tracker:
  kind: linear
  api_key: "$LINEAR_API_KEY"
  project_slug: my-project
codex:
  command: codex app-server
  approval_policy: never
```

New (GitHub/Copilot):

```yaml
tracker:
  kind: github
  repo: my-org/my-repo
copilot:
  command: copilot
  mode: autopilot
  permission_mode: yolo
finalizer:
  push_branch: true
  open_pr: true
  close_issue: false
  merge_pr: false
```

## Removed environment variables

- `LINEAR_API_KEY`
- `LINEAR_ASSIGNEE`

Authentication for both `gh` and `copilot` is taken from the tools' own
credential stores (run `gh auth login` and `copilot login`).

## Removed skills and assets

- `linear_graphql` skill / app-server tool
- the `linear` skill in `.codex/`
- Linear-specific status names (`Rework`, `Human Review`, `Merging`)

## Known limitations

- The orchestrator and StatusDashboard still use the `Linear.Issue` struct
  shape internally because of historical coupling. The GitHub adapter
  converts to that shape at the boundary so the dashboard renders without
  changes.
- Copilot CLI's deny-tool flag matching has been observed to vary across
  versions. If the installed CLI cannot enforce the configured deny rules,
  Symphony reports the degraded mode in `runner` status metadata; outer
  orchestration controls remain in force.
- Live e2e cannot be exercised in environments without Copilot CLI auth.
- Validation gates (`mix`, `gh`, `copilot`, `shellcheck`) require the
  full toolchain; in their absence this PR documents which assertions are
  unverified rather than silently passing.
