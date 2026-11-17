# Version 1 release readiness — progress log

Resume from here after an interruption. Newest entries at the bottom.

## Fixed facts

- Worktree: `<worktree>/`, branch `release-readiness/v1` (local only, not pushed).
- Candidate base: `ab5dc10a24d393ffe80bb1d459af3aa385b83ba7` = tip of `origin/feat/post-beta-features` (2026-11-17 02:27 +0200). Every local feature branch is already merged into it.
- Last TestFlight build: 1.0.0 (147) from `b6fc0dad` (one commit behind the candidate), Codemagic `ios-signed`, 2026-11-16. Build number read from the Codemagic log.
- The main checkout (`<main-checkout>`, branch `codex/build45-persistence-trace`, September) has untracked user files; it is not touched.
- Orchestrator model: Claude Fable 5.2. Specialists requested as `opus`; each report states the model identifier the agent observed.
- Machine: Flutter 3.47.3 / Dart 3.13.3, Xcode 27.2, Node 26.8.2, Deno 2.9.6, Supabase CLI 2.117.0. No Java, no adb → Android cannot be built or run here. iOS 26.5 simulators available. No physical devices.
- `PUB_CACHE` in the shell profile points at an unmounted volume; use `PUB_CACHE=$HOME/.pub-cache` for Flutter commands.

## Log

