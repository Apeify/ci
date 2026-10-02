#!/usr/bin/env bash
#
# Print what this run is deploying, and which version of this action is doing
# it, at the top of the log.
#
# Run by the "Show deploy target" step of actions/deploy/action.yml.
#
# Inputs, as environment variables:
#   RESOLVED_ENVIRONMENT  The action's `environment` input.
#   BRANCH                The branch or tag the run is for (github.ref_name).
#   SITE_URL              The action's `site-url` input.
#   ACTION_REPOSITORY     The repository this action was loaded from
#                         (github.action_repository).
#   ACTION_REF            The ref the caller's `uses:` named for this action
#                         (github.action_ref): a SHA when pinned.
#
# Outputs: none. Log lines only.
#
# Never fails.

# The options GitHub gives an inline bash step, which this was written against.
set -eo pipefail

echo "Branch:       ${BRANCH}"
echo "Environment:  ${RESOLVED_ENVIRONMENT}"
echo "Site URL:     ${SITE_URL}"
# Which version of this action ran, straight from GitHub rather than a
# hand-maintained version string.
#
# Read it for what it is: action_ref is the LITERAL ref written in the
# caller's `uses:`. Pinned by SHA it is the SHA and answers the question
# exactly; tracking a branch it says "main", which identifies the branch
# and not the commit. The reusable-workflow form of this logged
# job.workflow_sha, which was always a commit - that resolution is not
# available to an action, and it is one more reason to pin by SHA.
echo "Pipeline:     ${ACTION_REPOSITORY}"
echo "Pipeline ref: ${ACTION_REF}"
