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
  printf 'Missing %s. Run scripts/setup-symphony-copilot.sh first.\n' "$WORKFLOW_PATH" >&2
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

SYMPHONY_HOME="${SYMPHONY_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/symphony-copilot}"
BIN="$SYMPHONY_HOME/elixir/bin/symphony"
if [[ ! -x "$BIN" ]]; then
  printf 'Symphony binary missing at %s. Build with mix.\n' "$BIN" >&2
  exit 1
fi

LOG_FILE="$LOG_DIR/symphony.out"
nohup "$BIN" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$LOG_DIR" \
  "$REPO_ROOT/$WORKFLOW_PATH" \
  >>"$LOG_FILE" 2>&1 &
PID=$!
echo "$PID" > "$PID_FILE"
printf 'Symphony started (pid=%s). Logs: %s\n' "$PID" "$LOG_FILE"
