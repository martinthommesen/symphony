# Security

Symphony runs arbitrary agent code on your local machine.  The following safeguards are built in.

## Workspace Isolation

Every issue gets its own workspace directory under `workspace.root` (default: system temp).  The orchestrator verifies that the agent's working directory stays inside this root before spawning acpx.  Attempts to escape via `..` or symlinks are rejected.

## No Shell Interpolation

`Acpx.CommandBuilder` constructs argv arrays directly.  User input (issue titles, descriptions, prompt templates) never passes through `/bin/sh -c`.

## Secret Redaction

`SymphonyElixir.Redaction` scans log output before it reaches the console or disk logs.  Known secret patterns (API keys, tokens, passwords) are replaced with `[REDACTED]`.

The `logging.redact_secrets` setting (default `true`) controls whether NDJSON logs are also scrubbed.

## No Direct Agent Spawning

Production code must only spawn agents through `AgentRunner.Acpx`.  Direct invocation of `codex`, `claude`, `copilot`, `cursor`, `gemini`, `opencode`, or `qwen` binaries is forbidden.  Static guardrail tests scan `lib/` for these patterns and fail the build if found.

## Label-Based Routing Only

Agent selection is driven exclusively by GitHub issue labels (`symphony/agent/<id>`).  There is no API endpoint or config flag that allows an external caller to override the agent for a specific issue.

## Self-Correction Limits

Even retryable failures are capped by `max_correction_attempts`.  An infinite loop of agent crashes will eventually be promoted to a terminal failure and the issue will be left alone.

## Audit Trail

All recovery decisions, agent dispatches, and issue transitions are logged with:

* `issue_id` and `issue_identifier`
* `session_id`
* `run_id`
* timestamp

Enable `logging.tui_audit_log` for an additional append-only audit stream consumed by the TUI.
