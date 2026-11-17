import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

// V1-009 (IOS-02, REL-03, REL-16, REL-18) and V1-012 (REL-06).
//
// `ios-signed-release` is the App Store path. It must carry every guarantee of
// the internal-only `ios-signed` workflow, differ from it only where a store
// build has to (branch pattern, export options, build-number resolution), and
// never submit anything for review by itself. `ios-signed` must keep behaving
// as it does today. Scripts are compared after removing comment and blank
// lines, so a reworded comment is fine but a changed command is not.

const root = process.cwd(); // the gate runs node tests from the repo root
const yaml = readFileSync(join(root, "codemagic.yaml"), "utf8");

// Minimal structural parse of the shapes this file uses: workflows are the
// 2-space keys under `workflows:`; steps are `      - name:` items; a step's
// script is either `script: <one line>` or a `script: |` literal block whose
// lines are indented 10 spaces.
function parse(src) {
  const workflows = {};
  let wf = null;
  let step = null;
  let inScript = false;
  for (const line of src.split("\n")) {
    const w = line.match(/^  ([A-Za-z0-9_-]+):\s*$/);
    if (w) {
      wf = { name: w[1], lines: [], steps: [] };
      workflows[w[1]] = wf;
      step = null;
      inScript = false;
      continue;
    }
    if (!wf) continue;
    wf.lines.push(line);
    const s = line.match(/^      - name:\s*(.*)$/);
    if (s) {
      step = { name: s[1].trim(), wd: "", script: [], keys: [] };
      wf.steps.push(step);
      inScript = false;
      continue;
    }
    if (!step) continue;
    if (inScript) {
      if (line.trim() === "" || line.startsWith("          ")) {
        step.script.push(line.slice(10));
        continue;
      }
      inScript = false;
    }
    if (/^ {0,5}\S/.test(line) || /^      - /.test(line)) {
      step = null;
      continue;
    }
    const k = line.match(/^        ([a-z_]+):\s*(.*)$/);
    if (k) {
      step.keys.push(k[1]);
      if (k[1] === "working_directory") step.wd = k[2];
      if (k[1] === "script") {
        if (k[2] === "|") inScript = true;
        else step.script.push(k[2]);
      }
    }
  }
  for (const f of Object.values(workflows)) {
    f.text = f.lines.join("\n");
    for (const st of f.steps) {
      while (st.script.length && st.script.at(-1).trim() === "") st.script.pop();
      st.text = st.script.join("\n");
    }
  }
  return workflows;
}

const workflows = parse(yaml);
const RELEASE = "ios-signed-release";
const INTERNAL = "ios-signed";
const SIDELOAD = "ios-unsigned-sideload";

const steps = (wf) => {
  assert.ok(workflows[wf], `workflow ${wf} missing`);
  return workflows[wf].steps;
};
const indexOf = (wf, prefix) => steps(wf).findIndex((s) => s.name.startsWith(prefix));
const step = (wf, prefix) => {
  const found = steps(wf).filter((s) => s.name.startsWith(prefix));
  assert.equal(found.length, 1, `${wf}: expected exactly one step "${prefix}…"`);
  return found[0];
};
const normalize = (text) =>
  text
    .split("\n")
    .map((l) => l.replace(/\s+$/, ""))
    .filter((l) => l.trim() !== "" && !l.trim().startsWith("#"))
    .join("\n");
const pycode = (text) => {
  const m = text.match(/<<'PYCODE'\n([\s\S]*?)\nPYCODE/);
  assert.ok(m, "expected a PYCODE heredoc");
  return m[1];
};

const GATE = "Canonical gates (tools/ci_gates.sh, strict)";
const REVISION = "Verify approved immutable CI revision";
const XCTEST = "iOS native unit tests (RunnerTests on a simulator)";
const PROFILES = "Set up provisioning profiles";
const ASSERT = "Assert production Supabase config";
const ADMOB = "Materialise AdMob release config (native)";
const BUILD = "Build signed IPA";
const STAMP = "Resolve, stamp, and verify the EXACT signed IPA";
const SIGNING = "Verify distribution signing and entitlements of the EXACT signed IPA";
const BUILD_NUMBER = "Resolve next iOS build number from App Store Connect";
const INTERNAL_ONLY = ` --custom-export-options='{"testFlightInternalTestingOnly": true}'`;

