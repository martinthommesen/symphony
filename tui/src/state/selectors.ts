/**
 * Pure selectors over `AppState`. Tested in `src/test/state.test.ts`.
 */

import type { AppState, ViewName } from "./store.ts";
import type { EventPayload, IssueProjection } from "../api/types.ts";

export interface IssueSortOptions {
  by: "state" | "runtime" | "tokens" | "last_event" | "identifier";
  direction: "asc" | "desc";
}

export const VIEW_NAMES: Record<string, ViewName> = {
  "1": "overview",
  "2": "issues",
  "3": "live",
  "4": "controls",
  "5": "analytics",
  "6": "logs",
  "7": "config",
  "8": "help",
};

export function selectedIssue(state: AppState): IssueProjection | null {
  if (!state.selectedIssueId) return state.issues[0] ?? null;
  return state.issues.find((i) => i.issue_id === state.selectedIssueId) ?? null;
}

export function filteredIssues(state: AppState): IssueProjection[] {
  const q = state.searchQuery.trim().toLowerCase();
  let list = state.issues;

  if (q) {
    list = list.filter((issue) => {
      return (
        (issue.issue_identifier ?? "").toLowerCase().includes(q) ||
        (issue.title ?? "").toLowerCase().includes(q) ||
        (issue.state ?? "").toLowerCase().includes(q) ||
        (issue.labels ?? []).some((l) => l.toLowerCase().includes(q))
      );
    });
  }

  return list;
}

export function sortedIssues(
  issues: IssueProjection[],
  opts: IssueSortOptions = { by: "state", direction: "asc" },
): IssueProjection[] {
  const direction = opts.direction === "asc" ? 1 : -1;
  return [...issues].sort((a, b) => {
    switch (opts.by) {
      case "runtime":
        return direction * (Number(a.runtime_seconds ?? 0) - Number(b.runtime_seconds ?? 0));
      case "tokens":
        return direction * ((a.tokens?.total_tokens ?? 0) - (b.tokens?.total_tokens ?? 0));
      case "last_event":
        return direction * (a.last_event ?? "").localeCompare(b.last_event ?? "");
      case "identifier":
        return direction * (a.issue_identifier ?? "").localeCompare(b.issue_identifier ?? "");
      case "state":
      default:
        return direction * statePriority(a.state).localeCompare(statePriority(b.state));
    }
  });
}

const STATE_ORDER = ["running", "retrying", "review", "failed", "blocked", "open", "done", "closed"];

function statePriority(state?: string): string {
  if (!state) return "z";
  const i = STATE_ORDER.indexOf(state.toLowerCase());
  return i < 0 ? `z-${state.toLowerCase()}` : `${i}`.padStart(2, "0");
}

export function eventsForSelectedIssue(state: AppState): EventPayload[] {
  const target = selectedIssue(state);
  if (!target) return state.events;
  // Match by any of the identifiers present on both the projection and
  // the event. We deliberately don't try to match `session_id` here:
  // the projection doesn't carry one, and the previous form compared
  // session_id against workspace_path — a typo that produced spurious
  // matches when both happened to be null.
  return state.events.filter(
    (e) =>
      (e.issue_identifier != null && e.issue_identifier === target.issue_identifier) ||
      (e.issue_id != null && e.issue_id === target.issue_id) ||
      (e.workspace_path != null && e.workspace_path === target.workspace_path),
  );
}

export function filteredEvents(state: AppState): EventPayload[] {
  const { type, severity, query } = state.eventFilter;
  let events = state.events;
  if (type) events = events.filter((e) => e.type === type);
  if (severity) events = events.filter((e) => e.severity === severity);
  if (query) {
    const q = query.toLowerCase();
    events = events.filter((e) => {
      return (
        (e.message ?? "").toLowerCase().includes(q) ||
        (e.issue_identifier ?? "").toLowerCase().includes(q) ||
        (e.type ?? "").toLowerCase().includes(q)
      );
    });
  }
  return events;
}

export function isControlEnabled(state: AppState): boolean {
  return !state.readOnly;
}

export function pollingPaused(state: AppState): boolean {
  return state.state?.polling?.paused === true;
}

export function activeAgentCount(state: AppState): number {
  return state.state?.counts?.running ?? state.state?.running?.length ?? 0;
}

export function maxAgents(state: AppState): number {
  return state.state?.agent_capacity?.max ?? 0;
}

export function tokensTotal(state: AppState): number {
  return state.state?.tokens?.total_tokens ?? 0;
}

export function tokensPerSecond(state: AppState): number {
  return state.state?.tokens?.tokens_per_second ?? 0;
}
