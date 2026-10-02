# Changelog

What changed in each release of the shared pipeline, and what a consuming site has to do about it.

Versions follow the definition in [MAINTAINING.md](MAINTAINING.md#what-major-means-here): a
**major** bump is any change that requires a consumer to act. Every major release has a
**Migrating** section listing exactly what to change in a site repo; minor and patch releases need
nothing beyond moving the pin.

Dependabot shows the matching section of this file in the pull request that bumps your pin, so
read it there before merging. Pin by commit SHA as described in
[README.md](README.md#versioning), and take the SHA with `git rev-list -n 1 <tag>`.

## [3.1.0] - 2026-10-02

Action is required only for a site that both sets the `php-version` input and has a
`.php-version` file saying something different: its lint-and-test job now fails until the input is
removed or the two match. Every other site needs nothing beyond moving the pin.

### Changed

- **`lint-and-test` reads the repo's `.php-version`.** The `php-version` input no longer defaults to
  `8.3`. Left unset, setup-php reads `.php-version` when the repo has one, and `8.3` is used when
  it does not. A site that already has a `.php-version` saying something other than `8.3` will now
  lint and test against that version instead.
- **A `php-version` input that disagrees with `.php-version` fails the run.** One of the two is
  stale, and picking either silently would test against a PHP nobody chose. The comparison is
  exact, so `8.4` against a file saying `8.4.1` is refused too: remove the input and let the file
  decide.
- **A `php-version` input with whitespace inside it is refused.** `8. 3` is more likely a mistyped
  `8.13` than an `8.3`, so it fails rather than being repaired. Whitespace around the value is
  still trimmed.

## [3.0.1] - 2026-10-02

No action required. Apart from the one fix below, which no correctly configured site can notice, the
deploy action does exactly what it did; only where its shell lives has changed.

### Fixed

- **An `environment` input with leading or trailing whitespace is refused.** The production checks
  compared the exact name, so a value such as `" production"` skipped both of them - the refusal to
  deploy production from any ref but `main`, and the refusal of a commit `staging` never carried.
  The stub passes `needs.lint-and-test.outputs.environment`, which cannot contain whitespace, so
  only a hand-written value was ever exposed.

### Changed

- **The deploy action's shell moved out of `action.yml` into files.** Every multi-line step now runs
  a script from [`actions/deploy/scripts/`](actions/deploy/scripts/), found through
  `$GITHUB_ACTION_PATH`, so the scripts are pinned exactly as the action is. The code is moved, not
  rewritten, with one exception: "Show deploy target" now receives the action's repository and ref
  through `env:` instead of splicing `${{ github.action_* }}` into its shell. The log line is the
  same; a ref containing `$(...)` can no longer execute.
- **Shared helpers are defined once.** `norm_path` existed in three steps and `emit_transfer_stats`
  in two, because steps are separate shells. Both now live in
  [`actions/deploy/scripts/lib.sh`](actions/deploy/scripts/lib.sh) with `check_relative_dir`
  and `reject_repo_root`.
- **The deploy's shell is shellchecked for the first time.** Inline in a composite action, none of
  it was. It came back clean.
- **The tests run the scripts as shipped** instead of cutting the shell out of the YAML with awk. A
  new `tests/action-wiring.test.sh` checks what only a runner would otherwise discover: that each
  step names a script that exists, that every script is used, and that each sets the shell options
  it was written against.

## [3.0.0] - 2026-10-02

The deploy job no longer runs any third-party code. CSS and JS minification, which ran `esbuild`
inside the job holding the SSH deploy key, now runs in a separate reusable workflow and reaches the
deploy as a verified artifact.

### Migrating from 2.x

Required. An unmigrated stub fails at the deploy's first step with "The 'minified-assets' input
is empty."

1. In `.github/workflows/deploy.yml`, add a `minify` job and make the deploy depend on it:

   ```yaml
   jobs:
     lint-and-test:
       uses: Apeify/ci/.github/workflows/lint-and-test.yml@<sha> # v3.0.0

     minify:
       uses: Apeify/ci/.github/workflows/minify.yml@<sha> # v3.0.0

     deploy:
       needs: [lint-and-test, minify]
   ```

2. On the `uses: Apeify/ci/actions/deploy` step, add:

   ```yaml
   minified-assets: ${{ needs.minify.outputs.minified-assets }}
   ```

3. If the deploy step sets `public-dir`, set the same value under `with:` on the `minify` job. A
   mismatch refuses the deploy rather than shipping the wrong files.
4. Make the same three changes in `deploy-dr.yml`, if you have one.
5. Optional but recommended: delete `secrets: inherit` from `.github/workflows/promote.yml`. It
   was never needed, and it handed every repository and organization secret to shared code.

All three `uses: Apeify/ci` lines in a stub must name the same release. `minify.yml` and the
deploy action share a contract, and a mismatched pair fails on it.

Not supported any more: CSS or JS generated inside the deploy job, by a step between checkout and
the deploy action. The minify job never sees it, so the deploy refuses it as missing from the
artifact. See [README.md](README.md#minification).

### Security

- **Minification moved out of the deploy job.** Running `esbuild` before the SSH key was written
  protected nothing: a job's secrets are in the runner's memory from the first step, and any step
  can read that memory. The new [`minify.yml`](.github/workflows/minify.yml) runs on its own VM
  with no environment and no secrets.
- **The deploy treats the minified files as untrusted.** It fetches the artifact by ID rather than
  by name, and refuses to deploy unless the artifact holds exactly the CSS and JS its own checkout
  has, every entry is a regular file, and a digest binding each minified file to its exact source
  matches. JS must still parse and no file may collapse to nothing.
- **`secrets: inherit` removed from the example promote stub.** `promote.yml` only needs
  `GITHUB_TOKEN`, which GitHub grants every called workflow automatically.

### Added

- [`minify.yml`](.github/workflows/minify.yml), a reusable workflow with a `public-dir` input and a
  `minified-assets` output.
- A required `minified-assets` input on `actions/deploy`.
- `run-name` in the deploy stub, so the Actions tab reads "Deploy site to production" or "Deploy
  site to staging" instead of the same name for every run.
- This changelog.

### Changed

- The example stubs ship SHA-pinned with a version comment instead of tracking `@main`.
- The example stubs leave `app-excludes` commented out, since the right list differs per site.
- The docs explain why several web roots share one `SITE_URL`.

## [2.1.0] - 2026-09-04

No action required.

### Added

- Sixteen outputs on `actions/deploy`, so a later step in the deploy job can act on what the deploy
  did without scraping the log: `deployed-sha`, `pipeline-ref`, `web-roots`, `web-root-count`,
  `app-deployed`, `app-remote-dir`, `changed`, `public-changed`, `app-changed`,
  `files-transferred`, `bytes-transferred`, `paths-deleted`, `host-key-pinned`, `started-at`,
  `finished-at` and `duration-seconds`. See [README.md](README.md#outputs).

### Fixed

- **`deploy-app-dir` must be exactly `true` or `false`.** GitHub's `==` is case-insensitive and
  the shell's is not, so `True` made the app sync run while the preflight skipped every app-dir
  check - which could publish the private tree over HTTP. Any other spelling is now refused.
- **Web root names may not contain a double quote or a backslash.** Either would have produced a
  `web-roots` output that a consumer's `fromJSON()` rejects or misreads.
- The action-metadata check no longer rejects hyphenated step ids such as `public-sync`.

Neither refusal affects a correctly configured site, which is why this is a minor release.

## [2.0.0] - 2026-09-03

The deploy half became a composite action, so it works for a site repo owned by a different account
from Apeify/ci.

### Migrating from 1.x

Required. `.github/workflows/deploy.yml` no longer exists in this repo, so an unmigrated stub fails
with "workflow was not found".

1. Rewrite the one-job deploy stub as two jobs: a `lint-and-test` job calling
   `.github/workflows/lint-and-test.yml`, and a `deploy` job that declares
   `environment: ${{ needs.lint-and-test.outputs.environment }}`, runs `actions/checkout` with
   `fetch-depth: 0`, and then calls `Apeify/ci/actions/deploy`. Copy the stub from
   [README.md](README.md#the-deploy-stub) rather than editing the old one.
2. Pass the credentials to the action explicitly (`ssh-key`, `host`, `user`, `base-dir`, and
   optionally `port` and `host-key`) from `secrets.*`, plus `web-root-dirs` from
   `vars.WEB_ROOT_DIRS`, `environment` and `attestation` from the `lint-and-test` job's outputs.
3. Remove `secrets: inherit` from the deploy stub.

### Fixed

- **Cross-owner consumers received no secrets.** `secrets: inherit` only carries secrets within one
  organization or enterprise, so a site under a different account deployed with every credential
  empty. The deploy now runs inside the consumer's own job, which reads its environment secrets
  directly.
- **Every consumer failed to load the action.** An input description contained a
  `${{ vars.* }}` expression, which GitHub evaluates in action metadata against a context set that
  excludes `vars`. A new check rejects expressions in action metadata.
- **`deploy-app-dir: 'false'` still ran the app sync.** Composite inputs are strings, and the old
  truthiness test read `'false'` as true. It is now compared against the string `'true'`.
- **An empty `environment` input skipped both production refusals.** It is now refused instead of
  defaulted.

### Changed

- The branch-to-environment mapping is resolved once, in `lint-and-test.yml`, and published as an
  output for the stub to use.
- The action no longer checks out the repository itself, so it no longer wipes anything the
  caller built before it ran.

## [1.0.0] - 2026-08-31

First release: a reusable `deploy.yml` workflow (lint and test, then rsync over SSH to one or more
web roots), the `promote.yml` publish button, and example stubs.

[3.1.0]: https://github.com/Apeify/ci/releases/tag/v3.1.0
[3.0.1]: https://github.com/Apeify/ci/releases/tag/v3.0.1
[3.0.0]: https://github.com/Apeify/ci/releases/tag/v3.0.0
[2.1.0]: https://github.com/Apeify/ci/releases/tag/v2.1.0
[2.0.0]: https://github.com/Apeify/ci/releases/tag/v2.0.0
[1.0.0]: https://github.com/Apeify/ci/releases/tag/v1.0.0
