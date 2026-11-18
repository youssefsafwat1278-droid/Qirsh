# S — Independent review: money correctness of the integrated V1 closure

- Reviewer: `review-money` (independent; wrote none of the reviewed code)
- Model: `claude-opus-5-5`
- Date: 2026-11-18
- Tree reviewed: branch `release-readiness/v1`, HEAD `7577f347`, diff `5dae2e2d..7577f347`
- Baselines run side by side: `ab5dc10a` (the build 147 parser) and `5dae2e2d` (called "pre" below)
- Scope: the parser (message meaning, direction, amount roles, currency table), `process-ios-sms`, `parse-sms`, `_shared/ai_*`, `message_meaning.ts`, `engine/ai`, `domain/capture`, the add-transaction and mark-for-review use cases, the import and sync services, `legacy_capture_drain`, `currency_scale`, the global AI budget gate and `capture_push.ts`. Requirements checked: OWNER-BRIEF-ROUND3 sections 4 and 5, and decisions 3.7, 3.12 and 3.15.
- Method: the real code ran at all three commits in scratch git worktrees. Device code ran under `flutter test --no-pub`; server code ran under Deno. All data was synthetic. The repository was not modified apart from this file. `tools/message_eval/heldout/**` was not read.
- Severity and class use `docs/release-process/SEVERITY-AND-GATES.md`.

## Verdict: REJECT

This round adds two S1 money-correctness regressions:

- **SM-01.** A declined or pending message is recorded as completed spending.
- **SM-03.** A purchase that mentions reward points is booked as income.

It also adds:

- **SM-02.** A parser exception breaks capture for common "charged"/"deducted" formats.
- A server that makes build 147 worse than build 147 with today's server (SM-03, SM-04).

Each S1 is reproduced on every path: device, server and the effective iOS import. The previous commit `5dae2e2d` handled all of them correctly. The closure claim that no message became newly wrong or silent on any leg (parser.md) does not hold for these message shapes.

## Findings

Path names used below:

| Code | Path |
|---|---|
| dB | device parse with a bank sender |
| dN | device parse with no sender |
| s | server `parseSms` plus the `index.ts` meaning downgrade |
| eB | effective iOS import (server row, then the device import decision) with a bank sender |
| eN | effective iOS import with no sender |

### SM-01 — S1 — REPRODUCED — regression of this round: declined or pending messages are recorded as completed spending

**What happens.** A status sentence can carry both a declined or pending cue and a footer cue. When it does, `ParserEngine._clauseScope` sets the whole sentence aside as a footer. With no status left in the core text, `meaningOf` returns `completedMovement` and `TransactionStateCues.isNotCompleted` returns false. The message is then booked as a completed debit.

**Where.** `app/lib/engine/parser/parser_engine.dart`, `_footerCue` (around line 558). It treats a sentence as a footer when it contains:
- a notice word or an ignore word (for example "card limit", "credit limit", "click", "activation", "حد البطاقة", "الحد الائتماني"); or
- a declined cue together with an other-event marker ("another", "previous", "earlier", "prior", "أخرى", "السابقة").

None of these branches check whether the sentence's own status cue belongs to the current event. `supabase/functions/process-ios-sms/message_meaning.ts` mirrors the same rule, so the server makes the same mistake.

**Reproduce.** Each message below is booked as OUT for the stated amount on dB, dN, s, eB and eN at HEAD. At `5dae2e2d` each one was kept out (not recorded, or sent to review) on every path.

- `Purchase of SAR 120.00 at Jarir with card *4521. Transaction declined, please use another card.`
- `Purchase of AED 45.75 at Carrefour with card *4521. Declined: exceeds your credit limit.`
- `Purchase of KWD 120.00 at Talabat with card *4521. Status: Declined (card limit).`
- `Purchase of AED 45.75 at Carrefour with card *4521. Transaction pending, previous transaction still being processed.`
- `POS SAR 45.00 at Kudu card *4521. Insufficient funds, try another card.`
- `Purchase of SAR 250.00 at Extra on card *4521 was declined. Please try another card.`
- `Online purchase AED 340.00 at Amazon card *4521. Not completed, please click here to verify.`
- `شراء 450 ريال لدى اكسترا بطاقة 4521. مرفوضة - تجاوز حد البطاقة.`
- `POS\nCard: *4521\nAmount: SAR 89.00\nMerchant: Noon\nDeclined: exceeds your credit limit.` (field layout)

Minimal device check:

```dart
ParserEngine.meaningOf('Purchase of SAR 120.00 at Jarir with card *4521. Transaction declined, please use another card.')
// HEAD returns completedMovement / record
```

**Scale.**
- A-class probes (declined or pending with a footer cue in the status sentence): 33 of 44 are wrongly recorded at HEAD.
- Q-class probes (natural variants): 6 of 12 are wrongly recorded.

**Why S1.** These rows count as spending in the totals (an incorrect core financial result). OWNER-BRIEF-ROUND3 §4 and decision 3.7 require that a message which does not complete a transaction is never recorded.

**Note.** The improvement this round targeted still works. A *separate* sentence such as "Previous transaction declined." after a completed purchase is now recorded correctly (Q012, Q013, K013, K014). The rule is too broad, not wrong in direction.

### SM-02 — S2 (borderline S1: broken capture journey) — REPRODUCED — regression of this round: parser exception on "charged"/"deducted" messages

**What happens.** The parser throws a `MoneyInputException` on common message shapes. Two things must both be present:
1. A charged, billed, deducted, equivalent or `المبلغ المخصوم` phrase with a currency.
2. Anywhere in the message, a number directly followed by a comma (for example `*4521,` or `17/11/2026,`).

**Where.** `parser_engine.dart` `_extractChargedPair` (around line 1435) calls `normalizeLocalizedDecimal(raw)` on each `_plainNumber` match without a try/catch. `_plainNumber` captures the trailing comma (`4521,`), and `normalizeLocalizedDecimal` throws on it. The other call sites (around lines 1340 and 1530) do wrap this call.

**Reproduce.** At HEAD, each of these throws from `ParserEngine.parse`, `isIgnoredMessage`, `meaningOf`, `DirectionSignal.detect`, `TransactionStateCues.isNotCompleted` and `meaningHoldReason`:

- `SAR 50.00 deducted from your card *4521, Jarir, 17/11/2026`
- `Card *4521 charged SAR 35.00 at Kudu on 17/11/2026, 21:40`
- `Dear customer, SAR 60.00 has been deducted from account 4521, balance SAR 940.00`
- `تم خصم 50.00 ريال من بطاقتك 4521, لدى جرير`

Scale: 14 of 17 natural "charged"/"deducted" formats throw (X-class). The control without the trailing comma does not throw. `5dae2e2d` and the TypeScript server do not throw.

**Effects.**
- **Device parse.** The isolate parse returns null. `AddTransactionUseCase` throws before any decision is made.
- **Server-row import.** `CaptureImportService` calls `meaningHoldReason(item.text)` before it looks at the server row. A correct server row is therefore never imported. The item fails, is retried 3 times (`maxPermanentAttempts`), and is then parked in Smart Inbox.
- **AI-primary validation.** The device AI validator also throws.
- **Lists.** CODE-SUPPORTED, not run: `features/common/transaction_direction.dart` `transactionIsDebit` calls `DirectionSignal.detect(tx.rawMessage)` for transfer rows with unknown direction. Stored historical rows with such text would throw inside the dashboard and transaction-list builders (decision 3.15, older records).

