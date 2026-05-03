/**
 * Glues the API client, SSE stream, store, and renderer together. The
 * bootstrap sequence is:
 *
 *   1. fetch /health (capabilities + control posture)
 *   2. dispatch initial state, issues, analytics, and recent events
 *   3. open SSE stream for live events
 *   4. attach renderer + key handler
 *
 * Every async path catches errors and dispatches `connection/changed` so
 * the UI always reflects the latest connection status.
 */

import { ApiClient, HttpError, NetworkError, TimeoutError } from "./api/client.ts";
import { SseClient } from "./api/sse.ts";
import type { SseStatus } from "./api/sse.ts";
import { Store, initialState } from "./state/store.ts";
import type { Action, AppState, ViewName } from "./state/store.ts";
import { selectedIssue, VIEW_NAMES } from "./state/selectors.ts";
import { renderApp } from "./views/render.ts";
import { DEFAULT_THEME, NO_COLOR_THEME } from "./render/adapter.ts";
import type { RenderAdapter } from "./render/adapter.ts";
import type { RuntimeConfig } from "./config.ts";

export interface AppOptions {
  client: ApiClient;
  sse: SseClient | null;
  adapter: RenderAdapter;
  config: RuntimeConfig;
  /** Override the polling interval for state/issues. */
  pollIntervalMs?: number;
}

export class App {
  private readonly store: Store;
  private readonly adapter: RenderAdapter;
  private readonly client: ApiClient;
  private sse: SseClient | null;
  private readonly config: RuntimeConfig;
  private readonly pollIntervalMs: number;
  private pollTimer: ReturnType<typeof setInterval> | null = null;
  private renderTimer: ReturnType<typeof setTimeout> | null = null;
  private dirty = true;
  private stopped = false;
  private commandSeq = 0;

  constructor(options: AppOptions) {
    this.client = options.client;
    this.sse = options.sse;
    this.adapter = options.adapter;
    this.config = options.config;
    this.pollIntervalMs = options.pollIntervalMs ?? 2_000;

    const initial = initialState({
      noColor: options.config.noColor,
      reducedMotion: options.config.reducedMotion,
      readOnly: !options.client.hasControlToken(),
      layoutWidth: options.adapter.size().width,
      layoutHeight: options.adapter.size().height,
    });

    this.store = new Store(initial);
    this.store.subscribe(() => {
      this.dirty = true;
      this.scheduleRender();
    });
  }

