/**
 * Pure render functions: `(state) -> Frame`. Each view returns rows of
 * `CellSpan` arrays so the adapter knows how to colorize them.
 *
 * Views never import OpenTUI directly — that decoupling lets us assert
 * against rendered frames in tests without a real terminal.
 */

import type { CellSpan, Frame, Theme } from "../render/adapter.ts";
import { buildFrame } from "../render/adapter.ts";
import type { AppState, ViewName } from "../state/store.ts";
import {
  activeAgentCount,
  eventsForSelectedIssue,
  filteredEvents,
  filteredIssues,
  isControlEnabled,
  maxAgents,
  pollingPaused,
  selectedIssue,
  sortedIssues,
  tokensPerSecond,
  tokensTotal,
} from "../state/selectors.ts";
import { redact } from "../redaction/redact.ts";
import {
  formatRuntime,
  formatTokens,
  pad,
  relativeTime,
  truncate,
} from "./format.ts";

const NAV_LABELS: { key: string; view: ViewName; label: string }[] = [
  { key: "1", view: "overview", label: "Overview" },
  { key: "2", view: "issues", label: "Issues" },
  { key: "3", view: "live", label: "Live agent" },
  { key: "4", view: "controls", label: "Controls" },
  { key: "5", view: "analytics", label: "Analytics" },
  { key: "6", view: "logs", label: "Logs" },
  { key: "7", view: "config", label: "Config" },
  { key: "8", view: "help", label: "Help" },
];

export function renderApp(state: AppState, theme: Theme): Frame {
  const width = Math.max(state.layoutWidth, 40);
  const height = Math.max(state.layoutHeight, 12);
  const headerRows = renderHeader(state, theme, width);
  const navRows = renderNavBar(state, theme, width);
  const bodyRows = renderBody(state, theme, width, height - headerRows.length - navRows.length - 2);
  const footer = renderFooter(state);
  const modal = renderModal(state);

  const allRows = [...headerRows, ...navRows, ...bodyRows];
  return buildFrame(allRows, width, height, { footer, modal });
}

function renderHeader(state: AppState, theme: Theme, width: number): CellSpan[][] {
  const status = state.health?.status ?? "?";
  const repo = state.health?.repo ?? "?";
  const connection = state.connection;
  const paused = pollingPaused(state);
  const readOnly = state.readOnly;

  const titleRow: CellSpan[] = [
    { text: "▌ ", fg: theme.primary, bold: true },
    { text: "Symphony", bold: true, fg: theme.foreground },
    { text: " · ", fg: theme.muted },
    { text: `${repo}`, fg: theme.foreground },
    { text: "   ", fg: theme.muted },
    { text: `[${connection}]`, fg: connectionColor(theme, connection) },
    { text: paused ? "  PAUSED" : "", fg: theme.warning, bold: true },
    { text: readOnly ? "  READ-ONLY" : "", fg: theme.danger, bold: true },
  ];

  const summaryRow: CellSpan[] = [
    { text: " ", fg: theme.foreground },
    { text: `Status: `, fg: theme.muted },
    { text: state.state?.status ?? "?", fg: theme.foreground },
    { text: "  Agents: ", fg: theme.muted },
    {
      text: `${activeAgentCount(state)}/${maxAgents(state)}`,
      fg: theme.foreground,
      bold: true,
    },
    { text: "  Tokens: ", fg: theme.muted },
    { text: formatTokens(tokensTotal(state)), fg: theme.foreground },
    { text: "  tok/s: ", fg: theme.muted },
    { text: tokensPerSecond(state).toFixed(1), fg: theme.foreground },
    { text: "  Buffer: ", fg: theme.muted },
    { text: `${state.events.length}`, fg: theme.foreground },
  ];

  return [titleRow, summaryRow, blankRow(width)];
}

function renderNavBar(state: AppState, theme: Theme, _width: number): CellSpan[][] {
  const cells: CellSpan[] = [{ text: " ", fg: theme.foreground }];
  for (const item of NAV_LABELS) {
    const active = state.view === item.view;
    cells.push({
      text: ` ${item.key} ${item.label} `,
      fg: active ? theme.badgeFg : theme.foreground,
      bg: active ? theme.primary : undefined,
      bold: active,
    });
    cells.push({ text: " ", fg: theme.muted });
  }
  return [cells];
}

