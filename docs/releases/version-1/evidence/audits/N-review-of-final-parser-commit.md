# N — Independent review of the sixth parser commit (`1be44623`)

- Reviewer model: `claude-opus-5-5` (Opus 5.5). I wrote none of the code under review and none of the earlier reviews (K, L).
- HEAD reviewed: `1be446238efa1a69e3de769bc7cb459ed6444c4a`, branch `release-readiness/v1`, worktree `.claude/worktrees/v1-readiness`. Date 2026-11-17.
- Scope: commit `1be44623` only. It answers review L (LR-01 to LR-08). Baseline for "before" is `0095a239`.
- Constraints:
  - No tracked file changed. `git status --short app supabase` is empty before and after, and `deno.lock` is unchanged. This file is the only write.
  - The baseline code was extracted with `git archive 0095a239 app/lib app/assets supabase/functions/...` into the scratch directory. No git worktree was used.
  - No simulator, Docker or production access was used. All messages are synthetic.
- Harness, in scratch `…/scratchpad/N/`:
  - Device side: `p/dev_new.dart` and `p/dev_old.dart`, run with `dart run --packages=…`. They call `ParserEngine.parse`, `ParserEngine.isIgnoredMessage` and `TransactionStateCues.isNotCompleted`. HEAD also calls `ParserEngine.isNonTransactionText` and `localParseContradictsServer`; the baseline calls `localParseOpposesDirection`.
  - Server side: `p/srv.ts`, which calls `deterministicParse`, `isDeclinedText`, `isResolved` and `isNonTransactionText`.
  - AI validators:
    - `p/ai_dev_test.dart`, run with `flutter test` from `app/`, calls `AiCandidateValidator.validate` with a correct candidate on `SmsSanitizer` output.
    - `p/ai_srv.ts` calls `validateAiCandidate`.
  - Comparators: `p/cmp.py`, `p/diff2.py`.
  - Each set is run three ways on the device: with no sender, with the row's sender, and with sender `AlRajhi`.
- Device outcome classes:
  - `payment`, `income`, `refund`, `withdrawal` or `transfer`: a confirmed transaction.
  - `review`: `amountDetected`.
  - `ignored`: `isIgnoredMessage` is true. This is silent: `add_transaction_usecase.dart:828` sets `wasIgnored`, which makes `intentionallyIgnored` true (`:892`), so there is no Smart Inbox card and no AI.
  - `drop`: not ignored and no amount. It becomes a Smart Inbox card only for a bank-like sender or AI-primary (`:893`).
- Server outcome classes:
  - `REJECT`: a not-completed cue.
  - `IGNORED`: rejected with no AI.
  - `type/direction`: accepted.
  - `unresolved`.

## Commands run (actual results)