  async start(): Promise<void> {
    await this.adapter.start();
    this.adapter.on("key", (key) => this.handleKey(key));
    this.adapter.on("resize", (size) => this.dispatch({ type: "layout/resized", width: size.width, height: size.height }));

    this.dispatch({ type: "connection/changed", status: "connecting" });
    await this.refreshAll();

    if (this.sse) {
      this.sse.start();
    }

    this.pollTimer = setInterval(() => this.refreshAll().catch(() => {}), this.pollIntervalMs);
    this.scheduleRender();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.pollTimer) clearInterval(this.pollTimer);
    if (this.renderTimer) clearTimeout(this.renderTimer);
    if (this.sse) this.sse.stop();
    await this.adapter.stop();
  }

  store_(): Store {
    return this.store;
  }

  /**
   * Fetches health, state, issues, analytics, and recent events. Each call
   * is independent so a failure in one only affects that slice of state.
   */
  async refreshAll(): Promise<void> {
    if (this.stopped) return;

    await Promise.allSettled([
      this.refreshHealth(),
      this.refreshState(),
      this.refreshIssues(),
      this.refreshAnalytics(),
      this.refreshEvents(),
    ]);
  }

  /**
   * Hydrate the event ring from the backend so Logs/Live views are not
   * blank until the next SSE frame arrives. Polling reuses the same call
   * to backfill events the SSE stream might miss after a reconnect.
   */
  async refreshEvents(): Promise<void> {
    try {
      const payload = await this.client.events({ limit: 200 });
      this.dispatch({ type: "events/received", events: payload.events });
    } catch {
      // tolerate
    }
  }

  async refreshHealth(): Promise<void> {
    try {
      const health = await this.client.health();
      this.dispatch({ type: "health/received", health });
      this.dispatch({ type: "connection/changed", status: "connected" });
    } catch (err) {
      this.dispatch({
        type: "connection/changed",
        status: connectionFromError(err),
        message: errorMessage(err),
      });
    }
  }

  async refreshState(): Promise<void> {
    try {
      const state = await this.client.state();
      this.dispatch({ type: "state/received", state });
    } catch {
      // health refresh already updates connection status; do not double-report
    }
  }

  async refreshIssues(): Promise<void> {
    try {
      const payload = await this.client.issues();
      this.dispatch({ type: "issues/received", payload });
    } catch {
      // tolerate
    }
  }

  async refreshAnalytics(): Promise<void> {
    try {
      const payload = await this.client.analytics();
      this.dispatch({ type: "analytics/received", payload });
    } catch {
      // tolerate
    }
  }

  // --------------------------------------------------------------------------

  setSseStatus(status: SseStatus, info?: string): void {
    if (status === "connected") {
      this.dispatch({ type: "connection/changed", status: "connected" });
    } else if (status === "reconnecting") {
      this.dispatch({ type: "connection/changed", status: "reconnecting", message: info });
    } else if (status === "stopped") {
      this.dispatch({ type: "connection/changed", status: "disconnected", message: info });
    }
  }

  ingestEvent(event: import("./api/types.ts").EventPayload): void {
    this.dispatch({ type: "events/append", event });
  }

  // --------------------------------------------------------------------------
  // Key handling
  // --------------------------------------------------------------------------

  handleKey(key: { name: string; ctrl: boolean; shift: boolean; meta: boolean }): void {
    const state = this.store.getState();

    if (state.confirmation) {
      this.handleConfirmationKey(key);
      return;
    }

    if (state.searchOpen) {
      this.handleSearchKey(key);
      return;
    }

    if (key.name === "q") {
      void this.stop().then(
        () => process.exit(0),
        () => process.exit(1),
      );
      return;
    }

    if (key.name === "?") {
      this.dispatch({ type: "view/changed", view: "help" });
      return;
    }

    if (Object.prototype.hasOwnProperty.call(VIEW_NAMES, key.name)) {
      const target = VIEW_NAMES[key.name as keyof typeof VIEW_NAMES];
      if (target) this.dispatch({ type: "view/changed", view: target });
      return;
    }

    if (key.name === "tab") {
      const direction = key.shift ? -1 : 1;
      this.dispatch({ type: "view/changed", view: nextView(state.view, direction) });
      return;
    }

    if (key.name === "/" && state.view === "issues") {
      this.dispatch({ type: "search/open", open: true });
      return;
    }

    if (key.name === "return" || key.name === "enter") {
      // Enter inspects the selected issue: jump from any list view into
      // the live agent panel for the highlighted row. The Live and Logs
      // views ignore Enter (no inspectable subitem).
      if (state.view === "issues" || state.view === "overview" || state.view === "controls") {
        this.dispatch({ type: "view/changed", view: "live" });
      }
      return;
    }

    if (key.name === "r" && !key.shift && !key.ctrl) {
      void this.runCommand("refresh", {}, false);
      return;
    }

    if (key.name === "p") {
      void this.runCommand("pause", {}, false);
      return;
    }

    if (key.name === "u") {
      void this.runCommand("resume", {}, false);
      return;
    }

    const issue = selectedIssue(state);

    if (key.name === "d" && issue?.issue_identifier) {
      void this.runCommand("dispatch", { issue_identifier: issue.issue_identifier }, false);
      return;
    }

    if (key.name === "s" && issue?.issue_identifier) {
      this.dispatch({
        type: "confirm/show",
        command: "stop",
        message: `Stop agent for ${issue.issue_identifier}? This terminates the running task. Workspace stays.`,
        payload: { issue_identifier: issue.issue_identifier },
      });
      return;
    }

    if (key.name === "r" && key.shift && issue?.issue_identifier) {
      this.dispatch({
        type: "confirm/show",
        command: "retry",
        message: `Retry ${issue.issue_identifier}? Symphony status labels will be cleared so the orchestrator picks it up.`,
        payload: { issue_identifier: issue.issue_identifier },
      });
      return;
    }

    if (key.name === "b" && issue?.issue_identifier) {
      // Use the orchestrator-derived `state` (which the backend resolves
      // against the configured blocked_labels) instead of pattern-matching
      // a hardcoded label prefix. This stays correct when blocked_labels
      // is customised in WORKFLOW.md.
      const command = (issue.state ?? "").toLowerCase() === "blocked" ? "unblock" : "block";
      this.dispatch({
        type: "confirm/show",
        command,
        message: `${command === "block" ? "Block" : "Unblock"} ${issue.issue_identifier}? This toggles the blocked label on the tracker.`,
        payload: { issue_identifier: issue.issue_identifier },
      });
      return;
    }
  }

  private handleConfirmationKey(key: { name: string }): void {
    const state = this.store.getState();
    if (!state.confirmation) return;

    if (key.name === "y" || key.name === "return" || key.name === "enter") {
      const conf = state.confirmation;
      this.dispatch({ type: "confirm/hide" });
      void this.runCommand(conf.command, conf.payload, true);
    } else if (key.name === "n" || key.name === "escape" || key.name === "esc") {
      this.dispatch({ type: "confirm/hide" });
    }
  }

  private handleSearchKey(key: { name: string }): void {
    const state = this.store.getState();
    if (key.name === "escape" || key.name === "esc" || key.name === "return" || key.name === "enter") {
      this.dispatch({ type: "search/open", open: false });
      return;
    }
    if (key.name === "backspace") {
      this.dispatch({ type: "search/changed", query: state.searchQuery.slice(0, -1) });
      return;
    }
    if (key.name.length === 1) {
      this.dispatch({ type: "search/changed", query: state.searchQuery + key.name });
    }
  }

  // --------------------------------------------------------------------------

  async runCommand(command: string, params: Record<string, unknown>, _confirmed: boolean): Promise<void> {
    if (this.store.getState().readOnly && command !== "refresh") {
      // Surface the rejection via a notification rather than synthesising
      // a `command/failed` for a command we never started — otherwise the
      // command badge would jump between two unrelated rejected states.
      this.dispatch({
        type: "notification/push",
        severity: "error",
        message: `${command}: control disabled (read-only)`,
      });
      return;
    }

    const seq = ++this.commandSeq;
    this.dispatch({ type: "command/started", command, seq });

    try {
      const result = command === "refresh"
        ? await this.client.refresh()
        : await this.client.control(command, params);

      if (result.ok) {
        this.dispatch({ type: "command/succeeded", command, seq, message: "ok" });
        // Optimistically refresh state.
        void this.refreshAll();
      } else {
        this.dispatch({
          type: "command/failed",
          command,
          seq,
          message: `${result.error.code}: ${result.error.message}`,
        });
      }
    } catch (err) {
      this.dispatch({ type: "command/failed", command, seq, message: errorMessage(err) });
    }
  }

  // --------------------------------------------------------------------------

  private dispatch(action: Action): void {
    this.store.dispatch(action);
  }

  private scheduleRender(): void {
    if (this.renderTimer) return;
    const interval = this.config.reducedMotion ? 200 : 50;
    this.renderTimer = setTimeout(() => {
      this.renderTimer = null;
      if (!this.dirty) return;
      this.dirty = false;
      this.paint();
    }, interval);
  }

  private paint(): void {
    const state = this.store.getState();
    const theme = state.noColor ? NO_COLOR_THEME : DEFAULT_THEME;
    const frame = renderApp(state, theme);
    this.adapter.paint(frame);
  }
}

function nextView(current: ViewName, direction: 1 | -1): ViewName {
  const order: ViewName[] = ["overview", "issues", "live", "controls", "analytics", "logs", "config", "help"];
  const idx = order.indexOf(current);
  const next = (idx + direction + order.length) % order.length;
  return order[next] ?? "overview";
}

function connectionFromError(err: unknown): AppState["connection"] {
  if (err instanceof HttpError) return "error";
  if (err instanceof TimeoutError) return "reconnecting";
  if (err instanceof NetworkError) return "backend_unavailable";
  return "disconnected";
}

function errorMessage(err: unknown): string {
  if (err instanceof HttpError) return err.message;
  if (err instanceof TimeoutError) return "request timed out";
  if (err instanceof NetworkError) return err.message;
  return (err as { message?: string })?.message ?? String(err);
}