| When (EET) | What | State |
|---|---|---|
| 11-17 02:30 | Phase A discovery: branch relations, toolchain, component inventory | done |
| 11-17 02:32 | Baseline `tools/ci_gates.sh` run 1 | invalid for Flutter gates — pub cache path unmounted (environment, not code). Non-Flutter gates: migration lint, catalog drift, deno tests + lint, node contract, skip manifest, admin auth, arch guard, deps policy PASS |
| 11-17 02:40 | Baseline run 2 with working pub cache | running |
| 11-17 02:35 | Specialist audits launched (A scope, B data, C iOS, D Android, E security/privacy, F backend/ops, H tests/artifact/store) + standards research for `docs/release-process/SOURCES.md` | running; reports land in `evidence/audits/` |
| 11-17 02:55 | Reusable process written: `docs/release-process/` README, RELEASE-POLICY, SEVERITY-AND-GATES, MASTER-CHECKLIST, EVIDENCE-TEMPLATE, EXCEPTION-TEMPLATE, RELEASE-RUNBOOK, INCIDENT-AND-RECOVERY | done (SOURCES pending research) |
| 11-17 03:22 | Baseline run 2 finished: 13 gates PASS, 1 FAIL (`flutter test` bulk: 33 failures of 10,695 while eight audits ran on the same machine). The four failing files re-run alone: 281/281 pass in local time and `TZ=UTC`. `head_completeness_test` failed because the tree was not pristine (new docs; `deno.lock` touched by the deno gate, restored). Treated as load-induced; a clean full run is still owed. Log: scratchpad `baseline_ci_gates_run2.log` | done |
| 11-17 03:30 | All seven specialist audits + standards research returned; every agent reported model `claude-opus-5-5`. Consolidated into `ISSUES.md` (V1-001…V1-053) | done |
| 11-17 03:35 | UI/UX audit (G) launched on its own simulator in a second worktree `.claude/worktrees/v1-ui-audit` | running |
| 11-17 03:40 | Fix specialists launched in this worktree with disjoint paths (no commits by agents): parser (V1-001, V1-029, V1-030) · iOS native (V1-008, V1-034) · CI (V1-010, V1-011) · admin + runbook (V1-025, V1-049) · app copy / force-update / timezone (V1-018, V1-041, V1-039, V1-028). Rules in `evidence/audits/_FIX-BRIEF.md` | done |
| 11-17 03:45 | Records compilers launched: SCOPE, SYSTEM-MAP, COVERAGE-MATRIX · MANUAL-DEVICE-TESTS, STORE-READINESS, RELEASE-PLAN | running |
| 11-17 04:45 | Fix batches reviewed by the orchestrator and committed locally (no push): `64e571e5` CI version + skip gate · `f9c5be75` admin Next.js patch + runbook · `d70ba396` iOS manifests + app-switcher cover · `2f2c4707` Help copy · `ff1fc292` zone-less timestamps · `7597bb42` force-update range · `d35fc044` declined transactions, year-less dates, AI grounding (+ orchestrator's AI-skip for declined messages). Targeted suites green (engine/domain/capture/transactions 3134; announcements/onboarding 159; deno process-ios-sms 124; admin 191; node contract 296 pass / 89 credential skips) | done |
| 11-17 04:50 | Records compiled: SCOPE, SYSTEM-MAP, COVERAGE-MATRIX (at `ab5dc10a`, needs refresh for fixes), MANUAL-DEVICE-TESTS, STORE-READINESS, RELEASE-PLAN | done, refresh owed |
| 11-17 05:35 | UI/UX audit G returned (23 findings, 40 before-screenshots). UI fix specialist launched (paths `app/lib/features/**`, theme, l10n, tests; writes UI-UX-REVIEW.md) | running |
| 11-17 05:35 | Independent reviewer launched (read-only; writes `evidence/audits/I-independent-review.md`) | running |
| 11-17 06:10 | Independent review returned (18 findings; NOT READY on all scopes). Rejected the first V1-001 fix; re-rated V1-007/014/015/020 to S1; found six suites that never ran | done |
| 11-17 06:30 | Responses: second declined fix `668f4d64` (+ relay-import check by the orchestrator); gate stage for define-gated suites `29cb1819`; admin images unoptimized `f6dc5076`; removal-suite failures diagnosed as a harness limit (V1-054 → S2 coverage gap) | done |
| 11-17 06:40 | iOS simulator debug build at `f6dc5076` compiled; launch → background → return OK on an iOS 26.5 simulator; cover inside the app switcher not observed | done |
| 11-17 07:00 | UI fixes committed `23499229` (13 UX findings fixed, 2 partly); UI-UX-REVIEW.md written; after-screenshots 45–48 | done |
| 11-17 07:05 | Full strict gate on `23499229`: 14 pass, 1 fail — one stale digit expectation in `story_screen_test` from the UX-13 change. Fixed in `af675aec` | done |
| 11-17 07:10 | Records refreshed to the final commits; RELEASE-MANIFEST, CHANGELOG, KNOWN-LIMITATIONS, AUDIT-REPORT, RELEASE-DECISION, README, TEST-EVIDENCE written | done |
| 11-17 07:10 | Full strict gate on `af675aec` | see TEST-EVIDENCE.md |

## Round 2 (after the owner's review)

| What | State |
|---|---|
| Candidate | `5dae2e2d` = final application code `50957c06` (15 round-2 code commits on top of `d830855e`) + one test-only commit; records commits on top |
| Parser rounds 3–10 and reviews K, L, N, O, P, Q, R | done; final review R accepts with follow-up; no further round by agreement with the owner |
| Restore versus sync: reproduced on a local stack, fixed, re-verified | done; replace-or-merge is the owner's decision |
| Signed-in simulator run, tab-bar fix and its simulator check | done |
| Native iOS tests on a simulator | done (194 passed) |
| Production read-only comparison | done; `evidence/production-comparison.md` |
| Release workflow hardening, removal tests in a configured build, UI round 2 | done |
| Records reconciled; REVIEW-CLOSURE, DECISIONS-NEEDED, action package in RELEASE-PLAN | done |
| Strict gate on `50957c06` | see TEST-EVIDENCE.md |

Local stack `qirsh_v1_verify` (Docker, ports 56321–56330, synthetic data): see `evidence/local-stack.md`. Stop it with the command recorded there when it is no longer needed. The other Docker stacks on the machine were not created by this work.

## Next (for whoever resumes)

1. Owner decisions in DECISIONS-NEEDED.md and the action package in RELEASE-PLAN.md.
2. Push and merge `release-readiness/v1` only when the owner authorizes it.
3. CI build of the merged commit → physical-device run of MANUAL-DEVICE-TESTS.md.
4. Device run with real bank messages before any wide release (parser measurements are on synthetic messages only).
5. Open parser defects RR-01 — only after the owner decides how notices and ambiguous credits should be treated.

## Not done, by design

No push, merge, production deploy, production configuration change, TestFlight upload, or store submission.
