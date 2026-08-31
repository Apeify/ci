# ci

Shared GitHub Actions workflows for deploying small PHP sites to SSH-accessible
hosting. One pipeline, written once, consumed by every site repo.

## Birds-Eye View

This CI system is designed around the idea that the consumer wants to be able to easily and
automatically deploy changes to their staging and production environments.  There are a few
central tenets for using this CI system:

The consuming project ...
* ... uses `main` as their production branch.
* ... uses `staging` as their staging branch.
* ... can use as many other branches as desired, but nothing ever gets merged or pushed directly
  into `main` -- it must always first go to `staging` and then get merged into `main` from there.
* ... wants all changes that land in `staging` to immediately be deployed to their staging
  environment.
* ... wants a simple "button" for putting all `staging` contents into `main` and immediately
  releasing to production, as opposed to a Pull Request (PR) process (a PR process can still be
  used for landing changes into `staging` if desired).

## Available Workflows

| Workflow | What it does |
|---|---|
| [`deploy.yml`](.github/workflows/deploy.yml) | Lints, tests, minifies assets, and rsyncs the site to one or more web roots over SSH |
| [`promote.yml`](.github/workflows/promote.yml) | The publish button: fast-forwards `main` to `staging`, then starts the production deploy |

Neither has a trigger of its own. `workflow_call` is their only entry point, so
pushing to this repository never runs them and no "Run workflow" button appears
here. Every real trigger lives in the consuming repo, which is where branch
policy belongs.

