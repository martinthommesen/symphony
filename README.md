# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## GitHub Issues + Copilot CLI quickstart

This fork ports the reference Elixir implementation from Linear/Codex to
GitHub Issues and the GitHub Copilot CLI in autonomous mode.

### Prerequisites

- [`gh`](https://cli.github.com/) – authenticated (`gh auth login`)
- [`copilot`](https://docs.github.com/en/copilot/github-copilot-in-the-cli) – authenticated (`copilot login`); requires Node.js >= 22 if installing via npm
- Elixir + Erlang via [mise](https://mise.jdx.dev/) (for building Symphony)

### Setup

From the root of the GitHub-backed repository you want to wire up:

```bash
scripts/setup-symphony-copilot.sh
```

The script is idempotent. It:

1. Validates that `origin` is a GitHub remote, derives `owner/repo`.
2. Verifies `gh` and `copilot` are installed and authenticated.
3. Vendors Symphony into `$XDG_DATA_HOME/symphony-copilot`.
4. Builds Symphony when `mix` is available.
5. Creates the `symphony`, `symphony/blocked`, `symphony/running`,
   `symphony/done`, `symphony/failed`, and `symphony/review` labels.
6. Writes `.symphony/WORKFLOW.md`, `.symphony/config.yml`, and the
   `scripts/symphony-{start,stop,status}.sh` wrappers.
7. Appends `.symphony/logs/` to `.gitignore`.

### Daily use

```bash
scripts/symphony-start.sh    # start orchestrator (HTTP API on 127.0.0.1)
scripts/symphony-tui.sh      # OpenTUI operations cockpit
scripts/symphony-status.sh   # show current state and active issues
scripts/symphony-stop.sh     # stop orchestrator
```

### OpenTUI operations cockpit

`scripts/symphony-tui.sh` launches a terminal cockpit that talks to the
running Symphony backend over an authenticated HTTP/SSE API. It needs
[Bun](https://bun.sh) (the OpenTUI renderer uses Bun's FFI). The cockpit
provides:

- live overview, issue list, agent stream, controls, analytics, logs
- pause/resume polling, dispatch/stop/retry/block individual issues
- read-only mode whenever no control token is configured

`scripts/setup-symphony-copilot.sh` writes a 32-byte hex token to
`.symphony/control-token` (mode 600) and adds it to `.gitignore`. Override
with `SYMPHONY_CONTROL_TOKEN`. See
[`docs/opentui-dashboard.md`](docs/opentui-dashboard.md) for the full
keybinding reference and security posture.


Create or label any issue with `symphony` to dispatch a run. Symphony will:

1. Add `symphony/running` to claim the issue.
2. Create an isolated workspace and check out `symphony/issue-<number>`.
3. Invoke `copilot --autopilot --yolo` with the rendered workflow prompt.
4. Validate the working branch and commits.
5. Push the branch, open a PR (`Related to #<number>`), and comment on the
   issue.
6. Move the label from `symphony/running` to `symphony/review`.

### Label semantics

| Label                | Meaning                                                                  |
| -------------------- | ------------------------------------------------------------------------ |
| `symphony`           | Eligible candidate                                                       |
| `symphony/blocked`   | Skip (will not be dispatched)                                            |
| `symphony/running`   | Cross-instance lock (Symphony is currently working on this issue)        |
| `symphony/review`    | Symphony finished; review the linked PR                                  |
| `symphony/failed`    | The run failed; remove or set `retry_failed: true` to retry              |
| `symphony/done`      | Optional terminal label (not set automatically)                          |

### How to retry a failed issue

Either remove the `symphony/failed` label, or set `tracker.retry_failed: true`
in `.symphony/WORKFLOW.md`.

### How to block an issue

Add the `symphony/blocked` label. Symphony will skip the issue while the
label is present.

### Security model

`copilot --autopilot --yolo` grants the agent broad permissions inside its
working directory. **It is not a sandbox.** Symphony enforces guardrails at
the orchestration layer:

- isolated per-issue workspaces
- argv-only command construction (no shell interpolation)
- `--deny-tool='shell(git push)'`, `--deny-tool='shell(gh pr)'`,
  `--deny-tool='shell(gh issue)'` where supported
- pre-push branch validation
- token redaction on every log path
- no auto-merge, no auto-close

### Live e2e

```bash
SYMPHONY_LIVE_GITHUB_REPO=owner/repo make e2e-github
```

This mode creates a disposable issue, runs Symphony end-to-end, and asserts
PR creation and label transitions. It does not auto-close the disposable
issue or merge the PR.

See [MIGRATION_NOTES.md](MIGRATION_NOTES.md) for the Linear→GitHub mapping.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
