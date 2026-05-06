# Logging Best Practices

This guide defines logging conventions for Symphony so operators can diagnose failures quickly.

## Goals

- Make logs searchable by issue and session.
- Capture enough execution context to identify root cause without reruns.
- Keep messages stable so dashboards/alerts are reliable.

## Required Context Fields

When logging issue-related work, include both identifiers:

- `issue_id`: Linear internal UUID or GitHub node ID (stable foreign key).
- `issue_identifier`: human ticket key (for example `MT-620` or `#42`).

When logging agent execution lifecycle events, include:

- `session_id`: acpx session identifier.

## Message Design

- Use explicit `key=value` pairs in message text for high-signal fields.
- Prefer deterministic wording for recurring lifecycle events.
- Include the action outcome (`completed`, `failed`, `retrying`) and the reason/error when available.
- Avoid logging large payloads unless required for debugging.

## NDJSON Structured Logs

When `logging.ndjson_enabled` is `true` (default), `SymphonyElixir.StructuredLogger` writes newline-delimited JSON to `.symphony/logs/symphony-YYYY-MM-DD.ndjson`.

Each line is a JSON object with:

```json
{
  "@timestamp": "2026-05-04T12:34:56Z",
  "level": "info",
  "message": "Agent task completed",
  "service": "symphony",
  "issue_id": "abc-123",
  "issue_identifier": "MT-620",
  "session_id": "sess-42"
}
```

Use these logs for programmatic analysis, alerting, and long-term audit trails.

## Scope Guidance

- `AgentRunner`: log start/completion/failure with issue context, plus `session_id` when known.
- `Orchestrator`: log dispatch, retry, terminal/non-active transitions, and worker exits with issue context. Include `session_id` whenever running-entry data has it.
- `AgentRunner.Acpx`: log session start/completion/error with issue context and `session_id`.

## Checklist For New Logs

- Is this event tied to an issue? Include `issue_id` and `issue_identifier`.
- Is this event tied to an agent session? Include `session_id`.
- Is the failure reason present and concise?
- Is the message format consistent with existing lifecycle logs?
- Does the message contain secrets? Ensure `Redaction` is applied.
