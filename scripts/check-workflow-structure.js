// Layer 1 of this repo's checks: the structural floor.
//
// Parses every workflow, every example, and every composite action as YAML,
// and writes each `run:` block out as its own script so the caller can check
// it parses as bash. It covers the two failure classes that have actually
// broken this code: a file that stops parsing after an indentation slip, and
// a `run:` block whose shell is broken and stays invisible until it executes
// on a live deploy.
//
// For a composite action it also checks what nothing else can, because
// actionlint cannot read one at all: that `runs.using` is "composite", and
// that every `run:` step declares a `shell:` - GitHub rejects one without it,
// but only when the step runs.
//
// GitHub expressions are replaced with a plain identifier before a block is
// written. `${{ ... }}` is not shell - bash reads `${{` as a parameter
// expansion with an invalid name - so leaving them in would produce failures
// that say nothing about the actual script.
//
// Run by scripts/check-workflow-structure.sh, from the repository root:
//
//   node scripts/check-workflow-structure.js <js-yaml dir> <output dir>
//
// Arguments:
//   js-yaml dir   The installed js-yaml package to load. Resolved by the
//                 wrapper, so a bare clone gets an instruction, not a trace.
//   output dir    Existing directory to write one <file>__<job>__<step>.sh
//                 per `run:` block into.
//
// Exits 1, with ::error:: annotations, when any file fails to parse, an
// action breaks the rules above, or nothing at all was found - an extractor
// that finds nothing is a broken extractor, not a clean repo.

const fs = require('fs');
const path = require('path');
const yaml = require(process.argv[2]);
const outDir = process.argv[3];

const dir = '.github/workflows';
let extracted = 0;
let failed = false;

for (const file of fs.readdirSync(dir).filter(f => /\.ya?ml$/.test(f)).sort()) {
  const full = path.join(dir, file);
  let doc;
  try {
    doc = yaml.load(fs.readFileSync(full, 'utf8'));
  } catch (e) {
    console.log(`::error file=${full}::YAML parse failed: ${e.message}`);
    failed = true;
    continue;
  }
  console.log(`parsed ${full}`);

  for (const [jobName, job] of Object.entries(doc.jobs || {})) {
    for (const [i, step] of (job.steps || []).entries()) {
      if (!step.run) continue;
      const body = step.run.replace(/\$\{\{[^}]*\}\}/g, 'GH_EXPR');
      const label = (step.name || `step${i}`).replace(/[^A-Za-z0-9]+/g, '_');
      const out = `${outDir}/${path.parse(file).name}__${jobName}__${label}.sh`;
      fs.writeFileSync(out, '#!/usr/bin/env bash\n' + body);
      extracted++;
    }
  }
}

// Parse everything under examples/ too, at both levels, without
// extracting from it.
//
// The stubs in examples/workflows/ reach actionlint via
// scripts/lint-workflows.sh,
// but examples/dependabot.yml deliberately does not - actionlint
// rejects a Dependabot config outright - which left the one copyable
// artifact in the repo with no syntax coverage at all. A YAML parse is
// not a schema check, but it catches the failure that matters for a
// file people copy: one that does not load.
let examplesParsed = 0;
for (const dir of ['examples', 'examples/workflows']) {
  if (!fs.existsSync(dir)) continue;
  for (const file of fs.readdirSync(dir).filter(f => /\.ya?ml$/.test(f)).sort()) {
    const full = path.join(dir, file);
    try {
      yaml.load(fs.readFileSync(full, 'utf8'));
    } catch (e) {
      console.log(`::error file=${full}::YAML parse failed: ${e.message}`);
      failed = true;
      continue;
    }
    console.log(`parsed ${full}`);
    examplesParsed++;
  }
}

// Composite actions too, and this is not a nicety: actionlint parses
// action.yml as a workflow and reports nonsense, so it provides NO
// schema check for the deploy half of the pipeline. Its shell lives in
// actions/deploy/scripts/ and is shellchecked and tested there; this
// is what checks the YAML around it.
//
// Steps live under runs.steps rather than jobs.<id>.steps.
let actionsParsed = 0;
for (const dir of fs.existsSync('actions') ? fs.readdirSync('actions') : []) {
  for (const name of ['action.yml', 'action.yaml']) {
    const full = path.join('actions', dir, name);
    if (!fs.existsSync(full)) continue;
    let doc;
    try {
      doc = yaml.load(fs.readFileSync(full, 'utf8'));
    } catch (e) {
      console.log(`::error file=${full}::YAML parse failed: ${e.message}`);
      failed = true;
      continue;
    }
    console.log(`parsed ${full}`);
    actionsParsed++;

    if (!doc.runs || doc.runs.using !== 'composite') {
      console.log(`::error file=${full}::runs.using is not "composite".`);
      failed = true;
      continue;
    }
    for (const [i, step] of (doc.runs.steps || []).entries()) {
      if (!step.run) continue;
      // GitHub rejects a composite run step with no explicit shell, and
      // it is the kind of omission that only surfaces at run time.
      if (!step.shell) {
        console.log(`::error file=${full}::step "${step.name || i}" has run: but no shell:.`);
        failed = true;
      }
      const body = step.run.replace(/\$\{\{[^}]*\}\}/g, 'GH_EXPR');
      const label = (step.name || `step${i}`).replace(/[^A-Za-z0-9]+/g, '_');
      fs.writeFileSync(`${outDir}/action__${dir}__${label}.sh`, '#!/usr/bin/env bash\n' + body);
      extracted++;
    }
  }
}

if (fs.existsSync('actions') && actionsParsed === 0) {
  console.log('::error::actions/ exists but no action.yml was parsed - the filter is wrong.');
  process.exit(1);
}

console.log(`extracted ${extracted} run-step(s)`);
if (examplesParsed === 0) {
  console.log('::error::No examples were parsed - examples/ moved, or the filter is wrong.');
  process.exit(1);
}
if (failed) process.exit(1);
if (extracted === 0) {
  console.log('::error::No run-steps were extracted - the extractor is probably broken.');
  process.exit(1);
}
