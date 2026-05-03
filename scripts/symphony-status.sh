#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

CONFIG_PATH=".symphony/config.yml"
LOG_DIR=".symphony/logs"
PID_FILE="$LOG_DIR/symphony.pid"

printf 'Repo: %s\n' "$REPO_ROOT"
if [[ -f "$CONFIG_PATH" ]]; then
  printf 'Config: %s\n' "$CONFIG_PATH"
else
  printf 'Config: (missing)\n'
fi

if [[ -f "$PID_FILE" ]]; then
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    printf 'State: running (pid=%s)\n' "$PID"
  else
    printf 'State: not running (stale pid file)\n'
  fi
else
  printf 'State: not running\n'
fi

printf 'Logs: %s\n' "$LOG_DIR"
if [[ -f "$LOG_DIR/symphony.out" ]]; then
  printf '\nLast 10 log lines:\n'
  tail -n 10 "$LOG_DIR/symphony.out" 2>/dev/null || true
fi

if command -v gh >/dev/null 2>&1; then
  REPO=""
  if [[ -f "$CONFIG_PATH" ]]; then
    REPO="$(awk '/^[[:space:]]*repo:[[:space:]]*/ {sub(/^[[:space:]]*repo:[[:space:]]*/,""); gsub(/"/,""); print; exit}' "$CONFIG_PATH" || true)"
  fi
  if [[ -n "$REPO" ]]; then
    printf '\nActive Symphony issues in %s:\n' "$REPO"
    gh issue list --repo "$REPO" --state open --label symphony --json number,title,labels \
      --jq '.[] | "  #\(.number) \(.title) [\(.labels|map(.name)|join(", "))]"' 2>/dev/null || true
  fi
fi