**Why not S1 outright.** Per-item catches stop the failure from spreading to other captures, and the parked row is still visible.

### SM-03 — S1 — REPRODUCED — regression of this round: purchases with a reward clause in the same sentence are booked as income

**What happens.** The first flow phrase wins ("credited to your account", "added to your account"). The points or miles skip only applies when the reward word comes *after* the verb.

**Reproduce.** At HEAD each of these is booked IN on dB, dN and s. At `5dae2e2d` each was booked OUT for the right amount.

- `Purchase SAR 450.00 at Extra card *4521, 45 points credited to your account`
- `Purchase SAR 450.00 at Extra card *4521, points credited to your account`
- `POS SAR 120.00 at Jarir card *4521 - 12 miles credited to your account`
- `Purchase SAR 89.00 at Noon card *4521, cashback points credited to your account`
- `شراء 300 ريال لدى جرير بطاقة 4521 وتمت إضافة 30 نقطة إلى حسابك`

The server validator also rejects a correct debit candidate for these messages with `direction_contradiction`.

**Build 147 with the new server.** Build 147 imports the server's income row. For 7 of 8 P-class messages the result was correct with today's server and is wrong-direction with the new server. Deploying this server therefore breaks installed build 147 clients, even though the clients did not change.

**Why S1.** A spend recorded as income is an incorrect core financial result.

### SM-04 — S2 — REPRODUCED — regression of this round: real purchases with an offer, future or due tail become "no movement"

**What happens.** A completed purchase is followed, in the same sentence, by a marketing, future or due tail, for example:
- ", earn 5 points"
- ", eligible for installments"
- ", convert to 0% instalments"
- ", will be posted within 2 days"
- ", offer valid till 30 Nov"
- ", reminder: statement due 25 Nov"
- Arabic tails with `احصل`, `تذكير`, `سيتم إضافة النقاط` or `سيظهر المبلغ`

`_noMovementReason` classifies the whole message as `noMovementNotice`. Results:
- The server rejects it before any AI call and pushes "Not recorded: no completed transaction in this message", which is false.
- The device and effective paths send it to review.

**Reproduce.**
- `Purchase SAR 230.00 at Jarir with card *4521, eligible for installments` gives s = silent, dB = review.
- `Please note SAR 500.00 has been debited from your account *4521 for your loan instalment due on 1 Nov` (s = silent, dB/eB = review) (and `يرجى العلم بأنه تم خصم 500 ريال لقسط مستحق`) goes to review or silent. Both are debits that already happened.

**Scale.**
- S-class: 36 of 36 are silent on the server; 33 moved from correct to review on dB.
- B-class: 22 more are silent on the server.

**Build 147 with the new server.**
- `Purchase SAR 120.00 at Jarir card *4521, offer valid till 30 Nov` becomes SILENT on build 147. Build 147's local parse also drops it, and it was correct with today's server.
- B026 (an Arabic offer that includes `استرداد نقدي`) becomes wrong-direction through build 147's local fallback.

**3.12.** The push says "not recorded" while build 147 may record the message locally anyway.

### SM-05 — S3 — REPRODUCED — the new `chargedTotal` check rejects correct candidates

`AiCandidateValidator` (device) and `validated_capture.dart` / `parse.ts` (import and server) reject a candidate whose amount is not the stated "total". This check runs whenever a tip, fee, VAT or `رسوم` word appears anywhere in the message. The pattern's optional `[a-z]{3}` currency slot matches any three letters, and "total" also matches inside balance phrases.

- `Fee SAR 5.00 debited from account *4521. Total bal 12,345.00`: amount 5.00 is rejected (`amount_not_charged_total`), because "bal" is read as a currency.
- `POS SAR 230.00 at Extra incl. VAT card *4521. Total due 4,500.00 by 25 Nov` (AI validator only)
- `تحويل 1,000 ريال إلى علي، رسوم 5 ريال. الرصيد الإجمالي 20,000 ريال`

The outcome is review, not a wrong booking.

AI validator rejections of *correct* candidates (244 synthetic candidates):

| Validator | ab | pre | head |
|---|---|---|---|
| server | 17 | 21 | 19 |
| device | 6 | 15 | 23 (16 of them are the SM-02 exception) |

### SM-06 — S3 — REPRODUCED — the multi-event rule sends ordinary footers to review

- `Purchase SAR 80.00 at Danube card *4521. Cashback SAR 4.00 credited`: goes to review as multiple events.
- `Purchase SAR 120.00 at Jarir card *4521. Previous purchase SAR 80.00 at Panda`: goes to review.
- `Cash deposited by Ahmed SAR 400.00 into your account`: goes to review as `cash_deposit`. This follows the owner policy and is listed for visibility only.

### SM-07 — S3/S4 — REPRODUCED — the "both sides identical" parity claim is overstated; the drift tests are real for word lists

Parity was run over 1,833 texts (268 own probes plus the 1,565 table texts):
- 161 differ in meaning kind or reason between the device and the server.
- 2 differ in disposition:
  - G000, a tip-total message: the device records it; the server says multiple_events.
  - T79, `Transaction unauthorised: SAR 100.00 at CAFE ONE`.

Server redaction (`redactThirdPartyNames`) can consume text up to and through a period: `to Ali completed.` becomes `to [NAME]`. This merges sentences. K015 (`SAR 1,000.00 sent to Ali completed. Previous transfer declined.`) is silent on the server and recorded on the device. This direction is conservative.

Mutation checks on the drift tests:
- Removing `another` from `parser_rules.json` made the Dart drift test fail. The list drift test is real.
- Removing the other-event footer branch from `message_meaning.ts` was caught by `message_meaning_test.ts` and by the declined table in `parse_test.ts`.

The list drift tests do not cover logic; the table pins do.

### SM-08 — S4 — CODE-SUPPORTED — allowlist headroom and fixture

- The deviation ceiling is `MAX_DEVIATIONS = 700` against a current count of 698. The ceiling stops large growth, but the "cannot grow" wording is overstated: two more deviations fit.
- The golden fixture `sa_anb_atm_deposit_income` dropped its amount and date assertions. This matches a recorded decision and is noted only.

### SM-09 — S3 — REPRODUCED — regression of this round: parse time on long or adversarial input exceeds the 2-second isolate limit

The device parse is much slower at HEAD on some shapes. Times are device parse plus meaning, measured with `flutter test` on this Mac:

| Input (chars) | ab | pre | head |
|---|---|---|---|
| "Avl. Bal. " repeated, 1,600 | — | 24 ms | 112 ms |
| "Avl. Bal. " repeated, 3,000 | — | 9 ms | 279 ms |
| "Avl. Bal. " repeated, 5,017 | 12 ms | 16 ms | 748 ms |
| "Avl. Bal. " repeated, 20,017 | 44 ms | 60 ms | **11,592 ms** |
| "SAR n.00 " repeated, 1,600 | — | 80 ms | 391 ms |
| "SAR n.00 " repeated, 3,000 | — | 249 ms | **1,177 ms** |
| "SAR n.00 " repeated, 7,607 | 1,379 ms | 1,412 ms | **7,240 ms** |
| " . " repeated, 10,017 | 18 ms | 25 ms | 511 ms |
| Realistic SMS (corpus) | | | p99 1.6 ms, max 21 ms |

The server (Deno) at HEAD takes 2,442 ms on the 20k "Avl. Bal." input, against 7 ms at pre.

