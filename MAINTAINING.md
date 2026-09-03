# Maintaining these workflows

For people working *on* the shared pipeline, not consuming it. If you are wiring
a site up to it, [README.md](README.md) is the document you want - this one
assumes you have read it.

Four things live here: how to cut a release, why the pipeline is shaped the way
it is, how to check a change before it reaches a real site, and how to run those
checks on your own machine.

- [Releasing](#releasing)
- [Design notes](#design-notes)
- [Why `SITE_URL` is a variable and not an input](#why-site_url-is-a-variable-and-not-an-input)
- [Validating changes here](#validating-changes-here)
- [Running the checks locally](#running-the-checks-locally)

The house rules for editing this repo - pinning, spelling, comment style, the
newline-separated-lists rule - are in [CLAUDE.md](CLAUDE.md).

## Releasing

Branch → PR → merge to `main` → tag. Consumers move when their pin is bumped,
which Dependabot will offer automatically. There is no publish step and no
registry: a tag is just a git ref, and GitHub fetches whatever ref a consumer's
`uses:` line names at run time. Commits can accumulate on `main` here without
affecting anyone until their pin moves.

### What "major" means here

A **major** bump is any change requiring the consumer to act: a new required
input, a renamed secret or variable they must create, a changed server layout,
or a change to the SHAPE of the stub - a workflow that moved or was deleted, a
job that has to be added. Everything else is minor or patch.

That last clause exists because the first release to carry it is one the earlier
definition did not describe: `deploy.yml` was deleted and every consumer has to
rewrite a one-job stub into two. A pin bump alone gives them "workflow was not
found" on their next push. Any release like that needs a migration note saying
so, not just a version number.

That definition is doing real work, because a consumer pinned to a SHA gets a
Dependabot PR either way - the version comment beside the pin is the only signal
telling them whether it needs reading before merging.

### At tag time, update [`examples/workflows/`](examples/workflows/)

Those stubs currently say `@main`, which is the one place in this repo that
teaches the opposite of the advice in
[Versioning](README.md#versioning). Once a tag exists they should show the
SHA-pinned form with a version comment, so the copyable artifact matches the
convention it documents.

Editing them will fail the README-matches-examples check until the README blocks
are regenerated from the files - which is the reminder that both need updating.

The first tag is also what makes [`examples/dependabot.yml`](examples/dependabot.yml)
useful. Dependabot can only offer a version bump when the pinned commit is
reachable from a tag; against a branch there is nothing to compare, and it may
move the pin to an untagged branch HEAD while leaving a version comment that is
now wrong. Until the tag exists, that example describes something consumers
cannot yet benefit from - which is another reason not to leave the stubs on
`@main` indefinitely.

### Testing a change before tagging

The suite in [`tests/`](tests/) covers the validation logic. It cannot cover the
deploy, because there is no host here and no credentials. The only thing that
does is running the pipeline against a real account, which means borrowing a
consumer's staging environment.

This is a procedure, not an automated test. Nothing below asserts anything on
your behalf.

**Point a consumer at the branch.** In one site repo, change the stub's `uses:`
ref to your branch and push that repo's `staging`:

```yaml
uses: Apeify/ci/.github/workflows/lint-and-test.yml@my-branch
# ...and, in the same stub:
uses: Apeify/ci/actions/deploy@my-branch
```

GitHub resolves the ref at run time, so no tag or release is involved. Use
`staging`, never `main`: production refuses any commit `staging` has not already
carried, so a production run would be refused on that ground rather than telling
you anything about your change.

**Then check the things the pipeline is responsible for.** Not the site's
content - what the pipeline promises regardless of what the site happens to be:

| Check | How | Why it is here |
|---|---|---|
| Both jobs went green | Actions run | The lint/test job and the deploy job are separate; a green deploy with a skipped test job is not a pass |
| The preflight printed the layout you expected | `Preflight - check configuration` step log | It echoes the normalized paths. If they differ from what you configured, normalization changed |
| The site still serves | `curl -sI https://<staging-domain>` | Confirms the web root still holds a servable tree, whatever that tree is |
| Server-managed state survived | `ssh` in and check a path from that environment's `app-excludes` / `public-excludes` | `--delete` runs against a tree the repo does not contain these files in. This is the check most likely to catch a real regression |
| The private tree is beside the web roots, not inside one | `ls` `DEPLOY_BASE_DIR`: the app directory and each web root should be siblings | The whole layout guarantee. If it moved, application source is being served |
| Deletions propagate | Remove a file from the repo, push, confirm it is gone from the server | `--delete` is the reason a broken deploy is destructive; confirm it still works as intended |
| mtimes are commit dates, not deploy time | `ls -l` a few files on the server | The mtime restore exists so rsync does not re-send the whole tree every run |
| A second deploy with no changes transfers almost nothing | Re-run the workflow, read the rsync `--stats` output | The strongest single signal that the mtime restore is working. A full re-transfer means it is not |
| The itemized change list contains only what you expected | rsync `--itemize-changes` output in the log | Anything else moved is the finding |

If the site has CSS or JS, also confirm the minified assets are present and
non-empty; if it has none, that step has nothing to do and its log will say so.

**Put the stub back** when you are done - to the pin it had, or `@main` - and
push again so the consumer is not left tracking your branch.

**What this still does not cover.** The production path: the `main`-only refusal
and the staging-containment guard are exercised only by [`tests/`](tests/),
because rehearsing them for real means deploying to production. Treat the tests
as the coverage there and this procedure as coverage of everything downstream of
the preflight.

## Design notes

**Lint/test is a separate job from deploy, deliberately.** Tests may execute
third-party code. Secrets are not ambient environment variables, so such code
cannot read the deploy key directly - but a job shares one runner and one
working directory with everything after it, and code running during dependency
installation could tamper with the tree that is about to be rsynced to a live
site. A separate job is a separate VM whose filesystem the deploy never sees.
The lint job declares **no** `environment:`, so environment secrets are never in
scope there at all.

**The deploy job still runs third-party code** - `esbuild`, on the tree it is
about to ship. It runs before the SSH key is written, so it cannot read the key,
but the exact-version pin is the real mitigation, not the step ordering.

**Test suites and Composer are detected, not configured.** A repo either has
`tests/run.php`, or `vendor/bin/phpunit`, or `composer.json`, or none of them.
Asking the caller to declare that in an input would just be a second place for
the truth to live and a second place to get it wrong.

**Excludes default to a union.** Excluding a file that does not exist is free,
so the default covers every dev-only shim used across these sites rather than
making each repo configure its own.

**`WEB_ROOT_DIRS` is validated before anything transfers.** It is interpolated
into an rsync destination that runs with `--delete`, so an empty entry would
collapse the destination to `<base>//` - the account home - and prune everything
there that is not in `public/`. Entries must be relative, free of `..`, and must
not resolve to their own parent (`.`, `./`).

An empty entry is **skipped, not rejected**, and the distinction matters if you
ever touch that code. A value entered through the GitHub UI routinely ends with
a newline, so a trailing blank entry arrives on every run and failing on it
would be useless. What the preflight refuses is a variable with no usable entry
at all.

There are two identical-looking `[ -z "$dir" ] && continue` lines, one in the
preflight and one in the rsync loop, and **neither is redundant with the
other**. The rsync loop's is what keeps a stray newline away from `--delete`:
without it the destination collapses to the account home. The preflight's
guards `check_relative_dir`, which *rejects* an empty value, so without it that
same ordinary trailing newline fails the preflight outright and no deploy runs
anywhere. Delete one and every deploy breaks loudly; delete the other and one
deploy destroys an account. Both are commented in place. The rsync steps also
carry a dot-only backstop mirroring the preflight's, so the second line of
defense is not narrower than the hazard the first one names.

**Every path is normalized before it is compared.** `norm_path` collapses
repeated slashes, removes `./` segments wherever they appear (leading, interior
or trailing), and strips trailing slashes; the preflight and both rsync steps
run every path through it. The comparisons in
[the layout checks](README.md#the-layout-must-not-overlap) are string prefix
tests, so an unexpected spelling defeats them *silently* - and this has now been
the same bug twice, which is why the normalizer is deliberately aggressive
rather than minimal:

- An early version normalized only two of the values, and only one leading
  `./`, which left `app-remote-dir: ./site.com/app` able to place the private
  tree inside a served web root.
- The next one normalized every value but left a trailing `/.` intact, so
  `WEB_ROOT_DIRS: site.com/.` with `app-remote-dir: site.com/app` built the
  nesting pattern `site.com/./*`, which never matched `site.com/app`.

Both put the entire private tree on the public web while every check reported
success. Any new comparison must normalize both sides, and any spelling that
survives `norm_path` is this bug a third time.

**The pipeline is split across two mechanisms, and neither half can move.**
`lint-and-test` is a reusable workflow; the deploy is a composite action. The
asymmetry looks untidy and is load-bearing in both directions.

The deploy must be an action because only a normal job can declare
`environment:`, and the credentials are environment secrets. As a reusable
workflow it could receive them only via `secrets: inherit`, which GitHub honors
solely within one organization or enterprise - so a consumer under a different
owner inherited nothing, silently, while the environment was still entered and
`vars` still resolved.

`lint-and-test` must stay a workflow because a job calling one cannot also
declare `steps:` - GitHub rejects the file, and so does actionlint. That refusal
is what guarantees third-party test code never shares a runner with the deploy
key. Convert it to an action "for symmetry" and both halves land in one job's
steps, and the guarantee is gone with no error anywhere.

The costs of the split are worth stating plainly. actionlint does not understand
composite actions - it parses `action.yml` as a workflow and reports nonsense -
so the deploy half has no schema linting and no actionlint-driven shellcheck.
[`tests/`](tests/) and validate.yml's extractor are its entire automated
coverage, which is why the extractor checks `runs.using` and rejects a `run:`
step with no `shell:`. And `vars` is unavailable inside a composite action
altogether, so web roots arrive as an input rather than being read from context.

There is also no wrapper reusable workflow, deliberately. `uses:` accepts no
expressions and `uses: ./...` inside a reusable workflow resolves against the
CALLER's checkout, so a wrapper could only name `actions/deploy@<hardcoded ref>`
- and a consumer pinning the wrapper to a tag would silently get whatever that
hardcoded ref moved to. One path is better than a wrapper that breaks pinning.

**The production guard fails closed.** The containment check refuses the
deploy if it cannot fetch `origin`, or if `origin/staging` does not resolve. An
earlier version swallowed both cases and continued, which meant a network blip
skipped the check on exactly the configuration it exists to refuse. It also
compares `HEAD` - the commit the run is deploying - rather than `origin/main`,
which can have moved since the run was created.

## Why `SITE_URL` is a variable and not an input

It supplies the link GitHub shows on a deployment. Two earlier designs were
rejected:

- **Derived from the web-root name.** Only works on hosts that name the docroot
  after the domain, which is a hosting convention rather than a rule, and this
  pipeline is meant to outlive any one host.
- **One input per environment**, selected by branch. Works for two environments
  and stops there: a third needs a nested ternary, and every consumer stub grows
  a line per environment.

A variable resolved from whichever environment was entered is constant in the
number of environments, which is what makes a DR or preview target possible
without touching the shared workflow. It also puts the URL beside
`WEB_ROOT_DIRS`, where the rest of that environment's topology already lives.

This works because GitHub's context-availability table grants `vars` to both
`environment` and `environment.url`. `url` is evaluated **late** - the same
table grants it `steps` and `job` - so the environment has been fully entered by
then and an environment-scoped variable resolves. That is not true of
`environment.name`, which cannot depend on the environment it is selecting.

It is optional, and a missing value is a **warning, not an error**: you lose a
clickable link and nothing else. Failing a production deploy over a cosmetic UI
detail would be the wrong trade.

## Validating changes here

[`validate.yml`](.github/workflows/validate.yml) runs on every push and pull
request, with no `paths:` filter. There was one, and every file it omitted
turned out to be a file that changes what these checks do - `setup.sh`,
`.actionlint-version`, `.github/actionlint.yaml` - so a commit to any of them
was silently unchecked. See the comment above its triggers. It checks in five
layers.

### 1. A structural floor

Parse every workflow as YAML, extract each `run:` block to its own script, and
confirm each parses as shell (`bash -n`). This covers the two failure classes
that have actually broken this code:

1. **A workflow that no longer parses** - the usual result of an edit that drops
   or adds a level of indentation.
2. **A `run:` block with broken shell** - invisible until the step executes on a
   real deploy, by which point a site is failing.

GitHub expressions are replaced with a plain identifier first. `${{ ... }}` is
not shell - bash reads `${{` as a parameter expansion with an invalid name - so
leaving them in would produce errors that say nothing about the script.

This step installs `js-yaml` from npm. An earlier version of this section called
it self-contained and said it "still works when a download does not", which was
never true of a step whose first action is `npm install`. Layer 5 is the one
that genuinely needs nothing installed.

### 2. [actionlint](https://github.com/rhysd/actionlint)

It checks what nothing above can: the workflow *schema* (unknown keys, invalid
`runs-on`, bad `needs:` references) and the expressions inside `${{ }}`,
including which contexts are legal in which position. It also runs `shellcheck`
over `run:` blocks itself, handling the expression substitution natively - which
is why layer 4 covers only the scripts that live *outside* a `run:` block.

`examples/workflows/` has to be named explicitly on the command line. actionlint
scans only the conventional workflow directory, and the stubs deliberately live
outside it: they carry real triggers, so GitHub would run them in *this* repo if
they sat in `.github/workflows/`.

Naming them is [`scripts/lint-workflows.sh`](scripts/lint-workflows.sh)'s job,
and it selects by DIRECTORY: everything in `examples/workflows/` is linted, and
[`examples/dependabot.yml`](examples/dependabot.yml) one level up is not, because
it is configuration rather than a workflow and actionlint rejects it outright.

An earlier version selected by content - any `examples/*.yml` carrying a
top-level `on:` key - because the directory did not yet carry that meaning. The
directory is better, and not only for being simpler: content selection silently
SKIPS a stub that has lost its `on:` key, which is exactly the broken stub you
want reported, since a broken example gets copied.

actionlint is pinned by exact version **and** verified against a SHA256
committed in [`.actionlint-version`](.actionlint-version). The checksum is the
real pin: a version tag is mutable, so if a release were re-cut under the same
tag the download would silently change, and the hash check turns that into a
failed build. The checksum is verified before the archive is extracted or run.

To update: bump `ACTIONLINT_VERSION` in
[`.actionlint-version`](.actionlint-version) and take the matching lines from
that release's `checksums.txt`.

[`.github/actionlint.yaml`](.github/actionlint.yaml) holds a single, narrowly
scoped suppression. actionlint's built-in type for the `job` context is missing
`workflow_ref`, `workflow_sha`, `workflow_repository`, and `workflow_file_path`,
which GitHub documents and supports - so the pipeline-version logging in
`promote.yml` is reported as an undefined property. The ignore
pattern is anchored to the job context's object type, so a typo against any
other context, or against a different `job` property, still fails the build.
Delete the file and re-run after upgrading actionlint to see whether it is still
needed.

### 3. README matches `examples/`

Each file in [`examples/`](examples/), at both levels, is reproduced inline in
[README.md](README.md), and that duplication would drift - so the two are
compared mechanically rather than trusted. Blocks are delimited by an HTML
comment naming the file they mirror by repo-relative path
(`<!-- example:examples/workflows/deploy.yml -->`, invisible
when rendered), and **the file is the source of truth**: if the check fails,
regenerate the README block from the file. It also fails if a marker goes
missing, so deleting one cannot silently disable the comparison.

A stale README stub is worse than no stub, because it gets copied.

### 4. `shellcheck` over the standalone scripts

`.devcontainer/setup.sh` and everything in `scripts/` and [`tests/`](tests/) are
shell, but they are not workflow `run:` blocks, so actionlint never sees them.
Without this step nothing would check them at all.

That gap was not hypothetical - a broken `shellcheck` directive in `setup.sh`
was found only by running the equivalent VS Code task by hand, which is what
prompted adding the CI step. Both use the same flags, so they cannot disagree:
`-x` follows sourced files, and `--source-path=SCRIPTDIR` resolves
`# shellcheck source=` directives relative to the *script* rather than the
working directory.

In CI, scripts are discovered with `git ls-files '*.sh'`, so a new one is
covered automatically. The local task uses `find` instead, and that difference
is deliberate rather than an oversight: locally you want a script checked while
you are still writing it, before it has ever been staged.

### 5. The test suite in [`tests/`](tests/)

Layers 1 to 4 all ask whether the code is well-formed. This one asks whether it
does the right thing, and it is the only layer that can. Every defect that has
reached a consuming site was well-formed shell that behaved wrongly:

- a repo-root check placed above the gate that was supposed to skip it, so
  `deploy-app-dir: false` failed over an input it had switched off;
- two sides of a path comparison normalized differently, twice, each time
  putting the private tree inside a served web root while every check reported
  success;
- a production refusal downgraded to a warning, so a network blip skipped the
  guard on exactly the configuration it exists to refuse.

None of the four layers above can see any of that. actionlint passes all three.

**The tests extract the shell from the workflow rather than restating it.**
[`tests/lib/harness.sh`](tests/lib/harness.sh) pulls a step's `run:` body, or a
single function, back out of
[actions/deploy/action.yml](actions/deploy/action.yml) with awk
and runs it. A copy of the logic maintained under `tests/` would keep passing
while the workflow was broken, which is the failure this layer exists to
prevent. Extraction is structural, so every extractor asserts a sentinel and
aborts loudly rather than testing an empty string.

The preflight step is driveable this way because it reads every value from the
environment and contains no GitHub expressions of its own. Keep it that way: an
inline expression there would take the step out of test coverage.

It needs bash, awk and git and nothing else - no network, no npm - so it runs
anywhere, including outside the dev container.

**Regression cases are labeled.** Anything marked `REGRESSION` in a test name is
a bug that actually shipped. Those assertions are the record of it; do not
delete one because the input looks contrived.

**Assert the message, not only the exit code.** Several guards sit in front of
one another, so deleting one still produces a nonzero exit from the next. The
fail-closed tests assert *which* refusal fired for exactly that reason - an
exit-code-only assertion passes against a guard that has been removed, and one
did, until it was tightened.

**How to know the suite still works: delete a guard and watch it fail.** A test
that cannot fail is worse than no test, and this suite has twice been found
green against an `action.yml` with a guard removed. The check is mechanical:

```bash
mkdir -p /tmp/mut && tar --exclude=node_modules --exclude=.git -cf - . | (cd /tmp/mut && tar -xf -)
```

Then, inside the copy, delete one `check_relative_dir` or `reject_repo_root`
call, or one `case` in the web-root overlap loop, and run `bash tests/run.sh`.
It must fail, and it must fail naming that guard. Work in a copy: mutation
testing edits the action, and a half-restored `action.yml` is a bad thing to
leave in a working tree.

**Verify the mutation applied before believing a pass.** This is the rule that
matters, because breaking it produces a false all-clear that looks exactly like
a real one. Three separate mutations in this repo's history silently did
nothing - a `sed` whose indentation did not match, a `perl` regex mangled by
shell quoting - and each reported a green suite that proved only that the file
had not changed. Diff the copy, or check its line count, before drawing any
conclusion from a pass.

### What none of it can do

**It cannot test a deploy.** The tests cover the validation logic, but there is
no host here and no credentials, by design, so nothing exercises rsync, ssh, or
the server-side layout. The real integration test is
[pointing a consumer at a branch](#testing-a-change-before-tagging).

## Running the checks locally

Open the repo in VS Code and choose **Reopen in Container**
([`.devcontainer/`](.devcontainer/)). Provisioning installs `shellcheck`, Node,
and the same pinned actionlint that CI uses.

Then press **Ctrl+Shift+B**, or Terminal → Run Task → **Validate all**.
[`.vscode/tasks.json`](.vscode/tasks.json) defines four check tasks plus the
chain that runs them:

| Task | Runs |
|---|---|
| Validate workflows and examples | [`scripts/lint-workflows.sh`](scripts/lint-workflows.sh) - `actionlint` over every workflow |
| Check README matches examples | `scripts/check-readme-examples.sh` |
| Shellcheck scripts | `shellcheck` over every `*.sh` in the working tree |
| Run tests | [`tests/run.sh`](tests/run.sh) - the behavior suite |
| **Validate all** | all four, in order (the default build task) |

Or directly:

```bash
bash scripts/lint-workflows.sh
```

```bash
bash scripts/check-readme-examples.sh
```

```bash
git ls-files '*.sh' | xargs shellcheck -x --source-path=SCRIPTDIR
```

```bash
bash tests/run.sh
```

The tasks deliberately declare no `problemMatcher`. The shellcheck extension is
installed in the container and gives live diagnostics in the Problems panel as
you edit, which covers the same ground continuously rather than only when a task
is run.

The container exists because this repo cannot deploy anything on its own, so
without it the first place a broken change gets exercised is a real site's
pipeline. Catching it locally is considerably cheaper.

Both the container and CI read their actionlint version and checksums from
[`.actionlint-version`](.actionlint-version), so there is one place to bump and
no way for local checks and CI to validate against different versions. It
carries hashes for `linux/amd64` and `linux/arm64` - CI is always amd64, and a
container on Apple Silicon is arm64.
