# acpx Runner

`AgentRunner.Acpx` is the only supported production runner.  It spawns the `acpx` CLI as a Port, translates acpx JSON events into Symphony internal events, and classifies errors for self-correction.

## Lifecycle

1. **Build argv** – `Acpx.CommandBuilder` constructs the command array with no shell interpolation.
2. **Spawn port** – `Port.open({:spawn_executable, executable}, args: argv)` starts acpx.
3. **Read JSON lines** – stdout is parsed as newline-delimited JSON events.
4. **Translate events** – Each JSON event becomes a Symphony internal event (`:agent_event`).
5. **Classify errors** – Non-zero exit or malformed JSON is classified into a failure class.
6. **Cleanup** – The port is closed and any zombie OS processes are reaped.

## Command Builder

`Acpx.CommandBuilder` always uses `Path.expand/1` for the executable and `--workspace` path.  It never passes user input through a shell.  Supported flags include:

| Flag | Source |
|------|--------|
| `--agent=<id>` | `agents.registry.*.acpx_agent` |
| `--workspace=<path>` | `workspace.root` + issue sub-directory |
| `--approve=auto` | `acpx.approve_mode` |
| `--sandbox=default` | `acpx.sandbox` |
| `--timeout=<seconds>` | `agents.registry.*.timeout_seconds` |
| `--session-id=<uuid>` | Generated per run |

Custom agent commands (when `custom_acpx_agent_command` is set) are parsed with `OptionParser.split/1` and the `--agent=` flag is injected if missing.

## Event Translation

acpx emits events like:

```json
{"type": "message", "content": "...", "role": "assistant"}
```

These are translated to:

```elixir
{:agent_event, %{type: :message, payload: %{content: "...", role: "assistant"}}}
```

The runner also synthesises `:session_started` and `:session_finished` events so the orchestrator can track session boundaries.

## Error Classification

Exit codes and stderr output are mapped to failure classes:

| Symptom | Failure Class |
|---------|---------------|
| acpx binary missing | `:acpx_missing` |
| Adapter error (bad API key, etc.) | `:acpx_adapter_error` |
| Session timeout / crash | `:acpx_session_error` |
| No output for `stall_timeout_ms` | `:agent_stalled` |
| Validation script failure | `:validation_failed` |
| Tests failed | `:tests_failed` |

These classes feed into `SelfCorrection.recover/2` to decide whether to retry.

## Sandbox Policy

acpx handles sandboxing internally via its `--sandbox` flag.  Symphony does not attempt to apply additional sandbox constraints at the BEAM level.  The `acpx.sandbox` config value is passed through verbatim.
