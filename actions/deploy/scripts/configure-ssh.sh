#!/usr/bin/env bash
#
# Write the deploy key and the host's known_hosts entry, so the rsync steps can
# connect.
#
# The key goes to ~/.ssh/deploy_key with mode 600, and is checked to be a
# valid unencrypted OpenSSH private key before anything uses it. The last step
# of the action deletes it again, even when an earlier step failed.
#
# The host key is pinned when DEPLOY_HOST_KEY was supplied. Otherwise this
# falls back to ssh-keyscan - trust on first use, which cannot detect a
# substituted host - and says so with a warning.
#
# Run by the "Configure SSH" step of actions/deploy/action.yml.
#
# Inputs, as environment variables:
#   SSH_KEY             The action's `ssh-key` input: the private key.
#   SSH_HOST            The `host` input. Used only for ssh-keyscan.
#   SSH_PORT            The `port` input. Empty means 22.
#   HOST_KEY            The `host-key` input: known_hosts line(s) to pin, or
#                       empty to fall back to ssh-keyscan.
#
# Outputs, to $GITHUB_OUTPUT:
#   host-key-pinned     'true' when HOST_KEY was used, 'false' for ssh-keyscan.
#
# Writes ~/.ssh/deploy_key and appends to ~/.ssh/known_hosts.
#
# Exits 1 with an ::error:: annotation when the key is not a valid OpenSSH
# private key - usually a PuTTY .ppk pasted into the secret.

# The options GitHub gives an inline bash step, which this was written against.
set -eo pipefail

mkdir -p ~/.ssh
# Write via printf (not echo/interpolation) so the multi-line PEM key
# is preserved exactly and ends with a single trailing newline.
printf '%s\n' "$SSH_KEY" > ~/.ssh/deploy_key
chmod 600 ~/.ssh/deploy_key

# Fail early with a clear message if the key is not a valid private
# key. The usual cause is a PuTTY .ppk pasted straight into the secret.
if ! ssh-keygen -y -f ~/.ssh/deploy_key >/dev/null 2>&1; then
  echo "::error::DEPLOY_SSH_KEY is not a valid unencrypted OpenSSH private key. Check the secret's format."
  exit 1
fi

if [ -n "$HOST_KEY" ]; then
  # Pinned host key: we know what we expect to be talking to.
  printf '%s\n' "$HOST_KEY" >> ~/.ssh/known_hosts
  echo "Using pinned DEPLOY_HOST_KEY."
  echo "host-key-pinned=true" >> "$GITHUB_OUTPUT"
else
  # Trust on first use. This accepts whatever the server presents, on
  # every run, so it cannot detect a substituted host. Set
  # DEPLOY_HOST_KEY to close that gap.
  #
  # No -H. Hashing hides which hosts a known_hosts file refers to,
  # which is worth something on a shared machine and nothing on a
  # runner that discards the file minutes later - while costing the
  # ability to read the entry when a host-key failure needs debugging.
  # The docs tell consumers not to hash a pinned value; hashing here
  # would contradict that for no gain.
  echo "::warning::DEPLOY_HOST_KEY is not set - falling back to ssh-keyscan (trust on first use)."
  ssh-keyscan -p "${SSH_PORT:-22}" "$SSH_HOST" >> ~/.ssh/known_hosts 2>/dev/null
  echo "host-key-pinned=false" >> "$GITHUB_OUTPUT"
fi
