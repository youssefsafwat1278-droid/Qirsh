# Closure round 3: parser (`parser`)

- **Model:** `claude-opus-5-5` (Opus 5.5). Source: my runtime's own statement of its model. I did not check it any other way.
- **Date:** 2026-11-18. Worktree `.claude/worktrees/v1-readiness`, base `HEAD` = `d1212986`. Nothing committed, staged or stashed.
- **Scope:** owner brief round 3, sections 4.1, 4.2, 4.4, 4.6 and 5, under the constraints of 3.7 and 3.15. Issues V1-001, V1-031, V1-071..V1-090, R-review of the tenth parser commit, and the coordinator's defect classes.
- **Evidence language:** every number below is from synthetic messages. The harness sets and `declined_cases.json` were used during development, so their numbers are **development (tuned-on) numbers, not real-world accuracy**. I did not read `tools/message_eval/heldout/**`.

## 1. Files changed (all within my assignment)

| File | Change |
|---|---|
| `app/lib/engine/parser/message_meaning.dart` (new) | `MessageKind`, `MessageDisposition`, `MessageMeaning` and its word lists (done verbs, tense, due, future, offer, summary, own-account, cash-deposit, source-of-funds, own-destination, abbreviations) |
| `app/lib/engine/parser/currency_table.dart` (new) | Table-driven ISO list (154 codes) and local forms (`SR`, `ر.س`, …) |
| `app/lib/engine/parser/parser_engine.dart` | `clauseScope`, `meaningOf`, charged-amount pairing, merchant-safe currency, clause-scoped ignore and notice checks, type from the clause flow |
| `app/lib/engine/parser/direction_signal.dart` | `debitFlow`/`creditFlow`, `flowOf` (verb and preposition structure), clause-scoped `detect` |
| `app/lib/engine/parser/normalizer.dart`, `parse_result.dart`, `transaction_state_cues.dart` | Local currency forms; `ParseResult.meaning`; cues read the clause core |
| `supabase/functions/process-ios-sms/message_meaning.ts` (new) | Server mirror of the above, reading `parser_rules.json` |
| `supabase/functions/process-ios-sms/parse.ts` | Uses the meaning: `no_movement` → rejected with no AI; review kinds → direction `unknown`; charged/foreign amounts; table currency. Removed the import my change left unused |
| `supabase/functions/process-ios-sms/parser_rules.json` | New `messageMeaning` and `currencyTable` sections (generated from Dart, drift-tested); `مدفوعات` added to `debitKeywords` |
| `declined_cases.json`, `declined_cases_deviations.json` | Pins re-measured; see §4 |
| Tests | `app/test/engine/parser/message_meaning_test.dart` (new), `supabase/functions/process-ios-sms/message_meaning_test.ts` (new), `transaction_state_cues_drift_test.dart`, `declined_state_cues_table_test.dart`, `round9_regression_test.dart`, `parse_test.ts` |

`supabase/functions/_shared/money_text.ts` and `parse-sms/**`: not changed. `parse-sms` has no deterministic classifier apart from its amount grounding (`money.ts`).

## 2. Work items

### 4.1 Meaning before amount — DONE (device and server)
- `clauseScope` splits the text into sentences and marks each one as event, figure or text.
  - A labelled figure (balance, limit, amount due) is a footer.
  - A sentence with no amount and a footer cue is a footer: security advice, an advert, a notice, or another attempt's status.
  - A no-movement event sentence next to a real movement is a footer.
  - Status cues, ignore words, notice words and direction read only the remaining **core**.
- `meaningOf` returns a kind, a machine-readable reason and a disposition:
  - `otp`, `undetermined` and `no_movement_notice` (`bill_due`, `scheduled_or_expected`, `offer`, `summary`) → disposition **no_movement**;
  - `not_completed` (`pending`, `declined_or_failed`), `own_account_transfer`, `cash_deposit` and `multiple_events` → disposition **review**;
  - `completed_movement` (`single_event` or `footer_set_aside`) → disposition **record**.
