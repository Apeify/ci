#!/usr/bin/env bash
# Integration tests for the deploy action's preflight step, run as one script the way
# GitHub runs it.
#
# path-rules.test.sh covers the helpers in isolation. This file covers how they
# are COMPOSED, which is where the defects have actually been: a check placed
# above the gate that should have skipped it, a guard that returned early, a
# comparison whose two sides were normalized differently. Every one of those
# passed a unit test of the individual function.
#
# The step reads every value from the environment - it contains no `${{ }}` of
# its own - so it can be driven directly.

# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PREFLIGHT="${WORK}/preflight.sh"
extract_run_step "$DEPLOY_ACTION" "Preflight - check configuration" > "$PREFLIGHT"
require_shell "$PREFLIGHT" "WEB_ROOT_DIRS"

# A known-good configuration. Each test overrides only what it is about, so a
# failure points at the value that changed rather than at the whole environment.
preflight() {
  local -a env=(
    DEPLOY_SSH_KEY=key
    DEPLOY_HOST=host.example.com
    DEPLOY_USER=user
    DEPLOY_BASE_DIR=/home/user
    WEB_ROOT_DIRS=site.com
    SITE_URL=https://site.com
    PUBLIC_DIR=public
    APP_DIR=app
    APP_REMOTE_DIR=
    DEPLOY_APP_DIR=true
    RESOLVED_ENVIRONMENT=staging
    GITHUB_REF=refs/heads/staging
    # The runner always provides this, and the preflight writes its outputs
    # there. `env -i` strips the whole environment, so without it every
    # success-path assertion fails on an ambiguous redirect rather than on
    # anything the test is about. Pointed at a real file rather than /dev/null
    # so a test can read back what was emitted.
    "GITHUB_OUTPUT=${WORK}/github_output"
  )
  : > "${WORK}/github_output"
  env -i PATH="$PATH" HOME="$HOME" "${env[@]}" "$@" "${GH_BASH[@]}" "$PREFLIGHT"
}

describe "a valid configuration passes"
assert_exit 0 "baseline" preflight
assert_exit 0 "trailing slash on DEPLOY_BASE_DIR is accepted" preflight DEPLOY_BASE_DIR=/home/user/
assert_exit 0 "a trailing newline in WEB_ROOT_DIRS is ordinary input" \
  preflight "WEB_ROOT_DIRS=site.com
"
assert_exit 0 "several sibling web roots" preflight "WEB_ROOT_DIRS=a.com
b.com"
assert_exit 0 "app-remote-dir may differ from app-dir" preflight APP_REMOTE_DIR=private

# Run the preflight, then read one key back out of the outputs it emitted.
pf_output() {
  local key="$1"; shift
  preflight "$@" >/dev/null 2>&1 || true
  sed -n "s/^${key}=//p" "${WORK}/github_output"
}

describe "the preflight publishes what it deployed"
# These are a contract now: consumers gate CDN purges and delete-tripwires on
# them, and removing or renaming one is a major bump.
assert_eq '["site.com"]' "$(pf_output web-roots)" "web-roots is a JSON array"
assert_eq '["a.com","b.com"]' "$(pf_output web-roots "WEB_ROOT_DIRS=a.com
b.com")" "several roots, JSON, no trailing comma"
assert_eq "2" "$(pf_output web-root-count "WEB_ROOT_DIRS=a.com
b.com")" "web-root-count matches"
assert_eq "true" "$(pf_output app-deployed)" "app-deployed is true by default"
assert_eq "false" "$(pf_output app-deployed DEPLOY_APP_DIR=false)" "app-deployed follows the input"
assert_eq "app" "$(pf_output app-remote-dir)" "app-remote-dir defaults to app-dir"
assert_eq "private" "$(pf_output app-remote-dir APP_REMOTE_DIR=private)" "app-remote-dir follows the input"
# Normalized, not raw: the outputs must agree with what the rsync steps use.
assert_eq '["site.com"]' "$(pf_output web-roots "WEB_ROOT_DIRS=./site.com/")" "web-roots is normalized"

describe "no output is derived from a secret"
# base-dir, host and user are secrets. An output built from them would be
# stored and readable through the API, and a value concatenated from a secret
# and a non-secret may not be masked at all.
# Asserted against the WHOLE emitted block, not one key: a leak would most
# likely arrive in a field nobody thought to check.
leaked() {
  preflight >/dev/null 2>&1 || true
  grep -cE '/home/user|host\.example\.com|^[^=]*=user$' "${WORK}/github_output" || true
}
assert_eq "0" "$(leaked)" "no output contains base-dir, host or user"

