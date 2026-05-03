import { afterEach, describe, expect, test } from "bun:test";
import {
  clearKnownSecrets,
  containsSecret,
  redact,
  redactDeep,
  registerKnownSecret,
} from "../redaction/redact.ts";

afterEach(() => clearKnownSecrets());

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

  test("masks SYMPHONY_CONTROL_TOKEN= env var assignments", () => {
    const out = redact(
      "env SYMPHONY_CONTROL_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef body",
    );
    expect(out).toContain("SYMPHONY_CONTROL_TOKEN=[REDACTED]");
    expect(out).not.toContain("0123456789abcdef0123456789abcdef");
  });

  test("masks gh* tokens that border on `_` via lookbehind boundary", () => {
    // Old `\b` boundary failed between `_` and `g`, leaking the token
    // when it appeared after another word character. The new
    // `(?<![A-Za-z0-9_])` lookbehind catches it.
    const out = redact("prevtoken_gho_AAAABBBBCCCCDDDDEEEEFFFFGGGG and friends");
    expect(out).not.toContain("AAAABBBBCCCCDDDDEEEEFFFFGGGG");
    expect(out).toContain("[REDACTED]");
  });

  test("registered known secrets are redacted even without an env-var prefix", () => {
    const literal = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    registerKnownSecret(literal);

    const out = redact(`got the bearer ${literal} as a bare value`);
    expect(out).not.toContain(literal);
    expect(out).toContain("[REDACTED]");

    expect(containsSecret(`leak ${literal} leak`)).toBe(true);
  });

  test("registerKnownSecret ignores values shorter than 16 bytes", () => {
    registerKnownSecret("tiny");
    // The cleaner shouldn't replace `tiny` everywhere; that would
    // false-positive on prose.
    expect(redact("a tiny value")).toBe("a tiny value");
  });
});
