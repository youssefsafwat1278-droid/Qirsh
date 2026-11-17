import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import test from "node:test";

// Phase-7 Batch-1 — the canonical gate (tools/ci_gates.sh) must be truthful: a failed
// gate produces a non-zero exit, the mandatory suites are wired in, and CI invokes the
// same gate. (Uses --self-test, which exercises only the failure-propagation machinery,
// so this test — itself run BY the gate — does not recurse.)

const root = process.cwd(); // the gate runs node tests from the repo root

test("ci_gates --self-test proves a failed gate exits non-zero", () => {
  const r = spawnSync("bash", ["tools/ci_gates.sh", "--self-test"], {
    cwd: root,
    encoding: "utf8",
  });
  assert.equal(r.status, 0, "self-test itself passes (machinery is correct)");
  assert.match(r.stdout, /SELF-TEST PASS/);
});

test("the canonical gate wires in the previously CI-invisible mandatory suites", () => {
  const sh = readFileSync(`${root}/tools/ci_gates.sh`, "utf8");
  assert.match(sh, /deno lint/, "deno lint gate");
  assert.match(sh, /node --test/, "node test runner");
  assert.match(sh, /supabase\/tests\/\*\.mjs/, "node contract gate");
  assert.match(sh, /check_test_skips\.mjs/, "skip/ignore manifest gate");
  assert.match(sh, /npm run --silent test:auth/, "admin authorization gate");
  assert.match(sh, /check_migrations\.sh/, "migration lint gate");
  assert.match(sh, /flutter gen-l10n/, "l10n freshness gate");
  // MALI-042/066n — every Edge-function Deno suite runs (not just _shared/), and
  // the iOS packaging inventory is wired (conditional/external when no build).
  assert.match(sh, /deno tests \(all functions\)/, "per-function deno tests (MALI-042/066n)");
  assert.match(sh, /verify_ios_packaging\.sh/, "ios packaging inventory step (MALI-066n)");
  assert.match(sh, /check_deps_policy\.sh/, "offline dependency policy (MALI-037)");
  // Reports UNAVAILABLE separately from pass, and a truthful nested summary.
  assert.match(sh, /unavail/);
  assert.match(sh, /node tests skipped/);
  assert.match(sh, /deno tests ignored/);
  // REL-05 — Flutter skip sites are enforced by the manifest gate and reported.
  assert.match(sh, /args\+=\(--flutter "\$ROOT\/app\/test"\)/, "flutter skips governed by the manifest");
  assert.match(sh, /flutter skip sites/);
  assert.match(sh, /\\"flutter_skip_sites\\"/);
  assert.match(sh, /CI_GATES_JSON/);
});

test("the iOS packaging stage is PROVENANCE-GATED — a stale bundle is never counted as current", () => {
  const sh = readFileSync(`${root}/tools/ci_gates.sh`, "utf8");
  // verify_ios exit code is interpreted; exit 3 (not-current) maps to UNAVAILABLE
  // (pending), never to a pass banner.
  assert.match(sh, /ios_rc/, "ci_gates interprets the verify_ios exit code");
  assert.match(sh, /NOT CURRENT \/ no provenance/, "not-current iOS artifact -> pending, not pass");
  const vios = readFileSync(`${root}/app/tools/verify_ios_packaging.sh`, "utf8");
  assert.match(vios, /ios_input_sha\.sh/, "verify_ios checks source provenance");
  assert.match(vios, /\bexit 3\b/, "verify_ios exits 3 when the artifact is not current");
});

test("the CI workflow invokes the canonical gate as its only validation step", () => {
  const yml = readFileSync(`${root}/.github/workflows/ci.yml`, "utf8");
  assert.match(yml, /bash tools\/ci_gates\.sh/, "CI runs the canonical gate");
  assert.match(yml, /Run canonical CI gates/);
  // No competing CI-only validation step (freshness now lives inside the gate).
  assert.doesNotMatch(yml, /git diff --exit-code/);
});

test("the gate cannot print an all-passed banner while a mandatory suite failed", () => {
  const sh = readFileSync(`${root}/tools/ci_gates.sh`, "utf8");
  assert.match(sh, /if \[ "\$fail" -eq 0 \]; then/);
  assert.match(sh, /SOME GATES FAILED/);
  // pass_count is only ever incremented by ok() — skipped/ignored increment their
  // own counters, never pass_count.
  assert.match(sh, /ok\(\)\s*\{[^}]*pass_count=/);
  assert.match(sh, /unavail\(\)\s*\{[^}]*unavail_count=/);
});

