#!/usr/bin/env bash
#
# Combine the two syncs' figures into the totals the action publishes, and
# stamp the finish time.
#
# Separate from the syncs because the app sync is skipped for a site with no
# private tree, and a skipped step's outputs are empty strings. Every figure
# below defaults to 0, so the totals stay correct rather than becoming blank.
#
# Runs on the success path only. If any earlier step failed this never runs and
# every output is unset - the documented behavior of action outputs, and the
# reason diagnosis belongs in the log rather than here.
#
# Run by the "Summarize the deploy" step of actions/deploy/action.yml.
#
# Inputs, as environment variables (all may be empty):
#   PUBLIC_TRANSFERRED  sync-public.sh's files-transferred.
#   PUBLIC_BYTES        sync-public.sh's bytes-transferred.
#   PUBLIC_DELETED      sync-public.sh's paths-deleted.
#   APP_TRANSFERRED     sync-app.sh's files-transferred. Empty when skipped.
#   APP_BYTES           sync-app.sh's bytes-transferred. Empty when skipped.
#   APP_DELETED         sync-app.sh's paths-deleted. Empty when skipped.
#   STARTED_EPOCH       preflight.sh's started-epoch.
#   PIPELINE_REF        The ref the caller's `uses:` named for this action
#                       (github.action_ref).
#
# Outputs, to $GITHUB_OUTPUT, re-published as the action's outputs:
#   files-transferred, bytes-transferred, paths-deleted
#                       Totals across both syncs.
#   changed             'true' when anything transferred or was deleted.
#   finished-at         UTC ISO 8601 time this step ran.
#   duration-seconds    Seconds since STARTED_EPOCH.
#   pipeline-ref        PIPELINE_REF, passed through.
#
# Never fails on its own.

# The options GitHub gives an inline bash step, which this was written against.
set -eo pipefail

transferred=$(( ${PUBLIC_TRANSFERRED:-0} + ${APP_TRANSFERRED:-0} ))
bytes=$(( ${PUBLIC_BYTES:-0} + ${APP_BYTES:-0} ))
deleted=$(( ${PUBLIC_DELETED:-0} + ${APP_DELETED:-0} ))

finished_epoch=$(date -u +%s)

{
  echo "files-transferred=${transferred}"
  echo "bytes-transferred=${bytes}"
  echo "paths-deleted=${deleted}"
  echo "finished-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "duration-seconds=$(( finished_epoch - ${STARTED_EPOCH:-finished_epoch} ))"
  echo "pipeline-ref=${PIPELINE_REF}"
  if [ "$transferred" -gt 0 ] || [ "$deleted" -gt 0 ]; then
    echo "changed=true"
  else
    echo "changed=false"
  fi
} >> "$GITHUB_OUTPUT"

echo "deploy summary: ${transferred} file(s) transferred, ${deleted} deleted, ${bytes} byte(s)"
