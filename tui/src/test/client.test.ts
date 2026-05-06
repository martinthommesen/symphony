import { describe, expect, test } from "bun:test";
import { ApiClient, HttpError } from "../api/client.ts";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("ApiClient", () => {
  test("includes bearer token on control requests", async () => {
    let observed: { url?: string; init?: RequestInit } = {};
    const fetchImpl: typeof fetch = ((url: string, init?: RequestInit) => {
      observed = { url, init };
      return Promise.resolve(jsonResponse({ ok: true, command: "pause", payload: {} }));
    }) as unknown as typeof fetch;

    const client = new ApiClient({
      baseUrl: "http://x",
      controlToken: "secret-token",
      fetchImpl,
    });

    const result = await client.control("pause");
    expect(result.ok).toBe(true);
    const headers = new Headers(observed.init?.headers as Record<string, string>);
    expect(headers.get("authorization")).toBe("Bearer secret-token");
  });

  test("does not include bearer on /api/v1/health (the only public route)", async () => {
    let headers: Headers | null = null;
    const fetchImpl: typeof fetch = ((_url: string, init?: RequestInit) => {
      headers = new Headers(init?.headers as Record<string, string>);
      return Promise.resolve(jsonResponse({ status: "ok" }));
    }) as unknown as typeof fetch;

    const client = new ApiClient({ baseUrl: "http://x", controlToken: "t", fetchImpl });
    await client.health();
    expect(headers!.get("authorization")).toBeNull();
  });

  test("includes bearer on read endpoints when control token is configured", async () => {
    // The backend's `:control_auth` pipeline gates state/issues/events/
    // analytics too, so the client must authenticate every non-health
    // request when it has a token.
    let headers: Headers | null = null;
    const fetchImpl: typeof fetch = ((_url: string, init?: RequestInit) => {
      headers = new Headers(init?.headers as Record<string, string>);
      return Promise.resolve(
        jsonResponse({ generated_at: "2026-01-01T00:00:00Z", running: [], retrying: [] }),
      );
    }) as unknown as typeof fetch;

    const client = new ApiClient({ baseUrl: "http://x", controlToken: "secret", fetchImpl });
    await client.state();
    expect(headers!.get("authorization")).toBe("Bearer secret");
  });

  test("omits bearer on read endpoints when no control token is configured", async () => {
    let headers: Headers | null = null;
    const fetchImpl: typeof fetch = ((_url: string, init?: RequestInit) => {
      headers = new Headers(init?.headers as Record<string, string>);
      return Promise.resolve(
        jsonResponse({ generated_at: "2026-01-01T00:00:00Z", running: [], retrying: [] }),
      );
    }) as unknown as typeof fetch;

    const client = new ApiClient({ baseUrl: "http://x", controlToken: null, fetchImpl });
    await client.state();
    expect(headers!.get("authorization")).toBeNull();
  });

  test("throws HttpError with status and code on 4xx", async () => {
    const fetchImpl: typeof fetch = (async () =>
      jsonResponse({ ok: false, error: { code: "missing_token", message: "no token" } }, 401)) as unknown as typeof fetch;

    const client = new ApiClient({ baseUrl: "http://x", controlToken: null, fetchImpl });
    try {
      await client.health();
      throw new Error("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(HttpError);
      const httpErr = err as HttpError;
      expect(httpErr.status).toBe(401);
      expect(httpErr.code).toBe("missing_token");
    }
  });

  test("control() returns ControlFailure on 4xx instead of throwing", async () => {
    const fetchImpl: typeof fetch = (async () =>
      jsonResponse(
        { ok: false, error: { code: "missing_token", message: "no token" } },
        401,
      )) as unknown as typeof fetch;

    const client = new ApiClient({ baseUrl: "http://x", controlToken: null, fetchImpl });
    const result = await client.control("pause");
    expect(result.ok).toBe(false);
    if (result.ok === false) {
      expect(result.error.code).toBe("missing_token");
      expect(result.error.message).toBe("no token");
    }
  });

  test("refresh() returns ControlFailure on 4xx with legacy error envelope", async () => {
    const fetchImpl: typeof fetch = (async () =>
      jsonResponse({ error: { code: "missing_token", message: "no token" } }, 401)) as unknown as typeof fetch;

    const client = new ApiClient({ baseUrl: "http://x", controlToken: null, fetchImpl });
    const result = await client.refresh();
    expect(result.ok).toBe(false);
    if (result.ok === false) {
      expect(result.error.code).toBe("missing_token");
    }
  });

  test("getJson retries on 5xx but not 4xx", async () => {
    let attempts = 0;
    const fetchImpl: typeof fetch = (async () => {
      attempts += 1;
      if (attempts < 3) {
        return jsonResponse({ error: { code: "x", message: "x" } }, 503);
      }
      return jsonResponse({ status: "ok" });
    }) as unknown as typeof fetch;

    const client = new ApiClient({ baseUrl: "http://x", controlToken: null, fetchImpl });
    const health = await client.health();
    expect(health.status).toBe("ok");
    expect(attempts).toBe(3);
  });

  test("getJson does not retry 4xx", async () => {
    let attempts = 0;
    const fetchImpl: typeof fetch = (async () => {
      attempts += 1;
      return jsonResponse({ error: { code: "missing_token", message: "no token" } }, 401);
    }) as unknown as typeof fetch;

    const client = new ApiClient({ baseUrl: "http://x", controlToken: null, fetchImpl });
    try {
      await client.health();
      throw new Error("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(HttpError);
    }
    expect(attempts).toBe(1);
  });

  test("hasControlToken reports presence correctly", () => {
    const a = new ApiClient({ baseUrl: "http://x", controlToken: "t" });
    const b = new ApiClient({ baseUrl: "http://x", controlToken: null });
    expect(a.hasControlToken()).toBe(true);
    expect(b.hasControlToken()).toBe(false);
  });
});
