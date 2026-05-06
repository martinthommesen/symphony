# Installer

Symphony ships with two install scripts in the repository root:

* `scripts/install-symphony.sh` – fresh install on a new machine.
* `scripts/setup-symphony-copilot.sh` – compatibility wrapper over the generic installer.

## Prerequisites

* Elixir ~> 1.19 (via `mise` or system package manager)
* Bun for the TUI, or npm so the installer can place Bun under `.symphony/runtime/bun`
* Node.js >= 18 (for acpx if using JS-based agents)
* `git` and `gh` CLI authenticated to your target repository
* `acpx` binary on `$PATH`

## Quick Start

```bash
cd your-repo
bash scripts/install-symphony.sh
```

The script will:

1. Verify prerequisites (`symphony-doctor.sh`).
2. Create `.symphony/` directories (logs, workspaces, cache).
3. Generate `.symphony/config.yml` and `.symphony/WORKFLOW.md` with GitHub/acpx defaults.
4. Create GitHub labels (`symphony/agent/codex`, `symphony/agent/claude`, etc.).
5. Print next steps (set env vars, start the orchestrator).

## What the Script Does Not Do

* It installs acpx into `.symphony/runtime/acpx` when `--install-missing` is passed and npm is available.
* It installs Bun into `.symphony/runtime/bun` when `--install-missing` is passed and npm is available.
* It installs Elixir/Erlang into `.symphony/runtime/mise` when `--install-missing` is passed and mise is available.
* It does **not** create GitHub tokens – authenticate `gh` beforehand.
* It does **not** start the orchestrator as a daemon – use `mix phx.server` or your own systemd unit.

## Updating

Re-run `install-symphony.sh` to regenerate labels or repair `.symphony/` paths. It is idempotent: existing config and workflow files are left untouched.

## Uninstalling

Remove `.symphony/` and `WORKFLOW.md`. No third-party binaries are committed to the repository.
