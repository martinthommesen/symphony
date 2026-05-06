#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# install-symphony.sh
#
# Generic installer for Symphony orchestrator.
# Creates a managed runtime under .symphony/ in the target repository.
#
# Usage:
#   scripts/install-symphony.sh [--install-missing]

INSTALL_MISSING=0
for arg in "$@"; do
  case "$arg" in
    --install-missing) INSTALL_MISSING=1 ;;
    -h|--help)
      sed -n '3,10p' "$0"
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

json_log() {
  local severity="$1"
  local message="$2"
  if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    MESSAGE="$message" SEVERITY="$severity" ruby -rjson -rtime -e '
      puts JSON.generate({
        timestamp: Time.now.utc.iso8601,
        event_type: "installer_event",
        severity: ENV.fetch("SEVERITY"),
        message: ENV.fetch("MESSAGE"),
        payload: {}
      })
    ' >> "$LOG_DIR/installer.ndjson" 2>/dev/null || true
  fi
}

log() { printf '[symphony-install] %s\n' "$*"; json_log info "$*"; }
warn() { printf '[symphony-install] WARN: %s\n' "$*" >&2; json_log warning "$*"; }
die() { printf '[symphony-install] ERROR: %s\n' "$*" >&2; json_log error "$*"; exit 1; }

# 1. Resolve git repo root.
if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  die "Run this script from inside a git repository."
fi
cd "$REPO_ROOT"
LOG_DIR=".symphony/logs"
mkdir -p "$LOG_DIR"
json_log info "installer started"

# 2. Resolve origin remote.
if ! ORIGIN_URL="$(git config --get remote.origin.url 2>/dev/null)"; then
  die "No 'origin' remote configured."
fi

# 3. Derive owner/repo from the origin URL.
parse_repo() {
  local url="$1"
  case "$url" in
    git@github.com:*)
      url="${url#git@github.com:}"
      ;;
    https://github.com/*)
      url="${url#https://github.com/}"
      ;;
    ssh://git@github.com/*)
      url="${url#ssh://git@github.com/}"
      ;;
    *)
      return 1
      ;;
  esac
  url="${url%.git}"
  url="${url%/}"
  printf '%s' "$url"
}

if ! REPO="$(parse_repo "$ORIGIN_URL")"; then
  die "origin URL is not a GitHub URL: $ORIGIN_URL"
fi

# 4. Validate owner/repo
if ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die "Computed repo identifier '$REPO' is not a valid owner/repo."
fi
log "Target repo: $REPO"

# 5. Verify gh + gh auth.
if ! command -v gh >/dev/null 2>&1; then
  die "GitHub CLI ('gh') not found. Install: https://github.com/cli/cli#installation"
fi
if ! gh auth status >/dev/null 2>&1; then
  die "gh is not authenticated. Run: gh auth login"
fi

# 6. Check acpx (runtime agent execution surface).
ACPX_BIN="${ACPX_BIN:-acpx}"
MANAGED_ACPX_BIN="$REPO_ROOT/.symphony/runtime/acpx/node_modules/.bin/acpx"
if [[ ! -x "$ACPX_BIN" && -x "$MANAGED_ACPX_BIN" ]]; then
  ACPX_BIN="$MANAGED_ACPX_BIN"
fi
if ! command -v "$ACPX_BIN" >/dev/null 2>&1; then
  if [[ "$INSTALL_MISSING" -eq 1 ]]; then
    if ! command -v npm >/dev/null 2>&1; then
      die "npm not found; required to install acpx."
    fi
    mkdir -p .symphony/runtime/acpx
    log "Installing acpx into .symphony/runtime/acpx..."
    npm install --prefix .symphony/runtime/acpx acpx
    ACPX_BIN="$REPO_ROOT/.symphony/runtime/acpx/node_modules/.bin/acpx"
  else
    cat >&2 <<EOF