describe "deploy-app-dir must be exactly true or false"
# The step condition that runs the app sync uses GitHub's `==`, which is
# case-INSENSITIVE, while every reader in this shell uses POSIX `[ = ]`, which
# is not. 'True' therefore made the shell skip reject_repo_root,
# check_relative_dir, the app-inside-public checks and the app-inside-web-root
# loop, while the gate still ran the sync - publishing the private tree into a
# served web root, or running --delete outside the account home.
assert_exit 1 "'True' is refused" preflight DEPLOY_APP_DIR=True
assert_output_contains "must be exactly" "the refusal explains the rule" \
  preflight DEPLOY_APP_DIR=True
assert_exit 1 "'TRUE' is refused" preflight DEPLOY_APP_DIR=TRUE
assert_exit 1 "'False' is refused" preflight DEPLOY_APP_DIR=False
assert_exit 1 "'yes' is refused" preflight DEPLOY_APP_DIR=yes
assert_exit 1 "an empty value is refused" preflight DEPLOY_APP_DIR=
assert_exit 0 "'true' is accepted" preflight DEPLOY_APP_DIR=true
assert_exit 0 "'false' is accepted" preflight DEPLOY_APP_DIR=false
# The case that made it dangerous: a spelling the gate accepts must never reach
# the app checks unvalidated.
assert_exit 1 "'True' with a nested app-remote-dir is still refused" \
  preflight DEPLOY_APP_DIR=True APP_REMOTE_DIR=site.com/app
assert_exit 1 "'True' with an escaping app-remote-dir is still refused" \
  preflight DEPLOY_APP_DIR=True APP_REMOTE_DIR=../shared

describe "a web root must not break the web-roots JSON"
# The JSON is built by hand and asserts these cannot occur. Until this was
# validated, 'my"site.com' produced ["my"site.com"] - rejected by a consumer's
# fromJSON() only AFTER both rsyncs had written and deleted.
assert_exit 1 "a double quote is refused" preflight 'WEB_ROOT_DIRS=my"site.com'
assert_output_contains "double quote" "the quote is named" preflight 'WEB_ROOT_DIRS=my"site.com'
assert_exit 1 "a backslash is refused" preflight 'WEB_ROOT_DIRS=a\b.com'
assert_output_contains "backslash" "the backslash is named" preflight 'WEB_ROOT_DIRS=a\b.com'

describe "the environment input must be present"
# Not a formality. `required: true` on an action input is advisory - the runner
# does not enforce it - so an omitted or misspelled `environment:` arrives as an
# empty string, fails the `= "production"` test, and silently disables BOTH
# production refusals while the caller's job has already entered the
# environment and put its credentials in scope.
assert_exit 1 "an empty environment is refused" preflight RESOLVED_ENVIRONMENT=
assert_output_contains "'environment' input is empty" "the empty input is named" \
  preflight RESOLVED_ENVIRONMENT=
assert_exit 1 "a whitespace-only environment is refused" preflight "RESOLVED_ENVIRONMENT=   "
# The refusal must come BEFORE the production guards, not instead of them: an
# empty value must never be treated as 'staging' and waved through.
assert_output_contains "'environment' input is empty" "whitespace is refused the same way" \
  preflight "RESOLVED_ENVIRONMENT=	"

describe "missing configuration is refused, and named"
assert_exit 1 "missing SSH key" preflight DEPLOY_SSH_KEY=
assert_output_contains "DEPLOY_SSH_KEY (secret)" "the missing secret is named" \
  preflight DEPLOY_SSH_KEY=
assert_output_contains "WEB_ROOT_DIRS (variable)" "the missing variable is named" \
  preflight WEB_ROOT_DIRS=
assert_exit 1 "WEB_ROOT_DIRS of only blank lines" preflight "WEB_ROOT_DIRS=

"

