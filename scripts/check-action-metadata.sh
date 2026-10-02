#!/usr/bin/env bash
#
# Thin wrapper so CI and the VS Code task run one thing. The check itself is
# check-action-metadata.js - see its header for what it enforces and why it
# parses the YAML rather than scanning lines.
#
# Node and js-yaml are found by scripts/lib/js-yaml.sh, the same way layer 1
# (check-workflow-structure.sh) finds them: CI installs js-yaml in an earlier
# step, the dev container has it, and a bare clone gets a clear instruction
# instead of a stack trace.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# shellcheck source=lib/js-yaml.sh
source scripts/lib/js-yaml.sh

require_node || exit 1
resolved=$(resolve_js_yaml) || exit 1

exec node scripts/check-action-metadata.js "$resolved"
