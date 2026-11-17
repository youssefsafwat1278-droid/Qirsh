# O — Independent review of the seventh parser commit (`c8cef416`)

- Reviewer model: `claude-opus-5-5` (Opus 5.5). I wrote none of the code under review and none of the earlier reviews (K, L, N).
- HEAD reviewed: `c8cef416c12091c5548c587a5223d30ed7be42dd`, branch `release-readiness/v1`, worktree `.claude/worktrees/v1-readiness`. Date 2026-11-17.
- Scope: commit `c8cef416` only. It answers review N (NR-01, NR-02, NR-03, NR-06). The baseline for "before" is `0095a239`. I also compare against `1be44623` ("mid") and the audit baseline `ab5dc10a`.
- Constraints kept:
  - No tracked file changed. `git status --short app supabase` was empty after every run, including after the `deno test` run, and `deno.lock` did not change. This file is the only write.
  - Older code came from `git archive <sha> app/lib app/assets supabase/functions/process-ios-sms supabase/functions/_shared` into scratch. No git worktree was used.
  - No simulator, no Docker, no production. All messages are synthetic.

## Harness (my own; the fixer's was not used)

All files are in scratch: `<scratch>/O/`.

Code:
- `p/dev.dart`
  - Calls `ParserEngine.parse` and `ParserEngine.isIgnoredMessage`.
  - It runs three ways: with no sender, with sender `AlRajhi` ("bank"), and with the row's sender.
  - It runs against each version through its own `package_config.json` (`cfg_head`, `cfg_base`, `cfg_mid`, `cfg_ab`).
- `p/srv.ts`: calls `deterministicParse`, `isDeclinedText` and `isResolved` at each version.
- `p/eff_h.dart` and `p/eff_b.dart` give the **effective import outcome** on the non-AI-primary iOS path when the server is reachable:
  - If the server result is accepted and the device does not contradict it, the server's row is imported. The contradiction check is `localParseContradictsServer` at HEAD and `localParseOpposesDirection` at base.
  - If it contradicts at HEAD, the message goes to Smart Inbox ("inbox").
  - Otherwise the device's own local result is used (`capture_import_service.dart:519-545`).
- `p/ai_dev_test.dart` (`flutter test`) and `p/ai_srv.ts` run the AI candidate validators and `isNonTransactionText`.
- `p/cmp.py`, `p/trans.py` and `p/table.py` are the comparators.

Input sets, in `O/in/`:

| Set | Size | What it is |
|---|---|---|
| `n122` | 122 | N's 122 new completed messages |
| `gold` | 462 | N's 33 golden layouts, each original plus 13 added lines: credit limit, card limit, statement date, e-statement, card renewal, `PIN-verified`, card activated (two wordings), PIN-change advice, available balance, a credit-limit total, and the English/Arabic opposite-language limit and activation lines |
| `corpus` | 263 | N's corpus extraction of the repository fixtures |
| `cases` | 566 | The shared table at HEAD |
| `own` | 186 | **My new completed messages** (§1d) |
| `notice` | 44 | Pure notices that carry a money word (§2) |
| `cue` | 40 | NR-03 wordings and counter-cases |
| `otp` | 39 | OTP and code-number probes |

Class labels:
- Device classes: `<type>:<amount>` means recorded; `review` means `amountDetected`; `drop` means no amount, which becomes a Smart Inbox card only for a bank-like sender or on AI-primary (`add_transaction_usecase.dart:893`); `ignored` means silent.
- Server classes: `<type>:<amount>` means accepted; `unresolved` means AI or review; `REJECT` means a not-completed cue; `IGNORED` means rejected with no AI.

Limits of the harness: catalog rules were not loaded, the AI legs were not run against a model, and the `eff` model treats a server `unresolved` result as falling back to the local parse.

## Commands run (actual results)

| Command | Result |
|---|---|
| `git rev-parse HEAD` | `c8cef416c12091c5548c587a5223d30ed7be42dd` |
| `flutter test --no-pub` on the 4 Dart test files the commit changed | **+1142, All tests passed** |
| `deno test --allow-all process-ios-sms/ _shared/` | **690 passed, 0 failed, 2 ignored** |
| `p/table.py`: my device run (sender `AlRajhi`) and server run against each row's `device ?? expect` and `server ?? expect` | **0 mismatches** out of 566. My harness reproduces the table |

