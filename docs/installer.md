# Installer

`scripts/install-symphony.sh` creates the managed `.symphony/` layout,
checks GitHub and acpx prerequisites, creates labels, and writes starter config.
When requested with `--install-missing`, it installs acpx into
`.symphony/runtime/acpx`, Bun into `.symphony/runtime/bun` through npm, and
Elixir/Erlang into `.symphony/runtime/mise` when `mise` is available.

`scripts/symphony-doctor.sh` reports dependency, authentication, runtime, log,
and workspace health. Underlying agent CLIs may be invoked only for
prerequisite checks such as `--version`. Installer and doctor events are logged
to `.symphony/logs/installer.ndjson` and `.symphony/logs/doctor.ndjson`.
