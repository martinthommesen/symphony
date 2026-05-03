/**
 * Tolerant runtime validators for backend payloads. Unknown fields are
 * preserved as-is; missing required fields trigger `null` returns so
 * callers can degrade gracefully. The reducer must not crash on unknown
 * event types.
 */

import type {
  AnalyticsPayload,
  EventPayload,
  EventsPayload,
  HealthPayload,
  IssueProjection,
  IssuesListPayload,
  RetryEntry,
  RunningEntry,
  Severity,
  StatePayload,
  TokenTotals,
} from "./types.ts";

const SEVERITIES: ReadonlyArray<Severity> = ["debug", "info", "warning", "error"];

export function asObject(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

export function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

export function asString(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

export function asNullableString(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  return typeof value === "string" ? value : null;
}

export function asNumber(value: unknown, fallback = 0): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  }
  return fallback;
}

export function asNullableNumber(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "number" && Number.isFinite(value)) return value;
  return null;
}

export function asBoolean(value: unknown, fallback = false): boolean {
  if (typeof value === "boolean") return value;
  return fallback;
}

export function asSeverity(value: unknown): Severity {
  return SEVERITIES.includes(value as Severity) ? (value as Severity) : "info";
}

export function asStringArray(value: unknown): string[] {
  return asArray(value).filter((v): v is string => typeof v === "string");
}

export function parseEvent(value: unknown): EventPayload | null {
  const obj = asObject(value);
  if (!obj || typeof obj.id !== "string" || typeof obj.type !== "string" ||
      typeof obj.timestamp !== "string") {
    return null;
  }

  return {
    id: obj.id,
    type: obj.type,
    severity: asSeverity(obj.severity),
    timestamp: obj.timestamp,
    issue_id: asNullableString(obj.issue_id),
    issue_identifier: asNullableString(obj.issue_identifier),
    issue_number: asNullableNumber(obj.issue_number),
    session_id: asNullableString(obj.session_id),
    worker_host: asNullableString(obj.worker_host),
    workspace_path: asNullableString(obj.workspace_path),
    message: asNullableString(obj.message),
    data: asObject(obj.data) ?? {},
  };
}

export function parseEventsPayload(value: unknown): EventsPayload {
  const obj = asObject(value) ?? {};
  const events = asArray(obj.events).map(parseEvent).filter(
    (e): e is EventPayload => e !== null
  );

  return {
    generated_at: asString(obj.generated_at, ""),
    events,
    count: asNumber(obj.count, events.length),
  };
}

export function parseIssue(value: unknown): IssueProjection | null {
  const obj = asObject(value);
  if (!obj) return null;

  return {
    issue_id: asNullableString(obj.issue_id) ?? undefined,
    issue_identifier: asNullableString(obj.issue_identifier) ?? undefined,
    issue_number: asNullableNumber(obj.issue_number),
    title: asNullableString(obj.title),
    state: asNullableString(obj.state) ?? undefined,
    labels: asStringArray(obj.labels),
    assignee_id: asNullableString(obj.assignee_id),
    priority: asNullableNumber(obj.priority),
    branch: asNullableString(obj.branch),
    pr_url: asNullableString(obj.pr_url),
    created_at: asNullableString(obj.created_at),
    updated_at: asNullableString(obj.updated_at),
    agent_state: asNullableString(obj.agent_state) ?? undefined,
    worker_host: asNullableString(obj.worker_host),
    workspace_path: asNullableString(obj.workspace_path),
    runtime_seconds: asNullableNumber(obj.runtime_seconds),
    turn_count: asNullableNumber(obj.turn_count),
    tokens: asObject(obj.tokens) ?? undefined,
    last_event: asNullableString(obj.last_event),
    last_error: asNullableString(obj.last_error),
  };
}