## 1. Regression against `0095a239` for completed movements

Counts are base → HEAD for messages whose truth is a completed movement. In the cell for each side: "rec→silent" is recorded → `ignored`/`IGNORED`, and "rec→review" is recorded → review, unresolved or REJECT.

| Set | Device, no sender | Device, bank sender | Server | Effective import |
|---|---|---|---|---|
| (a) N's 122 | silent **0**, review 0 | silent **0**, review 0 | silent **0**, review 1 (Z021; base wrongly recorded **income** 300) | silent 0. 2 to review: Z069, base wrong withdrawal; Y012, no sender. **1 rec→drop**: Z021, the wrong income 300 is now a device `drop` (§OR-06) |
| (b) gold, 462 | silent **0**, review 0 | silent **0**, review 0 | silent **0**, review 10 (all base **wrong incomes**, e.g. G010 limit total → income 20,000) | silent 0. Review 17 / 14, all base-wrong: G014 ATM deposit withdrawal, G010/G013 income 9,000–20,000, G017/G018 xlim |
| (c) corpus, 263 | 0 / 0 | 0 / 0 | 0 / 0 | 1 to review: K014, the base device wrongly recorded a withdrawal |
| (c) 566 table, completed truth | silent 0, review 4 | silent 0, **review 5** (C551, C553, C554, C556, C557) | silent 0. **REJECT 6** (C550–C557, correct at base) + unresolved 4 (C318, C374, C488, C494, all base-wrong incomes) | silent 0. Review 8 / 6. **rec→drop 1** (C374 = Z021) |
| (d) **mine, 186** | 0 / 0 | silent **0**, review **43** (27 correct at base, 16 wrong at base) | **silent 17** (7 correct at base: P10_7, P21_1, P31_7, P32_1, P49_1, P52_7, P53_1), review 4 | silent **0**. Review 18 / 50. **rec→drop 1** (P42_1, base wrong income 30) |

**Silent at HEAD on every path, but visible at base: 3 of my 186** (P20_3, P40_6, P43_5). See OR-01. Each is drop → `ignored` on the device and `unresolved` → `IGNORED` on the server:

```
P20_3  Card *4521 authorised SAR 45.00 at Test Diner. Your card renewal is due 01/2027
P40_6  Monthly account maintenance fee SAR 15.00\nYour e-statement is available in the app
P43_5  Fee: SAR 5.75 for SMS service, account *5678. Card activated
```

My 186 messages are 62 cores times 3: each core alone and with two different informational lines. The cores cover:
- currency-only messages (`SAR 250.00 Test Cafe 14:02`);
- terse POS (`POS 4521 Test Mart 89.50`);
- unusual verbs: settled, used, taken, collected, billed, booked, processed, approved, authorised, posted, `سُدد`, `خُصم`, `قُيّد`, `نُفذت`, `أودع`, topped up, landed;
- Arabic-Indic digits;
- fees, standing orders and direct debits;
- salary, payroll and wages;
- incoming transfers.

**Where the "no money word" rule leaves them.** I looked at every completed message that has an informational word and no listed money word:
- On the device they are mostly `review`: 43 rec→review with a bank sender, none silent except the 3 above.
- On the server they are `IGNORED` with no AI: 17 that the base server had recorded, 7 of them correctly.
- The device recovers all 17. The effective outcome is review, plus 1 recorded (P21_1).
- `moneyWords` (`parser_engine.dart:342`) does not contain `fee`, `charge`, `debit`, `authorised`, `approved`, `posted`, `used`, `billed`, `settled`, `payroll`, `wages`, `topped up` or `قيد`.

Positive control (NR-01 fixed in bulk): device `ignored` on completed truth, bank sender, mid → HEAD:
- gold **320 → 0**;
- my set **66 → 3**;
- N's 122 **10 → 0**;
- table **72 → 0**.

## 2. Pure notices that carry a money word (LR-04), 44 probes

Number recorded as money:

