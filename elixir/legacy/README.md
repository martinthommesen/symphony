# Legacy modules

The following modules belong to the original Linear/Codex implementation and
are **not** part of the default Symphony build path:

- `SymphonyElixir.Linear.Adapter` (`lib/symphony_elixir/linear/adapter.ex`)
- `SymphonyElixir.Linear.Client`  (`lib/symphony_elixir/linear/client.ex`)
- `SymphonyElixir.Linear.Issue`   (`lib/symphony_elixir/linear/issue.ex`)
- `SymphonyElixir.Codex.AppServer` (`lib/symphony_elixir/codex/app_server.ex`)
- `SymphonyElixir.Codex.DynamicTool` (`lib/symphony_elixir/codex/dynamic_tool.ex`)

These modules are unmaintained and retained only for backwards compatibility
with `tracker.kind: linear` configurations and the existing orchestrator
internal struct shape.

Default configurations now use:

- `tracker.kind: github` → `SymphonyElixir.GitHub.Adapter`
- Copilot autopilot runner → `SymphonyElixir.Copilot.Autopilot`
- Finalizer → `SymphonyElixir.GitHub.Finalizer`

Do not extend the legacy modules. New work belongs in
`lib/symphony_elixir/github/` and `lib/symphony_elixir/copilot/`.

## Why we did not physically move these files

The orchestrator (`lib/symphony_elixir/orchestrator.ex`) and the
StatusDashboard (`lib/symphony_elixir/status_dashboard.ex`) reference
`SymphonyElixir.Linear.Issue` as the canonical issue struct shape. The
GitHub adapter converts to that struct at the boundary
(`SymphonyElixir.GitHub.Issue.to_linear_issue/2`) so the existing
orchestrator wiring keeps working without a 100k+ LOC rewrite. The
Linear/Codex source files therefore stay where they are; this README is
the canonical record of which modules are deprecated.
