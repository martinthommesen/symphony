import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { ApiClient, HttpError } from "../api/client.ts";
import { startFakeBackend } from "./fake_backend.ts";

let backend: ReturnType<typeof startFakeBackend>;

beforeEach(() => {
  backend = startFakeBackend({
    controlToken: "test-token",
    initialIssues: [
      {
        issue_id: "1",
        issue_identifier: "GH-1",
        title: "Hello",
        state: "open",
        labels: ["symphony"],
        agent_state: "open",
      },
    ],
  });
});

afterEach(() => {
  backend.stop();
});

describe("integration with fake backend", () => {
  test("health and state respond", async () => {
    const client = new ApiClient({ baseUrl: backend.url, controlToken: "test-token" });
    const health = await client.health();
    expect(health.status).toBe("ok");
    expect(health.capabilities?.control).toBe(true);

    const state = await client.state();
    expect(state.status).toBe("running");
  });

  test("control rejects without token", async () => {
    const noTokenClient = new ApiClient({ baseUrl: backend.url, controlToken: null });
    try {
      await noTokenClient.control("pause");
      throw new Error("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(HttpError);
      expect((err as HttpError).status).toBe(401);
    }
  });

  test("control accepts a valid token", async () => {
    const client = new ApiClient({ baseUrl: backend.url, controlToken: "test-token" });
    const result = await client.control("pause");
    expect(result.ok).toBe(true);
  });

  test("issues list returns the seeded issue", async () => {
    const client = new ApiClient({ baseUrl: backend.url, controlToken: "test-token" });
    const list = await client.issues();
    expect(list.issues).toHaveLength(1);
    expect(list.issues[0]?.issue_identifier).toBe("GH-1");
  });
});
