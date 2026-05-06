/**
 * Deterministic application store. Components must dispatch actions; they
 * never mutate state directly. The reducer is pure and exported separately
 * so it can be unit-tested without a renderer.
 */

import type {
  AnalyticsPayload,
  EventPayload,
  HealthPayload,
  IssueProjection,
  IssuesListPayload,
  StatePayload,
} from "../api/types.ts";
import type { SseStatus } from "../api/sse.ts";

export type ViewName = "overview" | "issues" | "live" | "controls" | "analytics" | "logs" | "config" | "help";

export type ConnectionStatus =
  | "booting"
  | "connecting"
  | "connected"
  | "reconnecting"
  | "disconnected"
  | "backend_unavailable"
  | "read_only"
  | "error";

export interface CommandStatus {
  command: string;
  state: "pending" | "success" | "error";
  message?: string;
  startedAt: number;
  /** Monotonic per-command sequence number; stale results are ignored. */
  seq: number;
}

export interface AppState {
  view: ViewName;
  connection: ConnectionStatus;
  connectionMessage: string | null;
  health: HealthPayload | null;
  state: StatePayload | null;
  /** Most recent `state.generated_at` accepted into `state`. Older
   *  payloads (out-of-order HTTP responses) are dropped. */
  stateGeneratedAt: string | null;
  issues: IssueProjection[];
  issuesGeneratedAt: string | null;
  issuesSource: string | null;
  selectedIssueId: string | null;
  events: EventPayload[];
  eventFilter: { type: string | null; severity: string | null; query: string };
  follow: boolean;
  analytics: AnalyticsPayload | null;
  command: CommandStatus | null;
  notifications: { id: string; severity: "info" | "warning" | "error"; message: string; at: number }[];
  searchQuery: string;
  searchOpen: boolean;
  confirmation: { command: string; message: string; payload: Record<string, unknown> } | null;
  layoutWidth: number;
  layoutHeight: number;
  noColor: boolean;
  reducedMotion: boolean;
  readOnly: boolean;
}

export type Action =
  | { type: "view/changed"; view: ViewName }
  | { type: "connection/changed"; status: ConnectionStatus; message?: string | null }
  | { type: "health/received"; health: HealthPayload }
  | { type: "state/received"; state: StatePayload }
  | { type: "issues/received"; payload: IssuesListPayload }
  | { type: "issues/selected"; issueId: string | null }
  | { type: "events/received"; events: EventPayload[]; replace?: boolean }
  | { type: "events/append"; event: EventPayload }
  | { type: "events/filter"; filter: Partial<AppState["eventFilter"]> }
  | { type: "events/follow"; follow: boolean }
  | { type: "analytics/received"; payload: AnalyticsPayload }
  | { type: "command/started"; command: string; seq: number }
  | { type: "command/succeeded"; command: string; seq: number; message?: string }
  | { type: "command/failed"; command: string; seq: number; message: string }
  | { type: "search/open"; open: boolean }
  | { type: "search/changed"; query: string }
  | { type: "confirm/show"; command: string; message: string; payload: Record<string, unknown> }
  | { type: "confirm/hide" }
  | { type: "layout/resized"; width: number; height: number }
  | { type: "settings/loaded"; readOnly: boolean; noColor: boolean; reducedMotion: boolean }
  | { type: "notification/push"; severity: "info" | "warning" | "error"; message: string }
  | { type: "notification/expire"; id: string };

export function initialState(overrides: Partial<AppState> = {}): AppState {
  return {
    view: "overview",
    connection: "booting",
    connectionMessage: null,
    health: null,
    state: null,
    stateGeneratedAt: null,
    issues: [],
    issuesGeneratedAt: null,
    issuesSource: null,
    selectedIssueId: null,
    events: [],
    eventFilter: { type: null, severity: null, query: "" },
    follow: true,
    analytics: null,
    command: null,
    notifications: [],
    searchQuery: "",
    searchOpen: false,
    confirmation: null,
    layoutWidth: 80,
    layoutHeight: 24,
    noColor: false,
    reducedMotion: false,
    readOnly: false,
    ...overrides,
  };
}

const MAX_EVENTS = 2_000;
const MAX_NOTIFICATIONS = 5;

