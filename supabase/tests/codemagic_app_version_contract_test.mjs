import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

// REL-04 / AND-04 — every release build must compile a NON-EMPTY APP_VERSION.
// A present-but-empty define beats the app's compiled fallback, so a path that
// does not resolve (e.g. `app/pubspec.yaml` read from `working_directory: app`)
// silently ships `X-App-Version: ''`. `set -e` cannot catch a failing command
// substitution inside an argument, so the define must reference a variable that
// was checked non-empty with a hard failure before the build.

const root = process.cwd(); // the gate runs node tests from the repo root
const yaml = readFileSync(join(root, "codemagic.yaml"), "utf8");

// Minimal structural parse: workflows (2-space keys under `workflows:`) and their
// script steps (`      - name:`), each with its working_directory and body.
function parseSteps(src) {
  const workflows = [];
  let wf = null;
  let step = null;
  for (const line of src.split("\n")) {
    const w = line.match(/^  ([A-Za-z0-9_-]+):\s*$/);
    if (w) {
      wf = { name: w[1], steps: [] };
      workflows.push(wf);
      step = null;
      continue;
    }
    const s = line.match(/^      - name:\s*(.*)$/);
    if (s && wf) {
      step = { name: s[1], wd: "", body: [] };
      wf.steps.push(step);
      continue;
    }
    if (!step) continue;
    if (/^ {0,5}\S/.test(line)) { step = null; continue; } // left the step list
    const d = line.match(/^        working_directory:\s*(\S+)/);
    if (d) step.wd = d[1];
    step.body.push(line);
  }
  for (const f of workflows) for (const st of f.steps) st.text = st.body.join("\n");
  return workflows;
}

const workflows = parseSteps(yaml);
const guard = (v) =>
  new RegExp(`\\[ -n "\\$\\{?${v}\\}?" \\] \\|\\| \\{[\\s\\S]*?exit 1`);

test("every pubspec.yaml read resolves from its step's working_directory", () => {
  let reads = 0;
  for (const wf of workflows) {
    for (const st of wf.steps) {
      for (const m of st.text.matchAll(/sed -n '[^']*' (\S*pubspec\.yaml)/g)) {
        reads++;
        const p = join(root, st.wd, m[1]);
        assert.ok(
          existsSync(p),
          `${wf.name} › "${st.name}" reads ${m[1]} from working_directory ` +
            `'${st.wd || "."}', which resolves to a missing file (${p})`,
        );
      }
    }
  }
  assert.ok(reads > 0, "expected at least one pubspec version read");
});

test("every APP_VERSION define references a variable proven non-empty before the build", () => {
  let defines = 0;
  for (const wf of workflows) {
    wf.steps.forEach((st, i) => {
      for (const m of st.text.matchAll(/--dart-define=APP_VERSION=(\S*)/g)) {
        defines++;
        const where = `${wf.name} › "${st.name}"`;
        const v = m[1].match(/^"\$\{?([A-Z_][A-Z0-9_]*)\}?"$/);
        assert.ok(
          v,
          `${where}: APP_VERSION must be a quoted variable, not ${m[1]} — an ` +
            `inline command substitution that fails defines an EMPTY version`,
        );
        const name = v[1];
        const sameStep =
          new RegExp(`^\\s*${name}=`, "m").test(st.text) && guard(name).test(st.text);
        const earlier = wf.steps.slice(0, i).some((p) =>
          new RegExp(`${name}=`).test(p.text) &&
          /"\$CM_ENV"/.test(p.text) &&
          /\[ -n "\$\{?[A-Z_]+\}?" \] \|\| \{[\s\S]*?exit 1/.test(p.text)
        );
        assert.ok(
          sameStep || earlier,
          `${where}: \$${name} is not checked non-empty (with exit 1) in this ` +
            `step or exported by a guarded earlier step of the same workflow`,
        );
      }
    });
  }
  assert.ok(defines >= 4, `expected the release workflows' APP_VERSION defines, found ${defines}`);
});
