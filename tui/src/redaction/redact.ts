/**
 * Defense-in-depth secret redaction applied before any payload is rendered.
 * Mirrors `SymphonyElixir.Redaction` so the TUI never displays secrets even
 * if a future backend bug skips redaction.
 */

const PLACEHOLDER = "[REDACTED]";

// We deliberately drop word-boundary anchors. `\b` does not fire
// between two word characters (so `prevtoken_gho_…` slipped past),
// and a `(?<![A-Za-z0-9_])` lookbehind has the same gap. The pattern
// bodies (`gh[oprsu]_` + 20+ alphanumerics; literal `bearer\s+`) are
// specific enough to avoid false positives on prose, and erring
// toward over-redaction is the right trade-off for a security
// control.
const PATTERNS: RegExp[] = [
  /github_pat_[A-Za-z0-9_]{20,}/g,
  /gh[oprsu]_[A-Za-z0-9]{20,}/g,
  /bearer\s+[A-Za-z0-9._\-+/=]{16,}/gi,
  /(https?:\/\/)([^\s:@/]+):([^\s@/]+)@/g,
];

const SENSITIVE_ENV_VARS = [
  "GH_TOKEN",
  "GITHUB_TOKEN",
  "COPILOT_GITHUB_TOKEN",
  "SYMPHONY_CONTROL_TOKEN",
  "SYMPHONY_SECRET_KEY_BASE",
];

const ENV_PATTERNS = SENSITIVE_ENV_VARS.map((name) => ({
  name,
  re: new RegExp(`${name}=([^\\s"'\\]]+)`, "g"),
}));

const AUTH_HEADER_RE = /(authorization\s*:\s*)(bearer\s+)?[A-Za-z0-9._\-+/=]{8,}/gi;

// Literal known-secret values registered at runtime (e.g. the configured
// control token, when surfaced to the TUI). Plain string indexOf/replace
// covers the case where a value leaks without an env-var or bearer
// prefix.
const KNOWN_SECRETS = new Set<string>();

export function registerKnownSecret(value: string): void {
  if (typeof value === "string" && value.length >= 16) {
    KNOWN_SECRETS.add(value);
  }
}

export function clearKnownSecrets(): void {
  KNOWN_SECRETS.clear();
}

export function redact(value: string): string {
  let out = value;

  for (const secret of KNOWN_SECRETS) {
    out = out.split(secret).join(PLACEHOLDER);
  }

  for (const { name, re } of ENV_PATTERNS) {
    out = out.replace(re, `${name}=${PLACEHOLDER}`);
  }

  out = out.replace(AUTH_HEADER_RE, (_match, prefix: string, scheme: string | undefined) => {
    return `${prefix}${scheme ?? ""}${PLACEHOLDER}`;
  });

  for (const pattern of PATTERNS) {
    out = out.replace(pattern, PLACEHOLDER);
  }

  return out;
}

export function redactDeep<T>(value: T): T {
  if (typeof value === "string") {
    return redact(value) as unknown as T;
  }

  if (Array.isArray(value)) {
    return value.map(redactDeep) as unknown as T;
  }

  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, v] of Object.entries(value as Record<string, unknown>)) {
      out[key] = redactDeep(v);
    }
    return out as unknown as T;
  }

  return value;
}

export function containsSecret(value: string): boolean {
  // Each `.test()` call advances `lastIndex` on global regexes. Reset
  // unconditionally — including on early returns — so subsequent calls
  // produce stable results.
  let found = false;
  try {
    for (const re of PATTERNS) {
      if (re.test(value)) {
        found = true;
        break;
      }
    }
    if (!found && AUTH_HEADER_RE.test(value)) {
      found = true;
    }
    if (!found) {
      for (const { re } of ENV_PATTERNS) {
        if (re.test(value)) {
          found = true;
          break;
        }
      }
    }
    if (!found) {
      for (const secret of KNOWN_SECRETS) {
        if (value.includes(secret)) {
          found = true;
          break;
        }
      }
    }
    return found;
  } finally {
    for (const re of PATTERNS) re.lastIndex = 0;
    AUTH_HEADER_RE.lastIndex = 0;
    for (const { re } of ENV_PATTERNS) re.lastIndex = 0;
  }
}

export const PLACEHOLDER_TEXT = PLACEHOLDER;