A third workflow, [`validate.yml`](.github/workflows/validate.yml), *does* have
triggers - it lints the other two. See
[Validating changes here](MAINTAINING.md#validating-changes-here).

### Where to look

| If you want to | Read |
|---|---|
| Understand the branch/environment model | [The model](#the-model) |
| Wire a site up from scratch | [Consuming these workflows](#consuming-these-workflows), then [Configuration](#configuration) |
| Look up a secret, variable, or input | [Secrets](#secrets) / [Variables](#variables) / [Inputs](#inputs) |
| Deploy to a Disaster Recovery or preview host | [More than two environments](#more-than-two-environments-disaster-recovery-preview) |
| Use a repo layout other than `public/` and `app/` | [Directory names are not assumed](#directory-names-are-not-assumed) |
| Know what lands on the server, and where | [Server layout produced](#server-layout-produced) |
| Pin to a version | [Versioning](#versioning) |
| Keep that pin up to date | [Keeping the pin current with Dependabot](#keeping-the-pin-current-with-dependabot) |
| Work on the pipeline itself | [MAINTAINING.md](MAINTAINING.md) |

## The model

Two long-lived branches per site, each mapped by default to a GitHub Environment
holding that environment's own credentials:

- **`staging`** deploys automatically on every push.
- **`main`** has **no push trigger at all**, so pushing to it deploys nothing.

That asymmetry is the first safety property. `rsync --delete` against a live
account should never happen by accident, and the usual guard - an environment
"required reviewers" rule - needs a paid plan on a private repository. Removing
`main` from the push trigger replaces it: no push can reach production.

It is not exclusivity on its own. The deploy stub has to keep
`workflow_dispatch`, because `promote.yml` reaches it by dispatching it, so
someone with write access can run the deploy manually against `main` and skip
the publish button. So `deploy.yml` enforces the same invariant `promote.yml`
does: **a production deploy is refused unless the commit being deployed is
already contained in `staging`**. After a publish it is the tip of both; if
staging has moved on since, it is merely behind, which still passes. Only a
commit pushed straight to `main` fails it.

The branch mapping is a default, not a limit: a site needing a third target such
as a Disaster Recovery (DR) host sets the `environment` input. See
[More than two environments](#more-than-two-environments-disaster-recovery-preview).

Publishing is a **fast-forward**, never a merge. A pull request merge would put
a commit on `main` that `staging` does not have, and repeated drift eventually
makes fast-forwarding impossible. `promote.yml` refuses to run if `main` holds
any commit `staging` does not, and prints the exact commands to fix it.

## Consuming these workflows

Two small stubs in the site repo, plus an optional third for a Disaster
Recovery target. They hold the triggers and nothing else - everything
environment-specific lives in that environment's secrets and variables, so the
stubs are identical across sites unless a site needs a non-default directory
layout.

There is also a [Dependabot configuration](#keeping-the-pin-current-with-dependabot)
worth copying, which is what keeps the pin in those stubs from going stale. It
is not a workflow and does not live with them.

**The stubs are real files in this repo, ready to copy:
[`examples/workflows/`](examples/workflows/).** That directory mirrors where the
files go: everything in it belongs in your site repo's `.github/workflows/`, so
copy `deploy.yml` and `promote.yml` across keeping the same filenames.
[`examples/dependabot.yml`](examples/dependabot.yml) sits one level up because it
belongs one level up, at `.github/dependabot.yml`. The blocks below are the same
files, reproduced here for reading - a check in
[`validate.yml`](.github/workflows/validate.yml) fails the build if the two ever
disagree, so what you see here is always what is in `examples/`.

### `.github/workflows/deploy.yml`

[`examples/workflows/deploy.yml`](examples/workflows/deploy.yml)

<!-- example:examples/workflows/deploy.yml -->
```yaml
# Thin stub. The pipeline itself lives in Apeify/ci - see
# https://github.com/Apeify/ci#readme for the full contract and the reasoning.
#
# =========================================================================
# WHAT YOU MUST CONFIGURE BEFORE THIS WORKS
# =========================================================================
#
# ENVIRONMENTS (Settings -> Environments). Create two, named exactly:
#
#   production   deployed ONLY by promote.yml, and only from `main`
#   staging      deployed automatically on every push to `staging`
#
# Those names are not arbitrary. The shared workflow maps `main` to
# `production` and every other ref to `staging`. A third target - a Disaster
# Recovery host, a preview account - needs its own environment and the
# `environment:` input; see deploy-dr.yml.
#
# SECRETS, set on EACH environment (they hold different values per account):
#
#   DEPLOY_SSH_KEY   required  Unencrypted OpenSSH private key authorized on
#                              that host. A PuTTY .ppk will NOT work; export
#                              to OpenSSH format first.
#   DEPLOY_HOST      required  SSH hostname.
#   DEPLOY_USER      required  SSH username.
#   DEPLOY_BASE_DIR  required  Absolute path to the directory CONTAINING the
#                              web root(s) - on shared hosting usually the
#                              account home, e.g. /home/username.
#   DEPLOY_PORT      optional  SSH port. Defaults to 22.
#   DEPLOY_HOST_KEY  optional  The host's known_hosts line(s), pasted whole.
#                              Not a fingerprint - SSH needs the key itself.
#                              Prefer a value your host PUBLISHES; failing
#                              that, `ssh-keyscan your-host` (no -H, and keep
#                              every key line it prints, not just the first).
#                              Recommended: with it unset the deploy trusts
#                              whatever key the server presents, on every run.
#                              See the README's Host key pinning section.
#
# VARIABLES, set on EACH environment:
#
#   WEB_ROOT_DIRS    required  Web-root directory NAMES, ONE PER LINE, each
#                              relative to DEPLOY_BASE_DIR. Usually one. List
#                              more only if the app is built to serve several
#                              hostnames from a single ACCOUNT: they sit side
#                              by side under DEPLOY_BASE_DIR, receive the same
#                              commit, and therefore share one app directory
#                              and one set of runtime state.
#   SITE_URL         optional  Public URL of this environment's site. Used
#                              only for the link GitHub shows on the
#                              deployment; unset just means no link.
#
# PERMISSIONS: nothing to do for this stub. The deploy only reads the repo.
# promote.yml is the one that needs write, and it grants that on its own job -
# see that stub.
#
# INPUTS this stub may pass under `with:`. All are optional. Their default
# VALUES are declared in the shared workflow and deliberately not restated
# here - a copy in this file would go stale the day one of them changes. See
# the README, or the input descriptions in the shared deploy.yml itself.
#
#   php-version      PHP version used for lint and tests.
#   public-dir       Repo directory whose CONTENTS are deployed to each web
#                    root. Conventionally `public`.
#   app-dir          Repo directory kept OUT of the web root. Conventionally
#                    `app`.
#   app-remote-dir   Name that directory takes ON THE SERVER. Set it only when
#                    the server expects something other than app-dir.
#   deploy-app-dir   Set false if the site has no private directory at all -
#                    everything lives under the web root. The app-* inputs
#                    above are then ignored entirely.
#   environment      Override which environment is deployed to. Normally
#                    derived from the branch; see deploy-dr.yml.
#   public-excludes  rsync excludes for public-dir, ONE PER LINE. Supplying
#                    this REPLACES the default list rather than adding to it,
#                    so include anything from it you still need. .git and
#                    .github are always excluded regardless.
#   app-excludes     rsync excludes for app-dir, ONE PER LINE. Use for
#                    server-managed state or server-only config that a deploy
#                    must not overwrite.
# =========================================================================
name: Deploy site

on:
  push:
    # staging only. `main` is intentionally absent, so pushing to main deploys
    # nothing - that is what stops a stray commit reaching the live site by
    # accident.
    #
    # It is NOT the whole story, and an earlier version of this comment claimed
    # it was. workflow_dispatch below cannot be removed (promote.yml reaches
    # this workflow by dispatching it), so anyone with write access can run
    # this manually against `main`. The shared workflow closes that path
    # itself: a production deploy is refused unless the commit being
    # deployed is already contained in `staging`, which is the invariant
    # promote.yml enforces before it fast-forwards.
    branches: [staging]
  workflow_dispatch:

concurrency:
  # One in-flight deploy per branch, and NEVER cancel one that is already
  # running - on either branch.
  #
  # rsync defaults to --delete-during, so deletions interleave with the
  # transfer. Killing a deploy partway leaves that web root half-deleted and
  # half-updated. The next successful deploy repairs it, but that repair is
  # conditional: if the run that did the canceling then fails - a bad commit,
  # an SSH hiccup, a guard refusing it - the tree stays torn.
  #
  # Queueing instead means the in-flight deploy finishes and the tree is at
  # least consistent at SOME commit before the next one starts.
  #
  # This applies to staging as much as production. The stakes differ, but the
  # damage does not, and a half-deployed preview is actively misleading: the
  # whole point of staging is judging whether a change is good, and a torn tree
  # shows breakage that is not in the change.
  #
  # The cost is real but small: several rapid pushes deploy in sequence rather
  # than collapsing into one, spending a few extra runner minutes. Cheaper than
  # a preview nobody can trust.
  group: deploy-${{ github.ref }}
  cancel-in-progress: false

jobs:
  deploy:
    uses: Apeify/ci/.github/workflows/deploy.yml@main
    # `inherit` rather than an explicit secrets map, and this is forced rather
    # than lazy: the deploy credentials are ENVIRONMENT secrets, and a job that
    # uses `uses:` cannot declare `environment:`. An explicit map would be
    # evaluated here, in a context that never entered an environment, and would
    # silently pass empty strings.
    secrets: inherit
```

### `.github/workflows/promote.yml`

[`examples/workflows/promote.yml`](examples/workflows/promote.yml)

<!-- example:examples/workflows/promote.yml -->
```yaml
# Thin stub. The pipeline itself lives in Apeify/ci - see
# https://github.com/Apeify/ci#readme for the full contract and the reasoning.
#
# The publish button: Actions tab -> "Publish to production" -> Run workflow.
# It fast-forwards `main` to `staging`, then dispatches deploy.yml against
# `main`. The live site updates when that SECOND run goes green.
#
# =========================================================================
# WHAT YOU MUST CONFIGURE BEFORE THIS WORKS
# =========================================================================
#
# PERMISSIONS: granted on the job below, not repo-wide.
#
#   This workflow pushes `main` and dispatches the deploy, both using the
#   built-in GITHUB_TOKEN. A called workflow can only DOWNGRADE the token it is
#   handed - it cannot elevate - so the grant has to come from the calling job
#   here. That is why `permissions:` sits on `publish` below.
#
#   Granting it here rather than flipping the repository to "Read and write
#   permissions" keeps write scoped to this one job instead of handing it to
#   every workflow in the repo.
#
#   Do NOT add a branch-protection rule requiring pull requests on `main`:
#   publishing fast-forwards `main` from a workflow, and such a rule blocks
#   exactly that push.
#
# SECRETS AND VARIABLES:
#
#   None of its own. It dispatches deploy.yml, which reads the environment
#   secrets and variables listed in that stub's header.
#
# INPUTS - all optional. Default values are declared in the shared workflow
# rather than restated here, so this file cannot go stale when one changes.
#
#   deploy-workflow  Filename of the deploy workflow to dispatch, as it
#                    appears in .github/workflows/. Only needed if the deploy
#                    stub is not called deploy.yml.
#
# WHAT IT REFUSES TO DO
#
#   If `main` holds any commit `staging` does not, it fails without pushing
#   and prints the exact git commands to reconcile them. Do not publish by
#   merging a `staging` -> `main` pull request: the merge commit makes the two
#   branches drift, and enough drift breaks fast-forwarding permanently.
# =========================================================================
name: Publish to production

on:
  workflow_dispatch:

concurrency:
  # One publish at a time, and never cancel one halfway: a canceled run could
  # push main without starting the deploy, leaving main ahead of the live site.
  group: publish-to-production
  cancel-in-progress: false

jobs:
  publish:
    # Granted here because a called workflow cannot elevate the token it
    # receives, only reduce it. Without this the shared workflow's own
    # `permissions:` block asks for more than it was handed, and the run fails.
    permissions:
      contents: write # fast-forward and push `main`
      actions: write # dispatch the deploy workflow
    uses: Apeify/ci/.github/workflows/promote.yml@main
    secrets: inherit
```

The `name:` in the stub is what appears in the consuming repo's Actions sidebar,
so the button keeps whatever label its users already know.

### `.github/workflows/deploy-dr.yml` (optional)

Only for a site with a third target - see
[More than two environments](#more-than-two-environments-disaster-recovery-preview).

[`examples/workflows/deploy-dr.yml`](examples/workflows/deploy-dr.yml)

<!-- example:examples/workflows/deploy-dr.yml -->
```yaml
# Thin stub for a Disaster Recovery (DR) target. The pipeline itself lives in
# Apeify/ci - see https://github.com/Apeify/ci#readme for the full contract.
#
# Optional. Only add this if the site has a third deploy target - a standby
# host, a preview account - that the two-branch mapping cannot express, since
# one ref maps to exactly one environment.
#
# =========================================================================
# WHAT YOU MUST CONFIGURE BEFORE THIS WORKS
# =========================================================================
#
# ENVIRONMENT (Settings -> Environments). Create one named to match the
# `environment:` input below - `dr` as written here.
#
# It needs its OWN copy of everything the production environment has, because
# it is a different host with different credentials:
#
#   Secrets    DEPLOY_SSH_KEY, DEPLOY_HOST, DEPLOY_USER, DEPLOY_BASE_DIR
#              (required), DEPLOY_PORT, DEPLOY_HOST_KEY (optional)
#   Variables  WEB_ROOT_DIRS (required), SITE_URL (optional)
#
# See deploy.yml's header for what each one means.
#
# WHY THIS IS A SEPARATE FILE
#
# The environment is hardcoded below rather than offered as a run-time choice.
# Wiring it to a workflow_dispatch input would turn a reviewed,
# version-controlled decision into a dropdown that includes production.
# =========================================================================
name: Deploy to DR host

on:
  workflow_dispatch:

concurrency:
  group: deploy-dr
  cancel-in-progress: false

jobs:
  deploy:
    # DR mirrors production, so hold it to the same branch rule: deploy only
    # from `main`, which is the branch promote.yml fast-forwards.
    #
    # PART of the rule, not all of it. For `production` the shared workflow
    # applies two checks - the ref must be `main`, AND the commit being deployed
    # must already be contained in `staging`. It cannot apply either to `dr`,
    # because it has no way to know that `dr` is production-like, and only the
    # first is expressible from out here: a caller job may carry `if:` even
    # though it cannot carry `environment:`, but `if:` cannot inspect git
    # history. In practice a DR run started from `main` right after a publish
    # gets the second property anyway, by deploying the commit production
    # already accepted.
    if: github.ref == 'refs/heads/main'
    uses: Apeify/ci/.github/workflows/deploy.yml@main
    with:
      environment: dr
    secrets: inherit
```

## Configuration

Set these under **Settings → Environments** in the **consuming** repo, once for
`production` and once for `staging`. Nothing is stored in this repository, and
no configuration is shared between site repos.

### Secrets

| Secret | Required | Meaning |
|---|---|---|
| `DEPLOY_SSH_KEY` | yes | Unencrypted OpenSSH private key authorized on the host. A PuTTY `.ppk` will not work - export to OpenSSH format first |
| `DEPLOY_HOST` | yes | SSH hostname |
| `DEPLOY_USER` | yes | SSH username |
| `DEPLOY_BASE_DIR` | yes | Absolute path to the directory that **contains** the web root(s). On shared hosting, usually the account home, e.g. `/home/username` |
| `DEPLOY_PORT` | no | SSH port; defaults to `22` |
| `DEPLOY_HOST_KEY` | no | The host's `known_hosts` line(s). Recommended - see [Host key pinning](#host-key-pinning) |

### Variables

| Variable | Required | Meaning |
|---|---|---|
| `WEB_ROOT_DIRS` | yes | One or more web-root directory **names**, one per line, each relative to `DEPLOY_BASE_DIR` |
| `SITE_URL` | no | Public URL of this environment's site. Used only for the link GitHub shows on the deployment |

### Inputs

| Input | Default | Meaning |
|---|---|---|
| `php-version` | `8.3` | PHP version for lint and tests |
| `public-dir` | `public` | Repo directory whose **contents** go into each web root |
| `app-dir` | `app` | Repo directory holding code that must not be web-accessible |
| `app-remote-dir` | *(same as `app-dir`)* | Name that directory takes **on the server** |
| `environment` | *(derived from the ref)* | GitHub Environment to deploy to. Set it to reach a third target such as Disaster Recovery |
| `deploy-app-dir` | `true` | Set `false` for a site with no private directory; all `app-*` inputs are then ignored |
| `public-excludes` | `dev-router.php`, `router.php`, `.well-known` | rsync excludes for the public directory, **one per line**. Supplying this **replaces** the default |
| `app-excludes` | *(empty)* | rsync excludes for the app directory, **one per line**. Use for server-managed state or server-only config |

### More than two environments (Disaster Recovery, preview)

The branch mapping handles two targets and stops there: one ref maps to exactly
one environment, so there is no value of `github.ref` meaning "production *and*
the Disaster Recovery host." A DR target is the same commit as production on a
different host with different credentials - so it needs its own Environment, and
the `environment` input is how you reach it.

Add a third stub in the site repo. The full file is
[`examples/workflows/deploy-dr.yml`](examples/workflows/deploy-dr.yml) and is reproduced under
[Consuming these workflows](#consuming-these-workflows) - it is deliberately
NOT copied a second time here, because only the marked block is covered by the
README-matches-examples check and an unmarked copy could drift freely.

Then create a `dr` Environment with its own `DEPLOY_*` secrets, `WEB_ROOT_DIRS`,
and `SITE_URL`. Nothing in the shared workflow changes.

**Hardcode the value in the stub.** Do not wire it to a `workflow_dispatch`
choice input - that converts a reviewed, version-controlled decision into a
dropdown that includes production. A stub reading `environment: dr` cannot be
pointed anywhere else.

**Resolution is permissive; the preflight is the control.** The input simply
wins over the ref, so `environment: production` from `staging` does resolve to
`production`. What stops it there is the preflight, which then applies two
refusals that no input can bypass:

1. It refuses `production` from any ref but `main`, because the entire point of
   `main` having no push trigger is that production only ever receives what
   `promote.yml` fast-forwarded there.
2. It refuses any commit that `staging` does not already contain, which is the
   same invariant `promote.yml` enforces before it fast-forwards.

Comparison is case-insensitive, so `environment: Production` is caught too - it
names the same GitHub environment.

`production` is not an arbitrary name to single out - the default mapping
already treats it specially, and this keeps that mapping true when the input is
used.

**Custom environments are not covered by those refusals**, because the workflow
cannot know which of them are production-like. Express the branch half per stub
with an `if:` on the calling job, as above - a caller job may carry `if:` even
though it cannot carry `environment:`. Only that half: `if:` cannot inspect git
history, so the staging-containment refusal has no equivalent out there. In
practice a DR run started from `main` right after a publish gets that property
anyway, by deploying the commit production already accepted.

If DR should instead track production automatically on every publish, a caller
job can carry a `strategy: matrix` over `[production, dr]`. I would reach for
that only for a warm standby: it doubles every production deploy's runtime and
blast radius.

### Directory names are not assumed

`public` and `app` are only defaults. A repo using `web/` and `src/`, deploying
to a host that expects the private tree to be called `private/`, needs no
changes here:

```yaml
with:
  public-dir: web
  app-dir: src
  app-remote-dir: private
```

`app-remote-dir` exists because the repository name and the server name are
genuinely separate concerns - your application locates that directory at runtime
by relative path, so whatever it expects is what the server must have. It
defaults to `app-dir`, which is the common case.

### Sites with no private directory

For a simple site where everything lives under the web root:

```yaml
with:
  deploy-app-dir: false
```

`app-dir`, `app-remote-dir`, and `app-excludes` are then ignored, no app sync
runs, and the layout check stops requiring that directory.

It is a typed boolean rather than "pass an empty `app-dir`" on purpose. Empty is
the signature of the misconfiguration that collapses an rsync destination onto
`DEPLOY_BASE_DIR` and empties the account, so empty has to stay fatal
*everywhere* rather than meaning "skip" in one place. It also matters that
empty is reachable by accident - an unset input, a typo'd input name, a deleted
line - and an accidental skip would deploy your public tree while its backing
code silently went stale. A missing `app-dir` with `deploy-app-dir: true` is
therefore a hard error, and the message tells you about this flag.

### The repository root is not supported as a web root

`public-dir` must name a subdirectory. `.` is rejected, with a message showing
the fix.

Syncing the repository root to a web root would publish `.git` - the full
history, including any secret ever committed and later removed, and a path
that is actively scanned for - along with `.github`, tests, and dependency
manifests. It also cannot coexist with a private app directory, since that
directory would sit *inside* the published tree.

The workaround is a one-time restructure:

```bash
mkdir public
git mv <your site files> public/
```

That is preferable to a longer exclude list maintained forever against your own
repo layout, whose failure mode is silent publication.

### Two tiers of exclude

**Never-ship, and not overridable:** `.git` and `.github` are always excluded
from **both** syncs, public and app. A repository's history is not part of the
application and does not belong on any deploy target. In a web root the stakes
are higher - `.git` exposes the full history, including any secret ever
committed and later removed, at a path that is actively scanned for - but there
is no target where either directory is wanted, so neither depends on a caller
configuring it correctly. They are also constantly churning objects, so syncing
them would re-transfer on every deploy.

rsync patterns without a leading slash match a basename at any depth, so a
nested `.git` from a submodule or vendored checkout is caught too. In the common
case there is nothing to match, since `.git` lives at the repository root and
both sync sources are subdirectories - it costs nothing.

**Conventional, and overridable:** everything in `public-excludes`. These stay
overridable on purpose. `dev-router.php` and `router.php` are one project's
dev-shim filenames, not a universal truth, and `.well-known` is excluded only
because the host usually manages it - a site serving its own ACME challenges,
`security.txt`, or `apple-app-site-association` needs to deploy it, and must be
able to say so.

**Supplying `public-excludes` replaces the default; it does not extend it.** So
include anything from the default list you still need. That is the price of
being able to drop `.well-known`, and the deploy log prints the exclude list
actually in effect on every run so a replaced default is visible rather than
discovered later on the server:

```
excludes in effect:
  .git
  .github
  dev-router.php
  router.php
  .well-known
```

### Every list is newline-separated

`WEB_ROOT_DIRS` and both exclude inputs split on newlines, never on spaces. One
idiom throughout, and a value containing a space still works:

```yaml
with:
  app-excludes: |
    cache/
    config/mail.php
```

### Repository settings

**Workflow permissions: leave them alone.** `promote.yml` pushes `main` and
dispatches the deploy using the built-in `GITHUB_TOKEN`, and the promote stub
grants exactly that on its own job:

```yaml
permissions:
  contents: write
  actions: write
```

The grant has to live on the *calling* job because a called workflow can only
downgrade the token it is handed, never elevate it. Granting it there rather
than flipping **Settings → Actions → General → Workflow permissions** to "Read
and write permissions" keeps write scoped to that one job instead of handing it
to every workflow in the repo.

**Do not add a branch-protection rule requiring pull requests on `main`.**
Publishing fast-forwards `main` from a workflow, and such a rule blocks exactly
that push.

## `WEB_ROOT_DIRS`, and the one thing to know before using more than one

Every listed root receives an **identical** copy of `public/`. There is no
"primary" root - from the deploy's point of view they are the same operation.
This supports one commit serving several hostnames that differ only at runtime:
a hidden preview subdomain, a demo, a vanity mirror.

**But `app/` is synced once**, to `DEPLOY_BASE_DIR`, and the front controller
finds it by relative path. So every web root resolves to the **same `app/`** and
the same runtime state beneath it. If the application behaves differently per
hostname it must key that on `HTTP_HOST`, and anything it writes to disk must be
keyed by host too. Do not list more than one root unless the app is built for
it.

## The layout must not overlap

Every web root, and the app directory, are **siblings** under
`DEPLOY_BASE_DIR`. The preflight refuses anything else, because each is rsynced
with `--delete` and overlapping trees produce two kinds of damage.

Overlap is checked on **both sides**, because neither check can see what the
other catches.

**On the server**, under `DEPLOY_BASE_DIR`:

| Rejected | Why |
|---|---|
| `app-remote-dir` inside a web root, e.g. `site.com/app` | Publishes your application source over HTTP |
| `app-remote-dir` equal to a web root | The two syncs erase each other |
| A web root inside `app-remote-dir` | Same - they erase each other |
| One web root inside another | Same, and which wins depends on line order in a variable |
| The same web root listed twice | Almost certainly a mistake |

**In the repository**, between `public-dir` and `app-dir`:

| Rejected | Why |
|---|---|
| `app-dir` inside `public-dir`, e.g. `public/app` | `public-dir`s *contents* are copied into every web root, so the private tree ships with them |
| `app-dir` equal to `public-dir` | Same - the whole private tree is published |
| `public-dir` inside `app-dir` | The app sync would carry the public tree too, and the two rsyncs overlap |
| Either one set to the repository root | See [The repository root is not supported as a web root](#the-repository-root-is-not-supported-as-a-web-root) |

The repository-side checks are not redundant with the server-side ones. With
`app-dir: public/app` and `public-dir: public`, every server-side check passes -
`<base>/app` really is beside `<base>/site.com` - while the public sync copies
`public/`s contents into each web root, `app/` included.

On the server side, the first row is the one worth knowing about.
`app-remote-dir` may legally contain slashes, so `site.com/app` passes every
other check - it is relative, has no `..`, is not empty - and would quietly
place your entire private tree inside a served directory.

Excluding dotfiles would not save you in any of these cases: if the app tree
lands in a web root, its source, config, and any server-side credentials are
already public. **The layout is the control**, which is why every row is a hard
failure rather than a warning.

Every path is normalized before comparison - repeated slashes collapsed, `./`
segments removed wherever they appear (leading, interior or trailing), trailing
slashes stripped - so neither `./site.com/app` nor `site.com/.` slips past a
check that `site.com/app` fails.

App-directory checks are skipped entirely when `deploy-app-dir` is false, since
there is nothing to place.

## Server layout produced

```
<DEPLOY_BASE_DIR>/<each WEB_ROOT_DIRS entry>/   <- contents of <public-dir>
<DEPLOY_BASE_DIR>/<app-remote-dir>/             <- contents of <app-dir>,
                                                   ABOVE the web roots
```

Only those two directories are shipped. `tests/`, `.github/`, and dev tooling
never reach the server.

**A note on the `app` sync, if you are reading the workflow.** Its destination
is built as `<DEPLOY_BASE_DIR>/<app-remote-dir>/`, and an empty
`<app-remote-dir>` would collapse that to `<DEPLOY_BASE_DIR>/` - where
`--delete` would prune every live web root beside it. An earlier version passed
the directory without a trailing slash, which made that structurally impossible
but also forced the server name to equal the repo name. Supporting a distinct
server name traded the structural guarantee for a validated one, so
`app-remote-dir` goes through the same checks as every web root, plus a final
assertion immediately before the rsync. That assertion applies the same test
`check_relative_dir` does, not merely a non-empty one: `.` and `./` normalize to
a non-empty value that still resolves to the parent directory, so a backstop
testing only for empty would be narrower than the hazard it exists for.

## Host key pinning

If `DEPLOY_HOST_KEY` is unset, the deploy falls back to `ssh-keyscan`, which is
trust-on-first-use: it accepts whatever key the server presents, on every run,
and therefore cannot detect a substituted host. Setting `DEPLOY_HOST_KEY` closes
that gap.

**Prefer a value your host publishes.** Most providers document their
`known_hosts` entries; take them from there. The whole point of pinning is to
know what you should be talking to, and a key you scanned yourself is only as
trustworthy as the network path you scanned it over - if that path was
intercepted, you have pinned the interceptor.

If nothing is published, scan it, but treat that as trust-on-first-use moved
earlier rather than eliminated:

```bash
ssh-keyscan your-host.example.com
```

**The value is one or more whole `known_hosts` lines**, appended verbatim to the
runner's `known_hosts`. Not a fingerprint - a fingerprint is a hash of the key,
and SSH needs the key itself. Paste every line the host offers rather than
picking one: pinning only `ssh-rsa` usually works, because OpenSSH prefers
algorithms it already has for a host, but it leaves you one algorithm retirement
away from a failed deploy. Drop the `#` comment lines; `ssh-keyscan` writes those
to stderr and they are not part of the output.

No `-H`. Hashing hides *which hosts you connect to* from someone reading a
shared machine's `known_hosts`, which protects nothing on an ephemeral runner,
and it costs you the ability to look at the secret and see what it is for or
check it against a published fingerprint.

**Verify before you paste**, if the host publishes fingerprints:

```bash
ssh-keyscan your-host.example.com 2>/dev/null | ssh-keygen -lf -
```

Every line that prints should appear in the published list. If one does not,
stop and find out why before deploying.

Two things that silently produce a pin that never matches:

- **The host field must equal `DEPLOY_HOST` exactly.** SSH looks the entry up by
  the name it is connecting to. A wildcard like `*.example.com` matches; a
  different literal hostname does not. If a published line is keyed to another
  name, keep the key material and substitute your host in the first field.
- **A non-default `DEPLOY_PORT` changes the key.** `known_hosts` records those
  entries as `[host]:port`, so scan with `ssh-keyscan -p <port> <host>` or the
  pin will not apply.

Worth doing before a host migration rather than during one.

## Versioning

The `@ref` in a consumer's `uses:` line is just a git ref - branch, tag, or
commit SHA. There is no publish step and no registry; GitHub fetches that ref at
run time. Commits can accumulate on `main` here without affecting any consumer
until their pin moves.

For production sites, pin by **commit SHA** with a version comment, the same way
actions are pinned:

```yaml
uses: Apeify/ci/.github/workflows/deploy.yml@a1b2c3d # v1.2.0
```

A moving `@v1` tag is the other common convention, but it is a mutable ref: one
bad commit reaches every consumer at once. A SHA pin plus Dependabot gives the
same propagation with a review gate and a staggered rollout.

**The version comment is only a comment.** The SHA decides what runs. If the two
disagree, nothing complains. For ground truth, both workflows log
`job.workflow_ref` and `job.workflow_sha`, which come from GitHub and cannot
drift.

Note those are the `job` context, not `github`. For a job running via
`workflow_call` they describe the workflow file that *defines* the job - the
reusable one here - whereas `github.workflow_ref` / `github.workflow_sha`
describe the *calling* workflow in the site repo.

A **major** bump is any change that requires you to act - a new required input,
a renamed secret or variable you must create, a changed server layout. Anything
else is minor or patch, and the version comment beside the pin is what tells you
which kind of Dependabot PR you are looking at.

### Keeping the pin current with Dependabot

A SHA pin only helps while somebody moves it, and a pin nobody moves is a site
running a pipeline nobody has looked at in a year. Dependabot turns that from a
chore into a review: it watches the refs your workflows `uses:`, opens a pull
request when a newer version exists, and updates the version comment beside the
SHA along with it. Reusable-workflow references are covered, not just `uses:` on
steps.

Copy this to `.github/dependabot.yml` - **not** into `.github/workflows/`, which
is a different directory for a different thing.

[`examples/dependabot.yml`](examples/dependabot.yml)

<!-- example:examples/dependabot.yml -->
```yaml
# Copy to .github/dependabot.yml in the consuming repo.
#
# NOTE THE PATH. This is Dependabot configuration, not a workflow: it belongs at
# .github/dependabot.yml, NOT in .github/workflows/. Putting it in the workflows
# directory does nothing - GitHub will not read it there, and Actions will try
# to run it as a workflow and fail.
#
# =========================================================================
# WHY YOU WANT THIS
# =========================================================================
#
# The deploy and promote stubs pin the shared pipeline to a commit SHA with a
# version comment beside it:
#
#   uses: Apeify/ci/.github/workflows/deploy.yml@<sha>  # v1.4.0
#
# A pin is what stops a change in the shared repo from reaching this site
# without anyone deciding it should. The cost is that the pin then has to be
# moved by hand, and a pin nobody moves is a site running a pipeline nobody has
# looked at in a year. Dependabot is what makes the pin maintainable: it opens a
# pull request when a newer version exists, so updating is a review rather than
# a chore somebody has to remember.
#
# It understands reusable-workflow references, not just `uses:` on steps, and it
# updates the version COMMENT alongside the SHA - which is what makes that
# comment trustworthy enough to review against. See the README's Versioning
# section for what a major bump means.
#
# =========================================================================
# target-branch IS NOT OPTIONAL HERE
# =========================================================================
#
# Read this before deleting the line below.
#
# Dependabot targets the repository's DEFAULT branch unless told otherwise, and
# on most repos that is `main`. Merging a Dependabot PR into `main` puts a commit
# on `main` that `staging` does not have - and this pipeline's whole model is
# that `main` only ever contains what `staging` already carried. From that point
# on the publish button refuses to fast-forward, and a production deploy of that
# commit is refused too, until someone repairs the branches by hand.
#
# So updates are aimed at `staging`, where every other change to the site lands.
# They then reach production the same way everything else does, by publishing.
#
# If this repo's default branch IS `staging`, the line is redundant but harmless.
# Leave it: it documents the requirement, and it keeps working if the default
# branch is ever changed.
version: 2

updates:
  - package-ecosystem: "github-actions"
    # Covers everything `uses:` in .github/workflows - the pipeline stubs and any
    # third-party action they call - plus an action.yml in the repository root if
    # one exists. Other directories can be given their own entry if this repo
    # keeps composite actions outside .github/, which most sites do not.
    directory: "/"
    schedule:
      # Weekly. Daily turns a shared pipeline into a stream of pull requests
      # nobody reads, and reviewing these carelessly is worse than updating
      # slowly: merging one changes what deploys to the live site.
      interval: "weekly"
    # See above. Without this, merging an update breaks publishing.
    target-branch: "staging"
    # One pull request for all of them rather than one each. The noise from
    # separate PRs is what gets update PRs ignored, and ignored updates are the
    # failure this file exists to prevent.
    #
    # The trade is that a pipeline bump can ride along with unrelated action
    # bumps, so read the version comment in the diff rather than the PR title:
    # a major bump means a required input, secret, variable or server layout
    # changed, and merging it without acting is what breaks the next deploy.
    groups:
      github-actions:
        patterns:
          - "*"
    commit-message:
      prefix: "ci"
```

**`target-branch` is the line to not delete.** Dependabot targets the
repository's default branch unless told otherwise. If that is `main`, merging an
update puts a commit on `main` that `staging` does not have - and this pipeline
refuses to publish, or to deploy production, in exactly that state. Aiming
updates at `staging` keeps them on the same path as every other change.

One entry covers every `uses:` in `.github/workflows/`, so it picks up both
pipeline stubs and any third-party action they call. It does not cover the
site's own dependencies; add a second `updates:` entry if the repo grows a
`composer.json` or `package.json` worth tracking.

Dependabot can only offer a version bump when it has a newer version to compare
against, which means the pin has to be a tagged release rather than a branch.
While a stub tracks `@main` there is nothing for it to do. Pin to a tagged SHA
before relying on this file, and keep the version comment beside the pin - it is
what tells you, in the diff, whether you are looking at a major bump.

## Working on the pipeline itself

[MAINTAINING.md](MAINTAINING.md) covers releasing, the local validation setup,
and the reasoning behind the choices above - why lint and test run in a separate
job from the deploy, why `SITE_URL` is a variable rather than an input, why the
production guard fails closed. Read it if a decision here looks arbitrary and
you want to know whether it is.

## License

MIT - see [LICENSE](LICENSE).