describe "DEPLOY_BASE_DIR - the value --delete is scoped by"
assert_exit 1 "relative base dir" preflight DEPLOY_BASE_DIR=home/user
assert_exit 1 "filesystem root" preflight DEPLOY_BASE_DIR=/
assert_exit 1 "filesystem root spelled //" preflight DEPLOY_BASE_DIR=//
assert_exit 1 "base dir containing .." preflight DEPLOY_BASE_DIR=/home/user/..
assert_output_contains "must not contain '..'" "'..' is refused by name" \
  preflight DEPLOY_BASE_DIR=/home/user/..

# EVERY refusal below asserts the MESSAGE as well as the exit code, and that is
# not belt-and-braces. These guards sit in front of one another: delete the
# absolute-path check and a dot-only check further down still exits 1, so an
# exit-code-only assertion goes on passing against a guard that no longer
# exists. That is not a hypothetical - it was measured. Five guards in this
# preflight could be deleted with all 45 assertions green, because their tests
# checked only the exit code.
#
# The rule for anything added here: if you cannot name the message, you are not
# testing the guard you think you are testing.
describe "web roots must be usable and must not nest"
assert_exit 1 "absolute web root" preflight WEB_ROOT_DIRS=/var/www
assert_output_contains "must be relative" "absolute web root is refused as absolute" \
  preflight WEB_ROOT_DIRS=/var/www
assert_exit 1 "dot-only web root" preflight WEB_ROOT_DIRS=.
assert_output_contains "resolves to its parent directory" "dot-only web root is named" \
  preflight WEB_ROOT_DIRS=.
assert_exit 1 "web root containing .." preflight WEB_ROOT_DIRS=../elsewhere
assert_output_contains "must not contain '..'" "'..' in a web root is named" \
  preflight WEB_ROOT_DIRS=../elsewhere

assert_exit 1 "one web root inside another" preflight "WEB_ROOT_DIRS=site.com
site.com/sub"
assert_output_contains "is inside web root" "nesting is named" preflight "WEB_ROOT_DIRS=site.com
site.com/sub"
assert_exit 1 "nesting hidden by a leading ./" preflight "WEB_ROOT_DIRS=site.com
./site.com/sub"

# Reversed order. The nesting test above exercises `case "$b" in "$a"/*)`; this
# one is the only thing exercising the second `case`, and deleting that branch
# left the whole suite green. Order-dependent overlap is exactly what its own
# comment calls the worst kind of intermittent.
assert_exit 1 "nesting with the inner root listed first" preflight "WEB_ROOT_DIRS=site.com/sub
site.com"
assert_output_contains "is inside web root" "reversed-order nesting is named" \
  preflight "WEB_ROOT_DIRS=site.com/sub
site.com"

# Two rsyncs into the same tree, both with --delete.
assert_exit 1 "the same web root listed twice" preflight "WEB_ROOT_DIRS=site.com
site.com"
assert_output_contains "twice" "the duplicate is named" preflight "WEB_ROOT_DIRS=site.com
site.com"

describe "the private tree must never land inside a served web root"
# Round 2. Only the repository-side values were normalized, so this reached the
# nesting test spelled differently from the web root it was inside.
assert_exit 1 "REGRESSION app-remote-dir './site.com/app'" \
  preflight WEB_ROOT_DIRS=site.com APP_REMOTE_DIR=./site.com/app
# Round 4. Every value was normalized, but a trailing '/.' survived it, so the
# nesting pattern became 'site.com/./*' and never matched 'site.com/app'.
assert_exit 1 "REGRESSION web root 'site.com/.'" \
  preflight WEB_ROOT_DIRS=site.com/. APP_REMOTE_DIR=site.com/app
assert_exit 1 "app-remote-dir plainly inside a web root" \
  preflight APP_REMOTE_DIR=site.com/app
assert_exit 1 "app-remote-dir equal to a web root" preflight APP_REMOTE_DIR=site.com
assert_exit 1 "a web root inside app-remote-dir" \
  preflight WEB_ROOT_DIRS=private/site.com APP_REMOTE_DIR=private
assert_output_contains "over HTTP" "the consequence is stated" \
  preflight APP_REMOTE_DIR=site.com/app

# app-remote-dir goes through check_relative_dir, and nothing else catches
# these. Deleting that one call left the suite green while allowing
# `app-remote-dir: ../shared`, which normalizes to '../shared', clears the
# rsync dot-only backstop, and matches no web root - so the deploy would run
# `rsync --delete` into <DEPLOY_BASE_DIR>/../shared/, outside the account home
# entirely.
assert_exit 1 "app-remote-dir escaping the base dir with .." preflight APP_REMOTE_DIR=../shared
assert_output_contains "must not contain '..'" "the escape is refused as '..'" \
  preflight APP_REMOTE_DIR=../shared