function renderBody(state: AppState, theme: Theme, width: number, available: number): CellSpan[][] {
  if (available <= 0) {
    return [[{ text: "(terminal too small)", fg: theme.warning, bold: true }]];
  }
  switch (state.view) {
    case "overview":
      return renderOverview(state, theme, width, available);
    case "issues":
      return renderIssues(state, theme, width, available);
    case "live":
      return renderLiveAgent(state, theme, width, available);
    case "controls":
      return renderControls(state, theme, width, available);
    case "analytics":
      return renderAnalytics(state, theme, width, available);
    case "logs":
      return renderLogs(state, theme, width, available);
    case "config":
      return renderConfig(state, theme, width, available);
    case "help":
      return renderHelp(state, theme, width, available);
  }
}

function renderOverview(state: AppState, theme: Theme, width: number, available: number): CellSpan[][] {
  const rows: CellSpan[][] = [];

  rows.push(sectionTitle("Overview", theme));

  const counts = state.state?.counts ?? {};
  const polling = state.state?.polling ?? {};

  rows.push([
    { text: "  Polling: ", fg: theme.muted },
    {
      text: polling.paused ? "paused" : polling.checking ? "checking" : "idle",
      fg: polling.paused ? theme.warning : theme.success,
      bold: true,
    },
    { text: "    Next poll in: ", fg: theme.muted },
    { text: pollingCountdown(polling.next_poll_in_ms), fg: theme.foreground },
    { text: "    Interval: ", fg: theme.muted },
    {
      text:
        typeof polling.poll_interval_ms === "number" && polling.poll_interval_ms > 0
          ? `${Math.round(polling.poll_interval_ms / 1000)}s`
          : "?",
      fg: theme.foreground,
    },
  ]);

  rows.push(blankRow(width));

  const fallback = { fg: theme.foreground };
  rows.push([
    { text: "  ", fg: theme.foreground },
    badge("Running", counts["running"] ?? 0, theme.state.running ?? fallback, theme),
    badge("Retrying", counts["retrying"] ?? 0, theme.state.retrying ?? theme.severity.warning ?? fallback, theme),
    badge("Review", counts["review"] ?? 0, theme.state.review ?? fallback, theme),
    badge("Failed", counts["failed"] ?? 0, theme.state.failed ?? fallback, theme),
    badge("Blocked", counts["blocked"] ?? 0, theme.state.blocked ?? fallback, theme),
  ]);

  rows.push(blankRow(width));

  // Top active agents
  rows.push(sectionTitle("Top active agents", theme));
  const running = state.state?.running ?? [];
  if (running.length === 0) {
    rows.push([{ text: "  (no agents currently running)", fg: theme.muted }]);
  } else {
    for (const entry of running.slice(0, 5)) {
      rows.push([
        { text: "  ", fg: theme.foreground },
        { text: pad(entry.issue_identifier ?? "?", 10), fg: theme.foreground, bold: true },
        { text: pad(entry.state ?? "", 10), fg: stateFg(theme, entry.state) },
        { text: pad(formatRuntime(entry.runtime_seconds), 10), fg: theme.foreground },
        {
          text: pad(formatTokens(entry.tokens?.total_tokens ?? 0), 10, true),
          fg: theme.foreground,
        },
        {
          text: " " + truncate(entry.last_message ?? entry.last_event ?? "", Math.max(10, width - 50)),
          fg: theme.muted,
        },
      ]);
    }
  }

  rows.push(blankRow(width));

  // Recent warnings/errors
  rows.push(sectionTitle("Recent warnings & errors", theme));
  const recent = state.events.filter((e) => e.severity !== "debug" && e.severity !== "info").slice(-5);
  if (recent.length === 0) {
    rows.push([{ text: "  (no recent warnings)", fg: theme.muted }]);
  } else {
    for (const ev of recent) {
      rows.push(eventRow(ev, theme, width, "  "));
    }
  }

  return clipRows(rows, available);
}

