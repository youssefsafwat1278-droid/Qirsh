# X — Independent review of round 5 (`e5881120`, branch `release-readiness/v1`)

Reviewer X (independent; wrote none of the code). Model: Claude Opus 5.5. Date 2026-11-19.
All work ran on a `git archive e5881120` copy in scratch (`review-r5/src`). The worktree was not touched (`git status` clean). No real model, network service, production or Docker stack was used. `tools/message_eval/heldout/` and `real_model/sample_b.jsonl` were not read.

## Verdicts

| Area | Verdict | Why |
|---|---|---|
| Money (owner decision 1) | **REJECT** | The guard "a model answer is never recorded when it flips a direction the text names" covers only a narrow word list. Payroll, salary, bonus, deposit («أودع»), cashback, fee, "billed", «المخصوم», «سُدد», "renewed on card" and similar texts are recorded in the opposite direction when the model flips. This happens on the server (both modes), on the device import, and worst on the device's own model path, which has no direction check and is not in the acceptance test. The frozen set hides these rows: `model_dependent` is computed by the implementation's own `namedDirection`, so every row it misses is exempt (X-M1, X-M2, X-M3). |
| Privacy (owner decision 2) | **ACCEPT WITH FOLLOW-UP** | Every V/W reproduction is fixed. TS, Dart and Swift give identical output on 582 texts. No amount, date or status word is lost. Remaining leaks: money-request wording and "beneficiary added" (both pre-existing), and a regression ("paid to <person> … card") that follows directly from owner decision 2. The owner should acknowledge that regression explicitly. |
| Rule restore (owner decision 3) | **REJECT** | Every R4R/AR reproduction passes. But a queued "Leave out" is pushed before the pull. If another device saved a newer rule in the meantime, that rule is silently overwritten and never returns to the list (X-R1). The closure claims the opposite. The same push-before-pull overwrites another device's later edit (X-R2). |

## Severity-ranked findings

### S1

**X-M1 (S1): a flipped model answer is recorded against a direction the text names. Server: both modes. Device: import.**
- The server checks `modelFlipsDirection` through `namedDirection`, which is `messageMeaning` or else `detectDirection` (`process-ios-sms/parse.ts:213`). The device import has its own twin (`validated_capture.dart namedDirection`).
- Neither knows payroll/wages, bonus/مكافأة, dividend, rent, deposit verbs («أودع»), "added to/topped up/landed in your account", cashback, fee/charge/billed, «المخصوم», «سُدد», «عمولة», "renewed on card", "ATM cash", "used for … at", "authorised … at".
- Observed (stub model answers the true figure in the other direction; `parsed.direction` as stored):

| Text | Server rule+model | Server AI-primary | Device import (AI row) |
|---|---|---|---|
| `Your payroll of SAR 8,500.00 has been posted to account *5678` | debit 8,500 | review | debit 8,500 (rule row) |
| `Payroll SAR 12,000.00 to account *5678 from Test Corp` | debit 12,000 | – | debit |
| `أودع مبلغ 2,000 ريال في حسابك *5678` | debit 2,000 | – | debit 2,000 |
| `Bonus SAR 2,000.00 to account *5678 from Test Corp` (fresh) | debit 2,000 | debit 2,000 | debit 2,000 |
| `مكافأة 2,000 ريال لحسابك *5678` (fresh) | debit 2,000 | debit 2,000 | debit 2,000 |
| `Dividend SAR 300.00 to your account *5678` (fresh) | debit | debit | debit |
| `Rent SAR 3,000.00 from Test Tenant arrived in account *5678` (fresh) | debit | debit | debit |
| `Cashback of SAR 18.40 has been added to your card *4521` (fresh) | debit | debit | debit |
| `Fee SAR 25.00 added to your account *5678` | credit 25 | – | – |
| `Annual card fee SAR 250.00 applied to card *4521` | credit 250 | – | – |
| `You were billed SAR 199.00 by Test Telecom on card *4521` | credit | – | credit |
| `المبلغ المخصوم 75.00 ريال, بطاقة 4521,` | credit | – | credit |
| `سُدد مبلغ 300 ريال لـ Test Electricity من حساب *5678` | credit | – | credit |
| `ATM cash SAR 500.00 card *4521 at Olaya branch` (fresh) | credit 500 | credit 500 | credit 500 |
| `Gym membership SAR 199.00 renewed on card *4521` (fresh) | credit | credit | credit |