acpx not found (looked for: $ACPX_BIN).

Install acpx:
  npm install -g acpx

Or re-run this script with --install-missing.
EOF
    exit 1
  fi
fi

# 6b. Check/install Bun for the TUI.
BUN_BIN="${BUN_BIN:-bun}"
MANAGED_BUN_BIN="$REPO_ROOT/.symphony/runtime/bun/node_modules/.bin/bun"
if [[ ! -x "$BUN_BIN" && -x "$MANAGED_BUN_BIN" ]]; then
  BUN_BIN="$MANAGED_BUN_BIN"
fi
if command -v "$BUN_BIN" >/dev/null 2>&1; then
  log "Found Bun prerequisite: $("$BUN_BIN" --version)"
elif [[ "$INSTALL_MISSING" -eq 1 ]]; then
  if ! command -v npm >/dev/null 2>&1; then
    warn "npm not found; cannot install Bun into .symphony/runtime/bun."
  else
    mkdir -p .symphony/runtime/bun
    log "Installing Bun into .symphony/runtime/bun..."
    npm install --prefix .symphony/runtime/bun bun
    BUN_BIN="$MANAGED_BUN_BIN"
  fi
else
  warn "Bun not found. Re-run with --install-missing or install Bun to use scripts/symphony-tui.sh."
fi

# 7. Check at least one underlying agent CLI is available (prerequisite only).
AGENT_FOUND=0
for agent_bin in codex claude copilot gemini cursor-agent opencode qwen; do
  if command -v "$agent_bin" >/dev/null 2>&1; then
    log "Found agent prerequisite: $agent_bin"
    AGENT_FOUND=1
    break
  fi
done
if [[ "$AGENT_FOUND" -eq 0 ]]; then
  warn "No underlying agent CLI found. Install at least one: codex, claude, copilot, gemini, cursor-agent, opencode, qwen."
fi

# 8. Vendor Symphony into managed runtime.
SYMPHONY_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/symphony"
mkdir -p "$SYMPHONY_HOME"
log "Symphony will be vendored at: $SYMPHONY_HOME"

if [[ ! -d "$SYMPHONY_HOME/.git" ]]; then
  if [[ -n "${SYMPHONY_SOURCE_DIR:-}" && -d "$SYMPHONY_SOURCE_DIR" ]]; then
    log "Copying Symphony source from $SYMPHONY_SOURCE_DIR"
    cp -a "$SYMPHONY_SOURCE_DIR/." "$SYMPHONY_HOME/"
  else
    SYMPHONY_REPO_URL="${SYMPHONY_REPO_URL:-https://github.com/martinthommesen/symphony.git}"
    log "Cloning $SYMPHONY_REPO_URL"
    git clone --depth 1 "$SYMPHONY_REPO_URL" "$SYMPHONY_HOME"
  fi
else
  log "Symphony already vendored, skipping clone."
fi

# 9. Build Symphony if a build is missing. Prefer a repo-local mise data dir
# when mise is available, otherwise use the system Elixir/Mix toolchain.
MISE_BIN="${MISE_BIN:-mise}"
MIX_RUNNER=()

if command -v "$MISE_BIN" >/dev/null 2>&1 && [[ -f "$SYMPHONY_HOME/elixir/mise.toml" ]]; then
  export MISE_DATA_DIR="$REPO_ROOT/.symphony/runtime/mise"
  export MISE_CACHE_DIR="$REPO_ROOT/.symphony/runtime/mise-cache"
  mkdir -p "$MISE_DATA_DIR" "$MISE_CACHE_DIR"

  if [[ "$INSTALL_MISSING" -eq 1 ]]; then
    log "Installing Elixir/Erlang toolchain with mise into .symphony/runtime/mise..."
    (cd "$SYMPHONY_HOME/elixir" && "$MISE_BIN" install)
  fi

  MIX_RUNNER=("$MISE_BIN" "exec" "--" "mix")