function renderIssues(state: AppState, theme: Theme, width: number, available: number): CellSpan[][] {
  const rows: CellSpan[][] = [];
  rows.push(sectionTitle(`Issues (source: ${state.issuesSource ?? "snapshot"})`, theme));

  if (state.searchOpen) {
    rows.push([
      { text: "  Search: ", fg: theme.muted },
      { text: state.searchQuery, fg: theme.foreground, bold: true },
      { text: "▌", fg: theme.primary },
    ]);
  }

  const visible = sortedIssues(filteredIssues(state));

  if (visible.length === 0) {
    rows.push([{ text: "  (no Symphony-managed issues)", fg: theme.muted }]);
    return clipRows(rows, available);
  }

  rows.push([
    { text: "  ", fg: theme.foreground },
    { text: pad("Issue", 10), fg: theme.muted, bold: true },
    { text: pad("State", 10), fg: theme.muted, bold: true },
    { text: pad("Agent", 9), fg: theme.muted, bold: true },
    { text: pad("Worker", 8), fg: theme.muted, bold: true },
    { text: pad("Runtime", 9), fg: theme.muted, bold: true },
    { text: pad("Turns", 6, true), fg: theme.muted, bold: true },
    { text: pad("Tokens", 9, true), fg: theme.muted, bold: true },
    { text: " Title", fg: theme.muted, bold: true },
  ]);

  for (const issue of visible) {
    const isSelected = state.selectedIssueId === issue.issue_id;
    rows.push([
      { text: isSelected ? "▶ " : "  ", fg: theme.primary, bold: isSelected },
      { text: pad(issue.issue_identifier ?? "?", 10), fg: theme.foreground, bold: isSelected },
      { text: pad(issue.state ?? "?", 10), fg: stateFg(theme, issue.state) },
      { text: pad(issue.agent_state ?? "-", 9), fg: stateFg(theme, issue.agent_state) },
      { text: pad(issue.worker_host ?? "local", 8), fg: theme.muted },
      { text: pad(formatRuntime(issue.runtime_seconds ?? null), 9), fg: theme.foreground },
      { text: pad(issue.turn_count ?? 0, 6, true), fg: theme.foreground },
      { text: pad(formatTokens(issue.tokens?.total_tokens), 9, true), fg: theme.foreground },
      { text: " " + truncate(issue.title ?? "", Math.max(10, width - 70)), fg: theme.muted },
    ]);
  }

  return clipRows(rows, available);
}

function renderLiveAgent(state: AppState, theme: Theme, width: number, available: number): CellSpan[][] {
  const rows: CellSpan[][] = [];
  const issue = selectedIssue(state);

  rows.push(sectionTitle("Live agent", theme));

  if (!issue) {
    rows.push([{ text: "  (select an issue from the Issues view)", fg: theme.muted }]);
    return clipRows(rows, available);
  }

  rows.push([
    { text: "  Issue: ", fg: theme.muted },
    { text: issue.issue_identifier ?? "?", fg: theme.foreground, bold: true },
    { text: "  State: ", fg: theme.muted },
    { text: issue.state ?? "?", fg: stateFg(theme, issue.state) },
    { text: "  Agent: ", fg: theme.muted },
    { text: issue.agent_state ?? "?", fg: stateFg(theme, issue.agent_state) },
    { text: "  Worker: ", fg: theme.muted },
    { text: issue.worker_host ?? "local", fg: theme.foreground },
  ]);

  rows.push([
    { text: "  Branch: ", fg: theme.muted },
    { text: issue.branch ?? "(unknown)", fg: theme.foreground },
    { text: "  Workspace: ", fg: theme.muted },
    {
      text: truncate(issue.workspace_path ?? "(unknown)", Math.max(20, width - 40)),
      fg: theme.foreground,
    },
  ]);

  rows.push([
    { text: "  PR: ", fg: theme.muted },
    { text: issue.pr_url ?? "(none)", fg: theme.foreground },
    { text: "  Tokens: ", fg: theme.muted },
    {
      text: `${formatTokens(issue.tokens?.total_tokens)} (in ${formatTokens(issue.tokens?.input_tokens)} / out ${formatTokens(issue.tokens?.output_tokens)})`,
      fg: theme.foreground,
    },
  ]);

  rows.push(blankRow(width));
  rows.push(sectionTitle("Stream", theme));

  // Reuse `eventsForSelectedIssue` so events that carry only `issue_id`
  // (e.g. the orchestrator's `:agent_stopped` audit emit) still appear
  // in the per-issue stream. Filtering on `issue_identifier` alone
  // dropped real control feedback.
  const streamEvents = eventsForSelectedIssue(state).slice(-Math.max(1, available - 8));

  if (streamEvents.length === 0) {
    rows.push([{ text: "  (no events for this issue yet)", fg: theme.muted }]);
  } else {
    for (const ev of streamEvents) {
      rows.push(eventRow(ev, theme, width, "  "));
    }
  }

  return clipRows(rows, available);
}