| Command | Result |
|---|---|
| `flutter test --no-pub` on the 7 test files the commit changed | **+821, All tests passed** |
| `deno test --allow-all process-ios-sms/ _shared/ parse-sms/` | **699 passed, 0 failed, 2 ignored** |
| 353 shared cases (`declined_cases.json`), device and server, HEAD | Device with no sender: 11 completed cases to review, 0 wrong totals. With `AlRajhi`: every `completed_*` case recorded. Disagreement 10 without a sender, 1 with. 3 type-only |
| 222 probes (K 94 + L 101 + fixer's X 27), with my own truth labels (§1) | **0 wrong total changes** on either side, with or without a sender |
| 353 cases, `0095a239` against HEAD | 64 cases changed (`cases.diff`) |
| L's corpus (263 texts), `0095a239` against HEAD | Device: **1 change** (IPN payment → income, correct). Server: 5 `unresolved` → `IGNORED` |
| 122 new completed synthetic messages (`newsyn.json` Z00–Z99, `newsyn2.json` Y00–Y21) | §2c |
| 66 golden-fixture variants (`gold.json`: each multi-line corpus fixture plus one limit line) | **64/66 now silently ignored** on device and server (§2c) |
| 12 new not-completed wordings and 8 completed messages that contain the new cues | §2d |
| AI validators, 122 completed messages, a correct candidate each | §4 |

## 1. Re-run of K's and L's probes, and audit of the shared table's expectations

### Expectations I dispute

Each of these cases records a completed money movement, but its `expect` is `not_completed` or `review`. The table therefore can never show it as a defect. All of them are total-neutral: device review, server REJECT or IGNORED.

- **Completed purchase with a declined word elsewhere in the message**
  - C113: `…Your card expired on…`
  - C114 and C198 (N05): `approved. Previous attempt declined.`
  - C197 (N04): `declined. Approved on retry.`
  - C205 (N40): the 80.00 purchase was approved.
  - C213 (N53): `Txn declined if limit exceeded`
  - C325 (M14): `approved. Daily limit SAR 5,000; pending SAR 0.00`
- **Merchant names**: C156 (N20 `FAILED VENTURES LLC`), C157 (N21 `Café Cancelled`).
- **Partial reversal**: C158 (N06), `Partial reversal … credited`. Money came in.
- **Footers** (`review` by policy, but completed): C170, C171, C238–C241 (L14–L17), C352 (X27).
- **New in this commit, labelled `review` to fit the code**: C334 (X09, `…Credit limit available SAR 9,900.00`) and C351 (X26, `…card has been activated for online use`). At `0095a239` both recorded payment 100 on both sides (`cases.diff`). They are regressions written into the table as expected outcomes.
- **Inconsistent the other way**: C103 `Reversal of SAR 99.00 at SHOP TWO` and C116 `Reversal of SAR 100.00 credited…` expect `completed_credit`, while C153 and C154 (`POS reversal`) expect review. Under the owner policy a bare reversal is ambiguous. Recording it as a credit can net spend down for an authorization that was never recorded. This is already a known limitation in ROUND2-FACTS §3.

### Fixer's figures against my run

Truth labels are the table's, except that the 16 completed probes above (N04, N05, N06, N20, N21, N23, N40, N53, M14, L14–L17, X09, X26, X27) are relabelled completed. Output files: `pr_dev_srv.cmp`, `pr_devs_srv.cmp`.

| Fixer's claim | My result |
|---|---|
| 0 wrong total changes among 222 | **Confirmed**: device 0 / server 0, with and without a sender |
| 10 completed movements sent to review with a known bank sender | **Corrected to 16.** The fixer's 10 match mine if the 6 footer cases are left out (L14–L17, N23, X27; `review` by policy). On the server, 8 of the 16 are `IGNORED`; the client recovers them as review on the device (§3) |
| 9 more with no sender | **10**: R2e, N25, L23, L24, L25, L26, L27, M05, M07, M11 |
| 1 device/server disagreement with a sender, 9 without | **Confirmed**: M07 with a sender; 9 without |
| 3 type-only differences | **Confirmed**: L33, L34, X24 (device `transfer`, server `income`) |

## 2. Regressions between `0095a239` and HEAD

### 2a. The 353 shared cases (`cases.diff`)

Improvements:
- LR-01: L48, M01, M02 and X12.
- LR-02: the L41–L63 wordings and X10–X11.
- LR-04: the limit and activation notices L85, L86, L87, X13, X14, X20. With a bank sender, the device used to record them as **payment 10,000–20,000**. That was worse than L reported, because L ran without a sender.
- LR-05: merchant names L08–L11 and L30.
- L02, L13, M06, M09 and, with a sender, L26, M05, M11.

Regressions:
- C334 (X09) and C351 (X26): device payment → review, server payment → IGNORED.
- C238–C240 (L14–L16): server payment → IGNORED. The device moved from ignored to review.

### 2b. Corpus (263 texts)

- **1 device change**: K079, the IPN credit, payment → income. This is correct.
- 5 server `unresolved` → `IGNORED`, all genuine notices.
- **The fixer's corpus claim is confirmed.** But the corpus contains **no** transaction message that carries a credit-limit, card-limit, activation, renewal, statement or PIN phrase (`grep -iE "limit|activat|statement|renewal|\bpin\b|الحد|تفعيل"` over the corpus finds only declined-case advisories). A corpus check cannot see the main risk of this commit.

### 2c. New completed messages — the main risk

**Golden formats.** I took every multi-line golden or sample fixture in the corpus (33 messages, real bank layouts, real senders such as `SNB`, `الراجحي`, `riyad`, `stcbank`, `anb`, `البلاد`, `D360`). I appended one line, either `الحد الائتماني المتاح: 9,000.00 SAR` / `Available Credit Limit: SAR 9,000.00`, or `حد البطاقة المتاح…` / `Available card limit…`.

- **64 of 66 are now `ignored` on the device and `IGNORED` on the server: silent.**
- At `0095a239` all 66 were recorded: purchases, ATM withdrawals, salary, transfers, refunds and a government payment.
- The other 2 (BSF) go to review.
- Mechanism:
  - When an ignore word is present, `parser_engine.dart:446-451` keeps the message only if `_hasTransactionSentence` (`:198`) finds one sentence or line that holds an amount with its currency **and** a money verb **and** no ignore word.
  - Multi-line bank SMS put the verb, the amount and the limit on separate lines, so no line qualifies. `amountDetected` is then false, so `isIgnoredMessage` is true.
  - For a bank-like sender, `add_transaction_usecase.dart:828,892` then treats the message as intentionally ignored: no AI and no Smart Inbox card.
  - The server rejects it with no AI (`parse.ts:112-117`).
  - On both iOS import paths a device-ignored text leaves no row: `capture_import_service.dart:482-490` on AI-primary, and `_importLocally` otherwise.

**122 new completed messages** (`worse.txt`). These are purchases at unusual merchant names, fees, purchases that carry a balance or limit, salary, transfers, ATM, bills, standing orders, refunds and Arabic with Arabic-Indic digits. Changes caused by this commit:

| | Device, bank sender (`AlRajhi`) | Device, no sender | Server |
|---|---|---|---|
| Newly **silent** | **10**: Z017, Z020, Z024, Z037, Z082, Y000, Y003, Y009, Y010, Y016 | **8**: Z034, Z037, Z042, Y000, Y002, Y003, Y007, Y009 | **30** newly IGNORED (26 had been recorded) |
| Newly **review** (no total change) | **16**: Z031, Z033, Z034, Z035, Z036, Z039, Z041, Z042, Z073, Y002, Y004–Y008, Y020 | 12 | — |
| Improved | 9: Winner Sports, Coupon Store, Marketing Hub, PRIZE PIZZA, Click & Collect, `مقهى عرض خاص`, and others | 10 | 7 |

How the bank-sender silent entries and the review entries break down:
- **Silent, fees**: `Card renewal fee SAR 150.00 deducted/debited…`, `Activation fee SAR 50.00 debited…` and `Card renewal fee refund … credited` are real money movements. They were `drop`, which is a Smart Inbox card for a bank sender; now they are `ignored`. The server had recorded Z020 and Z024 as payments and Z082 as a refund.
- **Silent, purchases**: `…on your newly activated card`, `(card activated for international use)`, `First purchase on your activated card…`, and the multi-line credit-card formats Y000 and Y003.
- **Review**: Z073, `Salary … credited. Your credit limit is unchanged.`, was income and is now review. Y020, a refund with `Available credit limit`, was a refund and is now review.

Merchant-name probes the task asked for: `Limit Cafe`, `Balance Gym`, `Statement Books`, `Activation Mobile`, `PIN Bar` and `Card Renewal Services` are still payments on both sides. Two exceptions:
- `Payment … to Profile Updated Salon` (Z010) and `Merchant refund … from Card Renewal Services` (Z079): the device records them, the server IGNORES them (its merchant extraction differs).
- On the server's AI-primary path these become review cards, because the device does not ignore them (`capture_import_service.dart:486`).

### 2d. Cue additions

- 6 of 8 completed messages that contain the new cues now go to review on both sides, where they used to be recorded:
  - `Bounced cheque fee SAR 100.00 debited`
  - `…dispute … is under review`
  - `تم خصم … تم إلغاء رسوم العملية`
  - `Payment … completed. Previous attempt did not go through.`
  - `Refund … credited… earlier payment did not go through`
- 5 of 12 new not-completed wordings still change totals:
  - `was returned`
  - `could not be authorised` (device only)
  - `not posted`
  - `تعذرت عملية الشراء`
  - `بانتظار الموافقة` (device transfer)
  - These are pre-existing (LR-02 continued).

## 3. LR-03 — direction and ignore conflicts sent to review

- **Flood check.** I counted server-accepted results whose device reading contradicts them (`localParseContradictsServer`).
  - Corpus: **0 of 135** with the row's sender, and 1 of 135 without (K014, ANB ATM deposit).
  - 353 cases: 0/111. 222 probes: 0/76. New messages: 2/74 without a sender and 1/74 with one.
  - **The rate is 0–3%. No flood.**
- **Duplicates or loss.**
  - The new non-AI-primary branch (`capture_import_service.dart:528-541`) calls `persistUnprocessableCapture`. That writes the Smart Inbox row and the payload marker in one transaction keyed by payload id (`capture_sync_service.dart:553-579`), then removes the native item and acks.
  - A redelivery sees the marker. I found no duplicate or loss path. CODE-SUPPORTED, not executed end to end.
  - `capture_sync_service.dart:956` now passes the sender (LR-09 is fixed: K014 no longer conflicts when the sender is known).
- **Changed test FR-02** (`capture_import_service_test.dart:563-587`).
  - The old non-AI-primary assertion expected the **device's** `refund`. For that Arabic text the device is right, so the old assertion recorded correct money.
  - The defect L found (LR-03) is the mechanism, not this outcome. Replacing the assertion with "Smart Inbox" is a stricter policy, not a fix of a wrong expectation.
  - The new IPN test asserts `['income']` because the parser now agrees with the server. It no longer exercises a conflict in which the **device** is wrong.

## 4. LR-06 — AI validators and the broadened OTP pattern

- **Code-like numbers.** Of 17 genuine purchases with code-like numbers (Z083–Z099), **4 are classed as OTP** by `isNonTransactionText` on both the device and the server. Every AI candidate for them is rejected with `not_a_transaction`:
  - `Use code 482913 for your next order discount`
  - `Order 482913 is your code for pickup`
  - `482913 is the auth code`
  - `Enter code 482913 at the counter…`
- **What happens to those 4.**
  - Two (Z089, Z098) still record deterministically when AI is not primary.
  - When AI is primary they become review (`add_transaction_usecase.dart:915-958`).
  - None of the 4 is silent.
- **No false OTP match.** `Ref 483920`, `Auth code 123456`, `Approval code 482913`, `approval code: 551204`, `Reference code`, `Transaction code 4821`, `Auth: 482913`, Arabic `رقم المرجع` and `رمز الموافقة` all pass.
- **Broader effect.** Across the 122 completed messages, the device and server validators reject **37** correct candidates as `not_a_transaction`, the same 37 on both sides. Before the commit the server validator accepted 121 of 122.
- **The OTP leak is fixed.** L72 and L78 (C296, C302) are now `ignored` on the device.

## 5. LR-08 — "nothing was recorded"

- `pasteSaysNotCompleted` (`manual_paste_screen.dart:41-45`) shows the text only when `!savedForAnalysis`.
- The ingest path does not write Smart Inbox for a paste (`ingest_captured_message_usecase.dart:89-95`). Only the cloud+AI draft (`:270-281`) does, and in that case the "saved for analysis" copy is shown instead.
- **The statement is now true on the single-message path.** CODE-SUPPORTED.
- Still open from LR-08:
  - (b) The copy still says "declined" for pending or hold messages, and for cue false positives on real purchases (C114, C325 and the §2d messages). It does not invite the user to add the transaction if it did go through.
  - (d) The batch label is still `pasteNotUnderstood` (`:708`).

## Findings

| ID | Sev | Class | Finding | Required action |
|---|---|---|---|---|
| **NR-01** | **S1** | REPRODUCED (synthetic built from real fixture layouts); real-world frequency SUSPECTED; **REGRESSION** | The new non-transaction words (`credit limit`, `card limit`, `الحد الائتماني`, `حد البطاقة`, `activated`, `activation`, `card renewal`, statement, PIN…) **silently drop completed money movements on device and server, on every import path**. One limit line added to any of 32 golden multi-line layouts → 64/66 silent; those layouts were all recorded at `0095a239`. Fees that are real debits (`Card renewal fee … deducted`, `Activation fee … debited`) → silent. `…newly activated card` and `card activated for international use` purchases → silent. 10 of 122 new completed messages became newly silent with a bank sender. Cause: `parser_engine.dart:446-451` with `_hasTransactionSentence` (`:198`), plus `wasIgnored` (`add_transaction_usecase.dart:828,892`) and `parse.ts:112-117`. This breaks "zero silent losses" and understates spend or income. | When an ignore word fires on a message whose parse found an amount and a money word anywhere (not in one sentence), return `amountDetected: true` (review), never silent. Remove or exempt fee phrases (`fee … debited/deducted/charged`). Add the golden-plus-limit-line variants and the fee messages to `declined_cases.json` as completed. |
| **NR-02** | S2 | REPRODUCED, REGRESSION | The same words send ordinary completed movements to review, and the AI validators reject them: 16 of 122 new completed messages newly go to review with a bank sender (credit-card purchase plus available limit, statement or PIN footers, salary with `credit limit unchanged`, refund with available limit). The validators now reject 37 of 122 correct candidates. The table hides two such cases (C334, C351) by labelling them `review`. | As NR-01: footer limit and balance lines on a readable transaction should not count. Relabel C334 and C351 as `completed_payment`. |
| NR-03 | S2 | REPRODUCED, pre-existing | Residual not-completed wordings still change totals: 5 of 12 new probes (`was returned`, `could not be authorised`, `not posted`, `تعذرت`, `بانتظار الموافقة`). | Decide and add them to the table. Keep the "not universal" statement. |
| NR-04 | S3 | REPRODUCED, REGRESSION (total-neutral) | The new cues (`bounced`, `under review`, `تم إلغاء`, `did not go through`) send 6 of 8 completed messages to review. | Apply the advisory and generic-noun rules to the new cues (a bounced-cheque fee is a debit). |
| NR-05 | S3 | REPRODUCED | The table encodes 20 completed movements as `not_completed`/`review` (§1), so it cannot detect them. C103 and C116 (bare reversal → credit) contradict C153 and C154. | Tag known false positives separately (`expect: completed_*`, `known: review`) so the table counts them. |
| NR-06 | S3 | REPRODUCED | The broadened OTP pattern matches 4 of 17 genuine purchases with codes (`Use code NNNN for…`, `NNNN is your code for pickup`, `NNNN is the auth code`, `Enter code NNNN at the counter`). AI-primary turns them into review cards. | Require a security word (`otp`, `verification`, `one time`) next to `code`. |
| NR-07 | S4 | CODE-SUPPORTED | LR-08 is only partly addressed: the copy still says "declined" for holds and false positives; batch still shows "Not understood". The FR-02 test now covers only a conflict in which the device is right. The corpus has no transaction carrying a limit or notice line, so the fixer's corpus check could not reveal NR-01. | Copy and test backlog. Add limit and notice-bearing transactions to the corpus. |

## Verdict for `1be44623`

**REJECT** in its current form.
- The LR-01, LR-03 and LR-09 parts are sound:
  - 0 wrong total changes on all 222 probes and all 353 cases, with or without a sender.
  - The bank-sender limit and activation notices that used to record 10,000–20,000 are now ignored.
  - The direction conflict goes to review on both paths, at a 0–3% rate.
  - The corpus is unchanged apart from one correct fix.
- But the LR-04 and LR-05 mechanism introduces an S1 regression (NR-01). Completed purchases, salaries, transfers, refunds and fees whose text contains a limit, activation or renewal phrase are dropped with no trace on device and server. That replaces a visible error class with an invisible one.
- Keep the LR-01 and LR-03 hunks. Rework the non-transaction rule per NR-01 and NR-02 before this commit can be accepted.

## V1-001 at `1be44623` — what is and is not established

- **Established:**
  - No probe from K, L or the fixer (222 inputs), and no case in the 353-case table, changes totals on the device or the deterministic server path, with or without a bank sender.
  - The corpus is unaffected.
  - Device/server direction conflicts are rare (0/135 corpus results with the sender).
- **Not established:**
  - That completed movements are still recorded. They are not, for messages that carry a credit-limit, card-limit, activation, renewal, statement or PIN phrase: silent loss (NR-01) or review (NR-02).
  - Residual not-completed wordings still change totals (NR-03).
  - AI legs were not run against a model.
  - Installed builds and the deployed server are unchanged until redeploy.
  - No universal coverage.
- **V1-001 stays S1 OPEN.**

## Structural alternative (auto-confirm only on a catalog-rule or bank-profile match)

- Definition used: a profile match is a non-null `ParseResult.bankKey`. Catalog rules were not loaded in my harness.
- **With a known bank sender it would have prevented none of the earlier wrong totals.**
  - At `0095a239`, 30 of the 222 probes changed totals on the device with sender `AlRajhi`, and **30/30 had a `bankKey`**. They would still auto-confirm.
- **With no sender it would have prevented 18 of 22.** 4 had a `bankKey` from content detection.
- **It prevents none of NR-01.** The silent drop happens before any confirmation decision.
- **Cost.**
  - With no sender (paste, unknown short codes), 63 of 64 correct device transactions in my new set would go to review.
  - With a bank sender, no change.
- **Conclusion.** It is a reasonable safety net for paste and unknown senders, at the price of reviewing almost everything there. It does not address the actual failure mode: wording from known banks, in both directions.
