import { describe, expect, test } from "bun:test";
import { containsSecret, redact, redactDeep } from "../redaction/redact.ts";

describe("redact", () => {
  test("masks GitHub OAuth tokens", () => {
    const out = redact("token: ghp_abcdefghijklmnopqrstuvwxyz");
    expect(out).not.toContain("ghp_abcdefghijklmnopqrstuvwxyz");
    expect(out).toContain("[REDACTED]");
  });

  test("masks fine-grained PATs", () => {
    const out = redact("export GH_TOKEN=github_pat_abcdefghijklmnopqrstuvwxyzabcd");
    expect(out).not.toContain("github_pat_");
    expect(out).toContain("[REDACTED]");
  });

  test("masks bearer headers", () => {
    const out = redact("Authorization: Bearer abc1234567890XYZdefghi");
    expect(out).toContain("Authorization");
    expect(out).toContain("Bearer");
    expect(out).toContain("[REDACTED]");
    expect(out).not.toContain("abc1234567890XYZdefghi");
  });

  test("preserves text without secrets", () => {
    expect(redact("running issue GH-1")).toBe("running issue GH-1");
  });

  test("redactDeep walks nested structures", () => {
    const value = {
      headers: { Authorization: "Bearer abc1234567890XYZdefghi" },
      args: ["--token", "ghp_abcdefghijklmnopqrstuvwxyz"],
      ok: true,
      n: 7,
    };
    const cleaned = redactDeep(value);
    const json = JSON.stringify(cleaned);
    expect(json).not.toContain("ghp_");
    expect(json).not.toContain("abc1234567890XYZdefghi");
    expect(json).toContain("[REDACTED]");
    expect(cleaned.ok).toBe(true);
    expect(cleaned.n).toBe(7);
  });

  test("containsSecret returns true for secrets and false otherwise", () => {
    expect(containsSecret("Bearer abc1234567890XYZdefghi")).toBe(true);
    expect(containsSecret("plain text")).toBe(false);
  });
});
