# Version 1 — release decision

**Recommendation, 2026-11-18, third round. Not an owner decision.** Prepared for the orchestrating agent (Claude Fable 5.2) under [`docs/release-process/SEVERITY-AND-GATES.md`](../../release-process/SEVERITY-AND-GATES.md) and [`RELEASE-POLICY.md`](../../release-process/RELEASE-POLICY.md), applied strictly. Drafted by the records editor (AI agent, `claude-opus-5-5`) from the issue register, reviews S and T, and the test evidence.

The owner approved the fifteen product decisions in [OWNER-BRIEF-ROUND3.md](OWNER-BRIEF-ROUND3.md) §3 on 2026-11-17. **The owner has accepted no defect and signed no exception.** Nothing in this file records an acceptance.

Candidate: **`a157e68e`** on the local branch `release-readiness/v1` ([RELEASE-MANIFEST.md](RELEASE-MANIFEST.md)). Not pushed, not built by CI, not signed, not deployed, not on a device.

| Scope | Decision for store release |
|---|---|
| iOS (iPhone) | **NOT READY** |
| Backend | **NOT READY** |
| Combined, for the intended launch | **NOT READY** |
| Android | Outside V1 by owner decision 3.1 — not assessed for this release |
| iPad | Outside V1 by owner decision 3.1 (the app is iPhone only; on an iPad it would run in compatibility mode, untested) |

**Separately: ready for the owner to authorize the next steps** — a push to a `release/*` branch so Codemagic can build and sign `a157e68e`, a physical-iPhone test run of that build, and the production package in [RELEASE-PLAN.md](RELEASE-PLAN.md) (after its pre-flight items). Reasons: the strict gate passes at the candidate (15/15, local); the money-correctness review accepts it with follow-up and no open S1; no evaluation path got worse than build 147 in any class that changes totals; the deploy set is derived and unchanged at `a157e68e`; and the remaining blockers can only be cleared by those steps or by the owner. This is not a release decision: nothing reaches users until a later owner decision (G9).

## Why NOT READY (decision rule applied)

- **Open S1 → NOT READY.** Ten S1 rows are still open in some part (ISSUES.md). Seven are fixed in code and wait for a signed build, a device run and (for the parser) the server deploy: V1-001, V1-005, V1-007, V1-014, V1-020, V1-072, V1-078. Three wait for owner actions outside the code: V1-003 (App Store Connect privacy answers), V1-015 (reviewer notes submitted with a build), V1-063 (production ad flags still ON; plan step P4). None can be cleared on this Mac.
- **Gates not met:**

| Gate | iOS | Backend | Why |
|---|---|---|---|
| G0 Candidate frozen | met | met | `a157e68e`; records only after it |
| G1 Automated gates | **met locally** | **met locally** | 15/15 at `a157e68e`, clean tree, on this Mac — **not CI**. One artifact-dependent check deferred to a built artifact; the opt-in backend stage was not run at `a157e68e` (passed at `f4dcabd3`, no SQL change since) |
| G2 Audit complete | met | met | Every checklist row has a status (COVERAGE-MATRIX: 7 PASS, 44 FAIL, 50 NOT TESTED, 1 N/A) |
| G3 Triage clean | **not met** | **not met** | 10 open S1; 26 open S2 with no exception (incl. V1-091 PRIV-1r, the one open S2 from review S) |
| G4 Artifact verified | **not met** | n/a | No signed or CI build of the candidate exists; `ios-signed-release` has never run. An unsigned release build of `a157e68e` compiled on this Mac (`flutter build ios --release --no-codesign`, local placeholder backend values, 69.7 MB; bundle: device family 1, version 1.0.0, AdMob app id empty) — proof that it compiles for the device, not an installable or inspected artifact |
| G5 Device verification | **not met** | n/a | Nothing has run on an iPhone |
| G6 Store and policy | **not met** | — | App privacy answers and export compliance not entered; live legal site still shows the old policy; reviewer notes not submitted |
| G7 Backend ready | — | **not met** | Plan written as one package and the set re-derived at `a157e68e`; but the production comparison and backend stage were measured at `f4dcabd3` and must be re-run in P0; no recovery exists today (PITR off, no backups; owner `pg_dump` proposed, not run); no alerting |
| G8 Independent review | **partly** | **partly** | S: ACCEPT WITH FOLLOW-UP at `a157e68e` (PRIV-1r open). T last reviewed `7dd6efa8`; platform changes after it (restore confirmation copy, consent text, Swift redaction, plan regeneration) were not reviewed by T |
| G9 Owner decision | **not met** | **not met** | — |