function renderControls(state: AppState, theme: Theme, width: number, available: number): CellSpan[][] {
  const rows: CellSpan[][] = [];
  rows.push(sectionTitle("Controls", theme));
  rows.push([
    { text: "  Mode: ", fg: theme.muted },
    {
      text: isControlEnabled(state) ? "control-enabled" : "read-only",
      fg: isControlEnabled(state) ? theme.success : theme.warning,
      bold: true,
    },
  ]);

  rows.push(blankRow(width));

  const items: { key: string; label: string; needsSelection: boolean; destructive?: boolean }[] = [
    { key: "r", label: "Refresh now", needsSelection: false },
    { key: "p", label: "Pause polling", needsSelection: false },
    { key: "u", label: "Resume polling", needsSelection: false },
    { key: "d", label: "Dispatch selected", needsSelection: true },
    { key: "s", label: "Stop selected", needsSelection: true, destructive: true },
    { key: "R", label: "Retry selected", needsSelection: true, destructive: true },
    { key: "b", label: "Block / unblock selected", needsSelection: true, destructive: true },
  ];

  const issue = selectedIssue(state);

  for (const item of items) {
    const enabled = !item.needsSelection || !!issue;
    const fg = enabled ? theme.foreground : theme.muted;
    const keyFg = enabled
      ? item.destructive
        ? theme.danger
        : theme.primary
      : theme.muted;
    rows.push([
      { text: "  [", fg: theme.muted },
      { text: item.key, fg: keyFg, bold: true },
      { text: "] ", fg: theme.muted },
      { text: item.label, fg },
      {
        text: enabled ? "" : "  (select an issue first)",
        fg: theme.muted,
      },
    ]);
  }

  rows.push(blankRow(width));

  if (state.command) {
    const fg =
      state.command.state === "success"
        ? theme.success
        : state.command.state === "error"
          ? theme.danger
          : theme.warning;
    rows.push([
      { text: "  Last command: ", fg: theme.muted },
      { text: state.command.command, fg: theme.foreground, bold: true },
      { text: "  ·  ", fg: theme.muted },
      { text: state.command.state, fg, bold: true },
      { text: state.command.message ? `  ·  ${state.command.message}` : "", fg },
    ]);
  }

  return clipRows(rows, available);
}

function renderAnalytics(state: AppState, theme: Theme, width: number, available: number): CellSpan[][] {
  const rows: CellSpan[][] = [];
  rows.push(sectionTitle("Analytics", theme));

  if (!state.analytics) {
    rows.push([{ text: "  (waiting for analytics payload)", fg: theme.muted }]);
    return clipRows(rows, available);
  }

  const m = state.analytics.metrics as Record<string, any>;
  const source = state.analytics.source;

  if (source && source.history_loaded === false) {
    rows.push([
      { text: "  ⚠ ", fg: theme.warning, bold: true },
      { text: "history not loaded — metrics reflect current snapshot only", fg: theme.warning },
    ]);
  }

  if (source) {
    rows.push([
      { text: "  Source: ", fg: theme.muted },
      { text: source.mode, fg: theme.foreground, bold: true },
      { text: "  Window: ", fg: theme.muted },
      { text: `${source.window_seconds}s`, fg: theme.foreground },
      { text: "  Events: ", fg: theme.muted },
      { text: `${source.event_count}`, fg: theme.foreground },
    ]);
  }

  const cap = m.agent_capacity ?? {};
  const tokens = m.tokens ?? {};
  const failures = m.failures ?? {};
  const runtime = m.runtime ?? {};

  rows.push(blankRow(width));
  rows.push([
    { text: "  Utilization: ", fg: theme.muted },
    { text: `${cap.running ?? 0}/${cap.max ?? 0}`, fg: theme.foreground, bold: true },
    { text: `  (${((cap.utilization ?? 0) * 100).toFixed(1)}%)`, fg: theme.foreground },
  ]);

  rows.push([
    { text: "  Tokens: ", fg: theme.muted },
    { text: `${formatTokens(tokens.total_tokens)} `, fg: theme.foreground, bold: true },
    { text: `tok/s ${tokens.tokens_per_second ?? 0}  `, fg: theme.foreground },
    { text: `(in ${formatTokens(tokens.input_tokens)} / out ${formatTokens(tokens.output_tokens)})`, fg: theme.muted },
  ]);

  rows.push([
    { text: "  Failures: ", fg: theme.muted },
    { text: `failed=${failures.agent_failed ?? 0} `, fg: theme.danger },
    { text: `timed_out=${failures.agent_timed_out ?? 0} `, fg: theme.danger },
    { text: `stalled=${failures.agent_stalled ?? 0} `, fg: theme.warning },
    { text: `retries=${failures.retry_scheduled ?? 0}`, fg: theme.foreground },
  ]);

  rows.push([
    { text: "  Runtime: ", fg: theme.muted },
    { text: `avg=${formatRuntime(runtime.average_seconds)} `, fg: theme.foreground },
    { text: `p50=${formatRuntime(runtime.p50_seconds)} `, fg: theme.foreground },
    { text: `p95=${formatRuntime(runtime.p95_seconds)}`, fg: theme.foreground },
  ]);

  rows.push(blankRow(width));
  rows.push(sectionTitle("Top token consumers", theme));
  const top: any[] = m.top_token_consumers ?? [];
  if (top.length === 0) {
    rows.push([{ text: "  (none)", fg: theme.muted }]);
  } else {
    for (const t of top) {
      rows.push([
        { text: "  ", fg: theme.foreground },
        { text: pad(t.issue_identifier ?? t.issue_id ?? "?", 14), fg: theme.foreground },
        { text: pad(formatTokens(t.total_tokens), 10, true), fg: theme.foreground },
      ]);
    }
  }

  return clipRows(rows, available);
}

