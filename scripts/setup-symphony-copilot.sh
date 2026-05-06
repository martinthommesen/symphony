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
      begin
        loaded = YAML.load_file(path)
      rescue Psych::SyntaxError => e
        warn "[symphony-setup] WARN: could not parse #{path}: #{e.message}"
        loaded = {}
      end
      config = loaded.is_a?(Hash) ? loaded : {}
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

TOKEN_FILE=".symphony/control-token"
if [[ ! -f "$TOKEN_FILE" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    TOKEN="$(openssl rand -hex 32)"
  elif [[ -r /dev/urandom ]]; then
    TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  else
    printf '[symphony-setup] WARN: no openssl or /dev/urandom available; skipping control-token generation.\n' >&2
    TOKEN=""
  fi

  if [[ -n "$TOKEN" ]]; then
    ( umask 077 && printf '%s\n' "$TOKEN" > "$TOKEN_FILE" )
    chmod 600 "$TOKEN_FILE" 2>/dev/null || true
    printf '[symphony-setup] Wrote %s (mode 600)\n' "$TOKEN_FILE"
  fi
fi

GITIGNORE=".gitignore"
touch "$GITIGNORE"
add_gitignore_line() {
  local line="$1"
  if ! grep -Fxq "$line" "$GITIGNORE"; then
    printf '%s\n' "$line" >> "$GITIGNORE"
    printf '[symphony-setup] Appended to .gitignore: %s\n' "$line"
  fi
}
add_gitignore_line ".symphony/logs/"
add_gitignore_line ".symphony/control-token"
add_gitignore_line ".symphony/*.token"
