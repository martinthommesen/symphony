/**
 * In-process fake backend for TUI tests/smoke runs. Serves the same
 * endpoints as the real Phoenix API and never requires GitHub/Copilot
 * credentials. Useful when bringing up the TUI in CI without launching
 * Elixir.
 */

import { serve } from "bun";

export interface FakeBackendOptions {
  port?: number;
  controlToken?: string | null;
  initialEvents?: Array<Record<string, unknown>>;
  initialIssues?: Array<Record<string, unknown>>;
}

export function startFakeBackend(options: FakeBackendOptions = {}) {
  const port = options.port ?? 0;
  const controlToken = options.controlToken ?? null;
  let events = [...(options.initialEvents ?? [])];
  let issues = [...(options.initialIssues ?? [])];
  const subscribers = new Set<ReadableStreamDefaultController<Uint8Array>>();

  const enc = new TextEncoder();

  function authorized(headers: Headers): boolean {
    if (!controlToken) return false;
    const h = headers.get("authorization") ?? "";
    const match = h.match(/^Bearer\s+(\S+)$/i);
    return match?.[1] === controlToken;
  }

  function jsonResponse(data: unknown, status = 200): Response {
    return new Response(JSON.stringify(data), {
      status,
      headers: { "content-type": "application/json" },
    });
  }

  // We need to refer to `server.port` from inside the `fetch` handler
  // (so /health reports the actual bound port, not the pre-bind option).
  // `serve()` doesn't accept a forward reference, so we create the
  // server first and then read its port lazily via the closure.
  let boundPort = port;

  const server = serve({
    port,
    fetch(req) {
      const url = new URL(req.url);

      if (url.pathname === "/api/v1/health") {
        return jsonResponse({
          status: "ok",
          version: "0.1.0",
          repo: "fake/repo",
          server: { host: "127.0.0.1", port: boundPort },
          capabilities: {
            control: !!controlToken,
            events_stream: true,
            analytics: true,
            read_only: !controlToken,
          },
          orchestrator: { available: true, paused: false },
        });
      }

      if (url.pathname === "/api/v1/state") {
        return jsonResponse({
          generated_at: new Date().toISOString(),
          status: "running",
          counts: { running: 0, retrying: 0, review: 0, failed: 0, blocked: 0 },
          running: [],
          retrying: [],
          codex_totals: { input_tokens: 0, output_tokens: 0, total_tokens: 0 },
          rate_limits: null,
          polling: { paused: false, checking: false, next_poll_in_ms: 0, poll_interval_ms: 30000 },
          agent_capacity: { max: 10, running: 0, available: 10 },
          tokens: { input_tokens: 0, output_tokens: 0, total_tokens: 0, tokens_per_second: 0 },
          recent_events: [],
        });
      }

      if (url.pathname === "/api/v1/issues") {
        return jsonResponse({
          generated_at: new Date().toISOString(),
          source: { mode: "fake", count: issues.length },
          issues,
        });
      }

      if (url.pathname === "/api/v1/events") {
        return jsonResponse({
          generated_at: new Date().toISOString(),
          events,
          count: events.length,
        });
      }

      if (url.pathname === "/api/v1/analytics") {
        return jsonResponse({
          generated_at: new Date().toISOString(),
          source: { mode: "fake", history_loaded: true, event_count: events.length, window_seconds: 0 },
          metrics: {
            agent_capacity: { max: 10, running: 0, available: 10, utilization: 0 },
            tokens: { input_tokens: 0, output_tokens: 0, total_tokens: 0, tokens_per_second: 0 },
            failures: { agent_failed: 0, agent_timed_out: 0, agent_stalled: 0, retry_scheduled: 0 },
            runtime: { completed_count: 0, average_seconds: 0, p50_seconds: 0, p95_seconds: 0 },
            top_token_consumers: [],
          },
        });
      }

      if (url.pathname === "/api/v1/events/stream") {
        // The `cancel(reason)` callback receives a cancellation reason,
        // not the controller, so we capture the controller in a closure
        // via `start()` and remove it explicitly when the consumer
        // disconnects. The previous form silently leaked entries.
        let captured: ReadableStreamDefaultController<Uint8Array> | null = null;
        const stream = new ReadableStream<Uint8Array>({
          start(controller) {
            captured = controller;
            subscribers.add(controller);
            controller.enqueue(enc.encode(":connected\n\n"));
          },
          cancel() {
            if (captured !== null) {
              subscribers.delete(captured);
              captured = null;
            }
          },
        });
        return new Response(stream, {
          headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
        });
      }

      if (url.pathname.startsWith("/api/v1/control/")) {
        if (!controlToken) {
          return jsonResponse(
            { ok: false, error: { code: "control_disabled", message: "no token" } },
            403,
          );
        }
        if (!authorized(req.headers)) {
          // Match the real Phoenix controller: distinguish a missing
          // Authorization header from a present-but-wrong one so
          // integration tests can assert the right error code.
          const presented = req.headers.get("authorization");
          const code = presented ? "invalid_token" : "missing_token";
          const message = presented ? "Invalid bearer token" : "Authorization: Bearer <token> required";
          return jsonResponse({ ok: false, error: { code, message } }, 401);
        }
        const command = url.pathname.split("/").pop() ?? "";
        return jsonResponse({ ok: true, command, payload: { status: "accepted" } });
      }

      if (url.pathname === "/api/v1/refresh") {
        return jsonResponse({ queued: true, coalesced: false, requested_at: new Date().toISOString() }, 202);
      }

      return new Response("not found", { status: 404 });
    },
  });

  // Now that the server is bound, capture the actual port so /health
  // reports the runtime value rather than the pre-bind option.
  boundPort = server.port ?? port;

  function pushEvent(event: Record<string, unknown>): void {
    events.push(event);
    const frame = `event: ${event.type}\nid: ${event.id}\ndata: ${JSON.stringify(event)}\n\n`;
    const buf = enc.encode(frame);
    for (const ctrl of subscribers) {
      try { ctrl.enqueue(buf); } catch { /* drop */ }
    }
  }

  return {
    port: server.port,
    url: `http://127.0.0.1:${server.port}`,
    pushEvent,
    setIssues(next: Array<Record<string, unknown>>) { issues = next; },
    setEvents(next: Array<Record<string, unknown>>) { events = next; },
    stop() {
      server.stop(true);
      for (const ctrl of subscribers) {
        try { ctrl.close(); } catch { /* drop */ }
      }
      subscribers.clear();
    },
  };
}