- **Late fix in this session (field lines):** a bank layout line (`مبلغ:SAR 100.00`) is a bare field line. It is not an event of its own, and the status or notice line above it is never a footer. Without this fix, "…will be processed" or an advert followed by a layout block was recorded. Eight totals tests caught it.
- Device: `isNoticeMessage` is also true for a `no_movement_notice` meaning, so import paths distrust a server result for a due bill, an expected salary or a scheduled payment. Its only library caller is `validated_capture.dart`.
- Server: `parseSms` returns `accepted:false` before any AI call for `no_movement`. Review kinds resolve to direction `unknown` (unresolved).

### 4.2 Amount roles, including V1-084 — DONE
- "Charged SAR 75.00" becomes the transaction amount. The other-currency figure becomes `foreign_amount` / `foreign_currency`. This holds on both sides; the server adds optional `foreign_*` fields to `ParsedCapture`.
- Different movement amounts in one message (purchase plus cashback) → `multiple_events` → review.
- **Not done:** tip and fee totals.

### 4.3 / §5 Direction — DONE
- `flowOf` reads the clause's verbs and prepositions ("debited", "paid to", "credited", "received from", `تم خصم`, `تم إيداع`, `إلى حسابك`). The first phrase wins. "Credited to X **from your account**" is a debit.
- A noun ("deposit", "salary", "refund" in a merchant name) no longer outweighs the structure.
- **ATM cash deposits are review, not income.** Own-account moves (two references, or a strong marker) are also review.
- `DirectionSignal.detect`, the cross-check that imports apply to a server or AI direction, ignores a bare `إلى حسابك` with no verb. This matches English, where a bare "to your account" never counted. Without it the validator rejected a server debit, and the import fell back to confirming the local reading (`capture_import_service_test` FR-02/LR-03).

### 4.4 Currency — DONE
- Currency comes from the table (ISO list plus local forms). `SR1,250.00` → SAR 1,250; `NGN` is read.
- A code that names the merchant ("at USD Store") is not the currency.
- Absence is reported, not invented:
  - device: `ParseResult.currencyDefaulted` and `meaning.currencyAbsent`;
  - server: `messageMeaning(text).currencyAbsent`.
- Persisting or acting on it belongs to files I do not own (§6).

### 4.6 Both sides identical — DONE for the shared rules
- The `messageMeaning` and `currencyTable` sections of `parser_rules.json` are generated from Dart. The drift test asserts exact equality of keys, lists, the ISO list and the local forms.
- The same synthetic cases run in `message_meaning_test.dart` and `message_meaning_test.ts`.
- Characterization pins are now separate from acceptance pins:
  - each deviation row carries `pin: safe_deviation` (666 rows) or `pin: open_defect` (34 rows);
  - both tests check the `pin` field and enforce a ceiling: `_maxDeviations` / `MAX_DEVIATIONS` = 700, down from 758;
  - the allowlist cannot grow without editing the ceiling.

### §5 Regression discipline — see §3 and §4.

## 3. Development numbers (tuned-on, synthetic; harness `pre` = HEAD vs `v6`)

1,758 messages: 1,388 completed and 370 not a movement. Legs:
- `dB` / `dN`: device with / without a bank sender;
- `s`: server deterministic;
- `eB` / `eN`: device end-to-end.

| Leg | Wrong | Silent | Review | OK |
|---|---|---|---|---|
| dB | 65 → 5 | 0 → 0 | 483 → 391 | 1209 → 1361 |
| dN | 50 → 5 | 3 → 2 | 692 → 695 | 1012 → 1055 |
| s | 58 → 14 | 30 → 14 | 568 → 521 | 1102 → 1209 |
| eB | 66 → 11 | 0 → 0 | 443 → 337 | 1249 → 1410 |
| eN | 58 → 11 | 0 → 0 | 552 → 506 | 1148 → 1241 |

**No message became newly wrong or newly silent on any leg.**

ok → review moves and their justification:
- Cash deposits (owner §5): Q062–Q065, MB09/10/26/37/38, MD05/06/11, T0752–T0754.
- Fixed/term deposit: MD10 (own-account).
- Two movements in one message: T0916, Q206.
- Q057 "ATM cash deposit reversal": a reversed cash deposit is ambiguous.
- Q134 (dN/eN only): the only currency is in the merchant name and there is no sender.

v6 ran before the last three fixes (field lines, no-movement notices to import paths, bare `إلى حسابك` in `detect`). Those affect the cases named in §2. The table suites below were re-run after all three. I did not re-run the harness after them.

