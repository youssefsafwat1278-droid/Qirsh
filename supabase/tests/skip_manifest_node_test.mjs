import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";

// Phase-7 Batch-1 — the skip/ignore manifest checker (tools/check_test_skips.mjs) must
// FAIL on an unexpected skip, an expected skip that disappeared, and partial/malformed
// credentials. Runs the checker as a subprocess (no recursion into node --test).

const root = process.cwd();
const checker = join(root, "tools/check_test_skips.mjs");

function runChecker({ tap, deno, env = {} }) {
  const dir = mkdtempSync(join(tmpdir(), "skipman-"));
  const args = [];
  if (tap != null) {
    const p = join(dir, "node.tap");
    writeFileSync(p, tap);
    args.push("--node", p);
  }
  if (deno != null) {
    const p = join(dir, "deno.txt");
    writeFileSync(p, deno);
    args.push("--deno", p);
  }
  return spawnSync("node", [checker, ...args], {
    cwd: root,
    encoding: "utf8",
    // Start from a clean credential env, then apply overrides.
    env: {
      ...process.env,
      SUPABASE_URL: "",
      SUPABASE_ANON_KEY: "",
      SUPABASE_SERVICE_ROLE_KEY: "",
      LOCAL_SUPABASE_URL: "",
      LOCAL_SUPABASE_ANON_KEY: "",
      LOCAL_SUPABASE_SERVICE_ROLE_KEY: "",
      LOCAL_MAILPIT_URL: "",
      ...env,
    },
  });
}

// A minimal valid node TAP: one skip matching EVERY manifest entry.
//
// It must cover every entry, not merely one per credential group: the checker
// also fails an entry that matches NOTHING, so that a manifest line outliving
// the test it excused is caught rather than quietly accumulating. That means
// this fixture has to grow whenever the manifest does — which is the point, and
// is how the 0093/0094 entry was caught the day it was added.
const validTap = [
  "TAP version 13",
  "ok 1 - a purge test # SKIP requires SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY",
  "ok 2 - a process-ios-sms test # SKIP requires SUPABASE_URL + SUPABASE_ANON_KEY (deployed process-ios-sms)",
  "ok 3 - a storage test # SKIP requires SUPABASE_URL + SUPABASE_ANON_KEY + SUPABASE_SERVICE_ROLE_KEY and a project with migrations 0075+0076 + the backups bucket deployed",
  "ok 4 - a coupons catalog test # SKIP requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (live PostgreSQL: migrations 0093/0094 must be applied)",
].join("\n");

test("valid manifest-matched skips with credentials ABSENT → pass", () => {
  const r = runChecker({ tap: validTap });
  assert.equal(r.status, 0, r.stdout + r.stderr);
});

test("an UNEXPECTED skip fails", () => {
  const bad = validTap + "\nok 9 - mystery test # SKIP no reason";
  const r = runChecker({ tap: bad });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /UNEXPECTED node skip/);
});

test("PARTIAL/malformed credentials fail (not a silent skip)", () => {
  const r = runChecker({ tap: validTap, env: { SUPABASE_URL: "https://x" } });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /PARTIAL\/malformed/);
});

test("credentials PRESENT but the test still skipped → fail (must run)", () => {
  const r = runChecker({
    tap: "ok 1 - a purge test # SKIP requires SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY",
    env: {
      SUPABASE_URL: "https://x",
      SUPABASE_ANON_KEY: "a",
      SUPABASE_SERVICE_ROLE_KEY: "s",
    },
  });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /credentials \(supabaseServiceRole\) are PRESENT/);
});

// Deno output in which every committed deno ignore entry is ignored (the live
// Postgres claims and the decision 3.4 local-stack deletion proofs D1-D4).
const validDeno = [
  "claim_ai_idempotency: claimed ... ignored (0ms)",
  "concurrent claims resolve to exactly one claimed ... ignored (0ms)",
  "D1 inline deletion completes: account data, cloud backups and profile photo are gone ... ignored (0ms)",
  "D2 an accepted deletion whose inline run never happened is finished by the worker alone ... ignored (0ms)",
  "D3 a storage failure schedules a retry; the worker resumes and finishes, claim clock-skew retried ... ignored (0ms)",
  "D4 a later sign-up with the same email is a new, empty account ... ignored (0ms)",
].join("\n");

const localStack = {
  LOCAL_SUPABASE_URL: "http://127.0.0.1:1",
  LOCAL_SUPABASE_ANON_KEY: "a",
  LOCAL_SUPABASE_SERVICE_ROLE_KEY: "s",
  LOCAL_MAILPIT_URL: "http://127.0.0.1:2",
};

test("local-stack deletion proofs ignored with NO local stack configured → pass", () => {
  const r = runChecker({ deno: validDeno });
  assert.equal(r.status, 0, r.stdout + r.stderr);
});

test("local stack configured but a deletion proof still ignored → fail (must run)", () => {
  const r = runChecker({ deno: validDeno, env: localStack });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /credentials \(localSupabaseStack\) are PRESENT/);
});

test("a partly configured local stack fails (not a silent ignore)", () => {
  const r = runChecker({ deno: validDeno, env: { LOCAL_SUPABASE_URL: "http://127.0.0.1:1" } });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /'localSupabaseStack' is PARTIAL/);
});

test("a deletion proof missing from deno output while no stack is configured → fail (stale entry)", () => {
  const r = runChecker({ deno: validDeno.split("\n").filter((l) => !l.startsWith("D4")).join("\n") });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /expected deno ignore matched NOTHING: "D4/);
});

