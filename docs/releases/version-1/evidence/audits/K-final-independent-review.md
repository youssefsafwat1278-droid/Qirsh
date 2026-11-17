# K — Final independent review of the Version 1 candidate

- Reviewer model: `claude-opus-5-5` (Opus 5.5). Wrote none of the fixes, audits A–H or review I.
- HEAD reviewed: `0f90003fd39bf9a5db1b1e51cfe501c2829989d4`, branch `release-readiness/v1`, worktree `.claude/worktrees/v1-readiness`. Date 2026-11-17.
- Scope: the 20 commits `ab5dc10a..0f90003f`. The records commit `d830855e` was reviewed for its claims only. Also reviewed: the uncommitted records in the working tree (`DECISIONS-NEEDED.md`, `production-comparison.md`, `official-doc-checks.md`, `local-stack.md`, `UI-UX-REVIEW.md`).
- Method: I read the diffs and ran probes from the session scratchpad against the real code. Device side: `dart run --packages=app/.dart_tool/package_config.json` calling `ParserEngine().parse`, `TransactionStateCues.isNotCompleted`, `validateCaptureCandidate` and `GroundingCheck.verify`. Server side: `deno run` importing `process-ios-sms/parse.ts` (`isDeclinedText`, `deterministicParse`, `isResolved`). I also ran the targeted tests listed below.
- Constraints honoured: no tracked file was changed (`git status` is the same as at the start), `deno.lock` is unchanged, no simulator, device, Docker or production access was used, and no iOS build was made. This file is the only file written.
- All probe messages are synthetic. Merchants are `SHOPX`, `Shop X` and similar.

## Commands run (actual results)

| Command | Result |
|---|---|
| `flutter test --no-pub test/engine/parser/ test/engine/ai/ai_candidate_validator_test.dart test/features/capture/{capture_import_service,capture_sync_service,transactions_backfill_identity}_test.dart test/core/backup/ test/core/sync/sync_conflict_store_test.dart test/ios/ test/l10n/help_copy_truthfulness_test.dart test/features/announcements/force_update_version_range_test.dart` | **+804, All tests passed** (host TZ EET) |
| `flutter test --no-pub test/core/startup/bootstrap_remove_data_integration_test.dart --plain-name 'configured real sender bootstrap receivers'` with the 3 synthetic defines | **+10, All tests passed** (3 sender + 7 ported removal journeys) |
| Same command with `--plain-name 'nonexistent group name zzz'` | `No tests match`, **exit 79** (the gate stage fails closed if the group is renamed) |
| `flutter test --no-pub test/integration_local/restore_then_sync_local_supabase_test.dart` against the local stack `qirsh_v1_verify` (env from its `stack.env`) | **+2, All tests passed** |
| `deno test --allow-all process-ios-sms/ parse-sms/` (from `supabase/functions`) | **135 passed, 0 failed** |
| `node --test supabase/tests/{codemagic_ios_store_pipeline_contract,codemagic_app_version_contract,ci_gates_contract_node,skip_manifest_node}_test.mjs` | **39 pass, 0 fail** |
| Drift-test mutation: a scratch copy of `transaction_state_cues_drift_test.dart` pointed at scratch copies of both JSON files with `denied` removed | **2 failures** (`declinedKeywords` equality; `preview asset ignores every declined cue`). The drift test is real for the lists |
| `awk` extraction of the `ios-signed:` block at `ab5dc10a` and at HEAD, then `diff` | **IDENTICAL** (242 lines) |
| `admin/node_modules/next/dist/server/next-server.js:167` (next 14.2.35) | `if (imagesConfig.loader !== "default" \|\| imagesConfig.unoptimized) { render404 }` |
| `git diff --stat af675aec..HEAD -- supabase/` | `parse-sms/{index,money}.ts`, `_shared/ai_candidate_validator.ts` and `process-ios-sms/*` changed **after** the production comparison commit |

## A. Declined / failed / reversed transactions (V1-001)

### A1. REV-01, REV-02 and REV-04 probes at HEAD (device ↔ server)

"review" = device `isTransaction=false` (Smart Inbox, no total change). "REJECT" = server `isDeclinedText` true (rejected, no AI). The device and server cue verdicts agreed on **every one of the 98 probe inputs** (85 + 11 + 2 long).

| Probe (REV) | Device | Server | Verdict |
|---|---|---|---|
| REV-01: all 17 inputs (`…declined. If amount was deducted it will be refunded.`; `…declined. Any held amount will be reversed.`; `…not credited or debited.`; `عملية شراء مرفوضة. لاسترداد المبلغ اتصل بنا`; `Transfer … rejected. Amount credited back…`; `لم تتم العملية`, `العملية لم تكتمل`, `could not be processed`, `denied`, `not approved`, `غير مقبولة`, `ملغاة`, `cancelled`, `مرفوضه`, `رفض عملية شراء`, `عملية فاشله`) | review (all 17) | REJECT (all 17) | Fixed |
| REV-02: `at Failed Ventures`, `لدى مرفوض للتجارة`, `at Rejected Records Store`, `…can be rejected by calling us.`, `Transactions exceeding limit will be declined.`, `للاعتراض على العمليات المرفوضة` | payment 100 | payment 100 | Fixed |
| REV-02: `Report unsuccessful or unauthorized transactions to 8001234` | review (cue `false`; the parse falls below the confidence threshold, not the cue) | payment 100 | Cue fixed. The device and server paths disagree, for a reason unrelated to the cue |
| REV-04: `رُفضت …`, `مـرفوضة …`, `تم رفض … 250.00 ريال` | review | REJECT | Fixed (the server now folds tashkeel and tatweel) |
| REV-17: `GroundingCheck.verify` on `شراء 1،250.00 SAR` | 1250 → `true`, 250 → `false` | `NUMERIC_TOKEN` now includes `،` (`_shared/ai_candidate_validator.ts:157`) | Fixed on both sides |