function renderLogs(state: AppState, theme: Theme, width: number, available: number): CellSpan[][] {
  const rows: CellSpan[][] = [];
  rows.push(sectionTitle(`Events (${state.follow ? "follow" : "paused"})`, theme));
  rows.push([
    { text: "  Filter: ", fg: theme.muted },
    { text: `type=${state.eventFilter.type ?? "*"}`, fg: theme.foreground },
    { text: `  severity=${state.eventFilter.severity ?? "*"}`, fg: theme.foreground },
    { text: `  q="${state.eventFilter.query}"`, fg: theme.foreground },
  ]);

  const events = filteredEvents(state).slice(-Math.max(1, available - 4));
  if (events.length === 0) {
    rows.push([{ text: "  (no events match the filter)", fg: theme.muted }]);
  } else {
    for (const ev of events) {
      rows.push(eventRow(ev, theme, width, "  "));
    }
  }
  return clipRows(rows, available);
}

function renderConfig(state: AppState, theme: Theme, width: number, available: number): CellSpan[][] {
  const rows: CellSpan[][] = [];
  rows.push(sectionTitle("Configuration", theme));

  rows.push([
    { text: "  Backend URL: ", fg: theme.muted },
    {
      text: state.health?.server
        ? `http://${state.health.server.host ?? "?"}:${state.health.server.port ?? "?"}`
        : "?",
      fg: theme.foreground,
    },
  ]);

  rows.push([
    { text: "  Repo: ", fg: theme.muted },
    { text: state.health?.repo ?? "?", fg: theme.foreground },
  ]);

  rows.push([
    { text: "  Control: ", fg: theme.muted },
    {
      text: state.health?.capabilities?.control ? "enabled" : "disabled",
      fg: state.health?.capabilities?.control ? theme.success : theme.warning,
      bold: true,
    },
    { text: "  Read-only: ", fg: theme.muted },
    { text: state.readOnly ? "yes" : "no", fg: state.readOnly ? theme.warning : theme.success },
  ]);

  rows.push([
    { text: "  Events stream: ", fg: theme.muted },
    {
      text: state.health?.capabilities?.events_stream ? "yes" : "no",
      fg: state.health?.capabilities?.events_stream ? theme.success : theme.warning,
    },
    { text: "  Analytics: ", fg: theme.muted },
    {
      text: state.health?.capabilities?.analytics ? "yes" : "no",
      fg: state.health?.capabilities?.analytics ? theme.success : theme.warning,
    },
  ]);

  rows.push([
    { text: "  Connection: ", fg: theme.muted },
    { text: state.connection, fg: connectionColor(theme, state.connection) },
    { text: state.connectionMessage ? `  (${state.connectionMessage})` : "", fg: theme.muted },
  ]);

  rows.push(blankRow(width));
  rows.push([{ text: "  Secrets are never displayed in this view.", fg: theme.muted }]);

  return clipRows(rows, available);
}

