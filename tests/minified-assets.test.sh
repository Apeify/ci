#!/usr/bin/env bash
# Tests for the minification handoff: the minify job in minify.yml, and
# the two deploy-action scripts that receive what it produced.
#
# The two halves live in different files and agree on a record format only by
# convention, so the central test here runs BOTH, as written, and feeds one's
# output to the other. A transcription of either side under tests/ would let
# them drift apart while every assertion stayed green.
#
# Everything the deploy side refuses is the point of the design - the artifact
# comes from a job that ran third-party code - so most cases below are an
# artifact a compromised minify job could produce, and each asserts WHICH
# refusal fired, not merely that something failed.
#
# esbuild itself is replaced by a stand-in `npx` on PATH: these tests need no
# network, and what they test is the shell around the minifier, not esbuild.
# The JS-validity cases need a real Node; without one they are reported as
# skipped rather than silently passing.

# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

MINIFY_WORKFLOW="${REPO_ROOT}/.github/workflows/minify.yml"

MINIFY="${WORK}/minify.sh"
extract_run_step "$MINIFY_WORKFLOW" "Minify and stage CSS and JS" > "$MINIFY"
require_shell "$MINIFY" "STAGE_DIR"

PUBLISH="${WORK}/publish.sh"
extract_run_step "$MINIFY_WORKFLOW" "Publish the handoff" > "$PUBLISH"
require_shell "$PUBLISH" "minified-assets="

HANDOFF="${DEPLOY_SCRIPTS}/check-handoff.sh"

APPLY="${DEPLOY_SCRIPTS}/apply-minified-assets.sh"

# ------------------------------------------------------------ stand-ins

BIN="${WORK}/bin"
mkdir -p "$BIN"

# A minifier that drops comment lines and blank lines, which is enough to make
# the output observably different from the source. STUB_ESBUILD selects a
# broken minifier instead. Every call is logged so a test can assert esbuild was
# never fetched at all.
cat > "${BIN}/npx" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${NPX_LOG:-/dev/null}"
[ "$1" = "--yes" ] && shift
shift
if [ "$1" = "--version" ]; then echo "0.25.10"; exit 0; fi
in="$1"; out=""
for a in "$@"; do
  case "$a" in --outfile=*) out="${a#--outfile=}" ;; esac
done
case "${STUB_ESBUILD:-}" in
  empty) : > "$out"; exit 0 ;;
  garbage) printf 'function (\n' > "$out"; exit 0 ;;
esac
grep -v -E '^[[:space:]]*(//|/\*|$)' "$in" > "${out}.stub-tmp" || true
mv -- "${out}.stub-tmp" "$out"
STUB
chmod +x "${BIN}/npx"

HAVE_NODE=1
if ! command -v node >/dev/null 2>&1; then
  HAVE_NODE=0
  # Only so the success paths can run. Every case that depends on Node really
  # judging JavaScript is skipped below when this stand-in is in use.
  printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN}/node"
  chmod +x "${BIN}/node"
fi

skip() { echo "  SKIP: $1"; }

# A refusal must both FAIL and say which guard fired. Checking only the message
# passes against a guard whose `exit 1` was deleted, because the error line is
# still printed - which mutation testing caught on both collapse guards.
#
# $1 needle, $2 label, rest: command.
assert_refused() {
  local needle="$1" label="$2"; shift 2
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    _fail "$label" "expected a refusal, got exit 0" "output:" "${out}"
    return
  fi
  case "$out" in
    *"$needle"*) _pass ;;
    *) _fail "$label" "refused, but not by the expected guard: '${needle}'" "actual output:" "${out}" ;;
  esac
}

# ------------------------------------------------------------ fixtures

# A source tree covering the awkward names: a nested directory, a dotfile, a
# space in a name, and a non-asset file that must never be staged.
make_site() {
  local root="$1"
  mkdir -p "${root}/public/assets/js"
  printf '/* header */\nbody { color: red; }\n\n/* footer */\n' > "${root}/public/assets/site.css"
  printf '// a comment\nvar a = 1;\n' > "${root}/public/assets/js/app.js"
  printf '// hidden\nvar h = 2;\n' > "${root}/public/assets/.hidden.js"
  printf '/* spaced */\np { margin: 0; }\n' > "${root}/public/assets/my file.css"
  printf '<?php echo "hi";\n' > "${root}/public/index.php"
}