for (const { tag, variable, label, otherTag } of [
  { tag: "crypto-prod", variable: "crypto_tests", label: "crypto", otherTag: "deletion-replica-io" },
  { tag: "deletion-replica-io", variable: "deletion_replica_tests", label: "deletion replica I/O", otherTag: "crypto-prod" },
]) {
  test(`all ${tag} tests run in one mandatory serialized stage`, () => {
    const sh = readFileSync(`${root}/tools/ci_gates.sh`, "utf8");
    const selectedBlock = sh.match(new RegExp(`${variable}=\\(([\\s\\S]*?)\\)`))?.[1];
    assert.ok(selectedBlock, "the serialized stage must declare its inputs");
    const selected = selectedBlock.match(/test\/[^\s]+_test\.dart/g).sort();
    const tagged = readdirSync(`${root}/app/test`, { recursive: true })
      .filter((path) => path.endsWith("_test.dart"))
      .filter((path) => {
        const source = readFileSync(`${root}/app/test/${path}`, "utf8");
        const included = new RegExp(`^\\s*@Tags\\(\\[[^\\]]*['"]${tag}['"]`, "m").test(source);
        if (included) {
          assert.doesNotMatch(source,
            new RegExp(`^\\s*@Tags\\(\\[[^\\]]*['"]${otherTag}['"]`, "m"),
            "serialized groups are disjoint");
        }
        return included;
      })
      .map((path) => `test/${path}`)
      .sort();
    assert.ok(tagged.length > 0, "coverage assertion must not be vacuous");
    assert.deepEqual(selected, tagged, "no tagged suite may be excluded without running");
    assert.match(sh, /--exclude-tags 'crypto-prod \|\| deletion-replica-io'/);
    assert.ok(sh.includes(
      'flutter test "${' + variable + '[@]}" --tags ' + tag + ' --concurrency=1',
    ));
    assert.ok(sh.includes(`ok "flutter test (${label} serialized)"`));
    assert.ok(sh.includes(`bad "flutter test (${label} serialized)"`));
    assert.ok(sh.includes(`caller_skipped "flutter test ${label}`));
  });
}

test("every synthetic-define skip site runs in one mandatory define stage; bulk stays define-free (REL-05/REV-06)", () => {
  const sh = readFileSync(`${root}/tools/ci_gates.sh`, "utf8");
  const manifest = JSON.parse(readFileSync(`${root}/tools/test_skip_manifest.json`, "utf8"));
  const expected = [...new Set(manifest.flutter.expectedSkips
    .filter((e) => e.class === "synthetic-define")
    .map((e) => `test/${e.file}`))].sort();
  assert.ok(expected.length > 0, "coverage assertion must not be vacuous");
  const files = sh.match(/synthetic_define_tests=\(([\s\S]*?)\)/)?.[1]
    ?.match(/test\/[^\s]+_test\.dart/g) ?? [];
  const group = sh.match(/^synthetic_define_group_test=(test\/[^\s]+_test\.dart)$/m)?.[1];
  const groupName = sh.match(/^synthetic_define_group='([^']+)'$/m)?.[1];
  assert.ok(group && groupName, "the group-selected input must be declared");
  assert.deepEqual([...files, group].sort(), expected, "no synthetic-define suite may be left unrun");
  assert.ok(readFileSync(`${root}/app/${group}`, "utf8").includes(`group('${groupName}'`),
    "the selected group exists, so --plain-name cannot select nothing");
  const defines = sh.match(/synthetic_defines=\(([\s\S]*?)\)/)?.[1] ?? "";
  for (const d of [
    "--dart-define=SUPABASE_ENV=local",
    "--dart-define=SUPABASE_URL=https://example.supabase.co",
    "--dart-define=SUPABASE_ANON_KEY=anon",
  ]) assert.ok(defines.includes(d), d);
  assert.ok(sh.includes('flutter test "${synthetic_define_tests[@]}" "${synthetic_defines[@]}" --concurrency=1'));
  assert.ok(sh.includes('flutter test "$synthetic_define_group_test" --plain-name "$synthetic_define_group" "${synthetic_defines[@]}" --concurrency=1'));
  assert.ok(sh.includes('ok "flutter test (synthetic-define serialized)"'));
  assert.ok(sh.includes('bad "flutter test (synthetic-define serialized)"'));
  assert.ok(sh.includes('caller_skipped "flutter test synthetic-define (SKIP_FLUTTER_TEST=1)"'));
  // The bulk stage must not inherit the defines (they change compile-time config).
  const bulk = sh.split("\n").find((l) => l.includes("--exclude-tags 'crypto-prod || deletion-replica-io'"));
  assert.ok(bulk && !bulk.includes("dart-define"), "bulk stage stays define-free");
});

test("the failing CDN tslib import uses an exact integrity-locked npm archive", () => {
  const config = JSON.parse(readFileSync(`${root}/supabase/functions/deno.json`, "utf8"));
  const lock = JSON.parse(readFileSync(`${root}/supabase/functions/deno.lock`, "utf8"));
  const override = config.imports["https://esm.sh/tslib@2.8.1/denonext/tslib.mjs"];
  const version = /^npm:tslib@(\d+\.\d+\.\d+)$/.exec(override)?.[1];
  assert.ok(version, "the replacement archive version must be exact");
  assert.equal(lock.specifiers[override], version);
  assert.match(lock.npm[`tslib@${version}`].integrity, /^sha512-[A-Za-z0-9+/]+={0,2}$/);
});
