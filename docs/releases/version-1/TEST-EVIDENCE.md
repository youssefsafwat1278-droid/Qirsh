# Version 1 — test evidence

What was actually run in this assessment, on what, and the result. Anything not listed here was not run. All runs: 2026-11-17, one Apple-silicon Mac, macOS (Darwin 27.0.0), Flutter 3.47.3 / Dart 3.13.3, Xcode 27.2, Node 26.8.2, Deno 2.9.6, local timezone Africa/Cairo unless stated. Reviewer for every row: AI (orchestrator Claude Fable 5.2, or an agent reporting `claude-opus-5-5`). Synthetic data only.

Not run at all: any physical device; any Android build, emulator or device; any signed or CI build of the candidate; anything against production or a store console; iOS XCTests; Kotlin tests; live-database tests.

## 1. Canonical gate — `REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh`

Run with Supabase credentials removed from the environment, as CI does. Summaries of each run are in [`evidence/logs/`](evidence/logs/).

| Run | Commit | Result | Notes |
|---|---|---|---|
| Baseline 1 | `ab5dc10a` | INVALID | Every Flutter stage failed before starting: the shell profile's `PUB_CACHE` points at an unmounted volume. Environment, not code. Non-Flutter gates passed |
| Baseline 2 | `ab5dc10a` | 13 passed, 1 failed | `flutter test` bulk: 10,662 passed, 35 skipped, 33 failed, while eight audit agents were running on the same machine. The four failing files re-run alone: 281/281 passed in local time and under `TZ=UTC`. One failure (`head_completeness_test`) was because the tree was not pristine. Treated as load-induced, not as pre-existing defects |
| Final 1 | `23499229` | 14 passed, 1 failed | Machine otherwise idle. `flutter test` bulk: 10,853 passed, 35 skipped, **1 failed** — `story_screen_test` expected Arabic-Indic digits in a label that the UX-13 fix changed to Western digits. A regression introduced by this assessment's own UI fix and caught by the gate. Crypto 24, deletion replica 79, synthetic-define 140 + 3, node contract, skip manifest, admin auth 191, l10n freshness, arch guard, deps policy, migration lint, catalog drift, deno tests and lint: passed |
| Final 2 | `af675aec` (the test expectation updated) | **15 passed, 0 failed** (exit 0) | Machine otherwise idle. `flutter test` bulk: 10,854 passed, 35 skipped, 0 failed; crypto 24; deletion replica 79; synthetic-define 140 + 3; analyze clean; deno tests and lint; node contract; skip manifest; admin auth; l10n freshness; arch guard; deps policy; migration lint; catalog drift. 1 artifact-dependent check still deferred (needs a built `Runner.app`). This satisfies gate G1 for `af675aec` on this machine; it is not a CI run |

Standing facts in every run: 89 node tests skipped (credentials absent), 2 Deno tests ignored (need live Postgres), 38 Flutter skip sites counted against the manifest, iOS packaging inventory deferred (needs a built `Runner.app`). These are not passes.

**Pre-existing failures at the baseline: none established.** Every baseline failure disappeared when the affected files were re-run without load.

## 2. Targeted runs during remediation

