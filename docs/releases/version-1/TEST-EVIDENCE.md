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

## 6. Second round (after the owner's review)

Same machine and toolchain. Docker Desktop 29.7.2 with a local Supabase stack (`qirsh_v1_verify`, synthetic data) for the rows that say "local stack". The disk filled once during this round; the runs made then are listed as discarded.

### 6.1 Canonical gate — `REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh`

| Run | Commit | Result | Notes |
|---|---|---|---|
| Round 2, run 1 | `50957c06` (records uncommitted) | 13 passed, 2 failed | `flutter test` bulk: 14,019 passed, 44 skipped, 1 failed — the clean-tree check, because the records were not committed. Synthetic-define stage: 139 passed, 1 failed — `startup_reconcile_default_rpc_refusal_test` pinned a request sequence that the restore fix (`0f90003f`) changed on purpose; this suite only runs in that stage, so no targeted run had seen it. Corrected in `5dae2e2d` (test only) |
| Round 2, run 2 | `c82f9a89` — application and test code of the candidate `5dae2e2d`, records committed, clean tree | **15 passed, 0 failed** (exit 0) | Machine otherwise idle. `flutter test` bulk 14,020 passed, 44 skipped; crypto 24; deletion replica 79; synthetic-define 140 + 10; analyze clean; deno tests and lint; node contract; skip manifest (39 Flutter skip sites counted); admin auth; l10n freshness; arch guard; deps policy; migration lint; catalog drift. 1 artifact-dependent check deferred (needs a built `Runner.app`). Local run, not CI |

### 6.2 Other runs

| What | Where | Commit | Result |
|---|---|---|---|
| Restore then cloud sync, scenarios R1 and R2 | Live local stack, real client services | parent of `0f90003f` → `0f90003f` | Both failed with the old code and passed with the fix, with and without a configured build (orchestrator) |
| Restore identity, 12 entity types, backfill, guest restore | Unit tests against an in-memory fake backend | `0f90003f` | Pass; fail before the fix |
| Backup, sync, capture, planning-sync, architecture suites | Flutter | `0f90003f` | 3,220 passed |
| Native iOS XCTests | iPhone 17 simulator, iOS 26.5, parallel testing off | `d830855e` (no `app/ios` change since) | 194 passed, 0 failed. First valid run |
| Native iOS XCTests, earlier attempt | same | same | DISCARDED — disk full, test host crashed (182 passed / 7 failed is not evidence) |
| Signed-in app shell | iPhone 17 and SE simulators, local stack, synthetic account, real email-code sign-in UI | `8e953d14` | 44 items seen, 5 not reached; report J |
| Tab-bar fix | iPhone 17 simulator, three fresh installs, plus a control build with the old observer | `0095a239` | Fixed build: bar visible each time. Control: defect reproduced. Report M |
| Removal journeys in a configured build | Gate command with synthetic defines | `837d0881` | 10 of 10 |
| Parser shared cases | Dart and Deno | `50957c06` | 1,565 cases; Flutter engine/domain/capture/transactions 6,268 passed; Deno 701 passed (orchestrator re-run of each round before committing) |
| Parser, independent measurements | Reviewer's own harness, 1,758 hand-labelled messages | `50957c06` vs `ab5dc10a` | Report R: wrong total-changing outcomes 509 → 71 on the effective path with a bank sender; nothing worse than the baseline on the device or effective path |
| UI round 2 | Widget tests | `34ccc9e9` | 97 new cases; related suites 1,823 passed |
| Release workflow contract tests | Node, including real execution of the revision-check and build-number scripts | `4fc2ecd6` | 13 of 13; never run on Codemagic |
| Production | Read-only: CLI and the connector the owner attached | 2026-11-17 | `evidence/production-comparison.md` |

Still not run anywhere: a physical device; Android; a CI or signed build of the candidate; the AI path against a real model; real bank messages.

## 7. Round 3 (closure round, 2026-11-18) — candidate `a157e68e`

