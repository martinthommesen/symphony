# Agent Routing

Symphony decides which acpx agent to run for an issue by inspecting its labels.

## Label Format

Agents are selected via labels that match the configured prefix:

```
symphony/agent/<agent-id>
```

The default prefix is `symphony/agent/`.  You can change it with:

```yaml
agents:
  routing:
    label_prefix: symphony/agent/
```

## Registry

Every agent that can be routed must be declared in the `agents.registry` map:

```yaml
agents:
  registry:
    codex:
      enabled: true
      display_name: Codex
      issue_label: symphony/agent/codex
      acpx_agent: codex
      timeout_seconds: 3600
    claude:
      enabled: true
      display_name: Claude
      issue_label: symphony/agent/claude
      acpx_agent: claude
      custom_acpx_agent_command: claude-code --agent=claude
```

| Field | Meaning |
|-------|---------|
| `enabled` | Whether this agent can be dispatched. |
| `display_name` | Human-readable name for dashboards. |
| `issue_label` | Exact GitHub label that triggers this agent. |
| `acpx_agent` | The `--agent=` value passed to acpx. |
| `custom_acpx_agent_command` | Optional custom agent command passed to acpx via `--agent`. |
| `timeout_seconds` | Max wall-clock time for a single run. |
| `ttl_seconds` | Session TTL before acpx forces a new context. |
| `max_attempts` | Max retries for this agent per issue. |

## Default Agent

If an issue has no matching label, Symphony falls back to `agents.routing.default_agent`.  If no default is configured, the issue is skipped.

## Multi-Agent Policy

An issue with more than one matching agent label is ambiguous.  The default policy is `reject`, which logs a warning and skips dispatch.  You can change this:

```yaml
agents:
  routing:
    multi_agent_policy: reject
```

* `reject` – skip the issue and log a warning.

## Blocked / Running / Review Checks

Before dispatch, `IssueLabelRouter` verifies:

1. The issue is not in a blocked state.
2. The issue is not already running on this worker.
3. The issue is not in a review state (unless configured otherwise).
4. The issue does not have a `failed` label.

If any check fails, dispatch is skipped regardless of labels.

## Aliases

You can define label aliases so that legacy labels still work:

```yaml
agents:
  routing:
    aliases:
      codex-agent: codex
      ai-copilot: copilot
```

An issue labelled `codex-agent` will be routed to the `codex` registry entry.
