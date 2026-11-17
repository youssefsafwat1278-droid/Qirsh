# L — Independent review of the three commits after K

- Reviewer model: `claude-opus-5-5` (Opus 5.5). Wrote none of the code under review and none of the earlier reviews.
- HEAD reviewed: `0095a239bc54827cc6789e430261a6b0ab770f47`, branch `release-readiness/v1`, worktree `.claude/worktrees/v1-readiness`. Date 2026-11-17.
- Scope: `42a0fd0c` (parser round 5: FR-01, FR-02, FR-03, FR-13), `45ea901a` (RT-01, tab bar after sign-in), `0095a239` (RT-02 paste wording, RT-05 Arabic sentence). Baseline for "before": `0f90003f` (the commit K reviewed).
- Constraints: no tracked file changed (`git status --short` is identical before and after; this file is the only write). `deno.lock` is unchanged. A scratch worktree at `0f90003f` was created for the before/after runs and then removed (`git worktree list` shows no scratch entry). No simulator, device, Docker or production access was used.
- All probe messages are synthetic. Merchants are `SHOPX`, `Shop X` and similar.
- Harness (scratch directory `…/scratchpad/L/`): the device side is `dart run --packages=app/.dart_tool/package_config.json` calling `ParserEngine().parse`, `ParserEngine.isIgnoredMessage`, `TransactionStateCues.isNotCompleted`, `localParseOpposesDirection` and `validateCaptureCandidate`. The server side is `deno run` importing `process-ios-sms/parse.ts` (`isDeclinedText`, `deterministicParse`, `isResolved`). These are K's scripts (`probe/dart_probe.dart`, `probe/srv_probe.ts`, `probe/inputs*.json`), reused without changes, plus extensions that add the ignore flag and direction. The "before" runs used the same scripts against the `0f90003f` worktree, with a `package_config.json` that points `money_companion` at it.

## Commands run (actual results)

| Command | Result |
|---|---|
| `flutter test --no-pub test/engine/parser/ test/domain/capture/ test/features/capture/capture_import_service_test.dart test/features/capture/capture_sync_service_test.dart test/core/router/modal_route_observer_test.dart test/features/capture/manual_paste_declined_message_test.dart` | **+679, All tests passed** |
| `deno test --allow-all process-ios-sms/ parse-sms/ _shared/` (from `supabase/functions`) | **694 passed, 0 failed, 2 ignored** |
| K's 94 probes at HEAD, device and server | Cue verdict agrees on **94/94**. Results are in §1a |
| 87 new probes (L01–L87) and 14 extra probes (M01–M14), at HEAD and at `0f90003f` | Cue verdict agrees on **101/101**. Outcomes are in §1b. None of the L texts is in `declined_cases.json`: a text match found **0/87** |
| Corpus run, 263 unique texts, at `0f90003f` and HEAD, both sides | **7 changed on device and 7 on server**, the same 7 texts (§1c) |
| `modal_route_observer_test.dart` at HEAD, run against `git show 45ea901a^:app/lib/core/router/modal_route_observer.dart` (scratch import) | **+4 −2**: the "replace" test and the "navigator torn down" test **fail** on the old observer |
| Scratch widget test: a shell `ValueListenableBuilder` listening to `modalRouteOpen`, root sheet, navigator unmounted and remounted | Passed. No build-phase exception, and the tab bar comes back. The flag stays `true` while no navigator is mounted |

## 1. `42a0fd0c` — parser round 5

### 1a. K's probe set at HEAD

The 94 inputs are R1a–R1p, R2a–R2g, R4a–c, N01–N56 and K1–K11.

- **Wrong in a way that changes totals: 0 of 94.** Every FR-01 false negative now goes to review on the device and is REJECTed on the server: N09, N11–N18, N31–N35, N41, N42, K6. N02, N03, N19, N22, N27 and N43 (FR-03) are now `payment 100` on both sides, which is correct.
- **Still sent to review although the movement completed** (no total change): N05 `approved. Previous attempt declined.`, N06 partial reversal credited, N20 `FAILED VENTURES LLC`, N21 `at Café Cancelled`, and R2e on the device only. N28–N30, N36, N37, N46, N47 and K6 go to review by the new owner policy and are not counted as wrong.
- **Device and server disagree on the outcome: 4.**
  - R2e: device review, server `payment 100`.
  - N23 (security footer): device review, server ignored.
  - N25 `Refund of SAR 30.00 for purchase SAR 100.00`: device review, server `refund 30`.
  - N39: device review, server unresolved.
  - None of these changes totals through the deterministic paths. The cue verdict agrees on all 94.