### A2. New adversarial probes (not in `declined_cases.json`)

**False negatives: a message that did not complete is recorded as money**

| ID | Synthetic input (abridged) | Device | Server (deterministic) | Agree? |
|---|---|---|---|---|
| N31 | `Transaction Report - Purchase SAR 100.00 at SHOPX declined` (`report` is a hypothetical marker in the same clause) | **payment 100** | **payment 100** | yes |
| N32 | `Payment of SAR 100.00 to STC will be declined due to insufficient funds` | **payment 100** | **payment 100** | yes |
| N34 | `Purchase … at SHOPX was declined, need assistance? Call 8001234` (the `?` ends the sentence, so the cue is treated as a question) | **payment 100** | **payment 100** | yes |
| N35 | `تم رفض عملية شراء … لدى SHOPX، هل تحتاج مساعدة؟` | **payment 100** | **payment 100** | yes |
| N42 | `عملية شراء بمبلغ 100 ريال من متجر مرفوضة` (`من` + `متجر` + cue is read as a name) | **payment 100** | **payment 100** | yes |
| N09 | `Purchase of SAR 100.00 at SHOPX is pending.` | **payment 100** | **payment 100** | yes |
| N18 | `E-commerce purchase … blocked` | **payment 100** | **payment 100** | yes |
| N11 | `Cash withdrawal of SAR 500.00 … could not be dispensed` | **withdrawal 500** | **payment 500** | type differs |
| N12 | `تعذر صرف مبلغ 500.00 ريال من الصراف الآلي` | **withdrawal 500** | unresolved (AI decides) | no |
| N13 / N14 | `transfer … could not be sent` / `لم يتم تحويل مبلغ 300.00 ريال` | **transfer 300** | unresolved | no |
| N33 | `scheduled transfer … will be processed tomorrow` | **transfer 300** | unresolved | no |
| N16 | `سداد فاتورة بمبلغ 200.00 ريال لم ينجح` (masculine `لم ينجح`; only `لم تنجح` is listed) | review (low confidence) | **payment 200**. `validateCaptureCandidate` **accepts** the server result (`vc_probe`: `accepted=true dir=debit`), so the iOS Cloud path on a new build records 200 as spend | no |
| K6 | `Reversal of declined purchase SAR 100.00 credited` | **refund 100** | **refund 100** | yes. Spend is reduced by 100 for a purchase that was never recorded. The Arabic equivalent N37 goes to review, so the two languages behave inconsistently |

**False positives: a completed movement is diverted to review** (total-neutral until the user acts; spend is under-stated in the meantime)

N02 `…was approved, not rejected.` · N03 `…is not declined.` · N27 `…was successful. It was not declined.` · N43 `Status: Approved (not declined)` (negation markers are applied only to credit words, never to declined cues) · N05 `approved. Previous attempt declined.` · N19 `Merchant: Failed Ventures` · N20 `POS purchase SAR 100.00 FAILED VENTURES LLC` · N21 `at Café Cancelled` · N22 `via Void Coffee` · N06 `Partial reversal of SAR 40.00 for purchase … credited` · N36 / N37 (refunds of a declined purchase). Every one of these: device review, server REJECT.

**Path divergence that is not about cues** (type or direction detection; the iOS Cloud path imports the server result)

| ID | Input | Device | Server | New-client `validateCaptureCandidate` on the server result |
|---|---|---|---|---|
| N46 | `تم خصم 100.00 ريال من بطاقتك لدى SHOPX وتم استرجاعه` | refund 100 | payment 100 | **accepted** (debit) |
| N30 | `POS reversal SAR 100.00 SHOPX card *1234` | refund 100 | payment 100 (`pos` is found before `reversal`, `parse.ts:614-621`) | rejected `direction_contradiction` → local parse refund 100 |
| N29 | `Transaction reversed: SAR 100.00 at SHOPX` | review | income 100 (rule 6 needs a `purchase`/`payment`/`شراء` noun) | **accepted** (credit) |
| N25 | `Refund of SAR 30.00 for purchase SAR 100.00 at SHOPX` | review | refund 30 | — |

**Robustness:** two 4.4 KB messages (N55, N56) took ≤ 5 ms on the device and ≤ 1 ms on the server. Right-to-left marks between Arabic words (N26) and Arabic-Indic digits (N01) are handled.

### A3. Installed clients and the server's refund typing

- At `b6fc0dad` (build 147), `capture_sync_service.dart:1041,1276-1284` maps the server's `'refund'` to `TransactionTypeEntity.refund`, and `validated_capture.dart:209-211` maps `refund` to credit. Build 147 therefore handles `type: refund`. After a `process-ios-sms` deploy, new captures that the server used to type `income` (refund wording) are recorded as `refund`: they net against spend instead of adding to income. This is a behavior change for future captures only. No stored row is rewritten, and nothing in the import path re-imports rows that were already imported.
- `reversal`, `reversed`, `تم استرجاع` and `استرجاع مبلغ` are new server credit keywords (`parser_rules.json` `creditKeywords`). A message that used to be `unknown` (unresolved, then AI or local parse) can now be accepted as a credit `refund` without AI.
- Build 147 and older remain unprotected against declined messages. A server rejection makes them re-parse locally with the old parser and auto-confirm (`old capture_import_service.dart:153-159`, `forceLocalAutoConfirm: true`). The register already records this.
- New client against the old server (before the deploy): refund wording imported from the server arrives as `income` while the device's own parse says `refund`, so totals depend on the path until the deploy (S3, temporary).

