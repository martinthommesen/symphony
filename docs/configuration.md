# Configuration

Runtime configuration lives in `.symphony/config.yml`. The workflow prompt lives
in `.symphony/WORKFLOW.md`.

The config file contains tracker labels, agent routing, the agent registry, acpx
settings, model overrides, workspace/worktree policy, commit and PR behavior,
validation, self-correction, and structured logging.

Workspace policy fields include:

```yaml
workspace:
  root: .symphony/workspaces
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
```

When `git_worktree_enabled` is true, Symphony creates the issue workspace with
`git worktree add`, owns branch naming, applies the configured dirty-worktree
policy, and can fetch/rebase before running acpx.
