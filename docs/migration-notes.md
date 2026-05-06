# Agent-Agnostic acpx Migration Notes

Symphony now routes every runtime coding-agent execution through
`SymphonyElixir.AgentRunner.Acpx`. GitHub issue labels select a configured agent
id, and the agent id becomes an acpx argv argument or an acpx `--agent` custom
ACP command. Symphony still owns issue polling, worktree setup, commit policy,
PR creation, label transitions, validation, bounded self-correction, and
structured logs.

Removed production runtime paths:

- `elixir/lib/symphony_elixir/codex/app_server.ex`
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- `elixir/lib/symphony_elixir/copilot/autopilot.ex`
- `elixir/test/symphony_elixir/app_server_test.exs`
- `elixir/test/symphony_elixir/dynamic_tool_test.exs`
- `elixir/test/symphony_elixir/copilot_autopilot_test.exs`

Replaced concepts:

- `codex_totals` -> `agent_totals`
- `last_codex_event` -> `last_agent_event`
- `codex_input_tokens` -> `agent_input_tokens`
- `codex_output_tokens` -> `agent_output_tokens`
- `codex_total_tokens` -> `agent_total_tokens`
- `codex_rate_limits` -> `agent_rate_limits`
- direct runtime command selection -> `acpx.executable` plus configured agent argv
- Copilot-specific setup -> generic managed runtime installer with an optional
  compatibility wrapper

Allowed agent-specific references remain only in configuration defaults,
documentation examples, tests/fixtures, installer checks, and doctor
prerequisite checks. Runtime execution must not spawn Codex, Copilot, Claude,
Gemini, Cursor, OpenCode, Qwen, or custom ACP commands directly.

Verification:

- `mix test && mix specs.check`
- `bun run check`
- `scripts/symphony-tui.sh cockpit --once`
- `scripts/symphony-tui.sh view`
- static scans for forbidden direct runtime spawning and legacy terminology
