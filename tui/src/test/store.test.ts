import { describe, expect, test } from "bun:test";
import { Store, initialState, reducer } from "../state/store.ts";
import type { EventPayload } from "../api/types.ts";

const baseEvent = (id: string, opts: Partial<EventPayload> = {}): EventPayload => ({
  id,
  type: "agent_stream_line",
  severity: "info",
  timestamp: opts.timestamp ?? "2026-01-01T00:00:00Z",
  issue_id: opts.issue_id ?? null,
  issue_identifier: opts.issue_identifier ?? null,
  message: opts.message ?? null,
  ...opts,
});

describe("reducer", () => {
  test("changes view and clears search", () => {
    const initial = initialState({ searchOpen: true, searchQuery: "abc" });
    const next = reducer(initial, { type: "view/changed", view: "issues" });
    expect(next.view).toBe("issues");
    expect(next.searchOpen).toBe(false);
    expect(next.searchQuery).toBe("");
  });

  test("dedupe events by id and sort by timestamp", () => {
    const a = baseEvent("a", { timestamp: "2026-01-01T00:00:01Z" });
    const b = baseEvent("b", { timestamp: "2026-01-01T00:00:00Z" });

    let state = reducer(initialState(), { type: "events/received", events: [a] });
    state = reducer(state, { type: "events/append", event: a });
    state = reducer(state, { type: "events/append", event: b });

    expect(state.events.map((e) => e.id)).toEqual(["b", "a"]);
  });

  test("issues/received preserves selection if still present", () => {
    const initial = initialState({ selectedIssueId: "1" });
    const next = reducer(initial, {
      type: "issues/received",
      payload: {
        generated_at: "x",
        issues: [
          { issue_id: "1", issue_identifier: "GH-1" },
          { issue_id: "2", issue_identifier: "GH-2" },
        ],
      },
    });
    expect(next.selectedIssueId).toBe("1");
  });

  test("issues/received resets selection when missing", () => {
    const initial = initialState({ selectedIssueId: "1" });
    const next = reducer(initial, {
      type: "issues/received",
      payload: {
        generated_at: "x",
        issues: [{ issue_id: "2", issue_identifier: "GH-2" }],
      },
    });
    expect(next.selectedIssueId).toBe("2");
  });

  test("health/received marks read-only when control disabled", () => {
    const next = reducer(initialState(), {
      type: "health/received",
      health: { status: "ok", capabilities: { control: false, read_only: true } },
    });
    expect(next.readOnly).toBe(true);
  });

  test("notifications cap at 5", () => {
    let state = initialState();
    for (let i = 0; i < 10; i++) {
      state = reducer(state, { type: "notification/push", severity: "info", message: `n${i}` });
    }
    expect(state.notifications.length).toBe(5);
  });
});

describe("Store", () => {
  test("subscribers fire on state change", () => {
    const store = new Store();
    let calls = 0;
    store.subscribe(() => calls++);
    store.dispatch({ type: "view/changed", view: "issues" });
    store.dispatch({ type: "view/changed", view: "issues" }); // identical state may still notify on new ref
    expect(calls).toBeGreaterThanOrEqual(1);
  });
});