elif command -v mix >/dev/null 2>&1; then
  MIX_RUNNER=("mix")
fi

if [[ "${#MIX_RUNNER[@]}" -gt 0 && -d "$SYMPHONY_HOME/elixir" ]]; then
  if [[ ! -x "$SYMPHONY_HOME/elixir/bin/symphony" ]]; then
    log "Building Symphony (mix setup && mix build)..."
    (
      cd "$SYMPHONY_HOME/elixir"
      "${MIX_RUNNER[@]}" setup
      "${MIX_RUNNER[@]}" build
    )
  else
    log "Symphony binary present, skipping build."
  fi
else
  warn "mix/mise not found; skipping Symphony build. Install Elixir or mise to build."
fi

# 10. Create labels.
LABELS=(
  "symphony"
  "symphony/blocked"
  "symphony/running"
  "symphony/done"
  "symphony/failed"
  "symphony/review"
  "symphony/agent/codex"
  "symphony/agent/claude"
  "symphony/agent/copilot"
  "symphony/agent/gemini"
  "symphony/agent/cursor"
  "symphony/agent/opencode"
  "symphony/agent/qwen"
  "symphony/agent/custom"
)
for label in "${LABELS[@]}"; do
  if gh label list --repo "$REPO" --json name --jq '.[].name' | grep -Fxq "$label"; then
    :
  else
    gh label create "$label" --repo "$REPO" >/dev/null 2>&1 || true
    log "Ensured label: $label"
  fi
done

# 11. Write target repo files.
mkdir -p .symphony/logs .symphony/runtime/acpx .symphony/runtime/node .symphony/runtime/bun .symphony/runtime/elixir .symphony/runtime/agent-cache .symphony/workspaces scripts
touch .symphony/logs/.gitkeep

CONFIG_PATH=".symphony/config.yml"
WORKFLOW_PATH=".symphony/WORKFLOW.md"

if [[ ! -f "$CONFIG_PATH" ]]; then
  cat > "$CONFIG_PATH" <<EOF
tracker:
  kind: github
  repo: ${REPO}
  active_labels: [symphony]
  blocked_labels: [symphony/blocked]
  running_label: symphony/running
  done_label: symphony/done
  failed_label: symphony/failed
  review_label: symphony/review
  retry_failed: false
  active_states: [open]
  terminal_states: [closed]

workspace:
  root: "\$HOME/.cache/symphony/workspaces"
  worktree_strategy: reuse
  git_worktree_enabled: true
  branch_prefix: symphony/
  branch_name_template: "symphony/issue-{{issue_number}}"
  base_branch: main
  fetch_before_run: true
  rebase_before_run: false
  reset_dirty_workspace_policy: fail
  cleanup_policy: never
  retention_days: 14
  max_workspace_size_bytes: null
  prune_stale_workspaces: false
  isolate_dependency_caches: false

hooks:
  before_run: |
    git status --short
  after_run: |
    git status --short

agent:
  max_concurrent_agents: 1
  max_turns: 10
  max_retry_backoff_ms: 300000

acpx:
  executable: ${ACPX_BIN}
  pinned_version: null
  install_location: .symphony/runtime/acpx
  config_location: .symphony/runtime/acpx/config
  default_output_format: json
  json_strict: true
  suppress_reads: true
  approve_mode: approve-all
  non_interactive_permission_behavior: deny
  auth_policy: auto
  extra_argv: []
  custom_agent_definitions: {}
  session_naming_template: "symphony-{{issue_number}}"