| | `ab5dc10a` | `0095a239` | `1be44623` | **`c8cef416`** |
|---|---|---|---|---|
| Device, no sender | 24 | 23 | 15 | **23** |
| Device, bank sender | 26 | 25 | 16 | **25** |
| Server | 36 | 34 | 19 | **31** |
| Effective import (no sender / bank) | — | 36 / 36 | — | **31 / 31** |

**No worse than `0095a239`** on any side:
- The device's recorded set is identical message for message.
- No notice is newly recorded on any side.
- One effective amount grows. Q01 (`statement: total due SAR 2,340.00, minimum payment SAR 115.00`) goes from payment 115 to payment 2,340, because the server now reads debit, so the device no longer opposes it.

**What remains:** 31 of 44 pure notices still become money on the effective path. Examples:
- `Your credit limit has been increased to SAR 20,000. Enjoy your purchases!` → payment 20,000. The server ignores it; the device records it.
- `Congratulations on your first purchase … Limit SAR 10,000` → payment 10,000.
- `Your new card has been activated. Daily purchase limit SAR 5,000` → payment 5,000.
- `Your salary of SAR 12,000 is expected on 27/11` → income 12,000.
- `ATM withdrawal limit changed to SAR 10,000` → payment 10,000.
- `Your card limit is SAR 9,000. Available for purchases: SAR 8,500` → payment 9,000.
- `Minimum payment due SAR 115.00` → payment 115.

The commit returns these to their `0095a239` state, as its message implies. LR-04 is open.

## 3. The 566 shared cases and their deviation fields

- 78 rows carry `device` and/or `server` fields. My run reproduces every row: 0 mismatches.
- Against `1be44623`, 27 pre-existing rows were relabelled; none was removed. Of the 27:
  - 18 now carry their true `expect` with a deviation. These are N's §1 list: C113, C114, C156–C158, C170, C171, C197, C198, C205, C213, C238–C241, C325, C352.
  - 9 are notices: C306–C311, C338, C344, C345.

Deviation rows by effect:

| Deviation (`expect` → `device` / `server`) | Rows | Changes a total? | Silent? |
|---|---|---|---|
| `completed_*` → `not_completed` / `not_completed` | 16 (C113, C114, C156–C158, C197, C198, C205, C213, C325, C550, C551, C553, C554, C556, C557) | No (review / REJECT) | No |
| `completed_*` → `review` (± server `review`) | 14 | No | No |
| `ignored` → `review` / `dropped` | 8 | No | No |
| `completed_payment`, `completed_income` or `completed_transfer_in` → server `unresolved` only | 11 | No | No; the device records |
| `completed_payment` → `dropped` (server records) | 11 (C372, C373, C375–C377, C379, C433, C434, C462, C469, C470) | Effective path: the server's row is imported | No |
| `completed_payment` → `dropped` / `unresolved` | **5** (C370, C371, C374, C467, C468) | Spend omitted | **With no bank sender and no AI-primary: yes.** Same at base for 4; C374 was a wrong income at base |
| `completed_payment` → `transfer` / `unresolved` | **13** (C409–C412, C473, C488, C489, C494, C495, C506, C507, C528, C529) | **Yes, against `expect`.** A `transfer` is excluded from net spend (`financial_semantics.dart:10`). Pre-existing; a product decision for person-to-person transfers | No |
| `completed_transfer_in` → server `unresolved`, device `transfer` | 1 (C424) | Income excluded (pre-existing) | No |

The fixer's figures against mine:

| Fixer's claim | My result |
|---|---|
| recorded→silent 0 | **Confirmed on the table** (device and server). **Refuted on my set**: the server sends 17 recorded messages to `IGNORED` (§1d). |
| recorded→review device 0 | **Refuted.** Device 5 with sender `AlRajhi` and 4 with no sender: C551, C553, C554, C556, C557. These are 1be44623's cues `under review`, `تم إلغاء` and `did not go through` (NR-04, not fixed). |
| recorded→review server 5 | **Refuted.** The server has 10 on the table: 6 REJECT that were correct at base (C550–C557), plus 4 unresolved that were wrong incomes at base. |
| not-completed→recorded 0 | **Confirmed** on device, server and the effective path: 0 of 196 not-completed or ignored rows. At base it was 28 / 37 / 27 / 34. |
| One remaining wrong total (cash deposit via ATM read as a withdrawal) | **Refuted. There are more** (OR-03). Also, the two messages that show that defect are the ones the table leaves out: **Z069 is the only one of N's 122 that is missing**, and G014a/b are the only two of N's 66 gold variants that are missing. |