### A4. Test changes in `d35fc044`, `668f4d64`, `0de54a2b`, `84f2fe41`

I read every removed line in the modified pre-existing tests (`git show --diff-filter=M`). **No assertion was weakened.**
- `d35fc044` pins `now` (meridiem, parser_engine).
- `668f4d64` adds `buildService({aiPrimary})` and new REV-03 cases.
- `0de54a2b` renames expectations and **tightens** them (`engineType`-or-not-expense becomes exactly `TransactionType.refund`; the server's `serverDirection` escape is removed and `[direction, type]` is now asserted).
- `84f2fe41` replaces a preview check that skipped tashkeel inputs with a stronger two-sided check.

### A5. Drift test and review path

- The drift test is real for the cue **lists** (mutation result above). It does **not** cover the algorithm: the regex logic in `parse.ts:131-260` and in `transaction_state_cues.dart` is mirrored by hand. Only the 127 shared cases (and, for this review, my 98 probes, which agreed on every cue verdict) guard against logic drift. It also does not cover type and direction detection (see the divergence table above).
- The review path is total-neutral and visible. On device, `parser_engine.dart:191` returns `notTransaction(amountDetected: true)`. AI is not called (`add_transaction_usecase.dart:857-858`) and AI output is rejected (`ai_candidate_validator.dart:69`). Server imports are blocked (`validated_capture.dart:245`, `capture_sync_service.dart:881-886` → `_persistBackendUnprocessableCapture`). `_SmartInboxBanner` renders on tab 0 with no flag (`transactions_screen.dart:302-305`).
- Re-delivery: `markPayloadImported` / `isPayloadImported` prevent a second import of the same payload. A re-paste is parsed again and can create a second review card, but no money moves.
- Not checked: whether confirming a review card from Smart Inbox re-runs any cue check. It is a user action.
- `parse-sms` (the server AI fallback) has **no** declined check. The invariant holds there only because its new-build consumers validate its output (`ai_candidate_validator.dart:69`). Old builds that call it are unprotected anyway.

## B. Restore then cloud sync (V1-020), `8e953d14`, `0f90003f`

- **Ownership.** `_captureSyncIdentity` (`restore_backup_usecase.dart`, added at the hunk `@@ -384`) takes identities only from rows **already on this device** (`SELECT … FROM $table WHERE server_id IS NOT NULL`), keyed by local id. A backup from another device or account can only be bound where its ids equal this device's ids. With UUID ids, that means the same entity lineage.
  - The backfill lookup filters on `.eq('user_id', uid).eq('client_request_id', localId)` (`transactions_backfill_service.dart`, `0f90003f` hunk). It cannot bind to another user's row, provided RLS and the `user_id` column hold. CODE-SUPPORTED; no two-account run was made.
  - Wrong-row binding needs a `client_request_id` collision with a local UUID. I found no writer that reuses ids across entities.
- **Tombstones.** A tombstoned cloud row is bound as `sync_status='conflict'` and is never un-deleted (backfill test "a live local row whose cloud copy is a tombstone…", and the identity test). The user sees it through the existing conflict flow. The flow's UI was not exercised.
- **Pre-restore intents.**
  - Intents are dropped only for entities that exist after the restore (`DELETE FROM ledger_sync_outbox WHERE transaction_id IN (SELECT id FROM transactions)`). Under "restore = return to the backup" semantics, edits made after the backup to restored rows are discarded. That is consistent.
  - **However**, `ledger_sync_outbox` carries `payload_json` (`app_database.dart:2708-2724`). A **create intent for a row added after the backup and never pushed** is not deleted. It will push, and the reset pull cursor brings it back: the restore "resurrects" it. That matches the MERGE default but is not tested. The tests cover only rows that were synced before the restore (R1/R2) (FR-06).
- **Cursor reset.** Every ledger and planning cursor is deleted, so the next pull re-reads the whole history. Correctness relies on "a pending local edit is never overwritten by a pull" (tested in the identity suites). The cost on a large account was not measured.
- **Guest / local-only.** "local-only (guest) restore: nothing is queued, bound or lost" passes.
- **Format.** The snapshot builder is unchanged. `restore_compatibility_test.dart` and the rest of `test/core/backup/` pass (part of the +804).
- **Owner decision.** The code comment states "PENDING OWNER DECISION — replace vs merge". `DECISIONS-NEEDED.md` (uncommitted) has **no V1-020 entry**. The confirm copy says "The backup will replace your current data on this device" (`app_en.arb:2984`), which is not true for a Cloud user: cloud rows that are absent from the backup come back. The default is non-destructive, but it is not documented where the user decides (FR-06).
- I could not make the new tests fail. The local-stack test passes, 2/2.

## C. CI and pipeline (`64e571e5`, `29cb1819`, `4fc2ecd6`, `837d0881`)

- **A red gate cannot produce a signed upload** in `ios-signed-release`. The steps run in this order: revision check (`codemagic.yaml:216-238`, `set -eu`, branch `release/*`, 40-hex SHA equal to `CM_COMMIT` and `HEAD`, clean tree) → strict gate (`:306-330`) → XCTest (`:337-347`) → signing (`:349`) → build → verify → upload. There is no `ignore_failure` anywhere in the file (grep). `submit_to_testflight: false` (`:551`).
  - The only bypass is the one already known: the SHA is self-attested by whoever starts the build (V1-051).
  - `SKIP_FLUTTER_TEST=1` produces caller-skipped, which is fatal under strict.
- **`ios-signed` is byte-identical** to `ab5dc10a` (diff above). It still has no XCTest step.
- **XCTest step** (added to `ios-unsigned-sideload` `:94` and `ios-signed-release` `:337`): it has never run on Codemagic or locally (`TEST-EVIDENCE.md` §3 has no XCTest row).
  - Any environmental failure blocks every build of both workflows: no available iPhone simulator (the step exits on purpose), `pod install` before the Flutter iOS build, or a runtime mismatch.
  - That is fail-closed, so it is safe, but it is a schedule risk for the first release build (FR-10).
  - `Runner.xcscheme:59-66` lists `RunnerTests` (194 `func test…`).
- **Synthetic-define stage** (`tools/ci_gates.sh` 4d) is honest: it runs the 5 files and the configured group, any non-zero exit is `bad`, and a renamed group fails (exit 79, shown above).
  - It ran in the af675aec strict run (`final_ci_gates_run2.summary.txt`). That run predates `837d0881`, so the 7 ported journeys have **not** run inside a strict gate. They pass alone (+10).
- **`837d0881` assertion parity.** I normalized every `expect(...)` in the original group (`:94-462`, 74 expects) and in the port (`:851-1314`, 77 expects).
  - Every original assertion has a counterpart; the differences are renames: `legacy` → `legacyDb`, and two whitespace or wrapping variants.
  - The port adds 3 session assertions (`currentSession?.user.id`, `exchanges.last`).
  - The originals still run unchanged in the bulk stage.
- **Skip-gate bypasses remain:** `testOn` / `@TestOn`, an excluded tag (`ci_gates.sh`), an early `return`, and changing `skip: !configured` to `skip: true`. Entries match on file, kind and `contextContains`, not on the condition (REV-06 residual, S3).

## D. UI changes (`23499229`, `af675aec`, `34ccc9e9`)

- **Manual add requires a category.**
  - `manual_transaction_sheet.dart:342` removes the `all_expenses` sentinel and the auto-preselect. `_save` rejects a new entry with no category (`:169-172`).
  - Income lists only `isIncome` categories. Transfer lists expense categories, and the user must now pick one. No widget test covers income or transfer (`manual_category_default_test.dart` covers payment).
  - Editing: the validation is skipped (`!_isEditing`), and `updateTransaction` falls back to a type default when `categoryId` is null (`drift_transaction_repository.dart:445`), so no category is lost.
  - Editing a row stored under `all_expenses`: the dropdown value is not among the items, so the field renders empty (`glass_dropdown_field.dart` `_selectedItem` → null; no assert, unlike `DropdownButton`). Save keeps `all_expenses` unchanged. This is a cosmetic gap (S4).
  - No financial meaning changed.
- **Theme.** `app_theme.dart:302-303` sets the label **and** hint to `textSecondary`. The two now share one style. Entered text keeps the field's own style. This is more readable, but a floating label and a hint are no longer distinguishable by color (S4). I found no screen where contrast goes down: both were raised from `textMuted`.
- **Hit areas.** The 44-pt changes in `calm_page_header`, `section_header`, `segmented_control`, `_TintedPill` and `budgets_screen` use `ConstrainedBox(minHeight: 44)` and replace the spacing gaps. They are checked by `primary_screens_tap_targets_test.dart` and `small_screen_headers_test.dart` only. Overlap between neighbors is not tested; the budgets chip `runSpacing` dropped from `s2` to `0`.
- **Consent and sign-in screens.** `email_code_sheet.dart` and `sign_in_methods_sheet.dart` gained only a close-button `tooltip`. `sms_permission_screen.dart` gained `textAlign`. No behavior changed.
- **Modified tests.** `story_screen_test` and `onboarding_motion` changed digits ١→1 (matching UX-13). `reports_details_render_test` was **narrowed** to `TabBarView` because a summary card may also show the value; that is acceptable, not a financial assertion. `txdetail_money_validation_test` changed `ensureVisible` alignment.
- **Verification level:** widget tests only. The only simulator evidence after the fixes is the four SE screenshots (`evidence/ui/after/45-48`, a "UI fix tree") and the `f6dc5076` launch/background screenshots. No simulator evidence exists for `34ccc9e9` or for any signed-in screen.

## E. iOS native (`d70ba396`)

- **Reason codes.** C617.1, CA92.1 and 1C8F.1 (Runner), 85F4.1 (both targets), and 1C8F.1, C617.1 and 85F4.1 (ShareBankMessage) (`PrivacyInfo.xcprivacy` Runner `:95,107,108,118`; Share `:39,49,60`) match `official-doc-checks.md` §a: all are "CORRECT-FOR-THIS-USE".
  - 85F4.1 is correct only narrowly. The API is compiled into release builds and displayed only in debug builds.
  - The clipboard question is COULD-NOT-CONFIRM there.
- **Collected data.** The Runner manifest declares no advertising data or purpose (only OtherFinancialInfo, EmailAddress, Name, PhoneNumber, DeviceID, CrashData, all AppFunctionality). See FR-05.
- **Scene cover.** It is installed only on `sceneDidEnterBackground` (`SceneDelegate.swift:75-80`) and removed on `sceneWillEnterForeground` / `sceneDidBecomeActive`. Unverified:
  - the inactive (app-switcher-opening) state;
  - a scene launched straight into the background;
  - the switcher snapshot itself.
  - Compile and launch → background → return were shown on a simulator at `f6dc5076` (`TEST-EVIDENCE.md:52-53`).

## F. Admin, force-update, timezone, Help

- **REV-07:** `admin/next.config.mjs` sets `images: { unoptimized: true }`. Next 14.2.35 then answers `/_next/image` with 404 before decoding (`next-server.js:167`). The two optimizer RCEs no longer apply. The other `next` advisories remain (V1-025 PARTIAL, correctly recorded).
- **REV-10:** no commit after `7597bb42` touches `app_providers.dart`, `catalog_daos.dart` or the admin form. A malformed bound still fails open. **OPEN.**
- **REV-11:** the `ff1fc292` test is unchanged. It still cannot fail on a UTC host. It passed here on an EET host. **OPEN.**
- **Help (`2f2c4707`):** `help_copy_truthfulness_test.dart` passes.

## H. Production facts against the candidate (from `production-comparison.md`, no new queries)

- **Profile photo left behind.**
  - Deletion flow: `delete-account-immediate` drives the job inline (`handler.ts:176-180`) and **swallows** errors ("the job is durable and will be resumed"). The cron worker then resumes it through `processNext` (`account-deletion-worker/handler.ts`).
  - Both functions use `account_deletion_runtime` / `account_deletion_adapter.ts:375` → `eraseBackupObjects`. In the candidate it iterates `ERASURE_BUCKETS = ['backups','profile-photos']` (`_shared/storage_erasure.ts:48`). The deployed worker v5 predates `9e19c3e4`, which added `profile-photos`.
  - Consequence: every deletion whose storage step the **worker** runs (the inline run failed, timed out or scheduled a retry) leaves the profile photo in the bucket. The cron runs every 5 minutes.
  - `purge-scheduled-deletions` (redeployed) handles a separate queue (`account_purge_queue`) and does not sweep the worker's jobs.
  - **FR-04.**
- **Ads.** A banner needs all of the following (`banner_ads_providers.dart:131-154`):
  - the placement flag on;
  - `CloudEgressGate.permits()`;
  - `AdMobBuildConfig.isBannerConfiguredFor` (a compiled `ADMOB_*` define, attached only by `ios-signed-release` and `android-release` through the `admob` group);
  - entitlement `verifiedInactive`;
  - UMP `canRequestAds()`, which typically returns true outside the EEA and UK.

  Production flags are ON. A Cloud-on user of any store build from `ios-signed-release` with the AdMob group therefore sees ads, and the manifest, policy and consent text do not cover that. Build 147 (`ios-signed`, no `admob` group) cannot show ads. **FR-05.**
- **`SECURITY DEFINER` functions executable by `anon`.** `create_profile_on_signup()` (`0005_profiles.sql:25-30`) and `feature_flag_audit_append_only()` (`0117_account_deletion_fence.sql:6056-6060`) both `RETURNS TRIGGER`. PostgreSQL refuses to call a trigger function outside a trigger, so they cannot be invoked through `/rpc`. Revoke the grants for hygiene (S4, FR-09).
- **Smallest deployment set at HEAD:** functions only, no migration.
  - `process-ios-sms` (V1-001 and refund typing; compatible with build 147, see A3).
  - `account-deletion-worker` (FR-04; same shared code as the already-deployed `delete-account-immediate`).
  - `parse-sms` (**changed after the comparison**: `groundedModelAmount` drops an ungrounded AI amount and falls back to the text amount; the response shape is unchanged, so it is compatible).
  - The comparison's "22 identical" includes `parse-sms` and is **stale for HEAD** (FR-07).
  - The four `_shared/apns.ts` functions: equivalence is unproven, so deploy them only if needed.
  - None of these changes a response field that installed clients parse. `type: 'refund'` is already understood by 147.
  - Separately, any production flag change (ads OFF) is an owner action.

## Findings

### FR-01 — S2 — V1-001 residual false negatives: messages that did not complete still change totals on device and server
- Class: REPRODUCED (probes N09, N11–N14, N16, N18, N31–N35, N42, K6 in §A2). The likelihood in real bank templates is unknown (SUSPECTED).
- Wrong: three mechanisms.
  - The hypothetical marker `report` and the question rule suppress real statuses: "Transaction Report - …declined", and "…declined, need assistance? Call".
  - A future decline ("will be declined due to insufficient funds") is recorded as a payment.
  - Wordings are missing: `pending`, `blocked`, `could not be dispensed/sent`, `تعذر صرف`, `لم يتم تحويل`, masculine `لم ينجح`. Also a "Reversal of declined purchase … credited" is a refund that nets 100 off spend, while the Arabic equivalent goes to review.
  - Device and server agree on the cue in every case, so the same message is wrong on both sides.
- Why S2, not S1: the remaining cases are specific, documented wordings with a workaround (edit or delete). The claim "never changes totals on any path" in the commit messages and records is nevertheless **false**. V1-001 itself stays S1 OPEN until the deploy, the build and the device run.
- Required action:
  - Add these classes to the shared cases and decide each one.
  - Narrow `report` to an imperative ("report to", "to report").
  - Apply the question rule only when the cue is the question's own subject.
  - Add `pending`, `blocked` and `لم ينجح`.
  - Make "reversal/refund of a declined purchase" consistent across languages.
  - Rewrite KNOWN-LIMITATIONS §V1-001 from a re-run, not from the author's list (it is stale: `voided`, `not authorised`, `Refund … failed` and `تم استرجاع` are already fixed; K1–K5 in my run).

### FR-02 — S2 — The device and server disagree on type and direction for some messages, and new builds import the server's answer on iOS with Cloud on
- Class: REPRODUCED (N16, N46, N29, N30, N25; `vc_probe` shows `validateCaptureCandidate` accepts the N16, N46 and N29 server results).
- Wrong:
  - A failed bill payment (`لم ينجح`) becomes spend 200 on the Cloud path, while the device-only path sends it to review.
  - A debit-then-returned message is a payment on the server and a refund on the device: a 200 swing depending on the path.
  - `Transaction reversed:` is income on the server and review on the device.
  - The drift test compares cue lists only, and the shared table covers 127 cases.
- Required action:
  - Extend the shared table to assert the same `isTransaction / type / direction` on both sides for every case. Add these inputs.
  - Make server direction detection prefer reversal and refund keywords over `pos`/`خصم` when both are present, or route such messages to review on both sides.

### FR-03 — S3 — False positives: completed movements go to review
- REPRODUCED: N02, N03, N05, N06, N19–N22, N27, N36, N37, N43 (§A2).
- Negation is never applied to declined cues ("approved, not rejected", "not declined"). Merchant names without a listed introducer (`Merchant:`, no introducer, `via`, `at Café X`) are treated as statuses.
- Total-neutral but under-states spend until the user confirms.
- Required action: fix if cheap (negation before a cue; `merchant:`/`via` introducers), otherwise list in KNOWN-LIMITATIONS.

### FR-04 — S2 — The deployed `account-deletion-worker` leaves profile photos behind on the resume path, and its cron is active
- CODE-SUPPORTED (§H). The production facts come from `production-comparison.md` §1 and §4.2.
- Required action:
  - Owner-authorized deploy of `account-deletion-worker` from the candidate.
  - Then a one-off audit of `profile-photos` for owners whose deletion has completed.
  - Record it in `ISSUES.md`: V1-062 exists only in an uncommitted document.

### FR-05 — S1 for any store build that carries AdMob IDs (re-rate V1-005 / V1-063) — advertising is live in production and undisclosed
- CODE-SUPPORTED (§H gate trace; `PrivacyInfo.xcprivacy` declares no advertising data).
- `ISSUES.md` keeps V1-005 at S2 "OWNER DECISION". With every ad flag ON in production, a build from `ios-signed-release` or `android-release` shows ads to Cloud-on users at launch.
- Required action, before any store build: the owner turns the ad flags OFF, or builds without the `admob` group, or updates the policy, consent text, manifest and store answers.

### FR-06 — S3 — Restore under MERGE resurrects unsynced post-backup rows and tells the user it "replaces" data; the decision is not recorded
- CODE-SUPPORTED (§B: `payload_json` in `ledger_sync_outbox`; the outbox delete is limited to restored ids; `app_en.arb:2984`; no V1-020 entry in `DECISIONS-NEEDED.md`).
- Required action:
  - Add the replace-vs-merge decision to `DECISIONS-NEEDED.md` with this exact behavior.
  - Add a test for an unsynced post-backup create.
  - Adjust the confirm copy for Cloud users, or drop orphan create intents in the restore transaction if "replace" is chosen.
  - Measure the full re-pull on a large fixture.

### FR-07 — S2 (gate) — No strict gate at HEAD; the production comparison is stale for HEAD
- REPRODUCED. The last strict run is at `af675aec` (`evidence/logs/final_ci_gates_run2.summary.txt` line 3). Seven later commits change the parser, the server functions, CI and restore.
- `git diff --stat af675aec..HEAD -- supabase/` shows `parse-sms` and `process-ios-sms` changed after the comparison.
- Required action: run `REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh` at the frozen commit; restate the deploy set against it.

### FR-08 — S3 — Records claim more than the evidence at HEAD
See §I below. Required action: refresh the records against the frozen commit.

### FR-09 — S4 — Two trigger functions are granted to `anon`
Not callable through `/rpc` (`RETURNS TRIGGER`). Revoke `EXECUTE` in a future migration.

### FR-10 — S3 — The XCTest gate has never run and can block every App Store build for environmental reasons
- CODE-SUPPORTED (§C).
- Required action: run `xcodebuild test -only-testing:RunnerTests` locally once (when disk allows) and in one Codemagic dry run before the release build is needed.

### FR-11 — S3 — The skip gate can still be bypassed (REV-06 residual)
- The bypasses are `testOn`, tags, an early return and an unconditional `skip: true` (§C).
- Required action: match on the skip condition text as well as file, kind and `contextContains`.

### FR-12 — S4 — UI gaps
- The hint and the label share one style (`app_theme.dart:302-303`).
- A legacy `all_expenses` row shows an empty category field when edited.
- No test covers manual income or transfer.
- 44-pt target overlap is not tested.
- Everything is widget-test-only.

### FR-13 — S2, pre-existing, SUSPECTED — Substring ignore rules silently drop real purchases
- REPRODUCED for the parser: N38 `Purchase of SAR 100.00 at Hotpot Restaurant` (contains `otp`) and N23 (a purchase with an "OTP" footer). Device: `notTransaction`; server: ignored.
- `add_transaction_usecase.dart:892-895`: "Intentionally ignored messages … always stay ignored". There is no Smart Inbox card, which breaks the "zero silent losses" threshold.
- `_isIgnored` (`parser_engine.dart:1053-1085`) and `isIgnoredText` (`parse.ts:103-106`) use substring matching for `otp`, `won`, `offer`, `promo`, `click` and others.
- This is not introduced by these commits. Found during the review.
- Required action: whole-token matching for Latin ignore words, and a Smart Inbox card when an ignore rule fires on text that also carries a purchase verb and an amount.

## I. Records whose claims exceed the evidence at HEAD

| File:line | Claim | Fact at HEAD |
|---|---|---|
| `COVERAGE-MATRIX.md:3,7,10,14,18` | Assessed at `23499229`; the candidate is `af675aec` | HEAD is `0f90003f`, 7 commits later (parser, restore, CI, UI) |
| `RELEASE-MANIFEST.md` "Candidate with local fixes" | `af675aec` … 12 commits | 20 commits; working tree not clean (5 untracked and 2 modified records), so G0 is unmet |
| `ISSUES.md` V1-001 | "69 shared device/server cases" | 127 cases (`declined_cases.json`); FR-01/02 residuals |
| `ISSUES.md` V1-020 | OPEN, SUSPECTED, mechanism not executed | Fixed in code (`0f90003f`), executed on a local stack (2/2 pass); open only for the owner decision and a device run |
| `ISSUES.md` V1-054 | "OPEN — needs the group ported" | Ported in `837d0881`; +10 pass with synthetic defines |
| `ISSUES.md` V1-057 | OPEN | Fixed on both sides (probe in §A1) |
| `ISSUES.md` V1-060 | "SUSPECTED — not verified" | Fixed in code (`parse-sms/money.ts` `groundedModelAmount`, `0de54a2b`) |
| `ISSUES.md` V1-012 | OPEN | XCTest step added (`4fc2ecd6`), never run |
| `ISSUES.md` (whole) | no V1-062/063/064 | They appear only in the uncommitted `production-comparison.md` |
| `ISSUES.md` V1-002 | OPERATOR CHECK, S1 | The ledger equals the candidate (`production-comparison.md` §4.1); the register is not updated |
| `COVERAGE-MATRIX.md:114` (FAIL-02) | `parse-sms/money.ts` "was not changed" | Changed in `0de54a2b` |
| `COVERAGE-MATRIX.md:75` (DATA-08) | V1-020 undefined; no round trip executed | Restore round-trip tests and the local-stack run exist at HEAD |
| `KNOWN-LIMITATIONS.md:3,9-16,20-22` | Candidate `af675aec`; residuals "voided", "not authorised" and "Refund … failed" not recognised; "تم استرجاع" typed as a payment | All four are fixed at HEAD (K1–K5); the real residuals are FR-01/02/03 |
| `TEST-EVIDENCE.md:18` | "satisfies gate G1 for `af675aec`" | True, but G1 is not met at HEAD (FR-07) |
| `RELEASE-PLAN.md:3,11,316` | Assessed at `23499229`; only `process-ios-sms` changed; "PITR availability is UNKNOWN" | `parse-sms` changed too; PITR is **off** and no backups are listed (`production-comparison.md` §3). The only real recovery point is the step-0 `pg_dump`, which has never been taken |
| `RELEASE-DECISION.md:50` | "production state unknown" | The ledger, functions, flags and cron are now known (uncommitted comparison) |
| `production-comparison.md:118` | "smallest set … see RELEASE-PLAN.md" | `RELEASE-PLAN.md` at HEAD contains no such set |
| `production-comparison.md` §1 | 22 functions identical "to the candidate" | Candidate meant `af675aec`; `parse-sms` differs at HEAD |
| Commit messages `d35fc044`, `0de54a2b`, `84f2fe41` | "never record a declined purchase as spending" | False for the FR-01 inputs |

## G. Status of REV-01 … REV-18 at HEAD

| REV | Status | Evidence |
|---|---|---|
| REV-01 | PARTLY | All 17 original probes are now review on device and REJECT on server (§A1). New false negatives: FR-01 |
| REV-02 | PARTLY | All 7 original FP probes record payment 100. New FPs: FR-03 |
| REV-03 | RESOLVED (code) | `validated_capture.dart:245` and `capture_sync_service.dart:881` with tests; RELEASE-PLAN step 3a names the deploy. Build 147 stays unprotected (inherent, recorded). The deploy itself has not happened |
| REV-04 | PARTLY | Server tashkeel and tatweel fixed (R4a/b). The Dart preview uses the cues. The Swift preview still matches by substring (V1-061) |
| REV-05 | OPEN | V1-056; no repair pass |
| REV-06 | PARTLY | Define-gated stage runs; removal port passes +10; bypasses remain (FR-11) |
| REV-07 | RESOLVED | `unoptimized: true` → 404 (`next-server.js:167`); residual advisories recorded in V1-025 |
| REV-08 | PARTLY | Compiled and launched on a simulator at `f6dc5076`; the switcher snapshot, the inactive state and a background launch were not observed |
| REV-09 | PARTLY | 85F4.1 checked against Apple's definition (`official-doc-checks.md`); the API is still in release builds |
| REV-10 | OPEN | No change after `7597bb42` |
| REV-11 | OPEN | Test unchanged; passes only incidentally on non-UTC hosts |
| REV-12 | RESOLVED | V1-007 and V1-015 re-rated S1 in `ISSUES.md` (the underlying issues are still open) |
| REV-13 | RESOLVED | V1-014 re-rated S1 (the issue is still open) |
| REV-14 | SUPERSEDED | V1-020 re-rated S1, then fixed in code and run on the local stack (§B); the owner decision is pending (FR-06) |
| REV-15 | PARTLY | Manifest, TEST-EVIDENCE and UI-UX-REVIEW now exist; the records are stale again for HEAD (§I) |
| REV-16 | RESOLVED | V1-059; the rows cited are NOT TESTED (for example DATA-09) |
| REV-17 | RESOLVED | Both sides (§A1); `ISSUES.md` V1-057 not updated |
| REV-18 | OPEN | Strict gate only at `af675aec`; no CI build, deploy or device run |

## Per-commit verdicts

| Commit | Verdict | Reason |
|---|---|---|
| `64e571e5` CI version + skip count | ACCEPT WITH FOLLOW-UP | Contract tests pass; bypasses (FR-11) |
| `f9c5be75` Next 14.2.35 + runbook | ACCEPT | Superseded in part by `f6dc5076` |
| `d70ba396` reason codes + scene cover | ACCEPT WITH FOLLOW-UP | Codes match the official definitions; cover gaps (REV-08) |
| `2f2c4707` Help copy | ACCEPT | Test passes |
| `ff1fc292` zone-less as UTC | ACCEPT WITH FOLLOW-UP | REV-11 |
| `7597bb42` force-update range | ACCEPT WITH FOLLOW-UP | REV-10 |
| `d35fc044` declined, dates, grounding | ACCEPT WITH FOLLOW-UP | Superseded by later rounds; FR-01 |
| `f6dc5076` admin images unoptimized | ACCEPT | Verified in the Next source |
| `29cb1819` define-gated stage | ACCEPT | Fails closed, including on a renamed group |
| `668f4d64` declined round 2 | ACCEPT WITH FOLLOW-UP | FR-01/02 |
| `23499229` UI fixes | ACCEPT WITH FOLLOW-UP | Widget tests only; FR-12 |
| `af675aec` test digits | ACCEPT | — |
| `d830855e` records | ACCEPT WITH FOLLOW-UP | Claims stale at HEAD (§I) |
| `0de54a2b` declined round 3 + parse-sms grounding | ACCEPT WITH FOLLOW-UP | Tests tightened; FR-01/02; changes the deploy set (FR-07) |
| `4fc2ecd6` App Store workflow checks | ACCEPT WITH FOLLOW-UP | Fail-closed; XCTest never run (FR-10); SHA self-attested |
| `34ccc9e9` touch targets / contrast | ACCEPT WITH FOLLOW-UP | Presentational; widget tests only; overlap untested |
| `837d0881` configured removal port | ACCEPT | Assertion parity shown; +10 pass |
| `8e953d14` restore reproduction | ACCEPT | Passes against the local stack |
| `84f2fe41` declined round 4 + plain refunds | ACCEPT WITH FOLLOW-UP | FR-01/02/03; changes the server type of refunds (compatible, A3) |
| `0f90003f` restore identity | ACCEPT WITH FOLLOW-UP | Correct for the tested cases; FR-06 |

No commit is rejected.

## J. Decision recommendation (by `SEVERITY-AND-GATES.md`)

- **iOS: NOT READY.**
  - Open S1:
    - V1-001 (needs the `process-ios-sms` deploy, a new build and a device run; residuals FR-01/02);
    - V1-003 (disclosures);
    - V1-007, V1-015 (store);
    - V1-014 (iPad);
    - V1-020 (code fixed; owner replace/merge decision and device run outstanding, FR-06);
    - FR-05 (ads live and undisclosed for any `ios-signed-release` build with AdMob IDs).
  - Gates unmet: G0 (tree dirty, manifest names `af675aec`), G1 at HEAD (FR-07), G4 (no release-workflow build), G5 (no device run), G6, G7, G9.
- **Android: NOT READY.** V1-004 (owner decision on scope; no release AAB, no device run) plus the shared S1s above (V1-001, V1-003, FR-05 since `android-release` attaches AdMob).
- **Backend: NOT READY.**
  - Unmet G7:
    - PITR off and no listed backups (V1-023);
    - deploy order unrehearsed (V1-021);
    - no monitoring (V1-024);
    - FR-04 (photo erasure gap live in production);
    - production ad flags ON (FR-05).
  - V1-002 can be closed for the ledger, once the register is updated.
- **Combined: NOT READY.**

Open blockers, by who can act on them:
- **Engineering, fixable locally:**
  - FR-01/02 residuals plus shared-table extension;
  - FR-06 test and copy;
  - FR-07 strict gate at the frozen commit;
  - FR-08 records refresh;
  - FR-13;
  - FR-11;
  - V1-007 allowlist implementation (once the owner picks the option).
- **Access or device-blocked:**
  - deploy `process-ios-sms`, `account-deletion-worker` and `parse-sms` (owner-authorized);
  - production flag change;
  - PITR / `pg_dump`;
  - Codemagic release build including the first XCTest run (G4);
  - physical-device MDT-IOS (G5);
  - App Store Connect and Play consoles (G6).
- **Owner decisions:**
  - V1-004 (Android scope);
  - V1-014 (iPhone-only);
  - V1-005 / FR-05 (ads at launch);
  - V1-020 (replace vs merge);
  - V1-007 / V1-015 approach;
  - V1-056 (existing declined rows);
  - V1-034 cover timing;
  - exceptions for any S2 kept (FR-01, FR-02, FR-04 if not deployed).