# Run the minify job's step in $1, staging into $WORK/rt/minified-assets.
run_minify() {
  local ws="$1"; shift
  rm -rf "${WORK}/rt"
  mkdir -p "${WORK}/rt"
  : > "${WORK}/minify_output"
  (cd "$ws" && env -i PATH="${BIN}:${PATH}" HOME="$HOME" \
    RUNNER_TEMP="${WORK}/rt" \
    STAGE_DIR="${WORK}/rt/minified-assets" \
    PUBLIC_DIR=public \
    GITHUB_OUTPUT="${WORK}/minify_output" \
    "$@" "${GH_BASH[@]}" "$MINIFY")
}

minify_out() { sed -n "s/^$1=//p" "${WORK}/minify_output"; }

# Run the deploy's apply step in $1. The default download directory is what a
# faithful artifact round trip leaves.
run_apply() {
  local ws="$1"; shift
  (cd "$ws" && env -i PATH="${BIN}:${PATH}" HOME="$HOME" \
    PUBLIC_DIR=public \
    DOWNLOAD_DIR="${WORK}/dl" \
    "$@" bash "$APPLY")
}

# A fresh pair of checkouts, the minify job run in one, and its staging
# directory "uploaded and downloaded" for the other. Sets TOKEN to what the
# Publish step would emit for artifact id 12345.
setup_round_trip() {
  rm -rf "${WORK}/m" "${WORK}/d" "${WORK}/dl"
  make_site "${WORK}/m"
  make_site "${WORK}/d"
  run_minify "${WORK}/m" >/dev/null 2>&1
  cp -R "${WORK}/rt/minified-assets" "${WORK}/dl"
  TOKEN="12345:$(minify_out digest)"
}

# What a compromised minify job could publish for whatever is in $WORK/dl: a
# digest that is internally consistent with the files it uploaded. This IS a
# copy of the record format, deliberately - it plays the attacker, who knows the
# format. The round-trip test is what checks the two real sides agree.
forge_token() {
  local ws="$1" rel records
  records=$(mktemp)
  while IFS= read -r -d '' rel; do
    printf '%s\0%s\0%s\0' "$rel" \
      "$(sha256sum < "${ws}/public/${rel}" | cut -d' ' -f1)" \
      "$(sha256sum < "${WORK}/dl/${rel}" | cut -d' ' -f1)" >> "$records"
  done < <(cd "${WORK}/dl" && find . -type f -print0 | sed -z 's|^\./||' | LC_ALL=C sort -z)
  echo "12345:$(sha256sum < "$records" | cut -d' ' -f1)"
  rm -f "$records"
}

# ------------------------------------------------------------ minify job

describe "the minify job stages every asset and publishes a digest"
rm -rf "${WORK}/m"; make_site "${WORK}/m"
assert_exit 0 "baseline minify" run_minify "${WORK}/m"
assert_eq "4" "$(minify_out count)" "count includes nested, hidden and spaced names"
if [[ "$(minify_out digest)" =~ ^[0-9a-f]{64}$ ]]; then _pass; else
  _fail "digest is a SHA256" "got: '$(minify_out digest)'"
fi
staged=$(cd "${WORK}/rt/minified-assets" && find . -type f | LC_ALL=C sort | tr '\n' '|')
assert_eq "./assets/.hidden.js|./assets/js/app.js|./assets/my file.css|./assets/site.css|" \
  "$staged" "exactly the CSS/JS is staged, under paths relative to public-dir"
assert_eq "body { color: red; }" "$(cat "${WORK}/rt/minified-assets/assets/site.css")" \
  "the staged file is the minified one"

describe "the minify job fetches nothing when there is nothing to minify"
rm -rf "${WORK}/m"; mkdir -p "${WORK}/m/public"
: > "${WORK}/npx_log"
assert_exit 0 "no assets directory is a normal state" run_minify "${WORK}/m" NPX_LOG="${WORK}/npx_log"
assert_eq "0" "$(minify_out count)" "count is 0"
assert_eq "" "$(cat "${WORK}/npx_log")" "esbuild is not even downloaded"

describe "the minify job refuses a broken minifier"
rm -rf "${WORK}/m"; make_site "${WORK}/m"
assert_refused "collapsed from" "a file minified to nothing" \
  run_minify "${WORK}/m" STUB_ESBUILD=empty
if [ "$HAVE_NODE" -eq 1 ]; then
  rm -rf "${WORK}/m"; make_site "${WORK}/m"
  assert_refused "SyntaxError" "a JS file minified to garbage" run_minify "${WORK}/m" STUB_ESBUILD=garbage