## 4. NR-03, OTP and the AI validators

- **NR-03.** All five wordings are now not-completed on both sides: N's V01, V03, V05, V07 and V11 go to review and REJECT, where at base they were recorded.
  - My 10 variants: 9 are caught. **`Payment SAR 100 to STC has been returned` is still recorded** as payment 100 on both sides.
  - My 10 completed counter-cases: **5 now go to review on both sides** (they were recorded at base):
    - `Refund … credited … for the item that was returned`
    - `Purchase … approved. An earlier attempt could not be authorised.`
    - `Salary SAR 12,000.00 credited … Bonus not posted yet.`
    - `تم تحويل 500 ريال … بانتظار الموافقة` (a card request is pending)
    - A returned-cheque fee
  - These are total-neutral.
- **OTP (NR-06).**
  - N's 17 code-number purchases (Z083–Z099): `isNonTransactionText` is now false for all 17 on both sides (4 at mid).
  - L72 and L78 (C296, C302) are still `ignored` on the device.
  - Genuine purchase-OTP texts **without** an `OTP` word are recorded as payments on device and server at **every** version (base, mid and HEAD). Examples: `482913 is your code for the purchase of SAR 250.00 at SHOPX`, `Use code 482913 for purchase of SAR 250.00…`, `Code 482913: confirm payment of SAR 250.00…`, `الرمز 482913 لإتمام عملية شراء…`.
  - **`482913 هو رمز عملية الشراء بمبلغ 250 ريال` is recorded on the device as payment 482,913.**
  - The tightening also stops the validator rejecting 5 such texts (O00, O02, O03, O11, O12; mid true → HEAD false). That is no regression against base, which had no such validator.
- **AI validators on N's 122 correct candidates.**
  - Device: **121/122 accepted, 0 `not_a_transaction`**. The 1 is `amount_not_grounded`.
  - Server: **121/122, 0 `not_a_transaction`**.
  - Mid server: 47 `not_a_transaction` in my harness (N reported 37 with a merchant passed in).

## 5. What `1be44623` got right still holds

- **`Merchant declined`.** C272 (L48), C312 (M01), C313 (M02), C337 (X12) and V00 are review on the device and REJECT on the server.
- **Ignore word inside the merchant name.**
  - `Offer Mart`, `Click Pharmacy`, `Promo Burger`, `Won Kitchen` and `Promotion Plaza` are recorded on both sides, and so are Z007–Z009 and Z015–Z016.
  - `مقهى عرض خاص` (Z013, C366) is still `ignored` with no sender. That was already so at base.
- **Direction conflict goes to review on both import paths.**
  - Both paths call `localParseContradictsServer`: `capture_import_service.dart:582` and `capture_sync_service.dart:956`. The commit adds `isNoticeMessage` to it (`validated_capture.dart:267`).
  - Flood check: server-accepted results sent to Smart Inbox at HEAD:
    - corpus 1/135 (0 with the row sender);
    - table 0–2/276;
    - N's 122 1–3/106;
    - my set 0/43;
    - gold 13–14/350 (all G014, the ATM deposit; 0 with the row sender).
  - **No flood.**

## 6. Tests changed in this commit

- **Table test** (`declined_state_cues_table_test.dart:40,48`).
  - It now uses `device ?? expect`.
  - The device deviation **values** are pinned to exactly `{review, not_completed, dropped, transfer}`. There is **no** pin on which rows may carry one, and no count.
  - A future regression that turns a completed purchase into review, dropped or transfer passes once someone adds `"device": "review"` to that row. Only code review of the JSON diff guards against it.
