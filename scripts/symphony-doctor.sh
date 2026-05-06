#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# symphony-doctor.sh
#
# Health check script for Symphony and its dependencies.
# Reports dependency/auth/runtime health.
#
# Usage:
#   scripts/symphony-doctor.sh

PASS=0
FAIL=0
WARN=0

if REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  cd "$REPO_ROOT"
fi

LOG_DIR=".symphony/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true

json_log() {
  local severity="$1"
  local message="$2"
  MESSAGE="$message" SEVERITY="$severity" ruby -rjson -rtime -e '
    puts JSON.generate({
      timestamp: Time.now.utc.iso8601,
      event_type: "doctor_event",
      severity: ENV.fetch("SEVERITY"),
      message: ENV.fetch("MESSAGE"),
      payload: {}
    })
  ' >> "$LOG_DIR/doctor.ndjson" 2>/dev/null || true
}

pass() { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); json_log info "$*"; }
fail() { printf '  [FAIL] %s\n' "$*" >&2; FAIL=$((FAIL + 1)); json_log error "$*"; }
warn() { printf '  [WARN] %s\n' "$*" >&2; WARN=$((WARN + 1)); json_log warning "$*"; }

log() { printf '[symphony-doctor] %s\n' "$*"; json_log info "$*"; }

log "Running Symphony health checks..."

# 1. Git
check_git() {
  if command -v git >/dev/null 2>&1; then
    pass "git installed ($(git --version))"
  else
    fail "git not found"
  fi
}

# 2. GitHub CLI
check_gh() {
  if command -v gh >/dev/null 2>&1; then
    pass "gh installed ($(gh --version | head -1))"
    if gh auth status >/dev/null 2>&1; then
      pass "gh authenticated"
    else
      fail "gh not authenticated (run: gh auth login)"
    fi
  else
    fail "gh not found (install: https://github.com/cli/cli#installation)"
  fi
}

# 3. Repository remote
check_remote() {
  if REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    pass "inside git repository: $REPO_ROOT"
    if git config --get remote.origin.url >/dev/null 2>&1; then
      pass "origin remote configured"
    else
      fail "no origin remote configured"
    fi
  else
    fail "not inside a git repository"
  fi
}

# 4. acpx (runtime execution surface)
check_acpx() {
  ACPX_BIN="${ACPX_BIN:-acpx}"
  MANAGED_ACPX_BIN=".symphony/runtime/acpx/node_modules/.bin/acpx"
  if ! command -v "$ACPX_BIN" >/dev/null 2>&1 && [[ -x "$MANAGED_ACPX_BIN" ]]; then
    ACPX_BIN="$MANAGED_ACPX_BIN"
  fi
  if command -v "$ACPX_BIN" >/dev/null 2>&1; then
    pass "acpx installed ($ACPX_BIN)"
    if "$ACPX_BIN" --version >/dev/null 2>&1; then
      pass "acpx executable runs"
    else
      fail "acpx --version failed"
    fi
  else
    fail "acpx not found (looked for: $ACPX_BIN; install: npm install -g acpx)"
  fi
}

# 5. Underlying agent CLIs (prerequisite checks only)
check_agents() {
  local found=0
  for agent_bin in codex claude copilot gemini cursor-agent opencode qwen; do
    if command -v "$agent_bin" >/dev/null 2>&1; then
      if "$agent_bin" --version >/dev/null 2>&1; then
        pass "agent CLI prerequisite healthy: $agent_bin --version"
      else
        warn "agent CLI found but --version failed: $agent_bin"
      fi
      found=1
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    warn "no underlying agent CLI found (install at least one: codex, claude, copilot, gemini, cursor-agent, opencode, qwen)"
  fi
}

# 6. Node.js (for acpx)
check_node() {
  if command -v node >/dev/null 2>&1; then
    NODE_VERSION="$(node --version)"
    pass "node installed ($NODE_VERSION)"
    if command -v npm >/dev/null 2>&1; then
      pass "npm available ($(npm --version))"
    else
      warn "npm not found (required to install acpx into managed runtime)"
    fi
  else
    warn "node not found (required for acpx)"
  fi
}

# 7. Elixir (for Symphony backend)
check_elixir() {
  if command -v elixir >/dev/null 2>&1; then
    pass "elixir installed ($(elixir --version | grep 'Elixir'))"
    if command -v mix >/dev/null 2>&1; then
      pass "mix available"
    else
      warn "mix not found"
    fi
  else
    warn "elixir not found (optional: needed to build Symphony from source)"
  fi
}

# 8. Bun (for TUI)
check_bun() {
  BUN_BIN="${BUN_BIN:-bun}"
  MANAGED_BUN_BIN=".symphony/runtime/bun/node_modules/.bin/bun"
  if ! command -v "$BUN_BIN" >/dev/null 2>&1 && [[ -x "$MANAGED_BUN_BIN" ]]; then
    BUN_BIN="$MANAGED_BUN_BIN"
  fi
  if command -v "$BUN_BIN" >/dev/null 2>&1; then
    pass "bun installed ($("$BUN_BIN" --version))"
  else
    warn "bun not found (required for scripts/symphony-tui.sh)"
  fi
}

# 9. Managed mise toolchain
check_mise_runtime() {
  if [[ -d ".symphony/runtime/mise" ]]; then
    pass "managed mise runtime directory exists"
  elif command -v mise >/dev/null 2>&1; then
    warn "mise available but managed runtime not installed (run: scripts/install-symphony.sh --install-missing)"
  else
    warn "mise not found (optional: used to install Elixir/Erlang into .symphony/runtime/mise)"
  fi
}

# 10. Config files
check_config() {
  if [[ -f ".symphony/config.yml" ]]; then
    pass "config.yml exists"
  else
    fail "config.yml not found (run: scripts/install-symphony.sh)"
  fi
  if [[ -f ".symphony/WORKFLOW.md" ]]; then
    pass "WORKFLOW.md exists"
  else
    fail "WORKFLOW.md not found (run: scripts/install-symphony.sh)"
  fi
}

config_value() {
  local path="$1"
  ruby -ryaml -e '
    data = YAML.load_file(".symphony/config.yml") rescue {}
    value = ARGV.fetch(0).split(".").reduce(data) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
    puts value unless value.nil?
  ' "$path" 2>/dev/null || true
}

# 10. Workspace path writable
check_workspace_path() {
  WORKSPACE_ROOT="$(config_value workspace.root)"
  WORKSPACE_ROOT="${WORKSPACE_ROOT:-${HOME}/.cache/symphony/workspaces}"
  if mkdir -p "$WORKSPACE_ROOT" 2>/dev/null; then
    pass "workspace path writable: $WORKSPACE_ROOT"
  else
    fail "workspace path not writable: $WORKSPACE_ROOT"
  fi
}

# 11. Logs path writable
check_logs_path() {
  LOG_PATH="$(config_value logging.directory)"
  LOG_PATH="${LOG_PATH:-.symphony/logs}"
  if mkdir -p "$LOG_PATH" 2>/dev/null; then
    pass "logs path writable: $LOG_PATH"
  else
    fail "logs path not writable"
  fi
}

# Run checks
check_git
check_gh
check_remote
check_acpx
check_agents
check_node
check_elixir
check_bun
check_mise_runtime
check_config
check_workspace_path
check_logs_path

# Summary
printf '\n'
log "Health check complete: $PASS passed, $FAIL failed, $WARN warned"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
else
  exit 0
fi