### 1b. New probes (101: L01–L87 and M01–M14)

Inputs are in `scratchpad/L/new.json` and `scratchpad/L/extra.json`. Outcomes are in `new.cmp` and `extra.cmp`.

**Not-completed messages that change totals at HEAD (wrong direction: money recorded for a movement that did not happen)**

| ID | Input | Device | Server | At `0f90003f` |
|---|---|---|---|---|
| L48 | `Purchase of SAR 100.00 at SHOPX. Merchant declined transaction.` | payment 100 | payment 100 | **review / REJECT: REGRESSION** |
| M01 | `… Merchant rejected the payment.` | payment 100 | payment 100 | **review / REJECT: REGRESSION** |
| M02 | `Card payment SAR 100.00 at SHOPX - merchant declined` | payment 100 | payment 100 | **review / REJECT: REGRESSION** |
| L41 | `Payment of SAR 100.00 to STC did not go through` | payment 100 | payment 100 | same |
| L42 | `…has not been completed` | payment 100 | payment 100 | same |
| M03 | `…has not been approved` | payment 100 | payment 100 | same |
| L43 | `Transaction of SAR 100.00 at SHOPX was refused` | payment 100 | unresolved | same |
| L44 | `We could not process your payment of SAR 100.00…` | payment 100 | payment 100 | same |
| L45 | `Your payment of SAR 100.00 cannot be completed` | payment 100 | payment 100 | same |
| L46 | `عملية سحب نقدي بمبلغ 500 ريال لم تتم` | withdrawal 500 | payment 500 | same |
| L47 | `تم إلغاء شراء بمبلغ 100 ريال لدى SHOPX` | payment 100 | payment 100 | same |
| L49 | `…status changed from pending to declined` | payment 100 | payment 100 | same |
| L50 | `Failed payments SAR 100.00 to STC card *1234` | payment 100 | payment 100 | same |
| L53 | `Payment to STC SAR 100.00 bounced` | payment 100 | payment 100 | same |
| L63 | `…awaiting confirmation` | payment 100 | payment 100 | same |
| L52, L60–L62 | transfer `has not been processed` / `is under review` / `is being processed` / `قيد التنفيذ` | transfer 300 (affects account cash flow, `financial_semantics.dart:112-118`) | unresolved | same |

**Server-only wrong results**

All four are pre-existing. In each case the iOS Cloud path of a new build imports the server result: `validateCaptureCandidate` accepts it, and `localParseOpposesDirection` does not block it because the device parse has no transaction.

| ID | Input | Server |
|---|---|---|
| L85 | `Your card *1234 is now active. Credit limit SAR 10,000.00` | **income 10,000** |
| L86 | `Your credit limit has been changed to SAR 15,000.00` | **income 15,000** |
| L79 | `Exclusive offers: get SAR 50 cashback on purchases of SAR 200…` | **payment 50**. The server ignore list has no `offer`, `click` or `won` |
| M07 | `Transaction SAR 100.00 at SHOPX card *1234. Disputed transactions may be reversed` | **income 100** for a purchase |

**Completed purchases silently dropped** (no card, no total). All are pre-existing and unchanged from `0f90003f`.
- Device, 8: L08 `Offer Mart`, L09 `Click Pharmacy`, L10 `Promo Burger`, L11 `Won Kitchen`, L30 `Promotion Plaza`, L14 footer `For complaints call…`, L15 footer `https://…`, L16 footer `Check our latest offers`.
- Server, 3: L10, L30, and L17, a security footer.

**Completed movements newly sent to review by the new cues** (no total change):
- Both sides: L02 `pending balance`, L13 `Blocked cards can be reactivated…`.
- Server only: L26 / M05 `Transactions above SAR 5,000 will be declined` (the future marker plus a digit in the same clause), M11 (a refund with the same footer), M14 `Daily limit SAR 5,000; pending SAR 0.00`.
- Both sides: M06 `…سيتم تنفيذ العمليات المعلقة لاحقا`.
- Already in review before (not new): L23, L24, L25, L27 on the device.