- **Server table** (`parse_test.ts:520`). It uses `server ?? expect` with **no constraint at all** on the value. A regression to `unresolved` is absorbed the same way.
- **Totals test** (`declined_cases_totals_test.dart:115-121`).
  - For rows that are completed with a device deviation, the AI path and the `_snb` variant are no longer asserted. This is logically consistent: AI recording a true movement is correct. But it is a reduction.
  - **`transfer` deviations fall into no branch**, so 13 rows have no totals-level assertion.
- **Amounts.** No table assertion checks the **amount**, which is how OR-03 passes as `completed_payment`.
- **Drift test** (`transaction_state_cues_drift_test.dart:46-69`).
  - It went from exact list equality to **set-union equality**.
  - That allows the device and server to diverge on which words are hard:
    - `offer`, `won`, `اربح`, links, `click`, `complaint` and `has been closed` are hard ignore words on the device (`parser_engine.dart:309,358`).
    - On the server they are soft: `nonTransactionKeywords` with a money-word exemption.
  - Observed effect: the server now records promotion texts as payments 50–1,000 (Q11, Q13, Q15, Q16). Only the device's contradiction rule turns them into Smart Inbox.

## Findings

| ID | Sev | Class | Finding | Required action |
|---|---|---|---|---|
| **OR-01** | **S1** | REPRODUCED for the deterministic legs; the AI leg was not run. REGRESSION against `0095a239`, introduced by `1be44623` and narrowed but not removed by `c8cef416`. Frequency SUSPECTED. | A completed movement with a notice word, no listed money word, and an amount the device cannot read is **silent on every path**. Examples: `…authorised SAR 45.00… card renewal is due`, `Monthly account maintenance fee SAR 15.00 / e-statement…`, `Fee: SAR 5.75… Card activated`. Mechanism: `isIgnoredMessage` (`parser_engine.dart:165-174`) returns true when `_isNotice` (`:209`) holds and the parse reads no amount. The server returns `IGNORED` with no AI (`parse.ts:117-123`). On AI-primary the result is `ai_ignored` and the device ignores it, so there is no Smart Inbox row (`capture_import_service.dart:482-490`). At base these were a Smart Inbox card (bank sender) and server `unresolved` (AI). 3 of my 186. | A notice-word hit must never be silent when the text holds a currency amount: let it fall to drop (Smart Inbox), and let the server send it to AI. Add `fee`, `charge(s)`, `debit`, `authori[sz]ed`, `approved`, `posted` and `قيد` to `moneyWords`/`moneyKeywords`, or drop the money-word gate in favour of an amount-token gate. Add P20_3, P40_6 and P43_5 to the table as `completed_payment`. |
| **OR-02** | S2 | REPRODUCED; REGRESSION, total-neutral | The server now sends completed movements that carry a notice word and no listed money word to `IGNORED` with no AI. 17 of my 186 were recorded at base, 7 of them correctly: `Payroll SAR 12,000.00… Credit limit…`, `Direct debit SAR 89.00…`, `SAR 300.00 posted to card…`, `…topped up…`, `…added to your account…`. The device recovers all 17 (16 as review, 1 recorded), so none is silent system-wide. This breaks the stated criterion ("not ignored on server") and the commit message's "no completed movement became silent on either side". | As OR-01. |
| **OR-03** | **S1** | REPRODUCED (server and device); CODE-SUPPORTED import acceptance; pre-existing at `ab5dc10a` and `0095a239` | **Wrong amounts: a limit or balance figure recorded as the transaction.** Server: G007/G009 layouts plus `Available Credit Limit: SAR 9,000.00` → **payment 9,000** for an 8 SAR / 1.22 SAR purchase, and `POS 4521 Test Mart 89.50. Credit limit: SAR 20,000` → **20,000**. The iOS import accepts these: `validateCaptureCandidate` checks grounding only, and `localParseContradictsServer` checks direction only. Effective path at HEAD: 28 of 462 gold variants (54 at base). Device with a bank sender: `Foreign transaction fee SAR 3.25… Credit limit: SAR 20,000` and `رسوم كشف حساب 10 ريال. حد البطاقة 20,000 ريال` → **payment 20,000**. For P41_7 the effective outcome went from income 3.25 at base to payment 20,000 at HEAD, because the server no longer reads it. The table carries 4 of these rows (C482, C483, C486, C487) as passing `completed_payment`. Also pre-existing: a device with a bank sender records incoming wording (`Payroll…`, `wages… arrived`, `topped up`, `أودع`, `وصلك`) as **payment**; my set has 23 wrong-total effective results at HEAD, against 45 at base. | Skip amounts on lines labelled limit or balance on both sides. Reject an import whose amount differs from the device's amount for the same direction. Assert amounts in the table. |
| **OR-04** | S1 | REPRODUCED; pre-existing; LR-04 open | 31 of 44 pure notices with a money word are still recorded as money on the effective path (36 at base), e.g. `credit limit … increased to SAR 20,000. Enjoy your purchases` → payment 20,000. | Owner decision on the notice rule. Add these 44 to the table. |
| OR-05 | S2 | REPRODUCED; pre-existing; frequency SUSPECTED | Purchase-OTP texts that say `code` or `الرمز` rather than `OTP` are recorded as payments on both sides (7/20), and the device records `482913 هو رمز عملية الشراء…` as **482,913**. NR-06 also makes the AI validator accept 5 of them again. | Apply `_otpCode` in `parse` even without an ignore word; extend the pattern with `code for (the )?purchase/payment`. |
| OR-06 | S3 | REPRODUCED | The fixer's figures are partly wrong (§3): device rec→review is 5, not 0; server 10, not 5; more than one wrong total. Z069 and G014a/b, the messages showing the admitted wrong total, are missing from the table. Z021 (C374) went from wrong income 300 to a device `drop`, which is silent without a bank sender on the non-AI path. | Correct ROUND2-FACTS §47. Add Z069 and G014a/b with a `known` tag. |
| OR-07 | S3 | CODE-SUPPORTED | Deviation fields can absorb regressions (§6). `transfer` deviations have no totals branch. Amounts are never asserted. The 13 `transfer` rows understate spend against `expect`. | Freeze the deviation rows (a test listing the allowed ids). Constrain the `server` values. Add an amount check. Owner decision on person-to-person transfers. |
| OR-08 | S3 | REPRODUCED | The device/server split of hard and soft ignore words diverged, and the drift test was weakened to allow it (§6). | Same partition on both sides, and an exact-list drift test. |
| OR-09 | S3 | REPRODUCED; total-neutral | The new NR-03 cues send 5 of 10 completed counter-cases to review (including a 12,000 salary). The variant `has been returned` is still recorded. NR-04 (W00–W07) is still open. | Apply the advisory and attributive rules to the new cues; add `has been returned`. |

