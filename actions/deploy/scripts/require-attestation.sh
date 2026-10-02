#!/usr/bin/env bash
#
# Refuse to deploy unless this run's lint-and-test job really ran.
#
# The lint-and-test job cannot be skipped - the stub's deploy job reads its
# outputs, so it must exist and be listed in `needs` - but it CAN be
# miswired: a stub that passes a literal string instead of the job's output
# would defeat the point. This checks the value is exactly the one that job
# emits for this run. It is cheap, and it runs before the SSH key is ever
# written.
#
# Run as the first step of actions/deploy/action.yml ("Require the lint and
# test job").
#
# Inputs, as environment variables:
#   ATTESTATION         The action's `attestation` input. Must be exactly
#                       `lint-and-test:<run id>:<run attempt>`, which is what
#                       lint-and-test.yml publishes.
#
# Also reads, set by the runner: GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT.
#
# Outputs: none.
#
# Exits 1 with an ::error:: annotation when the value does not match.

# The options GitHub gives an inline bash step, which this was written against.
set -eo pipefail

# An EXACT match against the value lint-and-test.yml emits, not a
# prefix. `lint-and-test:*` accepted the literal string
# `lint-and-test:skip`, which is precisely the hand-written value this
# is supposed to reject. GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT are
# identical in the caller's job, so the expected value is computable
# here.
#
# Be clear about what this does and does not prove. It shows that some
# job in THIS run emitted the string; it cannot show that this job
# declared `needs: lint-and-test`. The real guarantee is structural and
# lives elsewhere: a job calling a reusable workflow cannot also declare
# `steps:`, so the two halves cannot share a runner. This check only
# raises forging it from typing a constant to adding a job that
# reproduces the run id.
expected="lint-and-test:${GITHUB_RUN_ID}:${GITHUB_RUN_ATTEMPT}"
if [ "$ATTESTATION" != "$expected" ]; then
  echo "::error::attestation input did not come from this run's lint-and-test job."
  echo "Pass 'needs.lint-and-test.outputs.attestation' rather than a literal."
  echo "That job runs in a separate VM, which is what keeps third-party test code off"
  echo "the runner holding the deploy key."
  exit 1
fi
