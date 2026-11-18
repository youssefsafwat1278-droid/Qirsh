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

## Follow-up 3 (independent review S of `7577f347`: REJECT), 2026-11-18

Nothing committed. Model: Opus 5.5 (`claude-opus-5-5`). Every number below is synthetic and tuned-on development data, not real-world accuracy.

### Differential harness (`tools/parser_diff/`), built before the code changes

Re-run: `PARSER_DIFF_SCRATCH=<empty dir> PUB_CACHE=$HOME/.pub-cache tools/parser_diff/run.sh [BASE=5dae2e2d] [WORK=working-tree|<commit>]` (needs `flutter pub get` done in `app/`).

- It extracts BASE with `git archive` and runs the same messages through both versions, on five paths: dB (device, bank sender), dN (device, no sender), s (server `parseSms` with the `index.ts` meaning downgrade, on the redacted text), eB and eN (effective iOS import: server row, then the device's import decision).
- Inputs: every case file in `tools/parser_diff/cases/` (2,345 distinct texts, including the reviewer's 29 reproductions in `review_s.json` and my 59 class probes in `fu3.json`, each hand-labelled) plus the live shared table `declined_cases.json`.
- `report.txt` lists every message whose outcome moved, with direction and amount, grouped by class. The exit status is 1 on any regression (labelled right at BASE → wrong or silent), any throw, or any text BASE read as not completed that is now recorded.
- `diff.py freeze` wrote `process-ios-sms/pre_round_not_completed.json`: the 265 texts `5dae2e2d` read as not completed. That file is the fixture for the SM-01 invariant tests on both sides.

### Result: `5dae2e2d` → working tree (run pd5)

**0 regressions, 0 throws, 0 base-not-completed texts now recorded.** For comparison, HEAD (`98e8e56d`) had 140 regressed path-moves on 38 messages, plus 8 throws.

| Path | wrong | silent | review | right | throw |
|---|---|---|---|---|---|
| dB | 82 → 7 | 1 → 0 | 482 → 395 | 998 → 1,161 | 0 → 0 |
| dN | 61 → 6 | 4 → 2 | 702 → 712 | 796 → 843 | 0 → 0 |
| s | 77 → 15 | 23 → 9 | 566 → 518 | 897 → 1,021 | 0 → 0 |
| eB | 90 → 13 | 0 → 0 | 441 → 336 | 1,032 → 1,214 | 0 → 0 |
| eN | 80 → 13 | 0 → 0 | 552 → 503 | 931 → 1,047 | 0 → 0 |

Every remaining wrong or silent outcome is wrong or silent at `5dae2e2d` too. They are listed under "Not fixed" below.

### Moved messages by class (path-moves / messages)

| Class | Move | Path-moves | Messages | Note |
|---|---|---|---|---|
| right → review | record IN → review | 72 | 15 | Cash deposits (owner §5) and a fixed deposit |
| right → review | record OUT → review | 4 | 2 | Q057, Q134 (no currency in the text) |
| wrong/silent → review | record IN / OUT → review, ignored → review | 60 | 22 | Safer outcomes |
| fixed (wrong → right) | record → no-movement | 147 | 42 | Bill due, expected, scheduled, adverts ("earn points on every SAR x") |
| fixed | record IN ↔ OUT, wrong amount → right | 110 | 33 | «إليك»/«منك إلى», points or miles, "charged as SAR" |
| fixed | other → right | 36 | 16 | Includes ignored → recorded completed purchases |
| review → right | review → record OUT / IN | 415 | 200 | "charged"/"deducted" formats, notice tails, side events |
| unlabelled | server ignored → not-completed | 154 | 154 | Same rejection; the reason is now named |
| unlabelled | record IN → review | 70 | 14 | ATM deposit golden layouts G014/K014 (owner §5, decided) |
| unlabelled | review → record OUT / IN | 67 | 62 | Correct transfers and payments (e.g. K_N23, K097 on the server, K098 IN 750 EGP) |
| unlabelled | other | 5 | 5 | K250/K_N05 server ignored → review (SM-01 invariant); A117/A146 eN record → review (tip totals, the validator's call) |
| same grade | review → no-movement, ignored → not-completed, dropped → review, … | 392 | 180 | Same grade, more exact outcome |

### Fixes by finding (device AND server, each with shared cases)

- **SM-01: a status sentence is never a footer.**
  - Rule: a sentence with a status cue (declined, failed, pending, reversed, …) is never set aside as a footer.
  - When the whole message reads as not completed but the core does not, or when the only completed core is next to another event's status sentence ("Previous attempt declined"), the meaning is the new kind `uncertain`. The reasons are `status_disputed` and `other_event_status`, the disposition is review, and the message is never recorded.
  - On the server, a declined text is still rejected before any AI request, as before.
  - The invariant is tested on both sides over the 265 frozen texts: never recorded on device (with and without a sender), never recorded on the server, and never accepted from an AI answer (the AI is not reached, or the meaning is not "record").
- **SM-03: points and miles.**
  - `DirectionSignal.isRewardFlow` (Dart) and `isRewardFlow` (TS, `_shared/money_text.ts`) skip a credit-flow phrase that moves a reward unit: points, miles, نقاط, نقطة, أميال. A count before the unit is allowed ("45 points credited"), and so is a unit in the flow's own clause.
  - `detect` falls back to word families with reward flows removed.
  - The server now records the correct debit (SM03a–e, P01–P04).
- **SM-02: no entry point throws.**
  - `_decimalOrNull` guards `_extractChargedPair` and the international-parens parse.
  - A fuzz test covers 8 leads × 10 tails (commas after numbers, dates, card suffixes, Arabic-Indic digits, `٫`/`٬`), each truncated every 7 characters. It calls the following entry points:
    - `parse` (with and without a sender), `isIgnoredMessage`, `isNoticeMessage`, `meaningOf`, `clauseScope`
    - `DirectionSignal.detect`/`flowOf`, `TransactionStateCues.isNotCompleted`
    - `meaningHoldReason`, `localParseContradictsServer`
    - `AiCandidateValidator.bookedDirection`/`chargedTotal`
    - on the server, `parseSms`, `messageMeaning`, `isDeclinedText`, `deterministicParse`, `flowOf` and `clauseScope`
  - The reviewer's concern about lists: `transactionIsDebit` calls `DirectionSignal.detect(rawMessage)` for stored transfer rows. `detect` reaches `_extractChargedPair` only through the parser's amount extraction, which is now guarded, and the fuzz test runs `detect` itself on every shape.
- **SM-04: a completed movement with a notice tail is never `no_movement`.**
  - `_noMovementReason` returns null when any figure clause states a movement. It also strips notice openers first ("Please note", «يرجى العلم»).
  - `withoutNoticeTails` removes offer, due, future and summary clauses that carry no figure, before ignore-word and type checks.
  - The server no longer drops these (SM04a/c/d, S01–S08).
- **SM-05/06: side figures.**
  - A cashback or reward line, or a line about another operation ("Previous purchase SAR 80.00 at …"), is a side event: a footer next to the transaction's own sentence.
  - Distinct amounts are counted over the core events only.
  - Two real purchases stay `multiple_events` (review).
  - Percentages are masked in role reading. This also fixes the «عرض خاص! خصم 50%» advert that was recorded at `5dae2e2d`.
  - "Total bal": not a parser issue on device or server meaning. The remaining eB/eN review on SM05a comes from the `chargedTotal` currency slot `[a-z]{3}` matching "bal" in `ai_candidate_validator`/`validated_capture`. Those files are not mine; see below.
- **Held-out classes.**
  - Arabic or English debit plus salary in one message → review (H01, H02).
  - «تم تحويل … إليك من» → incoming, «منك إلى» → outgoing (H04–H06, H21).
  - Pending-refund notices → not booked (H07–H10).
  - "earn points on every SAR x", "على كل" and "cashback up to" adverts → no movement (S12, S14, H11–H14).
  - A truncated status ("… was decl", "was rej", "is pen") → `uncertain/truncated_status`, review (H15–H17).
  - "USD x … charged as SAR y" → the SAR amount (H18–H20).
- **SM-09: bounded input, no super-linear time.**
  - `ParserEngine.bounded` and TS `bounded` keep a text of 2,000 characters or less unchanged. A longer text is read as its first and last 1,000 characters on separate lines, so a status at either end still decides it. K_N55, whose status comes after 4,000 characters of filler, is still not completed.
  - Every entry point bounds its input.
  - The sentence splitter looks back only 12 characters for an abbreviation, and the quadratic `_beforeFieldLine` was replaced by a linear `aboveField` pass.
  - Timing test on both sides: five adversarial inputs of 10,000–20,000 characters must each finish in under 1.5 s. At HEAD, the device took 24,465 ms on 20,000 characters of "Avl. Bal." and the server took 4,756 ms.
- **SM-07: device/server parity.**
  - Over 2,345 texts, **meaning disposition differs in 1 text**: T79 "Transaction unauthorised: SAR 100.00 at CAFE ONE". The device says undetermined, the server not_completed, and both end with nothing recorded.
  - Kind or reason differs in 158 texts, all with the same disposition. The cause is systematic: the two sides read a sentence's role (event or figure) with different amount extractors. The device needs a "strong transaction" amount; the server takes any captured amount. Each misses some events the other finds, for example «تم خصم 45 ريال رسوم خدمة» (device) and "Paid 45.00 at Test Cafe" (server, no currency).
  - **I did not unify the extractors in this round.** The change touches every message, and no money outcome depends on it today (the dispositions agree). It is a recommended next step, with the harness as the guard.
  - The server-redaction sentence merge (SM07a/K015) is outside my files.
- **SM-08: allowlist.**
  - The ceiling now equals the count: **703** (Dart `_maxDeviations`, TS `MAX_DEVIATIONS`).
  - Five completed rows moved to review on both sides, because `5dae2e2d` read them not completed:
    - "Previous attempt declined" ×2
    - "Previous attempt did not go through"
    - "Your earlier payment did not go through"
    - "Your dispute … is under review"
  - "Daily limit SAR 5,000; pending SAR 0.00" moved to review on both sides as well.
  - K_N55 is back to not completed through the head-and-tail bound.
  - Three rows improved: A114 and "SAR 45.00 paid at Test Mart; cashback SAR 2 credited" are now recorded debits, and the server no longer accepts a grounded AI answer for one advert.

### Tests: "fails before, passes after"

- New tests:
  - `app/test/engine/parser/follow_up3_money_correctness_test.dart` and `supabase/functions/process-ios-sms/follow_up3_money_correctness_test.ts`.
  - The shared fixture `process-ios-sms/follow_up3_cases.json`: 88 labelled rows. Pins state why each one deviates: decided, safe deviation as at `5dae2e2d`, or OPEN defect, labelled characterization.
  - The invariant fixture `pre_round_not_completed.json`.
- How "before" was confirmed: the test files and fixtures were copied into a `git archive` of HEAD `98e8e56d`.
  - Dart: run as `flutter test` in that copy, **59 failures**, including the fuzz test (`MoneyInputException` on "SAR 50.00 deducted from your card *4521, Jarir, …") and timing (24,465 ms).
  - TS: **52 failures**, including timing (4,756 ms) and the invariant test. The TS fuzz test passes at HEAD; the server did not throw, as the reviewer found.
  - Both pass on the working tree.

### Changed expectations (decided, listed)

- `message_meaning_test.dart`/`.ts`:
  - "Purchase … approved. Previous attempt declined." is now review (`uncertain/other_event_status`), not a recorded purchase. This is the SM-01 invariant: `5dae2e2d` read it not completed.
  - "SAR 45.00 paid at Test Mart; cashback SAR 2 credited" is now a recorded debit (SM-06). The two-movement review example is now two purchases.
- `ai_meaning_gate_test.ts` and `parse-sms/ai_meaning_gate_contract_test.ts`: the `multiple_amounts` fixture is now a true two-purchase message. The cashback message is now asserted as a record (SM-06). The assertions themselves are unchanged.
- `direction_signal_test.dart`: "both families → unknown" now uses «شراء واسترداد مبلغ». A new case asserts that «شراء …، تم إيداع نقاط المكافآت» is a debit (SM-03).
- `transaction_state_cues_drift_test.dart`: covers the three new lists (`otherEventNouns`, `noticeOpeners`, `movementLeads`).
- `declined_cases.json` and the deviations file are re-pinned as described under SM-08.

### Not fixed (each wrong or silent at `5dae2e2d` too)

- M02: two purchases in one sentence are recorded as the first.
- H03: the server records the debit of a «خصم … وإيداع راتب» sentence.
- MA29, MA31, Q072, Q078, MD12: direction from a deposit noun.
- Server FX amounts A006–A008 and A060.
- Q035, Q060, Q196, Q13, Q17, Q30, Q38, Q142, Q207, R09.
- Server silents CU_W*, R10–R14, A10, A11, G10, LX_M14.
- Device review where the reviewer expects a record: X01, X05, SM02b, SM04b, SM05a, P02. These are safe, not recorded.

### Out of my files (for the coordinator / AI owner)

1. `_shared/ai_candidate_validator.ts` keeps its own `POINTS_AFTER` copy. It should call `isRewardFlow` from `_shared/money_text.ts` so the AI validator and the parser agree on points and miles.
2. `chargedTotal` (Dart `ai_candidate_validator.dart`, TS `ai_candidate_validator.ts`) has the currency slot `[a-z]{3}`, which matches "bal" in "Total bal 12,345.00" (SM-05). It needs the currency table.
3. `_shared/sms_redaction.ts` `redactThirdPartyNames` consumes text through a period, which merges sentences (SM-07, K015/SM07a).

### Commands and results (final state)

- Harness pd5 (`run.sh 5dae2e2d`): exit 0. Regressions, throws and base-not-completed-now-recorded are all 0.
- Deno, whole `supabase/functions`: **1,160 passed, 0 failed** (6 ignored). Lint is clean on `process-ios-sms/`, `parse-sms/`, `_shared/money_text.ts` and `tools/parser_diff/server.ts`. `deno check` is clean. `deno.lock` is unchanged.
- `flutter analyze --no-pub lib/engine/parser` plus the touched tests: no issues.
- Flutter: `flutter test --no-pub -j 2 test/engine/` plus 138 more files: every test outside `test/engine` that imports `engine/parser`, `test/domain/capture`, `test/features/capture`, `capture_commit*` and every test importing the capture import/sync services or `validated_capture`. Result: **6,253 passed, 0 failed.**
