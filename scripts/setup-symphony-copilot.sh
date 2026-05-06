#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Compatibility alias for older Copilot-focused setup instructions.
# Runtime execution still goes through acpx; this wrapper only asks the generic
# installer to create config whose default selected agent is Copilot.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

"$SCRIPT_DIR/install-symphony.sh" "$@"

CONFIG_PATH=".symphony/config.yml"
if [[ -f "$CONFIG_PATH" ]]; then
  if command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e '
      path = ARGV.fetch(0)
      config = YAML.load_file(path)
      config["agents"] ||= {}
      config["agents"]["routing"] ||= {}
      config["agents"]["routing"]["default_agent"] = "copilot"
      tmp = "#{path}.tmp"
      File.write(tmp, YAML.dump(config))
      File.rename(tmp, path)
    ' "$CONFIG_PATH"
  else
    printf '[symphony-setup] WARN: ruby not found; leaving default agent unchanged in %s\n' "$CONFIG_PATH" >&2
  fi
fi
