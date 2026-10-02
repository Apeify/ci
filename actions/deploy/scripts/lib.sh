# shellcheck shell=bash
#
# Functions shared by the deploy action's step scripts. Sourced, never run.
#
# This file exists because Actions steps are separate shells. While the steps'
# shell lived inline in action.yml, norm_path was defined three times and
# emit_transfer_stats twice, and tests had to assert the copies stayed
# byte-identical. Now each is defined once, here, and tests/action-wiring.test.sh
# fails if any step script defines one of them again.
#
# Sets no shell options. Each step script sets its own, and a sourced file that
# changed them would change the caller's behavior from a distance.
#
# Functions:
#
#   norm_path PATH
#       Prints PATH with repeated slashes collapsed, every './' segment removed
#       and trailing slashes stripped, so every spelling of one directory
#       compares equal. Prints an empty string for '/', '.' and the like.
#
#   check_relative_dir LABEL VALUE
#       Returns 1, after an ::error:: naming LABEL, if VALUE is empty,
#       absolute, contains '..', a double quote or a backslash, or resolves to
#       its own parent ('.', './'). Returns 0 otherwise. Call it as
#       `check_relative_dir ... || exit 1`.
#
#   reject_repo_root LABEL VALUE
#       Returns 1, after an ::error:: with advice, if VALUE names the
#       repository root. Returns 0 otherwise, including for an empty VALUE,
#       which is check_relative_dir's to refuse.
#
#   emit_transfer_stats LOG
#       Reads an rsync log written with --itemize-changes --stats, possibly
#       several runs long, and appends files-transferred, bytes-transferred,
#       paths-deleted and changed to $GITHUB_OUTPUT, summed across every run.
#
# Three of them set globals (label, value, trimmed, log, transferred, bytes,
# deleted) rather than declaring locals, as they did when they were inline;
# norm_path sets none.
# No script that sources this file uses those names, which is the only thing
# that keeps that safe. Check before using one in a caller.

# ---------------------------------------------------------------- paths
#
# Every path-ish value in this action goes through one set of rules,
# deliberately: they are all interpolated into rsync destinations that run with
# --delete, and they all fail the same catastrophic way. An empty, absolute, or
# dot-only value silently retargets the deploy at DEPLOY_BASE_DIR itself, which
# then prunes everything in the account that is not in the source tree.
#
# Sharing one check is what stops the call sites from drifting apart as they
# are edited.

# ONE normalizer, used by every comparison. Collapses repeated slashes, removes
# './' segments wherever they appear - leading, interior or trailing - and
# strips trailing slashes, so 'site.com', './site.com', './/site.com/',
# '././site.com', 'site.com/.' and 'site.com/./' all compare equal.
#
# The comparisons are string prefix tests, so a value that reaches them in an
# unexpected spelling defeats them SILENTLY. This has now been the same bug
# twice, which is why the normalizer is deliberately aggressive rather than
# minimal:
#
#   'app-remote-dir: ./site.com/app' - only the two repository-side values were
#   normalized, and only one leading './'.
#
#   'WEB_ROOT_DIRS: site.com/.' with 'app-remote-dir: site.com/app' - every
#   value was normalized, but a trailing '/.' survived it, so the nesting test
#   built the pattern 'site.com/./*' and never matched 'site.com/app'.
#
# Both placed the entire private tree inside a served web root while every
# check reported success. Any new spelling that survives this function is the
# same bug again: normalize, then compare.
norm_path() {
  printf '%s' "$1" | sed -e 's|//*|/|g' -e ':a' -e 's|^\./||' -e 's|/\./|/|' -e 's|/\.$||' -e 'ta' -e 's|/*$||'
}

