#!/usr/bin/env bash
# Tests for "Resolve PHP version" in lint-and-test.yml: which version reaches
# setup-php, and when an explicit input is refused for disagreeing with the
# repo's .php-version.
#
# An empty output is the point of the design, not a gap: it is what makes
# setup-php read .php-version itself. So each case asserts the exact value
# handed on, and every refusal asserts both the failure and its message.

# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

RESOLVE="${WORK}/resolve.sh"
extract_run_step "${REPO_ROOT}/.github/workflows/lint-and-test.yml" "Resolve PHP version" > "$RESOLVE"
require_shell "$RESOLVE" "php-version"

# The default is read from the workflow, not restated here, so bumping it does
# not mean editing a test - and an empty read fails loudly below.
DEFAULT_PHP=$(sed -n -E "s/^  DEFAULT_PHP_VERSION: '([^']*)'$/\1/p" \
  "${REPO_ROOT}/.github/workflows/lint-and-test.yml")
if [ -z "$DEFAULT_PHP" ]; then
  echo "HARNESS ERROR: no DEFAULT_PHP_VERSION found in lint-and-test.yml's env." >&2
  exit 2
fi

# $1 .php-version contents (the literal NONE for no file), $2 the input.
# Runs in a fresh repo dir; leaves the step's GITHUB_OUTPUT at ${WORK}/out.
run_resolve() {
  local dir="${WORK}/repo"
  rm -rf "$dir" "${WORK}/out"
  mkdir -p "$dir"
  : > "${WORK}/out"
  [ "$1" = NONE ] || printf '%b' "$1" > "${dir}/.php-version"
  (cd "$dir" && DEFAULT_PHP_VERSION="${3-$DEFAULT_PHP}" \
    REQUESTED="$2" GITHUB_OUTPUT="${WORK}/out" "${GH_BASH[@]}" "$RESOLVE")
}

resolved() { sed -n 's/^version=//p' "${WORK}/out"; }

# $1 file, $2 input, $3 expected version output, $4 label
expect_version() {
  assert_exit 0 "$4 (succeeds)" run_resolve "$1" "$2"
  assert_eq "$3" "$(resolved)" "$4"
}

describe "no .php-version"
expect_version NONE "" "$DEFAULT_PHP" "falls back to DEFAULT_PHP_VERSION, never to setup-php's 'latest'"
expect_version NONE "8.2" "8.2" "uses the input"
expect_version NONE "  8.2 " "8.2" "trims whitespace around the input"

describe "an input with whitespace inside it is refused, not repaired"
assert_exit 1 "a space inside the version" run_resolve NONE "8. 3"
assert_output_contains "contains whitespace" "says why" run_resolve NONE "8. 3"
assert_exit 1 "a tab inside the version" run_resolve NONE "$(printf '8.\t3')"
assert_exit 1 "refused even when a .php-version exists" run_resolve '8.3\n' "8. 3"

describe "a missing default is an error, not an empty version"
assert_exit 1 "an empty DEFAULT_PHP_VERSION" run_resolve NONE "" ""
assert_output_contains "DEFAULT_PHP_VERSION is not set" "names the missing setting" \
  run_resolve NONE "" ""
# Refused even when this run would not need it: a lost setting is a broken
# workflow, and it should surface on the first run, not the first fallback.
assert_exit 1 "refused even with an explicit input" run_resolve NONE "8.2" ""

describe ".php-version present: setup-php is left to read it"
expect_version '8.4\n' "" "" "no input passes nothing"
expect_version '8.4.1\n' "8.4.1" "" "a matching input passes nothing"
expect_version 'php 8.4.1\n' "8.4.1" "" "matches through a 'php ' prefix"
expect_version '8.4\r\n' "8.4" "" "matches a CRLF file"
expect_version '  8.4  \n\n' "8.4" "" "matches a file with stray whitespace"

describe "an input that disagrees with .php-version is refused"
assert_exit 1 "different minor" run_resolve '8.4\n' "8.3"
assert_output_contains "disagrees with .php-version ('8.4')" "names both values" \
  run_resolve '8.4\n' "8.3"
# Exact by choice. setup-php truncates every version to major.minor,
# so 8.4 and 8.4.1 install the same PHP - but the step does not encode that
# rule, so the two are refused as two values that merely look compatible.
assert_exit 1 "minor input against a patch-level file" run_resolve '8.4.1\n' "8.4"
assert_exit 1 "differing patch levels" run_resolve '8.4.1\n' "8.4.2"
# An empty file is still a file: the input does not quietly win over it.
assert_exit 1 "an empty .php-version against an input" run_resolve '' "8.3"
assert_exit 1 "a whitespace-only .php-version against an input" run_resolve ' \n' "8.3"
# The refusal must stop before anything reaches setup-php.
run_resolve '8.4\n' "8.3" >/dev/null 2>&1
assert_eq "" "$(cat "${WORK}/out")" "a refusal writes no version output"

# Everything above is worthless if setup-php is handed the raw input instead:
# an empty one sends it to composer.json and then to "latest", silently.
describe "setup-php is given the resolved version"
setup_php_version=$(awk '
  /- name: Set up PHP$/ { found = 1; next }
  found && /^[[:space:]]*- / { exit }
  found && /^[[:space:]]*php-version:/ { sub(/^[[:space:]]*php-version:[[:space:]]*/, ""); print; exit }
' "${REPO_ROOT}/.github/workflows/lint-and-test.yml")
# shellcheck disable=SC2016 # a literal expression, not shell
assert_eq '${{ steps.php.outputs.version }}' "$setup_php_version" "Set up PHP reads steps.php.outputs.version"
assert_output_contains "id: php" "the resolve step has the id the wiring names" \
  grep -A1 -- "- name: Resolve PHP version" "${REPO_ROOT}/.github/workflows/lint-and-test.yml"

finish
