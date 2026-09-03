#!/usr/bin/env bash
# Runs every *.test.sh in this directory.
#
# These tests exercise the shell embedded in actions/deploy/action.yml by
# extracting it and running it, so they test the code that ships rather than a
# transcription of it. actionlint cannot read a composite action at all, so for
# that file this suite and validate.yml's extractor are the only checks there
# are. They need bash, awk and git - nothing installed, no
# network - so a broken change is caught before any download-dependent step
# starts.
#
# What they cannot do is test a deploy. There is no host here and no
# credentials, so nothing below exercises rsync, ssh, or the server-side layout.
# Covering that means running the pipeline against a real account by borrowing a
# consumer's staging environment - a manual procedure, not something you can run
# from here. MAINTAINING.md, "Testing a change before tagging", is the
# checklist.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

failed=0
ran=0

for test in ./*.test.sh; do
  [ -e "$test" ] || continue
  ran=$((ran + 1))
  echo "=== ${test#./}"
  if bash "$test"; then
    echo
  else
    failed=$((failed + 1))
    echo
  fi
done

if [ "$ran" -eq 0 ]; then
  echo "::error::No test files found - the runner is looking in the wrong place."
  exit 1
fi

if [ "$failed" -ne 0 ]; then
  echo "::error::${failed} of ${ran} test file(s) failed."
  exit 1
fi

echo "${ran} test file(s) passed."
