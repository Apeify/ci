#!/usr/bin/env bash
# Tests for the two rsync steps (actions/deploy/scripts/sync-public.sh and
# sync-app.sh), run as the action runs them, with `rsync` replaced by a
# stand-in that records its arguments instead of transferring anything.
#
# These hold the most destructive lines in the repo. Each rsync runs with
# --delete, so a destination that collapses to DEPLOY_BASE_DIR itself prunes
# the whole account: every web root, the app tree, and whatever else lives
# there. The preflight refuses every value that could do that, and these
# scripts refuse them AGAIN, immediately before rsync - the second line of
# defense MAINTAINING.md describes, including the `[ -z "$dir" ] && continue`
# that turns an ordinary trailing newline in WEB_ROOT_DIRS into a skip rather
# than a sync into "<base>//".
#
# Until the steps were files, nothing ever executed those backstops: tests
# could reach the helper functions but not the step bodies around them. A
# guard nobody has watched fail cannot be trusted, so every one is driven to
# its refusal here, and every case that should transfer is checked for the
# exact destination it used.

# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SYNC_PUBLIC="${DEPLOY_SCRIPTS}/sync-public.sh"
SYNC_APP="${DEPLOY_SCRIPTS}/sync-app.sh"

# ------------------------------------------------------------ stand-in

BIN="${WORK}/bin"
mkdir -p "$BIN"

# One line per call, arguments separated by \037 so a pattern containing a
# space stays one argument. Prints the two --stats lines emit_transfer_stats
# reads, as if one file of 10 bytes moved. RSYNC_EXIT makes it fail instead.
cat > "${BIN}/rsync" <<'STUB'
#!/usr/bin/env bash
( IFS=$'\037'; printf '%s\n' "$*" ) >> "$RSYNC_LOG"
printf 'Number of regular files transferred: 1\nTotal transferred file size: 10 bytes\n'
exit "${RSYNC_EXIT:-0}"
STUB
chmod +x "${BIN}/rsync"

# $1 script, then KEY=value overrides of a known-good environment.
run_sync() {
  local script="$1"; shift
  : > "${WORK}/rsync.log"
  : > "${WORK}/output"
  env -i PATH="${BIN}:${PATH}" HOME="$HOME" \
    RSYNC_LOG="${WORK}/rsync.log" GITHUB_OUTPUT="${WORK}/output" \
    SSH_HOST=host.example.com SSH_USER=user SSH_PORT= \
    BASE_DIR=/home/user \
    WEB_ROOT_DIRS=site.com PUBLIC_DIR=public \
    APP_DIR=app APP_REMOTE_DIR= \
    EXCLUDES= \
    "$@" bash "$script"
}

calls() { wc -l < "${WORK}/rsync.log" | tr -d ' '; }

# The destination of every call, one per line, in order.
destinations() { awk -F'\037' '{ print $NF }' "${WORK}/rsync.log"; }
sources() { awk -F'\037' '{ print $(NF - 1) }' "${WORK}/rsync.log"; }

# Every argument of call $1 (1-based), one per line.
args_of() { sed -n "${1}p" "${WORK}/rsync.log" | tr '\037' '\n'; }

output() { sed -n "s/^$1=//p" "${WORK}/output"; }

# A refusal must both fail and say which guard fired, and must not have
# reached rsync for the refused value. $1 needle, $2 label, rest: run_sync args.
assert_refused_before_rsync() {
  local needle="$1" label="$2"; shift 2
  local out rc
  out=$(run_sync "$@" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    _fail "$label" "expected a refusal, got exit 0" "rsync calls:" "$(cat "${WORK}/rsync.log")"
    return
  fi
  case "$out" in
    *"$needle"*) _pass ;;
    *) _fail "$label" "refused, but not by the expected guard: '${needle}'" "output:" "$out" ;;
  esac
}

# No call may target the base directory itself, in any spelling.
assert_never_targets_base() {
  local d bad=""
  while IFS= read -r d; do
    case "$d" in
      *:/home/user/|*:/home/user//|*:/home/user/./|*:/home/user) bad="${bad} ${d}" ;;
    esac
  done < <(destinations)
  if [ -z "$bad" ]; then _pass; else _fail "$1" "rsync was pointed at the base directory:${bad}"; fi
}

# ------------------------------------------------------------ public sync

describe "public sync: one call per web root, into the right place"
assert_exit 0 "a single web root syncs" run_sync "$SYNC_PUBLIC"
assert_eq "1" "$(calls)" "exactly one rsync"
assert_eq "user@host.example.com:/home/user/site.com/" "$(destinations)" "destination is <base>/<root>/"
assert_eq "public/" "$(sources)" "source is the CONTENTS of public-dir (trailing slash)"
assert_exit 0 "--delete is passed" grep -q -x -- "--delete" <(args_of 1)
assert_eq "true" "$(output changed)" "the transfer is reported"

run_sync "$SYNC_PUBLIC" "WEB_ROOT_DIRS=a.com
b.com" >/dev/null 2>&1
assert_eq "user@host.example.com:/home/user/a.com/
user@host.example.com:/home/user/b.com/" "$(destinations)" "every root gets its own sync, in order"
assert_eq "2" "$(output files-transferred)" "transfer counts SUM across the roots"

describe "public sync: REGRESSION blank entries are skipped, never synced to the base"
# The case MAINTAINING.md calls load-bearing: a variable entered in the GitHub
# UI routinely ends with a newline. Without the skip, that empty entry becomes
# "<base>//" and --delete prunes the whole account.
assert_exit 0 "a trailing newline is ordinary input" run_sync "$SYNC_PUBLIC" "WEB_ROOT_DIRS=site.com
"
assert_eq "1" "$(calls)" "the empty entry is skipped, not synced"
assert_never_targets_base "a trailing newline never targets the base directory"

