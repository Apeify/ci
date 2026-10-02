#!/usr/bin/env bash
#
# Layer 1 of this repo's checks: every workflow, example and composite action
# parses as YAML, every action follows the rules actionlint cannot check, and
# the shell in every `run:` block parses as bash.
#
# The YAML half is check-workflow-structure.js - see its header for what it
# checks and why. This wrapper finds Node and js-yaml, runs it into a scratch
# directory, and then runs `bash -n` over every block it wrote out.
#
# CI and the VS Code "Check workflow structure" task both run this file, so
# the two cannot disagree. It used to live inline in validate.yml, as
# JavaScript in a heredoc inside YAML, which left it unlinted and made it the
# one layer that could not be run locally.
#
# Run from anywhere: `bash scripts/check-workflow-structure.sh`.
#
# Inputs: none. It reads the repository it lives in. Needs node, and js-yaml
# installed in ./node_modules or globally (`npm install --no-save
# js-yaml@4.1.0`).
#
# Outputs: none. Log lines, ::error:: annotations, and a scratch directory it
# removes on exit.
#
# Exits 1 if any file fails to parse, any action breaks a rule, or any `run:`
# block is not valid bash.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# shellcheck source=lib/js-yaml.sh
source scripts/lib/js-yaml.sh

require_node || exit 1
js_yaml=$(resolve_js_yaml) || exit 1

steps=$(mktemp -d)
trap 'rm -rf "$steps"' EXIT

node scripts/check-workflow-structure.js "$js_yaml" "$steps" || exit 1

fail=0
for s in "$steps"/*.sh; do
  if ! bash -n "$s" 2>"${steps}/err"; then
    echo "::error::bash syntax error in $(basename "$s")"
    sed 's/^/    /' "${steps}/err"
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "all run-steps parse as bash"
exit "$fail"
