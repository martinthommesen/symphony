#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

PID_FILE=".symphony/logs/symphony.pid"

if [[ ! -f "$PID_FILE" ]]; then
  printf 'No pid file at %s. Nothing to stop.\n' "$PID_FILE"
  exit 0
fi

PID="$(cat "$PID_FILE" 2>/dev/null || true)"
if [[ -z "$PID" ]]; then
  rm -f "$PID_FILE"
  printf 'pid file empty, removed.\n'
  exit 0
fi

if ! kill -0 "$PID" 2>/dev/null; then
  rm -f "$PID_FILE"
  printf 'pid %s not alive, cleaning up.\n' "$PID"
  exit 0
fi

printf 'Stopping Symphony pid=%s...\n' "$PID"
kill "$PID" || true

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! kill -0 "$PID" 2>/dev/null; then
    rm -f "$PID_FILE"
    printf 'Stopped.\n'
    exit 0
  fi
  sleep 1
done

printf 'Process %s did not exit, sending SIGKILL.\n' "$PID" >&2
kill -9 "$PID" || true
rm -f "$PID_FILE"
