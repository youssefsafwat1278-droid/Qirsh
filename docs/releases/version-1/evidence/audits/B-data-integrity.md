# Data integrity and financial correctness audit — Qirsh V1
Model: claude-opus-5-5 (Claude Opus 5.5)
Date: 2026-11-17 · Commit: ab5dc10a · Reviewer: Data integrity / financial correctness specialist (AI agent)

## 1. Scope covered / not covered

Covered (code inspection plus targeted runs):
- Canonical financial semantics (`app/lib/domain/finance/financial_semantics.dart`), exact money (`amount_minor` int64) vs REAL shadow, currency mixing guards on dashboard/budgets/plans.
- On-device parser (`app/lib/engine/parser/parser_engine.dart`, `local_validity.dart`) and the capture commit path (`app/lib/domain/usecases/add_transaction_usecase.dart`): declined/failed messages, Arabic digits, separators, currency position, year-less dates, missing currency.
- AI candidate grounding on device (`app/lib/engine/ai/ai_candidate_validator.dart`, `grounding_check.dart`) and server (`supabase/functions/_shared/ai_candidate_validator.ts`, `parse-sms`, `process-ios-sms`).
- Duplicate handling (device `findSuspiciousDuplicate` / same-text window; server `capture_fingerprints`).
- Category provenance (migration `20261117000000_transaction_category_source.sql`, pull/import/restore client side).
- Drift migration pipeline (`app/lib/data/db/app_database.dart` `_runInitialize`) and its tests.
- Backup restore (`app/lib/core/backup/restore_backup_usecase.dart`, `restore_controller.dart`), Qirsh package import (`app/lib/core/data_portability/`).
- Sync conflict recording/resolution (`app/lib/core/sync/*`, `ledger_sync_service.dart` pull apply) and the known `conflict_fields.dart` timezone issue.

Not covered / only skimmed: report PDF rendering, gamification, goals math, bill/subscription schedule math, admin catalog rules actually deployed in production (`sms_parsers`), server-side summary RPCs, Android native receiver code (cannot build here).

## 2. What is established (verified behavior, with evidence)

- One canonical spend contract: net expense = payment + withdrawal − refund; income = income; transfer/unknown excluded; only `confirmed` counts (`app/lib/domain/finance/financial_semantics.dart:7-17,124-155`). Repository aggregates use the exact `amount_minor` fragments (`financial_semantics.dart:196-208`). Unknown/future type is excluded, never silently expense (`:131-132`).
- Money is exact minor units; `Money.sum` throws on mixed currencies (`app/lib/domain/finance/money.dart:82-87`); dashboard/budget/subscription totals filter to the display currency before summing (`app/lib/features/dashboard/dashboard_providers.dart:468-474,585-596,697-700`). Accounts screen groups totals by currency, never sums across (`app/lib/features/accounts/accounts_screen.dart:174-195`).
- Date windows are half-open and built from LOCAL month/day boundaries converted to UTC (`dashboard_providers.dart:365,381`; `drift_transaction_repository.dart:875,986`; `drift_plan_repository.dart:238-244`).
- Arabic-Indic digits, Arabic thousands/decimal separators and currency before/after the amount parse correctly (probe below: `١٬٢٣٤٫٥٠ ريال` → 1234.50 SAR; `SAR 1,234.50` and `1,234.50 SAR` → 1234.50). A European `EUR 1.234,50` is not silently mis-confirmed: it reads 1.234 EUR, which fails exact-money (`nonExactMoney`) and routes to review.
- Capture money is exact: a rejected exact token becomes LEGACY_LOSSY pending review, never a rounded confirmed row (`add_transaction_usecase.dart:222-239`).
- Duplicates are never silently dropped on device: exact (amount, currency, merchant, comparison instant) or same-text-within-window becomes a *suspected duplicate* for review (`add_transaction_usecase.dart:991-1060`). Server iOS path fingerprints on the exact timestamp and marks `suspicious_duplicate` for review (`supabase/functions/process-ios-sms/index.ts:335-345,583-622`; `_shared/capture_fingerprint.ts:9-15`). Two genuine identical purchases at different times stay distinct.
- Category provenance: server trigger only accepts a fresh nonce token, otherwise records `unknown` on category change; `imported_from_file` is sticky (`supabase/migrations/20261117000000_transaction_category_source.sql:38-78`). Client pull keeps provenance unless the category changed (`app/lib/features/capture/services/ledger_sync_service.dart:586-596,620-625`); importer resets to `unknown` when the category changes (`drift_financial_importer.dart:465-466`); backup carries `category_source` (`backup_snapshot_builder.dart:94-98`). Ran `flutter test --no-pub test/core/backup/category_provenance_restore_test.dart` → `+5: All tests passed!`.
- Migrations: the whole upgrade (schema, versioned steps, repairs, backfills, postflight integrity, `user_version` bump) runs in ONE transaction; a newer-than-app DB fails closed (`app_database.dart:676-733`). Ran `flutter test --no-pub test/data/db/category_provenance_v43_migration_test.dart` → `+2: All tests passed!` (v42→v43 and crash-replay).
- Restore validates the whole payload before any destructive step, rejects newer backup formats, runs inside one transaction with in-transaction verification against the plan, and resets consent OFF inside the transaction (`restore_backup_usecase.dart:102-140,200-265`).
- Pull never overwrites a row with a pending local edit: if the server moved, it records a durable conflict; otherwise it skips (`ledger_sync_service.dart:485-532`). Each pulled row applies inside a DB transaction (`:775`). Keep-cloud for every interactive entity fetches and applies the current server row atomically, or changes nothing (`conflict_resolver.dart:308-355`; registrations `app/lib/core/di/app_providers.dart:1205-1222` cover all 8 interactive entities).
- Known timezone issue (`conflict_fields.dart`): see DATA-07. Ran `TZ=Asia/Riyadh flutter test --no-pub test/core/sync/sync_conflict_store_test.dart` → `+9: All tests passed!` (the test was rewritten to use explicit offsets; it no longer fails outside UTC).