**Correct, as the task required:**
- L01 `Purchase … approved. Available balance …; pending transactions may not be reflected` is `payment 100` on both sides.
- L35, L36, L37, L38, M10 and M12 (ordinary refunds of completed purchases, English and Arabic, some with pending or declined footers) are `refund` / credit on both sides.
- L31, L32 and L39 salary and deposit: income on both sides.
- L04–L07, L28, L29 and M13 (`Household`, `Holden`, `Bus Stop`, `One Stop`, `Hold Me`, `Stop & Go`, `Stopwatch`) are payments.
- L03 `spending` is a payment.
- L19 (Arabic-Indic digits) is `payment 120.5`.
- L64 is review.
- L33 and L34 (incoming transfers) are `transfer` on the device and income on the server. That is a type disagreement, pre-existing.

**Counts for the new set:**
- Messages whose result changes totals wrongly on at least one side: 19. That is 15 not-completed debits/withdrawals, of which **3 are regressions**, plus 4 server-only.
- 4 more change account cash flow only, as device transfers.
- Device and server outcome disagreements: 23. Cue verdict disagreements: 0.

### 1c. Corpus claim

- Corpus: 263 unique texts.
  - `bank_sms_golden_fixtures` / parser-gate / ambiguous / ignore fixtures: 33.
  - `SampleMessages`: 10.
  - `parser_rules.json` examples: 9.
  - Admin parity fixtures: 4.
  - `contract_fixtures/validated_capture_v1.json`: 22.
  - `sms_redaction_cases.json`: 37.
  - `ai_candidate_cases.json` and `declined_cases.json`, taken from `0f90003f`: 22 and 126.
- Changed outcomes: the same 7 texts on each side.
  - The six deliberate policy flips (`declined_cases` 19–23 and 118). Each went from `refund` on the device / credit on the server to review / REJECT.
  - `ai[32] "Purchase 500.00 EGP refund pending"`: device refund 500 → review; server payment 500 → REJECT. This change is correct.
- **Zero** of the 137 texts outside `declined_cases.json` changed from recorded to review. The fixer's claim holds if it means the non-declined corpora. Their own harness (`scratchpad/fix/corpus_dump.dart`) covered 60 texts and the device side only.

### 1d. The import-path direction rule (`validated_capture.dart:230-249`)

**LR-03.** The rule can adopt the device's wrong direction.
- The repository's own fixture `sms_redaction_cases.json:135`, `Your account **1234 was credited by EGP 500.00 from … via IPN`, is read by the server as **credit 500** (correct) and by the device as **payment 500** (wrong). `vc2.dart` output: `IPN vc.accepted=true … localNoSender=payment opp=true`.
- On `capture_import_service.dart:556-563` (not AI-primary), the rejected server result falls through to `_importLocally` (`:531`).
- `_importLocally` ingests with `onDeviceOnly: true, forceLocalAutoConfirm: true` (`:151-159`). The device's **payment 500** is therefore auto-confirmed, if the proof gate passes (CODE-SUPPORTED; not executed end to end). That is a 1,000 swing.
- At `0f90003f` the server's credit was imported.
- On `capture_sync_service.dart:953-963` and on the AI-primary import branch, the same item goes to Smart Inbox through `_persistBackendUnprocessableCapture` / `persistUnprocessableCapture`. That outcome is visible and recoverable.
- The commit message says the result is "no longer confirmed on both import paths". That is not true for the non-AI-primary import path, where the device's opposite reading is confirmed instead.

**LR-09.** The "device's own parse" is `const ParserEngine().parse(text)` with no sender, bank profiles or catalog rules (`:239`). It is not the parse the device actually performs.
- Golden fixture `sa_anb_atm_deposit_income` (sender `anb`, `bank_sms_golden_fixtures.dart:399`): the server says credit 4,000, and the device with its sender says income.
- Without the sender the device parse says withdrawal, so the rule fires (`opp=true`). A correct deposit goes to review on the sync and AI-primary paths.

**Duplicates.** I found no duplicate path. A blocked server result is never imported. The local fallback commits through `CaptureCommit` with a `readReceipt` keyed by capture id (`capture_import_service.dart:595-607`). CODE-SUPPORTED, not executed.

### 1e. Ignore rules

**Whole-word matching**
- It fixes `Hotpot`, `Wonder` and `Promoda`.
- It leaves whole-word merchant names and footers silently dropped on the device: 8 of 8 such probes (LR-05).
- Server and device ignore lists differ:
  - The device ignores `offer`, `click`, `won`, `complaint`, `https://` and others (`parser_engine.dart:1115-1160`).
  - The server ignores only `parser_rules.json` `ignoreKeywords`, which has 17 entries.
  - So L08, L09, L11 and L14–L16 are dropped on the device and recorded on the server.