- Expected: review with `direction_contradiction` (owner decision 1).
- Counts on the frozen set (my re-run):
  - Server rule+model: 185 rows recorded flipped. 77 of them (49 distinct wordings) carry an explicit direction word.
  - Server AI-primary: 186 rows.
  - Device AI-primary import: 141 rows, 59 with an explicit word.
  - Device rule-parse import: 78 rows, 22 with an explicit word.
- Not a regression: `a157e68e` had no flip check. On my 290 probe texts the server's flipped wrong entries fell from 31 → 13 (rule+model) and 29 → 11 (AI-primary).

**X-M2 (S1): the device's own model path accepts flipped answers with no direction check, and the acceptance test never exercises it.**
- Path: `AddTransactionUseCase._tryAiParseFirst` → validator. It is used for manual paste, the Shortcut's local path and Android notifications.
- The Dart acceptance test sets `loadAiConsent: () async => false`, so this path is never run.
- I ran it: a fake `AiParserClient` gave a forged answer, and I called the use case directly (`x_reviewer_money_probe_test.dart`, modes `device_ai_*`). 167 / 123 model calls were made.
- Recorded flipped — 18 wrong entries on my probes, including texts the import path does catch:
  - `Debit SAR 45.00 card *4521 Test Diner` → credit
  - `Debit transaction: SAR 1,150.00 via SADAD to MOI Traffic Violations` → credit
  - `Credit transaction: SAR 4,000.00 from Test Corp Payroll` → debit
  - `Transaction alert: SAR 5,000.00 debit on account *5678` → credit
  - `Refund for your purchase at Noon: SAR 150.00 returned to card *4521` → debit
  - `Standing order of SAR 1,000.00 to Ali executed today` → credit
  - `سداد فاتورة 300 ريال ببطاقتك الائتمانية 4521` → credit
  - plus all the X-M1 fresh texts
- Expected: review.
- My harness bypasses the import, so the 191 "silent" grades in this mode are an artefact and are not judged. Only confirmed saved rows are counted as wrong.

**X-M3 (S1, process): the frozen money set's `model_dependent` marks are derived from the implementation under test.**
- `tools/acceptance/mark_model_dependence.ts` marks a row `flipped` when `namedDirection(text) === 'unknown'`, using the final code.
- Every row the direction check misses is therefore exempt from failure: graded `model_dependent`, not `wrong`.
- That is why the set reports 0 wrong while the 185/186/141/78 rows above are booked in the wrong direction.
- The 398 `flipped` marks are effectively labels relaxed to fit the implementation.
- The 17 `wrong_completed` marks have the same construction. 16 are balances/limits/adverts and 1 is an own-account wallet top-up. Example: `رصيدك بعد الخصم 5,000 ريال` is stored as a 5,000 debit by both server modes on a forged "completed". The device holds it (`amount_is_account_figure`).
- Mutation check: the tests do detect broken rules where rows are not exempt.
  - Disabling `doubtOf` gave 80 wrong in `ai_wrong_completed`, and the test failed.
  - Forcing `namedDirection` to `unknown` gave 80 wrong in `ai_flipped`, and the test failed.
  - Both files were restored, and I verified the restore with diff.

**X-M4 (S1, pre-existing, not a regression): wrong entries with the AI off.**
- `Purchase SAR 150.00 at Noon card *4521 completed. Merchant confirmation received`
  - Server rule parse: processed **credit 150** in every mode.
  - Device alone (AI off): saved as **credit/income 150**.
  - This was U R4M-10, and it is not in the frozen set.
- `POS Refund SAR 64.50 HYPERPANDA card *4521` (fresh) → server rule parse **debit 64.50**. The device import holds it.
- `تم إيداع 50 ريال استرداد نقدي لبطاقتك 4521 عن عملية شراء بمبلغ 500 ريال` → server credit **500** (U §1; not in set).
- `Purchase SAR 20.00 at Jarir card *4521, cashback SAR 50.00 credited` → server credit 20 (U §1; not in set).
- Server and import also record these (parser_diff, pre-existing):
  - `Payment SAR 100 to STC has been returned` — labelled n, recorded on all 5 paths.
  - `Your installment plan: SAR 500 monthly payment for 12 months approved` — server and import.
- None of these are worse than at `a157e68e` (no server regressions on my 290 probes).

### S2

**X-R1 (S2): a queued "Leave out" overwrites a newer rule saved on another device.**
- Repro (`x_reviewer_restore_probe_test.dart` X-E3):
  1. A legacy backup goes to the review list.
  2. The user taps "Leave out" while signed in. A delete is queued.
  3. Another device saves a rule for that merchant one hour later.
  4. This device syncs twice.
