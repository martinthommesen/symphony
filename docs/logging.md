# Logging

Structured NDJSON logs are written under `.symphony/logs/`. Agent execution
events include `agent_execution_backend: acpx`, the selected agent,
`spawned_executable`, redacted argv, cwd, exit code, duration, and
`direct_agent_spawn: false`.

Secrets are redacted before logs are persisted.
