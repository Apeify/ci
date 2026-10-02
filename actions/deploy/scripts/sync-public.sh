#!/usr/bin/env bash
#
# rsync the CONTENTS of the public directory into every web root, with
# --delete, and count what moved.
#
# Every web root gets the identical tree. They are not ranked: the site tells
# them apart at runtime by HTTP_HOST, not by which copy it loaded.
#
# .git and .github are always excluded, whatever the caller passes. EXCLUDES is
# added on top - and it REPLACES the action's default list rather than
# extending it, which is why the excludes in effect are printed first.
#
# Each destination is <BASE_DIR>/<web root>/, built from the same normalized
# spelling the preflight validated. An empty web root entry - an ordinary
# trailing newline in WEB_ROOT_DIRS - is skipped here, and that skip is what
# stops the destination collapsing to <BASE_DIR>/ and --delete pruning the
# whole account. See the comment on it below before touching it.
#
# --itemize-changes logs one line per file touched (and why), and --stats
# summarizes the bytes moved: together they show in the log that the mtime
# restore kept the sync incremental, and they are what the outputs count.
#
# Run by the "Rsync public/ contents into each web root" step of
# actions/deploy/action.yml, in the root of the caller's checkout, after
# preflight.sh validated every value below and configure-ssh.sh wrote the key.
#
# Inputs, as environment variables:
#   SSH_HOST            The action's `host` input.
#   SSH_USER            The `user` input.
#   SSH_PORT            The `port` input. Empty means 22.
#   BASE_DIR            The `base-dir` input: absolute server directory that
#                       contains the web roots.
#   WEB_ROOT_DIRS       The `web-root-dirs` input: web root names, one per
#                       line, relative to BASE_DIR.
#   PUBLIC_DIR          The `public-dir` input: repo directory whose contents
#                       are synced.
#   EXCLUDES            The `public-excludes` input: rsync exclude patterns,
#                       one per line.
#
# Outputs, to $GITHUB_OUTPUT (via emit_transfer_stats in lib.sh), summed over
# every web root:
#   files-transferred, bytes-transferred, paths-deleted
#   changed             'true' when anything transferred or was deleted.
#
# Exits non-zero if any rsync fails, or if a web root resolves to BASE_DIR
# itself.

# The options GitHub gives an inline bash step, which this was written against.
set -eo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Two categories of exclude, deliberately separate.
#
# These are the NEVER-SHIP ones, and the caller cannot remove them.
# .git in a web root exposes the full history - including any secret
# ever committed and later deleted - and is actively scanned for.
# .github exposes the pipeline. Neither has any business on a web
# server, so neither depends on the caller getting public-excludes
# right. It costs nothing when public-dir is a subdirectory, because
# there is no .git inside it to match.
#
# rsync patterns without a leading slash match a basename at ANY
# depth, so these also catch a nested .git from a submodule or a
# vendored checkout.
exclude_args=( "--exclude=.git" "--exclude=.github" )

# And these are the CONVENTIONAL ones the caller may override.
#
# Every list this workflow accepts is newline-separated, including the
# exclude inputs. Splitting on newlines rather than whitespace means a
# pattern containing a space still works, and it keeps one parsing
# idiom across WEB_ROOT_DIRS and both exclude lists.
while IFS= read -r pattern; do
  pattern=$(printf '%s' "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$pattern" ] && continue
  exclude_args+=( "--exclude=${pattern}" )
done <<< "$EXCLUDES"

# Print what actually applies. Supplying public-excludes REPLACES the
# default list rather than extending it, and without this line that
# substitution stays invisible until something you assumed was
# excluded turns up on the server.
echo "excludes in effect:"
printf '  %s\n' "${exclude_args[@]#--exclude=}"

# Every rsync below is logged here as well as to the step log, so
# emit_transfer_stats (lib.sh) can sum what moved across every web root.
sync_log=$(mktemp)

# Building the destination from the SAME spelling the preflight
# checked matters beyond cosmetics: "/home/u//site.com//" in a log
# looks like a bug and invites someone to "fix" it, and a path shown
# here that differs from the one the nesting checks approved is
# exactly how a reader talks themselves out of trusting either.
base=$(norm_path "$BASE_DIR")
src=$(norm_path "$PUBLIC_DIR")

while IFS= read -r raw; do
  dir=$(norm_path "$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')")

  # LOAD-BEARING. Do not delete this as redundant with the preflight.
  #
  # A trailing newline in the WEB_ROOT_DIRS variable is ordinary input
  # and yields an empty entry on EVERY run. Without this line the
  # destination below collapses to "<base>//" - the account home - and
  # --delete prunes every web root, app/, and anything else kept there.
  #
  # The preflight has an identical-looking line, and it is load-bearing
  # too - for a different reason. There it guards check_relative_dir,
  # which REJECTS an empty value, so deleting it turns that ordinary
  # trailing newline into a hard preflight failure on every deploy in
  # every consuming repo. Neither copy is redundant with the other:
  # remove the preflight's and no deploy runs at all, remove this one
  # and a deploy runs against the account home.
  [ -z "$dir" ] && continue

  # Belt and braces, matching check_relative_dir's dot-only rejection
  # rather than only its empty one: '.', './', './/' normalize to a
  # non-empty '.', which resolves to the PARENT of the destination -
  # the same catastrophe by a different route. The preflight already
  # refuses these, so reaching here means something upstream broke.
  if [ -z "$(printf '%s' "$dir" | tr -d './')" ]; then
    echo "::error::web root '${raw}' resolves to its parent directory - refusing to rsync into ${base}/ itself."
    exit 1
  fi

  echo "::group::rsync ${src}/ -> ${dir}"
  # tee, not a redirect: the transfer stays visible in the log AND
  # becomes countable. Under `pipefail` an rsync failure still fails the
  # step, which a command substitution would have swallowed.
  rsync -az --delete --itemize-changes --stats \
    "${exclude_args[@]}" \
    -e "ssh -i ~/.ssh/deploy_key -p ${SSH_PORT:-22}" \
    "${src}/" \
    "${SSH_USER}@${SSH_HOST}:${base}/${dir}/" 2>&1 | tee -a "$sync_log"
  echo "::endgroup::"
done <<< "$WEB_ROOT_DIRS"

emit_transfer_stats "$sync_log"
