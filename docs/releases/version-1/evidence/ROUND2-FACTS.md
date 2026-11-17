# Round 2 — established facts (2026-11-17)

Single source of facts for reconciling the Version 1 records after the owner's review. Compiled by the orchestrator from commits, test runs and reports. Where a fact was not verified it says so. Nothing here is an owner approval: **the owner has accepted no limitation and approved no scope proposal.**

## 1. Candidate identity

| Name | Commit | What it is |
|---|---|---|
| Audit baseline | `ab5dc10a` | Tip of `origin/feat/post-beta-features`; what audits A–H read |
| Last distributed build | `b6fc0dad` → iOS 1.0.0 (147) | One commit before the baseline; TestFlight internal testing |
| Round-1 code candidate | `23499229` | Baseline + 11 fix commits; the strict gate found one stale test expectation |
| Round-1 final code | `af675aec` | `23499229` + that one test expectation; strict gate 15/15 |
| Round-1 records commit | `d830855e` | Documentation only, on top of `af675aec` |
| Final application code | `50957c06` | `d830855e` + 15 round-2 code commits (below). All earlier names are ancestors of it. This is the only candidate; the earlier names are history |
| **Current candidate** | **`5dae2e2d`** | `50957c06` + one test-only commit (a pinned request in a define-gated test, changed by the restore fix; found by the gate) |
| Round-2 records commits | after this file | Documentation only, on top of `5dae2e2d` |

Counts (`git log --oneline`): 28 commits after the baseline up to `50957c06` — 12 round-1 code commits, 1 round-1 records commit (`d830855e`), 15 round-2 code commits.

Not pushed, not merged, not built by CI, not deployed, not on a physical device. Build 147 contains none of it.

## 2. Round-2 commits (from `git log --reverse d830855e..50957c06`)

| Commit | Subject |
|---|---|
| `0de54a2b` | Treat failed refunds and more failed-payment wordings as not completed; type reversals as refunds |
| `4fc2ecd6` | Give the App Store iOS workflow the same checks as the internal-testing one |
| `34ccc9e9` | Enlarge the remaining small touch targets and fix low-contrast text with existing tokens |
| `837d0881` | Cover data removal through startup in a configured build |
| `8e953d14` | Add an executable reproduction of restore followed by cloud sync |
| `84f2fe41` | Send reversed purchases to review, read plain refund messages, and stop promotions becoming credits |
| `0f90003f` | Keep server identity across restore so restored data syncs without diverging or duplicating |
| `45ea901a` | Show the tab bar again after signing in with a sheet open |
| `42a0fd0c` | Cover more non-completed wordings, stop ignore rules dropping real purchases, and distrust a server result the device reads the other way |
| `0095a239` | Tell the user a pasted declined payment was not recorded instead of asking them to add it |
| `1be44623` | Undo two regressions in non-completed detection and stop informational messages becoming money |
| `c8cef416` | Stop informational words dropping real transactions |
| `5583cbea` | Never take a limit, balance or code figure as the amount, and never hide a message that carries an amount |
| `75dab61a` | Remove the last ways a real movement could end up worse than before the fixes |
| `50957c06` | Take back the direction words and amount rule that turned debits into income |

Parser rounds in order: `d35fc044` (1), `668f4d64` (2), `0de54a2b` (3), `84f2fe41` (4), `42a0fd0c` (5), `1be44623` (6), `c8cef416` (7), `5583cbea` (8), `75dab61a` (9), `50957c06` (10). Rounds 1–2 are round-1 commits.

## 3. Bank-message parser (V1-001 and related) — state at `50957c06`

**History, plainly.** Ten fix rounds. Every round was followed by an independent review with new adversarial messages, and every review found more. Five rounds introduced regressions that a later review caught: round 5 (`42a0fd0c`: "Merchant declined" read as a merchant name; a direction conflict confirmed the device's reading), round 6 (`1be44623`, REJECTED: informational words silently dropped completed transactions), round 7 (`c8cef416`: a smaller silent-loss class and server rejections of correct records — OR-01, OR-02, OR-08), round 8 (`5583cbea`: incoming credits with a limit line pre-filled as payments, and a silent class for unlisted currency forms — PR-01, PR-02), round 9 (`75dab61a`, REJECTED: outgoing debits imported as confirmed income). Each was removed by a later round; round 10 is subtractive and review R found no regression from it. Round 8 also fixed a pre-existing defect no audit had found: a limit or balance figure taken as the transaction amount. Round 10 is subtractive (removes round 9's additions).

