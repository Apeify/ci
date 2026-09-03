# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository.

## What this is

Shared GitHub Actions workflows for deploying small PHP sites to SSH-accessible hosting. One
pipeline, written once, consumed by every site repo.

Three docs, three audiences. [README.md](README.md) is the contract consumers read - what to
configure and what the pipeline does. [MAINTAINING.md](MAINTAINING.md) is for working *on* the
pipeline: releasing, local validation, and the reasoning behind the design. This file is the house
rules for editing the repo.

## How to collaborate here

Engage as a peer Principal engineer, not an order-taker. The maintainer wants honest technical
judgment, not agreement.

- **Push back when you disagree.** If a requested change is a bad idea, has a cheaper alternative,
  or trades away something that matters (deploy safety, the blast radius of a shared pipeline,
  a consumer's ability to reason about what will happen), say so plainly and explain why. A
  well-reasoned "I'd advise against this, because..." is more valuable than silent compliance.
- **When asked to weigh a decision, give a real recommendation with reasoning** - argue the
  trade-offs and commit to a position. Do not just enumerate options or reflexively endorse the
  proposal in the question.
- **Surface consequences the request may not have considered** - a validation gap that only shows up
  as data loss, a change that silently alters what an existing consumer deploys, a guard that moves
  from structural to merely validated. Flag it even when not asked.
- **Verify, do not assume.** Measure before claiming a benefit, drive the actual behavior before
  claiming it works, and grep for what a scripted change might have missed. Report failures and
  skipped steps honestly.
- Disagreement is a starting point for discussion, not the final word - the maintainer decides. But
  decisions should be made with the trade-offs on the table.

## Hard constraints

- **A change here reaches every consuming site.** This repo cannot deploy anything by itself, so a
  broken commit is first discovered by a real site failing to deploy. Treat every change as though
  it ships to production, because it does.
- **Nothing third-party runs unpinned.** Actions are pinned by commit SHA with a version comment;
  `actionlint` is pinned by version *and* verified against a SHA256 committed in
  [.actionlint-version](.actionlint-version); `esbuild` is pinned to an exact version. If something
  cannot be pinned, that is an argument against using it.
- **No secrets live here.** Every credential belongs to the consuming repo's GitHub Environment.
  The deploy reads them as action inputs, inside the consumer's own job - NOT via `secrets:
  inherit`, which carries nothing across an owner boundary and failed silently when it was tried.
  This repo is public.
- **The workflows must stay `workflow_call`-only.** They carry no triggers of their own; adding one
  would make them run here, where there is no site and no credentials.

## Development environment

Open in VS Code and choose **Reopen in Container** ([.devcontainer/](.devcontainer/)). Provisioning
installs `shellcheck`, Node, and the same pinned `actionlint` CI uses.

Run the checks with **Ctrl+Shift+B** (Terminal -> Run Task -> **Validate all**), which chains the
four check tasks defined in [.vscode/tasks.json](.vscode/tasks.json) (the fifth label there is
`Validate all` itself):

```bash
bash scripts/lint-workflows.sh                      # schema, expressions, embedded shell
bash scripts/check-readme-examples.sh               # README blocks match examples/
shellcheck -x --source-path=SCRIPTDIR <every *.sh>  # standalone scripts
bash tests/run.sh                                   # behavior of the shell in the deploy action
```

**The tests run the shipping code, not a copy of it.** [tests/lib/harness.sh](tests/lib/harness.sh)
extracts a step's `run:` body - or one function - out of `actions/deploy/action.yml` and
executes it, because a transcription under `tests/` would keep passing while the action was
broken. Two consequences worth knowing before editing either side: the preflight step is testable
only because it takes every value from `env:` and contains no `${{ }}` of its own, and a test named
`REGRESSION` records a bug
that actually shipped. They need only bash, awk and git.

**Local checks cannot test a deploy.** There is no host and no credentials here, so nothing
exercises rsync, ssh, or the server-side layout. The real integration test is to point one
consumer's stub at a branch of this repo and push to its `staging`, which runs the actual pipeline
against a real host. [MAINTAINING.md](MAINTAINING.md) covers this and the rest of the release
process in full.

## Architecture

```
.github/workflows/
  lint-and-test.yml  Reusable. Lints, tests, and resolves the target environment.
  promote.yml        Reusable. The publish button: fast-forward main, dispatch the deploy.
  validate.yml       The ONLY workflow with triggers. Lints the other two.
actions/
  deploy/         Composite action. The rsync half, run inside the CONSUMER's job.
examples/         Copyable artifacts, laid out to mirror where each goes in a
                  consuming repo.
  workflows/      Belongs in the consumer's .github/workflows/. NOT in this repo's
                  .github/workflows - they carry real triggers and would run here.
  dependabot.yml  Belongs at the consumer's .github/dependabot.yml. Config, not a
                  workflow: actionlint rejects it, so lint-workflows.sh lints the
                  workflows/ directory only and validate.yml's extractor
                  YAML-parses this one.
scripts/          Logic shared between CI and the VS Code tasks.
tests/            Behavior tests. Extract the shell from the deploy action and run it.
.actionlint-version   Pinned version + checksums, read by CI and the dev container.
```

Two properties are load-bearing and easy to break by accident:

- **The split between a workflow and an action is not stylistic.** The deploy is an action because
  only a normal job can declare `environment:`, and the credentials are environment secrets - as a
  reusable workflow it would need `secrets: inherit`, which carries nothing across an owner
  boundary. `lint-and-test` stays a workflow because a job calling one cannot also declare
  `steps:`, which is what stops third-party test code sharing a runner with the deploy key.
  Converting either to match the other silently destroys one of those two properties.
- **Consumers omit `main` from their push trigger.** That absence substitutes for the
  required-reviewer rule these repos cannot have: pushing to `main` deploys nothing. It is not
  exclusivity, though - the stub must keep `workflow_dispatch`, since that is how `promote.yml`
  reaches it, so a manual run against `main` is always possible. The preflight is what closes that
  path: it refuses `production` from any ref but `main`, AND refuses any commit that `staging` has
  not already carried.

## Conventions

- **Never use an em dash (U+2014) or en dash (U+2013)** in code, comments, or documentation. Any
  time one is needed, a regular dash (-) will do.
- **Use American spelling, never British.** `behavior` not `behaviour`, `normalize` not `normalise`,
  `canceled` not `cancelled`, `center` not `centre`, `license` not `licence`, `analyze` not
  `analyse`. This covers code, comments, and documentation.
- **Every list a workflow accepts is newline-separated**, never space-separated. One parsing idiom
  throughout, and a value containing a space still works.
- **`examples/` is the source of truth, not the README.** The README reproduces each stub inline;
  `scripts/check-readme-examples.sh` fails the build if they disagree. Regenerate the README block
  from the file, never the reverse.
- **Comment the reasoning, not the mechanics.** A reader can see *what* a step does. Record why it
  is written that way, especially where the obvious simplification is wrong - the merge-commit trap
  in the mtime restore, the trailing-slash rule on the app rsync, and why the deploy half is an
  action while the lint half stays a workflow are all examples worth preserving.
- **Prefer detection over configuration.** A repo either has `tests/run.php`, or `composer.json`, or
  neither. Asking the caller to declare it adds a second place for the truth to live and a second
  place to get it wrong.
- **A guard that can fail silently is worse than no guard.** Anything that validates should be
  tested against a case that must fail, not only one that must pass.
- **Markdown files wrap prose at 100 characters.** Reflow paragraphs/list items to that width when
  adding or editing them. Exceptions: table rows, fenced code blocks (including long command
  lines), and headings are left as-is rather than force-wrapped. A backtick-delimited code span is
  never split across two lines - if it doesn't fit, move its opening backtick to the start of the
  next line whole, even if that line then exceeds 100 characters. Any reference to another
  markdown file in the repo (even a bare filename mention, not just a "see X" pointer) should be an
  actual markdown link (`[FILE.md](FILE.md)` or `[dir/FILE.md](dir/FILE.md)`), not just backticked
  or plain text.