test("parser sanity: the iOS workflows and their steps are found", () => {
  assert.ok(steps(INTERNAL).length >= 9);
  assert.ok(steps(RELEASE).length >= 10);
  assert.match(step(RELEASE, GATE).text, /REQUIRE_ALL_GATES=1 bash tools\/ci_gates\.sh/);
});

test("store workflow: revision check, strict gate and XCTests all precede signing and the build", () => {
  const order = [REVISION, "Flutter pub get", BUILD_NUMBER, GATE, XCTEST, PROFILES, ASSERT, ADMOB, BUILD, STAMP, SIGNING]
    .map((p) => [p, indexOf(RELEASE, p)]);
  for (const [p, i] of order) assert.ok(i > -1, `${RELEASE} lost "${p}"`);
  assert.equal(order[0][1], 0, "the revision check must be the first step");
  for (let i = 1; i < order.length; i++) {
    assert.ok(order[i - 1][1] < order[i][1], `"${order[i - 1][0]}" must run before "${order[i][0]}"`);
  }
});

test("shared steps are identical to the vetted ios-signed workflow", () => {
  for (const p of [GATE, ASSERT, ADMOB, BUILD]) {
    assert.equal(normalize(step(RELEASE, p).text), normalize(step(INTERNAL, p).text), `"${p}" drifted`);
  }
  // Production backend identity, not just non-empty values.
  assert.match(step(RELEASE, ASSERT).text, /\[ "\$\{SUPABASE_URL:-\}" = "https:\/\/[a-z0-9]+\.supabase\.co" \]/);

  // Profiles: identical verification; only the internal-only export differs.
  const internalProfiles = normalize(step(INTERNAL, PROFILES).text);
  assert.ok(internalProfiles.includes(INTERNAL_ONLY), "ios-signed must stay internal-only");
  assert.equal(normalize(step(RELEASE, PROFILES).text), internalProfiles.replace(INTERNAL_ONLY, ""));

  // Stamp step: ios-signed's commands up to the hash; the signing check is
  // the next step with the byte-identical Python verifier.
  const internalStamp = normalize(step(INTERNAL, STAMP).text);
  const cut = internalStamp.indexOf("python3 - \"$IPA\"");
  assert.ok(cut > 0);
  assert.equal(normalize(step(RELEASE, STAMP).text), internalStamp.slice(0, cut).trimEnd());
  assert.equal(pycode(step(RELEASE, SIGNING).text), pycode(step(INTERNAL, STAMP).text));
  assert.match(step(RELEASE, SIGNING).text, /shasum -a 256 -c "\$\{IPA\}\.sha256"/,
    "the signing check must first prove it reads the stamped bytes");
  for (const s of [step(RELEASE, STAMP), step(RELEASE, SIGNING)]) assert.equal(s.wd, "app");
});

test("store export is App Store–eligible; ios-signed stays internal-only", () => {
  assert.ok(!normalize(workflows[RELEASE].text).includes("testFlightInternalTestingOnly"),
    "an internal-only export can never be submitted for external testing or review");
  assert.ok(workflows[INTERNAL].text.includes(`xcode-project use-profiles${INTERNAL_ONLY}`));
});

test("revision check: release/* branch pattern, otherwise identical to ios-signed", () => {
  const release = normalize(step(RELEASE, REVISION).text);
  const internal = normalize(step(INTERNAL, REVISION).text);
  const branchLine = '[ "${CM_BRANCH:-}" = "release/ios-beta1-personal-20261013" ]';
  assert.ok(internal.includes(branchLine), "ios-signed keeps its exact branch");
  assert.ok(!release.includes("ios-beta1-personal"));
  const releaseBranchCheck = [
    'case "${CM_BRANCH:-}" in',
    "  release/*) ;;",
    '  *) echo "ERROR: store builds run only from a release/* branch."; exit 1 ;;',
    "esac",
  ].join("\n");
  assert.equal(release, internal.replace(branchLine, releaseBranchCheck));
});

