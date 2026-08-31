#!/usr/bin/env bash
#
# Runs actionlint over every workflow in this repository.
#
# WHY THIS EXISTS
#
# The invocation used to be a pair of globs, `.github/workflows/*.yml` and
# `examples/*.yml`, repeated in CI, the VS Code task, the dev container's
# closing hint, and two documents. That worked only while everything under
# examples/ was a workflow. examples/dependabot.yml is not one - it is Dependabot
# configuration, which a consumer copies to .github/dependabot.yml - and
# actionlint reports four errors on it ("jobs" section is missing, unexpected
# key "version", and so on), none of which mean anything.
#
# WHY IT SELECTS BY DIRECTORY
#
# examples/ is laid out to mirror where each file goes in a consuming repo:
# examples/workflows/ holds what belongs in .github/workflows/, and
# examples/dependabot.yml is what belongs beside it at .github/dependabot.yml.
# That makes the directory the declaration of intent, so everything in
# examples/workflows/ is linted unconditionally.
#
# An earlier version selected by CONTENT instead - any examples/*.yml with a
# top-level `on:` key - because the directory did not yet carry that meaning.
# Content selection has a failure mode the directory does not: a stub that LOST
# its `on:` key would be silently skipped rather than reported, and a broken stub
# is worse than no stub because it gets copied. Linting the directory means
# actionlint sees that file and says "on section is missing in workflow".
#
# WHY IT IS A SCRIPT
#
# Same reason as check-readme-examples.sh: CI and the local task must run the
# identical thing, and the way to guarantee that is for both to call one file.
#
# The binary is taken from $ACTIONLINT so CI can point at the pinned copy it
# downloads to /tmp, while the dev container just uses the one on PATH.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

ACTIONLINT="${ACTIONLINT:-actionlint}"

# Both extensions everywhere. GitHub accepts either in .github/workflows,
# validate.yml's extractor already matches /\.ya?ml$/, and .github/actionlint.yaml
# scopes its own suppression to **/*.{yml,yaml} - so a workflow added as .yaml is
# a shape the rest of the repo already expects. Globbing only *.yml would skip it
# WITHOUT tripping the guards below, because the existing .yml files keep each
# count non-zero.
collect() {
  local dir="$1" file
  for file in "$dir"/*.yml "$dir"/*.yaml; do
    [ -e "$file" ] || continue
    printf '%s\n' "$file"
  done
}

mapfile -t workflows < <(collect .github/workflows)
mapfile -t stubs < <(collect examples/workflows)

# Not a formality. If either glob matches nothing - a moved directory, a renamed
# extension - actionlint would be handed a short list and exit 0, reporting
# success for a run that checked none of the files it was meant to.
if [ ${#workflows[@]} -eq 0 ]; then
  echo "::error::No workflows found in .github/workflows/ - refusing to report success."
  exit 1
fi

if [ ${#stubs[@]} -eq 0 ]; then
  echo "::error::No stubs found in examples/workflows/ - refusing to report success."
  echo "Every stub a consumer copies must be linted; failing here rather than skipping them."
  exit 1
fi

printf 'linting: %s\n' "${workflows[@]}" "${stubs[@]}"
exec "$ACTIONLINT" -color "${workflows[@]}" "${stubs[@]}"
