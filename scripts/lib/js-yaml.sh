# shellcheck shell=bash
#
# Finding Node and js-yaml for the checks that parse YAML: layer 1
# (check-workflow-structure.sh) and the action-metadata check. Sourced, never
# run.
#
# js-yaml is resolved rather than assumed: CI installs it in an earlier step,
# the dev container has it, and a bare clone gets a clear instruction instead
# of a stack trace. Both checks find it the same way because they share this.
#
# Functions:
#
#   require_node
#       Returns 1, after an ::error::, if node is not on PATH.
#
#   resolve_js_yaml
#       Prints the absolute path of an installed js-yaml - ./node_modules
#       first, then the global npm root - and returns 0. Returns 1, after an
#       ::error:: giving the install command, if there is none. Run it from
#       the repository root.

require_node() {
  if ! command -v node >/dev/null 2>&1; then
    echo "::error::node is required. It is on every GitHub runner and in the dev container."
    return 1
  fi
}

resolve_js_yaml() {
  local candidate
  for candidate in node_modules/js-yaml "$(npm root -g 2>/dev/null)/js-yaml"; do
    [ -n "$candidate" ] || continue
    if [ -d "$candidate" ]; then
      (cd "$candidate" && pwd)
      return 0
    fi
  done
  echo "::error::js-yaml not found. Run: npm install --no-save js-yaml@4.1.0" >&2
  return 1
}