Neither the device parser nor `process-ios-sms` caps message length below 16 KB (`MAX_BODY_BYTES`). Only the catalog matcher caps it, at 4,000 characters. On real SMS lengths (up to about 1,600 characters) the worst case is under 0.4 s, so the impact is limited to long pasted text or crafted input. When the limit is exceeded, the parse times out to null and the capture falls back to review.

## Measurements

Own probe set `rm` (268 messages, classes A–L) and `rm2` (82 messages, classes X, P, Q, R, S). All messages are synthetic and were written for this review.

Legend:
- W = wrong outcome (wrong direction, amount, currency, a recorded non-movement, own-account counted as spend, or an exception).
- S = completed movement that is silent.
- R = completed movement sent to review.
- b147 = the build 147 parser (ab5dc10a import logic) against HEAD server rows.

`rm` (268):

| Path | ab | pre | head | b147 |
|---|---|---|---|---|
| dB | W90 S6 R25 | W31 S5 R22 | W44 (recorded 35, exception 2, direction 2, amount 2, own 3) S5 R41 | — |
| dN | W54 | W16 | W41 | — |
| s | W65 S4 | W14 S7 | W38 S26 | W38 S26 |
| eB | W81 | W29 | W43 R31 | W76 |
| eN | W68 | W21 | W41 | W57 |

`rm2` (82):

| Path | ab | pre | head | b147 |
|---|---|---|---|---|
| dB | W15 | W0 | W27 (exception 14, direction 7, recorded 6) R37 | — |
| s | W10 | W0 | W12 S37 | — |
| eB | W16 | W0 | W26 | W23 |

HEAD remains well ahead of ab5dc10a overall. Against `5dae2e2d`, however, it is worse on every path for both sets.

**Fixed at HEAD** (wrong at pre and/or ab, correct now):
- SR1,250.00
- NGN, KD, and "TRY Pizza" with KWD
- cash deposit and fixed deposit sent to review
- direction for "Security deposit"
- Arabic due and expected notices
- separate-sentence "Previous transaction declined" footers
- a loyalty-points sentence on its own (D005)
- AED charged amount

**Pre-existing** (wrong at ab, pre and head):
- `...was decl` (truncated) is recorded.
- OTP footers containing ":" digits are silent.
- `Transfer SAR 2,000.00 from account *4521 to credit card *7788` counts as own spend.
- An InstaPay own-account transfer is booked as income.
- `You earned 120 points on your purchase at Jarir` is recorded as 120 on the device.
- An FX foreign figure is recorded instead of the charged amount (F001, F003, F006).

## Other checks

**Consent and identity on the AI path** (read, not run).
- The device rechecks identity (throws) and consent after the AI response and before applying it. A revoked consent returns `skipped('consent_revoked')` and falls back to the local flow.
- The server's `beforeAi` calls the budget gate.

**Budget gate** (read).
- `reserveAiBudget` fails closed. The one exception is when the guard RPC is missing (PGRST202/42883); then the call is allowed. This fails open if the migration is not deployed, so deploy order matters.
- A refused budget makes the capture retryable. In non-primary mode the deterministic result is discarded while the budget is refused (S4 note: delayed capture, not lost).

**Categorization and the markForReview/confirm round trip** (read).
- `markForReview` only moves a row from confirmed to pending. It keeps category and provenance and enqueues an outbox update.
- A rule-applied category write does not confirm pending rows.
- The past-update plan excludes manual rows.

**Build 147 compatibility.** Build 147 treats a not-processed capture as a local-parse fallback, as modelled above. See SM-03 and SM-04 for the new failures.

## Not checked

- Real AI model calls. Validators were run on synthetic candidates only.
- The Swift and native preview paths.
- The manual paste and Smart Inbox confirm UI, including with SM-02 texts. The SM-02 effect on dashboard and list rendering was not run.
- Full categorization precedence through restore, sync and a late AI result.
- The server consent recheck after the AI response, end to end.
- Any deployed server.
- The held-out set (deliberately not read).
- Parse time on a real iPhone. Timings were taken on this Mac.

## Fix guidance (not prescriptive)

- **SM-01.** A sentence that carries a status cue should stay in the core unless an other-event marker clearly attaches the cue to a different transaction. Notice words or ignore words alone should never set aside a sentence that has a declined or pending cue.
- **SM-02.** Wrap the conversion at line 1435 like the other call sites, or stop `_plainNumber` from capturing a trailing comma.
- **SM-03.** Let the purchase or POS lead decide direction before a later reward clause does.
- **SM-04.** Only treat offer, future or due wording as no-movement when there is no completed-movement verb with a figure in the same clause.
- **SM-09.** Cap the parse length, or bound the clause scope work.

Each fix needs table pins on both the device and the server.

---

## Re-review at 7dd6efa8

- Reviewer: `review-money` (independent; same rules as above). Model: `claude-opus-5-5`. Date: 2026-11-18.
- Commits run side by side: `ab5dc10a` (build 147 parser) → `5dae2e2d` ("pre") → `7577f347` (first review) → `7dd6efa8` ("new"). Each ran in a scratch git worktree. Device code ran under `flutter test --no-pub`; server code ran under Deno. All data was synthetic. `tools/message_eval/heldout/**` was not read.
- Claims checked: parser.md "Follow-up 3" and ai.md "Follow-up 9".

### Verdict: REJECT (narrow)

Most of the first review is fixed. SM-01, SM-02, SM-05, SM-08 and SM-09 are fixed, and wrong outcomes on my original set fell below `5dae2e2d` on every path.

One S1 class from SM-03 remains open, and it is a regression against `5dae2e2d` on realistic messages: a purchase that also says a reward, cashback, bonus or Qitaf was "credited to your account" is booked as **income** on every path. Example: `Purchase SAR 45.00 at Noon card *4521, cashback SAR 2.00 credited to your account`.

SM-04 is only partly fixed. The server still silently drops some completed purchases as `no_movement` and pushes "not recorded" (S2).

### Status per finding

| Finding | Status | Evidence at `7dd6efa8` |
|---|---|---|
| SM-01 declined recorded | **Fixed** (new S3 edge, NEW-3) | A-class (44): 0 recorded. Q-class (12): 0 recorded. New not-completed probes in English and Arabic (21): 0 recorded on any path. Status words in merchant names or service footers (32 probes): 2 go to review, the same 2 as at pre, so nothing newly went to review. |
| SM-02 parser throws | **Fixed** | X-class: 0 exceptions (was 14). Dart fuzz: 45,000 random texts × 22 entry points, 0 throws. Entry points include parse, meaningOf, clauseScope, isNotCompleted, DirectionSignal.detect, meaningHoldReason, localParseContradictsServer, validateCaptureCandidate, AiCandidateValidator.validate/chargedTotal/bookedDirection, SmsSanitizer, CardNetworkDetector, MerchantSanity, and captureAmountTokens with canonicalCaptureMoneyText. TS fuzz: 40,000 texts × 7 entry points (parseSms, messageMeaning, isDeclinedText, deterministicParse, chargedTotal, validateAiCandidate, redaction), 0 throws. |
| SM-03 reward clause → income | **Partly fixed, S1 open** (NEW-1) | Original P-class: 7 of 8 fixed. P006 (`…, credited to your account: 4 points`) is still IN on every path. See NEW-1 for the new probes. |
| SM-04 notice tail → no_movement | **Partly fixed, S2 open** (NEW-2) | Server silent completed purchases, head → new: rm 22 → 5 and rm2 36 → 16 (pre: 7 and 3). New probes: 8 of 19 completed-with-tail messages silent on the server. |
| SM-05 chargedTotal false rejects | **Fixed** | `chargedTotal` returns null for "Total bal", "Total due" and «الرصيد الإجمالي». The tip total (115) still applies. |
| SM-06 footers → multiple events | **Partly fixed** (S3) | "Cashback SAR 4.00 credited" and "Previous purchase SAR 80.00 at Panda" now record. "Last transaction SAR 30.00 at Panda", "Previous salary SAR 11,500.00", «الراتب السابق» and «آخر عملية 30 ريال» still go to review as multiple_events. That is 4 probes, correct at `5dae2e2d` on bank paths. |
| SM-07 parity / redaction | **Mostly fixed** (S4) | Over 1,915 texts, the disposition differs in 2: G000 (tip total; device records 100 with the wrong amount, server sends to review) and T79. The claim names only T79. Kind or reason differs in 162 texts. The redaction merge is fixed: R004/K015 is `uncertain` on both sides. |
| SM-08 allowlist | **Fixed** | The ceiling equals the count (703). |
| SM-09 parse time | **Fixed** | Device, on a Mac: 20k "Avl. Bal." 11,592 → 29 ms; 7.6k "SAR n.00" 7,240 → 325 ms. Worst under the 2,000-character bound is 873 ms (2,000 chars of "SAR n.00"). That is still super-linear inside the bound, so check the margin on a slow iPhone. Server worst is 144 ms. |

