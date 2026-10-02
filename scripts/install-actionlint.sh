#!/usr/bin/env bash
#
# Download the pinned actionlint release, verify it against the checksum this
# repo commits, and install the binary into a directory.
#
# CI (validate.yml) and the dev container (.devcontainer/setup.sh) both install
# actionlint through this file, so the download and - more to the point - the
# checksum verification exist once. The version and hashes come from
# .actionlint-version, which explains why the checksum, not the version tag, is
# the real pin.
#
# The archive is verified BEFORE it is extracted or run. The point of a
# checksum is to be checked while the artifact is still inert.
#
# Run from anywhere: `bash scripts/install-actionlint.sh <dir>`.
#
# Arguments:
#   dir     Existing directory to put the `actionlint` binary in. It must be
#           writable by the caller: this script never uses sudo, so a caller
#           installing somewhere system-wide installs into a scratch directory
#           and copies the binary with the privileges it already has.
#
# Picks the linux/amd64 or linux/arm64 build, with the matching checksum, from
# `uname -m`. CI is always amd64; a dev container on Apple Silicon is arm64.
#
# Outputs: none. Writes <dir>/actionlint and prints its version.
#
# Exits non-zero if the architecture is unsupported, the download fails, or the
# checksum does not match - in which case nothing is extracted.

set -euo pipefail

if [ $# -ne 1 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <existing directory to install actionlint into>" >&2
  exit 2
fi
# Absolute, BEFORE the cd below - a relative <dir> means the caller's
# directory, not the repository root this script moves to.
dest=$(cd "$1" && pwd)

cd "$(dirname "$0")/.."

# shellcheck source=../.actionlint-version
. ./.actionlint-version

# Pick the archive AND its hash together - mixing them would fail the
# checksum, which is the correct outcome but a confusing one to debug.
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
    echo "::error::Unsupported architecture: $(uname -m)" >&2
    echo "Add its checksum to .actionlint-version and extend this case block." >&2
    exit 1
    ;;
esac

archive="actionlint_${ACTIONLINT_VERSION}_linux_${arch}.tar.gz"
url="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${archive}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -sSfL --retry 3 --max-time 120 -o "${work}/${archive}" "$url"
echo "${expected_sha}  ${work}/${archive}" | sha256sum --check --strict -

tar -xzf "${work}/${archive}" -C "$dest" actionlint
chmod +x "${dest}/actionlint"
"${dest}/actionlint" --version
