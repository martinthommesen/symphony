#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# symphony-tui.sh
#
# Launches the Symphony TUI configuration editor.
#
# Usage:
#   scripts/symphony-tui.sh

log() { printf '[symphony-tui] %s\n' "$*"; }
die() { printf '[symphony-tui] ERROR: %s\n' "$*" >&2; exit 1; }

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  die "Run this script from inside a git repository."
fi
cd "$REPO_ROOT"

CONFIG_PATH=".symphony/config.yml"

if [[ ! -f "$CONFIG_PATH" ]]; then
  die "Config not found at $CONFIG_PATH. Run scripts/install-symphony.sh first."
fi

mkdir -p ".symphony/logs"

BUN_BIN="${BUN_BIN:-bun}"
MANAGED_BUN_BIN="$REPO_ROOT/.symphony/runtime/bun/node_modules/.bin/bun"
if ! command -v "$BUN_BIN" >/dev/null 2>&1 && [[ -x "$MANAGED_BUN_BIN" ]]; then
  BUN_BIN="$MANAGED_BUN_BIN"
fi
if ! command -v "$BUN_BIN" >/dev/null 2>&1; then
  die "Bun not found. Run scripts/install-symphony.sh --install-missing or install Bun."
fi

if ! command -v ruby >/dev/null 2>&1; then
  die "Ruby not found. The TUI uses Ruby's YAML parser for atomic config edits."
fi

if [[ ! -f "tui/src/index.ts" ]]; then
  die "TUI source not found at tui/src/index.ts."
fi

cd tui
SYMPHONY_CONFIG="../$CONFIG_PATH" \
SYMPHONY_TUI_AUDIT="../.symphony/logs/tui-audit.ndjson" \
  "$BUN_BIN" run start "$@"