**Speed** (`perf2.dart`, 1,564 table texts, device, two runs each, under concurrent test load): HEAD mean 0.56–0.61 ms, p99 3.9–4.8 ms; now mean 1.78 ms, p99 7.7–8.6 ms, max 38 ms. That is about 3× slower, and far inside the 2-second isolate timeout.

## 4. Changed test expectations, and why

1. **`round9_regression_test.dart`:** "Cash deposit SAR 1,500.00 to account *5678 via ATM" changed from *recorded as income* to *review row, not recorded, not silent*. Reason: owner brief §5.
2. **`declined_state_cues_table_test.dart`:**
   - The allowed device-value set gains `completed_income`; correct credits are now income.
   - The preview branch calls `isNoticeMessage(text, wholeText: true)`, which keeps the whole-text reading this check always used. `isNoticeMessage` itself is now core-scoped.
   - Ceiling 700 plus the `pin` check were added.
3. **`parse_test.ts`:** ceiling 700 plus the `pin` check were added.
4. **`declined_cases.json`** (1,565 rows; no `expect` value changed):
   - 178 device pins and 114 server pins re-measured. Defect rows went from 75 to 34; the fixed Q defects were removed.
   - Moves away from correct, both sides: the cash deposits Z069, G014a, G014b and Q062–Q065; the multi-events A114 and Q206; device-only Q043 (own transfer). All are review, never recorded.
   - Added open-defect parts:
     - `detailed purchase preview` on Q057, Q061, Q226, Q229, Q230, Q233, Q238, Q240, Q244 and Q245. The preview is not mine, and it still shows these notices in full.
     - `server accepts a grounded AI refund` on Q057.
     - `the sync import confirms a processed server refund the device keeps in review` on Q057, which is now review rather than income.
   - Sync-import defect parts **removed**, and now held by `capture_sync_service_test` as acceptance: Q061, Q148, Q150, Q151, Q153, Q224, Q225, Q227, Q231, Q233, Q235, Q236, Q237, Q239, Q242, Q243, Q245, Q247, Q248, Q249. They are protected by the no-movement `isNoticeMessage` change.
   - The 15 other HEAD sync-import parts are kept unchanged (Q140, Q142, Q147, Q149, Q152, …).
5. **`declined_cases_deviations.json`:** regenerated, 758 → 700 rows, each with `pin`.

**How "before" was confirmed:**
- **Dart.** `message_meaning_test.dart` was rewritten with a no-flutter shim (scratch `fb/before.dart`). The meaning-API group was dropped, because that API does not exist at HEAD. I ran it with `dart run --packages=<HEAD package config>` against an extracted HEAD tree:
  - HEAD: 25 of 32 cases fail. They include both new `isNoticeMessage` cases, every notice, pending, direction, cash and own-account case, and all four currency/amount cases.
  - Worktree: all pass. The full file passes 40/40 under `flutter test`.
- **Deno.** `message_meaning_test.ts` was copied into the HEAD tree and run with `deno test --no-check`. All five parse-level tests fail at HEAD.
- **Field-line fix.** Eight `declined_cases_totals_test` composites failed in this session's intermediate state, and pass after the fix. They also pass at HEAD.

## 5. Commands and results (final state)

- `flutter test --no-pub -j 2 test/engine/parser/ test/features/capture/capture_sync_service_test.dart`: **3,353 passed** (run before the bare-`إلى حسابك` change; the final run below covers it).
- `flutter test --no-pub -j 2 test/domain/capture/ test/features/capture/{capture_import_service,capture_sync_local_recovery,ai_not_transaction_review,capture_notification_content,capture_generic_text,cloud_ack_review}_test.dart`: **199 passed**.
- Final run, after every change: `flutter test --no-pub -j 2 test/engine/parser/ test/engine/ai/ test/features/capture/capture_sync_service_test.dart` plus the 20 test files that use `AddTransactionUseCase`: **3,723 passed, 0 failed**.
- `flutter analyze --no-pub lib/engine/parser test/engine/parser`: **no issues**.
- `deno test --allow-all --no-lock process-ios-sms/ _shared/`: final run **757 passed, 0 failed**. An earlier run had one failure in `capture_state_machine_test.ts` while another specialist was editing that file; alone it passed 52/52.
- `deno test parse-sms/`: 12/12. `deno lint process-ios-sms/`: clean.
- `deno.lock`: unchanged.
- **The "declined table" failure the ai specialist reported is fixed.** The row "approved. Previous attempt declined." is now acceptance-correct on both sides.