**OTP leakage** (8 OTP probes, L71–L78)
- The server ignores all 8.
- The device ignores 6. L72 `Use 482913 as OTP to complete SAR 100.00 purchase` and L78 `Enter code 482913 … Do not share this OTP` do not match `_otpCode` (`parser_engine.dart:205-212`). At `0f90003f` the device ignored them; now it sends them to review.
- With AI consent, `isIgnoredMessage` is false for them (`parser_engine.dart:159-166`), so `wasIgnored` is false and `notCompleted` is false. AI is then consulted (`add_transaction_usecase.dart:858-870`).
- If the model returns payment 100, nothing in `AiCandidateValidator.validate` rejects it: cue check, grounding, no local parse. An OTP would be **auto-confirmed as spend**. CODE-SUPPORTED, SUSPECTED. No model was run.
- **Quantified: 2 of 8 OTP probes (25%) newly reach AI. No promo probe newly leaks on the device.** L82 `winning` and L84 `promoted` go to review, not to a transaction, on the deterministic path.

**Security-footer purchases with AI consent on** (N23, L17, two shared `review` cases)
- They now reach AI and can be auto-confirmed. For genuine purchases that is the correct result.
- The risk is the OTP shapes above, not the footers.
- `declined_cases_totals_test.dart` explicitly skips the AI leg for `review` cases, so this is untested.

### 1f. Test changes

**The six `completed_credit` → `not_completed` flips and the three changed tests**
- Changed tests: `declined_transaction_test.dart` (two expectations) and `parse_test.ts` (one).
- These flips follow the stated policy. A refund of a failed or declined original returns money that was never recorded, so recording it as a credit nets spend down for a purchase that never counted. Review is the "ambiguous stays reviewable" outcome.
- They do not hide a regression for genuine refunds. L35–L38, M10 and M12 and the shared `completed_credit` case `Refund of SAR 99.00 for your order at SHOP TWO credited` still record a credit on both sides.
- Side effect: when the original *was* debited and recorded from another SMS, spend stays overstated until the user confirms the card. This reverses a DATA-01 decision. It should be in `DECISIONS-NEEDED.md` as an owner decision. It currently appears only in code comments as "owner policy".

**The fixture word change in `ai_candidate_cases.json:579`** (`pending` → `noted`)
- It is legitimate for keeping that case about direction.
- But the original case expected `accepted: true` for AI type `income` on `Purchase 500.00 EGP refund pending`, which records +500 for a refund that has not happened. HEAD now correctly rejects it.
- No test asserts that rejection: `grep -rniE "refund (is )?pending|pending refund" app/test supabase/functions` finds nothing. The edit masks a correct behavior change rather than a wrong one, but the protection is untested (LR-10).

## 2. `45ea901a` — modal route observer

- **Correct for the reported defect.** The new test reproduces both failures on the old file (−2: replace, and navigator torn down).
- **Popped routes that are still animating.** `didPop` removes the route at the start of the pop, as the old counter did, so the bar reappears at the same moment as before.
  - Any other popped route is in `_RouteLifecycle.popping`, which is greater than `remove`, so `isActive` is false and the prune drops it (Flutter `navigator.dart:640-643`, `3524-3527`).
  - At `didPush` the new route is in `pushing` or `idle`, so `isPresent` is true and it is not pruned.
- **Teardown.** The stale route is dropped only at the **next** event on the new navigator: the initial route's `didPush`.
  - Between unmount and remount the flag stays `true` (scratch test: `flag while unmounted: true`).
  - Nothing renders the bar in that window, so this is harmless. It would matter if a future flow kept the shell mounted while swapping only the navigator with no initial push.
- **Root navigator and nesting.** `app_router.dart:76` attaches the observer to the root `GoRouter` navigator, which has no `ShellRoute`.
  - Sheets on a nested navigator are not observed (scratch test: `nested sheet -> false`). The app has none, so this does not apply today.
  - None of the 69 `showModalBottomSheet`/`showDialog` call sites passes `useRootNavigator: true`. They all use the nearest navigator, which is the root.
- **`PopupRoute`.** Menus and dropdown routes also hide the bar, as before. Tooltips are not routes.
- **Memory and hot paths.** At most a handful of route references are held, and they are pruned on every event. `removeWhere` over that small set with `isActive` costs a history scan per navigation. Negligible.
- **Build phase.** In the scratch test, flipping the value during the navigator's initial build raised no exception (`tester.takeException()` was null).
- Runtime confirmation on a simulator or device is separate and **not done here**. The commit says the same.