assert_exit 1 "absolute app-remote-dir" preflight APP_REMOTE_DIR=/etc
assert_output_contains "must be relative" "absolute app-remote-dir is named" \
  preflight APP_REMOTE_DIR=/etc
assert_exit 1 "dot-only app-remote-dir" preflight APP_REMOTE_DIR=.
assert_output_contains "resolves to its parent directory" "dot-only app-remote-dir is named" \
  preflight APP_REMOTE_DIR=.

describe "app-dir must sit outside public-dir in the repository"
assert_exit 1 "app-dir inside public-dir" preflight APP_DIR=public/app
assert_output_contains "is INSIDE public-dir" "the nesting is named" preflight APP_DIR=public/app
assert_exit 1 "app-dir equal to public-dir" preflight APP_DIR=public
assert_output_contains "the same directory" "the collision is named" preflight APP_DIR=public
assert_exit 1 "public-dir inside app-dir" preflight PUBLIC_DIR=app/public
assert_output_contains "is INSIDE app-dir" "the reverse nesting is named" \
  preflight PUBLIC_DIR=app/public

# public-dir has its own check_relative_dir call, and deleting it left the suite
# green. Without it `public-dir: /etc` reaches the layout step, which passes
# because /etc exists, and /etc/ is then rsynced into every web root.
assert_exit 1 "absolute public-dir" preflight PUBLIC_DIR=/etc
assert_output_contains "must be relative" "absolute public-dir is named" preflight PUBLIC_DIR=/etc
assert_exit 1 "public-dir containing .." preflight PUBLIC_DIR=../elsewhere
assert_output_contains "must not contain '..'" "'..' in public-dir is named" \
  preflight PUBLIC_DIR=../elsewhere

# app-dir needs the same pair, and every case here sets APP_REMOTE_DIR on
# purpose. app-dir is otherwise validated only through the
# `app_remote="${APP_REMOTE_DIR:-$APP_DIR}"` fallback, so with app-remote-dir
# set, deleting app-dir's own check_relative_dir call left the whole suite
# green while allowing `app-dir: /etc` - which rsyncs /etc/ to the server.
assert_exit 1 "absolute app-dir, with app-remote-dir set" \
  preflight APP_DIR=/etc APP_REMOTE_DIR=private
assert_output_contains "must be relative" "absolute app-dir is named" \
  preflight APP_DIR=/etc APP_REMOTE_DIR=private
assert_exit 1 "app-dir containing .., with app-remote-dir set" \
  preflight APP_DIR=../secrets APP_REMOTE_DIR=private
assert_output_contains "must not contain '..'" "'..' in app-dir is named" \
  preflight APP_DIR=../secrets APP_REMOTE_DIR=private

describe "the repository root is not a deployable directory"
assert_exit 1 "public-dir is the repo root" preflight PUBLIC_DIR=.
assert_exit 1 "app-dir is the repo root" preflight APP_DIR=.
assert_output_contains "cannot be the repository root" "the reason is stated" preflight PUBLIC_DIR=.
# Without its own reject_repo_root call, app-dir still exits 1 via
# check_relative_dir - with a message about resolving to a parent directory
# rather than the actionable "move your files into a subdirectory" advice. The
# exit code alone cannot tell the two apart.
assert_output_contains "cannot be the repository root" "app-dir gets the actionable message too" \
  preflight APP_DIR=.
# Round 3. The repo-root check used to run above the deploy-app-dir gate, so a
# site with no private tree was failed over an input it had switched off, and
# told to `git mv` into a directory it does not have.
assert_exit 0 "REGRESSION deploy-app-dir false ignores app-dir entirely" \
  preflight DEPLOY_APP_DIR=false APP_DIR=.
assert_exit 0 "deploy-app-dir false ignores a nested app-remote-dir too" \
  preflight DEPLOY_APP_DIR=false APP_REMOTE_DIR=site.com/app

describe "production is refused from anywhere but main"
assert_exit 1 "production from a non-main ref" \
  preflight RESOLVED_ENVIRONMENT=production GITHUB_REF=refs/heads/staging
