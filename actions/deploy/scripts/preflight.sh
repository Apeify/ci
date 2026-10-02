#!/usr/bin/env bash
#
# Validate every value the deploy depends on, before anything is transferred,
# and publish the facts later steps and the action's outputs report.
#
# Every path here ends up in an rsync destination that runs with --delete, so
# a malformed value is not a typo, it is data loss: an empty, absolute,
# dot-only or '..' value retargets the deploy at DEPLOY_BASE_DIR itself and
# prunes everything there. The checks fail with an explicit list of what is
# wrong rather than with whatever error an empty value happens to produce
# three steps later - misconfigured secrets are the most common failure when
# wiring up a new repo, and their natural failure modes are actively
# misleading.
#
# In order, it refuses:
#   - an `environment` input with leading or trailing whitespace, which would
#     otherwise slip past the production refusals below;
#   - production from any ref but main, and any commit staging has not
#     already carried (this is the step that runs `git fetch origin`);
#   - an empty `environment` input, which would skip both of those refusals;
#   - deploy-app-dir other than exactly 'true' or 'false';
#   - missing secrets or WEB_ROOT_DIRS, named all at once;
#   - a DEPLOY_BASE_DIR that is relative, contains '..', or is '/';
#   - a WEB_ROOT_DIRS with no usable entry, and web roots that are absolute,
#     contain '..', are dot-only, repeated or nested. Blank lines are SKIPPED,
#     not refused - a value entered in the GitHub UI routinely ends in a
#     newline - and that skip is load-bearing; see the comment on it below;
#   - public-dir or app-dir that is the repository root, or that overlap;
#   - an app-remote-dir that is, contains, or sits inside a web root.
# The path rules themselves live in lib.sh.
#
# Run by the "Preflight - check configuration" step of
# actions/deploy/action.yml, in the root of the caller's checkout.
#
# Inputs, as environment variables:
#   RESOLVED_ENVIRONMENT  The action's `environment` input - the GitHub
#                         environment being deployed to. Drives the
#                         production refusals.
#   DEPLOY_SSH_KEY        The `ssh-key` input. Only checked for presence.
#   DEPLOY_HOST           The `host` input. Only checked for presence.
#   DEPLOY_USER           The `user` input. Only checked for presence.
#   DEPLOY_BASE_DIR       The `base-dir` input: absolute directory on the
#                         server that contains the web roots.
#   WEB_ROOT_DIRS         The `web-root-dirs` input: web root names, one per
#                         line, relative to DEPLOY_BASE_DIR.
#   SITE_URL              The `site-url` input. Only warned about when empty.
#   PUBLIC_DIR            The `public-dir` input: repo directory whose
#                         contents go into each web root.
#   APP_DIR               The `app-dir` input: repo directory kept out of the
#                         web roots.
#   APP_REMOTE_DIR        The `app-remote-dir` input: that directory's name on
#                         the server. Empty means the same as APP_DIR.
#   DEPLOY_APP_DIR        The `deploy-app-dir` input: 'true' or 'false'.
#
# Also reads, set by the runner: GITHUB_REF.
#
# Outputs, to $GITHUB_OUTPUT (most re-published as the action's outputs):
#   deployed-sha        The commit being deployed (HEAD).
#   started-at          UTC ISO 8601 time this step started.
#   started-epoch       The same instant, in seconds, for summarize.sh.
#   web-roots           JSON array of the normalized web root names.
#   web-root-count      How many.
#   app-remote-dir      The normalized server-side app directory name, or
#                       empty when deploy-app-dir is false.
#   app-deployed        'true' or 'false'.
#
# Exits 1 with an ::error:: annotation naming the problem on any refusal.

