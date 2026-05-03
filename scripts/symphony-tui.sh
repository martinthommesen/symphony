#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# symphony-tui.sh — launches the OpenTUI operations cockpit. Connects to a
# running Symphony backend (default http://127.0.0.1:4000). Read-only when
# no SYMPHONY_CONTROL_TOKEN is configured.

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

SYMPHONY_HOME="${SYMPHONY_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/symphony-copilot}"
TUI_DIR_CANDIDATES=(
  "$REPO_ROOT/tui"
  "$SYMPHONY_HOME/tui"
)

TUI_DIR=""
for candidate in "${TUI_DIR_CANDIDATES[@]}"; do
  if [[ -d "$candidate" && -f "$candidate/package.json" ]]; then
    TUI_DIR="$candidate"
    break
  fi
done

if [[ -z "$TUI_DIR" ]]; then
  printf 'Could not find the Symphony TUI directory in any of:\n' >&2
  for c in "${TUI_DIR_CANDIDATES[@]}"; do printf '  - %s\n' "$c" >&2; done
  exit 1
fi

if ! command -v bun >/dev/null 2>&1; then
  cat >&2 <<'EOF'
[symphony-tui] Bun is required to run the TUI (OpenTUI's native renderer
              uses Bun's FFI). Install Bun from https://bun.sh and re-run.
EOF
  exit 1
fi

if [[ ! -d "$TUI_DIR/node_modules" ]]; then
  printf '[symphony-tui] Installing TUI dependencies in %s...\n' "$TUI_DIR" >&2
  ( cd "$TUI_DIR" && bun install --silent ) >&2
fi

# Resolve the control token: env var beats on-disk file. We never log it.
TOKEN_FILE="${SYMPHONY_CONTROL_TOKEN_FILE:-$REPO_ROOT/.symphony/control-token}"
if [[ -z "${SYMPHONY_CONTROL_TOKEN:-}" && -f "$TOKEN_FILE" ]]; then
  TOKEN_VALUE="$(tr -d '\r\n' < "$TOKEN_FILE")"
  if [[ -n "$TOKEN_VALUE" ]]; then
    export SYMPHONY_CONTROL_TOKEN="$TOKEN_VALUE"
  fi
fi

export SYMPHONY_API_URL="${SYMPHONY_API_URL:-http://127.0.0.1:4000}"

if [[ -z "${SYMPHONY_CONTROL_TOKEN:-}" ]]; then
  printf '[symphony-tui] No control token configured; running in READ-ONLY mode.\n' >&2
  printf '              Set SYMPHONY_CONTROL_TOKEN or create %s.\n' "$TOKEN_FILE" >&2
fi

# Sanity check: backend reachable?
if ! curl -sf "${SYMPHONY_API_URL%/}/api/v1/health" >/dev/null 2>&1; then
  printf '[symphony-tui] Backend not reachable at %s/api/v1/health.\n' "$SYMPHONY_API_URL" >&2
  printf '              Start it with: scripts/symphony-start.sh\n' >&2
fi

cd "$TUI_DIR"
exec bun run src/main.ts "$@"
