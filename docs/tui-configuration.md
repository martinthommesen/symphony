# TUI Configuration

Run `scripts/symphony-tui.sh view` to inspect runtime configuration, or
`scripts/symphony-tui.sh cockpit` to open the OpenTUI operations cockpit.

Use `scripts/symphony-tui.sh set <path> <value>` or
`scripts/symphony-tui.sh unset <path>` for global settings, and
`scripts/symphony-tui.sh agent <agent-id> <field> <value>` for agent registry
settings. The editor supports arbitrary non-secret config paths, validates the
resulting config, writes atomically, and audits changes to
`.symphony/logs/tui-audit.ndjson`.

Operational views:

```bash
scripts/symphony-tui.sh logs runs 25
scripts/symphony-tui.sh events 25
scripts/symphony-tui.sh failures 25
scripts/symphony-tui.sh metrics
scripts/symphony-tui.sh audit 25
scripts/symphony-tui.sh cockpit --once
```

The log views read the repo-local NDJSON logs and expose live run output, acpx
events, failure classification and recovery decisions, installer/doctor output,
TUI audit changes, and per-agent success/failure/runtime/retry metrics.

The cockpit view uses OpenTUI for an interactive operator screen with the same
runtime, agent, log, failure, and metric data. `--once` renders a noninteractive
snapshot for scripts, doctor output, or CI smoke checks.
