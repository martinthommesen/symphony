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

  test("health/received preserves local read-only posture when client has no token", () => {
    // Initial state mirrors `App` ctor when client.hasControlToken() === false.
    const initial = initialState({ readOnly: true });
    const next = reducer(initial, {
      type: "health/received",
      health: { status: "ok", capabilities: { control: true, read_only: false } },
    });
    // Server says control is enabled, but local client lacks a token —
    // we must remain read-only so the UI doesn't promise mutations
    // it cannot deliver.
    expect(next.readOnly).toBe(true);
  });

  test("health/received clears read-only only when both local and server allow control", () => {
    const initial = initialState({ readOnly: false });
    const next = reducer(initial, {
      type: "health/received",
      health: { status: "ok", capabilities: { control: true, read_only: false } },
    });
    expect(next.readOnly).toBe(false);
  });

  test("notifications cap at 5", () => {
    let state = initialState();
    for (let i = 0; i < 10; i++) {
      state = reducer(state, { type: "notification/push", severity: "info", message: `n${i}` });
    }
    expect(state.notifications.length).toBe(5);
  });

  test("state/received drops out-of-order responses with older generated_at", () => {
    const initial = initialState();

    const newer = reducer(initial, {
      type: "state/received",
      state: { generated_at: "2026-05-03T00:00:01Z" },
    });
    expect(newer.stateGeneratedAt).toBe("2026-05-03T00:00:01Z");

    const older = reducer(newer, {
      type: "state/received",
      state: { generated_at: "2026-05-03T00:00:00Z", status: "stale" },
    });
    // Older snapshot must be ignored — `state` and `stateGeneratedAt`
    // unchanged.
    expect(older.state?.generated_at).toBe("2026-05-03T00:00:01Z");
    expect(older.state?.status).not.toBe("stale");
  });

  test("issues/received drops out-of-order responses with older generated_at", () => {
    const initial = initialState();

    const newer = reducer(initial, {
      type: "issues/received",
      payload: {
        generated_at: "2026-05-03T00:00:01Z",
        issues: [{ issue_id: "1", issue_identifier: "GH-1" }],
      },
    });
    expect(newer.issuesGeneratedAt).toBe("2026-05-03T00:00:01Z");

    const older = reducer(newer, {
      type: "issues/received",
      payload: {
        generated_at: "2026-05-03T00:00:00Z",
        issues: [{ issue_id: "2", issue_identifier: "GH-2" }],
      },
    });

    expect(older.issues.map((i) => i.issue_id)).toEqual(["1"]);
  });

  test("command/succeeded for a stale seq is ignored", () => {
    let state = initialState();

    state = reducer(state, { type: "command/started", command: "pause", seq: 1 });
    state = reducer(state, { type: "command/started", command: "resume", seq: 2 });
    expect(state.command?.command).toBe("resume");
    expect(state.command?.state).toBe("pending");

    // Pause's success arrives late — must not overwrite the active resume.
    state = reducer(state, { type: "command/succeeded", command: "pause", seq: 1, message: "ok" });
    expect(state.command?.command).toBe("resume");
    expect(state.command?.state).toBe("pending");

    // Resume's own success applies because seq matches.
    state = reducer(state, { type: "command/succeeded", command: "resume", seq: 2, message: "ok" });
    expect(state.command?.state).toBe("success");
    expect(state.command?.command).toBe("resume");
  });
});

describe("Store", () => {
  test("subscribers fire exactly once per dispatch that changes state", () => {
    const store = new Store();
    let calls = 0;
    const unsubscribe = store.subscribe(() => calls++);

    store.dispatch({ type: "view/changed", view: "issues" });
    expect(calls).toBe(1);

    // The reducer always returns a fresh object, so the second dispatch
    // also produces a new ref and fires the subscriber. The behaviour
    // we want to pin: subscribers fire on every applied action, not
    // some deduplicated subset.
    store.dispatch({ type: "view/changed", view: "issues" });
    expect(calls).toBe(2);

    unsubscribe();
    store.dispatch({ type: "view/changed", view: "live" });
    expect(calls).toBe(2);
  });
});