agents:
  routing:
    required_dispatch_label: symphony
    label_prefix: "symphony/agent/"
    default_agent: codex
    multi_agent_policy: reject
    aliases:
      codex: codex
      claude: claude
      copilot: copilot
  registry:
    codex:
      enabled: true
      display_name: "Codex"
      issue_label: "symphony/agent/codex"
      acpx_agent: "codex"
      permissions:
        mode: approve-all
        non_interactive: deny
      runtime:
        timeout_seconds: 3600
        ttl_seconds: 300
        max_attempts: 3
        max_correction_attempts: 2
    claude:
      enabled: true
      display_name: "Claude"
      issue_label: "symphony/agent/claude"
      acpx_agent: "claude"
      permissions:
        mode: approve-all
        non_interactive: deny
      runtime:
        timeout_seconds: 3600
        ttl_seconds: 300
        max_attempts: 3
        max_correction_attempts: 2
    copilot:
      enabled: true
      display_name: "Copilot"
      issue_label: "symphony/agent/copilot"
      acpx_agent: "copilot"
      permissions:
        mode: approve-all
        non_interactive: deny
      runtime:
        timeout_seconds: 3600
        ttl_seconds: 300
        max_attempts: 3
        max_correction_attempts: 2
    gemini:
      enabled: true
      display_name: "Gemini"
      issue_label: "symphony/agent/gemini"
      acpx_agent: "gemini"
    cursor:
      enabled: true
      display_name: "Cursor"
      issue_label: "symphony/agent/cursor"
      acpx_agent: "cursor"
    opencode:
      enabled: true
      display_name: "OpenCode"
      issue_label: "symphony/agent/opencode"
      acpx_agent: "opencode"
    qwen:
      enabled: true
      display_name: "Qwen"
      issue_label: "symphony/agent/qwen"
      acpx_agent: "qwen"
    custom:
      enabled: false
      display_name: "Custom ACP Agent"
      issue_label: "symphony/agent/custom"
      acpx_agent: null
      custom_acpx_agent_command: null

finalizer:
  auto_commit_uncommitted: true
  push_branch: true
  open_pr: true
  close_issue: false
  merge_pr: false
EOF
  log "Wrote $CONFIG_PATH"
else
  log "$CONFIG_PATH already exists, leaving untouched."
fi

if [[ ! -f "$WORKFLOW_PATH" ]]; then
  if [[ -f "$SYMPHONY_HOME/elixir/priv/templates/WORKFLOW.md" ]]; then
    cp "$SYMPHONY_HOME/elixir/priv/templates/WORKFLOW.md" "$WORKFLOW_PATH"
    sed -i.bak "s|__SYMPHONY_REPO_PLACEHOLDER__|${REPO}|g" "$WORKFLOW_PATH" && rm -f "${WORKFLOW_PATH}.bak"
    log "Wrote $WORKFLOW_PATH"
  else
    warn "Symphony WORKFLOW.md template not found; create $WORKFLOW_PATH manually."
  fi
else
  log "$WORKFLOW_PATH already exists, leaving untouched."
fi

# 12. Wrapper scripts.
WRAPPERS_SRC="$SYMPHONY_HOME/scripts"
for w in symphony-start.sh symphony-stop.sh symphony-status.sh; do
  if [[ -f "$WRAPPERS_SRC/$w" && ! -f "scripts/$w" ]]; then
    cp "$WRAPPERS_SRC/$w" "scripts/$w"
    chmod +x "scripts/$w"
    log "Wrote scripts/$w"
  fi
done

# 13. Append .gitignore entries (idempotent).
GITIGNORE=".gitignore"
touch "$GITIGNORE"
add_gitignore_line() {
  local line="$1"
  if ! grep -Fxq "$line" "$GITIGNORE"; then
    printf '%s\n' "$line" >> "$GITIGNORE"
    log "Appended to .gitignore: $line"
  fi
}
add_gitignore_line ".symphony/logs/"

cat <<EOF

Symphony setup complete.

Next steps:

  scripts/symphony-start.sh       # start orchestrator
  scripts/symphony-status.sh      # show running issues
  scripts/symphony-stop.sh        # stop orchestrator

Create a GitHub issue with the 'symphony' label to dispatch an agent via acpx.
EOF