## 3. `0095a239` — paste wording

- The single-message paste branch now checks `TransactionStateCues.isNotCompleted(item.message)` **before** `savedForAnalysis` (`manual_paste_screen.dart:331-337`).
- **False positives of the cue on real purchases.** L02, L13, M06 on the device; L26, M05, M11 and M14 by server wording. The user is told "This payment was declined or not completed — nothing was recorded." Before this commit they were told to add it manually.
  - The claim "nothing recorded" is true for money.
  - But the copy now discourages the one action that would recover a real purchase.
  - It also calls a pending hold or a refund of a declined purchase "declined". `pending`, `on hold` and refund-of-declined all reach this branch.
  - What the user should do: open Smart Inbox if a card exists, otherwise add the transaction manually. The copy says neither.
- **`savedForAnalysis` path.** With cloud and AI consent, a draft is saved to Smart Inbox before ingest (`:258-267`) and kept when the disposition is unprocessable (`:278-281`). A declined paste therefore leaves a Smart Inbox card while the user is told only that nothing was recorded. Totals are still unchanged, so this is wording, not data.
- **Batch paste** (several messages) still labels the item "Not understood" / `غير مفهوم` (`:697`) and counts it as failed (`:732-733`). RT-02 is fixed only for the single-message path.
- **`transactions_screen.dart:2364`.** This is the suspected-duplicate "keep both" action, not a paste entry. When it gets `notTransaction` it shows `pasteNotATransaction` ("add it manually"). If the stored capture text is now not completed, the old invitation remains. S4.
- **Arabic.** Both `pasteNotCompleted` (`هذه العملية مرفوضة أو لم تكتمل — لم يُسجَّل شيء.`) and the rewritten `otpSentTo` are Modern Standard Arabic, consistent with neighbouring strings. The previous `otpSentTo` was Egyptian dialect. RT-05 is fixed.

## Findings