## 6. Not done or not verified

- **Not done:**
  - tip and fee totals (§4.2);
  - an AI-primary notice gate (the AI-primary path still checks only `isIgnoredText`; that is ai-owned);
  - the Swift and asset notification preview, which still shows detailed previews for the 10 notice rows above.
- **Not verified:**
  - Q057 and Q061 on the sync path at HEAD. I did not check out HEAD; both rows are pinned as open defects.
  - Real bank messages, real-world accuracy and the held-out set. Those belong to the `eval` specialist.
- The `expect` truth column still says `completed_income` for cash deposits. I left truth data unchanged; the owner should decide whether to relabel it.

## 7. Compatibility

- **Stored data:** nothing rewritten (3.15). `meaning` is not persisted. The new `foreign_*` and `meaning` fields are optional and additive.
- **Build 147 against the new backend:** extra optional JSON fields are ignored. The server now rejects no-movement notices that it used to return as processed. That is safer for the old app, which confirmed them.
- **New build against the old backend:** the device's no-movement `isNoticeMessage` and the cash/own review now distrust old-server results for those texts. They go to Smart Inbox, never to confirmed money.

## 8. Changes needed in files I do not own

1. `add_transaction_usecase.dart` and the import services: consume `ParseResult.meaning` / `ParseOutcome.meaning`, and book `cash_deposit` and `own_account_transfer` as review/neutral. Act on `currencyAbsent` / `currencyDefaulted` (V1-031).
2. `capture_import_service.dart`: a validator `direction_contradiction` rejection should go to Smart Inbox like `_localContradicts`. Today it falls back to the local reading.
3. `_shared/ai_candidate_validator.ts`: extend `CURRENCY_CODES` to the table's ISO list. Add an AI-primary no-movement gate that uses `messageMeaning`.
4. `localParseOpposesDirection`: use the booked direction. This is coordinator class 6, owned by ai.
5. The Swift preview and `app/assets/catalog/parser_rules.json`: stop showing notices as detailed purchases.

## 9. Coordinator classes

| Class | Status |
|---|---|
| 1. Pending booked as done ("under processing", "scheduled for", "will be debited/executed", refund requests) | Fixed on both sides; Arabic cases included |
| 2. Notices booked as money (expected salary, adverts with a figure, Arabic bill due on the cloud path) | Fixed; the server rejects them with no AI |
| 3. Wrong direction (deposit/salary wording on outgoing money, "credited to X from your account", cashback reversal deducted, Refund/Salary merchant names, own-account transfers) | Fixed; own-account transfers are review |
| 4. Foreign figure instead of the charged amount (cloud) | Fixed |
| 5. Wrong amount on multi-event messages | Fixed (now review); tip/fee totals not done |
| 6. Device contradiction check overruling a correct answer | ai-owned; reported in §8 |

## 10. Owner actions

- Confirm the cash-deposit review rule, and decide whether to relabel the table's `expect` values.
- Assign the §8 items.
- Deploy `process-ios-sms` only together with its `parser_rules.json`.

## Follow-up (after the `ai` specialist's Follow-up 6), 2026-11-18

Requested by the orchestrator. Model: `claude-opus-5-5`. Synthetic messages only. Nothing committed.

### (1) Q232 ("Annual fee of SAR 250 will be charged on 1 Dec") — FIXED, not just re-pinned
- **Before:**
  - device: `undetermined` (the figure is a labelled fee and no sentence counted as an event), so review;
  - server: unresolved; AI-primary consulted the model; a grounded AI payment was accepted.
- **Class fix, both sides:**
  - A done verb whose clause holds a future-tense word (new list `futureTense`: will, shall, to be, `سيتم`, `سوف`) makes a sentence `scheduled_or_expected`, even with no scheduling word.
  - A message with no event sentence is a `no_movement_notice` when **every** sentence carrying a currency figure is one. A due footer next to a fee is not: "Foreign transaction fee SAR 3.25 … Your card renewal is due" stays unresolved, which the table caught.
  - `parse.ts` `parsePrimarySms` holds a `no_movement_notice` before any model request. It returns `ai_ignored` with `reviewReason`, so `index.ts` stores the reason and the app keeps the capture in Smart Inbox.