else
  skip "a JS file minified to garbage (node not installed)"
fi

# ------------------------------------------------------------ publish

run_publish() {
  : > "${WORK}/publish_output"
  env -i PATH="$PATH" GITHUB_OUTPUT="${WORK}/publish_output" "$@" "${GH_BASH[@]}" "$PUBLISH"
}
publish_out() { sed -n 's/^minified-assets=//p' "${WORK}/publish_output"; }

describe "the handoff value names the artifact by id"
D=$(printf 'a%.0s' {1..64})
run_publish COUNT=0 >/dev/null 2>&1
assert_eq "none" "$(publish_out)" "no assets publishes none"
run_publish COUNT=4 ARTIFACT_ID=987 DIGEST="$D" >/dev/null 2>&1
assert_eq "987:${D}" "$(publish_out)" "id and digest"
assert_refused "no usable artifact id" "an upload with no id is refused" \
  run_publish COUNT=4 ARTIFACT_ID= DIGEST="$D"

# ------------------------------------------------------------ deploy: handoff

run_handoff() {
  : > "${WORK}/handoff_output"
  env -i PATH="$PATH" GITHUB_OUTPUT="${WORK}/handoff_output" \
    DOWNLOAD_DIR="${WORK}/dl" "$@" bash "$HANDOFF"
}
handoff_id() { sed -n 's/^artifact-id=//p' "${WORK}/handoff_output"; }

describe "the deploy checks the handoff's shape before anything else"
assert_exit 0 "none is accepted" run_handoff MINIFIED_ASSETS=none
assert_eq "" "$(handoff_id)" "none downloads nothing"
assert_exit 0 "a real value is accepted" run_handoff MINIFIED_ASSETS="42:${D}"
assert_eq "42" "$(handoff_id)" "the artifact id is extracted"
assert_refused "input is empty" "a stub that never passed it" run_handoff MINIFIED_ASSETS=
assert_refused "not a value the minify workflow produces" "a hand-written literal" \
  run_handoff MINIFIED_ASSETS=skip
assert_refused "not a value the minify workflow produces" "an artifact NAME instead of an id" \
  run_handoff MINIFIED_ASSETS="minified-assets-1:${D}"
assert_refused "not a value the minify workflow produces" "a short digest" \
  run_handoff MINIFIED_ASSETS="42:abc"
mkdir -p "${WORK}/dl/assets"; touch "${WORK}/dl/assets/stale.css"
run_handoff MINIFIED_ASSETS=none >/dev/null 2>&1
if [ -e "${WORK}/dl" ]; then _fail "a leftover download directory is cleared"; else _pass; fi

# ------------------------------------------------------------ deploy: apply

describe "a faithful round trip applies (the two halves agree on the format)"
setup_round_trip
assert_exit 0 "the minify job's own output is accepted" run_apply "${WORK}/d" MINIFIED_ASSETS="$TOKEN"
assert_eq "body { color: red; }" "$(cat "${WORK}/d/public/assets/site.css")" \
  "the deploy tree now holds the minified file"
assert_eq "p { margin: 0; }" "$(cat "${WORK}/d/public/assets/my file.css")" \
  "a name with a space survives the round trip"
assert_eq "var h = 2;" "$(cat "${WORK}/d/public/assets/.hidden.js")" \
  "a dotfile survives the round trip"
assert_eq '<?php echo "hi";' "$(cat "${WORK}/d/public/index.php")" "non-assets are untouched"

describe "the deploy refuses an artifact that holds anything extra"
setup_round_trip
printf '<?php phpinfo();\n' >"${WORK}/dl/assets/shell.php"
assert_refused "does not hold exactly" "a planted .php file" \
  run_apply "${WORK}/d" MINIFIED_ASSETS="$TOKEN"
if [ -e "${WORK}/d/public/assets/shell.php" ]; then
  _fail "the planted file must never reach the tree"
else _pass; fi
assert_eq "/* header */" "$(head -n1 "${WORK}/d/public/assets/site.css")" \
  "a refused artifact leaves the tree as checked out"

setup_round_trip
printf 'x{}\n' > "${WORK}/dl/assets/extra.css"
assert_refused "does not hold exactly" "an extra CSS file the checkout does not have" \
  run_apply "${WORK}/d" MINIFIED_ASSETS="$TOKEN"

describe "the deploy refuses an artifact that is missing a file"
setup_round_trip
rm "${WORK}/dl/assets/js/app.js"
assert_refused "does not hold exactly" "one asset missing would ship unminified" \
  run_apply "${WORK}/d" MINIFIED_ASSETS="$TOKEN"

