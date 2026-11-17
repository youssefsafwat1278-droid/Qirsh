#!/usr/bin/env bash
# Canonical CI gate runner (MALI-036 / Phase-7 Batch-1) — the SINGLE source of truth
# for local + CI validation of everything that does NOT need cloud infra. CI invokes
# this exact script (see .github/workflows/ci.yml); there is no CI-only subset.
#
# Gates (mandatory unless the toolchain is unavailable):
#   1. supabase migration lint (numbering + SECURITY DEFINER lockdown)
#      + catalog parser asset drift (canonical source vs bundled asset)
#   2. Deno edge-function tests (ALL functions, not just _shared/) + Deno lint (_shared)
#   3. flutter analyze
#   4a. flutter test — BULK parallel; crypto-prod and deletion-replica-io
#       EXCLUDED. Both run in mandatory serialized stages below.
#       SKIP_FLUTTER_TEST=1 for fast local iteration.
#   4b. flutter test — SERIALIZED production-cost crypto (--tags crypto-prod
#       --concurrency=1). Split is a DETERMINISM fix, not a convenience: the v3
#       Argon2id KDF derives each segment in a worker isolate guarded by a hardcoded
#       10s per-segment timeout (cryptography 2.9.0) that no @Timeout can raise; under
#       the parallel bulk run's CPU saturation a starved segment trips it
#       nondeterministically ("Segment processing timeout"). Serializing gives the
#       derivation an uncontended core. All three Flutter stages are mandatory;
#       their union is the whole suite. See dart_test.yaml + PHASE_7_TEST_AND_CI_CONTRACT.md.
#   4c. flutter test — SERIALIZED real-replica deletion suites. Their admission
#       and cleanup bounds stay unchanged. This isolates real SQLite/file I/O
#       from bulk CPU/memory contention; every tagged suite still runs.
#   4d. flutter test — SERIALIZED synthetic-define suites (REL-05/REV-06): the
#       configured cases that skip without SUPABASE_ENV/URL/ANON_KEY, run with
#       literal placeholder defines (no network). Bulk stays define-free.
#   5. Node contract tests (supabase/tests/*.mjs; live cases self-skip)
#   6. skip/ignore manifest enforcement (tools/test_skip_manifest.json) — node
#      skips, deno ignores, and every Flutter skip site in app/test (REL-05)
#   7. admin authorization tests
#   8. l10n freshness (flutter gen-l10n + git diff app/lib/l10n; .g.dart is gitignored)
#   9. MALI-034 architecture guard — the retired Supabase-primary financial
#      authority (flags / FinancialCacheRepairService / legacy Supabase financial
#      repos / Routed* wrappers) cannot silently return; schema stays 29.
#  10. MALI-037 dependency policy — OFFLINE/deterministic: lockfile present, no
#      git deps, path deps allowlisted. CVE/outdated registry scans are external.
#  11. iOS packaging inventory (MALI-066n/043) — PROVENANCE-GATED/external: runs the
#      built-Runner.app check only when a bundle exists (real archive evidence),
#      else UNAVAILABLE. The static Info.plist/privacy contract is in flutter test.
#
# Truthfulness contract (Phase-7 B1):
#   * an unexpected failure returns non-zero; a failed subcommand is NEVER hidden;
#   * pipelines use PIPESTATUS so a tee'd command's real status is used;
#   * an UNAVAILABLE toolchain is reported separately — never counted as pass;
#   * the final summary surfaces NESTED status (skips/ignored/external) truthfully and
#     never rolls skipped/ignored into passed;
#   * the success banner is guarded by fail==0; it cannot print while a mandatory
#     suite failed;
#   * `--self-test` / CI_GATES_INJECT_FAILURE prove a failed gate fails the script.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

pass_count=0; fail_count=0; unavail_count=0; fail=0
# Audit H-15 / CI-02: strict mode for RELEASE gates. When REQUIRE_ALL_GATES=1, a
# tool-missing gate (unavail) OR a caller-skipped mandatory test (caller_skipped)
# becomes FATAL, so a release workflow cannot hollow-pass this gate. Only an
# ARTIFACT-DEPENDENT gate (artifact_pending — iOS packaging needs a built bundle)
# stays non-fatal, because it is deferred to a mandatory post-build step in the
# release workflow (never classified as PASS — requirement 9).
REQUIRE_ALL_GATES="${REQUIRE_ALL_GATES:-0}"