## What changed since the round-2 decision (`5dae2e2d`)

| Round-2 blocker | Now at `a157e68e` |
|---|---|
| V1-001 parser (509 → 71 wrong on R's set) | Rebuilt as meaning-first. Held-out set (753, synthetic): 0 non-transactions, 0 declined/pending, 0 wrong amount/currency/direction, 0 lost on every path — weaker evidence than a first run, because families the set exposed were fixed using fresh sibling examples, and the device with Cloud off still sends 27.2 % of correct messages to review (119 of those 123 already went to review at build 147). S's 708 independent probes, iOS import: 75 → 11 wrong, 3 silent; server: 9 wrong, 26 silent. **Still**: synthetic only, no real model, no device, not deployed; residual CUE-1 and PRE-* (S3) |
| V1-072 notices as money | Fixed in code for the measured classes; 0 saved on the held-out set; residual wordings (V1-094) |
| V1-005 / V1-063 ads | Decided (3.2); ads compiled out of the V1 build. Production flags still ON until P4 |
| V1-007 legal pages with Cloud off | Decided (3.5); fixed in code |
| V1-014 iPad | Decided (3.1); iPhone only in code |
| V1-015 reviewer access | Decided (3.11); Sign in with Apple, no blocker found |
| V1-020 restore | Decided (3.3, merge); verified on local stacks by the data specialist and reviewer T |
| V1-006 deletion wording | Decided (3.4); copy, policy text and worker tests aligned |
| V1-022 AI spend ceiling | Guard written and integrated; in the package (P2) |
| V1-025 admin advisories | Next 15.5.29, 0 production advisories |
| Round-2 package (3 functions, no migration) | Regenerated: 7 functions + 1 migration; build-147 condition met (0 worse) |

## Remaining blockers and who clears each

| # | Blocker | Issues | Who clears it |
|---|---|---|---|
| 1 | A signed build of `a157e68e` from the release workflow, inspected (G4) | V1-009, V1-055, V1-016 | Owner authorizes the push and the Codemagic build; confirms the sign-in variables |
| 2 | iPhone device run of MANUAL-DEVICE-TESTS (including MDT-IOS-R3-01 … -16) and a period of real use with real bank messages (G5) | V1-001, V1-005, V1-007, V1-014, V1-020, V1-072, V1-078, V1-065, V1-034 … V1-038 | Owner or a tester with an iPhone |
| 3 | Production package executed and observed (G7) | V1-062, V1-063, V1-022, V1-001 server side, V1-087 | Owner: `pg_dump`, approve package, run P0–P5 (or have it run) |
| 4 | Name leak PRIV-1r (S2): fix it, or sign an exception | V1-091 | Engineering fix round with review S, or the owner |
| 5 | Every other open S2 fixed or excepted (G3) — most clear with items 1–3; still needing work or a decision: real AI model never run (V1-074), no CI for backend behaviour and native tests (V1-012, V1-013), no recovery (V1-023), no alerting (V1-024), export compliance (V1-026) | ISSUES.md S2 list | Owner (key and budget, decisions), engineering |
| 6 | Store items (G6): App privacy answers, export compliance and France, reviewer notes with the build, legal site redeploy, one support address | V1-003, V1-026, V1-015 | Owner, with counsel for export |
| 7 | A narrow re-review by T of the platform changes after `7dd6efa8` (G8) | SP-11 … SP-15 | Engineering (can run now, no owner access needed) |
| 8 | Owner's release decision (G9) | — | Owner |

## Owner actions and access — one list

1. Read this file, [KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md) and [DECISIONS-NEEDED.md](DECISIONS-NEEDED.md) table C; answer C1 (export compliance, with counsel) and C6 (how much review volume is acceptable), and approve, edit or reject the package (C7).
2. Decide on PRIV-1r (V1-091): another fix round, or a signed exception.
3. Authorize pushing `release-readiness/v1` to a `release/*` branch and one `ios-signed-release` build; check in Codemagic that the Apple, Google and email sign-in variables are set (their values are not visible to us).
4. Run, or have a tester run, the device script on an iPhone with that build, including real bank messages over a period of use; an iPad compatibility check if available.
5. Before any production change: take a `pg_dump` yourself (free plan, PITR off, no backups); then let P0 run read-only (archive, `prod_compare.sh a157e68e`, backend stage at `a157e68e`); approve the grants clean-up separately.
6. Provide a Gemini test key with a spending limit for the real-model evaluation (command ready, about 300 requests for the sample, up to about 2,250 for the full set), and set a Google Cloud budget alert.
7. In App Store Connect: enter the App privacy answers ops drafted, answer export compliance (and France), set territories, attach the reviewer notes.
8. After release: redeploy the legal site with the new policy; choose one support address.
9. Name who watches the monitoring queries in RELEASE-PLAN (g) during the observation window.
10. Allow a read-only look, in P0, at the one production account with 540 failed iOS notifications (error 2003) and 2 captures stuck in `processing`.

## Production package (summary of RELEASE-PLAN; nothing executed)

One package, approved or edited as a whole, from `a157e68e`:
- **P0** read-only: archive the deployed sources and compare (`prod_compare.sh a157e68e b6fc0dad 4bde299a a106bd6f`; expected 16 IDENTICAL / 12 DIFFERS, measured at `f4dcabd3`); secret and Vault names; monitoring baselines. Stops on any difference.
- **P1** `account-deletion-worker` (adds profile-photo erasure; rollback v5 `4bde299a`).
- **P2** migration `20261117120000_ai_global_spend_guard` (additive; the only migration).
- **P3** in order: `process-notification-retries`, `process-ios-sms`, `parse-sms`, `bank-discovery`, `enrich-merchant`, `merchant-category-contribution`, with smoke tests; rollback sources recorded for each. The build-147 condition is met (0 worse in total-changing classes, synthetic).
- **P4** the eight advertising flags off (decision 3.2).
- **P5** observe (proposed 7 days).
- Not proposed: `sync-captures`, `send-push-broadcast`, the `evaluate-*` functions; no secret, Vault, Auth or cron change.

## Evidence

[ISSUES.md](ISSUES.md) (status table) · [REVIEW-CLOSURE.md](REVIEW-CLOSURE.md) (127 findings: 43 closed, 51 partly, 27 open, 6 superseded) · [TEST-EVIDENCE.md](TEST-EVIDENCE.md) §7 · [`evidence/audits/S-review-money-correctness.md`](evidence/audits/S-review-money-correctness.md) · [`evidence/audits/T-review-platform-and-records.md`](evidence/audits/T-review-platform-and-records.md) · [`evidence/closure/`](evidence/closure/) · [RELEASE-PLAN.md](RELEASE-PLAN.md) · [`evidence/logs/gate-round3-run4.summary.txt`](evidence/logs/gate-round3-run4.summary.txt) · [MANUAL-DEVICE-TESTS.md](MANUAL-DEVICE-TESTS.md).

## Not performed

No push, merge, production deploy, production configuration or data change, migration, function deploy, flag change, TestFlight upload, store submission, console change, purchase or account creation on any hosted service. Production was only read. The AI model was never called.
