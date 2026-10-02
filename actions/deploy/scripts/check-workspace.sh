#!/usr/bin/env bash
#
# Check the caller has already checked out the repository, with full history.
#
# This action does NOT check out for itself. It runs in the caller's job,
# where a checkout has already happened, and `actions/checkout` defaults to
# `clean: true` - `git clean -ffdx`. Doing it again would silently delete
# anything the caller built between their checkout and this action: compiled
# assets, a `composer install --no-dev` tree, a generated config. An action
# that destroys its caller's workspace is a bad neighbor, so this asks for
# what it needs instead of taking it.
#
# Full history is a real requirement, not a preference: restore-mtimes.sh
# dates every file from its last commit, and a shallow clone silently dates
# only what it has. Checked here so a missing `fetch-depth: 0` fails with a
# sentence naming the fix, rather than as a deploy that re-transfers the whole
# tree every run for reasons nobody can see.
#
# Run by the "Check the workspace" step of actions/deploy/action.yml, in the
# root of the caller's checkout.
#
# Inputs: none. It inspects the working directory.
#
# Outputs: none.
#
# Exits 1 with an ::error:: annotation when there is no checkout, or it is
# shallow.

# The options GitHub gives an inline bash step, which this was written against.
set -eo pipefail

if [ ! -d .git ]; then
  echo "::error::No checkout found. Add actions/checkout before this action:"
  echo ""
  echo "    - uses: actions/checkout@<sha>"
  echo "      with:"
  echo "        fetch-depth: 0"
  exit 1
fi

if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  echo "::error::The checkout is shallow. Add 'fetch-depth: 0' to actions/checkout."
  echo "The mtime restore dates each file from its last commit, which needs full history."
  exit 1
fi
