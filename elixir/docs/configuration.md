# Configuration

Runtime configuration lives in `.symphony/config.yml`. The workflow prompt lives
in `.symphony/WORKFLOW.md`. `WORKFLOW.md` may still carry YAML front matter in
tests and older deployments, but the repo-local config file is the normal
operations surface.

## Minimal Example

```yaml
---
tracker:
  kind: github
  repo: owner/name
  active_labels: [symphony]
workspace:
  root: .symphony/workspaces
  worktree_strategy: reuse
  git_worktree_enabled: true
  branch_prefix: symphony/
  branch_name_template: "symphony/issue-{{issue_number}}"
  base_branch: main
  fetch_before_run: true
  rebase_before_run: false
  reset_dirty_workspace_policy: fail
  cleanup_policy: never
  retention_days: 14
agent:
  stall_timeout_ms: 300000
acpx:
  executable: acpx
  approve_mode: approve-all
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
```

## Top-Level Sections

| Section | Purpose |
|---------|---------|
| `tracker` | Issue tracker integration (Linear, GitHub, or memory). |
| `workspace` | Worktree/workspace root, branch naming, dirty policy, cleanup, retention, and size limits. |
| `server` | HTTP server port for the status dashboard. |
| `agent` | Global agent behaviour (stall timeout, max turns). |
| `acpx` | Runtime executable and sandbox settings for acpx. |
| `agents` | Agent registry and label-based routing rules. |
| `commit` | Commit message templates and signing. |
| `pr` | Pull-request templates, metadata, issue comments, and merge safety toggles. |
| `validation` | Lint, test, and review requirements. |
| `self_correction` | Retry budgets and failure-class policies. |
| `logging` | NDJSON log directory, level, and retention. |
| `finalizer` | Issue transition rules on success/failure. |
| `hooks` | Pre/post run shell commands. |
| `observability` | Metrics and health-check endpoints. |

## Environment Variable Substitution

String values that match `${VAR_NAME}` are resolved from the environment at load time.  This is the recommended way to inject secrets:

```yaml
tracker:
  api_key: "${LINEAR_API_KEY}"
```

If the variable is unset the value remains the literal string `${LINEAR_API_KEY}` and validation will fail.

## Validation

Symphony validates `.symphony/config.yml` before use. Invalid configs cause the
orchestrator to log an error and retry with backoff. Run
`scripts/symphony-tui.sh view` or `mix symphony.validate` to surface mistakes
early.

## Reloading

`WorkflowStore` polls the files every second. Changing `.symphony/config.yml` or
`.symphony/WORKFLOW.md` on disk takes effect automatically without restarting
the BEAM node.