export function parseIssuesList(value: unknown): IssuesListPayload {
  const obj = asObject(value) ?? {};
  const issues = asArray(obj.issues).map(parseIssue).filter(
    (i): i is IssueProjection => i !== null
  );
  const source = asObject(obj.source);

  return {
    generated_at: asString(obj.generated_at, ""),
    source: source
      ? { mode: asString(source.mode, "unknown"), count: asNumber(source.count, issues.length) }
      : { mode: "unknown", count: issues.length },
    issues,
  };
}

export function parseRunningEntry(value: unknown): RunningEntry | null {
  const obj = asObject(value);
  if (!obj) return null;
  return {
    issue_id: asNullableString(obj.issue_id) ?? undefined,
    issue_identifier: asNullableString(obj.issue_identifier) ?? undefined,
    state: asNullableString(obj.state) ?? undefined,
    worker_host: asNullableString(obj.worker_host),
    workspace_path: asNullableString(obj.workspace_path),
    session_id: asNullableString(obj.session_id),
    turn_count: asNullableNumber(obj.turn_count) ?? undefined,
    last_event: asNullableString(obj.last_event),
    last_message: asNullableString(obj.last_message),
    started_at: asNullableString(obj.started_at),
    last_event_at: asNullableString(obj.last_event_at),
    runtime_seconds: asNullableNumber(obj.runtime_seconds) ?? undefined,
    tokens: (asObject(obj.tokens) ?? undefined) as TokenTotals | undefined,
  };
}

export function parseRetryEntry(value: unknown): RetryEntry | null {
  const obj = asObject(value);
  if (!obj) return null;
  return {
    issue_id: asNullableString(obj.issue_id) ?? undefined,
    issue_identifier: asNullableString(obj.issue_identifier) ?? undefined,
    attempt: asNullableNumber(obj.attempt) ?? undefined,
    due_at: asNullableString(obj.due_at),
    error: asNullableString(obj.error),
    worker_host: asNullableString(obj.worker_host),
    workspace_path: asNullableString(obj.workspace_path),
  };
}

export function parseState(value: unknown): StatePayload {
  const obj = asObject(value) ?? {};

  return {
    generated_at: asString(obj.generated_at, ""),
    status: asNullableString(obj.status) ?? "unknown",
    counts: (asObject(obj.counts) ?? {}) as Record<string, number>,
    running: asArray(obj.running)
      .map(parseRunningEntry)
      .filter((entry): entry is RunningEntry => entry !== null),
    retrying: asArray(obj.retrying)
      .map(parseRetryEntry)
      .filter((entry): entry is RetryEntry => entry !== null),
    codex_totals: asObject(obj.codex_totals) ?? {},
    rate_limits: obj.rate_limits ?? null,
    polling: asObject(obj.polling) ?? {},
    agent_capacity: asObject(obj.agent_capacity) ?? {},
    tokens: asObject(obj.tokens) ?? {},
    recent_events: asArray(obj.recent_events)
      .map(parseEvent)
      .filter((e): e is EventPayload => e !== null),
    error: asObject(obj.error) as { code: string; message: string } | undefined,
  };
}

export function parseHealth(value: unknown): HealthPayload {
  const obj = asObject(value) ?? {};
  return {
    status: asString(obj.status, "ok") === "ok" ? "ok" : "degraded",
    version: asNullableString(obj.version) ?? undefined,
    repo: asNullableString(obj.repo) ?? null,
    server: (asObject(obj.server) ?? {}) as HealthPayload["server"],
    capabilities: (asObject(obj.capabilities) ?? {}) as HealthPayload["capabilities"],
    orchestrator: (asObject(obj.orchestrator) ?? {}) as HealthPayload["orchestrator"],
  };
}

export function parseAnalytics(value: unknown): AnalyticsPayload {
  const obj = asObject(value) ?? {};
  const source = asObject(obj.source);

  return {
    generated_at: asString(obj.generated_at, ""),
    source: source
      ? {
          mode: asString(source.mode, "unknown"),
          history_loaded: asBoolean(source.history_loaded, false),
          event_count: asNumber(source.event_count, 0),
          window_seconds: asNumber(source.window_seconds, 0),
        }
      : undefined,
    metrics: asObject(obj.metrics) ?? {},
  };
}
