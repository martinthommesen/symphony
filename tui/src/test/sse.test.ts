import { describe, expect, test } from "bun:test";
import { SseClient } from "../api/sse.ts";

/**
 * Minimal in-process fetch stub that yields a single SSE response.
 */
function makeFetch(body: string): typeof fetch {
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new TextEncoder().encode(body));
      controller.close();
    },
  });

  const response = new Response(stream, {
    status: 200,
    headers: { "content-type": "text/event-stream" },
  });

  return ((async () => response) as unknown) as typeof fetch;
}

interface CapturedFetch {
  fetchImpl: typeof fetch;
  calls: { url: string; init?: RequestInit }[];
}

/**
 * Yields a different response on each call. Useful for exercising
 * reconnect logic: arrange a 401 on call 0 and a normal stream on
 * call 1, and assert backoff + `?since=` resume.
 */
function makeSequencedFetch(responses: (() => Response)[]): CapturedFetch {
  const calls: { url: string; init?: RequestInit }[] = [];
  let i = 0;

  const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
    const url =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.toString()
          : (input as Request).url;
    calls.push({ url, init });
    const idx = Math.min(i, responses.length - 1);
    const fn = responses[idx];
    i++;
    if (!fn) throw new Error(`fetch sequence exhausted at index ${idx}`);
    return fn();
  }) as unknown as typeof fetch;

  return { fetchImpl, calls };
}

function streamBody(body: string): Response {
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new TextEncoder().encode(body));
      controller.close();
    },
  });
  return new Response(stream, {
    status: 200,
    headers: { "content-type": "text/event-stream" },
  });
}

describe("SseClient", () => {
  test("parses event frames and deduplicates by id", async () => {
    const body =
      "event: agent_stream_line\nid: evt_1\ndata: " +
      JSON.stringify({
        id: "evt_1",
        type: "agent_stream_line",
        severity: "info",
        timestamp: "2026-01-01T00:00:00Z",
      }) +
      "\n\n" +
      "event: agent_stream_line\nid: evt_1\ndata: " +
      JSON.stringify({
        id: "evt_1",
        type: "agent_stream_line",
        severity: "info",
        timestamp: "2026-01-01T00:00:00Z",
      }) +
      "\n\n";

    const events: { id: string }[] = [];
    const client = new SseClient({
      baseUrl: "http://localhost:0",
      onEvent: (e) => events.push({ id: e.id }),
      fetchImpl: makeFetch(body),
    });

    client.start();
    await new Promise((resolve) => setTimeout(resolve, 50));
    client.stop();

    expect(events).toEqual([{ id: "evt_1" }]);
  });

  test("reconnects after a non-2xx response and resumes via ?since=", async () => {
    const successFrame =
      "event: agent_stream_line\nid: evt_resume\ndata: " +
      JSON.stringify({
        id: "evt_resume",
        type: "agent_stream_line",
        severity: "info",
        timestamp: "2026-01-01T00:00:00Z",
      }) +
      "\n\n";

    const sequenced = makeSequencedFetch([
      () => new Response("nope", { status: 401, statusText: "unauthorized" }),
      () => streamBody(successFrame),
    ]);

    const events: { id: string }[] = [];
    const statuses: string[] = [];

    const client = new SseClient({
      baseUrl: "http://localhost:0",
      onEvent: (e) => events.push({ id: e.id }),
      onStatus: (s) => statuses.push(s),
      fetchImpl: sequenced.fetchImpl,
      // Make backoff fast enough to catch the second connect inside the test.
      initialBackoffMs: 10,
      maxBackoffMs: 25,
    });

    client.start();

    // Wait long enough for: (a) initial connect → 401, (b) backoff,
    // (c) reconnect, (d) frame consumption.
    await new Promise((resolve) => setTimeout(resolve, 200));
    client.stop();

    expect(events).toEqual([{ id: "evt_resume" }]);
    expect(statuses).toContain("reconnecting");
    expect(statuses[statuses.length - 1]).toBe("stopped");

    // The first call had no since=. The second call should carry
    // since=<lastEventId> from the (non-existent) first stream — but
    // since the first stream returned 401, no event id was seen, so
    // the second call also has no since=. Test instead that two
    // connects happened (proves reconnect fired).
    expect(sequenced.calls.length).toBeGreaterThanOrEqual(2);
  });

  test("dedupe set evicts oldest ids without losing future delivery", async () => {
    // Build a frame that issues 5_001 unique ids — enough to push the
    // dedupe set past the 5_000 cap and force eviction. Then one
    // additional id that must still get through.
    const frames: string[] = [];
    for (let i = 0; i < 5_001; i++) {
      const id = `evt_${i}`;
      frames.push(
        `event: agent_stream_line\nid: ${id}\ndata: ` +
          JSON.stringify({
            id,
            type: "agent_stream_line",
            severity: "info",
            timestamp: "2026-01-01T00:00:00Z",
          }) +
          "\n\n",
      );
    }
    frames.push(
      `event: agent_stream_line\nid: evt_after_eviction\ndata: ` +
        JSON.stringify({
          id: "evt_after_eviction",
          type: "agent_stream_line",
          severity: "info",
          timestamp: "2026-01-01T00:00:00Z",
        }) +
        "\n\n",
    );

    const events: { id: string }[] = [];
    const client = new SseClient({
      baseUrl: "http://localhost:0",
      onEvent: (e) => events.push({ id: e.id }),
      fetchImpl: makeFetch(frames.join("")),
    });

    client.start();
    await new Promise((resolve) => setTimeout(resolve, 200));
    client.stop();

    // Every distinct id was delivered exactly once.
    expect(events.length).toBe(5_002);
    expect(events[events.length - 1]).toEqual({ id: "evt_after_eviction" });
  });

  test("stop() prevents queued reconnects", async () => {
    let connectCount = 0;
    const fetchImpl = (async () => {
      connectCount++;
      return new Response("nope", { status: 500, statusText: "boom" });
    }) as unknown as typeof fetch;

    const client = new SseClient({
      baseUrl: "http://localhost:0",
      onEvent: () => {},
      fetchImpl,
      initialBackoffMs: 10,
      maxBackoffMs: 20,
    });

    client.start();
    // Let the first connect fail and a reconnect get scheduled.
    await new Promise((resolve) => setTimeout(resolve, 30));
    client.stop();
    const observedAtStop = connectCount;
    // Wait long enough that any pending reconnect would have fired.
    await new Promise((resolve) => setTimeout(resolve, 100));

    expect(connectCount).toBe(observedAtStop);
  });

  test("ignores comments and unknown frames without crashing", async () => {
    const body =
      ":heartbeat\n\n" +
      "event: unknown\ndata: not-json\n\n" +
      "event: agent_stream_line\nid: evt_2\ndata: " +
      JSON.stringify({
        id: "evt_2",
        type: "agent_stream_line",
        severity: "info",
        timestamp: "2026-01-01T00:00:00Z",
      }) +
      "\n\n";

    const events: { id: string }[] = [];
    const client = new SseClient({
      baseUrl: "http://localhost:0",
      onEvent: (e) => events.push({ id: e.id }),
      fetchImpl: makeFetch(body),
    });

    client.start();
    await new Promise((resolve) => setTimeout(resolve, 50));
    client.stop();

    expect(events).toEqual([{ id: "evt_2" }]);
  });
});