# The options GitHub gives an inline bash step, which this was written against.
set -eo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Facts this action publishes as outputs, captured before any guard can
# exit. The commit is read here rather than inside the production branch
# below because every environment wants to know what it deployed, and a
# consumer correlating a deploy against monitoring should not have to
# care which environment it was.
deployed_sha=$(git rev-parse HEAD)
# One `date` call for both representations. Reading the epoch again
# later made started-at and started-epoch different instants, so
# duration-seconds did not match the interval between the two
# timestamps it is documented as measuring - on a production deploy the
# gap included the whole origin fetch.
started_epoch=$(date -u +%s)
started_at=$(date -u -d "@${started_epoch}" +%Y-%m-%dT%H:%M:%SZ)

# Refused outright if it has leading or trailing whitespace. The production
# test below compares the whole (lowercased) string, so ' production' or
# 'production ' fails it and skips BOTH production refusals - and nothing here
# can rule out GitHub resolving that same value to the production environment,
# credentials and all, when the caller's job enters it. No real environment
# name begins or ends with whitespace, and lint-and-test.yml already refuses
# whitespace in its override, so this costs no legitimate configuration
# anything. Refused rather than trimmed, for the same reason deploy-app-dir is:
# one spelling per value, so no later comparison can disagree with this one.
#
# An all-whitespace value is left to the empty check further down, whose
# message fits it better. A trailing NEWLINE never reached the bypass - command
# substitution strips it before the comparison - but it is refused here too,
# since a value nobody intended is not one to deploy on.
case "$RESOLVED_ENVIRONMENT" in
  [[:space:]]*|*[[:space:]])
    if [ -n "$(printf '%s' "$RESOLVED_ENVIRONMENT" | tr -d '[:space:]')" ]; then
      echo "::error::The 'environment' input '${RESOLVED_ENVIRONMENT}' has leading or trailing whitespace."
      echo "Pass 'needs.lint-and-test.outputs.environment' unchanged. No environment name begins or ends with whitespace,"
      echo "and the production refusals compare the exact name, so this is refused rather than guessed at."
      exit 1
    fi ;;
esac

