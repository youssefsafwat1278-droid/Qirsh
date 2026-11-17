# R — Independent review of the tenth parser commit (`50957c06`) and the state of the parser

- Reviewer model: `claude-opus-5-5` (Opus 5.5). I wrote none of the code under review and none of the earlier reviews (K, L, N, O, P, Q).
- HEAD reviewed: `50957c06c2a1bf037eabdb73b3e224452caa32a1`, branch `release-readiness/v1`, worktree `.claude/worktrees/v1-readiness`. Date 2026-11-17.
- Scope: commit `50957c06` (round 10, subtractive), which answers review Q (QR-01..QR-03 on `75dab61a`).
- Comparison points: audit baseline `ab5dc10a` ("ab", = TestFlight build 147's parent state), `0095a239` ("base"), round 8 `5583cbea` ("r8"), the parent `75dab61a` ("par").
- Constraints kept: no tracked file changed (`git status --short app supabase` empty after every run, including `deno test`); this file is the only file written in the repository; no simulator, no Docker, no production; synthetic messages only. Older code ran from scratch `git worktree add --detach` trees under my scratch directory, removed at the end (§9).

## 1. Harness (my own)

Scratch: `<scratch>/RR/` (`h/` code, `in/` inputs, `out/` results).

- **Server** (`h/srv.ts`): the version's own `parseSms` on `redactThirdPartyNames(redactPii(raw)).trim()` (what `index.ts:137,266-268` parses), AI off; processed = `accepted && amount && currency` (`index.ts:335`). A second call with AI allowed and a `beforeAi` hook returning false separates *unresolved* (would reach the AI: review) from *IGNORED/rejected with no AI* (silent on the server).
- **Device** (`h/tmpl.dart` → `dev_{ab,base,r8,par,head}.dart`): `isIgnoredMessage`, then `ParserEngine.parse`, sender `null` (dN) and `AlRajhi` (dB). A `drop` is a Smart Inbox card for both (null sender is bank-like, `bank_sender_filter.dart:20`; `add_transaction_usecase.dart:896`).
- **New in this harness — the booked outcome, not the parser type.** A recorded row is graded on what reaches the totals: the use case resolves direction as `DirectionSignal.detect(raw) ?? type` and turns a transfer (or a transfer-worded message) into income or payment by that direction, an own-account transfer or an incoming withdrawal into a neutral transfer (`add_transaction_usecase.dart:1127-1158`, byte-identical at all five versions — md5 of the block checked); totals count by **type** (`drift_transaction_repository.dart:726-747`). Server rows are booked as `capture_sync_service.dart:1068-1079`.
- **Effective iOS import (non-AI-primary, AI off)**, per version: ab — validated server row imported, else local (`capture_import_service.dart:525` at ab); base — also `!localParseOpposesDirection` (base `:525-563`); r8/par/HEAD — validated, then `localParseContradictsServer` → Smart Inbox, else imported (`:525-541`); a server row that is not processed falls back to the device parse.
- **Grades**: OK, REVIEW (review/drop/inbox/unresolved), SILENT, WDIR (wrong direction), WAMT, WCUR, WREC (a not-completed message or notice recorded as money), WOWN (own-account transfer booked as spend/income), WNEU (a movement booked neutral). A cash/ATM deposit is accepted as income or neutral (the use case's own comment, `add_transaction_usecase.dart:1120`, calls it neutral; see RR-05).
- **AI validator** (`h/ai.ts`, `h/ai.dart` run as a scratch `flutter test` inside each scratch tree): the correct candidate (true amount, currency, type, direction) through `validateAiCandidate` (server) and `AiCandidateValidator` (device).

**Inputs.** Q's sets copied from `…/scratchpad/Q/in/` (P's 1,154 + Q's 250 + g5 11), all **1,565** rows of HEAD's `declined_cases.json`, the corpus (263), golden fixtures (462), N's 66 golden limit-line variants, N's 122 AI candidates, and **163 new hand-labelled messages of mine** (`in/mine.json`, built by `h/mk_mine.py`): 40 outgoing transfers/fees/wages with inflow phrases, 40 genuine incoming credits, 20 `POS` whole-word cases, 15 deposit wordings, 20 due/scheduled clauses, 20 label-then-amount purchases, 8 notices with inflow phrases. After de-duplicating by text across all truth-labelled sets: **1,758 messages (1,389 completed, 175 not-completed, 194 notices/OTP/adverts)**.

**Commands and actual results**

| Command | Result |
|---|---|
| `git rev-parse HEAD` | `50957c06c2a1bf037eabdb73b3e224452caa32a1` |
| `flutter test --no-pub` `declined_cases_totals_test.dart` `declined_state_cues_table_test.dart` `round9_regression_test.dart` | `03:35 +3065: All tests passed!` |
| `deno test --allow-all process-ios-sms/ _shared/` | `ok \| 692 passed \| 0 failed \| 2 ignored`; `deno.lock` unchanged |

## 2. The acceptance rule — nothing worse than the baseline

Worse = HEAD SILENT where the baseline was not; HEAD wrong (WDIR/WAMT/WCUR/WREC/WOWN) where the baseline was not wrong; or a different wrong. De-duplicated truth set, 1,758 messages.

| Side | vs `ab5dc10a` | vs `0095a239` |
|---|---|---|
| Device, bank sender | **0** | **0** |
| Device, no sender | 1 (A028, see below) | 1 (A028) |
| Server | **21 silent + 1 wording class wrong direction (2 msgs)** | **11 silent** |
| Effective, bank sender | **0** | **0** |
| Effective, no sender | **0** | **0** |

- **A028** `Purchase of USD 20.00 … Charged SAR 75.00`: device with no sender went review → USD 20 (truth SAR 75). It equals what ab already did with a bank sender and on the server/effective path (USD 20 everywhere), so nothing changes system-wide. Not counted as a violation; listed for completeness.
- **Server direction (fixer's exception a): confirmed.** `Cashback reversal: SAR 15.00 deducted from account *5678` (Q015 = T1330) and my MA06 `Cashback reversal SAR 15.00 deducted from your card *4521`: ab server unresolved → HEAD server refund. The device was already refund at ab, and the ab effective path imported the device refund, so the effective path is unchanged (WDIR at every version). Server-only; total-neutral relative to ab on the iOS path.
- **Server silent (fixer's exception b): confirmed, none lost.** 21 completed messages vs ab, 11 vs base (fixer: 27/16 on its counting). All 21 are review on device (both senders) and on both effective paths (listed: G10 `…Merchant Declined Store…`, LX_M14, CU_W00/01/03/04/06/07, R10/11/12/14, T0113/0114/0156/0157/0158/0197/0198/0205/0213 — e.g. `Bounced cheque fee SAR 100.00 debited…`, `Salary SAR 12,000.00 credited… Bonus not posted yet.`, `Refund … for the item that was returned`). On AI-primary a rejected capture is persisted to Smart Inbox (`capture_import_service.dart:495-518`). None comes from this commit (all silent at par).
- **Purchase-OTP silences (exception c): genuine codes.** The only device/effective rows silent at HEAD and review at base are `Use 482913 as OTP to complete SAR 100.00 purchase…`, `482913 is the code to confirm your purchase…`, `Verification code for transaction of SAR 100.00…: 4821`, `Enter code 482913 to approve the purchase…`, `Your one time password for SAR 250.00…` (silent at ab too), and two adverts that ab/base recorded as payments (`Exclusive offer(s)…`). All correct.
- **credit→transfer (exception d).** Rows whose device type went income (par) → transfer (HEAD): MA29/MA30/MD13 (English, outgoing transfers containing `deposit`) are still **booked as income** by the use case because `deposit` is a `DirectionSignal` credit word — wrong, but identical at ab; MA31/Q078 (Arabic) are now booked as payment — right. So the stored result is right for the Arabic ones and wrong (as at ab) for the English ones.

**QR-01 / QR-02 / QR-03 re-run** (Q's ids, my harness, HEAD vs ab, all five sides):
- QR-01: Q003, Q004, Q007, Q011, Q013, Q014, Q018, Q024, Q045, Q046, Q047 — **no income anywhere**; each equals ab on every side. Q021, Q025, Q027, Q052 went from ab-OK to REVIEW (cost). Own transfers Q029/Q037/Q038 → review; Q043 back to ab (spend); Q044 neutral.
- QR-02: Q012/Q022/Q023 no income (Q022/Q023 device → review; server/effective OK). Q076/Q077 remain **income on every side, equal to ab** (booked: device transfer + `deposit` credit word). Q078 device OUT (fixed), server/effective income (= ab). Q157 device 50 → review with a bank sender; server and effective **5,000 → 50 (fixed)**. Q140/Q147/Q158/Q159/Q162: review everywhere (ab recorded 9,000/5,000/9,000/5,000 on the server and effective path — fixed).
- QR-03: Q151, Q242, Q243, Q248: review everywhere (fixed vs par; vs ab Q151 server and Q243/Q248 device-bank were recorded at ab — fixed).

## 3. The cost: correct → review

Share of completed messages that the baseline booked correctly and HEAD sends to review.

| Set | Side | vs ab | vs base | vs parent |
|---|---|---|---|---|
| **Corpus (137 completed) + golden (462 + 66)** | every side | **0** (one ambiguous: K136 `Purchase 500.00 EGP refund pending`) | 0 | 0 |
| **Full probe set (1,389 completed)** | device, bank | 125/852 = **14.7%** | 118/881 = 13.4% | 203/1,043 = 19.5% |
| | device, no sender | 50/579 = 8.6% | 43/604 = 7.1% | 36/686 = 5.2% |
| | server | 52/765 = 6.8% | 52/756 = 6.9% | 109/852 = 12.8% |
| | effective, bank | 141/983 = **14.3%** | 126/972 = 13.0% | 187/1,066 = 17.5% |
| | effective, no sender | 94/833 = 11.3% | 79/821 = 9.6% | 125/899 = 13.9% |

- On the repository corpus and golden fixtures — the closest thing to ordinary traffic in the repo — **no message that the baseline recorded correctly now waits in review**; every corpus/golden change against ab/base is a fix (92 declined rows no longer recorded; G007–G009 limit/balance amounts 9,000/1,234.56/20,000 → the true 8/14/0.1; G010/G013/G017/G018/G020/G021/G036/G039 direction/amount fixes; K017/K087/K076 credits). Caveat: the corpus has no transaction carrying a notice or limit footer, which is exactly where the cost sits.
- On the probe set the review cost is concentrated in completed movements that carry a notice footer (`Card activated`, `Credit limit…`, `e-statement…`) or use a word removed from the money list (`authorised`, `approved`, `posted`, `direct debit`, `standing order`, `payroll`, `قيد`), plus `POS` whole-word (`mPOS`, `ePOS`, `posted`, `Repos…`: 7–9 of my 20 POS probes go review with no sender and on the server; still recorded with a bank sender and on the bank-sender effective path).
- **The fixer under-reports the cost of this commit.** Against the parent on the shared table alone my harness counts correct → review device-bank 194, device-none 33, server 96, effective 178 / 113 (fixer: 74 / 29 / 28 / 74–76). The table diff itself shows 167 rows pinned `device: None → review`, 12 `completed_income → review`, 1 `transfer → review`, 97 `server: None → unresolved`.
- **AI validator rejecting correct candidates (NR-02 class) — returned.**

  | Candidates (correct) | n | server ab / base / par / HEAD | device ab / base / par / HEAD |
  |---|---|---|---|
  | N's 122 | 122 | 1 / 1 / 1 / **1** | 1 / 1 / 1 / **1** |
  | mine | 144 | 4 / 4 / 4 / 3 | 0 / 1 / 1 / 1 |
  | Q's | 174 | 22 / 22 / 27 / 28 | 19 / 19 / 17 / 19 |
  | table (rest) | 866 | 176 / 175 / 228 / **321** | 150 / 165 / 232 / **332** |
  | all | 1,306 | 203 / 202 / 260 / **353** | 170 / 186 / 251 / **353** |

  Against ab: server newly rejects 169 (accepts 19 new), device newly rejects 211 (accepts 28). Reasons at HEAD: `not_a_transaction` 228 server / 239 device. Examples: `Card *4521 authorised SAR 45.00 at Test Diner. Credit limit: SAR 20,000`, `Test Diner: SAR 45.00 approved on card *4521\nYour e-statement is available`, `Minimum payment SAR 115.00 has been paid` (`amount_is_account_figure` after the verb-after-figure rule was removed). The table's own `ai: not_a_transaction` pins rose 107 → 255 (+138 as the fixer says). N's 122 is unaffected because it holds no removed money word. Effect: an AI-primary capture of such a message is rejected and kept in Smart Inbox; no wrong total.

## 4. Did removing the round-8 money words bring back silent loss?

**No.** Recorded (at ab, base, r8 or par) → silent at HEAD on device and effective sides: O's three probes (P20_3, P40_6, P43_5) are review on all five sides at ab and HEAD; P's 182 notice-line probes `nc`: **0** silent on every side; N's 66 golden variants: 0; corpus/golden: 0 (the 12 corpus device silences are OTP/advert rows, never recorded). Mechanism: `isIgnoredMessage` now returns false unless an original ignore word is present (`parser_engine.dart:166-171`), so a notice word alone never silences. Server-only silent rows are those in §2.

## 5. The shared table

- **75 `OPEN` pins** (all `src: V1-RES10`, 44 not_completed, 17 payment, 8 own transfer, 4 income, 2 credit): run at ab on all five sides, **74 are no worse than ab; 1 (T1330, cashback reversal) is worse on the server alone** (ab unresolved → refund), equal on the effective path. At HEAD the 75 still carry, on the bank-sender effective path, 20 notices recorded, 9 wrong directions, 6 own transfers booked, 1 amount, 1 currency — all as at ab.
- **256 changed rows**: every change is toward review — `device: None→review` 167, `completed_income→review` 12, `transfer→review` 1, `server: None→unresolved` 97, `ai: None→not_a_transaction` 138. I graded all 256 at HEAD on five sides: **0 wrong, 0 newly silent**; I read 85 by hand (random sample, seed 7): each is a completed movement now in review or an AI pin; none moves toward a wrong record.
- **The test relaxation** (`parse_test.ts:545-556`): a wrong pinned side must carry a `defect` string, and only `V1-RES10` rows may carry one. Guards fire (mutations on a scratch copy of the table in a scratch worktree, `deno test process-ios-sms/parse_test.ts`, baseline `31 passed`): completed row set to device `ignored` → FAIL; amount + 1 → FAIL; currency SAR→USD → FAIL; a `defect` on a non-RES10 row → FAIL; a pinned wrong server row with its `defect` removed → FAIL; Q076 appended as `completed_payment` → FAIL. Appending `Wages paid to employee SAR 3,000 from your account…` as `completed_payment` → passes (correct: the server now reads it as a payment). Engine mutations (Dart table tests): see §8.
- **The four tip/VAT rows** (A117, A146, A133, A143) are still not in the table; their outputs are identical at ab and HEAD (45, 10, 2.25, 2.25).

## 6. Earlier guarantees (K, L, N, O, P probe sets; Q's g5)

- K+L (`kl`, 195), N (122 + 66), O/P (`own` 186, `amt` 168, `bal` 22, `cr` 144, `nc` 182, `otp2` 12, `otp` 39, `notice` 44, `cue` 40): **no new wrong total change** on any device or effective side against ab or base; only the server silences of §2.
- "Merchant declined" (G07–G09): review on device/effective, server rejected — holds. `…at Merchant Declined Store` (G10) is a server silence (review elsewhere).
- Ignore word inside a merchant name (Offer Mart, Click Pharmacy, Promo Burger, Won Kitchen, Promotion Plaza, Winner Sports): recorded on every side (silent at ab — fixed). `مقهى عرض خاص` (G06) is still silent on the device with no sender (as at ab); review on the effective path.
- Direction conflict → Smart Inbox: at HEAD 13 (bank) / 10 (no sender) device-vs-server direction conflicts go to the inbox; 3 still import the server row (MA04 `Salary transfer … debited`, MA31, Q078 — device type `transfer` counts as direction-unknown in `localParseOpposesDirection`, `validated_capture.dart:240-247`); at ab 78/31 conflicts imported the server row. The sync path calls the same function (`capture_sync_service.dart:956`).
- Limit/balance/code figure never the amount, whole-word currency: 0 WAMT/WCUR regressions; still wrong at every version: Q120 `SR1,250.00` → 250, Q103 `…at USD Store` → USD, and four FX rows (A006/A007/A008/A060) recording the foreign figure.

## 7. Findings

| ID | Sev | Finding | Action |
|---|---|---|---|
| RR-01 | **S2** (carried; impact class S1, frequency SUSPECTED) | Residual wrong total-changing outcomes at HEAD, each equally wrong at ab: notices recorded as confirmed money (34 of 194 notice probes on the bank-sender effective path: `Your bill of SAR 300 is due…`, `Payment of SAR 1,200 is scheduled…`, `Your expected salary of SAR 12,000 will be credited…`, `Deposit SAR 1,000 or more to get a free card`); outgoing payments/transfers with `deposit`/salary/fee-deducted wording booked as income (18: `Security deposit SAR 1,000 paid to Test Landlord…`, `Transfer SAR 1,000 to Ali for rent deposit`, `Deposit handling charge SAR 15.00 debited`); own-account transfers booked as spend/income (8); foreign figure recorded (6). | Owner decision: keep V1-001 open as a known limitation with these classes, or fix `deposit` as a credit word in `DirectionSignal`, and future-tense notices. |
| RR-02 | S3 | Review volume: correct → review vs ab is 0 on the corpus/golden but 14.7% (device bank) / 14.3% (effective bank) / 11.3% (effective none) / 6.8% (server) of baseline-correct completed probes; vs the parent 203/36/109/187/125 — about 2.5× what the commit reports. | Monitor review-queue volume after release; restore a whole-word money list for `authorised/approved/posted/direct debit/standing order` only where no limit line follows, if volume is high. |
| RR-03 | S3 | AI validator again rejects correct candidates (NR-02 class): 353 of 1,306 on each side vs 203/170 at ab; +138 table pins. N's 122 unaffected. Review-only for AI-primary users. | Same as RR-02; track in known limitations. |
| RR-04 | S3 | Server-only regressions vs ab: 21 completed messages rejected with no AI (11 vs base), and the cashback-reversal wording read as a refund. Device and effective path recover all as review; anything that reads only the server row (push text, server-side totals before device import) sees nothing or a refund. Not from this commit. T1330 is pinned "as at ab or better" but is worse on the server alone. | Keep tracked; correct the T1330 pin text. |
| RR-05 | S3 | An ATM cash deposit is now booked as **income** (gold G014 ×13, corpus K014), while the use case's own accounting comment says it is a neutral transfer (`add_transaction_usecase.dart:1120`). Introduced in round 9, narrowed (not removed) here. | Owner policy decision. |
| RR-06 | S3 | A device `transfer` type never contradicts a server direction, so a server income on an outgoing transfer imports confirmed (3 probes; 78 at ab). | Treat the booked direction of a transfer in `localParseOpposesDirection`. |
| RR-07 | S4 | Commit message/claims: "75 pinned … no worse than the audit baseline" is true except T1330 on the server; review-cost numbers understated (RR-02). | Docs. |

No S1 and no regression attributable to this commit on the device or the effective path.

## 8. Verdict for `50957c06`: **ACCEPT WITH FOLLOW-UP**

QR-01/02/03 are resolved without new wrong records; the commit's only effects against its parent are total-neutral (records → review) plus fixes. Follow-up: RR-02/RR-03 (measure review volume), RR-04 pin text, RR-05 policy, RR-01 owner decision.

Engine-mutation results (scratch worktree, Dart table tests): with the new inflow-hint review rule disabled (`parser_engine.dart:668-675`), the three table tests FAIL (flutter's failing-test list ends "… and 46 more"); with the new due-figure rule disabled (`:577-590`), they FAIL ("… and 2 more"). Both new rules are guarded. The engine file was restored and the scratch tree removed afterwards.

## 9. The state of the parser at HEAD, compared with the audit baseline `ab5dc10a` (TestFlight 147's parser)

**Wrong total-changing outcomes**, de-duplicated truth set of 1,758 synthetic messages (1,389 completed, 369 not a completed movement). Format ab → HEAD.

| Kind | Device, bank | Device, none | Server | Effective, bank | Effective, none |
|---|---|---|---|---|---|
| Declined / not-completed recorded | 165 → 3 | 154 → 2 | 150 → 3 | 174 → 4 | 165 → 3 |
| Notice recorded as money | 114 → 26 | 81 → 17 | 117 → 29 | 145 → 34 | 122 → 27 |
| Wrong direction | 126 → 23 | 42 → 20 | 79 → 17 | 137 → 18 | 77 → 18 |
| Own transfer booked | 12 → 10 | 10 → 8 | 9 → 9 | 12 → 8 | 12 → 8 |
| Wrong amount | 20 → 3 | 11 → 3 | 20 → 5 | 27 → 6 | 23 → 6 |
| Wrong currency | 17 → 1 | 16 → 1 | 0 → 0 | 14 → 1 | 13 → 1 |
| **Total** | **454 → 66** | **314 → 51** | **375 → 63** | **509 → 71** | **412 → 63** |
| Completed silent | 36 → 0 | 36 → 3 | 23 → 30 | 23 → 0 | 23 → 0 |

The split of "recorded although not a completed movement" into declined/not-completed versus notice uses a keyword classifier over the text (`h/state.py`), so it is approximate; the totals are exact under my grading. The truth set is synthetic and deliberately aimed at known weak spots, and part of it (the table) was tuned against HEAD, so these are not real-traffic rates. On my 163 new messages, which HEAD's author never saw, the totals are 39 → 16 (device bank), 16 → 12 (device none), 20 → 15 (server), 39 → 20 (effective bank), 23 → 17 (effective none).

**Is anything worse than the baseline for a real user at HEAD?** On the device and on the effective iOS-Cloud path: **no** (0 wrong-where-ab-was-right, 0 newly silent; A028 is equal system-wide). On the server alone: yes — 21 completed messages are rejected with no AI where ab recorded or reviewed them (all recovered as review by the device), and 1 wording class reads as a refund.

**Review-volume cost:** 0% of correct completed corpus/golden messages; 14.7% / 8.6% / 6.8% / 14.3% / 11.3% (device bank / device none / server / effective bank / effective none) of the probe-set messages that ab booked correctly. Overall, completed messages waiting in review on the bank-sender effective path: ab 192 → HEAD 443 of 1,389.

**What remains wrong at HEAD** (effective, bank sender; every item equally wrong at ab): 34 notices recorded (future/scheduled/due bills, expected salary, adverts with `deposit`) — money **out** or **in** that never moved; 18 wrong directions — mostly outgoing money booked as **income** (`deposit`, `salary transfer … debited`, `cashback reversal … deducted`) and 3 incomes booked as spend; 8 own-account transfers counted as spend or income; 6 foreign-currency figures recorded instead of the charged amount; 1 currency; 4 not-completed messages recorded.

**Judgement.** On the evidence, the parser at HEAD is safer to put in front of users than the baseline parser on the device path and on the effective iOS-Cloud path: wrong total changes fall by roughly 85% on every side, no completed message is silently lost on those paths, and nothing that the baseline booked correctly is now booked wrongly. The price is review volume (up to ~15% of correct completed messages that carry footers or less common verbs, and AI-primary rejections of the same class), which changes no total. On the server alone it is better in aggregate (375 → 63) but rejects 21 completed messages that ab handled, so the server is only safe together with a device build that carries the matching parser (the device recovers each). Conditions: deploy the server and the device build together (a server at HEAD with the build-147 device, or the reverse, was not measured and loses the device recovery); verify on a device with real bank messages before wide release; monitor Smart Inbox volume and the AI `not_a_transaction` rate. Among the commits I measured (ab, base, r8 `5583cbea`, par `75dab61a`, HEAD) **HEAD is the best state** on every side; r8 has 25 silent completed messages on the effective path and par has the QR-01 income class. No universal-coverage claim: AI legs against a model, installed builds and the deployed server were not tested.