# Repo-coherence: a RELEASE gate must test the code being released. Six times in
# the 2026-08 audit a gate was green about code HEAD did not contain, because
# every suite runs against the working tree. Under strict mode the Flutter suite
# additionally asserts that no tracked file differs from HEAD, so a pass and
# "HEAD passes" are the same statement. Outside strict mode the same test only
# PRINTS how many files differ, because failing every dirty local run would make
# the suite unusable — and a gate people routinely ignore is not a gate.
if [ "$REQUIRE_ALL_GATES" = "1" ]; then
  export REQUIRE_PRISTINE_TREE="${REQUIRE_PRISTINE_TREE:-1}"
fi
# Batch-15 follow-up: preserve the REASON a stage did not run as a PASS. A broad
# "external" bucket erased the distinction between (a) a caller deliberately
# skipping a mandatory test — which is NOT evidence and is fatal for a release —
# and (b) a gate that genuinely cannot run until an artifact exists (iOS
# packaging), which is legitimately deferred to a post-build step.
tool_missing_count=0     # UNAVAILABLE_TOOL   — fatal under strict
caller_skipped_count=0   # CALLER_SKIPPED     — fatal under strict (not evidence)
artifact_pending_count=0 # ARTIFACT_NOT_BUILT — deferred to post-build (never strict-fatal)
node_skips="n/a"; deno_ignored="n/a"; flutter_skips="n/a"; manifest_state="not-run"
LINT_EXCEPTIONS=7  # deno-lint-ignore no-explicit-any suppressions (2 prod Edge helpers + 5 test doubles); see PHASE_7_TEST_AND_CI_CONTRACT.md

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ci_gates.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
NODE_TAP="$TMP/node.tap"; DENO_OUT="$TMP/deno.txt"; FLUTTER_SKIPS="$TMP/flutter_skips.txt"

step() { echo; echo "══ $1 ══"; }
ok() { echo "  ✓ $1"; pass_count=$((pass_count + 1)); }
bad() { echo "  ✗ $1"; fail_count=$((fail_count + 1)); fail=1; }
# UNAVAILABLE_TOOL — a tool the gate needs is not installed. Fatal under strict.
unavail() { echo "  ! $1 — UNAVAILABLE TOOL (not a pass)"; unavail_count=$((unavail_count + 1)); tool_missing_count=$((tool_missing_count + 1)); }
# CALLER_SKIPPED — the caller bypassed a MANDATORY test (e.g. SKIP_FLUTTER_TEST).
# A deliberately-bypassed test is NOT evidence, so under a release gate
# (REQUIRE_ALL_GATES=1) this is FATAL. In normal/portable local mode it stays a
# reported, non-fatal skip (the historically-permitted fast path).
caller_skipped() { echo "  ! $1 — SKIPPED BY CALLER (mandatory; not evidence)"; caller_skipped_count=$((caller_skipped_count + 1)); }
# ARTIFACT_NOT_YET_BUILT — a gate that genuinely cannot run before an artifact
# exists (iOS packaging needs a built Runner.app). NEVER strict-fatal here; it is
# DEFERRED to a mandatory POST-BUILD step in the release workflow. Its absence
# pre-build is expected, not a gap.
artifact_pending() { echo "  ~ $1 — ARTIFACT-DEPENDENT (deferred to a mandatory post-build check)"; artifact_pending_count=$((artifact_pending_count + 1)); }

# --- Self-test: prove a failed gate makes the script exit non-zero ----------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0
  if false; then ok "unreachable"; else bad "injected self-test failure"; fi
  if [ "$fail" -eq 1 ]; then echo "SELF-TEST PASS: a failed gate sets fail=1 and would exit non-zero."; exit 0; fi
  echo "SELF-TEST FAIL: failure was not detected."; exit 1
fi

step "migration lint"
if bash "$ROOT/supabase/tools/check_migrations.sh"; then ok "migrations"; else bad "migrations"; fi

# Catalog parser rules exist in two places that must never disagree: the
# canonical source and the bundled app asset. Migration 0091 widened the amount
# quantifier in the database and the asset was never regenerated, so every
# shipped rule kept the pre-0091 shape — and because catalog-delta serves no
# unvalidated parser, that fix could reach no device by any route. This gate
# makes the two copies incapable of drifting silently again.
step "catalog asset drift"
if python3 "$ROOT/tools/gen_catalog_assets.py" --check; then
  ok "catalog asset in sync"
else
  bad "catalog asset drifted from supabase/catalog/parser_rules.json"
fi