## 3. Findings

### DATA-01 — Declined/failed card transactions are recorded and auto-confirmed as spending
- Severity: S1 · Class: REPRODUCED · Platforms: Android (on-device parse), iOS (local-after-reject path and server deterministic path without AI); Backend
- User impact: A bank SMS saying a purchase was declined / failed / unsuccessful is saved as a confirmed `payment`, counted in monthly spend, budgets, category totals and reports. Money the user never spent is reported as spent. Banks commonly send declined notices (insufficient balance, limit reached), often several retries in a row, so one event can inflate spend multiple times.
- Evidence:
  - Parser ignore list has OTP/promo/marketing terms but no declined/failed/rejected/`رفض`/`مرفوضة`/`فشل`/`غير ناجحة` terms (`app/lib/engine/parser/parser_engine.dart:1024-1075`); type detection then returns `payment` from `شراء`/`purchase` (`:310-325`). `LocalValidity.check` has no state check (`app/lib/engine/parser/local_validity.dart:40-93`).
  - The only declined-state logic is in the Proof engine (`app/lib/engine/proof/evidence.dart:258-262`, `proof_checker.dart:232-272`), which runs in shadow mode: `enable_proof_autocommit` defaults false (`app/lib/data/catalog/feature_flag_service.dart:74`) and is hard-blocked from being armed server-side (`supabase/migrations/0101_feature_flag_admin_audit.sql:311-315`).
  - Server iOS deterministic parser: `ignoreKeywords` likewise lacks declined terms (`supabase/functions/process-ios-sms/parser_rules.json`, key `ignoreKeywords`); `deterministicParse` accepts any amount+currency+direction (`process-ios-sms/parse.ts:97-100,213-260`). Only the AI path is asked about "completed" transactions (`parse.ts:270`).
  - Parser probe (synthetic messages, `dart --packages=.dart_tool/package_config.json <scratch>/probe.dart`, sender `AlRajhi`): `تم رفض عملية شراء بمبلغ 250.00 ريال…` → `isTx=true type=payment conf=1.00 valid=true`; `Purchase declined: SAR 250.00…` → same; `Transaction failed. Purchase of SAR 99.00…` → `conf=1.00 valid=true`; `عملية غير ناجحة: شراء بمبلغ 75.00 ريال…` → `conf=0.95 valid=true`.
  - End-to-end probe through the real `AddTransactionUseCase` on an in-memory Drift DB (default flags: V2 off, proof shadow, on-device only; scratch file `declined_probe_test.dart`, run with `flutter test --no-pub <scratch>/declined_probe_test.dart`): two declined messages at a known merchant → `saved=TransactionStatus.confirmed type=payment amount=Money(250.00 SAR)` and `Money(180.00 SAR)`; `expenseTotalBetween(month, SAR)` → `Money(430.00 SAR)`.
  - No test in `app/test` covers a declined/failed transaction message (grep for `declined|مرفوض|رفض` finds only privacy/consent tests).
