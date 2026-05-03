/**
 * Minimal SSE client. Reconnects with backoff, deduplicates by event id,
 * tolerates unknown event types, and parses redacted JSON payloads. Writes
 * directly to the provided callback rather than buffering.
 */

import { parseEvent } from "./schema.ts";
import type { EventPayload } from "./types.ts";
import { redactDeep } from "../redaction/redact.ts";

/** Maximum number of recently-seen event ids retained for de-duplication. */
const MAX_SEEN_IDS = 5_000;
/** How many of the oldest dedupe ids to evict once `MAX_SEEN_IDS` is exceeded. */
const SEEN_IDS_EVICTION_CHUNK = 1_000;

export type SseStatus =
  | "connecting"
  | "connected"
  | "reconnecting"
  | "disconnected"
  | "stopped";

export interface SseClientOptions {
  baseUrl: string;
  controlToken?: string | null;
  query?: Record<string, string>;
  onEvent: (event: EventPayload) => void;
  onStatus?: (status: SseStatus, info?: string) => void;
  fetchImpl?: typeof fetch;
  /** Initial reconnect delay in ms; doubles each failure up to maxDelayMs. */
  initialBackoffMs?: number;
  maxBackoffMs?: number;
  /** Tracks last seen event id so reconnect resumes via `?since=`. */
  resumeFromLastId?: boolean;
}

export class SseClient {
  private readonly options: Required<
    Omit<SseClientOptions, "onStatus" | "controlToken" | "query">
  > & {
    onStatus: (status: SseStatus, info?: string) => void;
    controlToken: string | null;
    query: Record<string, string>;
  };

  private abortController: AbortController | null = null;
  private stopped = false;
  private seen = new Set<string>();
  private lastEventId: string | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private currentBackoff: number;

  constructor(options: SseClientOptions) {
    this.options = {
      baseUrl: options.baseUrl.replace(/\/+$/, ""),
      controlToken: options.controlToken ?? null,
      query: options.query ?? {},
      onEvent: options.onEvent,
      onStatus: options.onStatus ?? (() => {}),
      fetchImpl: options.fetchImpl ?? fetch,
      initialBackoffMs: options.initialBackoffMs ?? 500,
      maxBackoffMs: options.maxBackoffMs ?? 10_000,
      resumeFromLastId: options.resumeFromLastId ?? true,
    };
    this.currentBackoff = this.options.initialBackoffMs;
  }

  start(): void {
    if (this.stopped) return;
    // Idempotent: a second `start()` while a connection or reconnect
    // is already in flight would otherwise spawn a parallel `connect()`
    // chain and double-deliver every event.
    if (this.abortController || this.reconnectTimer) return;
    void this.connect();
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    this.abortController?.abort();
    this.abortController = null;
    this.options.onStatus("stopped");
  }

  private async connect(): Promise<void> {
    this.options.onStatus("connecting");
    const query = { ...this.options.query };
    if (this.options.resumeFromLastId && this.lastEventId) {
      query.since = this.lastEventId;
    }
    const search = encodeQuery(query);
    const url = `${this.options.baseUrl}/api/v1/events/stream${search}`;

    const headers: Record<string, string> = { accept: "text/event-stream" };
    if (this.options.controlToken) {
      headers["authorization"] = `Bearer ${this.options.controlToken}`;
    }

    this.abortController = new AbortController();

    try {
      const response = await this.options.fetchImpl(url, {
        headers,
        signal: this.abortController.signal,
      });

      if (!response.ok || !response.body) {
        throw new Error(`SSE connect failed: ${response.status} ${response.statusText}`);
      }

      this.options.onStatus("connected");
      this.currentBackoff = this.options.initialBackoffMs;
      await this.consume(response.body);
    } catch (err) {
      if (this.stopped) return;
      this.options.onStatus("reconnecting", (err as Error).message);
      this.scheduleReconnect();
    }
  }

  private async consume(body: ReadableStream<Uint8Array>): Promise<void> {
    const reader = body.getReader();
    const decoder = new TextDecoder("utf-8");
    let buffer = "";

    while (!this.stopped) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      let separatorIndex = buffer.indexOf("\n\n");
      while (separatorIndex >= 0) {
        const frame = buffer.slice(0, separatorIndex);
        buffer = buffer.slice(separatorIndex + 2);
        this.handleFrame(frame);
        separatorIndex = buffer.indexOf("\n\n");
      }
    }

    if (!this.stopped) {
      this.options.onStatus("reconnecting", "stream closed");
      this.scheduleReconnect();
    }
  }

  private handleFrame(frame: string): void {
    if (!frame.trim()) return;

    let data = "";
    let id: string | null = null;

    for (const line of frame.split("\n")) {
      if (line.startsWith(":")) continue; // comment / heartbeat
      if (line.startsWith("data:")) data += line.slice(5).trimStart() + "\n";
      else if (line.startsWith("id:")) id = line.slice(3).trim();
    }

    if (!data) return;
    if (id && this.seen.has(id)) return;

    let payload: unknown;
    try {
      payload = JSON.parse(data.trimEnd());
    } catch {
      return;
    }

    const event = parseEvent(payload);
    if (!event) return;

    if (id) {
      this.seen.add(id);
      this.lastEventId = id;
      // Cap dedupe set size so it cannot grow unboundedly. When the
      // cap is hit, evict the oldest `SEEN_IDS_EVICTION_CHUNK` entries
      // in one pass — amortises the eviction cost over many adds.
      if (this.seen.size > MAX_SEEN_IDS) {
        const iter = this.seen.values();
        for (let i = 0; i < SEEN_IDS_EVICTION_CHUNK; i++) {
          const next = iter.next();
          if (next.done) break;
          this.seen.delete(next.value);
        }
      }
    }

    // Defense-in-depth redaction before delivery.
    this.options.onEvent(redactDeep(event));
  }

  private scheduleReconnect(): void {
    if (this.stopped) return;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    // ±25% jitter so a fleet of TUIs reconnecting after a server
    // restart doesn't fire in lockstep at every doubling step.
    const jitter = Math.random() * 0.5 + 0.75;
    const delay = Math.round(this.currentBackoff * jitter);
    this.currentBackoff = Math.min(this.currentBackoff * 2, this.options.maxBackoffMs);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      void this.connect();
    }, delay);
  }
}

function encodeQuery(filters: Record<string, string>): string {
  const entries = Object.entries(filters).filter(([, v]) => v !== "");
  if (entries.length === 0) return "";
  const search = entries
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join("&");
  return `?${search}`;
}
