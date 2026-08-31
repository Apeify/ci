#!/usr/bin/env bash
#
# Dev container provisioning. Runs once, as postCreateCommand, from the
# workspace root.
#
# Installs exactly what is needed to run this repo's checks locally:
#   - shellcheck: actionlint invokes it on `run:` blocks when present, so
#     without it actionlint silently does less than CI does
#   - actionlint: the same pinned, checksum-verified release CI uses
#   - js-yaml: for the extractor step in validate.yml
#
# Note the leading "- " on those bullets is load-bearing. shellcheck treats a
# comment whose first word is "shellcheck" as a DIRECTIVE (# shellcheck disable=SC1234),
# so a prose line starting with that word is parsed as a malformed directive and fails
# with SC1072/SC1073.
#
# The actionlint version and hashes come from ../.actionlint-version, the same
# file the workflow reads, so the container and CI cannot drift apart.

set -euo pipefail

echo "==> Installing shellcheck"
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends shellcheck

echo "==> Installing actionlint"

# shellcheck source=../.actionlint-version
. ./.actionlint-version

# CI is always linux/amd64; a dev container on Apple Silicon is linux/arm64.
# Pick the matching archive AND its matching hash together - mixing them would
# fail the checksum, which is the correct outcome but a confusing one to debug.
case "$(uname -m)" in
  x86_64 | amd64)
    arch=amd64
    expected_sha="${ACTIONLINT_SHA256_LINUX_AMD64}"
    ;;
  aarch64 | arm64)
    arch=arm64
    expected_sha="${ACTIONLINT_SHA256_LINUX_ARM64}"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    echo "Add its checksum to .actionlint-version and extend this case block." >&2
    exit 1
    ;;
esac

archive="actionlint_${ACTIONLINT_VERSION}_linux_${arch}.tar.gz"
url="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${archive}"

curl -sSfL --retry 3 --max-time 120 -o "/tmp/${archive}" "$url"

# Verify BEFORE extracting or running. The point of a checksum is to be checked
# while the artifact is still inert.
echo "${expected_sha}  /tmp/${archive}" | sha256sum --check --strict -

sudo tar -xzf "/tmp/${archive}" -C /usr/local/bin actionlint
sudo chmod +x /usr/local/bin/actionlint
rm -f "/tmp/${archive}"

echo "==> Installing js-yaml (for the workflow extractor)"
npm install --no-save --silent js-yaml@4.1.0

echo
echo "==> Ready. Versions:"
actionlint --version
shellcheck --version | sed -n '2p'
node --version
echo
echo "Run the checks the way CI does:"
echo "    bash scripts/lint-workflows.sh"
