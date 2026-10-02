#!/usr/bin/env bash
#
# Set every tracked file's mtime to the date of the last commit that changed
# it.
#
# A fresh checkout stamps every file with a brand-new mtime, which makes
# rsync's size+mtime quick check treat the whole tree as changed on every
# deploy: every file is re-sent and lands on the server with a new mtime.
# Restoring last-commit dates fixes both halves: unchanged files are skipped,
# and any <lastmod> derived from filemtime() reflects when a page actually
# changed rather than the latest deploy.
#
# Hand-rolled rather than the git-restore-mtime package: that tool shells out
# to the deprecated `git whatchanged` plumbing, which newer git versions refuse
# to run without --i-still-use-this - it fails with zero output and no error,
# silently restoring nothing.
#
# ONE history walk, not one `git log` per tracked file. The saving is process
# count, and it scales on file count rather than on file count times a
# history lookup.
#
# --diff-merges=first-parent is LOAD-BEARING, not a tuning flag. Without it,
# `git log --name-only` prints no filenames at all for a merge commit (git
# will not pick a parent to diff against), so a file whose current content
# came from a merge is mishandled in one of two ways:
#   * a file created while resolving the merge is MISSED entirely - it keeps
#     its checkout mtime and re-syncs on every deploy;
#   * a file whose conflict was resolved silently inherits the OLDER parent's
#     timestamp - it still gets a value, so a "missed files" counter reports
#     zero and the error stays invisible.
# Verified against a fixture containing both cases: with this flag every
# tracked file gets a timestamp, and a conflict resolution gets the merge's
# own date rather than an older parent's.
#
# It does NOT reproduce `git log -1 -- <file>` exactly, and an earlier version
# of this comment wrongly claimed it did. `git log -- <path>` applies history
# simplification and reports the side-branch commit, while
# --diff-merges=first-parent attributes it to the merge. The flag's one
# trade-off follows: a file changed only on a side branch is dated to when it
# LANDED on the mainline rather than when it was authored. Both readings of
# "last modified" are defensible, and at day granularity it is almost always
# the same date.
#
# Three details that matter if you copy this:
#   * The `[ -e ]` guard is required, not defensive. The walk emits historical
#     paths that no longer exist, and `touch` CREATES a missing file - without
#     the guard the tree fills with empty files at deleted paths and rsync
#     ships them.
#   * core.quotePath=false stops git escaping non-ASCII paths, which would
#     otherwise be touched under their quoted names and silently missed.
#   * Do NOT make awk emit NUL-delimited output. mawk truncates a printf
#     format string at an embedded \0, so `printf "%s\0%s\0"` silently
#     produces nothing usable and the step restores ZERO mtimes while exiting
#     0. gawk handles it, so this passes on a dev box and fails on the runner:
#     Ubuntu's /usr/bin/awk is mawk. Records are newline-delimited instead,
#     and read in pairs.
#
# Batching the touches by timestamp was tried and abandoned: bash cannot hold
# NUL bytes in a variable, so grouping paths in a shell array concatenates
# them. Correctness beats the couple of seconds.
#
# Run by the "Restore file mtimes from git history" step of
# actions/deploy/action.yml, in the root of the caller's checkout, which must
# have full history (check-workspace.sh makes sure).
#
# Inputs: none. It works on the git checkout in the working directory.
#
# Outputs: none. Changes file mtimes in the working tree, and writes scratch
# files under /tmp.
#
# Exits 1 with an ::error:: annotation if the history walk desynchronizes,
# which would mean a tracked path contains a newline.

# The options GitHub gives an inline bash step, which this was written against.
set -eo pipefail

marker=$(printf '\001')
touched=0

# Two lines per record: timestamp, then path.
git -c core.quotePath=false log --diff-merges=first-parent \
    --format="${marker}%ct" --name-only \
| awk -v M="$marker" '
    substr($0, 1, 1) == M {
      t = substr($0, 2)
      if (t ~ /^[0-9]+$/) { ts = t; next }
    }
    $0 == ""    { next }
    !seen[$0]++ { print ts; print $0 }
  ' > /tmp/mtimes.txt

: > /tmp/walked.txt
while IFS= read -r ts && IFS= read -r path; do
  case "$ts" in
    ''|*[!0-9]*)
      echo "::error::mtime restore desynchronized at '${ts}' - does a tracked path contain a newline?"
      exit 1
      ;;
  esac
  if [ -e "$path" ]; then
    touch -d "@$ts" -- "$path"
    printf '%s\n' "$path" >> /tmp/walked.txt
    touched=$((touched + 1))
  fi
done < /tmp/mtimes.txt

# Belt and braces: REPAIR anything the walk did not attribute at all,
# instead of only warning about it. In the normal case this loop spawns
# zero git processes, so it costs nothing.
#
# Note precisely what it does and does not cover. `comm -23` finds
# files the walk MISSED; it cannot find files the walk MIS-DATED,
# because those already have a timestamp. So a file dated to a merge
# rather than to its side-branch commit is not repaired here, and the
# counters will report it as successfully walked. That is the accepted
# trade-off described above, not a gap this loop closes.
LC_ALL=C sort -u /tmp/walked.txt > /tmp/walked.sorted
repaired=0
while IFS= read -r f; do
  ts=$(git log -1 --format=%ct -- "$f")
  if [ -n "$ts" ]; then
    touch -d "@$ts" -- "$f"
    repaired=$((repaired + 1))
  else
    echo "::warning::no commit timestamp for '$f' - it will re-sync every deploy."
  fi
done < <(comm -23 <(git -c core.quotePath=false ls-files | LC_ALL=C sort) /tmp/walked.sorted)

tracked=$(git ls-files | wc -l)
echo "restored mtimes on $tracked tracked files: $touched from the history walk, $repaired via per-file fallback"
