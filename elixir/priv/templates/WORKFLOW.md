---
# Symphony Copilot workflow template.
#
# Front matter is YAML.
# Body is rendered with Solid (Liquid-compatible) using `{{ ... }}` variables.
# Hook scripts use environment variables, not template variables:
#   $ISSUE_NUMBER
#   $ISSUE_IDENTIFIER
#   $SOURCE_REPO_URL
#   $WORKSPACE

tracker:
  kind: github
  repo: "__SYMPHONY_REPO_PLACEHOLDER__"
  active_labels: [symphony]
  blocked_labels: [symphony/blocked]
  running_label: symphony/running
  done_label: symphony/done
  failed_label: symphony/failed
  review_label: symphony/review

workspace:
  root: "$HOME/.cache/symphony-copilot/workspaces"

hooks:
  # `after_create` must be idempotent across reruns. If the remote already
  # has a `symphony/issue-<N>` branch (e.g. from a previous failed or
  # successful run), check it out instead of creating a new branch from
  # the default branch. Pushing the same branch from a fresh checkout is
  # rejected as non-fast-forward, so reruns must continue from the remote
  # tip.
  after_create: |
    git clone "$SOURCE_REPO_URL" .
    BRANCH="symphony/issue-${ISSUE_NUMBER}"
    git fetch origin "$BRANCH" || true
    if git rev-parse --verify --quiet "refs/remotes/origin/$BRANCH" >/dev/null; then
      git checkout -B "$BRANCH" "origin/$BRANCH"
    else
      git checkout -B "$BRANCH"
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

finalizer:
  auto_commit_uncommitted: true
  push_branch: true
  open_pr: true
  close_issue: false
  merge_pr: false
---

You are working on GitHub issue {{ issue.identifier }}.

Branch:
{{ issue.branch_name }}

Title:
{{ issue.title }}

Issue body:
{{ issue.description }}

Your task:
- Make the smallest complete change that satisfies the issue.
- Work only inside the current repository checkout.
- Do not edit files outside the workspace.
- Use the existing branch. Do not create a different branch.
- Run the strongest relevant validation available in this repository.
- Create a local commit if you make changes.
- Do not push.
- Do not create a pull request.
- Do not comment on the issue.
- Do not close the issue.
- Do not merge pull requests.
- Do not delete branches.
- At the end, print a concise summary with:
  - files changed
  - validation run
  - remaining blockers
