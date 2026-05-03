/**
 * Wire types shared between the TUI and the Symphony backend. Names
 * mirror the JSON keys returned by `SymphonyElixirWeb.ObservabilityApiController`.
 *
 * All fields are optional unless the backend has a hard guarantee (which
 * is true only of `id`, `type`, `severity`, `timestamp` for events).
 * Other shapes are tolerated as `unknown` and parsed defensively.
 */

export type Severity = "debug" | "info" | "warning" | "error";

export interface HealthPayload {
  status: "ok" | "degraded";
  version?: string;
  repo?: string | null;
  server?: { host?: string; port?: number };
  capabilities?: {
    control?: boolean;
    events_stream?: boolean;
    analytics?: boolean;
    read_only?: boolean;
  };
  orchestrator?: { available?: boolean; paused?: boolean };
}

export interface PollingState {
  paused?: boolean;
  checking?: boolean;
  next_poll_in_ms?: number | null;
  poll_interval_ms?: number | null;
}

export interface AgentCapacity {
  max?: number;
  running?: number;
  available?: number;
  utilization?: number;
}

export interface RunningEntry {
  issue_id?: string;
  issue_identifier?: string;
  state?: string;
  worker_host?: string | null;
  workspace_path?: string | null;
  session_id?: string | null;
  turn_count?: number;
  last_event?: string | null;
  last_message?: string | null;
  started_at?: string | null;
  last_event_at?: string | null;
  runtime_seconds?: number;
  tokens?: TokenTotals;
}

export interface RetryEntry {
  issue_id?: string;
  issue_identifier?: string;
  attempt?: number;
  due_at?: string | null;
  error?: string | null;
  worker_host?: string | null;
  workspace_path?: string | null;
}

export interface TokenTotals {
  input_tokens?: number;
  output_tokens?: number;
  total_tokens?: number;
  tokens_per_second?: number;
}

export interface StatePayload {
  generated_at: string;
  status?: "running" | "paused" | string;
  counts?: Record<string, number>;
  running?: RunningEntry[];
  retrying?: RetryEntry[];
  codex_totals?: TokenTotals & { seconds_running?: number };
  rate_limits?: unknown;
  polling?: PollingState;
  agent_capacity?: AgentCapacity;
  tokens?: TokenTotals;
  recent_events?: EventPayload[];
  error?: { code: string; message: string };
}

export interface IssueProjection {
  issue_id?: string;
  issue_identifier?: string;
  issue_number?: number | null;
  title?: string | null;
  state?: string;
  labels?: string[];
  assignee_id?: string | null;
  priority?: number | null;
  branch?: string | null;
  pr_url?: string | null;
  created_at?: string | null;
  updated_at?: string | null;
  agent_state?: string;
  worker_host?: string | null;
  workspace_path?: string | null;
  runtime_seconds?: number | null;
  turn_count?: number | null;
  tokens?: TokenTotals;
  last_event?: string | null;
  last_error?: string | null;
}

export interface IssuesListPayload {
  generated_at: string;
  source?: { mode: string; count?: number };
  issues: IssueProjection[];
}

export interface EventPayload {
  id: string;
  type: string;
  severity: Severity;
  timestamp: string;
  issue_id?: string | null;
  issue_identifier?: string | null;
  issue_number?: number | null;
  session_id?: string | null;
  worker_host?: string | null;
  workspace_path?: string | null;
  message?: string | null;
  data?: Record<string, unknown>;
}

export interface EventsPayload {
  generated_at: string;
  events: EventPayload[];
  count: number;
}

export interface AnalyticsPayload {
  generated_at: string;
  source?: {
    mode: string;
    history_loaded: boolean;
    event_count: number;
    window_seconds: number;
  };
  metrics: Record<string, unknown>;
}

export interface ControlSuccess {
  ok: true;
  command: string;
  payload: Record<string, unknown>;
}

export interface ControlFailure {
  ok: false;
  error: { code: string; message: string };
}

export type ControlResult = ControlSuccess | ControlFailure;