- **Pin now:**
  - Q232: device `review`, server `ignored` (rejected with no AI on every path), no defect.
  - 22 other notice rows moved from server `unresolved` to `ignored`, for the same reason (Q061, Q148, Q150–Q155, Q224–Q233, Q235–Q249 notices).
  - Q00, Q07, Q20, Q21, L81 and Q241 became acceptance rows.
  - Sync-import defect parts removed (now held by `capture_sync_service_test`): Q152, Q154, Q155, Q228, Q232.
  - Deviations: 700 → **698** (669 safe, 29 open). The ceiling stays 700.

### (2) Misreadings fixed as classes, with shared cases on both sides
| Class | Before | After |
|---|---|---|
| "from your account *1234 to your account *5678" (and the Arabic `من حسابك … إلى حسابك …`) | completed debit transfer | `own_account_transfer`, review. Rule: a source-of-funds phrase plus an own-destination phrase counts as both flows; it still needs two references or an own marker |
| "Get 20% cashback up to SAR 50.00 on your next purchase… Offer ends soon" (and Arabic `على مشترياتك القادمة … ينتهي العرض`) | completed payment of 20 | `no_movement_notice` / offer. `offerMarkers` += next purchase, offer ends, offer valid, limited time, `مشترياتك القادمة`, `عملية الشراء القادمة`, `ينتهي العرض` |
| "POS purchase SAR 45.00 at Salary Store. Credited points 45" | **income**; merchant "Salary Store. Credited points 45" | payment; merchant "Salary Store". A merchant ends at its sentence (`cutAtSentenceEnd`; "Test Co. Ltd" kept through the abbreviation list). A loyalty-points sentence is a footer (new `rewardMarkers`; deliberately not bare `نقاط`, because `نقاط البيع` means point of sale and the table caught it) |

- **Tests:**
  - `message_meaning_test.dart`: 4 new notice cases, 1 own-account case, and a points/merchant test.
  - `message_meaning_test.ts`: 4 notice cases, 2 own-account cases (English and Arabic), and a points/merchant test.
  - The drift test covers the two new lists.
- **"Before":** I ran the same texts through the device probe (`h/one4.dart`) and the server probe (`h/one.ts`) on the pre-follow-up state in this session. Results:
  - Q232 undetermined;
  - the own-account text a completed transfer;
  - the offer a completed payment of 20;
  - Salary Store income with the run-on merchant.

  All the new assertions fail on those outputs. I did not re-run them as a test file against a saved copy.

### (3) `legacy_capture_drain.dart` — DONE
- `handoff.complete(reviewReason:)` now passes `result.addTransactionResult.reviewReason` when the AI failure is not temporary.
- Test added to `legacy_capture_drain_test.dart`: "a message the parser holds keeps its meaning reason". An ATM cash deposit drained on device → no transaction; the Smart Inbox row carries `cash_deposit`.
- **Before** (the line reverted to `null`): fails, `Expected: 'cash_deposit'`, `Actual: <null>`. **After:** passes.

### Final-state results
- `flutter test --no-pub -j 2`, covering:
  - `test/engine/parser/`, `test/engine/ai/`, `test/domain/capture/`, `test/domain/usecases/`;
  - `capture_sync_service_test`, `capture_import_service_test`, `legacy_capture_drain_test`, `legacy_capture_drain_policy_test`;
  - the 20 `AddTransactionUseCase` test files.

  Result: **3,913 passed, 0 failed.** Both table suites are included: `declined_state_cues_table_test` and `declined_cases_totals_test`.
