/**
 * Symphony backend HTTP client. Wraps `fetch` with timeouts and unauthenticated/
 * authenticated request flows. Read endpoints retry on transient failure;
 * mutating endpoints never retry.
 */

import {
  parseAnalytics,
  parseEventsPayload,
  parseHealth,
  parseIssuesList,
  parseState,
} from "./schema.ts";
import type {
  AnalyticsPayload,
  ControlResult,
  EventsPayload,
  HealthPayload,
  IssuesListPayload,
  StatePayload,
} from "./types.ts";

export interface ApiClientOptions {
  baseUrl: string;
  controlToken?: string | null;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

export class HttpError extends Error {
  public readonly status: number;
  public readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(`${status} ${code}: ${message}`);
    this.name = "HttpError";
    this.status = status;
    this.code = code;
  }
}

export class TimeoutError extends Error {
  constructor() {
    super("Request timed out");
    this.name = "TimeoutError";
  }
}

export class NetworkError extends Error {
  public override readonly cause: unknown;

  constructor(cause: unknown) {
    super(`Network error: ${(cause as { message?: string })?.message ?? String(cause)}`);
    this.name = "NetworkError";
    this.cause = cause;
  }
}

export class ApiClient {
  private readonly baseUrl: string;
  private readonly controlToken: string | null;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch;

  constructor(options: ApiClientOptions) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, "");
    this.controlToken = options.controlToken ?? null;
    this.timeoutMs = options.timeoutMs ?? 5_000;
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  hasControlToken(): boolean {
    return typeof this.controlToken === "string" && this.controlToken.length > 0;
  }

  // ---- read endpoints (idempotent, retry up to 2x) ------------------------

  async health(): Promise<HealthPayload> {
    return parseHealth(await this.getJson("/api/v1/health"));
  }

  async state(): Promise<StatePayload> {
    return parseState(await this.getJson("/api/v1/state"));
  }

  async issues(): Promise<IssuesListPayload> {
    return parseIssuesList(await this.getJson("/api/v1/issues"));
  }

  async events(filters: Record<string, string | number | undefined> = {}): Promise<EventsPayload> {
    const search = encodeQuery(filters);
    return parseEventsPayload(await this.getJson(`/api/v1/events${search}`));
  }

  async analytics(): Promise<AnalyticsPayload> {
    return parseAnalytics(await this.getJson("/api/v1/analytics"));
  }

  // ---- control endpoints (no retry) ---------------------------------------

  async control(command: string, body: Record<string, unknown> = {}): Promise<ControlResult> {
    // Control endpoints must surface the backend's structured
    // {ok: false, error: {code, message}} body on 4xx so the UI can show
    // a useful error (missing token, invalid token, not_dispatchable, …).
    // We therefore tell `request` not to throw on >= 400.
    const response = await this.request(
      "POST",
      `/api/v1/control/${encodeURIComponent(command)}`,
      body,
      { throwOnHttpError: false },
    );

    const data = (await response.json().catch(() => null)) as ControlResult | Record<string, unknown> | null;

    if (data && typeof (data as { ok?: unknown }).ok === "boolean") {
      return data as ControlResult;
    }

    return {
      ok: false,
      error: { code: "invalid_response", message: `HTTP ${response.status}` },
    };
  }

  async refresh(): Promise<ControlResult> {
    const response = await this.request("POST", `/api/v1/refresh`, {}, { throwOnHttpError: false });
    const data = (await response.json().catch(() => null)) as Record<string, unknown> | null;
    if (!data) {
      return { ok: false, error: { code: "invalid_response", message: `HTTP ${response.status}` } };
    }

    // `/api/v1/refresh` is a legacy endpoint and uses the original
    // {error: {...}} envelope, not {ok: false, error: ...}. Treat any 4xx
    // (e.g. missing/invalid token, 503 unavailable) as a control failure
    // for callers that want a uniform return shape.
    if (response.status >= 400) {
      const err = (data as { error?: { code?: string; message?: string } }).error;
      return {
        ok: false,
        error: {
          code: err?.code ?? "http_error",
          message: err?.message ?? `HTTP ${response.status}`,
        },
      };
    }

    if ((data as { ok?: unknown }).ok === false) {
      return data as unknown as ControlResult;
    }

    return { ok: true, command: "refresh", payload: data };
  }

  // ---- internals ----------------------------------------------------------

  private async getJson(path: string, attempt = 0): Promise<unknown> {
    try {
      const response = await this.request("GET", path);
      return await response.json();
    } catch (error) {
      if (error instanceof HttpError) throw error;
      if (attempt < 2) {
        await sleep(150 * 2 ** attempt);
        return this.getJson(path, attempt + 1);
      }
      throw error;
    }
  }

  private async request(
    method: "GET" | "POST",
    path: string,
    body?: Record<string, unknown>,
    options: { throwOnHttpError?: boolean } = {},
  ): Promise<Response> {
    const url = `${this.baseUrl}${path}`;
    const headers: Record<string, string> = { accept: "application/json" };

    if (method === "POST") {
      headers["content-type"] = "application/json";
    }

    if (path.startsWith("/api/v1/control/") || path === "/api/v1/refresh") {
      if (this.controlToken) {
        headers["authorization"] = `Bearer ${this.controlToken}`;
      }
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);

    let response: Response;
    try {
      response = await this.fetchImpl(url, {
        method,
        headers,
        body: method === "POST" ? JSON.stringify(body ?? {}) : undefined,
        signal: controller.signal,
      });
    } catch (error) {
      const isAbort = (error as { name?: string }).name === "AbortError";
      throw isAbort ? new TimeoutError() : new NetworkError(error);
    } finally {
      clearTimeout(timer);
    }

    const throwOnHttpError = options.throwOnHttpError ?? true;
    if (throwOnHttpError && response.status >= 400) {
      const data = (await response.clone().json().catch(() => null)) as
        | { error?: { code?: string; message?: string } }
        | null;
      throw new HttpError(
        response.status,
        data?.error?.code ?? "http_error",
        data?.error?.message ?? response.statusText,
      );
    }

    return response;
  }
}

function encodeQuery(filters: Record<string, string | number | undefined>): string {
  const entries = Object.entries(filters).filter(
    ([, v]) => v !== undefined && v !== null && v !== "",
  );
  if (entries.length === 0) return "";
  const search = entries
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
    .join("&");
  return `?${search}`;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
