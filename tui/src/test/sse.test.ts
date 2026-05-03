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