run_sync "$SYNC_PUBLIC" "WEB_ROOT_DIRS=
a.com


b.com
" >/dev/null 2>&1
assert_eq "2" "$(calls)" "blank and whitespace-only lines anywhere are skipped"
assert_never_targets_base "interior blank lines never target the base directory"

describe "public sync: a root that resolves to the base never reaches rsync"
# Two routes, both safe, and worth telling apart. A value that norm_path keeps
# as '.' hits the dot-only refusal. A value it reduces to nothing ('./', './/')
# is indistinguishable from a blank line by then, so the same skip handles it.
# (The preflight has already refused all of these by the time this runs.)
for bad in "." "./."; do
  assert_refused_before_rsync "resolves to its parent directory" "web root '${bad}' is refused" \
    "$SYNC_PUBLIC" "WEB_ROOT_DIRS=${bad}"
  assert_eq "0" "$(calls)" "web root '${bad}' never reaches rsync"
done
for skipped in "./" ".//" "././"; do
  run_sync "$SYNC_PUBLIC" "WEB_ROOT_DIRS=${skipped}" >/dev/null 2>&1
  assert_eq "0" "$(calls)" "web root '${skipped}' normalizes to nothing and is skipped, not synced"
done

describe "public sync: paths are normalized the way the preflight checked them"
run_sync "$SYNC_PUBLIC" BASE_DIR=/home/user/ "WEB_ROOT_DIRS=./site.com/" PUBLIC_DIR=./public/ >/dev/null 2>&1
assert_eq "user@host.example.com:/home/user/site.com/" "$(destinations)" "no // or ./ in the destination"
assert_eq "public/" "$(sources)" "no ./ or // in the source"

describe "public sync: .git and .github are excluded whatever the caller passes"
run_sync "$SYNC_PUBLIC" >/dev/null 2>&1
assert_exit 0 ".git excluded with no EXCLUDES" grep -q -x -- "--exclude=.git" <(args_of 1)
assert_exit 0 ".github excluded with no EXCLUDES" grep -q -x -- "--exclude=.github" <(args_of 1)
run_sync "$SYNC_PUBLIC" "EXCLUDES=my file.txt
  router.php
" >/dev/null 2>&1
assert_exit 0 ".git still excluded alongside caller excludes" grep -q -x -- "--exclude=.git" <(args_of 1)
assert_exit 0 "a pattern containing a space stays one pattern" grep -q -x -- "--exclude=my file.txt" <(args_of 1)
assert_exit 0 "surrounding whitespace is trimmed" grep -q -x -- "--exclude=router.php" <(args_of 1)

describe "public sync: an rsync failure fails the step"
assert_exit 23 "rsync exiting non-zero fails the sync, with rsync's own status" run_sync "$SYNC_PUBLIC" RSYNC_EXIT=23
assert_exit 23 "the failure is not masked by a later root" run_sync "$SYNC_PUBLIC" RSYNC_EXIT=23 "WEB_ROOT_DIRS=a.com
b.com"

# ------------------------------------------------------------ app sync

describe "app sync: into <base>/<app remote dir>/"
assert_exit 0 "the default app sync runs" run_sync "$SYNC_APP"
assert_eq "user@host.example.com:/home/user/app/" "$(destinations)" "an empty app-remote-dir means the same as app-dir"
assert_eq "app/" "$(sources)" "source is the CONTENTS of app-dir"
assert_exit 0 "--delete is passed" grep -q -x -- "--delete" <(args_of 1)

run_sync "$SYNC_APP" APP_REMOTE_DIR=private >/dev/null 2>&1
assert_eq "user@host.example.com:/home/user/private/" "$(destinations)" "app-remote-dir names the server directory"

run_sync "$SYNC_APP" APP_DIR=./app/ "APP_REMOTE_DIR=./private//" BASE_DIR=/home/user/ >/dev/null 2>&1
assert_eq "user@host.example.com:/home/user/private/" "$(destinations)" "server path is normalized"
assert_eq "app/" "$(sources)" "repo path is normalized"

describe "app sync: a destination that resolves to the base is refused before rsync"
for bad in "." "./" ".//" "./."; do
  assert_refused_before_rsync "refusing to rsync into" "app-remote-dir '${bad}' is refused" \
    "$SYNC_APP" "APP_REMOTE_DIR=${bad}"
  assert_eq "0" "$(calls)" "app-remote-dir '${bad}' never reaches rsync"
done
# The fallback path too: an app-dir that normalizes to nothing, with no
# app-remote-dir to override it, must not become "<base>/".
assert_refused_before_rsync "refusing to rsync into" "app-dir '.' with no app-remote-dir is refused" \
  "$SYNC_APP" APP_DIR=. APP_REMOTE_DIR=
assert_eq "0" "$(calls)" "app-dir '.' never reaches rsync"

describe "app sync: .git and .github are excluded whatever the caller passes"
run_sync "$SYNC_APP" "EXCLUDES=cache/
config/mail.php" >/dev/null 2>&1
assert_exit 0 ".git excluded" grep -q -x -- "--exclude=.git" <(args_of 1)
assert_exit 0 ".github excluded" grep -q -x -- "--exclude=.github" <(args_of 1)
assert_exit 0 "caller excludes are passed" grep -q -x -- "--exclude=config/mail.php" <(args_of 1)

describe "app sync: an rsync failure fails the step"
assert_exit 23 "rsync exiting non-zero fails the sync, with rsync's own status" run_sync "$SYNC_APP" RSYNC_EXIT=23

finish