**Reviews of the parser** (none is an approval; none covers later code): I at `d35fc044`; K at `0f90003f`; L at `0095a239`; N at `1be44623` (REJECT); O at `c8cef416` (accept with follow-up); P at `5583cbea` (accept with follow-up; three outcomes worse than baseline); Q at `75dab61a` (REJECT); **R at `50957c06` — the final code — ACCEPT WITH FOLLOW-UP, no S1, no regression from that commit on the device or effective path.** The parser commits are therefore independently reviewed up to and including the final one. No further fix round was made after R.

**Final independent measurements (review R, own harness, 1,758 de-duplicated messages with hand truth; candidate versus the audit baseline `ab5dc10a`, which is also what TestFlight build 147 runs one commit earlier):**

| Wrong total-changing outcomes | Baseline | Candidate |
|---|---|---|
| Device, bank sender | 454 | 66 |
| Device, no sender | 314 | 51 |
| Server | 375 | 63 |
| Effective iOS-Cloud path, bank sender | 509 | 71 |
| Effective iOS-Cloud path, no sender | 412 | 63 |

- Declined or not-completed messages recorded as money on the effective path with a bank sender: 174 → 4.
- On 163 probes the fixers never saw: 39 → 20 (effective path, bank sender).
- **Worse than the baseline:** device 0 and effective path 0 against both `ab5dc10a` and `0095a239`, with one device case without a sender (a message that moved from review to a USD 20 record, which R judged equal across the whole system). Server only: 21 completed messages are rejected where the baseline handled them (11 against `0095a239`) and one wording ("Cashback reversal … deducted") is read as a refund; every one of these is kept for review by the device and on the effective path, so none is lost — but the server and the device build must ship together; a mixed version pair was not measured.
- **Cost — correct messages that the baseline recorded and the candidate sends to review:** 0% on the repository corpus and golden fixtures; on the probe set 14.7% (device, bank sender), 8.6% (device, no sender), 6.8% (server), 14.3% (effective, bank sender), 11.3% (effective, no sender). Total-neutral, but more manual review for the user.
- **AI candidate validator** rejects 353 of 1,306 correct candidates on each side (170 device / 203 server at the baseline). Effect: review only.
- Silent loss: none on the device or effective path (re-checked on the sets where earlier rounds lost messages).
- Reviewer's judgement: the candidate is the best parser state of the commits measured (`ab5dc10a`, `0095a239`, `5583cbea`, `75dab61a`, `50957c06`) and is safer than the baseline on the device and effective paths; not tested: the AI legs against a real model, installed builds, the deployed server.

**Still wrong at the candidate (review R, effective path with a bank sender; each equally wrong at the baseline) — open defects, not accepted limitations (RR-01):** 34 notices recorded as money (due or scheduled bills, expected salary, deposit adverts); 18 wrong directions, mostly outgoing money booked as income (deposit wording, "salary transfer … debited", "cashback reversal … deducted"); 8 own-account transfers counted as spending or income; 6 record the foreign-currency figure instead of the amount charged.

**Mechanics.** Rule in `app/lib/engine/parser/transaction_state_cues.dart` and the parser engine, mirrored in `supabase/functions/process-ios-sms/parse.ts` + `parser_rules.json`; a drift test keeps the lists equal. Shared cases: `supabase/functions/process-ios-sms/declined_cases.json`, **1,565** synthetic cases run by Dart and Deno with expected outcome, amount, currency and direction; a pinned deviations allowlist (`declined_cases_deviations.json`); 75 rows carry an explicit open-defect pin (74 no worse than the baseline; one — the cashback reversal — worse on the server only). Review R confirmed the guards fire under mutation and graded all 256 rows changed in round 10 as moves toward review.