# The `environment` input could otherwise be used to send any ref's
# content to production, walking straight past the promote gate: the
# whole point of `main` having no push trigger is that production only
# ever receives what promote.yml fast-forwarded there.
#
# So the invariant is enforced here rather than assumed. `production`
# is not an arbitrary name to hardcode - the default branch mapping in
# lint-and-test.yml already treats it specially - and this simply keeps that
# mapping true when the input is used.
#
# Other environments are NOT covered, because this workflow cannot
# know which of them are production-like. A DR target should carry the
# branch half of this rule, expressed as an `if:` on the calling job -
# see examples/workflows/deploy-dr.yml. Only the branch half:
# `if:` cannot inspect git history, so the staging-containment check
# below has no equivalent out there.
# Compared case-INSENSITIVELY. `environment: Production` names the same
# GitHub environment as `production`, so a case-sensitive test would
# let one spelling walk straight past this refusal.
if [ "$(printf '%s' "$RESOLVED_ENVIRONMENT" | tr '[:upper:]' '[:lower:]')" = "production" ]; then
  if [ "$GITHUB_REF" != "refs/heads/main" ]; then
    echo "::error::Refusing to deploy to production from '${GITHUB_REF}'."
    echo "Production only ever receives what promote.yml fast-forwarded onto main."
    echo "Publish with the 'Publish to production' button instead of deploying this ref directly."
    exit 1
  fi

  # Being ON main is not enough, and this is the gap that matters.
  #
  # The deploy stub carries workflow_dispatch - it must, because
  # promote.yml reaches this workflow by dispatching it - so anyone
  # with write access can run the deploy directly against `main` from
  # the Actions tab. That path skips promote.yml entirely, including
  # its check that main holds nothing staging has not seen. Omitting
  # `main` from the stub's push trigger stops accidental deploys; it
  # does not stop this one.
  #
  # So the invariant is enforced here rather than assumed: the commit
  # this run is deploying must already be contained in staging. After
  # a normal publish it is the tip of both; if staging has moved on
  # since, the deployed commit is merely behind it, which is still
  # contained and still fine. Only a commit pushed straight to main
  # fails this.
  # FAILS CLOSED, deliberately. An earlier version ended this fetch
  # with `>/dev/null 2>&1 || true` and downgraded a missing
  # origin/staging to a warning, so a transient network failure
  # skipped the check entirely - on the one configuration it exists to
  # refuse - while the discarded stderr made the log blame a missing
  # branch. A guard that opts out when it cannot run is not a guard.
  if ! git fetch --prune --no-tags origin \
       +refs/heads/main:refs/remotes/origin/main \
       +refs/heads/staging:refs/remotes/origin/staging; then
    echo "::error::Could not fetch origin to check this commit against staging - refusing to deploy production."
    echo "This check is the only thing between a commit pushed straight to main and the live site, so a fetch failure is fatal rather than skippable."
    exit 1
  fi

  if ! git rev-parse --verify -q refs/remotes/origin/staging >/dev/null; then
    echo "::error::origin/staging does not exist - refusing to deploy production."
    echo "This pipeline's model is that production only serves what staging has already served, so there is nothing to verify against."
    exit 1
  fi

  # Compare the COMMIT BEING DEPLOYED, not origin/main.
  #
  # The workspace is checked out at github.sha, frozen when this run
  # was created; origin/main is whatever the branch points at right
  # now. Those diverge whenever a run sits queued - more likely since
  # cancel-in-progress became false - or if main moves after dispatch.
  # It is the WORKSPACE that gets rsynced, so validating origin/main
  # would approve a commit this run is not deploying.
  deploying="$deployed_sha"

  if ! git merge-base --is-ancestor "$deploying" origin/staging; then
    echo "::error::The commit being deployed is not contained in staging - refusing to deploy production."
    echo "Deploying ${deploying}. These commits are in it but were never on staging:"
    git log --oneline origin/staging..HEAD
    echo ""
    echo "Get them onto staging first, then publish with the 'Publish to production' button."
    exit 1
  fi
fi

# Checked FIRST, and separately, because an empty value here does not
# merely misconfigure the deploy - it silently disables both production
# refusals above. `required: true` on an action input is advisory: the
# runner does not enforce it, so a stub that omits or misspells
# `environment:` reaches this point with an empty string, fails the
# `= "production"` test, and deploys any ref to whatever environment the
# caller's job entered. Refuse rather than default: guessing 'staging'
# here would deploy staging's tree using production's credentials
# whenever the caller's environment block said production.
env_trimmed=$(printf '%s' "$RESOLVED_ENVIRONMENT" | tr -d '[:space:]')
if [ -z "$env_trimmed" ]; then
  echo "::error::The 'environment' input is empty."
  echo "Pass 'needs.lint-and-test.outputs.environment', the same value the job's own environment: block uses."
  echo "Without it the production refusals below cannot run, so this is fatal rather than defaulted."
  exit 1
fi

# Exactly 'true' or 'false', refused otherwise, because the step gate
# and this shell compare it DIFFERENTLY. GitHub's `==` on strings is
# case-insensitive, POSIX `[ = ]` is not - so 'True' made every reader
# here say false while `if: inputs.deploy-app-dir == 'true'` on the app
# sync said true. That combination skipped reject_repo_root,
# check_relative_dir, the app-inside-public checks and the
# app-inside-web-root loop, and then rsynced the private tree anyway:
# 'True' plus 'app-remote-dir: site.com/app' published the whole app
# tree over HTTP, and plus '../shared' ran --delete outside the account
# home.
#
# Normalizing the case here would fix the disagreement too, but
# refusing is better: it leaves exactly one spelling for each value, so
# a future reader cannot reintroduce the split by comparing the raw
# string somewhere new.
case "$DEPLOY_APP_DIR" in
  true|false) ;;
  *)
    echo "::error::deploy-app-dir must be exactly 'true' or 'false' (got '${DEPLOY_APP_DIR}')."
    echo "It is a string, and it is compared case-sensitively here but case-INSENSITIVELY by the"
    echo "step condition that runs the app sync, so any other spelling makes the two disagree."
    exit 1 ;;
