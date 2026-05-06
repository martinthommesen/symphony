# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors work and delegates implementation to coding agents. Engineers manage the work at a higher level while Symphony owns the GitHub, workspace, validation, and PR lifecycle._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## GitHub Issues + acpx Quickstart

Symphony is an agent-agnostic GitHub Issues orchestrator. Issue labels select
a configured agent id, and Symphony delegates runtime agent execution only
through [acpx](https://github.com/openclaw/acpx). acpx handles delegation to
the selected underlying coding agent.

### Prerequisites

- [`gh`](https://cli.github.com/) – authenticated (`gh auth login`)
- [`acpx`](https://github.com/openclaw/acpx) – the only runtime execution surface
- At least one configured underlying agent CLI, used by installer/doctor only for prerequisite/auth checks
- Elixir + Erlang via [mise](https://mise.jdx.dev/) (for building Symphony)
- Bun for the TUI configuration console

### Setup

From the root of the GitHub-backed repository you want to wire up:

```bash
scripts/install-symphony.sh
```

The script is idempotent. It:

1. Validates that `origin` is a GitHub remote, derives `owner/repo`.
2. Verifies `gh`, acpx, and configured agent prerequisites.
3. Vendors Symphony into `$XDG_DATA_HOME/symphony`.
4. Builds Symphony when `mix` is available.
5. Creates the default dispatch, state, and `symphony/agent/<agent-id>` labels.
6. Writes `.symphony/WORKFLOW.md`, `.symphony/config.yml`, and the
   `scripts/symphony-{start,stop,status,tui}.sh` wrappers.
7. Appends `.symphony/logs/` to `.gitignore`.

### Daily use

```bash
scripts/symphony-start.sh    # start orchestrator (HTTP API on 127.0.0.1)
scripts/symphony-tui.sh      # OpenTUI operations cockpit
scripts/symphony-status.sh   # show current state and active issues
scripts/symphony-tui.sh view # view runtime config
scripts/symphony-tui.sh cockpit # open OpenTUI operations cockpit
scripts/symphony-stop.sh     # stop orchestrator
```

Create or label any issue with `symphony` to dispatch a run. Add one agent
label such as `symphony/agent/codex`, `symphony/agent/claude`, or
`symphony/agent/copilot` to override the configured default agent. Symphony
will:

1. Add `symphony/running` to claim the issue.
2. Create an isolated workspace and check out `symphony/issue-<number>`.
3. Spawn the configured acpx executable with the selected agent as argv.
4. Validate the working branch and commits.
5. Push the branch, open a PR (`Related to #<number>`), and comment on the
   issue.
6. Move the label from `symphony/running` to `symphony/review`.

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

### Label semantics

| Label                | Meaning                                                                  |
| -------------------- | ------------------------------------------------------------------------ |
| `symphony`           | Eligible candidate                                                       |
| `symphony/blocked`   | Skip (will not be dispatched)                                            |
| `symphony/running`   | Cross-instance lock (Symphony is currently working on this issue)        |
| `symphony/review`    | Symphony finished; review the linked PR                                  |
| `symphony/failed`    | The run failed; remove or set `retry_failed: true` to retry              |
| `symphony/done`      | Optional terminal label (not set automatically)                          |
| `symphony/agent/*`   | Selects the configured acpx-backed agent                                 |

### How to retry a failed issue

Either remove the `symphony/failed` label, or set `agents.routing.retry_failed: true`
in `.symphony/config.yml`.

### How to block an issue

Add the `symphony/blocked` label. Symphony will skip the issue while the
label is present.

### Security model

acpx normalizes agent execution. **It is not a sandbox.** Symphony workspace
isolation is not host isolation, and high-autonomy agents can execute commands
inside the workspace through their tools. Symphony enforces guardrails at the
orchestration layer:

- isolated per-issue workspaces
- argv-only command construction (no shell interpolation)
- pre-push branch validation
- token redaction on every log path
- no auto-merge, no auto-close
- bounded retries and structured audit logs

### Live e2e

```bash
SYMPHONY_LIVE_GITHUB_REPO=owner/repo make e2e-github
```

This mode creates a disposable issue, runs Symphony end-to-end, and asserts
PR creation and label transitions. It does not auto-close the disposable
issue or merge the PR.

### More Docs

- [Agent routing](docs/agent-routing.md)
- [acpx runner](docs/acpx-runner.md)
- [Configuration](docs/configuration.md)
- [TUI configuration](docs/tui-configuration.md)
- [Self-correction](docs/self-correction.md)
- [Logging](docs/logging.md)
- [Installer](docs/installer.md)
- [Security](docs/security.md)
- [Migration notes](docs/migration-notes.md)

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