describe "the deploy refuses symlinks"
setup_round_trip
rm "${WORK}/dl/assets/site.css"
ln -s "${HOME}/.ssh/deploy_key" "${WORK}/dl/assets/site.css" 2>/dev/null
if [ -L "${WORK}/dl/assets/site.css" ]; then
  assert_refused "is not a regular file" "a symlink where an asset should be" \
    run_apply "${WORK}/d" MINIFIED_ASSETS="$TOKEN"
else
  skip "a symlink where an asset should be (this platform cannot create symlinks)"
fi

setup_round_trip
rm "${WORK}/dl/assets/site.css"
mkfifo "${WORK}/dl/assets/site.css" 2>/dev/null
if [ -p "${WORK}/dl/assets/site.css" ]; then
  # A FIFO would hang the hashing below rather than fail it, so this one is
  # about the guard firing BEFORE anything reads the file. Under `timeout` so
  # that, with the guard broken, the suite fails instead of hanging forever.
  assert_refused "is not a regular file" "a named pipe where an asset should be" \
    timeout 30 bash -c "$(declare -f run_apply); $(declare -p WORK BIN APPLY); run_apply \"\$@\"" _ \
    "${WORK}/d" MINIFIED_ASSETS="$TOKEN"
else
  skip "a named pipe where an asset should be (this platform cannot create FIFOs)"
fi

describe "the deploy refuses content the digest does not cover"
setup_round_trip
printf 'body{color:blue}\n' > "${WORK}/dl/assets/site.css"
assert_refused "do not match the digest" "a minified file altered after the minify job" \
  run_apply "${WORK}/d" MINIFIED_ASSETS="$TOKEN"
assert_eq "/* header */" "$(head -n1 "${WORK}/d/public/assets/site.css")" \
  "a digest refusal leaves the tree as checked out"

setup_round_trip
printf '/* a different source */\nh1 { x: y; }\n' > "${WORK}/d/public/assets/site.css"
assert_refused "do not match the digest" "the deploy's source differs from what was minified" \
  run_apply "${WORK}/d" MINIFIED_ASSETS="$TOKEN"

setup_round_trip
assert_refused "do not match the digest" "a digest from a different run" \
  run_apply "${WORK}/d" MINIFIED_ASSETS="12345:${D}"

describe "the deploy refuses a public-dir mismatch between the two halves"
setup_round_trip
mkdir -p "${WORK}/d/web/assets"
printf 'body { color: green; }\n' > "${WORK}/d/web/assets/site.css"
assert_refused "does not hold exactly" "a different directory with different assets" \
  run_apply "${WORK}/d" MINIFIED_ASSETS="$TOKEN" PUBLIC_DIR=web
mkdir -p "${WORK}/d/empty"
assert_refused "holds none" "a different directory with no assets" \
  run_apply "${WORK}/d" MINIFIED_ASSETS="$TOKEN" PUBLIC_DIR=empty

describe "none is only accepted when there really is nothing to minify"
setup_round_trip
assert_refused "minified nothing" "none, but the checkout has CSS/JS" \
  run_apply "${WORK}/d" MINIFIED_ASSETS=none
mkdir -p "${WORK}/bare/public"
assert_exit 0 "none, and the checkout has none" run_apply "${WORK}/bare" MINIFIED_ASSETS=none

describe "the deploy refuses when the artifact never arrived"
setup_round_trip
rm -rf "${WORK}/dl"
assert_refused "was not downloaded" "no download directory" \
  run_apply "${WORK}/d" MINIFIED_ASSETS="$TOKEN"

describe "the deploy re-checks what it received instead of trusting the minify job"
# A compromised minify job publishes a digest consistent with what it uploaded,
# so these get past the digest and must be caught by the checks after it.
setup_round_trip
: > "${WORK}/dl/assets/site.css"
assert_refused "collapsed from" "an empty file under a consistent digest" \
  run_apply "${WORK}/d" MINIFIED_ASSETS="$(forge_token "${WORK}/d")"
if [ "$HAVE_NODE" -eq 1 ]; then
  setup_round_trip
  printf 'function (\n' > "${WORK}/dl/assets/js/app.js"
  assert_refused "not valid JavaScript" "invalid JS under a consistent digest" \
    run_apply "${WORK}/d" MINIFIED_ASSETS="$(forge_token "${WORK}/d")"
else
  skip "invalid JS under a consistent digest (node not installed)"
fi

finish
