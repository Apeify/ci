#!/usr/bin/env bash
#
# Replace the checkout's CSS and JS with the minified copies minify.yml
# produced, after checking every byte of the artifact against this checkout.
#
# No third-party code runs in the deploy job to do this. The minifier runs in
# minify.yml's own job, because a step in this job could read every secret the
# job was given from the runner's memory - see the header of
# .github/workflows/minify.yml. So the artifact is untrusted input, and it is
# checked as such before anything reaches the tree that gets rsynced:
#
#   - Its file list must EQUAL what this checkout's own discovery finds under
#     <public-dir>/assets. An extra file is refused, not ignored - that is the
#     one thing that stops a compromised minifier planting a .php file in a web
#     root. A missing file is refused too, since it would ship unminified.
#   - Every entry must be a regular file. A symlink could point anywhere on
#     this runner, ~/.ssh included, and the copy would follow it.
#   - The digest covers each file's SOURCE hash as well as its minified hash,
#     recomputed here from this checkout. A minified file is accepted only as
#     the replacement for the exact source it was made from - which also
#     catches a minify job `public-dir` that names a different directory from
#     this action's. The record format must match minify.yml's byte for byte;
#     tests/minified-assets.test.sh runs both and notices if they drift.
#   - The JS-validity and collapsed-file checks run again here, on what was
#     received, rather than trusting the other job's report of them.
#
# CSS or JS the caller built in THIS job, after checkout and before this
# action, is not covered: minify.yml never saw it, so it shows up as missing
# from the artifact and the deploy is refused. That is loud on purpose -
# shipping it unminified, or minifying it here, would each quietly undo
# something.
#
# The minified files are written over the source in the working tree only;
# the repo keeps the readable source and nothing is committed back. They get a
# fresh mtime, so they re-sync each deploy.
#
# Run by the "Apply minified assets" step of actions/deploy/action.yml, in the
# root of the caller's checkout, after the artifact (if any) was downloaded by
# the ID check-handoff.sh extracted.
#
# Inputs, as environment variables:
#   MINIFIED_ASSETS     The action's `minified-assets` input: `none`, or
#                       `<artifact-id>:<sha256>`. The digest is checked here.
#   PUBLIC_DIR          The action's `public-dir` input. Its assets/ subtree is
#                       what gets replaced.
#   DOWNLOAD_DIR        Where the artifact was downloaded.
#
# Outputs: none. Overwrites <PUBLIC_DIR>/assets/**/*.{css,js} in place.
#
# Exits 1 with an ::error:: annotation, leaving nothing deployed, when the
# artifact and the checkout disagree in any way above.

# The options GitHub gives an inline bash step, which this was written against.
set -eo pipefail

expected=()
if [ -d "$PUBLIC_DIR/assets" ]; then
  mapfile -d '' -t expected < <(
    cd "$PUBLIC_DIR" &&
      find assets -type f \( -name '*.css' -o -name '*.js' \) -print0 | LC_ALL=C sort -z
  )
fi

if [ "$MINIFIED_ASSETS" = "none" ]; then
  if [ ${#expected[@]} -ne 0 ]; then
    echo "::error::The minify job minified nothing, but ${PUBLIC_DIR}/assets here holds ${#expected[@]} CSS/JS file(s):"
    printf '  %s\n' "${expected[@]}"
    echo "Either the minify job's public-dir names a different directory from this action's,"
    echo "or those files were created in this job after checkout. Refusing to ship them unminified."
    exit 1
  fi
  echo "No CSS or JS to apply."
  exit 0
fi

if [ ${#expected[@]} -eq 0 ]; then
  echo "::error::The minify job minified CSS/JS, but ${PUBLIC_DIR}/assets here holds none."
  echo "The minify job's public-dir must name the same directory as this action's."
  exit 1
fi

if [ ! -d "$DOWNLOAD_DIR" ] || [ -L "$DOWNLOAD_DIR" ]; then
  echo "::error::The minified-assets artifact was not downloaded to ${DOWNLOAD_DIR}."
  exit 1
fi

# Everything that is not a directory must be a regular file...
entries=()
mapfile -d '' -t entries < <(
  cd "$DOWNLOAD_DIR" && find . -mindepth 1 ! -type d -print0 | LC_ALL=C sort -z
)
bad=0
for entry in "${entries[@]}"; do
  if [ -L "${DOWNLOAD_DIR}/${entry}" ] || [ ! -f "${DOWNLOAD_DIR}/${entry}" ]; then
    echo "::error::Artifact entry '${entry#./}' is not a regular file."
    bad=1
  fi
done
[ "$bad" -eq 0 ] || exit 1

# ...and the set of them must equal what discovery found here.
received=()
for entry in "${entries[@]}"; do
  received+=("${entry#./}")
done
if [ "$(printf '%s\0' "${received[@]}" | LC_ALL=C sort -z | sha256sum)" != \
     "$(printf '%s\0' "${expected[@]}" | sha256sum)" ]; then
  echo "::error::The minified-assets artifact does not hold exactly the CSS/JS this checkout has."
  echo "Expected (from ${PUBLIC_DIR}/assets here):"
  printf '  %s\n' "${expected[@]}"
  echo "Received:"
  printf '  %s\n' "${received[@]}"
  echo "Refusing to deploy. An extra file is never copied into the tree."
  exit 1
fi

records=$(mktemp)
for rel in "${expected[@]}"; do
  src_hash=$(sha256sum < "${PUBLIC_DIR}/${rel}" | cut -d' ' -f1)
  min_hash=$(sha256sum < "${DOWNLOAD_DIR}/${rel}" | cut -d' ' -f1)
  printf '%s\0%s\0%s\0' "$rel" "$src_hash" "$min_hash" >> "$records"
done
digest=$(sha256sum < "$records" | cut -d' ' -f1)
rm -f "$records"

if [ "$digest" != "${MINIFIED_ASSETS#*:}" ]; then
  echo "::error::The minified assets do not match the digest the minify job published."
  echo "Either the artifact changed after it was produced, or a file here differs from the"
  echo "source that job minified. Refusing to deploy."
  exit 1
fi

# Every GitHub-hosted runner has Node. Checked once, so a self-hosted
# runner without it is told so, rather than told every script it
# ships is invalid JavaScript.
if ! command -v node >/dev/null 2>&1; then
  echo "::error::node is not installed on this runner; it is needed to check the minified JavaScript."
  exit 1
fi

# Checked IN PLACE, after the copy, not in the download directory:
# `node --check` decides between ES module and CommonJS from the
# nearest package.json, so the same file can pass in the repo and fail
# in a temp directory, or the reverse. A refusal here fails the action
# before any sync step, so the copies already made never ship.
for rel in "${expected[@]}"; do
  f="${PUBLIC_DIR}/${rel}"
  before=$(wc -c < "$f")
  cp -- "${DOWNLOAD_DIR}/${rel}" "$f"
  after=$(wc -c < "$f")

  case "$rel" in
    *.js)
      if ! node --check "$f"; then
        echo "::error::$f: the minified file is not valid JavaScript - refusing to deploy."
        exit 1
      fi ;;
  esac

  if [ "$before" -gt 0 ] && [ "$after" -eq 0 ]; then
    echo "::error::$f collapsed from $before bytes to nothing - refusing to deploy."
    exit 1
  fi

  echo "$f: ${before} -> ${after} bytes"
done
