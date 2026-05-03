# OpenTUI Operations Cockpit

This document describes the Symphony OpenTUI dashboard: a separate terminal
client that talks to the running Symphony backend over an authenticated
HTTP/SSE API. The TUI never invokes `gh`, `git`, `copilot`, or `codex`
directly — every state-changing operation goes through the Phoenix
control API.

## Architecture

```
┌────────────────────────┐
│ tui/  (Bun + TypeScript)│  ── HTTP/SSE ──┐
│  @opentui/core renderer │                │
└────────────────────────┘                 ▼
                                ┌──────────────────────────────┐
                                │ Phoenix observability/control│
                                │  - /api/v1/health            │
                                │  - /api/v1/state             │
                                │  - /api/v1/issues            │
                                │  - /api/v1/issues/:id        │
                                │  - /api/v1/events            │
                                │  - /api/v1/events/stream     │
                                │  - /api/v1/analytics         │
                                │  - /api/v1/control/*         │
                                └──────────────┬──────────────┘
                                               │
                                ┌──────────────▼──────────────┐
                                │ SymphonyElixir.Orchestrator │
                                │ + Observability.EventStore  │
                                │ + Tracker adapter           │
                                └─────────────────────────────┘
```

The OpenTUI client is a separate Bun process. It can crash or detach
without affecting agents, and the Elixir backend is the single source of
truth for orchestration state.

## OpenTUI package assumptions

Verified at implementation time (May 2026):

- Package: `@opentui/core` v0.2.2 (latest), MIT.
- Core dependency: `bun-ffi-structs@0.2.2` — **requires Bun** as the
  runtime. The native renderer uses Bun's FFI to a Zig core. We therefore
  target **Bun** for the TUI process and document `npm`/`node` as
  *unsupported* for the renderer itself.
- Public API entry points used:
  - `createCliRenderer(config)` from `@opentui/core` — returns a
    `Promise<CliRenderer>`.
  - Renderables: `BoxRenderable`, `TextRenderable`, `InputRenderable`,
    `ScrollBoxRenderable`, `TextTable*`, `TabSelectRenderable`.
    We use the *imperative* API rather than the React reconciler.
  - `KeyHandler` exported via `@opentui/core` core exports for keypress
    handling on the renderer.
- The TUI is wrapped behind a thin adapter (`tui/src/render/adapter.ts`)
  so future OpenTUI API churn is localized and so we can swap in a
  test-only stub renderer for unit tests.

If `@opentui/core` cannot be installed in a deployment environment, the
TUI logs a clear error pointing users at `bun install` and exits cleanly.
There is no fallback to ink/blessed/bubbletea.

## Runtime

