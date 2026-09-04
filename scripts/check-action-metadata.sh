#!/usr/bin/env bash
#
# Thin wrapper so CI and the VS Code task run one thing. The check itself is
# check-action-metadata.js - see its header for what it enforces and why it
# parses the YAML rather than scanning lines.
#
# js-yaml is resolved rather than assumed: CI installs it in an earlier step,
# the dev container has it, and a bare clone gets a clear instruction instead of
# a stack trace.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

if ! command -v node >/dev/null 2>&1; then
  echo "::error::node is required. It is on every GitHub runner and in the dev container."
  exit 1
fi

resolved=""
for candidate in node_modules/js-yaml "$(npm root -g 2>/dev/null)/js-yaml"; do
  [ -n "$candidate" ] || continue
  if [ -d "$candidate" ]; then
    resolved=$(cd "$candidate" && pwd)
    break
  fi
done

if [ -z "$resolved" ]; then
  echo "::error::js-yaml not found. Run: npm install --no-save js-yaml@4.1.0"
  exit 1
fi

exec node scripts/check-action-metadata.js "$resolved"