Same Mac and toolchain. Recorded by a records editor (AI agent, `claude-opus-5-5`) from the gate summaries in [`evidence/logs/`](evidence/logs/), the closure reports in [`evidence/closure/`](evidence/closure/) and reviews S and T; this editor ran no test. The header of this file ("Not run at all: … iOS XCTests …") describes round 1; round 3 did run XCTests (below).

**What each word means here.** *Implemented locally*: committed on the local branch. *Verified locally*: a test or measurement passed on this Mac, a simulator or a local Supabase stack. *Verified on CI*: **nothing.** *Verified on a device*: **nothing.** *Deployed*: **nothing.** Every round-3 item is at most "verified locally".

### 7.1 Canonical gate — `REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh` (orchestrator, local Mac, not CI)

| Run | Commit | Result | Notes |
|---|---|---|---|
| Round 3, run 1 | `7cab5e8b` | **12 passed, 3 failed** (exit 1) | `flutter test` bulk +14,435 ~52 **−5**; synthetic-define stage +129 **−11**; skip/ignore manifest VIOLATED (the four local-stack deletion tests D1–D4 ignored without manifest entries). Of the 16 failing tests, two were real parser regressions (reward points; an advert footer — parser specialist), the others expectations changed by approved decisions (ATM deposit, UMP removed, Smart Inbox label). Fixed in `b6f102b4` |
| Round 3, run 2 | `b6f102b4` | 14 passed, **1 failed** (exit 1) | `flutter analyze`: one lint (a fixture not `const`). Bulk +14,445 ~52. Fixed in `7577f347` |
| Round 3, run 3 | `f4dcabd3` | **15 passed, 0 failed** (exit 0) | Bulk +14,933 ~52; crypto +24; deletion replica +79; synthetic-define +140; +10. Flutter skip sites 41 (39 before) |
| Round 3, run 4 | `a157e68e`, clean tree | **15 passed, 0 failed** (exit 0) | Bulk +14,984 ~52; crypto +24; deletion replica +79; synthetic-define +140; +10. Node skipped 89, Deno ignored 6, Flutter skip sites 41, manifest satisfied. **1 artifact-dependent check deferred** (needs a built artifact). **Opt-in backend stage `not-run`** |

Backend stage (`tools/backend_behaviour.sh`, opt-in): run by the ops specialist at `f4dcabd3` on a local PostgreSQL — 135 migrations applied, 13 SQL proofs pass. **Not re-run at `a157e68e`**; between the two commits no migration or SQL changed (`git diff f4dcabd3 a157e68e -- supabase/migrations` is empty; checked by this editor); the backend change is Edge Function TypeScript only.

### 7.2 Native iOS tests

| What | Where | State | Result | Who |
|---|---|---|---|---|
| XCTest, Runner and extensions | iPhone 17 Pro simulator | working tree that became `a157e68e` (Swift redaction port) | **200 passed, 0 failed** | iOS specialist (implementer). Reviewer S read the Swift diff; no reviewer ran XCTest |
| Swift sanitizer parity with the server | Swift harness vs Deno output | same | 0 of 2,628 texts differ | iOS specialist |
| Release-like compile, no signing | `flutter build ios --release --no-codesign` | round-3 tree | Built (69.5 MB); disk-space API absent from the release binary | iOS specialist |

### 7.3 Local Supabase stacks (synthetic data)

| What | Who, where | Result |
|---|---|---|
| Restore = merge, R1–R9b (incl. account switch R7/R8) with dart-defines | data specialist; reviewer T on own stack | `+10` (data); T at `7577f347` `+10`, at `7dd6efa8` restore + sync `+24 ~2` |
| Sync end to end | data specialist; T | `+14 ~2` (data); T `+24 ~2` combined. S9/S9b (two devices) **not run** (skipped by manifest) |
| Deletion D1–D4 (inline, worker-only, storage failure + retry, re-signup) | data specialist; T | 4 passed; the old worker v5 shape fails D1–D3 (profile photo left) |
| Round-2 V1-020 evidence re-checked | T, at `0f90003f` | `+2` with and without the defines — the round-2 claim stands for R1/R2 |
| Backend stage | ops, at `f4dcabd3` | 135 migrations, 13 proofs (above) |