// Runs the store revision step in a synthetic clean git repository.
function runRevisionCheck(env, { dirty = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "qirsh-revision-"));
  try {
    const files = [
      "app/lib/main.dart",
      "app/lib/core/backend/supabase_config.dart",
      "app/lib/features/onboarding/auth_screen.dart",
      "app/ios/Runner/Runner.entitlements",
      "app/ios/ShareBankMessage/ShareBankMessage.entitlements",
    ];
    for (const f of files) {
      mkdirSync(join(dir, f, ".."), { recursive: true });
      writeFileSync(join(dir, f), "synthetic\n");
    }
    const git = (...args) => spawnSync("git", ["-c", "user.name=t", "-c", "user.email=t@example.invalid", ...args], { cwd: dir, encoding: "utf8" });
    git("init", "-q");
    git("add", ".");
    git("commit", "-q", "-m", "synthetic");
    const head = git("rev-parse", "HEAD").stdout.trim();
    if (dirty) writeFileSync(join(dir, files[0]), "changed\n");
    const resolved = Object.fromEntries(Object.entries(env).map(([k, v]) => [k, v === "HEAD" ? head : v]));
    return spawnSync("bash", ["-c", step(RELEASE, REVISION).text], {
      cwd: dir,
      encoding: "utf8",
      env: { PATH: process.env.PATH, HOME: process.env.HOME, ...resolved },
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("revision check behavior: fail-closed unless release/* + reviewed SHA + clean tree", () => {
  const ok = { CM_BRANCH: "release/v1.0.0", CM_COMMIT: "HEAD", EXPECTED_REVIEWED_CI_SHA: "HEAD" };
  assert.equal(runRevisionCheck(ok).status, 0, "the approved revision must pass");
  assert.notEqual(runRevisionCheck({ ...ok, CM_BRANCH: "main" }).status, 0);
  assert.notEqual(runRevisionCheck({ ...ok, CM_BRANCH: "release-readiness/v1" }).status, 0);
  const { EXPECTED_REVIEWED_CI_SHA: _, ...unset } = ok;
  const r = runRevisionCheck(unset);
  assert.notEqual(r.status, 0, "an unset reviewed SHA must fail");
  assert.match(r.stderr, /Set the independently reviewed full CI commit SHA/);
  assert.notEqual(runRevisionCheck({ ...ok, CM_COMMIT: "0".repeat(40) }).status, 0);
  assert.notEqual(runRevisionCheck({ ...ok, EXPECTED_REVIEWED_CI_SHA: "abc" }).status, 0);
  assert.notEqual(runRevisionCheck(ok, { dirty: true }).status, 0);
});

// REL-18: run the store build-number step with a stubbed App Store Connect CLI.
function runBuildNumber({ forVersion, anyVersion }) {
  const dir = mkdtempSync(join(tmpdir(), "qirsh-asc-"));
  try {
    const bin = join(dir, "bin");
    mkdirSync(bin);
    const stub = (res) =>
      res === "fail" ? 'echo "No builds found" >&2; exit 1' : `printf '%s\\n' '${res}'`;
    writeFileSync(join(bin, "app-store-connect"), [
      "#!/usr/bin/env bash",
      'case "$1" in',
      `  apps) printf '%s\\n' '[{"id": "1234567890"}]' ;;`,
      "  get-latest-build-number)",
      '    case " $* " in',
      `      *" --version-string "*) ${stub(forVersion)} ;;`,
      `      *) ${stub(anyVersion)} ;;`,
      "    esac ;;",
      "  *) exit 2 ;;",
      "esac",
      "",
    ].join("\n"));
    chmodSync(join(bin, "app-store-connect"), 0o755);
    const cmEnv = join(dir, "cm_env");
    writeFileSync(cmEnv, "");
    const r = spawnSync("bash", ["-c", step(RELEASE, BUILD_NUMBER).text], {
      cwd: root,
      encoding: "utf8",
      env: { PATH: `${bin}:${process.env.PATH}`, HOME: process.env.HOME, CM_ENV: cmEnv },
    });
    const number = readFileSync(cmEnv, "utf8").match(/^IOS_BUILD_NUMBER=(\d+)$/m)?.[1];
    return { status: r.status, number: number ? Number(number) : null, out: r.stdout + r.stderr };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("REL-18: a marketing version with no builds yet continues from the app's latest build", () => {
  const failing = runBuildNumber({ forVersion: "fail", anyVersion: "147" });
  assert.equal(failing.status, 0, failing.out);
  assert.equal(failing.number, 148);
  const empty = runBuildNumber({ forVersion: "", anyVersion: "147" });
  assert.equal(empty.status, 0, empty.out);
  assert.equal(empty.number, 148);
});

test("REL-18: the build number exceeds both the version's and the app's latest build", () => {
  assert.equal(runBuildNumber({ forVersion: "150", anyVersion: "149" }).number, 151);
  assert.equal(runBuildNumber({ forVersion: "12", anyVersion: "147" }).number, 148);
});

test("REL-18: an unusable App Store Connect answer fails clearly and exports nothing", () => {
  for (const c of [
    { forVersion: "147", anyVersion: "fail" },
    { forVersion: "147", anyVersion: "" },
    { forVersion: "abc", anyVersion: "147" },
  ]) {
    const r = runBuildNumber(c);
    assert.notEqual(r.status, 0, JSON.stringify(c));
    assert.equal(r.number, null, `no build number may be exported for ${JSON.stringify(c)}`);
    assert.match(r.out, /ERROR:/);
  }
});

test("V1-012: RunnerTests run on a simulator, mandatory, in both non-internal iOS workflows", () => {
  const a = step(RELEASE, XCTEST);
  const b = step(SIDELOAD, XCTEST);
  assert.equal(a.text, b.text, "the XCTest stage must be the same in both workflows");
  assert.equal(a.wd, "app/ios");
  assert.match(a.text, /^set -eu$/m);
  assert.match(a.text, /xcodebuild test \\\n\s+-workspace Runner\.xcworkspace \\\n\s+-scheme Runner \\\n\s+-only-testing:RunnerTests \\/);
  assert.match(a.text, /-destination "platform=iOS Simulator,id=\$SIM_ID"/);
  for (const s of [a, b]) {
    assert.ok(!/\|\|\s*true/.test(s.text), "the XCTest stage must not be softened");
    assert.ok(!s.keys.includes("ignore_failure") && !s.keys.includes("allow_failure"));
    assert.ok(!/\$\{?[A-Z_]*(RUN|ENABLE|SKIP)[A-Z_]*/.test(s.text), "no opt-in or skip variable");
  }
  assert.ok(indexOf(SIDELOAD, GATE) < indexOf(SIDELOAD, XCTEST));
  assert.ok(indexOf(SIDELOAD, XCTEST) < indexOf(SIDELOAD, "Build unsigned iOS"));
});

test("publishing uploads the verified IPA but never submits for review", () => {
  const pub = (wf) => {
    const t = normalize(workflows[wf].text);
    return t.slice(t.indexOf("\n    publishing:"));
  };
  for (const wf of [RELEASE, INTERNAL]) {
    const p = pub(wf);
    assert.match(p, /\n      app_store_connect:\n        auth: integration\n        submit_to_testflight: false(\n|$)/, wf);
    assert.ok(!/submit_to_testflight:\s*true/.test(p), `${wf} must not request external beta review`);
    assert.ok(!/submit_to_app_store/.test(p), `${wf} must not submit for App Review`);
    assert.ok(!/beta_groups/.test(p), `${wf} must not distribute to external testers`);
    assert.ok(!/^    triggering:/m.test(workflows[wf].text), `${wf} must stay manual`);
  }
});

test("store artifacts include the IPA, provenance, hashes and verification records", () => {
  for (const a of [
    "$IOS_RELEASE_IPA",
    "${IOS_RELEASE_IPA}.provenance",
    "${IOS_RELEASE_IPA}.verification.txt",
    "${IOS_RELEASE_IPA}.sha256",
    "${IOS_RELEASE_IPA}.signing-verification.txt",
  ]) {
    assert.ok(workflows[RELEASE].text.includes(`\n      - ${a}\n`), `${RELEASE} must collect ${a}`);
  }
});

test("ios-signed keeps its current behavior", () => {
  const t = workflows[INTERNAL].text;
  assert.ok(t.includes('IOS_BUILD_NUMBER_FLOOR: "146"'));
  assert.ok(!t.includes(XCTEST), "ios-signed is frozen; the XCTest stage is not added there");
  assert.deepEqual(
    steps(INTERNAL).map((s) => s.name),
    [REVISION, "Flutter pub get", BUILD_NUMBER, `${GATE} — REQUIRED before signing`, PROFILES, ASSERT, ADMOB, BUILD,
      `${STAMP} — REQUIRED before submit`],
  );
  const resolve = step(INTERNAL, BUILD_NUMBER).text;
  assert.ok(resolve.includes('--version-string "$MARKETING_VERSION"'));
  assert.ok(resolve.includes("IOS_BUILD_NUMBER=$((LATEST_BUILD_NUMBER + 1))"));
});