# Refuse a relative directory that would retarget an rsync destination. Every
# call site is `check_relative_dir ... || exit 1`, and that form matters:
# tests/path-rules.test.sh explains why the `return 1`s must stay explicit.
check_relative_dir() {
  label="$1"
  value="$2"

  if [ -z "$value" ]; then
    echo "::error::${label} must not be empty."
    return 1
  fi

  case "$value" in
    /*)   echo "::error::${label} '${value}' must be relative to its parent, not an absolute path."; return 1 ;;
    *..*) echo "::error::${label} '${value}' must not contain '..'."; return 1 ;;
    # A double quote or backslash would break the web-roots JSON output,
    # which is built by hand and states these cannot occur. That claim
    # was false until this line existed: 'my"site.com' produced
    # ["my"site.com"], which a consumer's fromJSON() rejects AFTER both
    # rsyncs have already written and deleted. A backslash is worse -
    # ["a\b"] parses as a different name, so a matrix silently targets
    # the wrong root. Neither belongs in a web root name anyway.
    *\"*) echo "::error::${label} '${value}' must not contain a double quote."; return 1 ;;
    *"\\"*) echo "::error::${label} '${value}' must not contain a backslash."; return 1 ;;
  esac

  # Normalize, then re-test what is left. Trailing slashes are
  # harmless to rsync but produce '//' in the destination, which reads
  # like a bug in the log; leading './' segments hide the dot-only
  # case below.
  trimmed=$(norm_path "$value")

  # A value made only of dots and slashes - '.', './', './/' - passes
  # every check above and then resolves to the PARENT directory. For a
  # web root that is DEPLOY_BASE_DIR, and --delete against it empties
  # the account. Same catastrophe as an empty value, different route.
  if [ -z "$trimmed" ] || [ -z "$(printf '%s' "$trimmed" | tr -d './')" ]; then
    echo "::error::${label} '${value}' resolves to its parent directory, which would delete everything in it."
    return 1
  fi

  return 0
}

# Refuse the repository root as public-dir or app-dir, with advice that fits.
#
# A function rather than a loop over both inputs, because app-dir must be
# checked only where it is actually used. An earlier version looped over both
# in the preflight, ABOVE the deploy-app-dir gate, so a site with no private
# tree at all could still be failed over the value of an input its own
# configuration had switched off - 'deploy-app-dir: false' with 'app-dir: .'
# meaning "there isn't one" was rejected with advice to run `git mv` into a
# directory it does not have.
reject_repo_root() {
  label="$1"
  value="$2"
  [ -n "$value" ] || return 0
  [ -z "$(norm_path "$value" | tr -d './')" ] || return 0
  echo "::error::${label} cannot be the repository root."
  echo "Move the files you want deployed into a subdirectory and point ${label} at it:"
  echo ""
  echo "    mkdir public"
  echo "    git mv <your site files> public/"
  echo ""
  echo "Then set '${label}: public' (or omit it - 'public' is the default)."
  return 1
}

# ---------------------------------------------------------------- outputs

# Transfer facts for this action's outputs, written to $GITHUB_OUTPUT from one
# rsync log. Used by both rsync steps.
#
# Parsed from the transfer rather than guessed. `*deleting` lines are the only
# version-independent record of what --delete actually removed: rsync's own
# "Number of deleted files" stat did not exist before 3.1. Both figures SUM
# across the log, because the public step runs rsync once per web root and
# reading a single block would report the last root only.
emit_transfer_stats() {
  log="$1"
  transferred=$(awk -F': *' '/^Number of regular files transferred:/ { gsub(/[^0-9]/, "", $2); s += $2 } END { print s + 0 }' "$log")
  bytes=$(awk -F': *' '/^Total transferred file size:/ { gsub(/[^0-9]/, "", $2); s += $2 } END { print s + 0 }' "$log")
  # `|| true` because grep exits 1 when it matches nothing, which is
  # the ordinary no-deletions case. It still prints 0, so no default is
  # needed after it.
  deleted=$(grep -c '^\*deleting' "$log" || true)

  {
    echo "files-transferred=${transferred}"
    echo "bytes-transferred=${bytes}"
    echo "paths-deleted=${deleted}"
    if [ "$transferred" -gt 0 ] || [ "$deleted" -gt 0 ]; then
      echo "changed=true"
    else
      echo "changed=false"
    fi
  } >> "$GITHUB_OUTPUT"

  echo "transferred ${transferred} file(s), ${bytes} byte(s); removed ${deleted} path(s)"
}