- `deno test --allow-all --no-lock _shared/ process-ios-sms/ parse-sms/ sync-captures/`: **823 passed, 0 failed.** This includes `parse_test.ts` "declined table" and the ai specialist's `ai_meaning_gate_test.ts`.
- `deno lint process-ios-sms/`: clean. `deno check index.ts`: clean. `flutter analyze` on touched files: clean. `deno.lock` unchanged.
- **Harness v7** (final state; development, tuned-on, synthetic; HEAD → now):

  | Leg | Wrong | Silent |
  |---|---|---|
  | dB | 65 → 5 | 0 → 0 |
  | dN | 50 → 5 | 3 → 2 |
  | s | 58 → 12 | 30 → 14 |
  | eB | 66 → 10 | 0 → 0 |
  | eN | 58 → 10 | 0 → 0 |

  - **No newly wrong and no newly silent completed message on any leg.** The categories present are only fixed, ok→review, review→ok, silent→ok/review, and notice moves.
  - ok→review is the same set as v6: cash deposits, two-movement messages, Q057, Q134.
  - Notice REV→SIL: on the server 35 notices are now rejected with no AI (their truth is "not a movement"). On the device end-to-end legs Q11, a "Special offer" advert, is now dropped by the advert filter together with Q15 and Q16, as designed for promotions.

## Follow-up 2 (strict gate on `7cab5e8b`: four failures in `app/test/engine`)

Nothing committed. All four were caused by parser changes in this round. Verdict per test:

| Test | Verdict | What changed |
|---|---|---|
| (a) `direction_signal_test.dart` "both families present → unknown (not decisive)" | **Regression, fixed in code** | A reward line such as "credited to your … points" counted as a credit flow, so a debit with a points footer read as "both families". `_firstMoneyFlow` (Dart `direction_signal.dart`, TS `message_meaning.ts`) now skips a flow phrase that is followed by points / miles / نقاط / نقطة. It does not skip نقاط البيع (point of sale). `hasDebitFlow`, `hasCreditFlow` and `flowOf` all use it. The `detect` meaning is otherwise unchanged. |
| (b) `parser_quality_golden_test.dart` "sa_anb_atm_deposit_income" | **Decided change (owner brief §5: an ATM cash deposit is not proven income → review)** | The fixture is now `ExpectedSmsStatus.review` (new enum value). The golden test checks a review row: not a transaction, amount detected. This is the same decision as round9 PR-01 in the main report. |
| (c) `parser_quality_golden_test.dart` negative corpus "promo_with_currency is ignored" | **Regression, fixed in code** | An advert sentence with an ignore word sat next to an event sentence that names no movement, and it was treated as a footer and removed. The core then looked like a transaction. Now an ignore-word text sentence counts as a footer only when an event sentence names a movement (`_namesMovement`, mirrored as `namesMovement` in TS). **The negative corpus is unchanged.** |
| (d) `ai_cascade_test.dart` "ATM cash deposit (withdrawal-typed + إيداع wording) becomes a transfer" | **Decided change (owner brief §5, and the ai meaning gate)** | The test is renamed "… is held for review". It expects nothing saved, outcome notTransaction, droppedByParser true and reviewReason `cash_deposit`. |

How the "before" was confirmed: (a), (b), (c) and (d) failed on the gate run at `7cab5e8b`. The new Deno test "flowOf skips points/miles" in `message_meaning_test.ts` fails against the `7cab5e8b` copy of `supabase/functions` and passes now. The Arabic promo case in `message_meaning_test.dart`/`.ts` ("عرض خاص! وفر SAR 50 …") pins (c) on both sides.

Who calls `DirectionSignal.detect`, all checked:
- `features/common/transaction_direction.dart` (transfer display)
- `add_transaction_usecase._directionFromText`
- `ai_candidate_validator.bookedDirection`

None of them depended on points text counting as a flow. One note for the ai owner: the TS AI validator has its own copy of the flow list, and that copy does not yet skip points. It is outside my files and I did not edit it.

Results after the change:
- **Gate.** `flutter test --no-pub -j 2 test/engine/` plus every test outside it that imports `engine/parser` (36 files): **4,399 passed, 1 "failure".** The one failure is `test/domain/local_v2_support.dart`. It is a helper library with no `main` that my import grep picked up, so it fails to load as a test. It is not a real test failure. All four target tests pass.
- `flutter analyze --no-pub lib/engine/parser test/engine`: clean.
- Deno (`_shared/ process-ios-sms/ parse-sms/ sync-captures/`): **823 passed**. Lint clean. `deno.lock` unchanged.
- Both declined tables: no pin changes (698 deviations, ceiling 700).
- **Harness v8** (development, tuned-on, synthetic): the same as v7 on every leg (wrong dB 5, dN 5, s 12, eB 10, eN 10). No message became newly wrong or newly silent.
