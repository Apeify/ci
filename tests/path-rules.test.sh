#!/usr/bin/env bash
# Unit tests for the three path helpers defined in the deploy action's preflight.
#
# These are the highest-value tests in the repo. Every path in the workflow is
# interpolated into an rsync destination that runs with --delete, the layout
# checks that keep the private tree off the public web are string prefix tests,
# and a value that reaches them in an unexpected spelling defeats them SILENTLY.
# That exact bug has shipped twice - see the norm_path cases marked REGRESSION.

# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

extract_run_step "$DEPLOY_ACTION" "Preflight - check configuration" > "${WORK}/preflight.sh"
require_shell "${WORK}/preflight.sh" "norm_path()"

for fn in norm_path check_relative_dir reject_repo_root; do
  extract_function "${WORK}/preflight.sh" "$fn" >> "${WORK}/fns.sh"
done
require_shell "${WORK}/fns.sh" "reject_repo_root()"
# shellcheck source=/dev/null
source "${WORK}/fns.sh"

# On `set -e`, and why these functions are called directly.
#
# harness.sh runs under `set -uo pipefail` - no `-e` - while GitHub runs the real
# step as `bash --noprofile --norc -eo pipefail`. That difference looks like it
# should matter and does not, because of HOW the workflow calls these functions.
# Every call site is of the form:
#
#   check_relative_dir "public-dir" "$PUBLIC_DIR" || exit 1
#
# and bash disables `errexit` inside a function invoked as the left operand of
# `||`. A non-zero command inside the body does not abort anything in production
# either; the body runs on to its `return`, exactly as it does here. Calling
# them directly is therefore the faithful reproduction.
#
# An earlier version wrapped them in `( set -eo pipefail; "$@" )` believing the
# opposite, and that wrapper was worse than the thing it replaced: it diverged
# in the FAIL-OPEN direction. Change a `return 1` to a bare `false` and
# production falls through to `return 0` and ACCEPTS the bad value, while the
# wrapper's subshell aborts at the `false` and reports a refusal - so the test
# passed on a mutation that had broken the guard.
#
# If a call site ever stops using `|| exit 1`, this reasoning changes with it.

describe "norm_path collapses every spelling of the same path"
while read -r input expected; do
  [ "$input" = "@empty" ] && input=""
  [ "$expected" = "@empty" ] && expected=""
  assert_eq "$expected" "$(norm_path "$input")" "norm_path '${input}'"
done <<'CASES'
@empty            @empty
public            public
public/           public
public//          public
./public          public
.//public//       public
././public        public
.                 .
./                @empty
.//               @empty
/                 @empty
//                @empty
./site.com/app    site.com/app
site.com/.        site.com
site.com/./       site.com
site.com/././     site.com
site.com//.       site.com
a/./b             a/b
a/././b           a/b
x/./././y         x/y
a/.b              a/.b
.well-known       .well-known
apps/site.com     apps/site.com
CASES

describe "norm_path regressions - each of these once bypassed a layout check"
# Round 2: only the repository-side values were normalized, and only one
# leading './', so this reached the nesting test spelled differently from the
# web root it was nested inside.
assert_eq "site.com/app" "$(norm_path './site.com/app')" "REGRESSION leading ./"
# Round 4: every value was normalized, but a trailing '/.' survived, so the
# nesting test built the pattern 'site.com/./*' and never matched 'site.com/app'.
assert_eq "site.com" "$(norm_path 'site.com/.')" "REGRESSION trailing /."

describe "check_relative_dir accepts real relative directories"
for good in public app site.com apps/site .well-known a/.b public/ ./public; do
  assert_exit 0 "check_relative_dir accepts '${good}'" check_relative_dir label "$good"
done

describe "check_relative_dir refuses what would retarget the deploy"
for bad in "" "." "./" ".//" "././" "/" "//" "/etc" "../x" "a/../b" "a/.."; do
  assert_exit 1 "check_relative_dir refuses '${bad}'" check_relative_dir label "$bad"
done
assert_output_contains "must not contain '..'" "'..' is named in the error" \
  check_relative_dir label "../x"
assert_output_contains "resolves to its parent directory" "dot-only is named in the error" \
  check_relative_dir label "."
assert_output_contains "must be relative" "absolute is named in the error" \
  check_relative_dir label "/etc"
assert_output_contains "must not be empty" "empty is named in the error" \
  check_relative_dir label ""

describe "reject_repo_root refuses the repository root, and nothing else"
for bad in "." "./" ".//" "././" "/" "//"; do
  assert_exit 1 "reject_repo_root refuses '${bad}'" reject_repo_root public-dir "$bad"
done
# Empty is somebody else's job: check_relative_dir rejects it with a message
# about retargeting, which is the accurate diagnosis. reject_repo_root passing
# it through is deliberate, not an oversight.
assert_exit 0 "reject_repo_root ignores empty" reject_repo_root public-dir ""
for good in public app public/ ./public site.com/app app/.; do
  assert_exit 0 "reject_repo_root allows '${good}'" reject_repo_root public-dir "$good"
done

describe "the three norm_path definitions must not drift apart"
# norm_path is defined once in the preflight and once in each of the two rsync
# steps, because Actions steps are separate shells. Only the preflight copy is
# extracted above, so a change made to one and not the others would leave the
# rsync steps building destinations from a spelling the preflight never
# approved - and every assertion in this file would still pass. This is not
# hypothetical: the fix that taught norm_path to collapse '/.' had to edit all
# three.
mapfile -t bodies < <(awk '
  /norm_path\(\) \{/ { inblock = 1; body = ""; next }
  inblock && /^ *\}/  { print body; inblock = 0; next }
  inblock             { line = $0; sub(/^[ \t]+/, "", line); body = body line }
' "$DEPLOY_ACTION")

assert_exit 0 "norm_path is defined in more than one place" test "${#bodies[@]}" -ge 2
for body in "${bodies[@]}"; do
  assert_eq "${bodies[0]}" "$body" "every norm_path definition is byte-identical"
done

finish
