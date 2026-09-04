#!/usr/bin/env bash
# Tests for scripts/check-action-metadata.js.
#
# This guard exists because an expression in an action DESCRIPTION took every
# consumer down at load time, and nothing in five validation layers could see
# it. CLAUDE.md's rule applies with force here: a guard that can fail silently
# is worse than no guard, and the first version of this check shipped untested
# and had four bypasses and three false positives.
#
# Every case below is one of those. They are fixtures rather than mutations of
# the real action because the failures are about YAML SHAPE - key order, block
# scalars, indentation - which a mutation of one well-formed file cannot reach.

# The fixtures below are YAML containing GitHub expressions, which must reach
# the checker as literal text - that is the entire point of the test. Single
# quotes are correct here and shellcheck's suggestion to use double quotes would
# break every case by making bash try to expand them.
# shellcheck disable=SC2016

# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Resolve js-yaml once, the same way the wrapper does.
JS_YAML="${REPO_ROOT}/node_modules/js-yaml"
if [ ! -d "$JS_YAML" ]; then
  echo "  SKIPPED: js-yaml not installed (run: npm install --no-save js-yaml@4.1.0)"
  exit 0
fi

# Run the checker against a fixture action, from a scratch tree so the real
# actions/ directory is not scanned.
check() {
  local body="$1"
  rm -rf "${WORK}/tree"
  mkdir -p "${WORK}/tree/actions/fixture" "${WORK}/tree/scripts"
  cp "${REPO_ROOT}/scripts/check-action-metadata.js" "${WORK}/tree/scripts/"
  printf '%s\n' "$body" > "${WORK}/tree/actions/fixture/action.yml"
  ( cd "${WORK}/tree" && node scripts/check-action-metadata.js "$JS_YAML" ) 2>&1
}
rc() { check "$1" >/dev/null 2>&1; }

describe "the bug this guard exists for"
assert_exit 1 "an expression in an input description is rejected" rc 'name: x
description: y
inputs:
  a:
    description: Pass ${{ vars.WEB_ROOT_DIRS }} here.
runs:
  using: composite
  steps:
    - shell: bash
      run: echo hi'
assert_output_contains "inputs.a.description" "the offending path is named" check 'name: x
description: y
inputs:
  a:
    description: Pass ${{ vars.WEB_ROOT_DIRS }} here.
runs:
  using: composite
  steps:
    - shell: bash
      run: echo hi'

describe "bypasses the first, line-based version allowed through"
# YAML mappings are UNORDERED. Putting outputs after runs is the natural order,
# since output values reference step ids defined in runs.
assert_exit 1 "metadata AFTER runs: is still checked" rc 'name: x
description: y
runs:
  using: composite
  steps:
    - id: s
      shell: bash
      run: echo hi
outputs:
  z:
    description: Broken - ${{ vars.NOPE }}
    value: ${{ steps.s.outputs.z }}'

# A block scalar line that happens to read `value: ...` is prose, not a key.
assert_exit 1 "a usage example inside a description is rejected" rc 'name: x
description: |
  How to wire this up:
    value: ${{ vars.WEB_ROOT_DIRS }}
runs:
  using: composite
  steps:
    - shell: bash
      run: echo hi'

# Greedy matching read only the last expression on a line.
assert_exit 1 "an illegal context BEFORE a legal one is caught" rc 'name: x
description: y
outputs:
  z:
    description: d
    value: ${{ vars.NOPE }}-${{ steps.s.outputs.z }}
runs:
  using: composite
  steps:
    - id: s
      shell: bash
      run: echo hi'

describe "shapes the first version wrongly REJECTED"
# A folded value with the expression on the following line.
assert_exit 0 "a folded outputs value is accepted" rc 'name: x
description: y
outputs:
  z:
    description: d
    value: >-
      ${{ steps.s.outputs.z }}
runs:
  using: composite
  steps:
    - id: s
      shell: bash
      run: echo hi'

# Expression functions are legal and their names are not contexts.
assert_exit 0 "fromJSON() in an outputs value is accepted" rc 'name: x
description: y
outputs:
  z:
    description: d
    value: ${{ fromJSON(steps.s.outputs.json).name }}
runs:
  using: composite
  steps:
    - id: s
      shell: bash
      run: echo hi'
assert_exit 0 "format() with a dotted literal is accepted" rc 'name: x
description: y
outputs:
  z:
    description: d
    value: ${{ format('"'"'a.b-{0}'"'"', steps.s.outputs.z) }}
runs:
  using: composite
  steps:
    - id: s
      shell: bash
      run: echo hi'

# Indentation is a style choice, not structure.
assert_exit 0 "a four-space-indented action is accepted" rc 'name: x
description: y
outputs:
    z:
        description: d
        value: ${{ steps.s.outputs.z }}
runs:
    using: composite
    steps:
        - id: s
          shell: bash
          run: echo hi'

describe "contexts a composite action cannot resolve"
for ctx in vars secrets needs; do
  assert_exit 1 "'${ctx}' in an outputs value is rejected" rc "name: x
description: y
outputs:
  z:
    description: d
    value: \${{ ${ctx}.ANYTHING }}
runs:
  using: composite
  steps:
    - shell: bash
      run: echo hi"
done
assert_output_contains "cannot resolve" "the refusal explains why" check 'name: x
description: y
outputs:
  z:
    description: d
    value: ${{ vars.NOPE }}
runs:
  using: composite
  steps:
    - shell: bash
      run: echo hi'

describe "expressions inside runs: are untouched"
assert_exit 0 "steps may use any context they like" rc 'name: x
description: y
runs:
  using: composite
  steps:
    - shell: bash
      env:
        A: ${{ inputs.a }}
        B: ${{ github.ref }}
      run: echo "$A $B"'

describe "malformed input fails loudly rather than passing"
assert_exit 1 "unparseable YAML is an error" rc 'name: x
description: "unterminated
runs: []'

finish