export function reducer(state: AppState, action: Action): AppState {
  switch (action.type) {
    case "view/changed":
      return { ...state, view: action.view, searchOpen: false, searchQuery: "" };

    case "connection/changed":
      return {
        ...state,
        connection: action.status,
        connectionMessage: action.message ?? null,
      };

    case "health/received": {
      // Server capability flags describe whether the *backend* would accept
      // mutating requests, not whether this TUI instance has a token. When
      // the local client started without one (read_only initialised to
      // true), keep it that way — otherwise hotkeys would re-enable and
      // every mutation would fail with `missing_token`. Only allow
      // health/received to make read_only more restrictive, never less.
      const serverReadOnly =
        action.health.capabilities?.read_only ?? !action.health.capabilities?.control;
      return {
        ...state,
        health: action.health,
        readOnly: state.readOnly || serverReadOnly,
      };
    }

    case "state/received": {
      // Drop out-of-order responses: a slow `/api/v1/state` resolved
      // after a fresher one would otherwise overwrite the newer
      // snapshot. Compare server-stamped `generated_at` because client
      // wall clocks would race the same dispatch order.
      if (state.stateGeneratedAt && action.state.generated_at &&
          action.state.generated_at < state.stateGeneratedAt) {
        return state;
      }
      return {
        ...state,
        state: action.state,
        stateGeneratedAt: action.state.generated_at || state.stateGeneratedAt,
      };
    }

    case "issues/received": {
      // Same monotonic gate as `state/received` — issues poll is on the
      // same 2s cadence and stacks the same way.
      if (state.issuesGeneratedAt && action.payload.generated_at &&
          action.payload.generated_at < state.issuesGeneratedAt) {
        return state;
      }

      const selected = state.selectedIssueId &&
        action.payload.issues.some((i) => i.issue_id === state.selectedIssueId)
        ? state.selectedIssueId
        : action.payload.issues[0]?.issue_id ?? null;

      return {
        ...state,
        issues: action.payload.issues,
        issuesGeneratedAt: action.payload.generated_at,
        issuesSource: action.payload.source?.mode ?? null,
        selectedIssueId: selected,
      };
    }

    case "issues/selected":
      return { ...state, selectedIssueId: action.issueId };

    case "events/received": {
      const next = action.replace ? action.events : mergeUnique(state.events, action.events);
      return { ...state, events: next.slice(-MAX_EVENTS) };
    }

    case "events/append": {
      const next = mergeUnique(state.events, [action.event]);
      return { ...state, events: next.slice(-MAX_EVENTS) };
    }

    case "events/filter":
      return {
        ...state,
        eventFilter: { ...state.eventFilter, ...action.filter },
      };

    case "events/follow":
      return { ...state, follow: action.follow };

    case "analytics/received":
      return { ...state, analytics: action.payload };

    case "command/started":
      return {
        ...state,
        command: {
          command: action.command,
          state: "pending",
          startedAt: Date.now(),
          seq: action.seq,
        },
      };

    case "command/succeeded": {
      // Ignore stale results: pressing `p` (pause) then quickly `u`
      // (resume) would otherwise see pause's success arrive after
      // resume's started, clobbering the active resume status.
      if (!state.command || state.command.seq !== action.seq) return state;
      return {
        ...state,
        command: {
          ...state.command,
          state: "success",
          message: action.message,
        },
      };
    }

    case "command/failed": {
      if (!state.command || state.command.seq !== action.seq) return state;
      return {
        ...state,
        command: {
          ...state.command,
          state: "error",
          message: action.message,
        },
      };
    }

    case "search/open":
      return { ...state, searchOpen: action.open };

    case "search/changed":
      return { ...state, searchQuery: action.query };

    case "confirm/show":
      return {
        ...state,
        confirmation: {
          command: action.command,
          message: action.message,
          payload: action.payload,
        },
      };

    case "confirm/hide":
      return { ...state, confirmation: null };

    case "layout/resized":
      return { ...state, layoutWidth: action.width, layoutHeight: action.height };

    case "settings/loaded":
      return {
        ...state,
        readOnly: action.readOnly,
        noColor: action.noColor,
        reducedMotion: action.reducedMotion,
      };

    case "notification/push": {
      const note = {
        id: `${Date.now()}-${state.notifications.length}`,
        severity: action.severity,
        message: action.message,
        at: Date.now(),
      };
      return {
        ...state,
        notifications: [...state.notifications, note].slice(-MAX_NOTIFICATIONS),
      };
    }

    case "notification/expire":
      return {
        ...state,
        notifications: state.notifications.filter((n) => n.id !== action.id),
      };

    default:
      return state;
  }
}

function mergeUnique(existing: EventPayload[], incoming: EventPayload[]): EventPayload[] {
  if (incoming.length === 0) return existing;
  const seen = new Set(existing.map((e) => e.id));
  const merged = [...existing];
  let appended = 0;
  for (const ev of incoming) {
    if (!seen.has(ev.id)) {
      merged.push(ev);
      seen.add(ev.id);
      appended++;
    }
  }
  if (appended === 0) return existing;
  // Always sort: SSE may deliver out-of-order during reconnect catch-up,
  // and the secondary `id.localeCompare` keeps ties deterministic so
  // identical timestamps produce a stable view across renders.
  merged.sort((a, b) => {
    const cmp = a.timestamp.localeCompare(b.timestamp);
    return cmp !== 0 ? cmp : a.id.localeCompare(b.id);
  });
  return merged;
}

export class Store {
  private current: AppState;
  private listeners = new Set<(state: AppState) => void>();

  constructor(initial: AppState = initialState()) {
    this.current = initial;
  }

  getState(): AppState {
    return this.current;
  }

  dispatch(action: Action): void {
    const next = reducer(this.current, action);
    if (next === this.current) return;
    this.current = next;
    for (const listener of this.listeners) {
      listener(this.current);
    }
  }

  subscribe(listener: (state: AppState) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
}