step "deno edge-function tests + lint"
if command -v deno >/dev/null 2>&1; then
  # MALI-042/066n — run EVERY Edge-function Deno test, not just _shared/. The
  # whole-tree run picks up per-function suites (e.g. catalog-delta's country-code
  # injection guard) that were previously CI-invisible; live-backend cases
  # self-skip via the skip/ignore manifest (deno_ignored).
  ( cd "$ROOT/supabase/functions" && deno test --allow-all ) 2>&1 | tee "$DENO_OUT"
  if [ "${PIPESTATUS[0]}" -eq 0 ]; then ok "deno tests (all functions)"; else bad "deno tests (all functions)"; fi
  if ( cd "$ROOT/supabase/functions" && deno lint _shared/ ); then ok "deno lint"; else bad "deno lint"; fi
else
  unavail "deno"
fi

step "flutter analyze"
if ( cd "$ROOT/app" && flutter analyze ); then ok "analyze"; else bad "analyze"; fi

# Three mandatory, disjoint stages. The union is the whole Flutter suite:
# parallel bulk, production-cost crypto, and real-replica deletion I/O.
step "flutter test (bulk — parallel; crypto and deletion replica I/O excluded)"
if [ "${SKIP_FLUTTER_TEST:-0}" != "1" ]; then
  if ( cd "$ROOT/app" && flutter test --exclude-tags 'crypto-prod || deletion-replica-io' ); then ok "flutter test (bulk)"; else bad "flutter test (bulk)"; fi
else
  caller_skipped "flutter test bulk (SKIP_FLUTTER_TEST=1)"
fi

# ci_gates_contract_node_test.mjs checks that these inputs cover every
# crypto-prod-tagged suite. Avoid discovering and compiling unrelated files
# a second time in the serialized stage.
crypto_tests=(
  test/core/backup/backup_envelope_v3_test.dart
  test/core/backup/backup_payload_limit_test.dart
  test/core/backup/production_kdf_contract_test.dart
)
step "flutter test (crypto — serialized production-cost Argon2, --concurrency=1)"
if [ "${SKIP_FLUTTER_TEST:-0}" != "1" ]; then
  if ( cd "$ROOT/app" && flutter test "${crypto_tests[@]}" --tags crypto-prod --concurrency=1 ); then ok "flutter test (crypto serialized)"; else bad "flutter test (crypto serialized)"; fi
else
  caller_skipped "flutter test crypto (SKIP_FLUTTER_TEST=1)"
fi

# Keep the explicit inputs synchronized with all deletion-replica-io tags.
# ci_gates_contract_node_test.mjs verifies complete coverage. Explicit paths
# avoid recompiling thousands of unrelated suites for this short I/O stage.
deletion_replica_tests=(
  test/core/auth/immediate_deletion_flow_test.dart
  test/core/auth/prepared_immediate_deletion_gateway_test.dart
)
step "flutter test (deletion replica I/O — serialized, --concurrency=1)"
if [ "${SKIP_FLUTTER_TEST:-0}" != "1" ]; then
  if ( cd "$ROOT/app" && flutter test "${deletion_replica_tests[@]}" --tags deletion-replica-io --concurrency=1 ); then
    ok "flutter test (deletion replica I/O serialized)"
  else
    bad "flutter test (deletion replica I/O serialized)"
  fi
else
  caller_skipped "flutter test deletion replica I/O (SKIP_FLUTTER_TEST=1)"
fi

# REL-05 / REV-06: suites whose configured cases skip unless the build is
# configured. The values are literal placeholders (no network; every transport
# is faked) and are compile-time, so they are never passed to the bulk stage.
# ci_gates_contract_node_test.mjs checks these inputs against every
# "synthetic-define" entry of tools/test_skip_manifest.json.
synthetic_defines=(
  --dart-define=SUPABASE_ENV=local
  --dart-define=SUPABASE_URL=https://example.supabase.co
  --dart-define=SUPABASE_ANON_KEY=anon
)
synthetic_define_tests=(
  test/core/auth/immediate_account_deletion_test.dart
  test/core/tracking/user_activity_consent_test.dart
  test/core/session/local_read_host_test.dart
  test/features/app/smart_inbox_status_cycle_test.dart
  test/features/planning_sync/startup_reconcile_default_rpc_refusal_test.dart
)
# This file also holds the unconfigured removal group, which runs in the bulk
# stage and is built for an unconfigured binary; only its configured group runs here.
synthetic_define_group_test=test/core/startup/bootstrap_remove_data_integration_test.dart
synthetic_define_group='configured real sender bootstrap receivers'
step "flutter test (synthetic-define suites — serialized, --concurrency=1)"
if [ "${SKIP_FLUTTER_TEST:-0}" != "1" ]; then
  ( cd "$ROOT/app" && flutter test "${synthetic_define_tests[@]}" "${synthetic_defines[@]}" --concurrency=1 ); sd_files=$?
  ( cd "$ROOT/app" && flutter test "$synthetic_define_group_test" --plain-name "$synthetic_define_group" "${synthetic_defines[@]}" --concurrency=1 ); sd_group=$?
  if [ "$sd_files" -eq 0 ] && [ "$sd_group" -eq 0 ]; then
    ok "flutter test (synthetic-define serialized)"
  else
    bad "flutter test (synthetic-define serialized)"
  fi