- Observed: `device=removed cloud=removed pending=0`. `_run` pushes the outbox before `_pull`, and the server upsert has no time comparison.
- Expected per decision 3 and `round5-restore.md` ("a genuinely newer cloud rule … goes back on the review list"): cloud keeps the newer rule, and the merchant returns to the list.
- The implementers' test only covers the order Leave out → sync → other device.

**X-R2 (S2): the same push-before-pull lets an older offline edit overwrite another device's later edit** (X-E4).
- Observed: `device=groceries cloud=groceries`; the other device's later `shopping` is lost.
- This contradicts "one timestamp precedence rule … no push before a completed pull". The mechanism predates this round.

**X-P1 (S2, regression vs `a157e68e`, consequence of owner decision 2): a person's name after "paid to … card" is now sent.**
All of the following were `[NAME]`/`[REDACTED]` at `a157e68e` and are sent whole now, identically in TS/Dart/Swift:
- `SAR 75.00 paid to Ahmed Saleh using your card *4521`
- `Card *4521: SAR 85.00 paid to Omar Farooq`
- `Apple Pay: SAR 85.00 paid to Omar Farooq using card *4521`
- `دفع 85 ريال إلى عمر فاروق ببطاقة مدى 4521`

This is what "merchants in card wording survive" implies. It needs explicit owner acknowledgement. It is not a reject reason under the decision as written.

**X-P2 (S2, pre-existing, also at `a157e68e`): requester names in money-request wording are sent.**
- `Money request of SAR 150 from Fatima Zahra. Tap to pay`
- `Request to pay SAR 150 from Fatima Zahra`
- `urpay: Fatima Zahra requested SAR 150 from you`
- `Request to pay EGP 250 from Nour El Sherif. Accept in app`

The closure says "request from" counts as a transfer word. Only the exact form `Request from X:` is covered.

**X-P3 (S2, pre-existing): "beneficiary added" notices send the name.**
- `Beneficiary added: Tariq Mansour, IBAN …` → `Beneficiary [NAME]: Tariq Mansour` ("added" is masked, the name is sent).
- `تمت إضافة مستفيد جديد: طارق منصور` is sent whole.
- The Shortcut uploads any routed SMS; there is no amount filter in `perform()`.
- Contrast: `New beneficiary Ahmed Saleh has been added` and `تم إضافة المستفيد أحمد صالح` are masked.

**X-M5 (S2): own-account moves still reach the model or are booked as spending.**
- `Your STC Pay wallet was topped up with SAR 100 from Al Rajhi card *4521` is sent to the model; a forged "completed" books an expense. The implementers acknowledged this case.
- `تم تحويل 300 ريال من بطاقتك الائتمانية إلى حسابك الجاري` (credit card → own current account, fresh) is saved as **debit 300** spending on the device alone and with a forged server row.

### S3 / follow-up

- **X-S1: label inconsistency.** `declined/841`, `842`, `843`, `957` (card repayments "Credit card payment … received", "Minimum due … paid") are labelled `d`. The hand labels say card repayment = `r` (policy review). These rows go to review today, so nothing is hidden, but the set contradicts itself.
- **X-S2: labels that are strict rather than wrong.** `pre_round/84` ("approved. An earlier attempt could not be authorised") and `pre_round/8` ("Returned cheque fee SAR 50.00 debited") are labelled `n`; `AM-R4M09a` (own-account) is labelled `n` instead of `t`. These are stricter than the truth (they cost reviews, they do not hide wrong entries).
- **X-S3: review budget.** The 331 budget is a count with zero headroom (331/331). It guards only unnecessary reviews, which the owner accepts as a cost. A swap of moves (one recovered, a different one lost) passes.
  - `VERIFIED_COMPLETED` is an explicit 9-id list plus an exact-booking check. A new planted row labelled `d` that is really declined fails unless it reuses one of those 9 ids (R4M-07 is closed).
  - Remaining gap (read, not planted): a row wrong at base and wrong at work, in the same way, is never flagged (`wrong → other wrong` only catches changed wrongs).
