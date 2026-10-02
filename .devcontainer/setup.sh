#!/usr/bin/env bash
#
# Dev container provisioning. Runs once, as postCreateCommand, from the
# workspace root.
#
# Installs exactly what is needed to run this repo's checks locally:
#   - shellcheck: actionlint invokes it on `run:` blocks when present, so
#     without it actionlint silently does less than CI does
#   - actionlint: the same pinned, checksum-verified release CI uses, through
#     the same scripts/install-actionlint.sh
#   - js-yaml: for scripts/check-workflow-structure.sh and
#     scripts/check-action-metadata.sh
#
# Note the leading "- " on those bullets is load-bearing. shellcheck treats a
# comment whose first word is "shellcheck" as a DIRECTIVE (# shellcheck disable=SC1234),
# so a prose line starting with that word is parsed as a malformed directive and fails
# with SC1072/SC1073.
#
# The actionlint version and hashes come from ../.actionlint-version, read by
# the install script CI also runs, so the container and CI cannot drift apart.

set -euo pipefail

echo "==> Installing shellcheck"
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends shellcheck

echo "==> Installing actionlint"

# The same download and checksum check CI runs. That script never uses sudo, so
# it installs into a scratch directory and the binary is copied into place here.
actionlint_tmp=$(mktemp -d)
bash scripts/install-actionlint.sh "$actionlint_tmp"
sudo install -m 0755 "$actionlint_tmp/actionlint" /usr/local/bin/actionlint
rm -rf "$actionlint_tmp"

echo "==> Installing js-yaml (for the YAML structure and metadata checks)"
npm install --no-save --silent js-yaml@4.1.0

echo
echo "==> Ready. Versions:"
actionlint --version
shellcheck --version | sed -n '2p'
node --version
echo
echo "Run the checks the way CI does:"
echo "    bash scripts/lint-workflows.sh"
