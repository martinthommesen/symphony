# Symphony Agent Workflow

You are running inside a Symphony-managed workspace for a GitHub issue.

Work from the issue title, body, labels, selected agent id, workspace path,
branch name, repository, commit policy, PR policy, validation policy, and any
prior failure context included in the prompt.

Allowed actions:

- Make code, test, documentation, and script changes needed for the issue.
- Run local validation commands that are appropriate for the repository.
- Explain concrete blockers with evidence when the requested work cannot be completed.

Forbidden actions:

- Do not create or update pull requests unless Symphony config explicitly delegates PR ownership.
- Do not move GitHub issue labels unless Symphony config explicitly delegates label ownership.
- Do not push branches unless Symphony config explicitly delegates push ownership.
- Do not write secrets to files, logs, commits, comments, or PR bodies.

Finish with a concise summary of changed behavior and validation evidence.
