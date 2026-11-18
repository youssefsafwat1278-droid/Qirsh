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