function renderHelp(_state: AppState, theme: Theme, _width: number, available: number): CellSpan[][] {
  const lines: [string, string][] = [
    ["q", "quit"],
    ["?", "help"],
    ["1-8", "switch view"],
    ["tab / shift+tab", "next/previous view"],
    ["/", "search (Issues)"],
    ["enter", "inspect selected"],
    ["r", "refresh now"],
    ["p / u", "pause / resume polling"],
    ["d", "dispatch selected issue"],
    ["s", "stop selected (confirmation required)"],
    ["R (shift+r)", "retry selected (confirmation required)"],
    ["b", "block / unblock selected (confirmation required)"],
    ["esc", "close modal / search"],
  ];

  const rows: CellSpan[][] = [];
  rows.push(sectionTitle("Keybindings", theme));
  for (const [key, label] of lines) {
    rows.push([
      { text: "  ", fg: theme.foreground },
      { text: pad(key, 18), fg: theme.primary, bold: true },
      { text: label, fg: theme.foreground },
    ]);
  }
  rows.push(blankRow(80));
  rows.push([
    { text: "  Tip: destructive actions always require confirmation.", fg: theme.muted },
  ]);
  return clipRows(rows, available);
}

function renderFooter(state: AppState): string {
  const conn = state.connection;
  const ro = state.readOnly ? " · read-only" : "";
  const view = NAV_LABELS.find((n) => n.view === state.view)?.label ?? state.view;
  return `Symphony · ${view} · ${conn}${ro} · q quit · ? help`;
}

function renderModal(state: AppState): string | null {
  if (!state.confirmation) return null;
  const lines = [
    "Confirm action",
    "",
    state.confirmation.message,
    "",
    "[y] confirm   [n] cancel",
  ];
  return lines.join("\n");
}

function eventRow(event: { type: string; severity: string; message?: string | null; issue_identifier?: string | null; timestamp: string }, theme: Theme, _width: number, prefix = ""): CellSpan[] {
  const sev = (theme.severity as Record<string, any>)[event.severity] ?? theme.severity.info;
  return [
    { text: prefix, fg: theme.foreground },
    { text: pad(relativeTime(event.timestamp), 10), fg: theme.muted },
    { text: pad((event.severity ?? "info").toUpperCase(), 8), fg: sev.fg, bold: !!sev.bold },
    { text: pad(event.type, 24), fg: theme.foreground },
    { text: pad(event.issue_identifier ?? "-", 10), fg: theme.muted },
    { text: " " + redact(event.message ?? ""), fg: theme.foreground },
  ];
}

function pollingCountdown(ms: number | null | undefined): string {
  if (typeof ms !== "number" || ms < 0) return "?";
  if (ms === 0) return "now";
  return `${Math.ceil(ms / 1000)}s`;
}

function badge(label: string, value: number | string, palette: { fg: string; bold?: boolean }, theme: Theme): CellSpan {
  const text = ` ${label} ${value} `;
  return { text, fg: palette.fg, bg: theme.background, bold: !!palette.bold };
}

function sectionTitle(label: string, theme: Theme): CellSpan[] {
  return [
    { text: " ", fg: theme.foreground },
    { text: `── ${label} `, fg: theme.muted, bold: true },
  ];
}

function connectionColor(theme: Theme, connection: string): string {
  switch (connection) {
    case "connected":
      return theme.success;
    case "reconnecting":
    case "connecting":
      return theme.warning;
    case "disconnected":
    case "backend_unavailable":
    case "error":
      return theme.danger;
    default:
      return theme.foreground;
  }
}

function stateFg(theme: Theme, state?: string | null): string {
  if (!state) return theme.foreground;
  return (theme.state as Record<string, any>)[state.toLowerCase()]?.fg ?? theme.foreground;
}

function blankRow(_width: number): CellSpan[] {
  return [{ text: " " }];
}

function clipRows(rows: CellSpan[][], available: number): CellSpan[][] {
  if (rows.length <= available) return rows;
  return rows.slice(0, available);
}