assert_exit 1 "production is matched case-insensitively" \
  preflight RESOLVED_ENVIRONMENT=Production GITHUB_REF=refs/heads/staging
assert_output_contains "Refusing to deploy to production" "the refusal is explicit" \
  preflight RESOLVED_ENVIRONMENT=production GITHUB_REF=refs/heads/feature

describe "production only deploys a commit staging has already carried"
# This guard is the last thing between a commit pushed straight to main and the
# live site, so it gets a real repository rather than a mocked git: a clone with
# an origin to fetch from, exactly as on a runner.
setup_repo() {
  local dir="${WORK}/repo$1"
  rm -rf "$dir" "${dir}.origin"
  git init -q --bare "${dir}.origin"
  git init -q "$dir"
  # Identity and signing are configured LOCALLY so the fixture does not depend
  # on the machine it runs on. A maintainer with commit.gpgsign enabled would
  # otherwise have every fixture commit block on a pinentry prompt, and CI has
  # no signing key at all.
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name "Test Fixture"
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" config tag.gpgsign false
  git -C "$dir" commit -q --allow-empty -m base
  git -C "$dir" branch -M main
  git -C "$dir" remote add origin "${dir}.origin"
  git -C "$dir" push -q origin main
  printf '%s' "$dir"
}

# The preflight, run from inside a git working tree with production selected.
preflight_in() {
  local dir="$1"; shift
  ( cd "$dir" && preflight RESOLVED_ENVIRONMENT=production GITHUB_REF=refs/heads/main "$@" )
}

# Published normally: staging and main point at the same commit.
repo=$(setup_repo 1)
git -C "$repo" push -q origin main:staging
assert_exit 0 "main published from staging is accepted" preflight_in "$repo"

# Staging moved on afterwards, so the deployed commit is merely behind it. Still
# contained, and must still be allowed - this is the normal state of things.
git -C "$repo" commit -q --allow-empty -m later
git -C "$repo" push -q origin main:staging
git -C "$repo" reset -q --hard HEAD~1
assert_exit 0 "a commit staging has moved past is still contained" preflight_in "$repo"

# The case the guard exists for: committed straight to main, never on staging.
repo=$(setup_repo 2)
git -C "$repo" push -q origin main:staging
git -C "$repo" commit -q --allow-empty -m "straight to main"
assert_exit 1 "a commit never on staging is refused" preflight_in "$repo"
assert_output_contains "not contained in staging" "the refusal names the reason" \
  preflight_in "$repo"

# Fails CLOSED. A guard that opts out when it cannot run is not a guard, and
# both of these were once downgraded to a warning.
# Both of these assert the MESSAGE as well as the exit code, and that is not
# belt-and-braces. Downgrading either refusal to a warning still produces exit 1,
# because execution falls through to `merge-base --is-ancestor` which fails on
# the same missing ref - so an exit-code-only assertion passes against a guard
# that has been removed. Naming the message is what distinguishes "refused for
# the right reason" from "happened to fail later".
# No staging branch on origin. Note this is caught by the FETCH, not by the
# `rev-parse --verify origin/staging` check below it: the fetch names
# refs/heads/staging in its refspec, so git exits 128 with "couldn't find remote
# ref" before that check is ever reached. The rev-parse guard is genuinely
# belt-and-braces rather than a separate reachable case, which is why there is
# no test asserting its message - a test that claimed to cover it would be
# asserting a branch this refspec cannot reach.
repo=$(setup_repo 3)
assert_exit 1 "a missing origin/staging is fatal, not a warning" preflight_in "$repo"
assert_output_contains "Could not fetch origin" "the fetch guard is the one that fired" \
  preflight_in "$repo"

repo=$(setup_repo 4)
git -C "$repo" push -q origin main:staging
git -C "$repo" remote set-url origin "${WORK}/does-not-exist"
assert_exit 1 "an unreachable origin is fatal, not skippable" preflight_in "$repo"
assert_output_contains "Could not fetch origin" "the fetch guard is the one that fired" \
  preflight_in "$repo"

# Staging is subject to none of the above: repo5 has no origin/staging at all,
# which is fatal for production and irrelevant here.
repo=$(setup_repo 5)
preflight_staging_in() { ( cd "$1" && preflight ); }
assert_exit 0 "staging deploys without any containment check" preflight_staging_in "$repo"

finish