### New findings

**NEW-1 — S1 — REPRODUCED — regression vs `5dae2e2d`: purchase plus a reward/cashback credit phrase is booked as income**

`isRewardFlow` only skips flows that move points, miles, نقاط or أميال. The following are booked IN 45 on dB, dN (where recorded), s, eB and eN; at `5dae2e2d` all were OUT 45:

- `Purchase SAR 45.00 at Noon card *4521, cashback SAR 2.00 credited to your account`
- `Purchase SAR 45.00 at Noon card *4521, reward credited to your account`
- `Purchase SAR 45.00 at Noon card *4521, Qitaf credited to your account`
- `Purchase SAR 45.00 at Noon card *4521, bonus credited to your wallet`
- `Purchase SAR 45.00 at Miles Cafe card *4521, credited to your account: 4 points`

On the server, `شراء 45 ريال لدى نون بطاقة 4521، تم إيداع المكافأة في حسابك` and `…، تم إيداع استرداد نقدي 2 ريال` are also IN.

Real cash credits are read correctly: "Cashback SAR 20.00 credited to your card" and point or mile redemptions credited in SAR are IN on all bank-sender paths.

**NEW-2 — S2 — REPRODUCED — SM-04 residual: the server silently drops completed purchases with a tail**

The server returns `no_movement` before any AI call, and the push says "not recorded". The new client sends these to review; build 147 records them locally. Examples:

- `Your card *4521 was used for EGP 650.00 at Seoudi, earn 5 points`. The "was used for" lead is not read as a movement.
- `Purchase SAR 230.00 at Jarir with card *4521 and earn rewards`
- `…, total spent this month SAR 3,200`
- `When you paid SAR 60.00 at Kudu … you earned 6 points`
- `شراء 150 ريال لدى نون بطاقة 4521 سيتم إضافة النقاط لحسابك`
- `دفع فاتورة 300 ريال …، تذكير: موعد السداد القادم 1/12`
- `خصم 99 ريال اشتراك شاهد …، تذكير بالتجديد`

**NEW-3 — S3 — REPRODUCED — regression of this round: a status cue in the dropped middle of a message over 2,000 characters is recorded**

Example: a completed purchase, then 1,100 characters of filler, then "Transaction declined." (or "Status: pending.", or «العملية مرفوضة»), then 1,100 more characters. It is recorded as OUT 45 on every path. At `5dae2e2d` it was not recorded.

This needs an unrealistic length for an SMS, but pasted or notification text has no length cap. A cue inside the last 1,000 characters is still caught.

**Other observations**

- A transaction placed in the dropped middle goes to review. That is a safe outcome.
- Two messages concatenated are pre-existing at `5dae2e2d`, except that two different purchases now go to review. Two identical purchases ("…*4521. Purchase SAR 45.00 at Jarir card *4521.") are still recorded once.
- "Spend SAR 500 at Jarir and get SAR 50 credited" is recorded as IN 500 on the server. This is pre-existing.
- `Transfer SAR 2,000.00 from account *4521 to credit card *7788` was review on the server at `5dae2e2d` and is now counted as spend. This first changed at `7577f347`. On eB it was already wrong at `5dae2e2d`.

### Measurements

W = wrong (wrong direction, amount or currency, recorded when nothing happened, own-account counted, one of two events lost, or an exception). S = completed movement silent.

On the server path, `uncertain` is counted as silent here. The implementers' harness treats it as review, so subtract 3 on rm and 3 on rm2 for that reading.

**Original set rm (268):**

| Path | ab5dc10a | 5dae2e2d | 7577f347 | 7dd6efa8 |
|---|---|---|---|---|
| dB | W90 S6 | W31 S5 | W44 S5 | **W7 S3** |
| dN | W54 S6 | W16 S5 | W41 S5 | **W4 S3** |
| s | W65 S4 | W14 S7 | W38 S26 | **W3 S11** |
| eB | W81 S4 | W29 S3 | W43 S5 | **W6 S3** |
| eN | W68 S4 | W21 S3 | W41 S5 | **W4 S3** |

**Original set rm2 (82):**

| Path | ab5dc10a | 5dae2e2d | 7577f347 | 7dd6efa8 |
|---|---|---|---|---|
| dB | W15 S0 | W0 S0 | W27 S0 | W1 S0 |
| s | W10 S0 | W0 S3 | W12 S37 | W1 S19 |
| eB | W16 S0 | W0 S0 | W26 S0 | W1 S0 |

**New probes rm3 (156)**, aimed at the fixes: merchant names, footers, success status, not-completed, the 2,000-character bound, reward vs cash credit, the no_movement boundary both ways, `uncertain`, and Arabic equivalents.

| Path | ab5dc10a | 5dae2e2d | 7577f347 | 7dd6efa8 |
|---|---|---|---|---|
| dB | W46 S2 | W15 S0 | W13 S0 | W13 S0 |
| dN | W24 S2 | W6 S0 | W10 S0 | W11 S0 |
| s | W30 S2 | W12 S6 | W12 S11 | W13 S12 |
| eB | W43 S2 | W17 S0 | W10 S0 | W12 S0 |
| eN | W33 S2 | W14 S0 | W10 S0 | W12 S0 |

On rm3, `7dd6efa8` is worse than `5dae2e2d` on 8 messages that change totals: NEW-1 (5 on every path, 2 more on the server) and NEW-3 (3).

### The implementers' harness (`tools/parser_diff/run.sh 5dae2e2d`)

**Reproduction.** I ran it from a scratch worktree at `7dd6efa8`: exit 0, 0 regressions. The per-path numbers match parser.md (eB right 1,215).

**Is it honest?** Partly. "Right" is graded against labels, but only 1,563 of the 2,345 texts are labelled; the rest are reported as "moves". A "regression" means only right → wrong or silent, a throw, or a base-not-completed text now recorded. **Right → review is never a regression.**

**Planted mutations** (in the scratch copy):
1. `isRewardFlow` made to always return false (device only). Caught: exit 1, 21 path-moves on 7 messages.
2. Every message containing "card" made `uncertain`. Result: exit 0 and "0 regressions", while 351 correctly recorded messages (1,227 path-moves) moved to review.