- Root cause: transaction state (completed vs declined/failed) is not part of the deterministic acceptance decision; it exists only in the shadow Proof engine.
- Proposed fix (smallest change): add declined/failed/unsuccessful/rejected cue phrases (English and Arabic, phrase-scoped like `direction_corroboration.dart:116-120` to avoid `رفض` false positives) to `_isIgnored` in `parser_engine.dart` and to `parser_rules.json` `ignoreKeywords`, or route such messages to `notTransaction`. Compatibility: messages already stored stay; consider a one-off review list of existing rows whose raw text matches the new cues (no automatic deletion). Admin catalog rules may also need a declined exclusion.
- Verification required after fix: unit tests for Arabic and English declined/failed/insufficient-funds samples in both the Dart parser and `process-ios-sms/parse_test.ts`; re-run the end-to-end probe (spend must stay 0); a regression set confirming normal purchases with the word `رفض` in unrelated text are not dropped.

### DATA-02 — Restore does not reconcile with cloud sync; restored data can be overwritten by, or silently diverge from, the cloud
- Severity: S2 · Class: SUSPECTED (CODE-SUPPORTED mechanism, not executed end to end) · Platforms: iOS, Android, Backend
- User impact: After restoring a backup and re-enabling cloud, (a) transactions the restore removed can come back from the cloud, (b) restored values for rows that also exist in the cloud can be overwritten by the cloud copy on the next pull (or the reverse: older backup values pushed over newer cloud values), and (c) a pending pre-restore edit in the outbox can still be pushed. The user expects "restore" to give them exactly the backup.
- Evidence: restore deletes/reinserts business tables only; `_deleteOrder` omits `ledger_sync_outbox`, `planning_sync_outbox`, `sync_conflicts` and sync cursors (`app/lib/core/backup/restore_backup_usecase.dart:62-81`). The snapshot carries no `server_id`/`sync_status`/`server_revision` (`backup_snapshot_builder.dart:66-104`), so restored rows have `server_id = NULL`, `sync_status = NULL`. The pull matches such a row by `client_request_id = id` (`ledger_sync_service.dart:875-886`) and, because it is not `pending`/`conflict`, overwrites it with server fields (`:540-640`). The backfill pushes every `server_id IS NULL` row (`transactions_backfill_service.dart:155,184`) using the same id as `client_request_id` (server identity column, `supabase/migrations/0107_sync_cas_rpcs.sql:80`). No restore code touches sync state (`restore_controller.dart`, `restore_service.dart`: no sync/cursor references). Contrast: the file importer deliberately enqueues delete/update intents in the same transaction (`drift_financial_importer.dart:31-36,59-70`). No test combines restore with a subsequent pull/push (all restore tests in `app/test/core/backup/` are local-only).
- Root cause: restore is designed as a local-only replace; cloud convergence after restore is undefined.
- Proposed fix: owner decision on semantics (restore = replace cloud too, or restore = local only and block/warn when cloud has data). Smallest safe step: clear the two outboxes inside the restore transaction and either enqueue intents like the importer does, or reset sync cursors and require an explicit "replace cloud with this backup" choice before cloud is re-enabled.
- Verification required after fix: integration test: cloud has rows A,B (B edited later); backup has A(old),C; restore; re-enable cloud; assert final local and cloud state matches the chosen semantics.

