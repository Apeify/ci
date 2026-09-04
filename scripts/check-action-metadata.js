// Reject GitHub expressions in composite action METADATA.
//
// WHY THIS EXISTS
//
// `${{ }}` is evaluated everywhere in an action file, including input and output
// DESCRIPTIONS, and the contexts available inside `runs:` are not available in
// metadata. So a description that merely mentions an expression takes the whole
// action down at load time, before any step runs. This shipped:
//
//   web-root-dirs:
//     description: >-
//       ... Pass `[expression]`. It is an input rather than read from vars
//       because a composite action cannot access that context at all.
//
// and every consumer failed with `Unrecognized named-value: 'vars'`. The
// sentence explaining that `vars` was unavailable was itself unavailable.
//
// WHY NOTHING ELSE CATCHES IT
//
// actionlint cannot read composite actions at all. validate.yml's extractor
// checks `runs.using` and `shell:`, but a description containing an expression
// is perfectly valid YAML. The test suite drives extracted shell and never sees
// metadata. This class had zero coverage, which is how it reached a deploy.
//
// WHY THIS PARSES THE YAML
//
// The first version scanned lines: metadata was "everything above `^runs:`" and
// expressions were allowed on any line matching `^    value: `. Every one of
// those assumptions was wrong, and a review found four bypasses and three false
// positives in it:
//
//   * YAML mappings are UNORDERED. Putting `outputs:` after `runs:` - the
//     natural order, since output values reference step ids - hid a fatal
//     expression completely.
//   * A block scalar line reading `  value: ${{ ... }}` inside a description
//     was exempted, so a usage example in an action's own docs sailed through.
//   * Greedy matching read only the LAST expression on a line, so
//     `${{ vars.NOPE }}-${{ steps.s.outputs.x }}` passed.
//   * A legitimate `value: >-` with the expression on the next line was
//     REJECTED, as was any four-space-indented action, as was any output using
//     `fromJSON()` or `format()`.
//
// Structure cannot be recovered from line shapes. This walks the parsed
// document instead, which costs a js-yaml dependency and is worth it.

'use strict';

const fs = require('fs');
const path = require('path');

// Contexts a composite action can actually resolve in `outputs.<name>.value`.
// `vars`, `secrets` and `needs` are the ones that look plausible and are not.
const ALLOWED = new Set([
  'steps', 'inputs', 'github', 'env', 'runner', 'job', 'strategy', 'matrix',
]);

const EXPRESSION = /\$\{\{/;

let yaml;
try {
  yaml = require(process.argv[2] || 'js-yaml');
} catch (e) {
  console.log(`::error::Could not load js-yaml (${e.message}). Pass its path as the first argument.`);
  process.exit(1);
}

let failed = false;
let checked = 0;

// Every string reachable under `node`, with a dotted path for the message.
function* strings(node, trail) {
  if (typeof node === 'string') {
    yield [trail, node];
  } else if (Array.isArray(node)) {
    for (const [i, v] of node.entries()) yield* strings(v, `${trail}[${i}]`);
  } else if (node && typeof node === 'object') {
    for (const [k, v] of Object.entries(node)) yield* strings(v, trail ? `${trail}.${k}` : k);
  }
}

// The context each `${{ ... }}` reference starts with. A context is a bare word
// followed by a dot, so `fromJSON(steps.s.outputs.json).name` yields `steps`
// and not `fromJSON` - the function name is followed by `(`, and `).name` has
// no word before the dot. Single-quoted literals are stripped first so
// `format('a.b', steps.x)` does not report a phantom `a`.
function contextsIn(expression) {
  const withoutLiterals = expression.replace(/'(?:[^']|'')*'/g, "''");
  const found = new Set();
  for (const m of withoutLiterals.matchAll(/(?:^|[^\w.])([A-Za-z_][\w-]*)\s*\./g)) {
    found.add(m[1]);
  }
  return found;
}

for (const dir of fs.existsSync('actions') ? fs.readdirSync('actions') : []) {
  for (const name of ['action.yml', 'action.yaml']) {
    const file = path.join('actions', dir, name);
    if (!fs.existsSync(file)) continue;
    checked++;

    let doc;
    try {
      doc = yaml.load(fs.readFileSync(file, 'utf8'));
    } catch (e) {
      console.log(`::error file=${file}::YAML parse failed: ${e.message}`);
      failed = true;
      continue;
    }
    if (!doc || typeof doc !== 'object') {
      console.log(`::error file=${file}::Not a YAML mapping.`);
      failed = true;
      continue;
    }

    // Metadata is everything that is not `runs`, whatever order the keys appear
    // in. outputs.<name>.value is handled separately below: it is the one place
    // in metadata where an expression belongs.
    const metadata = {};
    for (const [k, v] of Object.entries(doc)) {
      if (k !== 'runs') metadata[k] = v;
    }
    for (const [trail, value] of strings(metadata, '')) {
      if (/^outputs\.[^.]+\.value$/.test(trail)) continue;
      if (!EXPRESSION.test(value)) continue;
      console.log(
        `::error file=${file}::Expression in action metadata at '${trail}'. ` +
        'GitHub evaluates these at load time against a context set that excludes ' +
        'vars, secrets and needs, so this fails the whole action before any step ' +
        'runs. Name the variable instead of showing the expression.'
      );
      failed = true;
    }

    for (const [outName, out] of Object.entries(doc.outputs || {})) {
      const value = out && out.value;
      if (typeof value !== 'string') continue;
      for (const m of value.matchAll(/\$\{\{(.*?)\}\}/gs)) {
        for (const ctx of contextsIn(m[1])) {
          if (ALLOWED.has(ctx)) continue;
          console.log(
            `::error file=${file}::outputs.${outName}.value uses the '${ctx}' context, ` +
            `which a composite action cannot resolve. Allowed: ${[...ALLOWED].join(', ')}.`
          );
          failed = true;
        }
      }
    }
  }
}

if (checked === 0) {
  console.log('::error::No action.yml found under actions/ - the glob is wrong, or actions/ moved.');
  process.exit(1);
}

if (failed) process.exit(1);
console.log(`${checked} action file(s): no expressions in metadata.`);