// A crafted manifest (via SKIP_MANIFEST_PATH) exercises the resolved-known-failure
// guard without polluting the real committed manifest (which is honestly empty).
function runWithManifest(manifestObj, tap) {
  const dir = mkdtempSync(join(tmpdir(), "skipman-rkf-"));
  const mPath = join(dir, "manifest.json");
  writeFileSync(mPath, JSON.stringify(manifestObj));
  const tPath = join(dir, "node.tap");
  writeFileSync(tPath, tap);
  return spawnSync("node", [checker, "--node", tPath], {
    cwd: root,
    encoding: "utf8",
    env: {
      ...process.env,
      SKIP_MANIFEST_PATH: mPath,
      SUPABASE_URL: "",
      SUPABASE_ANON_KEY: "",
      SUPABASE_SERVICE_ROLE_KEY: "",
    },
  });
}

const rkfManifest = {
  credentialGroups: { supabaseServiceRole: ["SUPABASE_URL", "SUPABASE_ANON_KEY", "SUPABASE_SERVICE_ROLE_KEY"] },
  node: { expectedSkips: [] },
  deno: { expectedIgnored: [] },
  resolvedKnownFailures: [{ suite: "node", nameContains: "MALI-999 resolved probe", finding: "MALI-999" }],
};

test("a RESOLVED known-failure re-quarantined as a skip → fail", () => {
  const r = runWithManifest(
    rkfManifest,
    "ok 1 - MALI-999 resolved probe # SKIP re-hidden",
  );
  assert.equal(r.status, 1);
  assert.match(r.stderr, /resolved known-failure.*SKIPPED again/);
});

test("a RESOLVED known-failure that is failing again → fail", () => {
  const r = runWithManifest(
    rkfManifest,
    "not ok 1 - MALI-999 resolved probe\n  ---\n  ...",
  );
  assert.equal(r.status, 1);
  assert.match(r.stderr, /resolved known-failure.*FAILING again/);
});

test("a RESOLVED known-failure that passes normally → ok", () => {
  const r = runWithManifest(rkfManifest, "ok 1 - MALI-999 resolved probe");
  assert.equal(r.status, 0, r.stdout + r.stderr);
});

// REL-05 — Flutter `skip:` / `@Skip` / `markTestSkipped(` sites are enumerated
// statically and must each match a manifest entry; counts are exact.
function runFlutter(manifestObj, files) {
  const dir = mkdtempSync(join(tmpdir(), "skipman-flutter-"));
  const testDir = join(dir, "test");
  for (const [rel, body] of Object.entries(files)) {
    mkdirSync(dirname(join(testDir, rel)), { recursive: true });
    writeFileSync(join(testDir, rel), body);
  }
  const env = { ...process.env, SUPABASE_URL: "", SUPABASE_ANON_KEY: "", SUPABASE_SERVICE_ROLE_KEY: "" };
  if (manifestObj) {
    const mPath = join(dir, "manifest.json");
    writeFileSync(mPath, JSON.stringify(manifestObj));
    env.SKIP_MANIFEST_PATH = mPath;
  }
  return spawnSync("node", [checker, "--flutter", testDir], { cwd: root, encoding: "utf8", env });
}

const flutterManifest = (count = 1) => ({
  credentialGroups: {},
  node: { expectedSkips: [] },
  deno: { expectedIgnored: [] },
  flutter: {
    expectedSkips: [
      { file: "a/listed_test.dart", kind: "skip", contextContains: "needs synthetic defines", count, reason: "probe" },
    ],
  },
});
const listed = [
  "void main() {",
  "  test('x', () {}, skip: configured",
  "      ? false : 'needs synthetic defines');",
  "  // a comment mentioning skip: is not a skip",
  "  final rest = xs.skip(1);",
  "}",
].join("\n");

test("the real app/test tree: every Flutter skip site is manifest-matched → pass", () => {
  const r = spawnSync("node", [checker, "--flutter", join(root, "app/test")], { cwd: root, encoding: "utf8" });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /flutter: \d+ skip site\(s\)/);
});

test("a listed Flutter skip (reason on the next line) passes; comments and .skip( are not skips", () => {
  const r = runFlutter(flutterManifest(), { "a/listed_test.dart": listed });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /flutter: 1 skip site/);
});

for (const [label, line] of [
  ["skip:", "  test('y', () {}, skip: 'quietly off');"],
  ["@Skip", "@Skip('whole suite off')"],
  ["markTestSkipped", "  test('z', () { markTestSkipped('nope'); });"],
]) {
  test(`an UNLISTED Flutter ${label} fails the gate`, () => {
    const r = runFlutter(flutterManifest(), {
      "a/listed_test.dart": listed,
      "b/new_test.dart": `void main() {\n${line}\n}\n`,
    });
    assert.equal(r.status, 1, r.stdout + r.stderr);
    assert.match(r.stderr, /UNEXPECTED flutter skip: b\/new_test\.dart:2/);
  });
}

test("an extra Flutter skip reusing a listed reason fails (counts are exact)", () => {
  const r = runFlutter(flutterManifest(), {
    "a/listed_test.dart": listed + "\nvoid more() { test('w', () {}, skip: 'needs synthetic defines'); }\n",
  });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /expects 1 site\(s\), found 2/);
});

test("a stale Flutter manifest entry (skip removed) fails", () => {
  const r = runFlutter(flutterManifest(), { "a/listed_test.dart": "void main() {}\n" });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /expects 1 site\(s\), found 0/);
});

test("the committed manifest rejects a new unlisted skip next to the real tree's files", () => {
  const r = runFlutter(null, { "core/injected_unlisted_test.dart": "void main() {\n  test('q', () {}, skip: 'injected');\n}\n" });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /UNEXPECTED flutter skip: core\/injected_unlisted_test\.dart:2/);
});