### DATA-03 — AI-only amount grounding on device is a substring match (card digits / balance fragments pass)
- Severity: S3 · Class: REPRODUCED (validator behavior) · Platforms: iOS, Android
- User impact: When the local parser cannot read a message and the device AI fallback (non-primary mode) answers, an AI misread amount that is merely a substring of another number in the SMS (card number, balance, date) is accepted and auto-confirmed (validated AI bypasses confidence gates, `add_transaction_usecase.dart:1249-1254`).
- Evidence: `GroundingCheck.verify` uses `sanitizedText.contains(candidate)` on `toStringAsFixed(0..3)` forms (`app/lib/engine/ai/grounding_check.dart:1-28`). Probe (`dart … g.dart`) on `Purchase of SAR 47.50 … card ending 1234 balance SAR 8,120.00`: `12.0 grounded=true`, `23.0 grounded=true`, `120.0 grounded=true`. The server validator instead requires `amount_text` to be a whole numeric token and to agree with `amount` (`supabase/functions/_shared/ai_candidate_validator.ts:192-194,289-293`), but `parse-sms` only runs it in AI-primary mode (`parse-sms/index.ts:455-462`); the non-primary response is normalized (`amount = Number(amount_text)`, `parse-sms/money.ts:51-60`) but not grounded.
- Proposed fix: port the server's whole-token rule (`amountTokens(text).includes(amountText)`) to the Dart validator and check `amountText` (the committed value), not the double.
- Verification required after fix: unit tests with card-number and balance substrings rejected; existing grounding tests still pass.

### DATA-04 — Year-less SMS dates take the current year at processing time, so late-processed messages can be dated up to a year in the future
- Severity: S3 · Class: REPRODUCED (parser) / CODE-SUPPORTED (commit path) · Platforms: iOS, Android
- User impact: A message dated `31/12 23:50` processed after New Year (delayed delivery, manual paste/share of an older SMS, queued Shortcut capture) is stored as 31 December of the NEW year; it disappears from the month it belongs to and appears in a future month's totals/budgets.
- Evidence: `_dateDmNoYear` uses `DateTime.now().year` (`parser_engine.dart:56-60,969-982`). Probe today (2026-11-17): `…on 31/12 23:50` → `occurredAt=2026-12-31 23:50` (44 days in the future). The commit path does not clamp future dates (`add_transaction_usecase.dart:950-961,2231-2241` only handles the bare-date same-day case). The server path has a `trustedSmsTimestamp` guard; the device path has none.
- Proposed fix: infer the year relative to `smsReceivedAt` (choose the year that puts the date at or before receipt, within ~1 day of tolerance), and fall back to received time when the result is in the future.
- Verification required after fix: tests for Dec→Jan rollover and for a pasted message months old.

### DATA-05 — In the default (legacy) flow a message without any currency token is auto-confirmed in the account's currency
- Severity: S3 · Class: CODE-SUPPORTED (parser output REPRODUCED) · Platforms: iOS, Android
- User impact: For a multi-currency user, a bank SMS that omits the currency (or uses an unrecognized token) is confirmed in the default account's currency, so it may be counted in the wrong currency total.
- Evidence: parser falls back to `defaultCurrency` and sets `currencyDefaulted` (`parser_engine.dart:224-226,289`). Only the V2 validity check rejects it (`local_validity.dart:56-59`); `local_auto_confirm_v2` defaults OFF (`feature_flag_service.dart:121`) and the legacy gate (`add_transaction_usecase.dart:1249-1254`) never reads `currencyDefaulted`. Probe: `شراء بمبلغ 40.00 لدى متجر الاختبار` (sender AlRajhi) → `isTx=true cur=SAR conf=0.95`.
- Proposed fix: treat `currencyDefaulted` as "requires review" in the legacy gate (one condition in `canAutoConfirm`).
- Verification required after fix: unit test that a currency-less message is saved `pending`.