### 7.4 Differential harnesses (parser specialist; reviewed by S)

| Harness | What it compares | Last result |
|---|---|---|
| `tools/parser_diff/run.sh 5dae2e2d` | Device and effective paths, working tree vs the round-2 candidate, 2,519 messages (1,737 labelled) | Exit 0, 0 regressions, 38 to review against a budget of 38 (`ACCEPTED_REVIEW` DEV072, K062, K126). S: honest in what it prints, weak as a gate (HAR-1) |
| `tools/parser_diff/server_diff.sh b6fc0dad` | Server path vs the deployed parser | Exit 0; `ACCEPTED_SERVER` DEV084, DEV085, DEV090 (keyed by id, `not_completed` only) |

### 7.5 Held-out message evaluation (`tools/message_eval`, eval specialist; [`evidence/closure/eval.md`](evidence/closure/eval.md) §§12–13)

753 synthetic messages by one author, labels fixed before the first run; acceptance criteria A1–A8 written before the run and never relaxed. **Caveat:** failing families found in this set were fixed with fresh sibling examples (92 rows in `dev_siblings.jsonl`) shown to the tuners, so later runs are weaker evidence than the first. **Real model: BLOCKED** (no authorized key; a key in a git-ignored local file was deliberately not used). Counts exclude 14 policy-dependent rows. Columns: `ab5dc10a` → `5dae2e2d` → `7577f347` → `7dd6efa8` → `6f771108` → `f4dcabd3`; **`a157e68e` equals `f4dcabd3` exactly (0 of 753 grades changed on any path)**.

| Criterion (bar) | local_only | cloud_det | cloud_primary_oracle |
|---|---|---|---|
| A1 non-transactions saved (0) | 24 → 20 → 4 → 0 → 0 → **0** PASS | 44 → 32 → 8 → 0 → 0 → **0** PASS | 0 throughout PASS |
| A2 declined/pending saved (0) | 60 → 20 → 5 → 5 → 5 → **0** PASS | 79 → 27 → 12 → 12 → 9 → **0** PASS | 0 throughout PASS |
| A3 ambiguous saved (0) | 4 → 4 → 4 → 0 → 0 → **0** PASS | 4 → 4 → 4 → 0 → 0 → **0** PASS | 0 throughout PASS |
| A4 wrong amount/currency/direction (≤ 1 %) | 8.0 → 7.1 → 1.8 → 0.0 → 0.0 → **0.0 %** PASS | 13.9 → 12.6 → 3.5 → 0.9 → 0.0 → **0.0 %** PASS | 4.4 → 4.0 → 2.6 → 1.8 → 1.8 → **0.0 %** PASS |
| A4 injection-bearing wrong (0) | 4 → 0 … → **0** PASS | 4 → 0 … → **0** PASS | 0 PASS |
| A5 duplicates (0) | 0 PASS | 0 PASS | 0 PASS |
| A6 lost silently (0) | 12 → 0 … → **0** PASS | 8 → 0 … → **0** PASS | 8 → 0 … → **0** PASS |
| A7 completed to review (≤ 15 / 15 / 5 %) | 34.2 → 31.6 → 28.9 → 28.9 → 27.2 → **27.2 %** (123) **FAIL** | 7.3 → 11.0 → 8.8 → 8.8 → 8.8 → **8.8 %** (40) PASS | 1.8 → 7.7 → 3.1 → 3.1 → 4.0 → **3.1 %** (14) PASS |
| A8b correct AI answer not saved (≤ 5 %) | — | — | 16 → 35 → 14 → 14 → 18 → **14 (3.1 %)** PASS |

