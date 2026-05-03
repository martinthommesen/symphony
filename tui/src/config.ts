/**
 * TUI runtime configuration. Reads from environment variables with
 * sensible defaults. The shape is small on purpose — anything more
 * complex should be derived from the backend's `/api/v1/health` payload.
 */

import { readFileSync } from "node:fs";

export interface RuntimeConfig {
  apiUrl: string;
  controlToken: string | null;
  noColor: boolean;
  reducedMotion: boolean;
  logLevel: string;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): RuntimeConfig {
  const apiUrl = (env.SYMPHONY_API_URL ?? "http://127.0.0.1:4000").replace(/\/+$/, "");
  // Trim SYMPHONY_CONTROL_TOKEN and treat whitespace-only / empty as "no
  // token configured". Otherwise the TUI would start in writable mode
  // and send an empty Bearer header that the backend always rejects —
  // every mutating action would fail with `missing_token`.
  let controlToken = nilifyBlank(env.SYMPHONY_CONTROL_TOKEN);

  if (!controlToken) {
    const tokenFile = env.SYMPHONY_CONTROL_TOKEN_FILE ?? ".symphony/control-token";
    try {
      controlToken = nilifyBlank(readFileSync(tokenFile, "utf-8"));
    } catch {
      // No-op; missing token file means read-only mode.
    }
  }

  const noColor = parseBool(env.SYMPHONY_TUI_NO_COLOR);
  const reducedMotion = parseBool(env.SYMPHONY_TUI_REDUCED_MOTION);
  const logLevel = env.SYMPHONY_TUI_LOG_LEVEL ?? "info";

  return { apiUrl, controlToken, noColor, reducedMotion, logLevel };
}

function nilifyBlank(value: string | null | undefined): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function parseBool(value: string | undefined): boolean {
  if (!value) return false;
  return value === "1" || value.toLowerCase() === "true" || value.toLowerCase() === "yes";
}
