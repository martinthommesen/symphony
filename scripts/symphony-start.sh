#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

CONFIG_PATH=".symphony/config.yml"
WORKFLOW_PATH=".symphony/WORKFLOW.md"
LOG_DIR=".symphony/logs"
PID_FILE="$LOG_DIR/symphony.pid"

if [[ ! -f "$WORKFLOW_PATH" ]]; then
  printf 'Missing %s. Run scripts/install-symphony.sh first.\n' "$WORKFLOW_PATH" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  printf 'Missing %s. Run scripts/install-symphony.sh first.\n' "$CONFIG_PATH" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"

if [[ -f "$PID_FILE" ]]; then
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    printf 'Symphony already running (pid=%s).\n' "$PID"
    exit 0
  fi
  rm -f "$PID_FILE"
fi

SYMPHONY_HOME="${SYMPHONY_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/symphony}"
BIN="$SYMPHONY_HOME/elixir/bin/symphony"
MANAGED_ACPX_BIN="$REPO_ROOT/.symphony/runtime/acpx/node_modules/.bin/acpx"
MANAGED_BUN_BIN="$REPO_ROOT/.symphony/runtime/bun/node_modules/.bin/bun"
MANAGED_MISE_DIR="$REPO_ROOT/.symphony/runtime/mise"

if [[ ! -x "$BIN" ]]; then
  printf 'Symphony binary missing at %s. Build with mix.\n' "$BIN" >&2
  exit 1
fi

LOG_FILE="$LOG_DIR/symphony.out"
if [[ -x "$MANAGED_ACPX_BIN" ]]; then
  export ACPX_BIN="$MANAGED_ACPX_BIN"
  export PATH="$(dirname "$MANAGED_ACPX_BIN"):$PATH"
fi
if [[ -x "$MANAGED_BUN_BIN" ]]; then
  export BUN_BIN="$MANAGED_BUN_BIN"
  export PATH="$(dirname "$MANAGED_BUN_BIN"):$PATH"
fi
if [[ -d "$MANAGED_MISE_DIR" ]]; then
  export MISE_DATA_DIR="$MANAGED_MISE_DIR"
  export MISE_CACHE_DIR="$REPO_ROOT/.symphony/runtime/mise-cache"
fi

nohup "$BIN" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$LOG_DIR" \
  "$REPO_ROOT/$WORKFLOW_PATH" \
  >>"$LOG_FILE" 2>&1 &
PID=$!
echo "$PID" > "$PID_FILE"
printf 'Symphony started (pid=%s). Logs: %s\n' "$PID" "$LOG_FILE"
