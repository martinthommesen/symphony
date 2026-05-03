/**
 * Defense-in-depth secret redaction applied before any payload is rendered.
 * Mirrors `SymphonyElixir.Redaction` so the TUI never displays secrets even
 * if a future backend bug skips redaction.
 */

const PLACEHOLDER = "[REDACTED]";

const PATTERNS: RegExp[] = [
  /github_pat_[A-Za-z0-9_]{20,}/g,
  /\bgh[oprsu]_[A-Za-z0-9]{20,}/g,
  /(?:^|\s)bearer\s+[A-Za-z0-9._\-+/=]{16,}/gi,
  /(https?:\/\/)([^\s:@/]+):([^\s@/]+)@/g,
];

const SENSITIVE_ENV_VARS = ["GH_TOKEN", "GITHUB_TOKEN", "COPILOT_GITHUB_TOKEN"];

const ENV_PATTERNS = SENSITIVE_ENV_VARS.map((name) => ({
  name,
  re: new RegExp(`${name}=([^\\s"'\\]]+)`, "g"),
}));

const AUTH_HEADER_RE = /(authorization\s*:\s*)(bearer\s+)?[A-Za-z0-9._\-+/=]{8,}/gi;

export function redact(value: string): string {
  let out = value;

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
  if (PATTERNS.some((re) => re.test(value))) return true;
  // Reset lastIndex on global regexes after .test().
  for (const re of PATTERNS) re.lastIndex = 0;
  if (AUTH_HEADER_RE.test(value)) {
    AUTH_HEADER_RE.lastIndex = 0;
    return true;
  }
  return ENV_PATTERNS.some(({ re }) => {
    const matched = re.test(value);
    re.lastIndex = 0;
    return matched;
  });
}

export const PLACEHOLDER_TEXT = PLACEHOLDER;
