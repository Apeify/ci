#!/usr/bin/env bash
#
# Refuse to deploy unless there is actually something to deploy.
#
# This is not merely about a half-built repo. `rsync --delete` with a MISSING
# source fails safely, but with an EMPTY public directory it SUCCEEDS and
# empties the live web root. So the public directory must exist and be
# non-empty - and nothing more specific than that: requiring, say, index.php
# would tie the check to one framework's front controller, when the condition
# that matters is simply "is there anything to deploy".
#
# The app directory, when the site has one, must exist. A missing one is an
# error rather than a skip, because a skip would let a typo in app-dir deploy
# the public tree while its backing code silently went stale.
#
# Run by the "Check target layout is present" step of
# actions/deploy/action.yml, in the root of the caller's checkout. Both rsync
# steps run only when its `ready` output is 'true'.
#
# Inputs, as environment variables:
#   PUBLIC_DIR          The action's `public-dir` input.
#   APP_DIR             The `app-dir` input.
#   DEPLOY_APP_DIR      The `deploy-app-dir` input: 'true' when APP_DIR must
#                       exist.
#
# Outputs, to $GITHUB_OUTPUT:
#   ready               'true' when the layout is present.
#
# Exits 1 with an ::error:: annotation when it is not.

# The options GitHub gives an inline bash step, which this was written against.
set -eo pipefail

# The EMPTY case is the one that matters. rsync --delete with a
# MISSING source fails safely, but with an empty source directory it
# SUCCEEDS and empties the live web root. So check for content, not
# just existence.
#
# Checks the directory is non-empty rather than looking for a specific
# front controller: which file that is depends on the framework, and
# this workflow should not need to know.
if [ ! -d "$PUBLIC_DIR" ] || [ -z "$(ls -A "$PUBLIC_DIR" 2>/dev/null)" ]; then
  echo "::error::${PUBLIC_DIR}/ is missing or empty - refusing to deploy."
  exit 1
fi

# Only required when the site actually has a private tree. A missing
# app directory is a hard error rather than a silent skip: if it were
# a skip, a typo in app-dir would deploy the public tree while its
# backing code silently went stale.
if [ "$DEPLOY_APP_DIR" = "true" ] && [ ! -d "$APP_DIR" ]; then
  echo "::error::${APP_DIR}/ is missing - refusing to deploy."
  echo "If this site has no private directory, pass 'deploy-app-dir: false' instead."
  exit 1
fi

echo "ready=true" >> "$GITHUB_OUTPUT"
echo "Target layout present - deploying."
