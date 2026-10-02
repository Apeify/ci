#!/usr/bin/env bash
#
# Check the shape of the handoff from the minify workflow, and say which
# artifact to download.
#
# Runs early so a stub that never passed `minified-assets` fails in the first
# seconds with a sentence naming the fix. Only the SHAPE is checked here:
# whether the artifact matches this checkout is apply-minified-assets.sh's
# job, after the download.
#
# Also clears the download directory, so a leftover from an earlier step in
# the caller's job cannot pass for the artifact.
#
# Run by the "Check the minified-assets handoff" step of
# actions/deploy/action.yml. Its artifact-id output decides whether the next
# step downloads anything.
#
# Inputs, as environment variables:
#   MINIFIED_ASSETS     The action's `minified-assets` input: `none`, or
#                       `<artifact-id>:<sha256>` from minify.yml.
#   DOWNLOAD_DIR        Where the artifact will be downloaded. Removed here.
#
# Outputs, to $GITHUB_OUTPUT:
#   artifact-id         The artifact to download, or empty for `none`.
#
# Exits 1 with an ::error:: annotation when the input is empty or is not a
# value minify.yml produces.

# The options GitHub gives an inline bash step, which this was written against.
set -eo pipefail

rm -rf "$DOWNLOAD_DIR"

if [ "$MINIFIED_ASSETS" = "none" ]; then
  echo "artifact-id=" >> "$GITHUB_OUTPUT"
  echo "The minify job found no CSS or JS to minify."
  exit 0
fi

if [ -z "$MINIFIED_ASSETS" ]; then
  echo "::error::The 'minified-assets' input is empty."
  echo "Add a minify job calling Apeify/ci's minify.yml, and pass"
  echo "'needs.minify.outputs.minified-assets'. See the README's Minification section."
  exit 1
fi

if ! [[ "$MINIFIED_ASSETS" =~ ^[0-9]+:[0-9a-f]{64}$ ]]; then
  echo "::error::The 'minified-assets' input is not a value the minify workflow produces."
  echo "Pass 'needs.minify.outputs.minified-assets' unchanged, not a literal."
  exit 1
fi

echo "artifact-id=${MINIFIED_ASSETS%%:*}" >> "$GITHUB_OUTPUT"