### DATA-06 — Account "current balance" is shown but never derived from transactions
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: iOS, Android
- User impact: Accounts list and account detail show `current_balance` as the account balance (`accounts_screen.dart:148-195,380`; `account_detail_screen.dart:254-262`). On device it is only written by cloud pull and file import (`accounts_pull_service.dart:424-425`; `drift_financial_importer.dart:335-343`); the form preserves it verbatim ("running/derived state", `account_form_sheet.dart:289-297`), but no code derives it from transactions or SMS `balance_after`. An imported/pulled balance therefore freezes and drifts from reality as spending is captured.
- Proposed fix: owner decision: either hide it, label it "as of import", or derive it (initial balance + confirmed signed flows, or latest `balance_after`).
- Verification required after fix: widget/unit test that the displayed balance changes after a confirmed capture, or that the label reflects its source.

### DATA-07 — `conflict_fields.dart` zone-less timestamp parsing (known issue): latent only, display-only
- Severity: S4 · Class: CODE-SUPPORTED · Platforms: iOS, Android
- User impact today: none observed. `diffConflictFields` only feeds the conflict list's "what differs" display (`conflict_resolver.dart:140-143`); it does not drive resolution.
- Evidence: `_norm` date branch parses zone-less values as local (`app/lib/core/sync/conflict_fields.dart:153-159`). Mine snapshots are raw local rows (`sync_conflict_store.dart:152-170`), written via `dateTimeToSql` (UTC with `Z`, `app/lib/data/db/sql_value_codec.dart:5`); ledger pull normalizes to `dateTimeToSql` (`ledger_sync_service.dart:631`); planning pull stores PostgREST `timestamptz` strings verbatim (offset-qualified, `planning_pull_service.dart:1516-1519`; columns are `timestamptz`, `supabase/migrations/0021_planning_remaining_sync.sql:15,44,77,102-103`); the importer normalizes to UTC (`drift_financial_importer.dart:974-978`). The only route for a zone-less value is a restore of a hand-made backup (`_insertRow` inserts verbatim). The memory note's failing test was rewritten with explicit offsets and passes under `TZ=Asia/Riyadh` (see §2).
- Proposed fix (optional hygiene): treat a zone-less value as UTC in `_norm` (append `Z`) to match the app's storage contract.
- Verification: a unit test with `'2026-01-01 10:00:00'` vs `'2026-01-01T10:00:00Z'` under a non-UTC TZ.

### DATA-08 — Historical schema shapes v27–v42 are not covered by real upgrade fixtures
- Severity: S3 · Class: CODE-SUPPORTED (test-gap) · Platforms: iOS, Android
- User impact: An upgrade defect from an older TestFlight schema would surface only on testers' devices. Rollback is transactional, so the failure mode is "app cannot open data" rather than corruption.
- Evidence: `test/data/db/migration_data_survival_test.dart:9-47` states shape fixtures exist only for v0/v1/v5/v26 and that v31–v42 are covered by winding `user_version` back on the CURRENT schema, "It does NOT rebuild each historical schema SHAPE". v43 was added in `3ed29278` (2026-11-16); build 147 (`b6fc0dad`) is already v43, but earlier TestFlight builds were v42 or lower.
- Proposed fix: capture a real v42 database (from a build 146-or-earlier simulator install) as a fixture and add an upgrade test with populated money.
- Verification: the fixture test passes under the full pipeline.