| ID | Sev | Class | Finding | Required action |
|---|---|---|---|---|
| **LR-01** | S2 | REPRODUCED, REGRESSION | Adding `merchant` (and `via`) as merchant introducers (`parser_rules.json:192-193`, `transaction_state_cues.dart:109`) makes "Merchant declined/rejected …" a name. L48, M01 and M02 now record payment 100 on **both** sides; at `0f90003f` they were review / REJECT. | Require a colon or a following name for `merchant` (`Merchant: X`), or exclude a cue directly after a bare `merchant`. Add L48, M01 and M02 to `declined_cases.json`. |
| **LR-02** | S2 | REPRODUCED (likelihood SUSPECTED) | Residual false negatives change totals on both sides. Twelve wordings, all pre-existing: did not go through; has not been completed/approved/processed; refused (device); could not process; cannot be completed; bare `لم تتم`; `تم إلغاء شراء`; from pending to declined; plural `Failed payments`; bounced; awaiting confirmation; plus pending/under-review transfers as device cash flow. | Decide each one, add them to the shared table, and rewrite KNOWN-LIMITATIONS §V1-001 from this run. |
| **LR-03** | S2 | REPRODUCED (parser) + CODE-SUPPORTED (path), REGRESSION | The direction rule makes the non-AI-primary import path auto-confirm the **device's** opposite reading. Repository fixture IPN credit: server credit 500 → device payment 500. The commit claim "no longer confirmed" is false for that path. | Route a direction conflict to Smart Inbox on `capture_import_service` as well (as the sync path does), instead of falling through to `_importLocally` with `forceLocalAutoConfirm`. |
| **LR-04** | S2 (owner may re-rate S1: large amounts) | REPRODUCED, pre-existing | The server records non-transactions as money, and new clients on the iOS Cloud path import them: credit-limit change → income 15,000; card activation with limit → income 10,000; promo `offers` → payment 50; `Disputed transactions may be reversed` → income 100 for a purchase. | Make server `credit` direction need a movement verb, not `Credit limit`. Port the device ignore words to the server. Add these to the shared table. |
| **LR-05** | S2 (continues FR-13) | REPRODUCED, pre-existing | FR-13 is only partly fixed. Whole-word ignore words still silently drop real purchases on the device (8 of 8: `Offer Mart`, `Click Pharmacy`, `Promo Burger`, `Won Kitchen`, `Promotion Plaza`, footers `complaints`, `https://`, `offers`). There is no Smart Inbox card. The server records 6 of them, so totals depend on the path. | K's second action: a review card when any ignore word fires on purchase-shaped text with an amount, not only security words. Align the server and device lists. |
| **LR-06** | S2 | CODE-SUPPORTED, SUSPECTED | 2 of 8 OTP probes (L72, L78) no longer match the OTP-code pattern and now reach AI with consent on. Nothing in the validator rejects an OTP, so the OTP can be recorded as spend, and the purchase SMS that follows is recorded again. | Broaden `_otpCode` (`code NNNN`, `NNNN as OTP`), or skip AI when a security word and a 4–8 digit token co-occur. Add the AI leg to the `review` cases in `declined_cases_totals_test.dart`. |
| LR-07 | S3 | REPRODUCED, REGRESSION (total-neutral) | The new cues send completed movements to review: `pending balance`, `Blocked cards can be reactivated`, `Transactions above SAR 5,000 will be declined` (server), `pending SAR 0.00`, `سيتم تنفيذ العمليات المعلقة`, and a refund carrying that footer. | Treat `pending`/`blocked` before a noun or amount label as advice; drop the digit trigger when the amount is a threshold. |
| LR-08 | S3 | CODE-SUPPORTED | Paste copy. (a) A cue false positive on a real purchase now tells the user "nothing was recorded", which discourages a manual add. (b) It says "declined" for pending holds and refunds. (c) It hides the Smart Inbox card it just kept. (d) Batch paste still shows "Not understood". | Neutral copy ("did not complete or is still pending; no total changed — check Smart Inbox or add it if it did go through"). Apply it to the batch status too. |
| LR-09 | S3 | REPRODUCED | `localParseOpposesDirection` parses without the sender or catalog. The golden ANB ATM deposit (server credit, device-with-sender income) is blocked to review on the sync and AI-primary paths. | Pass the sender and bank profiles into the check, or compare against the device's real parse. |
| LR-10 | S4 | REPRODUCED | No test asserts that `refund pending` is rejected (the fixture word was changed). The six DATA-01 policy flips are not recorded in `DECISIONS-NEEDED.md`. | Add the test case. Record the owner decision. |
| LR-11 | S4 | REPRODUCED | Residual K false positives: N05, N06, N20, N21, R2e (device). Remaining outcome disagreements: R2e, N23, N25, N39. | Keep listed in KNOWN-LIMITATIONS. |
| LR-12 | S4 | CODE-SUPPORTED | Observer: the flag stays true while no navigator is mounted; nested-navigator modals are unobserved (no nested navigators today); the suspected-duplicate "keep both" still says "add it manually" (`transactions_screen.dart:2364`). | Backlog. Runtime check of RT-01 on a simulator or device. |

## Verdicts

| Commit | Verdict | Reason |
|---|---|---|
| `42a0fd0c` | **ACCEPT WITH FOLLOW-UP** (blocking for READY: LR-01, LR-03) | Every K FR-01 probe is fixed on both sides, cue parity is 101/101 on new probes, ordinary refunds and completed purchases with pending or hold wording are kept, and the non-declined corpus is unchanged. But it introduces one false-negative class (LR-01) and one path regression (LR-03), and it leaves FR-13 partly open (LR-05). |
| `45ea901a` | **ACCEPT** | The fix is correct. The test genuinely fails on the old observer. Only S4 notes. Runtime confirmation is still needed. |
| `0095a239` | **ACCEPT WITH FOLLOW-UP** (LR-08) | The single-message copy is correct for true declines and the Arabic register is fixed. The batch path is not covered, and false positives now get worse guidance. |

## V1-001 at HEAD — what is and is not established

- Established: **no probe in K's set (94 inputs) changes totals** on either side through the deterministic paths. Cue verdicts agree on all 94, and on all 101 new probes.
- **Not established, and false:** "no known probe still changes totals."
  - At HEAD, 15 not-completed messages from this review are recorded as money on the device, and 14 on the server. Three of them are new regressions from this commit (LR-01).
  - The server also records 4 non-transactions or wrong directions (LR-04).
  - The non-AI-primary import path can now confirm the device's wrong direction (LR-03).
- Coverage: the shared table has 177 synthetic cases, K has 94 probes and this review adds 101. None of this is universal coverage of bank wording. The AI legs (consent on) were not run against a model. Installed builds 147 and older remain unprotected, as recorded by K.
- V1-001 stays **S1 OPEN** until LR-01 to LR-04 are decided or fixed, the server is deployed, and the build is verified on a device.
