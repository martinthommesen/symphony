#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/.agents/init.sh" "$@"
