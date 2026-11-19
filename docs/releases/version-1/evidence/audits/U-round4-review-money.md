# U — Independent review: round 4 money correctness (`a157e68e..a86298fc`)

- Reviewer: `r4-review-money` (independent; wrote none of the reviewed code)
- Model: `claude-fable-5-2` (Claude Fable 5.2)
- Date: 2026-11-18
- Commit reviewed: `a86298fc`. Baselines run side by side: `5dae2e2d` ("pre"), `a157e68e` (previous candidate), `b6fc0dad` (build 147 client and deployed server).
- Method: every version ran from a `git archive` extract in a scratch folder (no git worktree was added). Device code ran under `flutter test --no-pub -j 2`; server code under Deno. All messages are synthetic. `tools/message_eval/heldout/**` and `real_model/sample_b.jsonl` were not read. The repository was not modified apart from this file.
- Note on the tree: the three official harness commands ran at 19:03 on a clean tree at `a86298fc`. At 19:12 a docs-only commit (`2f9931cb`, another reviewer's record) moved HEAD, and from about 19:27 other sessions were editing parser files, `diff.py` and case files in the working tree. Everything below is measured on commit `a86298fc` from archives, not on that working tree. I did not read the other reviewer's record.

## Verdict: REJECT

The original reproductions are fixed. But the new rules record money that did not move, in classes that `a157e68e` held for review:

- **R4M-01 (S1):** a bill with parts whose total "can be paid", "must be paid", "should be paid" or "paid?" is saved as confirmed spending at the total on every path.
- **R4M-02 (S1):** a late or overdue credit-card repayment is saved as income or spending, and a "pay … or a late payment fee applies" reminder is saved as spending.
- **R4M-03 (S2):** a refund that "is credited within 5 days", and a cancelled refund (Arabic), are saved as refunds.

On my 356 labelled new probes, `a86298fc` has more wrong entries than `a157e68e` on every path (table in section 2).

## 1. Original reproductions (82 texts from report S and the Gemini record)

Rule parse and import, graded per path (dB, dN, server, eB, eN). Wrong / silent / review / right:

| Path | `5dae2e2d` | `a157e68e` | `a86298fc` |
|---|---|---|---|
| dB | 17/1/7/57 | 6/0/15/61 | 3/0/7/72 |
| dN | 12/1/24/45 | 5/0/25/52 | 2/0/16/64 |
| server | 11/1/10/60 | 8/4/8/62 | 5/0/4/73 |
| eB | 16/0/9/57 | 7/0/11/64 | 4/0/2/76 |
| eN | 15/0/9/58 | 7/0/11/64 | 4/0/2/76 |

Real server handler (`handleProcessIosSms` on `capture_rpc_fake`, model stubbed to answer "completed" as payment, refund and income; both analysis modes): not-completed rows that became `processed`: 6 → **1** of 33. Completed rows processed: 37 → **46** of 46 (rule parse + model), 35 → 44 (AI-primary).

| Finding | Status at `a86298fc` | Evidence |
|---|---|---|
| CUE-1 (awaiting, attempted, future cashback, total to be charged, tip awaiting authorization, «عملية معكوسة:» prefix) | **Fixed for the quoted wordings; partly for the class** | 7 of 7 not recorded on every path and refused by the handler for every forged answer. Paraphrases are still recorded: see R4M-06 |
| HOLD-1 (a) expected/pending refund credited, (b) refund footer, (c) third-party two account types, (d) bill + VAT total paid | **Fixed** (5 of 5 recorded right on all five paths) | FX-fee total: **not fixed**, and with a merchant in the text it is recorded at 375 (device) or USD 100 (server) instead of 383.25 — same at `5dae2e2d` |
| FT-1 standing-order footer | **Fixed** | recorded on all paths; server no longer silent |
| NEW-2r (bill-reminder tail, month-total tail, "as per your request", "as scheduled") | **Fixed** on import (10 of 10). "Your scheduled transfer … executed as per your request" still goes to the model on the server rule parse (not silent) | |
| PRE-AT008 own-account transfers | **Fixed** (never spending or income; review or neutral) | 3 of 3 |
| PRE-RF009 Arabic refund direction | **Fixed** for «استرجاع عملية شراء …». «تم إيداع 50 ريال استرداد نقدي … عن عملية شراء بمبلغ 500 ريال» is still IN 500 on server and import (pre-existing) | |
| VAL-1 leftovers | **Fixed** (8 of 8 held; gate refuses) | |
| Gemini: bare operation | **Fixed** — rejected for all three forged answers in both modes | |
| Gemini: late-payment fee | **Fixed**, but the fix opened R4M-02 | |
| Gemini: refund of a cancelled operation | **Fixed**, but the fix opened R4M-03 | |
| SM-01, SM-02, SM-03, SM-04, NEW-1, NEW-3, VAL-1 (closed) | **Not re-opened** | 9 + 4 + 5 + 4 + 7 + 3 + 8 texts: 0 recorded declined, 0 throws, 0 wrong direction |
| Still wrong, pre-existing | "Credit card *4521 payment SAR 2,000.00 received" recorded (all paths, handler accepts); "Purchase SAR 20 …, cashback SAR 50 credited" booked IN 20; "Spend SAR 500 … get SAR 50 credited" IN on server | |

## 2. New probes (361; 356 labelled; Arabic and English)

Classes: A completed purchase with awaiting/attempt/future words in a footer or merchant name (43); B real pending or future, reworded (52); C refunds (67); D transfers (32); E fees and card repayment (31); F bare operation (34); G totals with VAT, tip, FX (46); H footers (45); I two amounts (11).

Wrong / silent / review / right:

| Path | `5dae2e2d` | `a157e68e` | `a86298fc` |
|---|---|---|---|
| dB | 106/0/50/200 | 49/0/64/243 | **58**/0/59/239 |
| dN | 61/0/102/193 | 28/0/96/232 | **40**/0/92/224 |
| server | 95/13/47/201 | 42/12/41/261 | **51**/10/39/256 |
| eB | 114/0/37/205 | 47/0/49/260 | **56**/0/44/256 |
| eN | 97/0/44/215 | 37/0/51/268 | **49**/0/46/261 |

- Worse than `a157e68e` on at least one path: **20 messages**; 15 of them are also worse than `5dae2e2d`. Better than `a157e68e`: 13.
- Class A (the question asked): 4 of 43 completed purchases are newly held on the device and import, and newly rejected by the server with a "declined" push (R4M-05). Merchant names ("Awaiting Cafe", "The Attempt Lounge", "Pending Coffee") record correctly.
- Class B: 20 (dB), 18 (server), 22 (eB) of 52 reworded pending or future messages are recorded — unchanged from `a157e68e` (R4M-06).
- Class G: wrong 0 → 7 (dB), 4 → 10 (server, eB) (R4M-01).
- Class E: wrong 5 → 9 on every path (R4M-02).
- Real handler with forged answers, 162 not-completed probes: processed 47 → 52 (rule parse + model), 47 → 46 (AI-primary). 182 completed probes: 153 → 158 and 161 → 162.

## 3. Findings

### R4M-01 — S1 — REPRODUCED — regression of this round: an unpaid bill is saved as spending at its total

Rule 12 (`paidTotal`, `PAID_VERB` in `message_meaning.ts`; `ParserEngine.paidTotal`) accepts any "paid" in the total's sentence unless it is negated or after "will".

Saved as a confirmed payment of SAR 230 by the real `CaptureImportService` on an in-memory database (device alone, server row, AI-primary row), totals +23,000 minor units, nothing in review. At `a157e68e`: nothing saved, review `total_with_parts`.

- `Your bill SAR 200.00, VAT SAR 30.00, total SAR 230.00 can be paid via SADAD`
- `Bill SAR 200.00, VAT SAR 30.00, total SAR 230.00 must be paid before 01/12`
- `Bill SAR 200.00, VAT SAR 30.00, total SAR 230.00 should be paid today`
- `Bill SAR 200.00, VAT SAR 30.00, total SAR 230.00 paid? Reply YES to confirm`
- also "… paid late incurs a fee", "… paid by cheque is subject to clearing", «تم سداد الإجمالي 230 ريال؟ للتأكيد أرسل 1 …» (device)

The server rule parse records them with no model; the handler stores `processed`. Held correctly: "not paid", "unpaid", "to be paid by", "payable", "has not been paid yet", and the Arabic negations.

### R4M-02 — S1 — REPRODUCED — regression of this round: late or overdue card repayments and a payment reminder are recorded

`CARD_REPAYMENT` now has `(?<!late )(?<!missed )(?<!overdue )` before "payment", so a late repayment itself no longer reads as a card repayment. At `a157e68e` all four were review `card_repayment`.

- `Thank you. We received your late payment of SAR 2,000.00 for credit card *4521` → **income 2,000** in totals (device alone, server row); server stores processed.
- `Your overdue payment of SAR 2,000.00 for credit card *4521 has been received` → spending 2,000.
- `Late payment of SAR 2,000.00 received towards your credit card *4521. Fee waived` → spending 2,000.
- `Pay SAR 2,000.00 by 25/11 or a late payment fee of SAR 100.00 applies to credit card *4521` → a confirmed payment row of 2,000 (dated by "25/11").
- «تم استلام سدادك المتأخر 2,000 ريال لبطاقتك الائتمانية 4521» → income on import.

### R4M-03 — S2 — REPRODUCED — regression of this round: a refund not yet received, or cancelled, is saved as a refund

Rule 15 treats "cancelled" as the original operation's status whenever a credit verb is present; "is credited within 5 days" counts as that verb.

- `Your order was cancelled. Refund of SAR 150.00 is credited within 5 days` → confirmed refund, totals −15,000, on all three import paths and the server (was not-completed).
- «تم إلغاء عملية الاسترداد بمبلغ 150 ريال التي أضيفت إلى بطاقتك 4521» (the refund was cancelled) → server records a refund; import saves it.
- `Purchase SAR 150.00 at Noon card *4521. Cancelled orders are refunded within 7 days` → the server books a **refund** (credit); the import then sends it to review (`direction_contradiction`); build 147 imports it as income.
- Pre-existing, same class: "Refund of SAR 150.00 credited to your card *4521 has been reversed" and «لم يتم رد مبلغ 150 ريال …» are saved as refunds.

### R4M-04 — S3 — REPRODUCED — regression of this round: an advice sentence removes the future reading

`Standing orders will be executed on the due date. SAR 500.00 to Ali on 01/12`: was `scheduled_or_expected`; now the device meaning releases it, so a server or model row "payment 500" is saved (totals +50,000). The server sends it to the model and the handler accepts the answer in both modes.

### R4M-05 — S3 — REPRODUCED — regression of this round: completed movements newly held

- "awaiting" / «بانتظار» / «في انتظار» in a courtesy sentence: `Purchase SAR 45.00 at Jarir card *4521. We are awaiting your feedback, rate us in the app`; "Awaiting you at our new branch"; «نحن بانتظار تقييمك للخدمة»; «في انتظار زيارتكم القادمة». Device and import: review. Server: rejected before the model, push class "declined" (false). Recorded at `a157e68e`.
- `Transfer SAR 500.00 from Current account *4521 to Savings account *7788 of Mohammed`: the handler now refuses it as `own_accounts` (accepted at `a157e68e`).
- «حركة مدينة بمبلغ 500 ريال على حسابك 4521» / «حركة دائنة …» (debit / credit movement) and "International transaction of USD 100.00 on your card" now read `unspecified_operation`.
- `Purchase SAR 45.00 at Jarir card *4521. Your standing order of SAR 500.00 to Ali will be executed on 01/12`: server `no_movement` (silent) — also at `a157e68e`, right at `5dae2e2d`.

### R4M-06 — S2 — REPRODUCED — pre-existing: "pending merchant confirmation" is fixed only for the listed words

The new list is `awaiting`, `attempted`, `… attempt`, «بانتظار», «في انتظار», «محاولة …». Saved as confirmed spending on all three import paths at `a86298fc` (and at `a157e68e`):

- `Purchase SAR 45.00 at Jarir card *4521 is waiting for merchant confirmation`
- `… awaits merchant confirmation`, `… Merchant confirmation awaited`, `… is yet to be confirmed by the merchant`, `… not yet confirmed`
- «شراء 45 ريال لدى جرير بطاقة 4521 ينتظر تأكيد التاجر», «… لم يتم تأكيده من التاجر بعد», «… بحاجة إلى تأكيد التاجر»
- `You'll be charged SAR 99.00 on 01/12 for Shahid` (server and import), "under processing", "in progress", "requires your approval", "Approve purchase … ? Reply Y"

The owner's item "pending merchant confirmation, future charges" is therefore only partly met.

### R4M-07 — S3 — REPRODUCED — the harness change lets a wrong hand label hide a recorded declined message

- The nine rows (FT1b, HOLD1b4, HOLD1a2, HOLD1a4, RF4b, CAN10a–d): I read each text; all nine are completed movements. The listing is honest for them.
- Planted in a scratch copy: the status cue disabled for texts naming "Zeta Mart", so `Purchase SAR 7x.00 at Zeta Mart card *4521 was declined` is recorded on all five paths.
  - Row labelled `d`, amount 77 (a wrong label): **exit 0**, 0 regressions; the row is printed under "required fixes" (10 instead of 9) and under "fixed".
  - Row unlabelled: exit 1 ("base not-completed, now recorded: 1").
  - Row labelled `n`: exit 1 (6 regressions).
- So the guard now depends on the labels being right; nothing checks a `d`/`c` label against the text. The frozen fixture `pre_round_not_completed.json` still protects its 265 texts.
- `server_diff.sh` (base `b6fc0dad`) did not flag the planted row with label `n`: the deployed server also records that text, so it is not "right at base".
- Reproduced at 19:03 on the clean tree: `run.sh 5dae2e2d` exit 0 (dB 204/1/511/1148 → 6/0/408/1450; 0 regressions; 9 required fixes; review 38 of 38); `server_diff.sh` exit 0 (rejected → processed 204); `server_diff.sh HEAD` exit 0 with all zeros (it compares the commit with itself once committed). With the committed harness, `server_diff.sh a157e68e a86298fc`: exit 0, rejected → processed 29, processed → rejected 11, booking changed 3; `run.sh a157e68e a86298fc`: exit 0, 0 regressions, 0 to review. The case files contain none of the R4M-01 to R4M-05 shapes.

### R4M-08 — S3 — REPRODUCED — final-effect tests: real, with gaps

Ran: `follow_up6_final_effect_test.dart`, `follow_up6_money_correctness_test.dart`, the cue drift test: 282 pass. Deno `process-ios-sms parse-sms _shared`: 1,369 pass; 2 failures are in ownership tests that need files outside my partial extract.

- They do assert the saved row, confirmed-only totals (`currencyTotalsBetween`), the open review item with its reason, and the server's stored state and push class.
- Gaps:
  - Category precedence is exercised on the server-row path only. My check: on the device-alone path the saved rule applies when the parser extracts the merchant ("at JARIR BOOKSTORE on 17/11" → `rule`), but for the test's own text "at Jarir card *4521" it does not apply (category `shopping`, provenance `auto`).
  - "A late model result never overwrites a manual category" is tested only as a redelivery of the same capture id.
  - Some held messages are in the review list with **no** `review_reason` (for example a late card repayment on the AI-primary path, the cancelled-orders footer on the device alone).
- My own checks through the real import service (63 case-paths, with and without a saved rule): a saved rule never turned a held or declined message into money; a rule did not change amount, currency, status, direction or type; a manual category survived a second capture of the same merchant and a later server row for the same id.

### R4M-09 — S4 — REPRODUCED — parity and robustness

- Device and server meaning on my 443 texts: disposition differs in 2 («تم تحويل 500 ريال إلى حسابك الادخاري 7788 من حسابك الجاري 4521»: device review, server books income; «تم خصم 150 ريال … الاسترجاع خلال 7 أيام من الشراء»). Kind or reason differs in 6 more. On 4,000 perturbed texts: 86 disposition differences.
- Fuzz: 12,443 texts × 20 device entry points and × 14 server entry points: 0 throws.
- Drift tests are real: removing one word from `stateCueAwaitedWords` in `parser_rules.json` fails the Dart drift test; removing "paid" from `PAID_VERB` and "refunds" from the advice rule on the server only fails 3 shared-table tests.

### R4M-10 — S3 — REPRODUCED — build 147 with the new server

Build 147's import model (processed row that validates, else its own local parse) on 438 labelled texts, bank sender: the new server is better than the deployed one on 41 messages and worse on 7.

- Worse than with the deployed server, changing totals: purchase + "Cancelled orders are refunded …" / "Order cancellations are credited back …" → income (2); "… completed. Merchant confirmation received" → income; `You'll be charged SAR 99.00 on 01/12` → spending; a refund that names the original purchase amount → 450 instead of 150; an Arabic own-account move → income; "cashback SAR 50.00 credited" → income.
- Worse than with the `a157e68e` server: 2 (the R4M-03 refund texts).
- R4M-01 texts: build 147 records them with either server (200 with the deployed one, 230 with the new one).

### Test integrity (item 7)

- `follow_up5_cases.json`: three `review` pins removed (DEV077, DEV081, DEV082); the rows now assert the amount. A decided behaviour change, not a weakened check — but it rests on the rule behind R4M-01.
- `transaction_state_cues_drift_test.dart`: one list pair added.
- Outside money, for the privacy reviewer: `sms_redaction_cases.json` no longer requires the employer name to be masked in two salary rows (`mustDrop` emptied), and `sms_name_minimization_test.dart` exempts transfer fixtures from the last-digits check.

## 4. Not checked

- Any real model call, any deployed server, production.
- Swift, the notification preview asset, Smart Inbox UI, timing on a phone.
- The full Flutter suites (only the three files above and my own tests ran).
- The working tree after `a86298fc` and the other reviewer's record.
- The held-out set and sample B (not read).

## 5. Fix guidance (not prescriptive)

- R4M-01: accept "paid" only as a stated past event (not after can/must/should/to be/if, not before "?", "late", "by cheque … subject to").
- R4M-02: keep the fee exclusion (`payment fee|charge|penalty`) and drop the `late|missed|overdue` look-behinds.
- R4M-03: a credit verb in a present-habitual or deadline clause ("is credited within", "are refunded within") is not a stated credit; a cancelled word whose subject is the refund keeps it not completed.
- R4M-05: an awaited cue needs an operation subject (merchant, authorization, confirmation), not any sentence.
- R4M-07: require each "required fix" id in a reviewed list, or check the label against a second reading.
- Add these shapes to the shared case table on both sides.
