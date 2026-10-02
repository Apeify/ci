#!/usr/bin/env bash
# Structural tests for how actions/deploy/action.yml and its scripts/ fit
# together.
#
# The behavior tests run the scripts directly, so they cannot see the one thing
# that only happens on a real runner: action.yml finding the script. A step
# naming a file that does not exist, or a script nothing runs any more, passes
# every behavior test and fails - or silently does nothing - on a consumer's
# deploy. Nothing local can execute the wiring, so this checks its shape.
#
# It also holds the line on the conventions the refactor into scripts depends
# on: one copy of each shared helper, the shell options every script was
# written against, and no GitHub expressions where none can be evaluated.

# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# One record per step: name, shell, run line, env keys, and anything the parser
# could not account for. Parsed with awk for the same reason as the extractor in
# harness.sh - nothing installed. The action's steps sit at four spaces; their
# keys at six; env entries at eight.
#
# A step key or env line this parser does not recognize is reported rather than
# skipped: a parser that quietly ignores what it cannot read is a check that
# quietly passes. That includes a step that does not start with `- name:` -
# its first key sits on the dash line, out of reach of everything below.
#
# Fields are separated by \037 (unit separator), NOT a tab. A tab is IFS
# whitespace, so `read` collapses consecutive tabs: on a step with no shell,
# run or env (the download step) the last field shifted left into `shell`,
# and an unknown key there passed unreported.
STEPS=$(awk '
  function flush() {
    if (name != "") printf "%s\037%s\037%s\037%s\037%s\n", name, shell, run, envs, odd
    name = ""; shell = ""; run = ""; envs = ""; odd = ""; inenv = 0
  }
  /^    - name: /        { flush(); name = substr($0, 13); next }
  /^    - /              { flush(); name = "(unnamed, line " NR ")"; odd = " [step does not start with - name:]"; next }
  name == ""             { next }
  /^[[:space:]]*(#|$)/   { next }
  /^      shell: /       { shell = substr($0, 14); inenv = 0; next }
  /^      run: /         { run = substr($0, 12); inenv = 0; next }
  /^      env:$/         { inenv = 1; next }
  inenv && /^        [A-Z_][A-Z0-9_]*: / {
    key = $1; sub(/:$/, "", key); envs = envs " " key; next
  }
  inenv && /^        /   { odd = odd " [env line: " $0 "]"; next }
  # working-directory would run the script from somewhere the checks never saw.
  /^      working-directory:/ { odd = odd " [working-directory]"; next }
  /^      (id|if|uses|with):/ { inenv = 0; next }
  /^        /            { next }
  /^      [a-z]/         { inenv = 0; odd = odd " [unknown key: " $0 "]"; next }
  END { flush() }
' "$DEPLOY_ACTION")

if [ -z "$STEPS" ]; then
  echo "HARNESS ERROR: no steps parsed from ${DEPLOY_ACTION}. Fix the parser." >&2
  exit 2
fi

# A literal $GITHUB_ACTION_PATH: this matches the text of action.yml.
# shellcheck disable=SC2016
SCRIPT_RUN='^bash "\$GITHUB_ACTION_PATH/scripts/([a-z0-9-]+\.sh)"$'

# The code of a script, comments removed, for the word matching below.
code_of() { grep -v -E '^[[:space:]]*#' "$1" || true; }

describe "every step runs a script, or is a single command"
if grep -q -E '^ +run: [|>]' "$DEPLOY_ACTION"; then
  _fail "no step has a multi-line run: block" \
    "move it into actions/deploy/scripts/ - inline shell gets no shellcheck" \
    "$(grep -n -E '^ +run: [|>]' "$DEPLOY_ACTION")"
else _pass; fi

# The env-only rule covers the YAML too, not just the scripts. A one-line
# `run:` that interpolates an input splices it into shell source in the job
# that holds the deploy key - the exact pattern this action moved away from.
# shellcheck disable=SC2016 # a literal ${{, searched for
if grep -n -E '^ +run: .*\$\{\{' "$DEPLOY_ACTION"; then
  _fail "no run: line in action.yml contains \${{" "pass the value through env: instead"
else _pass; fi

referenced=()
while IFS=$'\037' read -r name shell run envs odd; do
  if [ -n "$odd" ]; then
    _fail "step '${name}' contains only what this test can check" "found:${odd}"
  else _pass; fi

  [ -n "$run" ] || continue
  if [ "$shell" != "bash" ]; then
    _fail "step '${name}' declares shell: bash" "got: '${shell}'"
  else _pass; fi

  if [[ "$run" =~ $SCRIPT_RUN ]]; then
    script="${BASH_REMATCH[1]}"
    referenced+=("$script")
    if [ -f "${DEPLOY_SCRIPTS}/${script}" ]; then _pass; else
      _fail "step '${name}' runs a script that exists" "missing: scripts/${script}"
      continue
    fi
    code=$(code_of "${DEPLOY_SCRIPTS}/${script}")

    # Every value the step hands over must still be used. A variable renamed
    # on one side only reaches the script as an empty string, which several
    # of these scripts treat as "not configured" rather than as an error.
    # Matched as a word in code, not as `$NAME`: the preflight reads its
    # secrets indirectly, through `${!name}` over a list of names.
    #
    # Here-strings, not `grep -q` at the end of a pipe: under pipefail, -q
    # exiting at its first match kills the writer with SIGPIPE and turns a
    # match into a failure - which made this test fail at random on a clean
    # tree.
    for key in $envs; do
      if grep -w -- "$key" <<< "$code" >/dev/null; then _pass; else
        _fail "scripts/${script} uses ${key}, which step '${name}' passes"
      fi
    done

    # And the other direction, which is the dangerous one: a variable the
    # script reads that the step no longer passes arrives EMPTY. For the rsync
    # steps that retargets --delete - an empty BASE_DIR makes the destination
    # an absolute path at the server root. The only variables a script may
    # read without the step passing them are the runner's own GITHUB_* and
    # bash's BASH_SOURCE.
    mapfile -t reads < <(grep -o -E '\$\{?[A-Z_][A-Z0-9_]*' <<< "$code" | sed -E 's/^\$\{?//' | sort -u)
    for var in "${reads[@]}"; do
      case "$var" in GITHUB_*|BASH_SOURCE) continue ;; esac
      case " ${envs} " in
        *" ${var} "*) _pass ;;
        *) _fail "step '${name}' passes ${var}, which scripts/${script} reads" ;;
      esac
    done

    # The header's Inputs list is the script's documentation of what it
    # reads, so it must name exactly what the step passes - a list that
    # drifted would document a variable that no longer arrives. A script with
    # no inputs says "Inputs: none".
    documented=$(awk '
      !/^#/ && !/^$/      { exit }
      /^# Inputs: none/   { exit }
      /^# Inputs/         { inlist = 1; next }
      inlist && /^#$/     { exit }
      inlist && /^#   [A-Z_][A-Z0-9_]* / { print $2 }
    ' "${DEPLOY_SCRIPTS}/${script}" | sort | tr '\n' ' ')
    expected=$(tr ' ' '\n' <<< "$envs" | sed '/^$/d' | sort | tr '\n' ' ')
    if ! grep -q -E '^# Inputs' "${DEPLOY_SCRIPTS}/${script}"; then
      _fail "scripts/${script} documents its inputs in its header" "add an '# Inputs' section"
    else
      assert_eq "$expected" "$documented" "scripts/${script} header lists exactly the inputs step '${name}' passes"
    fi
  elif [[ "$run" == bash* ]] || [[ "$run" == *GITHUB_ACTION_PATH* ]]; then
    # Looks like a script call but is spelled differently - quoting dropped,
    # path changed. Refuse rather than let it slip past the checks above.
    _fail "step '${name}' calls its script in the standard form" \
      "expected: bash \"\$GITHUB_ACTION_PATH/scripts/<name>.sh\"" "got:      ${run}"
  fi
done <<< "$STEPS"

describe "every script is run by exactly one step"
for f in "${DEPLOY_SCRIPTS}"/*.sh; do
  base=$(basename "$f")
  [ "$base" = "lib.sh" ] && continue
  n=0
  for r in "${referenced[@]}"; do [ "$r" = "$base" ] && n=$((n + 1)); done
  assert_eq "1" "$n" "scripts/${base} is run by exactly one step"
done

describe "every script parses"
# The only check of this that needs nothing installed. shellcheck parses them
# too, but only in CI and the dev container.
for f in "${DEPLOY_SCRIPTS}"/*.sh; do
  assert_exit 0 "scripts/$(basename "$f") parses" bash -n "$f"
done

describe "every step script sets the options it was written against"
# GitHub runs an inline bash step as `bash -eo pipefail`; a script run as
# `bash <file>` gets neither unless it asks. Without -e, a failing guard
# command no longer stops the step.
for f in "${DEPLOY_SCRIPTS}"/*.sh; do
  base=$(basename "$f")
  [ "$base" = "lib.sh" ] && continue
  first=$(awk '!/^[[:space:]]*(#|$)/ { print; exit }' "$f")
  assert_eq "set -eo pipefail" "$first" "scripts/${base}: first command is set -eo pipefail"
done

describe "lib.sh changes no shell options for the scripts that source it"
if grep -q -E '^set ' "${DEPLOY_SCRIPTS}/lib.sh"; then
  _fail "lib.sh has no top-level set" "$(grep -n -E '^set ' "${DEPLOY_SCRIPTS}/lib.sh")"
else _pass; fi

describe "each shared helper is defined once, in lib.sh, and sourced where used"
# These were copied into every step that used them while steps were inline, and
# tests had to assert the copies matched. A copy reintroduced in a step script
# would shadow lib.sh's version for that step only - in any of bash's spellings
# of a definition.
mapfile -t helpers < <(sed -n -E 's/^([a-z_][a-z0-9_]*)\(\) \{$/\1/p' "${DEPLOY_SCRIPTS}/lib.sh")
assert_exit 0 "lib.sh defines helpers (parser sanity)" test "${#helpers[@]}" -ge 4
for fn in "${helpers[@]}"; do
  def="^[[:space:]]*(function[[:space:]]+${fn}([^a-z0-9_]|$)|${fn}[[:space:]]*\(\))"
  others=$(grep -l -E "$def" "${DEPLOY_SCRIPTS}"/*.sh | grep -v '/lib\.sh$' || true)
  if [ -z "$others" ]; then _pass; else
    _fail "${fn} is defined only in lib.sh" "also defined in: ${others}"
  fi
done
# A script calling a helper without sourcing lib.sh fails only on a runner,
# with "command not found" - shellcheck does not flag an undefined function.
# shellcheck disable=SC2016 # the literal source line, searched for
SOURCE_LINE='source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"'
for f in "${DEPLOY_SCRIPTS}"/*.sh; do
  base=$(basename "$f")
  [ "$base" = "lib.sh" ] && continue
  code=$(code_of "$f")
  uses=""
  for fn in "${helpers[@]}"; do
    if grep -w -- "$fn" <<< "$code" >/dev/null; then uses="${uses} ${fn}"; fi
  done
  [ -n "$uses" ] || continue
  if grep -F -x -- "$SOURCE_LINE" <<< "$code" >/dev/null; then _pass; else
    _fail "scripts/${base} sources lib.sh, since it calls:${uses}"
  fi
done

describe "no GitHub expressions inside scripts"
# Nothing evaluates `${{ }}` in a file; bash would read it as a bad
# substitution. Values reach a script through the step's env: block.
# shellcheck disable=SC2016 # a literal ${{, searched for
if grep -n '\${{' "${DEPLOY_SCRIPTS}"/*.sh; then
  _fail "no script contains \${{"
else _pass; fi

finish