A8a (validators on the correct transaction-form answer, 453): server 6 (1.3 %) PASS; **device 34 (7.5 %) FAIL by the letter** — 24 by design (own-account 8, several movements 16), 6 decimal-comma French/Turkish messages, 4 English completed reversals; 8 (1.8 %) on rows whose label requires a save. Server reading alone: processed though not completed 0; completed rejected 102 (all recovered by the device; A6 stays 0). 119 of the 123 `local_only` reviews already went to review at build 147.

**Build 147 with the new server** (mixed mode, `b6fc0dad` client): `cloud_det` A1 44 → 24, A2 79 → 60, A4 13.9 % → 3.5 % (1/0/15), A6 8 → 0, A7 33 → 36; oracle A4 4.4 % → 0. **0 messages worse in any class that changes totals** at `f4dcabd3` and `a157e68e`: the deploy condition in RELEASE-PLAN (c) is met on this set. At `7dd6efa8` and `6f771108` it was **not** met (8 messages: pending-refund notices, standing order "tomorrow").

Development siblings at `f4dcabd3` (= `a157e68e`; fit to known cases, not held-out): families a, b-future, c, d 0 wrong; e (tip/VAT totals) 11 review · 8 review · 0; f (English reversals) 4 · 4 · 4 review.

### 7.6 Reviewer measurements (AI reviewers, synthetic, scratch worktrees)

| Measurement | Reviewer, commit | Result |
|---|---|---|
| 708 probe messages, wrong / silent / review | S, `5dae2e2d` → `6f771108` → `f4dcabd3` = `a157e68e` | Server 52/21/107 → 16/26/64 → **9/26/77**; iOS import 75/3/62 → 16/3/52 → **11/3/62**. 0 outcome changes `f4dcabd3` → `a157e68e` |
| VAL-1 attack, forged "completed" model answers | S, `a157e68e` | Not-completed released as processed 68 → 7 of 96; the 7 are cue-word gaps |
| Redaction, 378 + 246 texts | S, `a157e68e` | 0 new leaks; residual PRIV-1r; device == server on 246 |
| Fuzz | S, `7dd6efa8` | Dart 45,000 texts × 22 entry points, 0 throws; Deno 40,000 × 7, 0 throws |
| Parse time (Mac) | S, `7dd6efa8`, `6f771108` | 20k "Avl. Bal." 11,592 → 29 ms; worst 392 ms at 2,000 characters; server ≤ 42 ms. Not on an iPhone |
| Large-text gate | T, `7dd6efa8` | `+128`; a planted truncation fails the gate |
| Deploy set derivation | T, `7dd6efa8`; this editor, `a157e68e` | T: 8 changed (not 6). This editor: `deploy_set.sh b6fc0dad a157e68e` → the same 8 names as at `f4dcabd3` |
| Admin | ops, `bae159e2` | `npm audit --omit=dev` 0; build ok; auth tests 190 pass, 1 skipped; T: `tsc` clean, authorization 8/8. Signed-in admin NOT TESTED |

### 7.7 Still not run anywhere

A physical device; a CI or Codemagic build; a signed archive (and its Privacy Report); the AI path against a real model; real bank messages; the backend stage at `a157e68e`; `prod_compare.sh` at `a157e68e`; S9/S9b two-device sync; network capture of the linked ad SDKs; Android (out of V1).

### Unsigned iPhone build of the candidate (orchestrator, 2026-11-18)

`flutter build ios --release --no-codesign` at `a157e68e`, with `SUPABASE_URL=http://127.0.0.1:54321`, a placeholder anon key, `SUPABASE_ENV=production`, Google/email/alternate sign-up `true`, `APP_VERSION=1.0.0`, no advertising defines: **succeeded** (`Runner.app`, 69.7 MB, Xcode build 113 s). Read from the built `Info.plist`: `UIDeviceFamily` = [1], `CFBundleShortVersionString` = 1.0.0, `GADApplicationIdentifier` empty. Not signed, not installed, not run; built with placeholder backend values, so it is not the store artifact. Build output removed afterwards.
