#!/usr/bin/env bash
# Tests for emit_transfer_stats, the helper behind the action's change outputs.
#
# It parses rsync's own reporting, which is the fragile part: `--stats` wording
# and number formatting vary by rsync version and locale, and the public sync
# runs rsync once per web root so every figure has to SUM across the log rather
# than read one block. A consumer gating a CDN purge or a "refuse if this would
# delete more than N files" tripwire on these numbers is trusting this parser.

# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=../actions/deploy/scripts/lib.sh
source "${DEPLOY_SCRIPTS}/lib.sh"

# The helper writes to $GITHUB_OUTPUT; give it one and read it back.
stats() {
  GITHUB_OUTPUT="${WORK}/out"
  : > "$GITHUB_OUTPUT"
  emit_transfer_stats "$1" >/dev/null
  cat "$GITHUB_OUTPUT"
}
field() { stats "$1" | sed -n "s/^$2=//p"; }

one_run() {
  cat > "${WORK}/log" <<'LOG'
sending incremental file list
*deleting   old/gone.html
*deleting   old/
>f+++++++++ index.html
>f.st...... about.html

Number of files: 1,234 (reg: 1,200, dir: 34)
Number of created files: 1
Number of regular files transferred: 2
Total file size: 5,678,901 bytes
Total transferred file size: 12,345 bytes
LOG
}

describe "a single rsync run"
one_run
assert_eq "2" "$(field "${WORK}/log" files-transferred)" "counts transferred files"
# One path per deleted file AND one per deleted directory: this fixture removes
# old/gone.html and old/, so the count is 2. That is the contract, not an
# accident of the fixture - a directory of three files would count four.
assert_eq "2" "$(field "${WORK}/log" paths-deleted)" "counts a deleted file and a deleted directory"
assert_eq "true" "$(field "${WORK}/log" changed)" "reports changed"
# Thousands separators are stripped rather than truncating the number at the
# comma, which would silently under-report every large deploy.
assert_eq "12345" "$(field "${WORK}/log" bytes-transferred)" "strips thousands separators"

describe "several web roots in one log must sum, not overwrite"
one_run
cat "${WORK}/log" "${WORK}/log" > "${WORK}/two"
assert_eq "4" "$(field "${WORK}/two" files-transferred)" "transferred sums across roots"
assert_eq "4" "$(field "${WORK}/two" paths-deleted)" "deletions sum across roots"
assert_eq "24690" "$(field "${WORK}/two" bytes-transferred)" "bytes sum across roots"

describe "a deploy that changed nothing"
cat > "${WORK}/none" <<'LOG'
sending incremental file list

Number of files: 1,234 (reg: 1,200, dir: 34)
Number of regular files transferred: 0
Total transferred file size: 0 bytes
LOG
assert_eq "false" "$(field "${WORK}/none" changed)" "reports unchanged"
assert_eq "0" "$(field "${WORK}/none" files-transferred)" "zero transferred"
assert_eq "0" "$(field "${WORK}/none" paths-deleted)" "zero deleted"

describe "deletions with no transfer still count as changed"
# The case a naive `transferred > 0` test would miss, and the one that matters
# most: a deploy that only removes files has changed the site.
cat > "${WORK}/del" <<'LOG'
sending incremental file list
*deleting   stale.html

Number of regular files transferred: 0
Total transferred file size: 0 bytes
LOG
assert_eq "true" "$(field "${WORK}/del" changed)" "deletions alone mean changed"
assert_eq "1" "$(field "${WORK}/del" paths-deleted)" "the deletion is counted"

describe "an empty log does not crash or report a change"
: > "${WORK}/empty"
assert_eq "false" "$(field "${WORK}/empty" changed)" "empty log reports unchanged"
assert_eq "0" "$(field "${WORK}/empty" paths-deleted)" "empty log counts zero"

finish