## Verdict for `c8cef416`

**ACCEPT WITH FOLLOW-UP.** Keep it: it is strictly better than `1be44623`.
- The NR-01 mass silent loss is fixed:
  - gold: 320 → 0;
  - my set: 66 → 3;
  - N's 122: 10 → 0;
  - table: 72 → 0.
- The AI validators no longer reject correct candidates.
- NR-03 and NR-06 are addressed.
- On the 566 table, not-completed→recorded is 0 on all sides.

**The fixer's acceptance criterion is NOT met.**
- The server ignores 17 messages it recorded at base (OR-02).
- 3 completed movements that were visible at base are now silent on every path (OR-01, S1).
- Two base-wrong records became a device `drop`.

## V1-001 at `c8cef416`

**Established.**
- On N's 122, the 462 gold variants, the 263 corpus texts and the 566 table, no completed movement that `0095a239` or `ab5dc10a` recorded is silent at HEAD on the device. The device recovers every server `IGNORED` as review.
- Not-completed→recorded is 0 on the table.
- The direction-conflict path has no flood.

**Not established.**
- That no completed movement is silently lost: **the same 3 of my 186 are silent relative to both `0095a239` and `ab5dc10a`** (OR-01, S1 regression). At both baselines they were a device `drop` (a Smart Inbox card for a bank sender) and server `unresolved` (AI). None of them was deterministically **recorded** at either baseline.
- Correct totals: limit figures are recorded as amounts (OR-03, S1, pre-existing). Notices are still recorded as money (OR-04, S1, pre-existing). There are OTP and code amounts (OR-05).
- AI legs against a model, installed builds, the deployed server, and universal coverage.

**V1-001 stays S1 OPEN.**
