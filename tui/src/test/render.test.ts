import { describe, expect, test } from "bun:test";
import { renderApp } from "../views/render.ts";
import { DEFAULT_THEME, NO_COLOR_THEME } from "../render/adapter.ts";
import { initialState } from "../state/store.ts";
import { StubAdapter } from "../render/stub_adapter.ts";

const flatten = (rows: { text: string }[][]): string =>
  rows.map((row) => row.map((s) => s.text).join("")).join("\n");

describe("renderApp", () => {
  test("includes view label in nav bar", () => {
    const state = initialState({ layoutWidth: 120, layoutHeight: 30, view: "issues" });
    const frame = renderApp(state, DEFAULT_THEME);
    expect(flatten(frame.rows)).toContain("Issues");
  });

  test("shows read-only badge when token absent", () => {
    const state = initialState({ readOnly: true, layoutWidth: 100, layoutHeight: 12 });
    const frame = renderApp(state, DEFAULT_THEME);
    expect(flatten(frame.rows)).toContain("READ-ONLY");
  });

  test("redacts secret-looking strings in event rows", () => {
    const state = initialState({
      layoutWidth: 120,
      layoutHeight: 20,
      view: "logs",
      events: [
        {
          id: "evt_1",
          type: "agent_stream_line",
          severity: "info",
          timestamp: "2026-01-01T00:00:00Z",
          message: "GH_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz",
        },
      ],
    });
    const frame = renderApp(state, DEFAULT_THEME);
    const text = flatten(frame.rows);
    expect(text).not.toContain("ghp_abcdefghijklmnopqrstuv");
    expect(text).toContain("[REDACTED]");
  });

  test("frame dimensions match layout", () => {
    const state = initialState({ layoutWidth: 80, layoutHeight: 24 });
    const frame = renderApp(state, NO_COLOR_THEME);
    expect(frame.width).toBe(80);
    expect(frame.height).toBe(24);
    expect(frame.rows.length).toBeLessThanOrEqual(24);
  });

  test("controls view marks destructive items only when an issue is selected", () => {
    const state = initialState({
      view: "controls",
      layoutWidth: 120,
      layoutHeight: 30,
      issues: [{ issue_id: "1", issue_identifier: "GH-1", labels: ["symphony"] }],
      selectedIssueId: "1",
    });
    const frame = renderApp(state, DEFAULT_THEME);
    const text = flatten(frame.rows);
    expect(text).toContain("Stop selected");
  });

  test("fills minimum height with blank rows when state is empty", () => {
    const state = initialState({ layoutWidth: 60, layoutHeight: 12 });
    const frame = renderApp(state, DEFAULT_THEME);
    expect(frame.rows.length).toBe(12);
  });

  test("Live view includes events that carry only issue_id", () => {
    // The orchestrator's :agent_stopped audit event is emitted with
    // issue_id but no issue_identifier; it must still appear in the
    // selected issue's Live stream.
    const state = initialState({
      view: "live",
      layoutWidth: 120,
      layoutHeight: 30,
      issues: [{ issue_id: "42", issue_identifier: "GH-42" }],
      selectedIssueId: "42",
      events: [
        {
          id: "evt_id_only",
          type: "agent_stopped",
          severity: "warning",
          timestamp: "2026-01-01T00:00:00Z",
          issue_id: "42",
          issue_identifier: null,
          message: "Stop requested via control API",
        },
      ],
    });
    const frame = renderApp(state, DEFAULT_THEME);
    const text = flatten(frame.rows);
    expect(text).toContain("agent_stopped");
    expect(text).toContain("Stop requested");
  });

  test("StubAdapter records frames", async () => {
    const adapter = new StubAdapter(60, 16);
    await adapter.start();
    const state = initialState({ layoutWidth: 60, layoutHeight: 16 });
    adapter.paint(renderApp(state, DEFAULT_THEME));
    expect(adapter.frames.length).toBe(1);
    expect(adapter.lastFrame()?.width).toBe(60);
  });
});