So "0 regressions vs `5dae2e2d`" is true only in that narrow sense, and the case set does not contain the NEW-1 shapes.

**Model differences from the real import code.** The harness's effective-import model sends a `direction_contradiction` server row to the local parse instead of Smart Inbox, and it does not pass the merchant to `localParseContradictsServer`.

### Build 147 with the new server (`7dd6efa8`) vs the deployed server (`b6fc0dad` = `ab5dc10a` on these paths)

Build 147's client import code was run against server rows from each.

Overall, the new server is better for build 147. On eB, wrong outcomes went 81 → 71 (rm), 16 → 16 (rm2) and 43 → 46 (rm3), with 20 messages better against 10 worse.

The classes that get worse and change totals:
- **Purchase plus reward/cashback "credited to your account"** (NEW-1, 8 messages). Correct with the deployed server; booked as income with the new one.
- **"Credit card payment of AED 2,500.00 received"**. Income with the deployed server; spend with the new one. Already wrong at `5dae2e2d`.
- **K001** (a message with an injected second amount). The new server sends it to review, so build 147 falls back to its own local parse, which books income.

The SM-04 residual (NEW-2) does not change build 147's totals, because build 147 records those messages locally. It does produce a false "not recorded" push.

### Not checked in the re-review

- Real AI calls.
- Native paths.
- Smart Inbox UI.
- Timing on an iPhone.
- Any deployed server.
- The held-out set.

---

## Re-review at 6f771108

- Reviewer: `review-money`, independent, same rules as above. Model: `claude-opus-5-5`. Date: 2026-11-18.
- Commits run side by side in scratch git worktrees: `ab5dc10a` → `5dae2e2d` ("pre") → `7577f347` → `7dd6efa8` → `6f771108` ("fin"). Device code ran under `flutter test --no-pub`, server code under Deno. All data was synthetic. `tools/message_eval/heldout/**` was not read.
- Claims checked: parser.md "Follow-up 4"; ai.md "Follow-up 10" and "Follow-up 11".

### Verdict: ACCEPT WITH FOLLOW-UP

- No S1 or S2 money defect of this round remains open on my probes.
- On every path and every probe set, `6f771108` has fewer wrong outcomes than `5dae2e2d`.
- No message is wrong at `6f771108` that was right at `5dae2e2d`.
- The redaction change sends exactly one new class of token: the user's own suffix of 4 digits or fewer.
- The open items are S3/S4, plus pre-existing privacy leaks. They are listed below.

### Status of earlier findings

| Finding | Status at `6f771108` |
|---|---|
| NEW-1 / SM-03 (reward or cashback clause → income) | **Fixed.** All 24 RW probes, the 8 P-class probes and 35 new primary-clause probes are correct or review. "Purchase SAR 20.00 …, cashback SAR 50.00 credited" is still recorded as one event (IN 20 on eB); this is pre-existing, WONE. |
| NEW-2 / SM-04 (completed purchase dropped by a tail) | **Mostly fixed; residual S3.** Server-silent completed purchases on the original 350: 63 at `7577f347`, 30 at `7dd6efa8`, 12 now. Four shapes are still `no_movement` on the server and review on the device. They were recorded at `5dae2e2d`: «دفع فاتورة 300 ريال…، تذكير: موعد السداد القادم 1/12»; «استخدمت بطاقتك … مجموع مصروفاتك هذا الشهر 3,200 ريال»; "Your scheduled transfer of SAR 1,000.00 to Ali has been executed as per your request"; "As per your request SAR 750.00 has been transferred to Sara as scheduled". The new client sends these to review. The server push wrongly says "not recorded". Build 147 records them locally. |
| NEW-3 (status cue in the dropped middle) | **Fixed.** Every text over 2,000 characters is `uncertain/over_length` (review). 1,999 and 2,000 characters still record; a "declined" tail at 2,000 is not recorded. One gap (S4): an Arabic or Arabic-Indic 2,001-character text that redaction shortens is recorded on the server (the correct amount), while the device sends it to review. |
| SM-06 (footers → multiple events) | **Fixed.** "Previous salary SAR …", "Last transaction SAR …", «آخر عملية» and «الراتب السابق» now record. "Refund … Original purchase was approved on 10 Nov" now goes to review on the device (S4). |
| SM-07 (parity) | **Mostly fixed (S4).** Over 2,193 texts (my 578 plus the table), the disposition differs in 2. LB005: the device records, the server says multiple_events (a second "Total charged" figure). UN010: the device says multiple_events, the server records. Kind or reason differs in 163. |

### New probes (122, aimed at the latest fixes)

- **Primary-clause abuse (35):** refund after an earlier smaller debit figure; partial refund naming the larger purchase; fee plus purchase; purchase plus larger cashback or bonus; salary with a deduction clause; Arabic credit-first word order. 0 got worse than at `5dae2e2d`; 2 improved. Remaining wrong, all the same at `5dae2e2d`: two "m" shapes recorded as one event, and «تم إيداع 50 ريال استرداد نقدي … عن عملية شراء بمبلغ 500 ريال» recorded as IN 500 on the server.
- **Tails that must still demote (27):** a real "declined" or "pending" after an offer, "was used for" or summary tail; future "will be used"; standing order "executes tomorrow"; cheque returned; refund request. 0 recorded.
- **Exactly 1,999 / 2,000 / 2,001 / 2,002 characters (14):** as above.
- **Ordinary purchases and transfers (30):** 0 newly sent to review against `5dae2e2d`.
- **Card repayment (16):**
  - 1 of 13 ordinary credit-card payments is caught by `card_repayment` and sent to review (S3, new): «سداد فاتورة 300 ريال ببطاقتك الائتمانية 4521».
  - 1 of 3 real repayments is still booked as spend (pre-existing): "Credit card *4521 payment SAR 2,000.00 received. Thank you".

### Completed messages moved to review against `5dae2e2d` (eB path)

| Set | right → review | review → right | Main reasons for the right → review moves |
|---|---|---|---|
| Original 350 | 6 | 18 | Card repayment ×2 (owner policy), cash deposit (policy), the four NEW-2 shapes above |
| rm3 | 3 | 6 | over_length, the NEW-2 Arabic tail, the UN010 refund |
| rm4 | 7 | 4 | over_length ×4 (policy), CR010, the NEW-2 Arabic tail, "Salary … SAR 500.00 GOSI deducted" |

### Wrong / silent outcomes

W = wrong (wrong direction, amount or currency; recorded when nothing happened; own-account counted; one of two events lost; an exception). S = completed movement silent.

**Original set (350):**

| Path | ab5dc10a | 5dae2e2d | 7577f347 | 7dd6efa8 | 6f771108 |
|---|---|---|---|---|---|
| dB | W105 S6 | W31 S5 | W71 S5 | W8 S3 | **W3 S3** |
| dN | W67 S6 | W16 S5 | W64 S5 | W5 S3 | **W1 S3** |
| s | W75 S4 | W14 S10 | W50 S63 | W4 S30 | **W1 S12** |
| eB | W97 S4 | W29 S3 | W69 S5 | W7 S3 | **W2 S3** |
| eN | W82 S4 | W21 S3 | W66 S5 | W5 S3 | **W1 S3** |

