import { describe, expect, test } from "bun:test";
import { parseEvent, parseEventsPayload, parseHealth, parseIssue, parseIssuesList, parseState } from "../api/schema.ts";

describe("parseEvent", () => {
  test("returns null for missing required fields", () => {
    expect(parseEvent({})).toBeNull();
    expect(parseEvent({ id: "x", type: "y" })).toBeNull();
  });

  test("parses a fully-formed event", () => {
    const event = parseEvent({
      id: "evt_1",
      type: "agent_stream_line",
      severity: "warning",
      timestamp: "2026-01-01T00:00:00Z",
      issue_identifier: "GH-1",
      data: { foo: 1 },
    });
    expect(event).not.toBeNull();
    expect(event?.severity).toBe("warning");
    expect(event?.data).toEqual({ foo: 1 });
  });

  test("falls back to severity=info for unknown values", () => {
    const event = parseEvent({
      id: "evt_2",
      type: "x",
      severity: "garbage",
      timestamp: "2026-01-01T00:00:00Z",
    });
    expect(event?.severity).toBe("info");
  });
});

describe("parseEventsPayload", () => {
  test("filters out invalid events", () => {
    const out = parseEventsPayload({
      generated_at: "2026-01-01T00:00:00Z",
      events: [
        { id: "evt_1", type: "x", severity: "info", timestamp: "2026-01-01T00:00:00Z" },
        { malformed: true },
      ],
      count: 2,
    });
    expect(out.events).toHaveLength(1);
  });
});

describe("parseHealth and parseState", () => {
  test("tolerates partial health payloads", () => {
    const health = parseHealth({});
    expect(health.status).toBe("ok");
    expect(health.repo).toBeNull();
  });

  test("preserves capabilities", () => {
    const health = parseHealth({
      status: "ok",
      capabilities: { control: true, events_stream: true, analytics: true, read_only: false },
    });
    expect(health.capabilities?.control).toBe(true);
  });

  test("parseState extracts running entries even without counts", () => {
    const state = parseState({
      generated_at: "2026-01-01T00:00:00Z",
      running: [{ identifier: "GH-1" }],
    });
    expect(state.running).toHaveLength(1);
  });
});

describe("parseIssue / parseIssuesList", () => {
  test("returns null for non-objects", () => {
    expect(parseIssue("nope")).toBeNull();
  });

  test("parses an issue with optional fields", () => {
    const issue = parseIssue({
      issue_id: "1",
      issue_identifier: "GH-1",
      labels: ["symphony"],
      tokens: { total_tokens: 5 },
    });
    expect(issue?.issue_identifier).toBe("GH-1");
    expect(issue?.labels).toEqual(["symphony"]);
  });

  test("parseIssuesList drops invalid entries", () => {
    const out = parseIssuesList({
      generated_at: "2026-01-01T00:00:00Z",
      issues: [{ issue_identifier: "GH-1" }, "garbage"],
    });
    expect(out.issues).toHaveLength(1);
  });
});