- **X-S4: own account suffix masked.** `Salary SAR 8,000 credited from ACME Trading Co. to account *5678` → `… to account [ACCOUNT]` (the user's own suffix is lost; a person-or-company employer is masked, which is acceptable).
- **Unnecessary reviews (counted, not failures):**
  - Frozen set: server 741 (AI off) / 515 (rule+model) / 550 (AI-primary); device AI off 890.
  - My 82 fresh money probes: server AI off 13, AI-primary correct about 10; device alone 14.
  - Examples: `Debit transaction: SAR 1,150.00 via SADAD to MOI Traffic Violations`, `Credit transaction: SAR 4,000.00 from Test Corp Payroll`, `Local transfer of SAR 5,000.00 to IBAN … has been executed`, `Cashback of SAR 18.40 has been added to your card`, `تم إيداع راتب شهر نوفمبر بمبلغ 1,500.000 د.ك`, `Transaction alert: SAR 5,000.00 debit on account *5678`, AR-06a/b, all R4M-05.

## A. Original reproductions (U, W, V)

Paths: server handler on `capture_rpc_fake`, stubbed model answering correct / forged "completed" / flipped; device alone; device import of forged rows.

| ID | Status | Observed |
|---|---|---|
| R4M-01 (7 texts) | fixed | review on every path and every stub |
| R4M-02 (5) | fixed | review |
| R4M-03 a, b, d, e | fixed | review |
| R4M-03 c | routed to review (unnecessary) | |
| R4M-04 | fixed | review |
| R4M-05 a–i | routed to review (unnecessary) | all 9 |
| R4M-06 (13) | fixed | review; were recorded at `a157e68e` |
| R4M-07 | fixed | id list; see X-S3 |
| R4M-08 | fixed | reasons present on review rows I inspected |
| R4M-09a | fixed | review (was IN 500) |
| R4M-10 | **not fixed** for "completed. Merchant confirmation received" | X-M4 |
| AR-02, AR-03, AR-04a–d, AR-05a–b | fixed | review under every stub |
| AR-06a/b | review (unnecessary) | |
| AR-01, AR-07 | fixed | masked; "yesterday"/«أمس» kept |
| AR-08..10, R4R-01..07 | pass in their tests | my X-E1 (restore → sync → restore), X-E2 (pull fails on page 2 of 2, removal on page 2: nothing pushed, the removal lands on the next sync) and X-E5 (Leave out → pull of an older cloud rule → restore → sync) pass |
| CUE-1, HOLD-1, FT-1, NEW-2r, PRE-AT008, PRE-RF009, VAL-1 (follow_up6, 130 rows) | no wrong entry with AI off or correct | flipped: 1 (AMB8f, text names no direction word) |
| FX-fee total | ok_alt (375) | AI-primary flipped records credit 383.25 |
| U §1 pre-existing (card repayment received) | fixed | review |
| U §1 pre-existing (cashback-vs-purchase) | **not fixed** | X-M4 |
| V originals (PRIV-1r, SP-16, MASK-0/1, OTP, "confirm") | fixed | in all three implementations |
| R4P-01..07 texts | fixed | identical across TS/Dart/Swift |
| R4P-03 | resolved by owner decision | brands masked in unclear payment wording, kept in purchase/card wording |
| R4P-08 lower case | fixed | |
| R4P-08 copy, R4P-09, R4P-10 | open as disclosed | |

## B. Acceptance-set audit

**Money: 222 rows sampled** (110 declined, 30 AM, 20 fu6, 15 fu5, 12 fu3, 12 fu4, 8 total, 5 pre_round, 10 HAND), plus all 17 `wrong_completed` and all 186 rows recorded under `flipped`.
- Truth labels in the source tables are unchanged versus `2f9931cb`: a script compared `kind`/`expect`/amount/currency, and the only additions are `device`/`server: review` deviations.
- No hand label was found relaxed to accept a wrong booking.
- The relaxation is in the `model_dependent` marks (X-M3).
- Missing U texts: R4M-10 "… completed. Merchant confirmation received", the two U §1 cashback texts (quoted with ellipses), and none of my X-M1 wordings.

**Privacy: 125 rows sampled**, plus every V/W row.
- `must_not` / `must_keep` are honest.
- The six R4P-03 rows moved to `must_not` per the owner decision.
- "Paid SAR 50.00 to Ahmed Trading" is listed as a known survivor.
- Missing: money-request and beneficiary-added wordings beyond `Request from X:`.

**Final effect.** The Dart test asserts the saved confirmed row, `currencyTotalsBetween` totals, and the open Smart Inbox row. The Deno test asserts the stored capture state and booking. Both fail on a wrong row unless it is marked `model_dependent`.

## C. Numbers

| Run | Result |
|---|---|
| Deno `round5_money_acceptance_test.ts` + `privacy_acceptance_test.ts` | 9 passed, 0 failed. All 7 money rows identical to the closure table (e.g. ai_off 1368/19/741/76; flipped rule+model 653 ok / 606 review / 185 model_dependent; flipped AI-primary 63 / 1213 / 186) |
| Dart money acceptance | ai_off 1273 ok / 890 review / 33 extra / 0 wrong; ai_correct 1606 / 543 / 50 / 0 wrong (match the closure) |
| Dart money acceptance, other 4 modes | stopped after 28 min (machine shared with the gate) |
| Dart money acceptance, 186 server-marked rows, 6 modes | flipped AI-primary 141 md / 44 review; flipped rule 78 md / 107 review; ai_off 0 recorded |
| Dart privacy acceptance | 2/2 pass |
| Restore suites (`test/core/backup`, v44 migration, `test/features/planning_sync`, learned-rules screen, wipe, destructive inventory) | +1101 pass; 2 load failures from a missing generated `countries.g.dart` in the archive, both pass after copying it in (+6); my X-E3 and X-E4 fail (findings) |
| Sanitizer parity on 582 texts (490 set + 62 + 20 + 10 probes) | TS = Dart = Swift (Swift compiled standalone with `swift_sanitize.sh`): 0 differences |
| `parser_diff/run.sh 5dae2e2d` (git archive pointed at the worktree's git, read-only) | exit 0; regressions 0; wrong→other wrong 0; to review 331 / budget 331; per-path numbers identical to the closure |
| Mutations | `doubtOf` → null: 80 wrong, fail; `namedDirection` → unknown: 80 wrong, fail |
| Server probes, 290 texts (82 fresh + originals + fu6) vs `a157e68e` | ai_off wrong 48 → 5; forged completed (rule) 61 → 3; flipped (rule) 31 → 13; flipped (AI-primary) 29 → 11; 0 rows worse than `a157e68e` |
| Privacy probes, 92 fresh texts vs `a157e68e` | 1 class regressed (X-P1); 6 leaks pre-existing (X-P2, X-P3); 0 amounts/dates/status words lost |

**On the 38 → 331 budget.** I accept it as a consequence of decision 1: every move is to review, there are no regressions, and the owner counts reviews as cost. The budget cannot catch direction errors, because the harness runs AI-off only. The real gap is X-M1/X-M3, not the budget.

## D. Fresh probes summary

**Money (82 texts; AI off / AI on with a correct, forged-completed and flipped stub):**
- Wrong entries:
  - AI off: 2 on the server (POS Refund; "completed. Merchant confirmation received") and 2 on the device alone (the latter, and card→own account).
  - Forged "completed": no new wrong entries beyond those.
  - Flipped: 9 to 11 per path (X-M1), 18 on the device's own model (X-M2).
- Silent losses: 0 on the server and import paths.
- Wrong amount: 0. `Your card *4521 was charged USD 15.99 (SAR 60.12)` books USD 15.99 on the server rule parse, which is the original-currency convention (ok_alt).

**Privacy (92 texts):**
- Personal data sent: X-P1 (4 texts), X-P2 (4), X-P3 (2).
- Merchants, amounts, dates and status words: none lost.
- One-time codes: all 8 fresh code wordings masked.

## E. Restore

- All implementer reproductions pass.
- My probes: X-E1, X-E2 and X-E5 pass; X-E3 and X-E4 fail (X-R1, X-R2).
- Legacy → explicit choice and Leave-all-out confirmation: covered by their passing widget tests (read and run).

## F. Regressions vs `a157e68e`

- **Money:** none found on server probes. Device paths were not compared at base: there was no base Flutter build, to save disk.
- **Privacy:** X-P1.
- **Restore:** X-R1 is new behaviour ("Leave out" now pushes a removal); X-R2 is pre-existing.

## Ran vs only read

- **Ran:** everything in the numbers table; the server handler with stubs; device import; the device use case with a fake model; the Swift sanitizer compiled standalone; restore in-memory fake cloud.
- **Read only:**
  - the Shortcut `perform()` upload path;
  - `diff.py` gap for wrong→same-wrong rows;
  - category precedence (no change this round; not re-tested);
  - Swift XCTest (not run).

## Could not check

- Dart acceptance modes ai_wrong_completed and ai_flipped over the full set: stopped for time. The 186-row subset ran instead.
- Device paths at `a157e68e`.
- The local Supabase stack test (`restore_then_sync_local_supabase_test.dart`).
- Real-model behaviour.
- iOS build and XCTest.
- Build 147 against the new server.

## Scratch

- Report: `review-r5/X-round5-review.md`.
- Probes and harnesses: `review-r5/probe/` and the `x_*` test files inside the scratch copy only.
- Build output and the base extracts were deleted.
