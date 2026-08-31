#!/usr/bin/env bash
# Shared machinery for the tests in this directory.
#
# The whole point of these tests is that they exercise the SHIPPING code, not a
# transcription of it. The shell that matters lives inside `run:` blocks in
# .github/workflows/deploy.yml, so the harness pulls those blocks back out of
# the YAML and runs them. A copy of the logic maintained here would pass while
# the workflow was broken, which is the failure mode the tests exist to prevent.
#
# Extraction is done with awk rather than a YAML parser on purpose: these tests
# must run with nothing installed, so that a broken change can be caught before
# a network-dependent step even starts. The trade is that extraction is
# structural, so every extractor below asserts a sentinel and aborts loudly if
# it comes back with nothing recognizable. A test harness that silently tests an
# empty string is worse than no harness.

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

TESTS_RUN=0
TESTS_FAILED=0

# DEPLOY_WORKFLOW and GH_BASH are read by the *.test.sh files that source this
# one, which shellcheck cannot see from here - hence the narrow disable rather
# than exporting them into the environment of every command the tests run.
#
# GH_BASH matters: GitHub runs `shell: bash` steps as
# `bash --noprofile --norc -eo pipefail`, and anything else would test a
# different language. `-e` in particular changes what a failing command inside
# a guard does.
# shellcheck disable=SC2034
DEPLOY_WORKFLOW="${REPO_ROOT}/.github/workflows/deploy.yml"
# shellcheck disable=SC2034
GH_BASH=(bash --noprofile --norc -eo pipefail)

# ---------------------------------------------------------------- extraction

# Pull one step's `run:` body out of a workflow, dedented.
#
# $1 workflow path, $2 exact step name as it appears after `- name: `.
extract_run_step() {
  local file="$1" name="$2" out
  out=$(awk -v want="$name" '
    function bare(s) { sub(/^[ \t]*/, "", s); return s }
    state == 0 { if (bare($0) == "- name: " want) state = 1; next }
    # A new step began before a `run:` did - this step has no script.
    state == 1 && bare($0) ~ /^- / { exit }
    state == 1 { if (bare($0) == "run: |") state = 2; next }
    state == 2 {
      if ($0 ~ /^[ \t]*$/) { print ""; next }
      match($0, /^ */)
      if (indent == 0) indent = RLENGTH
      if (RLENGTH < indent) exit
      print substr($0, indent + 1)
    }
  ' "$file")

  if [ -z "$out" ]; then
    echo "HARNESS ERROR: no run: body found for step '${name}' in ${file}." >&2
    echo "The step was renamed, or its indentation changed. Fix the extractor." >&2
    exit 2
  fi
  printf '%s\n' "$out"
}

# Pull one shell function definition out of an already-extracted script.
#
# $1 file containing shell, $2 function name. Assumes the closing brace sits at
# the same indentation as the definition, which is true throughout deploy.yml
# and is verified by the `bash -n` check in require_shell below.
extract_function() {
  local file="$1" fn="$2" out
  out=$(awk -v fn="$fn" '
    function bare(s) { sub(/^[ \t]*/, "", s); return s }
    state == 0 {
      if (bare($0) == fn "() {") {
        match($0, /^ */); indent = RLENGTH
        state = 1
        print substr($0, indent + 1)
      }
      next
    }
    state == 1 {
      match($0, /^ */); cur = RLENGTH
      print substr($0, indent + 1)
      if (cur == indent && bare($0) == "}") exit
    }
  ' "$file")

  if [ -z "$out" ]; then
    echo "HARNESS ERROR: function '${fn}' not found in ${file}." >&2
    exit 2
  fi
  printf '%s\n' "$out"
}

# Abort unless the extracted shell parses and contains an expected marker.
# Catches the case where the extractor returns something, but the wrong thing.
#
# $1 file, $2 marker that must appear.
require_shell() {
  local file="$1" marker="$2"
  if ! grep -q -- "$marker" "$file"; then
    echo "HARNESS ERROR: ${file} does not contain '${marker}' - extraction is wrong." >&2
    exit 2
  fi
  if ! bash -n "$file" 2>/dev/null; then
    echo "HARNESS ERROR: ${file} does not parse as shell." >&2
    bash -n "$file"
    exit 2
  fi
}

# ---------------------------------------------------------------- assertions

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  FAIL: $1"
  shift
  local line
  for line in "$@"; do echo "        $line"; done
}

# $1 expected, $2 actual, $3 label
assert_eq() {
  if [ "$1" = "$2" ]; then _pass; else
    _fail "$3" "expected: '$1'" "actual:   '$2'"
  fi
}

# $1 expected exit code, $2 label, rest: command to run.
assert_exit() {
  local want="$1" label="$2"; shift 2
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then _pass; else
    _fail "$label" "expected exit ${want}, got ${rc}" "output:" "${out}"
  fi
}

# $1 needle, $2 label, rest: command whose combined output must contain needle.
assert_output_contains() {
  local needle="$1" label="$2"; shift 2
  local out
  out=$("$@" 2>&1)
  case "$out" in
    *"$needle"*) _pass ;;
    *) _fail "$label" "expected output to contain: '${needle}'" "actual output:" "${out}" ;;
  esac
}

describe() { echo; echo "  $1"; }

finish() {
  echo
  if [ "$TESTS_FAILED" -eq 0 ]; then
    echo "  ${TESTS_RUN} assertion(s), all passed"
  else
    echo "  ${TESTS_RUN} assertion(s), ${TESTS_FAILED} FAILED"
  fi
  return "$TESTS_FAILED"
}