esac

missing=""
for name in DEPLOY_SSH_KEY DEPLOY_HOST DEPLOY_USER DEPLOY_BASE_DIR; do
  [ -z "${!name}" ] && missing="${missing} ${name} (secret)"
done
[ -z "$WEB_ROOT_DIRS" ] && missing="${missing} WEB_ROOT_DIRS (variable)"

# SITE_URL is deliberately NOT in the list above. An unset value costs
# a clickable link on the GitHub deployment and nothing else - the
# deploy itself is unaffected. Failing a production deploy over a
# cosmetic UI detail would be the wrong trade, so this warns instead.
if [ -z "${SITE_URL}" ]; then
  echo "::warning::SITE_URL is not set for this environment. The deploy will work; GitHub just will not show a link to the site."
fi

if [ -n "$missing" ]; then
  echo "::error::Missing configuration for the '${RESOLVED_ENVIRONMENT}' environment:${missing}"
  echo "Set these under Settings -> Environments in THIS repository."
  echo "See https://github.com/Apeify/ci#configuration"
  exit 1
fi

# DEPLOY_BASE_DIR is interpolated straight into an rsync destination
# that runs with --delete, so a malformed value is not a typo, it is
# data loss. It must be absolute, must not contain '..', and must not
# be the filesystem root. A trailing slash IS accepted - norm_path
# strips it below, and rejecting it would break every environment
# whose secret was pasted as '/home/username/'.
case "$DEPLOY_BASE_DIR" in
  /*) ;;
  *) echo "::error::DEPLOY_BASE_DIR must be an absolute path (got '${DEPLOY_BASE_DIR}')."; exit 1 ;;
esac

# Held to the same '..' rule as every relative path, rather than being
# the one path in the workflow exempt from it. '/home/u/..' makes each
# web root a sibling of the account home and scopes --delete there.
case "$DEPLOY_BASE_DIR" in
  *..*) echo "::error::DEPLOY_BASE_DIR must not contain '..' (got '${DEPLOY_BASE_DIR}')."; exit 1 ;;
esac

# The filesystem root would make every web root a top-level directory
# and scope --delete to '/'. norm_path reduces '/', '//' and '/.' all
# to the empty string, so this one test covers every spelling of it.
if [ -z "$(norm_path "$DEPLOY_BASE_DIR")" ]; then
  echo "::error::DEPLOY_BASE_DIR must not be the filesystem root."
  exit 1
fi

# Validate every web root BEFORE anything is transferred.
#
# This is the most dangerous value in the whole workflow. The rsync
# destination is "<base>/<root>/", so an empty entry collapses it to
# "<base>//" - the account home itself - and --delete would then prune
# everything there that is not in public/. That is the web roots, app/,
# and any state kept alongside them.
#
# Blank lines are SKIPPED, not rejected. A value entered through the
# GitHub UI routinely ends with a newline, so a trailing empty entry is
# normal input rather than a mistake and failing on it would be
# useless. What is refused is a variable with no usable entry at all
# (the count check below) and any entry that resolves to its parent
# (check_relative_dir). The `continue` is therefore load-bearing, not
# tidiness - and the copy of it in sync-public.sh is the one that
# actually stands between a stray newline and the account home.
count=0
web_roots=()
while IFS= read -r raw; do
  dir=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  # LOAD-BEARING, and not for the reason sync-public.sh's copy is.
  # check_relative_dir below rejects an empty value, so without this
  # the trailing newline described above would fail the preflight
  # outright rather than being skipped. See sync-public.sh for the
  # other half.
  [ -z "$dir" ] && continue
  check_relative_dir "WEB_ROOT_DIRS entry" "$dir" || exit 1
  norm=$(norm_path "$dir")
  web_roots+=( "$norm" )
  count=$((count + 1))
  echo "  web root: ${norm}"
done <<< "$WEB_ROOT_DIRS"

if [ "$count" -eq 0 ]; then
  echo "::error::WEB_ROOT_DIRS contained no usable entries."
  exit 1
fi

# Web roots must be SIBLINGS, never nested in one another. Each is
# rsynced with --delete, so two overlapping trees would each remove
# what the other just wrote and the winner would depend on ordering -
# a deploy that "works" or not depending on the order of lines in a
# variable is the worst kind of intermittent.
i=0
while [ "$i" -lt "${#web_roots[@]}" ]; do
  j=$((i + 1))
  while [ "$j" -lt "${#web_roots[@]}" ]; do
    a="${web_roots[$i]}"
    b="${web_roots[$j]}"

    if [ "$a" = "$b" ]; then
      echo "::error::WEB_ROOT_DIRS lists '${a}' twice."
      exit 1
    fi
    case "$b" in "$a"/*)
      echo "::error::web root '${b}' is inside web root '${a}'. Web roots must be siblings under DEPLOY_BASE_DIR."
      exit 1 ;;
    esac
    case "$a" in "$b"/*)
      echo "::error::web root '${a}' is inside web root '${b}'. Web roots must be siblings under DEPLOY_BASE_DIR."
      exit 1 ;;
    esac

    j=$((j + 1))
  done
  i=$((i + 1))
done

echo "${count} web root(s) validated."

# The repository root is NOT supported as a web root, and the generic
# dots-only rejection below would explain that badly - its message is
# about destinations collapsing onto DEPLOY_BASE_DIR, which is not the
# problem here. Catch it first and say something useful.
#
# Syncing the repository root to a web root publishes .git (full
# history, and any secret ever committed and later removed), .github,
# tests, and dependency manifests. It also cannot coexist with a
# private app directory, because that directory would sit INSIDE the
# published tree. Both are structural, so this is a hard no rather
# than a warning.
reject_repo_root "public-dir" "$PUBLIC_DIR" || exit 1
check_relative_dir "public-dir" "$PUBLIC_DIR" || exit 1

# Report the NORMALIZED values, matching what the rsync steps actually
# use. Echoing the raw input would print "app//" for a value with a
# trailing slash and quietly disagree with the destination below it.
echo "public dir:     $(norm_path "$PUBLIC_DIR")/  (repo)"

# The app directory is optional. When deploy-app-dir is false the site has
# no private tree at all, so none of the app-* inputs are validated or
# used - see the input's description for why this is a typed boolean
# rather than an empty app-dir.
#
# app-remote-dir defaults to app-dir so the out-of-box behavior is
# "the server name matches the repo name"; an input cannot default to
# another input, so the fallback is applied here.
if [ "$DEPLOY_APP_DIR" = "true" ]; then
  reject_repo_root "app-dir" "$APP_DIR" || exit 1
  check_relative_dir "app-dir" "$APP_DIR" || exit 1

  # The app directory must sit outside the public directory IN THE
  # REPOSITORY, not merely beside it on the server.
  #
  # The server-side comparison below cannot see this. With
  # app-dir=public/app and public-dir=public, every server-side check
  # passes - <BASE>/app really is beside <BASE>/site.com - while the
  # public sync copies public/'s CONTENTS into each web root, app/
  # included. The entire private tree ends up served over HTTP, and
  # excluding dotfiles would not help, because it is the source and
  # config that are exposed.
  public_repo=$(norm_path "$PUBLIC_DIR")
  app_repo=$(norm_path "$APP_DIR")

  if [ "$app_repo" = "$public_repo" ]; then
    echo "::error::app-dir and public-dir are the same directory ('${app_repo}')."
    echo "The private tree would be published over HTTP."
    exit 1
  fi
  case "$app_repo" in "$public_repo"/*)
    echo "::error::app-dir '${app_repo}' is INSIDE public-dir '${public_repo}'."
    echo "Everything under public-dir is copied into the web roots, so the private tree would be served over HTTP."
    exit 1 ;;
  esac
  case "$public_repo" in "$app_repo"/*)
    echo "::error::public-dir '${public_repo}' is INSIDE app-dir '${app_repo}'."
    echo "The app sync would then carry the public tree as well, and the two rsyncs would overlap."
    exit 1 ;;
  esac

  app_remote="${APP_REMOTE_DIR:-$APP_DIR}"
  check_relative_dir "app-remote-dir" "$app_remote" || exit 1
  app_norm=$(norm_path "$app_remote")

  # The entire design rests on the app directory sitting BESIDE the
  # web roots, never within one. Nothing above enforces that:
  # app-remote-dir may legally contain slashes, so 'site.com/app'
  # passes every other check and then places the whole application
  # source inside a web root, served over HTTP.
  #
  # Note that excluding dotfiles would not save you here - if the app
  # tree lands in a web root, its source, config and any server-side
  # credentials are already public. The layout is the control.
  for wr in "${web_roots[@]}"; do
    if [ "$app_norm" = "$wr" ]; then
      echo "::error::app-remote-dir '${app_norm}' is the same directory as web root '${wr}'."
      echo "The two rsyncs both run with --delete, so they would erase each other."
      exit 1
    fi
    case "$app_norm" in "$wr"/*)
      echo "::error::app-remote-dir '${app_norm}' is INSIDE web root '${wr}'."
      echo "That publishes your application source over HTTP. It must sit beside the web roots, not within one."
      exit 1 ;;
    esac
    case "$wr" in "$app_norm"/*)
      echo "::error::web root '${wr}' is INSIDE app-remote-dir '${app_norm}'."
      echo "The two rsyncs both run with --delete, so they would erase each other. They must be siblings."
      exit 1 ;;
    esac
  done

  echo "app dir:        $(norm_path "$APP_DIR")/  (repo)  ->  ${app_norm}/  (server)"
else
  echo "app dir:        none (deploy-app-dir is false)"
fi

# ------------------------------------------------------------ outputs
#
# Facts, never interpretations. `paths-deleted: 412` is something a
# consumer can write a policy against; a `risky: true` computed here
# would bake one site's policy into shared code.
#
# NOTHING DERIVED FROM A SECRET GOES IN HERE. base-dir, host and user
# are secrets, so the rsync destination, the account path and any
# summary built from them stay in the log where masking applies. What
# ships is names and counts.
#
# Web roots are emitted as JSON so a caller can fromJSON() them straight
# into a matrix. Building it by hand rather than with jq: the runner has
# jq, but a self-contained loop is one less thing to depend on, and the
# values are already validated to contain no quotes or backslashes.
roots_json="["
sep=""
for wr in "${web_roots[@]}"; do
  roots_json="${roots_json}${sep}\"${wr}\""
  sep=","
done
roots_json="${roots_json}]"

{
  echo "deployed-sha=${deployed_sha}"
  echo "started-at=${started_at}"
  echo "started-epoch=${started_epoch}"
  echo "web-roots=${roots_json}"
  echo "web-root-count=${#web_roots[@]}"
  echo "app-remote-dir=${app_norm:-}"
  # The effective value, not the raw input. The deploy-app-dir check above
  # already limits it to two spellings, so this is belt and braces - but an
  # output that passes its input through is one validation change away from
  # publishing something a consumer's `== 'false'` will never match.
  if [ "$DEPLOY_APP_DIR" = "true" ]; then
    echo "app-deployed=true"
  else
    echo "app-deployed=false"
  fi
} >> "$GITHUB_OUTPUT"