- Runtime: **Bun** (developed against 1.3.x; works with anything that
  supports `@opentui/core`'s FFI).
- Test runner: `bun test` (no extra dev dependencies).
- Lint/typecheck: `tsc --noEmit`.
- The `tui/` project is self-contained; its dependencies do not bleed
  into the Elixir build.

## Backend additions (high level)

- `SymphonyElixir.Observability.Event` — neutral redacted event struct.
- `SymphonyElixir.Observability.EventStore` — OTP `GenServer` ring
  buffer with optional JSONL persistence and PubSub broadcast.
- `SymphonyElixir.Observability.Analytics` — pure aggregator over the
  event store and orchestrator snapshot.
- `SymphonyElixir.Observability.Control` — token/auth gate for mutating
  requests; reads `SYMPHONY_CONTROL_TOKEN` or
  `.symphony/control-token` (or whatever the
  `observability.control_token_file` config points at).
- New routes under `/api/v1/...` (see § API surface below).
- New orchestrator commands: `pause_polling/0`, `resume_polling/0`,
  `dispatch_issue/1`, `stop_issue/1`, `retry_issue/1`,
  `block_issue/1`, `unblock_issue/1`, `polling_paused?/0`.

These do not break the existing `/api/v1/state`, `/api/v1/refresh`, or
`/api/v1/:issue_identifier` payload shapes — they only *add* fields.

## API surface

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/v1/health` | Capabilities + read-only/control posture |
| GET | `/api/v1/state` | Backwards-compatible state + new fields |
| GET | `/api/v1/issues` | Issue projection list |
| GET | `/api/v1/issues/:issue_identifier` | Issue detail |
| GET | `/api/v1/events?since=&type=&issue_identifier=&session_id=&limit=` | Recent events query |
| GET | `/api/v1/events/stream` | SSE live event stream (with optional `since`/`replay=1`) |
| GET | `/api/v1/analytics` | Aggregate metrics |
| POST | `/api/v1/control/refresh` | Trigger a poll refresh |
| POST | `/api/v1/control/pause` | Pause candidate polling |
| POST | `/api/v1/control/resume` | Resume candidate polling |
| POST | `/api/v1/control/dispatch` | Dispatch an eligible issue |
| POST | `/api/v1/control/stop` | Stop the active agent for an issue |
| POST | `/api/v1/control/retry` | Retry a failed issue |
| POST | `/api/v1/control/block` | Add the `symphony/blocked` label |
| POST | `/api/v1/control/unblock` | Remove the `symphony/blocked` label |

### Authentication

- `GET` observability endpoints are loopback-readable.
- `POST /api/v1/control/*` requires `Authorization: Bearer <token>`.
- Token resolution order:
  1. `SYMPHONY_CONTROL_TOKEN` environment variable.
  2. File at `observability.control_token_file` (default
     `.symphony/control-token`, relative to CWD).
- If no token is configured, control endpoints return `403` with
  `{ "ok": false, "error": { "code": "control_disabled", … } }` and the
  TUI runs in read-only mode.
- If the configured `server.host` is non-loopback, mutating endpoints
  *also* require a token regardless of any loopback exception.

### Event payload

```json
{
  "id": "evt_018f...",
  "type": "agent_stream_line",
  "severity": "info",
  "timestamp": "2026-05-03T15:00:00Z",
  "issue_id": "...",
  "issue_identifier": "GH-123",
  "issue_number": 123,
  "session_id": "abc",
  "worker_host": null,
  "workspace_path": "/redacted/safe/path",
  "message": "redacted message",
  "data": { }
}
```

Severity is one of `debug`, `info`, `warning`, `error`. `data` is a
redacted map. Unknown event `type` values are passed through but the TUI
must tolerate them.

## Configuration

In `WORKFLOW.md`/`.symphony/config.yml`:

```yaml
observability:
  dashboard_enabled: true
  refresh_ms: 1000
  render_interval_ms: 16
  event_buffer_size: 5000
  jsonl_path: ".symphony/logs/events.jsonl"
  jsonl_enabled: true
  control_token_file: ".symphony/control-token"
```

The on-disk JSONL is currently append-only. The in-memory ring buffer
is bounded by `event_buffer_size`; the file is bounded only by what
operators rotate themselves (e.g., via `logrotate`). A
`retention_days`-style automatic prune is a follow-up.

Backwards compatibility: existing deployments without `observability.*`
new keys keep their defaults. The legacy ANSI status dashboard remains
on by default.

## TUI keybindings

| Key | Action |
|---|---|
| `q` | quit |
| `?` | help |
| `r` | refresh now |
| `p` | pause polling |
| `u` | resume polling |
| `d` | dispatch selected |
| `s` | stop selected (confirmed) |
| `R` (shift+r) | retry selected (confirmed) |
| `b` | block/unblock selected (confirmed) |
| `/` | search |
| `tab`/`shift+tab` | next/previous panel |
| `1`–`8` | switch view (1=Overview … 8=Help) |
| `enter` | inspect selected |
| `esc` | close modal/search |

## Setup runbook

```bash
scripts/setup-symphony-copilot.sh   # creates .symphony/control-token if missing
scripts/symphony-start.sh           # backend (with API + event store)
scripts/symphony-tui.sh             # TUI (control-enabled if token present)
scripts/symphony-status.sh
scripts/symphony-stop.sh
```

Set `SYMPHONY_API_URL` to point at a non-default backend
(`http://127.0.0.1:4000` is the default). Set `SYMPHONY_CONTROL_TOKEN`
to override the on-disk token. Set `SYMPHONY_TUI_NO_COLOR=1` for a
no-color theme; `SYMPHONY_TUI_REDUCED_MOTION=1` disables animations.

## Security posture

- Mutating endpoints require an explicit token. There is no
  "unauthenticated localhost" exception for `POST` routes.
- The TUI never executes shell commands on behalf of a payload.
- All event/log payloads pass through `SymphonyElixir.Redaction.redact/1`
  before persistence, broadcast, API response, and TUI render.
- The TUI applies a defense-in-depth redaction sweep client-side before
  rendering text into any view.

## Known limitations

- `block`/`unblock`/`retry` for the in-memory and Linear trackers
  return `{ "code": "unsupported", "message": "tracker does not support …" }`.
  Only the GitHub adapter implements them today (label-driven).
- Analytics history reflects only events held in the in-memory ring or
  loaded from JSONL on startup. The payload includes
  `source.history_loaded` and `source.event_count` so the TUI can warn.
- The OpenTUI renderer requires a real TTY *and* Bun. Headless/CI
  environments should run TUI tests via `bun test` (which uses the
  renderer-free `StubAdapter`), not the live renderer.
- `gh`-based control commands (block/unblock/retry) require `gh` to be
  installed and authenticated on the orchestrator host, the same
  prerequisite the existing finalizer has.

## Test commands

```bash
# Elixir backend
cd elixir
make ci                    # full CI: setup → build → fmt-check → lint → coverage → dialyzer → tui-typecheck → tui-test
mix test                   # backend tests only
mix test --cover           # backend tests + coverage

# TUI (requires Bun)
cd tui
bun install
bun test                   # runs all TUI tests with the stub adapter
bun x tsc --noEmit         # type check only
```

The TUI tests do not require a running backend; an in-process fake
backend lives in `tui/src/test/fake_backend.ts`.