**Policy applied (owner's):** not completed → no total change; ambiguous → review; a refund or reversal of an original that was declined → review; "purchase … reversed" → review; a server result whose direction or amount contradicts the device's own reading is not confirmed; informational words can never silence a message; a limit, balance or code figure is never the amount.

**Not protected:** transactions already stored (proposal only: `HISTORICAL-REVIEW-PROPOSAL.md`); installed builds (147 and older) keep their old local parser; the server until `process-ios-sms` and `parse-sms` are redeployed from the candidate. The Swift notification preview still matches by substring (notification wording only).

**Not universal coverage.** These are measurements on synthetic probe sets, not on real bank traffic. No physical-device run exists.

## 4. Restore versus cloud sync (V1-020)

- Reproduced on a local Supabase stack (`evidence/local-stack.md`): after restore and two sync cycles device and cloud stayed different; a cloud-only row never returned; with the backfill active (fake backend) each restored row was duplicated in the cloud.
- Fixed in `0f90003f` for 12 entity types; no schema or backup-format change; guest restore unchanged.
- Verified: unit tests against an in-memory fake backend (fail before, pass after) and the live local stack test `restore_then_sync_local_supabase_test.dart` — failed on both scenarios with the old code and passed with the fix, with and without a configured build (orchestrator run).
- **Open owner decision: replace versus merge** for cloud rows absent from the backup. Current default is merge (kept and pulled back; nothing deleted). Under merge, a row created after the backup and not yet synced comes back after restore, and the restore confirmation text says the data is "replaced" (final review FR-06).
- Other notes: a row tombstoned in the cloud is not un-deleted (shown as a sync conflict); a fresh-install restore whose amount differs from the cloud becomes a user conflict; rows the server never had may wait for the next session's backfill; the full re-pull cost on a large account was not measured.

## 5. Runtime evidence gathered in round 2

| What | Result |
|---|---|
| Native iOS XCTests (first valid run ever) | 194 tests, 0 failures, iPhone 17 simulator iOS 26.5, at `d830855e` (no `app/ios` change since). An earlier run with a full disk is not evidence |
| Signed-in shell on simulators (file J) | Commit `8e953d14`, iPhone 17 and SE, iOS 26.5, local stack, synthetic account, real email-code sign-in UI with the code minted through the local admin API. 44 items seen, 5 not reached (error/offline state, notification permission denied, delete-account confirmation dialog, native tab-bar taps and edge-swipe, live app switcher). 45 screenshots |
| Fixes confirmed on the simulator | Manual add with no pre-selected category and its validation; add and close button labels; SE budget chips and titles; corrected Help text; app-switcher cover seen in the snapshot iOS stores (the live switcher was not opened); text scale cap 1.25× (capped rendering only — not full accessibility sizes) |
| Paste with Cloud off | Declined, declined-with-refund-boilerplate and failed-refund samples rejected; spend unchanged |
| RT-01 found and fixed | After email-code sign-in the native tab bar never appeared. Fixed in `45ea901a`; confirmed on a simulator at `0095a239` on three fresh installs, with a control build (old observer) reproducing the defect (file M). Build 147 has the same defect and email sign-in is enabled in the workflow that built it |
| Removal journeys in a configured build | 10/10 with the gate's exact command |
| Local stack | All 134 migrations apply cleanly to a fresh database |

Still not done anywhere: physical device, Android build or run, CI build of the candidate, signed build, VoiceOver focus order, push, Shortcuts, share extension, full device accessibility text sizes.

## 6. Production (read-only) — see `evidence/production-comparison.md`

- Migrations: production ledger = the candidate's 134 migrations exactly. **No migration is needed for this release.** (Ledger holds names, not content.) V1-002 closed for the ledger.
- Functions: 28 deployed of 33; the five missing are the affiliate functions and `parser-test` (decision D-14). Compared with the candidate at the time: 22 identical, 6 different. **The comparison was made against `af675aec`; since then `process-ios-sms` and `parse-sms` changed again in the candidate.**
- Smallest justified deployment set: `process-ios-sms` (V1-001), `parse-sms` (V1-060 amount grounding; the app re-grounds, so lower urgency), `account-deletion-worker` (V1-062: the deployed one predates profile-photo erasure and its job runs every 5 minutes). The four functions that differ only by the push-sender refactor (`evaluate-budgets`, `evaluate-gamification`, `evaluate-goals`, `process-notification-retries`) are NOT proposed: no behavior need established.
- Flags in production: **all advertising flags on at 100%** (contradicts decision D-19 as recorded); `local_auto_confirm_v2` off; `capture_ai_fallback_enabled` off. Ads render only in a build carrying AdMob IDs: `ios-signed` does not attach them; `ios-signed-release` and `android-release` do. Final review FR-05 rates this S1 for any store build with AdMob IDs.
- Backups: point-in-time recovery off; the API lists no backups. Any plan step assuming restore is not available. V1-023 confirmed.
- Advisor: two `SECURITY DEFINER` functions executable by `anon` are trigger functions and cannot be invoked through the API (final review FR-09 → S4, revoke for hygiene); 26 functions with a mutable `search_path`; leaked-password protection off (no password sign-in).
- Secrets: names only. Not set: `GEMINI_SMS_MODEL`, `GEMINI_MODEL` (defaults in effect: `gemini-3.8-flash`, `gemini-2.5-flash-lite`), `GOOGLE_MAPS_API_KEY`, `GEMINI_SHADOW_API_KEY`.
- Still unknown: Auth hook and Vault (dashboard), Codemagic variable values, admin panel exposure, cron run history.

## 7. Official-documentation checks — `evidence/official-doc-checks.md`

Privacy-manifest reason codes confirmed from Apple's documentation JSON: `CA92.1`, `1C8F.1`, `C617.1` correct for the use; `85F4.1` correct narrowly (value shown only on a debug screen; clipboard copy unconfirmed) — cleanest fix is compiling the disk probe out of release builds (not done). Reviewer access is blocked as documented (no password sign-in exists; email uses a one-time code). The manifest and store privacy answers miss four data types. `ITSAppUsesNonExemptEncryption=false` needs an export determination. In-app support address differs from the policy's.

## 8. Decisions

`DECISIONS-NEEDED.md` (written before the last fixes) found 4 settled by project records — Android out of V1 (V1_EXTERNAL_BLOCKERS EB-003 and V1_MASTER_PLAN, 2026-09-15), non-personalized ads with no ATT prompt (D-6), AdMob configuration frozen with ad flags shipping off (D-19 — **now contradicted by production, where the flags are on**), shared category learning on by default (privacy policy §3/§4) — and 21 open. New since then: restore replace-vs-merge (V1-020); whether a refund of a declined original should reduce spend (currently review); ad flags on in production versus D-19; wording for RT-03.

## 9. Gate

The strict gate on `50957c06`: see `TEST-EVIDENCE.md` (filled by the orchestrator). Until that row exists, no gate result may be stated for the current candidate; the last full pass was at `af675aec`.

## 10. Independent reviews

| File | Reviewed | Scope | Outcome |
|---|---|---|---|
| I | `d35fc044` | Round-1 fixes except UI | NOT READY; 18 findings REV-01…18 |
| K | `0f90003f` | Every commit after the baseline including UI and restore | NOT READY; 13 findings FR-01…13; REV statuses: resolved 03, 07, 12, 13, 16, 17; partly 01, 02, 04, 06, 08, 09, 15; open 05, 10, 11, 18; superseded 14 |
| L | `0095a239` | `42a0fd0c`, `45ea901a`, `0095a239` | V1-001 stays S1 OPEN; findings LR-01…LR-12; `45ea901a` accepted; the other two accepted with follow-up |
| M | `0095a239` | Simulator check of the tab-bar fix | CONFIRMED FIXED ON SIMULATOR with a control build reproducing the defect; device, Apple/Google sign-in and app lock not tested |
| N | `1be44623` | The sixth parser commit | REJECTED in that form: NR-01 (S1 regression, silent loss), NR-02, NR-03 |
| O | `c8cef416` | The seventh parser commit | ACCEPT WITH FOLLOW-UP; OR-01 (silent regression, 3 probes), OR-03 (limit figure as amount, pre-existing), OR-04, OR-05 |
| P | `5583cbea` | The eighth parser commit | ACCEPT WITH FOLLOW-UP; three outcomes worse than baseline (PR-01, PR-02, PR-04) |
| Q | `75dab61a` | The ninth parser commit | REJECT: outgoing debits imported as confirmed income (QR-01), QR-02, QR-03 |
| R | `50957c06` | The tenth (final) parser commit, with a state-of-the-parser statement | ACCEPT WITH FOLLOW-UP; no S1; nothing worse than baseline on device or effective path; RR-01 open defects carried from the baseline |

No review is an approval. An earlier review does not cover later code.
