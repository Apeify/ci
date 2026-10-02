#!/usr/bin/env bash
#
# rsync the private app directory to <BASE_DIR>/<app remote dir>/, beside the
# web roots and never inside one, with --delete, and count what moved.
#
# Synced once, however many web roots there are: every root shares it.
#
# DANGER: the destination MUST have a NON-EMPTY directory name. If it were ever
# empty the destination would collapse to <BASE_DIR>/, and --delete would prune
# everything beside it - starting with every live web root.
#
# That guard MOVED rather than disappeared, and the history matters. This used
# to pass the directory with no trailing slash, transferring the directory
# itself into BASE_DIR. That made targeting BASE_DIR structurally impossible,
# but it forced the server-side name to equal the repository's. Supporting a
# different name on the server means naming the destination explicitly, which
# trades the structural guarantee for a validated one: the preflight runs
# app-remote-dir through check_relative_dir, and this script refuses an empty
# or dot-only name again before rsync. Do not interpolate an unvalidated value
# into this destination, and do not remove either check.
#
# .git and .github are always excluded, as in the public sync.
#
# Run by the "Rsync app directory above the web roots" step of
# actions/deploy/action.yml, in the root of the caller's checkout, only when
# deploy-app-dir is 'true'.
#
# Inputs, as environment variables:
#   SSH_HOST            The action's `host` input.
#   SSH_USER            The `user` input.
#   SSH_PORT            The `port` input. Empty means 22.
#   BASE_DIR            The `base-dir` input: absolute server directory that
#                       contains the web roots and this directory.
#   APP_DIR             The `app-dir` input: repo directory whose contents
#                       are synced.
#   APP_REMOTE_DIR      The `app-remote-dir` input: its name on the server.
#                       Empty means the same as APP_DIR.
#   EXCLUDES            The `app-excludes` input: rsync exclude patterns, one
#                       per line - the only protection for server-managed
#                       state under this directory.
#
# Outputs, to $GITHUB_OUTPUT (via emit_transfer_stats in lib.sh):
#   files-transferred, bytes-transferred, paths-deleted
#   changed             'true' when anything transferred or was deleted.
#
# Exits non-zero if rsync fails, or if the destination name resolves to
# BASE_DIR itself.

# The options GitHub gives an inline bash step, which this was written against.
set -eo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Never-ship, same as the public sync and for the same reason: there is
# no deploy target on which a .git or .github directory belongs. In the
# public sync the argument is disclosure, since .git in a web root is
# actively scanned for. Here it is simpler than that - a repository's
# history is not part of the application, and syncing it would also
# re-transfer constantly churning git objects on every deploy.
#
# Only reachable at all when a submodule or vendored checkout sits
# under app-dir, since .git normally lives at the repository root. It
# costs nothing in the common case, exactly as in the public sync.
exclude_args=( "--exclude=.git" "--exclude=.github" )

while IFS= read -r pattern; do
  pattern=$(printf '%s' "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$pattern" ] && continue
  exclude_args+=( "--exclude=${pattern}" )
done <<< "$EXCLUDES"

# Same reasoning as the public step: show what is actually applied.
echo "excludes in effect:"
printf '  %s\n' "${exclude_args[@]#--exclude=}"

# Logged here as well as to the step log, so emit_transfer_stats (lib.sh)
# can count what moved.
sync_log=$(mktemp)

base=$(norm_path "$BASE_DIR")
src=$(norm_path "$APP_DIR")

# Same fallback the preflight validated: the server name defaults to
# the repository name.
remote=$(norm_path "${APP_REMOTE_DIR:-$APP_DIR}")

# Belt and braces, and deliberately the SAME test check_relative_dir
# applies rather than a narrower one. An earlier version tested only
# for empty, but norm_path returns a non-empty '.' for '.', './' and
# './.', and that resolves to the PARENT of the destination - the
# account home - exactly as an empty value would. A backstop narrower
# than the hazard it names is not a backstop. The preflight refuses
# both already, so reaching here means something upstream broke, and
# the cost of being wrong is the whole account.
if [ -z "$remote" ] || [ -z "$(printf '%s' "$remote" | tr -d './')" ]; then
  echo "::error::app remote directory resolved to '${remote}' - refusing to rsync into ${base}/ itself."
  exit 1
fi

echo "rsync ${src}/ -> ${remote}/"
rsync -az --delete --itemize-changes --stats \
  "${exclude_args[@]}" \
  -e "ssh -i ~/.ssh/deploy_key -p ${SSH_PORT:-22}" \
  "${src}/" \
  "${SSH_USER}@${SSH_HOST}:${base}/${remote}/" 2>&1 | tee -a "$sync_log"

emit_transfer_stats "$sync_log"