else
  caller_skipped "flutter test synthetic-define (SKIP_FLUTTER_TEST=1)"
fi

step "node contract tests"
if command -v node >/dev/null 2>&1; then
  ( cd "$ROOT" && node --test --test-reporter=spec --test-reporter-destination=stdout \
      --test-reporter=tap --test-reporter-destination="$NODE_TAP" supabase/tests/*.mjs )
  node_status=$?
  node_skips="$(grep -c '# SKIP' "$NODE_TAP" 2>/dev/null || true)"
  node_skips="${node_skips:-0}"
  if [ "$node_status" -eq 0 ]; then ok "node contract"; else bad "node contract"; fi
else
  unavail "node"
fi

step "skip/ignore manifest enforcement"
if command -v node >/dev/null 2>&1; then
  args=()
  [ -f "$NODE_TAP" ] && args+=(--node "$NODE_TAP")
  [ -f "$DENO_OUT" ] && args+=(--deno "$DENO_OUT")
  # REL-05 — Flutter skip sites are enumerated statically from the source, so the
  # check holds even when the Flutter stages were skipped by the caller.
  args+=(--flutter "$ROOT/app/test")
  if FLUTTER_SKIP_COUNT_FILE="$FLUTTER_SKIPS" node "$ROOT/tools/check_test_skips.mjs" "${args[@]}"; then
    ok "skip/ignore manifest"; manifest_state="satisfied"
  else
    bad "skip/ignore manifest"; manifest_state="VIOLATED"
  fi
  deno_ignored="$(grep -c '\.\.\. .*ignored' "$DENO_OUT" 2>/dev/null || true)"
  deno_ignored="${deno_ignored:-0}"
  flutter_skips="$(cat "$FLUTTER_SKIPS" 2>/dev/null || true)"
  flutter_skips="${flutter_skips:-n/a}"
else
  unavail "skip manifest (needs node)"
fi

step "admin authorization tests"
if command -v npm >/dev/null 2>&1 && [ -d "$ROOT/admin/node_modules" ]; then
  if ( cd "$ROOT/admin" && npm run --silent test:auth ); then ok "admin auth"; else bad "admin auth"; fi
elif command -v npm >/dev/null 2>&1; then
  unavail "admin auth (run 'npm ci' in admin/ first)"
else
  unavail "npm"
fi

# Generated-code freshness: drift/freezed/json .g.dart is GITIGNORED (regenerated by
# build_runner every build — no committed-staleness surface). The COMMITTED generated
# artifact is the l10n output (flutter gen-l10n → app/lib/l10n/*.dart), so THAT is the
# real, fast staleness check.
step "l10n freshness (flutter gen-l10n)"
if ( cd "$ROOT/app" && flutter gen-l10n >/dev/null 2>&1 ) && git -C "$ROOT" diff --quiet -- app/lib/l10n/; then
  ok "l10n freshness"
else
  bad "l10n freshness (committed app/lib/l10n is stale — run 'flutter gen-l10n' and commit)"
fi

step "MALI-034 architecture guard (retired Supabase-primary authority stays gone)"
if bash "$ROOT/tools/check_arch_guard.sh"; then ok "arch guard"; else bad "arch guard"; fi

step "MALI-037 dependency policy (offline: reproducibility + no git/rogue-path deps)"
if bash "$ROOT/tools/check_deps_policy.sh"; then ok "deps policy"; else bad "deps policy"; fi

# MALI-066n — iOS packaging inventory. The BUILT-bundle check needs a freshly
# built Runner.app (extensions, PrivacyInfo, bundle ids, Mach-O) — real archive
# evidence that only exists after a macOS/CI build. When a bundle is present it
# runs and must pass; otherwise it is reported UNAVAILABLE (never a pass, never
# faked). The source/static packaging contract (Info.plist usage descriptions /
# privacy manifest) is covered deterministically by `flutter test`
# (test/ios/ios_privacy_manifest_test.dart), which runs in stage 4a.
step "iOS packaging inventory (built Runner.app — PROVENANCE-GATED; source contract in flutter test)"
IOS_APP="$ROOT/app/build/ios/iphonesimulator/Runner.app"
if [ -d "$IOS_APP" ]; then
  bash "$ROOT/app/tools/verify_ios_packaging.sh" "$IOS_APP"; ios_rc=$?
  case "$ios_rc" in
    0) ok "ios packaging (CURRENT artifact — provenance-verified)" ;;
    3) artifact_pending "ios packaging: built artifact NOT CURRENT / no provenance — fresh build (tools/stamp_ios_provenance.sh) or external evidence pending" ;;
    *) bad "ios packaging (structural regression on a current artifact)" ;;
  esac
else
  artifact_pending "ios packaging (no built Runner.app; static Info.plist/privacy SOURCE contract runs in flutter test stage 4a)"
fi

# --- intentional-failure injection self-test hook ---------------------------------
if [ "${CI_GATES_INJECT_FAILURE:-0}" = "1" ]; then
  step "INJECTED FAILURE (self-test)"; bad "intentional failure (CI_GATES_INJECT_FAILURE=1)"
fi

# Strict-mode fatality (Batch-15 follow-up). A tool-missing gate and a
# caller-skipped MANDATORY test both make a release gate untrustworthy, so both
# are FATAL under REQUIRE_ALL_GATES=1. An ARTIFACT-DEPENDENT gate (iOS packaging)
# is NOT fatal — it is legitimately deferred to a mandatory post-build step.
strict_fatal=$((tool_missing_count + caller_skipped_count))
strict_note=""
if [ "$REQUIRE_ALL_GATES" = "1" ] && [ "$strict_fatal" -gt 0 ] && [ "$fail" -eq 0 ]; then
  fail=1
  strict_note=" [STRICT: $tool_missing_count tool(s) missing, $caller_skipped_count caller-skipped mandatory test(s)]"
fi

echo
echo "══ truthful summary ══"
echo "  mandatory gates passed : $pass_count"
echo "  mandatory gates failed : $fail_count"
echo "  tools unavailable      : $unavail_count  (strict: $([ "$REQUIRE_ALL_GATES" = "1" ] && echo FATAL || echo reported))"
echo "  caller-skipped tests   : $caller_skipped_count  (strict: $([ "$REQUIRE_ALL_GATES" = "1" ] && echo FATAL || echo 'reported skip')) — a bypassed mandatory test is NOT evidence"
echo "  artifact-dependent     : $artifact_pending_count  (deferred to a mandatory POST-BUILD check; never a pass, never strict-fatal)"
echo "  node tests skipped     : $node_skips  (credentials absent — see manifest)"
echo "  deno tests ignored     : $deno_ignored  (live-Postgres — see manifest)"
echo "  flutter skip sites     : $flutter_skips  (static skip:/@Skip/markTestSkipped in app/test — see manifest; NOT counted as passed)"
echo "  skip/ignore manifest   : $manifest_state"
echo "  external verification  : pending (device / live Supabase / native timing — see PHASE_6 checklist)"
echo "  retained lint exceptions: $LINT_EXCEPTIONS deno-lint-ignore (no-explicit-any; loosely-typed Supabase Edge client — see PHASE_7 doc)"
# machine-readable line for CI assertions (no secrets). Each reason is preserved
# as a distinct field — no broad bucket erases the classification (requirement 7).
echo "CI_GATES_JSON {\"passed\":$pass_count,\"failed\":$fail_count,\"tool_missing\":$tool_missing_count,\"caller_skipped\":$caller_skipped_count,\"artifact_pending\":$artifact_pending_count,\"strict\":$REQUIRE_ALL_GATES,\"node_skipped\":\"$node_skips\",\"deno_ignored\":\"$deno_ignored\",\"flutter_skip_sites\":\"$flutter_skips\",\"manifest\":\"$manifest_state\",\"lint_exceptions\":$LINT_EXCEPTIONS}"
echo
if [ "$fail" -eq 0 ]; then
  extra=$((unavail_count + caller_skipped_count + artifact_pending_count))
  if [ "$extra" -gt 0 ]; then echo "ALL RUN GATES PASSED ($unavail_count tool-missing, $caller_skipped_count caller-skipped, $artifact_pending_count artifact-pending — see notes)"; else echo "ALL LOCAL GATES PASSED"; fi
else
  echo "SOME GATES FAILED ($fail_count)$strict_note — see ✗ above"
fi
exit "$fail"
