#!/usr/bin/env bash
#
# Assert that every stub in examples/ matches the block reproduced inline in
# README.md.
#
# WHY THIS EXISTS
#
# The README reproduces each example so it can be read without navigating away.
# That duplication would drift - this repo has already produced several cases of
# documentation quietly disagreeing with behavior - so the two are compared
# mechanically rather than trusted.
#
# WHY IT IS A SCRIPT AND NOT INLINE IN THE WORKFLOW
#
# Both CI (.github/workflows/validate.yml) and the local VS Code task
# (.vscode/tasks.json) run it. Inlining it in the workflow and copying it into
# the task would reintroduce the exact class of drift this check exists to
# prevent, one level up.
#
# HOW BLOCKS ARE FOUND
#
# Each block is delimited in README.md by an HTML comment naming the file it
# mirrors - `<!-- example:examples/workflows/deploy.yml -->` immediately before
# the ```yaml fence.
# HTML comments are invisible when rendered, and an explicit marker is far more
# robust than inferring the block from a nearby heading.
#
# THE FILE IS THE SOURCE OF TRUTH. If this fails, regenerate the README block
# from the file, never the other way around.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

fail=0
checked=0

# examples/ mirrors where each file goes in a consuming repo: workflows/ for
# .github/workflows/, and dependabot.yml for beside it. Both levels are compared,
# and both extensions, matching scripts/lint-workflows.sh - a stub added as .yaml
# would otherwise skip this comparison silently.
#
# The marker is the repo-relative PATH, not the basename, so it identifies the
# file unambiguously and two examples can share a filename across directories.
for file in examples/*.yml examples/*.yaml examples/workflows/*.yml examples/workflows/*.yaml; do
  [ -e "$file" ] || continue
  name="$file"
  checked=$((checked + 1))

  extracted="$(mktemp)"

  awk -v marker="<!-- example:${name} -->" '
    $0 == marker         { found = 1; next }
    found && /^```yaml$/ { inblock = 1; next }
    inblock && /^```$/   { exit }
    inblock              { print }
  ' README.md > "$extracted"

  # An empty extraction means the marker is missing or malformed. Treated as a
  # failure rather than a skip: otherwise deleting a marker would silently
  # disable the comparison for that file, which is worse than never having had
  # the check.
  if [ ! -s "$extracted" ]; then
    echo "::error file=README.md::No fenced block found for ${name}. Expected a '<!-- example:${name} -->' marker immediately before a \`\`\`yaml fence."
    fail=1
    rm -f "$extracted"
    continue
  fi

  if diff -u "$file" "$extracted"; then
    echo "README block matches ${file}"
  else
    echo "::error file=README.md::README block for ${name} does not match ${file}."
    echo "The file is the source of truth - update the README block to match it."
    fail=1
  fi

  rm -f "$extracted"
done

if [ "$checked" -eq 0 ]; then
  echo "::error::No files found in examples/ - is the extractor looking in the right place?"
  exit 1
fi

exit "$fail"
