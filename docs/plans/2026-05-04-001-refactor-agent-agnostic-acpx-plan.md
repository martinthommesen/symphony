---
title: "Agent-Agnostic Migration: Codex/Copilot → acpx"
type: refactor
status: active
date: 2026-05-04
---

# Agent-Agnostic Migration: Codex/Copilot → acpx

## Summary

Replace all direct Codex/Copilot runtime execution with a single `SymphonyElixir.AgentRunner.Acpx` module. Introduce a generic agent registry, issue-label-based routing, structured logging, self-correction, and a managed runtime installer. All agent execution goes through `acpx`.

## Key Technical Decisions

- **One runner to rule them all**: `SymphonyElixir.AgentRunner.Acpx` is the only production agent execution module.
- **Agent registry in config**: Agents are configured in `Config.Schema` with routing, registry, and acpx sections.
- **Label-based routing**: `symphony/agent/<agent-id>` labels select agents; default is configurable.
- **Generic state names**: Agent-specific runtime fields become `agent_*`.
- **Argv-only subprocess**: No shell interpolation; acpx commands built as argv lists.
- **Failure classification**: 20+ failure classes with bounded recovery actions.
- **Structured NDJSON logging**: Every event logged to `.symphony/logs/*.ndjson`.

## Implementation Units

- **U1. Config Schema**: Add `agents`, `acpx`, `routing`, `commit`, `pr`, `worktree`, `validation`, `self_correction`, `logging` sections.
- **U2. Agent Registry**: `SymphonyElixir.AgentRegistry` module for agent lookup and validation.
- **U3. Issue Label Router**: `SymphonyElixir.IssueLabelRouter` resolves issue labels to agent IDs.
- **U4. Acpx Command Builder**: `SymphonyElixir.Acpx.CommandBuilder` builds argv for session ensure, prompt, cancel, status.
- **U5. Acpx Runner**: `SymphonyElixir.AgentRunner.Acpx` spawns acpx, parses events, handles timeouts.
- **U6. Agent Runner Refactor**: Update `AgentRunner` to use Acpx runner and generic state.
- **U7. Orchestrator Refactor**: Rename agent-specific fields to agent_*, integrate label router.
- **U8. Self-Correction**: `SymphonyElixir.SelfCorrection` classifier and recovery loop.
- **U9. Structured Logger**: `SymphonyElixir.StructuredLogger` with redaction.
- **U10. Finalizer**: Make agent-agnostic, update PR body template.
- **U11. CLI**: Update acknowledgements and guardrails messaging.
- **U12. Scripts**: Replace with `install-symphony.sh`, `symphony-doctor.sh`, etc.
- **U13. Tests**: Static guardrails, routing, command construction, model config.
- **U14. Docs**: Rewrite README and create agent-agnostic docs.

## Scope Boundaries

- TUI configuration editing is scoped to config file generation; full interactive TUI is deferred.
- `acpx` itself is an external dependency; we only build the orchestrator integration.
- Legacy `Codex.AppServer` and `Copilot.Autopilot` are removed from production; no runtime compatibility runner remains.

## Verification

- `mix test` passes.
- Static scan test fails if any production code spawns forbidden binaries.
- `mix specs.check` passes.