| What | Command (from `app/` unless noted, `PUB_CACHE=$HOME/.pub-cache`) | Commit / state | Result |
|---|---|---|---|
| Declined end-to-end probe (audit B) | `AddTransactionUseCase` on in-memory Drift, default flags | `ab5dc10a` | Reproduced: two declined messages → 430.00 SAR confirmed spend |
| Parser, AI, domain, capture, transactions | `flutter test --no-pub test/engine test/domain test/features/capture test/features/transactions` | after first fix | 3,134 passed |
| Same, after second fix | `flutter test --no-pub test/engine test/domain test/features/capture` | `668f4d64` tree | 3,061 passed |
| Shared declined cases | 69 synthetic cases in `declined_cases.json`, run by Dart and Deno tests | `668f4d64` | Pass. Against the first fix: 35/69 wrong on device, 37/69 on server |
| Relay import of a declined "processed" capture | `capture_sync_service_test.dart` new test | `668f4d64` | Pass; fails with the check disabled |
| Declined message not sent to AI | `declined_transaction_test.dart` new test | `d35fc044` | Pass; fails with the skip removed |
| Server parser | `deno test --allow-all process-ios-sms/` (from `supabase/functions`) | `668f4d64` | 125 passed; `deno lint` clean |
| Force-update range | `flutter test --no-pub test/features/announcements test/features/onboarding` | `7597bb42` | 159 passed; new test failed before the fix (2 of 4) |
| Sync conflict timezone | `sync_conflict_store_test.dart` under `TZ=UTC`, `Africa/Cairo`, `Asia/Riyadh` | `ff1fc292` | 10 passed in each; new test failed before the fix in the two non-UTC zones |
| Help copy and l10n | `flutter test --no-pub test/l10n test/features/help test/core/sync test/features/announcements` | `2f2c4707` | 222 passed |
| iOS manifest and scene-cover source contracts | `flutter test --no-pub test/ios` + 17 related files | `d70ba396` | 309 passed; 4 + 2 new assertions failed before |
| CI version and skip gate | `node --test supabase/tests/*.mjs`; `bash tools/ci_gates.sh --self-test` | `29cb1819` | 386 tests: 297 passed, 0 failed, 89 skipped; self-test passed |
| Define-gated suites | five files + the removal file's configured group, with the three synthetic defines | `29cb1819` | 140 + 3 passed |
| Removal file, whole, with the defines | `bootstrap_remove_data_integration_test.dart` | `f6dc5076` | 3 passed, 7 failed — harness limit (V1-054), reproduced by the orchestrator |
| Admin | `npm run build` with placeholder env on the command line; `npm run test:auth`; `npx tsc --noEmit`; `npm run lint` | `f6dc5076` | Build succeeded; 191 passed; typecheck and lint clean |
| Admin advisories | `npm audit --omit=dev` | before → after | 4 → 2 affected packages; on `next`: 31 → 25 advisories (3 critical, 9 high remain) |
| UI fixes | 107 related test files | `23499229` tree | 1,102 passed; every new test failed with the fix reversed |

## 3. Runtime on iOS simulators (not device evidence)

| What | Environment | Commit | Result |
|---|---|---|---|
| Onboarding walk in Arabic and English, light and dark, default and maximum text size | iPhone 17 and iPhone SE (3rd gen) simulators, iOS 26.5, debug build without backend configuration | `ab5dc10a` | Exercised; findings in [UI-UX-REVIEW.md](UI-UX-REVIEW.md). "Continue locally" cannot complete without a real session, so the signed-in shell was not reached |
| About 20 main screens over an in-memory database, with Flutter accessibility checks | same, via a temporary integration test (deleted) | `ab5dc10a` | 40 screenshots in `evidence/ui/before/` |
| Manual add: validation, input kept on error, double tap on Save | iPhone 17 simulator | `ab5dc10a` | One row created |
| After-screenshots for small-screen fixes (45–48) | iPhone SE simulator, 1.25× text | UI fix tree | In `evidence/ui/after/` |
| Compile of the Swift changes | `flutter build ios --simulator --debug` in a second worktree | `f6dc5076` | Built `Runner.app` |
| Launch → background → return | iPhone 17 simulator, iOS 26.5 | `f6dc5076` | App launched; after backgrounding and returning, the UI was intact (cover removed). The cover inside the app switcher was **not** observed. Screenshots `evidence/ui/after/ios-sim-f6dc5076-*.png` |

## 4. Read-only external checks

| What | Result |
|---|---|
| `git fetch --all --prune`, `git ls-remote` | Remote heads as recorded in the manifest |
| GitHub check runs for `b6fc0dad`, `96c2437e`, `047c585a` | Codemagic "iOS Signed" succeeded on each |
| Codemagic build log for the `b6fc0dad` build (owner signed in) | "1.0.0 (146) exists; building (147)" |

## 5. Evidence that expired

Audits A–F and H describe `ab5dc10a`. For code changed afterwards — the parser and AI validator, capture import paths, `process-ios-sms`, the privacy manifests, `AppDelegate`/`SceneDelegate`, `conflict_fields.dart`, the force-update gate, Help strings, the manual transaction sheet and the listed widgets, `codemagic.yaml`, `tools/ci_gates.sh`, the admin dependencies — the audit statements about those files no longer apply; the rows above are the current evidence. Audit statements about untouched code still describe the candidate.
