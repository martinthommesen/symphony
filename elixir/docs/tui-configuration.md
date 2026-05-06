# TUI Configuration

The TUI configuration console is launched with:

```bash
scripts/symphony-tui.sh view
scripts/symphony-tui.sh cockpit
scripts/symphony-tui.sh cockpit --once
scripts/symphony-tui.sh set acpx.executable /absolute/path/to/acpx
scripts/symphony-tui.sh unset pr.milestone
scripts/symphony-tui.sh agent codex model.enabled true
scripts/symphony-tui.sh agent codex model.value gpt-5.1
scripts/symphony-tui.sh logs runs 25
scripts/symphony-tui.sh events 25
scripts/symphony-tui.sh failures 25
scripts/symphony-tui.sh metrics
scripts/symphony-tui.sh audit 25
```

It reads `.symphony/config.yml`, supports arbitrary non-secret config paths,
validates the edited structure before saving, writes through a temporary file,
and appends audit events to
`.symphony/logs/tui-audit.ndjson`.

The console exposes the runtime-relevant configuration groups required for
normal operation:

- agent registry and per-agent model settings
- issue-label routing and retry behavior
- acpx executable, output, permission, and session settings
- worktree/workspace, commit, PR, validation, self-correction, and logging options
- live run logs, acpx events, failure classifier output, installer/doctor output,
  TUI audit changes, and per-agent success/failure/runtime/retry metrics

Secrets must not be written to `.symphony/config.yml`. Use environment
variables or local secret files excluded from git.

`cockpit` starts the OpenTUI operations cockpit. It shows the effective routing
config, enabled agents, live run log, acpx event stream, failure classifier
output, self-correction/recovery events, and per-agent metrics. `cockpit --once`
prints the same data as a static snapshot for noninteractive environments.
