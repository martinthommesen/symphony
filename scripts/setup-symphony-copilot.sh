#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# setup-symphony-copilot.sh
#
# Idempotent setup script that wires a GitHub repository for Symphony +
# GitHub Copilot CLI. Run from inside the target repository.
#
# Usage:
#   scripts/setup-symphony-copilot.sh [--install-missing]
#
# This script never overwrites unrelated files. It only writes:
#   - .symphony/WORKFLOW.md
#   - .symphony/config.yml
#   - .symphony/logs/.gitkeep
#   - scripts/symphony-{start,stop,status}.sh
#   - appends to .gitignore (never overwrites)

INSTALL_MISSING=0
for arg in "$@"; do
  case "$arg" in
    --install-missing) INSTALL_MISSING=1 ;;
    -h|--help)
      sed -n '3,16p' "$0"
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

log() { printf '[symphony-setup] %s\n' "$*"; }
warn() { printf '[symphony-setup] WARN: %s\n' "$*" >&2; }
die() { printf '[symphony-setup] ERROR: %s\n' "$*" >&2; exit 1; }

# 1. Resolve git repo root.
if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  die "Run this script from inside a git repository."
fi
cd "$REPO_ROOT"

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

# 6. Verify copilot CLI.
if ! command -v copilot >/dev/null 2>&1; then
  if [[ "$INSTALL_MISSING" -eq 1 ]]; then
    if ! command -v node >/dev/null 2>&1; then
      die "Node.js not found; required to install Copilot CLI."
    fi
    NODE_MAJOR="$(node -p 'parseInt(process.versions.node.split(".")[0],10)')"
    if [[ "$NODE_MAJOR" -lt 22 ]]; then
      die "Copilot CLI requires Node.js >= 22 (have $NODE_MAJOR)."
    fi
    if ! command -v npm >/dev/null 2>&1; then
      die "npm not found; required to install Copilot CLI."
    fi
    log "Installing @github/copilot via npm..."
    npm install -g @github/copilot
  else
    cat >&2 <<'EOF'
GitHub Copilot CLI ('copilot') not found.

Install with Node.js >= 22:
  npm install -g @github/copilot

Or re-run this script with --install-missing.
EOF
    exit 1
  fi
fi

# 7. Verify copilot auth (best-effort, non-interactive).
if ! copilot --version >/dev/null 2>&1; then
  die "copilot CLI invocation failed. Try: copilot login"
fi
if ! copilot auth status >/dev/null 2>&1; then
  warn "copilot auth status returned non-zero. If runs fail, try: copilot login"
fi

# 8. Vendor Symphony into XDG_DATA_HOME.
SYMPHONY_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/symphony-copilot"
mkdir -p "$SYMPHONY_HOME"
log "Symphony will be vendored at: $SYMPHONY_HOME"

if [[ ! -d "$SYMPHONY_HOME/.git" ]]; then
  if [[ -n "${SYMPHONY_SOURCE_DIR:-}" && -d "$SYMPHONY_SOURCE_DIR" ]]; then
    log "Copying Symphony source from $SYMPHONY_SOURCE_DIR"
    cp -a "$SYMPHONY_SOURCE_DIR/." "$SYMPHONY_HOME/"
  else
    SYMPHONY_REPO_URL="${SYMPHONY_REPO_URL:-https://github.com/openai/symphony.git}"
    log "Cloning $SYMPHONY_REPO_URL"
    git clone --depth 1 "$SYMPHONY_REPO_URL" "$SYMPHONY_HOME"
  fi
else
  log "Symphony already vendored, skipping clone."
fi

# 9. Build Symphony if a build is missing. Best-effort: requires elixir/mix.
if command -v mix >/dev/null 2>&1 && [[ -d "$SYMPHONY_HOME/elixir" ]]; then
  if [[ ! -x "$SYMPHONY_HOME/elixir/bin/symphony" ]]; then
    log "Building Symphony (mix setup && mix build)..."
    (
      cd "$SYMPHONY_HOME/elixir"
      mix setup
      mix build
    )
  else
    log "Symphony binary present, skipping build."
  fi
else
  warn "mix not found; skipping Symphony build. Install Elixir to build."
fi

# 10. Create labels.
LABELS=(
  "symphony"
  "symphony/blocked"
  "symphony/running"
  "symphony/done"
  "symphony/failed"
  "symphony/review"
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
mkdir -p .symphony/logs scripts
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
  # Match the GitHub adapter's derived state strings.
  active_states: [open]
  terminal_states: [closed]

workspace:
  root: "\$HOME/.cache/symphony-copilot/workspaces"

hooks:
  after_create: |
    git clone "\$SOURCE_REPO_URL" .
    BRANCH="symphony/issue-\${ISSUE_NUMBER}"
    git fetch origin "\$BRANCH" || true
    if git rev-parse --verify --quiet "refs/remotes/origin/\$BRANCH" >/dev/null; then
      git checkout -B "\$BRANCH" "origin/\$BRANCH"
    else
      git checkout -B "\$BRANCH"
    fi
  before_run: |
    git status --short
  after_run: |
    git status --short

agent:
  max_concurrent_agents: 1
  max_turns: 10
  max_retry_backoff_ms: 300000

copilot:
  command: copilot
  mode: autopilot
  permission_mode: yolo
  no_ask_user: true
  output_format: json
  max_autopilot_continues: 10
  turn_timeout_ms: 3600000
  read_timeout_ms: 5000
  stall_timeout_ms: 300000
  deny_tools:
    - "shell(git push)"
    - "shell(gh pr)"
    - "shell(gh issue)"

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
    # Substitute the repo placeholder.
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

Create a GitHub issue with the 'symphony' label to dispatch Copilot.
EOF