**rm3 (156, last round's probes):**

| Path | ab5dc10a | 5dae2e2d | 7577f347 | 7dd6efa8 | 6f771108 |
|---|---|---|---|---|---|
| dB | W46 S2 | W15 S0 | W13 S0 | W13 S0 | **W3 S0** |
| s | W30 S2 | W12 S6 | W12 S11 | W13 S12 | **W3 S6** |
| eB | W43 S2 | W17 S0 | W10 S0 | W12 S0 | **W4 S0** |

**rm4 (122, this round's probes):**

| Path | ab5dc10a | 5dae2e2d | 7577f347 | 7dd6efa8 | 6f771108 |
|---|---|---|---|---|---|
| dB | W34 S0 | W14 S0 | W9 S0 | W9 S0 | **W4 S0** |
| s | W32 S0 | W14 S2 | W12 S6 | W12 S5 | **W6 S4** |
| eB | W33 S0 | W12 S0 | W10 S0 | W10 S0 | **W4 S0** |

Every remaining wrong outcome at `6f771108` is also wrong at `5dae2e2d`:
- own-account transfers (E022, E023);
- two identical purchases recorded once;
- buy-now-pay-later adverts recorded;
- "Spend SAR 500 … get SAR 50 credited" recorded on the server;
- the card-repayment receipt above.

The only completed messages worse than at `5dae2e2d` are the server-silent NEW-2 shapes.

### Privacy: what leaves the device, `5dae2e2d` vs `6f771108`

**Method.** I generated 378 synthetic messages in English and Arabic, with Western and Arabic-Indic digits. Each one carries names, third-party accounts of 6–14 digits, the user's own full account, the user's own 4-digit suffix, unspaced and spaced IBANs, phone numbers, card numbers and OTPs. For each message I compared, token by token:
- the device output `SmsSanitizer.sanitize` with no type and with the transfer, income and payment types (this is what is sent to the server and stored);
- the server's `redactThirdPartyNames(redactPii(·))` applied to that output (this is what reaches the model).

**Newly sent at `6f771108`, masked at `5dae2e2d`.** One class: **the user's own suffix of 4 digits or fewer after «إلى حسابك»** (for example «إلى حسابك ***4005»). That is 14 of 14 such messages, on every stage. It is by design and matches the claim.

**Also newly kept.** Tense and status words, amounts, dates, and «من حسابك [ACCOUNT]». These are non-personal.

**Newly masked.** The user's own full 8-digit account number in 5 messages.

**No new leak** of names, third-party account digits, IBANs, phone numbers, cards or OTPs.

**Pre-existing leaks, the same at `5dae2e2d` and `6f771108`. S2 privacy, not this round:**
- English names after "Standing order to …" and "To Name:" (28 of 378) reach the server and the model.
- Third-party account numbers of 6–8 digits after "account" ("to [NAME] account 60181590", 25) reach the server and the model.
- A spaced IBAN keeps "SA88 … 9898" (check digits and the last group).

**Their frozen-HEAD diff test.** It compares against `4d54d258`, not `5dae2e2d`. My comparison against `5dae2e2d` finds the same single new class, so on these inputs the test is not hiding anything. It does not catch the pre-existing leaks above, because it only checks for digit runs that HEAD removed.

### The implementers' harness (`run.sh 5dae2e2d`, `server_diff.sh b6fc0dad`)

**Reproduction.** Both exit 0. The device harness reports 0 regressions, with 35 of 35 budget for moves to review. The server differential reports 0 server regressions.

**Planted mutations (scratch copy):**

| Mutation | `run.sh` result | `server_diff.sh` result |
|---|---|---|
| (1) Wrong direction: `sideCreditClause` disabled on both sides | **Caught:** exit 1, 28 path-moves on 8 messages, and over the review budget | **Caught:** exit 1, 8 regressions |
| (2) Mass move to review: every text containing "card" made `uncertain` | **Caught:** exit 1, 519 messages over the budget of 35 (it reported 0 "regressions") | — |

The harness is now honest about moves to review. One limit: the budget is a message count, so a fix and a new move to review of the same size would cancel out.

### Build 147 × new server (`6f771108` vs deployed `b6fc0dad`)

Build 147 client import code was run against server rows from each server. With the new server, wrong outcomes on eB fall: 81 → 71, 16 → 15, 43 → 39 and 33 → 28 across my four sets.

Worse with the new server, and changing totals: 2 messages, 1 class (S3).
- **Class:** messages the new server now holds for review are booked by build 147's own local parse.
  - "Credit card payment of AED 2,500.00 received" (card_repayment): booked OUT 2,500. The deployed server booked it IN.
  - K001, a purchase with an injected "salary credit of SAR 9,999": booked IN 45.
- No reward/cashback or tail class is worse any more.

### Timing at `6f771108`

The over-length policy holds. Device worst case at 2,000 characters is 392 ms on a Mac; at 20,000 characters it is 100 ms or less. The server takes 42 ms or less.

### Open defects (none of S1/S2 from this round)

| ID | Sev | Class | Description |
|---|---|---|---|
| NEW-2r | S3 | REPRODUCED, regression vs `5dae2e2d` | 4 completed shapes are `no_movement` on the server: the Arabic bill-reminder tail, the Arabic month-to-date total tail, "scheduled transfer … executed as per your request", and "transferred … as scheduled". The server push is false; the device sends them to review. |
| CR-1 | S3 | REPRODUCED, new | `card_repayment` catches «سداد فاتورة … ببطاقتك الائتمانية» (a bill paid with a credit card), so it goes to review. |
| B147-1 | S3 | REPRODUCED | Messages the new server holds for review (card repayment, multiple events) are booked wrongly by build 147's local parse (2 of 578). |
| PAR-1 | S4 | REPRODUCED | 2 disposition differences between device and server (LB005, UN010), against the claim of 0. |
| LEN-1 | S4 | REPRODUCED | A 2,001-character Arabic text shortened by redaction is recorded on the server but reviewed on the device. |
| PRIV-0 | S2 | REPRODUCED, pre-existing (`5dae2e2d`) | English beneficiary names after "Standing order to" and "To Name:", 6–8-digit third-party account numbers after "account", and spaced IBAN fragments reach the server and the model. |
| PRE-* | S3 | Pre-existing | Own-account transfers booked as spend or income; a card-repayment receipt booked as spend; buy-now-pay-later adverts recorded; two events recorded as one. |

### Not checked

- Real AI calls.
- The native share and preview paths.
- The Smart Inbox UI.
- Timing on an iPhone.
- Any deployed server.
- The held-out set.
- The restore-confirmation and UI parts of `6f771108`.

## Check at f4dcabd3

A narrow check of `f4dcabd3` against `6f771108`, with a clean tree. Model: `claude-opus-5-5`. Synthetic data only. The repo was read-only; everything was run from scratch worktrees.

### Verdict: ACCEPT WITH FOLLOW-UP

No message went from right to wrong on any path, and nothing new throws. Wrong outcomes on the iOS import and the server fell again.

Three things need follow-up:
- One server-gate hole on the AI path (VAL-1). The device import catches it.
- A new class of completed messages over-held for review (HOLD-1).
- One server drop that went from right to silent (FT003).

### Results: 5dae2e2d → 6f771108 → f4dcabd3

708 messages: the original 350, my earlier 278, and 80 new probes at the new rules' edges (rm5). Each cell is wrong / silent / review.

| Set | n | Server `s` | iOS import `eB` |
|---|---|---|---|
| original (rm+rm2) | 350 | 14/10/61 → 1/12/24 → 1/11/26 | 29/3/29 → 2/3/20 → 2/3/20 |
| rm3 | 156 | 12/6/9 → 3/6/7 → 2/6/7 | 17/0/11 → 4/0/8 → 3/0/8 |
| rm4 | 122 | 14/2/17 → 6/4/14 → 6/4/14 | 12/0/9 → 4/0/12 → 4/0/11 |
| rm5 (new) | 80 | 12/3/20 → 6/4/19 → **0/5/30** | 17/0/13 → 6/0/12 → **2/0/23** |
| **Total** | 708 | 52/21/107 → 16/26/64 → **9/26/77** | 75/3/62 → 16/3/52 → **11/3/62** |

**Right → wrong:** 0 on any path.

**Right → silent:** 1, FT003 on the server: "Purchase SAR 45.00 at Jarir card *4521. Standing orders will be executed on the due date" is now `no_movement`. The device sends it to review.

**Completed → review on eB, 6f771108 → f4dcabd3:** 11. The 9 in rm5 are:
- RF007: "Your expected refund of SAR 150.00 … has been credited" (C017 in rm is the same shape).
- FT000, FT001, FT006, FT008: purchases with a refund-request or refund-timing footer, in English and Arabic.
- FT003: a purchase with a standing-order footer.
- AT004, AT007: third-party transfers that name two account types (`own_accounts`).
- TO001: "Bill 200, VAT 30, total 230 paid" (`total_with_parts`; it was booked at 230 before).

These 9 were right at `6f771108` (FT000, FT001, FT006 and FT008 were already right on the server and import, wrong only on the device). Also in the rm set: K000, which goes to `multiple_amounts`; that is acceptable.

**Still open from earlier rounds:**
- NEW-2r is still open on the server: B027, NM016, TL022, NM018, TL024 and C003 are `no_movement`, contrary to the fix claim.
- CR010 and LN010 are fixed.

**Totals:**
- A stated total is never recorded as its base figure any more. TO005 and TO008 went from WAMT to review.
- A total with a stated label records (TO002, TO009).
- "Including tip" forms (TO006, TO007) stay on review.

### Validator attack: an AI answer accepted for a message that is not a completed movement

30 cases. Each had a model answer of "completed transaction" at the stated amount.

**Holds everywhere:**
- the device `validateCaptureCandidate` (through `meaningRejectionOf`), on the import with the server row forged as processed
- server `parse-sms`
- declined or failed with a filler second sentence, and a status two sentences later
- over 2,000 characters
- Arabic declined or pending
- own-account and several-movement messages

**VAL-1 (S2, server).** In `process-ios-sms/index.ts`, `gatedMeaning(text, meaning, parsed.amount)` promotes `tip_component` / `total_with_parts` to `completed_movement` whenever the answered amount equals the stated total. It never checks for a not-completed cue. `meaningRejectionOf` does check (`isDeclinedText` comes first), but index.ts does not call it.

As a result, these become processed server rows, with a "recorded" push, when the model answers the total:
- "Purchase SAR 115.00 … incl. tip SAR 15.00 was declined / is pending / Not completed / Reversed"
- "Pre-authorization … (bill + tip) on hold"
- "Bill …, VAT …, total SAR 230.00 … Status: failed"
- the Arabic tip-form forms «…الإجمالي 115 ريال، العملية مرفوضة / قيد المعالجة»

The deterministic parse never accepts them, so this needs a model answer to happen. The `f4dcabd3` device import catches all of them: the validator rejects and the message falls to the local parse, which holds it. A client without that import would book them. `parse-sms` is not affected.

**Accepted on every path, through gaps in the cue words rather than the new rule:**
- "Awaiting merchant confirmation"
- "Attempted purchase SAR 45.00"
- "You will receive SAR 500.00 cashback on 01/12"
- a total form "… will be charged tomorrow"
- a tip form "… awaiting authorization"

The last two record on eB at the stated total. The device alone holds them, but `meaningHoldReason` releases the hold at the stated total.

### Redaction (fin → last)

Two sets:
- the earlier 378 privacy messages
- 117 fresh probes: 14 name cues × 3 names, 7 account lengths × 8 labels, 7 IBAN forms, and 12 texts where an amount or date sits next to an account number

**Closed:**
- spaced IBANs, including the forms with hyphens, lower case and "SA 03"
- every 5–9-digit third-party account after a label I tried, except "acc no." (see the next list)
- "Standing order to" and the other names after a cue (14 of 28 previous leaks fixed)
- full own-account numbers

**Still reach the server and the model:**
- The `To Sara Ahmed: SAR 50.00, IBAN …` shape (name before the colon, no transfer word): 14 of 378.
- "Payee <Name>" and "Benef. <Name>", even in transfer context.
- Every name cue in a text with no transfer word ("From:", "Sender", "Recipient name:", "In favour of", "Paid to").
- "acc no. 55123…": the label is masked as `[NAME]` and the 5–9-digit number survives.
- With the `payment` type hint on the AI path, «إلى: ليلى حسن علي 76811732 … مجدول» and "To: Sara Ahmed 92214480 … scheduled" keep both the name and the account number.

**New leaks:** 0.

**Over-masking:**
- No amount or date was lost on any of the 12 texts next to account numbers (12500, 150000, 1500000 IQD, 17112026, 20261117).
- The server parse of the redacted text gives the same amount and acceptance as the raw text on all 117.

**Swift == server:**
- Device == server on all 117 fresh texts.
- I read the Swift Shortcut path against `sms_redaction.ts`. The counterparty cue list, the transfer and purchase context words, the beneficiary rules after «إلى»/"To:" and the IBAN and long-number rules match one for one.
- XCTest was not run.

### Is the harness's accepted-list honest?

`tools/parser_diff/run.sh 5dae2e2d working-tree` at `f4dcabd3`: exit 0, 0 regressions, **38 messages to review against a budget of 38**.

- **The list is honest in what it prints, but weak as a gate.**
  - `ACCEPTED_REVIEW` (3 ids) is only printed. The budget was raised from 35 to 38 to absorb them.
  - The budget is still a message count, set exactly to today's figure. Any 3 other moves to review would pass if those 3 ids disappeared, and there is no headroom.
  - `ACCEPTED_SERVER` is keyed narrowly: by id, and only for a `not_completed` rejection.
- **Coverage gap:**
  - `cases/fu5.json` (100 cases, written with the change) has no completed refund using the "expected/pending refund … credited" wording, no purchase with a refund or standing-order footer, no third-party transfer naming two account types, and no VAT/fee total with "paid".
  - Those are exactly the 9 completed→review moves above, so the gate cannot see them.
- **Hygiene:** `tools/parser_diff/__pycache__/diff.cpython-314.pyc` is committed.

### Open defects at f4dcabd3

| ID | Sev | Class | Description |
|---|---|---|---|
| VAL-1 | S2 (server; device import safe) | NEW | `gatedMeaning` releases tip or total forms at the stated total with no not-completed check. A declined, pending, failed or reversed tip or VAT total becomes a processed server row with a false push when the model answers the total. |
| HOLD-1 | S3 | NEW, from `6f771108` | Completed messages over-held for review on every path: (a) an "expected/pending refund … has been credited" refund; (b) a purchase with a refund-request or refund-timing footer, in English and Arabic; (c) a third-party transfer naming two account types; (d) "Bill + VAT = total paid". 11 of 708 moved completed→review. |
| FT-1 | S3 | NEW, right → silent on the server | A purchase with a "Standing orders will be executed …" footer is server `no_movement` (silent); the device reviews it. The Arabic twin was already silent. |
| NEW-2r | S3 | Still open (claimed fixed) | 6 completed shapes are `no_movement` on the server (bill-reminder tail, month-total tail, "as scheduled"). |
| CUE-1 | S3 | Pre-existing | "Awaiting merchant confirmation", "Attempted purchase", "will receive … cashback on 01/12" and "total … will be charged tomorrow" are recorded. |
| PRIV-1 | S2 | Narrowed, pre-existing | "To <Name>: …" with no transfer word; "Payee" and "Benef." cues; any name cue without transfer context; "acc no. <5–9 digits>"; name and account kept under the `payment` hint. |
| PRE-* | S3 | Pre-existing | As at `6f771108`: own-account transfer booked as spend (AT008), Arabic refund direction (RF009), and the B147-1 / PAR-1 items, which were not re-measured this round. |
| HAR-1 | S4 | NEW | Budget equals the measured count (38/38) and is count-based; the fu5 cases do not cover the HOLD-1 shapes; a .pyc is committed. |

### Not checked

- Real AI calls.
- Build 147 against this server.
- Timing.
- The XCTest for the Swift Shortcut.
- The consent wording (UI).
- Any deployed server.
- The held-out set.

## Confirmation at a157e68e

A confirmation check of `a157e68e` against `f4dcabd3`. Reviewer `review-money`, model `claude-opus-5-5`, synthetic data only. Both commits ran from scratch worktrees; the repo was read-only. The server leg mirrors the new `index.ts` gate: `meaningRejectionOf(sanitizedText, amount, gatedMeaning(...)) != null` sends the message to review.

### Verdict: ACCEPT WITH FOLLOW-UP

VAL-1 is closed. The diff changes no outcome on my 708 messages. PRIV-1 is narrowed further, with one new over-masking class (S3). No S1 is open; the one S2 left is a residual PRIV-1 leak.

### (1) VAL-1

104 cases:
- my 16 earlier reproductions
- 88 fresh variants: English and Arabic × tip, VAT, service fee and FX fee × declined, pending, failed, reversed and on hold × status before or after the total, plus completed controls

The model answer was "completed" at the stated total. I checked:
- the `process-ios-sms` gate, which is the last step of both the primary and the legacy path
- `parse-sms`
- the device import, with the server row forged as processed

**Not-completed messages that become a processed server row:** 68 → **7** (of 96).
- **All the declined, pending, failed, reversed and on-hold forms are closed**, apart from the two Arabic «عملية معكوسة» cases below, in both languages and both orders, on every path.
- **The 7 left are cue-word gaps, not the gate.** They were already recorded by `parse-sms` and the device import at `f4dcabd3`, and are recorded identically now:
  - "Awaiting merchant confirmation"
  - "Attempted purchase"
  - "You will receive … cashback on 01/12"
  - a total "… will be charged tomorrow"
  - a tip "… awaiting authorization"
  - the Arabic prefix «عملية معكوسة:» ("reversed transaction") before a VAT total and before a service-fee total

**Completed totals:** 7 of 8 are recorded at the stated total on the server and the iOS import. The exception is the FX-fee form "USD 100.00 (SAR 375.00) + FX fee SAR 8.25, total SAR 383.25", which goes to review as `multiple_amounts`. That is review, not a wrong amount.

### (2) Regression check, f4dcabd3 → a157e68e

All 708 messages (original 350 + 358 probes), on every path (dB, dN, server, eB, eN):
- **0 outcome changes**, so no right→wrong, no right→silent and no new throw.
- Totals are unchanged from the f4dcabd3 check: server wrong/silent/review 9/26/77; iOS import 11/3/62.

### (3) PRIV-1

Two sets:
- the earlier 378 privacy messages
- 246 fresh cases:
  - the earlier 117
  - 2 names × 12 English cues, with and without a transfer word
  - 7 Arabic cues with an account number
  - 7 "acc no."-style labels
  - 60 purchases from 10 merchants after "paid to", "To", "To:" and «إلى»

**Closed:**
- all 14 "To <Name>: …" leaks
- 56 of 70 name leaks under the `payment` type hint
- every account-number leak under the `payment` type hint
- the "Payee" and "Benef." cues
- "acc no. / acc. / a/c no / acct no / ac" followed by 5–9 digits
- cues with no transfer word: "Sender", "Recipient", "Remitter", "Paid to", "From:"

**New leaks:** 0.

**Still reach the server and the model:**
- "From <Name>: …" (a heading with "From", the twin of the "To" heading)
- "Attn", "Name:" and "Customer" before a name, even in transfer context
- «إلى حساب <name>» with no colon, under the `payment` hint only (14)

**Over-masking:**
- **NEW at a157e68e:** "Card *4521: SAR 85.00 paid to <Merchant>" (no purchase word) masks the merchant as `[NAME]` (10 of 10 merchants). The model loses the merchant and its category.
- **Pre-existing:** "Purchase To: <Merchant> SAR 85.00 card *4521" and «شراء 85 ريال إلى <Merchant> بطاقة 4521» mask the merchant as `[REDACTED]` and also the user's own card suffix 4521.
- **No change to the server's rule-based parse:** amount, acceptance and date are the same on raw and redacted text for all 246. The merchant changes only on 7 transfers, where a person's name was the merchant.

**Device == server:** on all 246 fresh texts. Reading the code, the Swift Shortcut diff adds the same person-cue, "From:"/"paid to", "To <Name>:" and "acc" rules, with the same purchase-context guard. XCTest was not run.

### Open defects at a157e68e

| ID | Sev | Class | Description |
|---|---|---|---|
| VAL-1 | — | CLOSED | Nothing not-completed is released by the tip or total rule on the server gate. |
| PRIV-1r | S2 | Residual, pre-existing | Names after "From <Name>:", "Attn", "Name:" and "Customer"; «إلى حساب <name>» under the `payment` hint. |
| MASK-1 | S3 | NEW | "SAR … paid to <Merchant>" with no purchase word: the merchant is masked as a person. |
| MASK-0 | S3 | Pre-existing | "Purchase To: <Merchant>" and «شراء … إلى <Merchant> بطاقة NNNN» mask the merchant and the user's own card suffix. |
| CUE-1 | S3 | Pre-existing | Recorded although no money moved: "Awaiting merchant confirmation", "Attempted purchase", "will receive … cashback on <date>", "… will be charged tomorrow", "awaiting authorization", and the Arabic prefix «عملية معكوسة:» before a total. |
| HOLD-1 | S3 | Open since f4dcabd3 | Completed messages held for review: an "expected/pending refund … credited" message, a purchase with a refund footer, a third-party transfer naming two account types, "Bill + VAT = total paid", and the FX-fee total. |
| FT-1 | S3 | Open | A purchase with a "Standing orders will be executed…" footer is silent on the server; the device sends it to review. |
| NEW-2r | S3 | Open | 6 completed shapes are no-movement on the server. |
| PRE-* | S3 | Pre-existing | An own-account transfer booked as spend (AT008), an Arabic refund booked in the wrong direction (RF009), and B147-1 / PAR-1 (not re-measured). |
| HAR-1 | S4 | Partly fixed | The `.pyc` is gone. The budget is still a message count set at exactly 38 of 38, and the fu5 cases do not cover HOLD-1. |

### Not checked

- Real AI calls.
- The Swift XCTest.
- Build 147.
- Timing.
- Any deployed server.
- The held-out set.