## 4. Coverage rows

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| Spend semantics | All | Refund nets expense; transfer/unknown excluded; only confirmed counts | financial_semantics.dart | Code inspection | PASS | §2 | — |
| Exact money | All | Totals in minor units; no cross-currency sum | money.dart, dashboard_providers.dart | Code inspection | PASS | §2 | — |
| Declined/failed SMS | Android/iOS | Declined purchase must not count as spend | parser_engine.dart, add_transaction_usecase.dart | End-to-end probe on in-memory DB | FAIL | DATA-01 | DATA-01 |
| Declined/failed SMS (server) | iOS/Backend | Deterministic path without AI | process-ios-sms/parse.ts | Code inspection | FAIL | DATA-01 | DATA-01 |
| Arabic digits / separators | All | `١٬٢٣٤٫٥٠ ريال`, `SAR 1,234.50`, `1,234.50 SAR` | parser_engine.dart | Parser probe | PASS | §2 | — |
| European decimal | All | `EUR 1.234,50` not mis-confirmed | parser + local_validity | Parser probe | PASS (routes to review) | §2 | — |
| Missing currency | All | No currency token | add_transaction_usecase.dart | Parser probe + code | FAIL (legacy flow) | DATA-05 | DATA-05 |
| Year rollover | All | `31/12` processed in a later year | parser_engine.dart | Parser probe | FAIL | DATA-04 | DATA-04 |
| AI grounding (device) | All | AI amount not a whole token | grounding_check.dart | Validator probe | FAIL | DATA-03 | DATA-03 |
| AI grounding (server primary) | Backend | amount_text whole-token + agreement | _shared/ai_candidate_validator.ts | Code inspection | PASS | §3 DATA-03 | — |
| Duplicates | All | Same message twice / two legit identical buys | add_transaction_usecase.dart, capture_fingerprint.ts | Code inspection | PASS | §2 | — |
| Category provenance | All | Survives pull/import/restore; bulk excludes user/unknown | migration 20261117000000, ledger_sync_service.dart | Code + `category_provenance_restore_test.dart` | PASS | §2 | — |
| Drift migration | All | v42→v43 and crash replay | app_database.dart | `category_provenance_v43_migration_test.dart` | PASS | §2 | — |
| Drift migration | All | Real historical shapes v27–v42 | migration tests | Code inspection | NOT TESTED | DATA-08 | DATA-08 |
| Restore | All | Malformed/newer backup rejected before mutation | restore_backup_usecase.dart | Code inspection | PASS | §2 | — |
| Restore + cloud | All | Restored data vs cloud after re-enable | restore + ledger sync | Code inspection | NOT TESTED (suspected FAIL) | DATA-02 | DATA-02 |
| Sync pull vs local edit | All | Pending edit never overwritten | ledger_sync_service.dart | Code inspection | PASS | §2 | — |
| Conflict keep-cloud | All | All interactive entities fetch+apply atomically | conflict_resolver.dart, app_providers.dart | Code inspection | PASS | §2 | — |
| Conflict diff display | All | Non-UTC timezone | conflict_fields.dart | `TZ=Asia/Riyadh` test run | PASS (latent issue) | DATA-07 | DATA-07 |
| Account balance | All | Displayed balance tracks transactions | accounts_screen.dart | Code inspection | FAIL | DATA-06 | DATA-06 |

## 5. Could not verify here (exact scenarios, what is needed)

- Whether production `sms_parsers` catalog rules or bank profiles from the server already exclude declined messages for specific banks (needs read access to the production catalog; probes used built-in profiles and no catalog rules).
- Production values of `local_auto_confirm_v2` and `ai_primary` adoption (needs read-only access to `feature_flags`); they change which gate applies in DATA-01/05.
- Android native SMS receiver delivery timing and backfill (no Java/adb here).
- Restore followed by cloud re-enable against a real Supabase project (DATA-02) — needs a test project and two devices or a scripted pull/push harness.
- Upgrade from a real v42-or-older on-disk database (DATA-08) — needs a database file from an earlier build.

## 6. Manual device test steps you recommend

1. On a device with a known bank sender, receive (or paste) a synthetic declined message, e.g. `تم رفض عملية شراء بمبلغ 250.00 ريال لدى <known merchant> بطاقة مدى 1234`. Expected after fix: no transaction (or Smart Inbox), monthly spend unchanged. Today: a confirmed 250.00 payment.
2. Repeat step 1 with English `Purchase declined … insufficient balance` and `Transaction failed …`. Same expectation.
3. Paste a synthetic message dated `31/12 23:50` (no year) after changing the device date to 2 January. Expected: dated 31 December of the previous year.
4. With cloud on, create transactions A and B, take a backup, delete A, edit B, add C; restore the backup; re-enable cloud and wait for sync. Record which of A/B/C exist locally and in the cloud and with which values; the owner decides whether that matches the intended semantics.
5. Paste a currency-less purchase message from a known bank. Expected after fix: saved as pending review, not confirmed.
6. Install build 146 (or earlier v42 build), create data across all money tables, then install the candidate; confirm all transactions, budgets, goals and plans and their totals are unchanged.
