# T — Independent review: platform, data, consent, iOS, ops and records (closure round 3)

- **Reviewer:** `review-platform`. Model: Claude Opus 5.5, identifier `claude-opus-5-5`, as stated in this agent's system context; not otherwise verifiable. I wrote none of the reviewed code.
- **Scope:** `5dae2e2d..7577f347` except message parsing / AI understanding. Requirements: `OWNER-BRIEF-ROUND3.md` §3 (3.1–3.15), §6, §7.
- **Tree:** `release-readiness/v1` at `7577f347`, clean. Read-only: nothing in the repository was edited, staged, stashed or checked out. Reproductions ran on a **scratch copy** of `app/`, `third_party/` and `supabase/` (rsync of `7577f347`, plus `git archive 0f90003f` for the round-2 check), with HEAD files swapped only inside that copy.
- **Local stack:** my own, project `review_platform`, ports 58321–58330, realtime/analytics/studio excluded, all 135 migrations applied. Synthetic users only. Stopped with `--no-backup` at the end. `frasaaaaa` / `qirsh_proof` untouched. Not CI, not a hosted project, not a device.
- **Severity / class:** `docs/release-process/SEVERITY-AND-GATES.md`.

## Reproductions run

| What | Code | Result |
|---|---|---|
| `restore_then_sync_local_supabase_test.dart` with `--dart-define=SUPABASE_URL/ANON_KEY` | HEAD | `+10: All tests passed!` |
| same test, HEAD test file, `restore_backup_usecase.dart` + `transactions_backfill_service.dart` from `5dae2e2d` | `5dae2e2d` use case | `+3 -7` (R1, R2, R3, R4, R6, R9, R9b fail) — matches the implementer. R6 fails because restored row `r6-B` ends `sync_status = conflict` |
| round-2 V1-020 test as committed at `0f90003f`, on `0f90003f` app code | `0f90003f` | `+2` **with** the defines and `+2` without |
| `sync_e2e_local_supabase_test.dart` with defines | HEAD | `+10 -6` (S8, S9, S9b, S11, S12, S14) — matches the implementer |
| `account-deletion-worker/local_stack_integration_test.ts` (D1–D4) | HEAD | `4 passed, 0 failed` |
| `test/core/backup/restore_merge_rule_test.dart` | HEAD | 8/8 |
| Reviewer test: saved merchant rule removed after the backup, then merge restore | HEAD | **FAIL** — rule returns (`restaurants`) → SP-01 |
| Reviewer test: account created after the backup on a device with no transactions, then restore | HEAD | **FAIL** — account deleted → SP-02 |
| Reviewer probe: consent panel and shared-learning panel at 2.0x/3.1x, AR/EN, 320×568 | HEAD | no layout error (8/8) |
| `large_text_overflow_test.dart` + `primary_screens_text_scale_test.dart` | HEAD | `+122` pass; 117 ellipsis truncations printed (SP-10) |
| `admin`: `tsc --noEmit` and `tests/admin-authorization.test.mjs` | HEAD (next 15.5.29 installed) | clean; 8/8 |

## Findings

| ID | Sev | Class | Finding | Round |
|---|---|---|---|---|
| SP-01 | **S2** | REPRODUCED | **Merge restore resurrects saved merchant rules the user removed after the backup.** "Forget this rule" (`DriftMerchantCategoryRepository._forget`) and category deletion (`DriftCategoryRepository.deleteCategory`) **hard-delete** `merchant_category_map` rows; there is no tombstone, so `_mergeRow` sees "only in the backup" and inserts it. The rule then outranks AI (brief 4.5 #2), is not queued to the cloud (local-only divergence), and after a category deletion it can point at a soft-deleted category (`userConfirmedCategoryFor` does not filter `deleted_at`). Violates 3.3 "respect intentional deletions … do not overwrite newer user choices". Repro: scratch `test/review_platform/restore_merge_attack_test.dart` (add sale → confirm rule → backup → forget → restore → rule is back). | This round (new merge semantics claim deletions are respected; under replace semantics the return was by design) |
| SP-02 | S3 | REPRODUCED | **Full apply wipes records created after the backup when the device has accounts/rules/custom categories but no transactions, budgets, goals, subscriptions or plans** (`_deviceHoldsFinancialData`). An account with a manual balance created on a new phone before restoring is deleted; synced ones return via pull once Cloud is on, unsynced ones are lost. Contradicts "retain newer data"; the confirm copy ("a device with no records yet") does not tell the user an account counts as none. | This round (by design in data.md) |
| SP-03 | S3 | CODE-SUPPORTED | **Deploy set misses `process-notification-retries`.** `_shared/capture_push.ts` changed this round (3.12 outcome-true wording, `captureOutcome`). `process-notification-retries/process_one.ts` calls `capturePushContent`; the deployed (old) copy ignores `captureOutcome`, so a retried generic push (clients without `notificationDetails`, hidden-content users) says "New transaction captured" / «تم رصد عملية جديدة» for a capture the new `process-ios-sms` classified declined / excluded / review. RELEASE-PLAN says the push senders have "no behaviour need" — no longer true. Import closure computed from `git diff b6fc0dad..7577f347 -- supabase/functions`: changed closures = `parse-sms`, `process-ios-sms`, `bank-discovery`, `enrich-merchant` (in the set) **plus `process-notification-retries`** (and `send-push-broadcast`, which uses only the unchanged dead-token helpers). | This round |
| SP-04 | S3 | CODE-SUPPORTED | **New storable currencies (50 → 155) are not covered by the mixed-build compatibility analysis.** Build 147 (`b6fc0dad`) quarantines ledger rows it cannot map (`_applyRowOrQuarantine`) and parks planning rows as unresolved currency, so a user with the new build on one phone and 147 on another sees rows in e.g. NOK/CAD silently missing on the old phone. Not in RELEASE-PLAN §(c). Server stores any `^[A-Z]{3}$`; `money_text.ts` is permissive for unknown codes; formatting falls back to the code — no crash path found. | This round |
| SP-05 | S4 | CODE-SUPPORTED | Migration `20261117120000` header and its rollback file say a guard that cannot reach `consume_ai_global_budget` "fails closed / sends every AI item to review". `_shared/ai_budget_gate.ts` deliberately **fails open** on `PGRST202`/`42883`. Consequence: rolling M1 back with the new functions still deployed silently removes the ceiling (no outage). RELEASE-PLAN describes the real behaviour; the SQL comments do not. Migration itself: additive, idempotent, RLS on, grants revoked from `public/anon/authenticated` for tables and function, `search_path` pinned, atomic reservation; callers use the service client. Accept. | This round |
| SP-06 | S3 | REPRODUCED | `sync_e2e` 6 failures: I agree none shows a product defect (S11/S12 assert a server state without 0100/0102 that no longer exists; S14 counts the admission sign-in's settings push; S8 now stops earlier at the fence — R7 shows safety holds; S9/S9b need two devices in one process). But the consequence is that **two-device pull-conflict / keep-remote and stale-owner parking have no passing end-to-end run against a real server**, and the suite is not in `ci_gates.sh`. They are unverified, not "passing for other reasons". | Pre-existing breakage (fence `2f414b15`); harness partly fixed this round |
| SP-07 | S4 | CODE-SUPPORTED | Records drift: `evidence/closure/consent.md` follow-up says `kCurrencyScale` is **not** extended (50 codes); the final code extends it to 155 and adds `kDetectionCurrencyScale`. Code comments cite "decision B26 (a)" (sign-out sheet) and "B24" (app-switcher cover) while `DECISIONS-NEEDED.md` still lists B26 as open and `ISSUES.md` V1-067 says "OWNER DECISION" — an implementer choice recorded in code as a decision. RELEASE-PLAN §(a) says ad flags "Turn off (P5)"; the step is P4. Nothing outside brief §3 is recorded as owner-approved in `DECISIONS.md` D-20 (checked). | This round |
| SP-08 | S4 | CODE-SUPPORTED | Test weakening: `restore_recovery_test.dart` now runs the delete-phase fault points (`afterFirstDelete`, `afterSeveralDeletes`) only against a destination holding a settings tweak, not `seedRich`; rollback of a populated full-apply destination at the delete phase is no longer exercised. Other assertions unchanged. | This round |
| SP-10 | **S2** | REPRODUCED | **Clipped text at the now-supported sizes is not recorded anywhere.** With the cap removed, 3.1x is a supported size, and the acceptance threshold says "no clipped text at the largest supported text size on primary screens". The gate asserts only Flutter errors; my run printed **117 ellipsis truncations** (18 at 1.0x, 15 at 1.3x, 35 at 2.0x, 49 at 3.1x), e.g. Home 3.1x AR: «مصروف الشهر ; دخل ; مصروف ; الصافي» cut; Home 1.0x 320pt: transaction date/category lines cut. `a11y.md` discloses this as a "known gap", but it is absent from `ISSUES.md`, `KNOWN-LIMITATIONS.md` and `RELEASE-DECISION.md`, so the threshold failure is invisible to the decision. | This round (cap removal) |
| SP-09 | S3 | CODE-SUPPORTED | Large-text gate (`largeTextScreens`, 20 screens) omits onboarding (language, sign-in, setup + country picker, currency choice), delete-account, privacy, restore confirmation, consent sheet. My probe of the two consent panels at 3.1x passed; the rest is NOT TESTED. | This round |

## Answers to the specific questions

**Restore = merge (3.3).** Rule implemented as described; ties go to the device; all `updated_at` writers use `dateTimeToSql` (UTC ISO with `Z`), and pull sets local `updated_at = now`, so zone-less parsing is not an issue here. Clock skew is inherent last-writer-wins: a backup from a phone whose clock runs ahead can beat a newer pulled edit; the push is a guarded update (base token), so the server raises a conflict rather than being overwritten. Transactions, budgets, goals, subscriptions, plans, cards, plan links and bill payments are soft-deleted → not resurrected; **merchant rules are hard-deleted → resurrected (SP-01)**. Tables without `updated_at` in the backup (budgets, goals, plans, subscriptions, categories, settings) always keep the device copy. Natural keys: cards matched by `(account_id,last4)` are not added to `_remappedReferences` — harmless today (transactions carry `card_last4`, not a card id). Backup-wins update: row marked `pending` only when server-backed, outbox intent deleted, `PendingSyncReconciler` records an `update`/`delete` (verified by merge-rule case 8). The 12→18 inventory raise is accurate: 4 TEMP-table drops + 2 single-entity outbox deletes, all inside the restore transaction. Partial failure: merge uses TEMP tables inside the same transaction; any fault rolls back (recovery tests pass on both paths, with SP-08's caveat).

**Round-2 V1-020 evidence.** At `0f90003f` the restored rows kept their server identity (`_captureSyncIdentity`/`_rebindSyncIdentity`), so the startup backfill was not on R1/R2's path; I reproduced `+2` both with and without the defines. The round-2 claim therefore stands for R1/R2, but its assertions did not check for conflicts on restored rows and had no restored-row-without-identity case; that path had a false "direction" conflict at `5dae2e2d` (my R6 run), fixed this round.

**Deletion (3.4).** D1–D4 pass on my stack (inline, worker-only, injected storage failure + retry, re-signup empty). Copy has no "immediately"/30-day promise. `cancel_account_deletion` only clears `delete_scheduled_at`; purge cron unscheduled; `request_account_deletion` raises. Queued iOS captures after deletion not exercised by me. **ACCEPT WITH FOLLOW-UP** (deploy `account-deletion-worker`; production photo orphans are an owner action).

**Consent (3.5–3.10).** Legal allowlist: whole-URL string equality against two constants, https only — no redirect/subdomain/parse bypass in Dart; the in-app Safari view can of course navigate further (user-driven, no app data). `LEGAL_BASE_URL` is a build-time override passed by Codemagic (empty unless set). Shared learning: missing key = OFF; only "Agree and enable", the one-time question or the switch write ON; the client re-checks opt-in and `aiProcessing` before each send. AI request body = sanitized text, install id, device secret, request id, and the new `local_evidence` + `account_currency`; the consent text names both. I did not re-trace every network client end to end (relied on the existing `CloudEgressGate`/`GatedHttpClient` architecture and its tests). **ACCEPT WITH FOLLOW-UP** (SP-04).

**iOS (3.1, 3.2, 3.12, 3.13).** `TARGETED_DEVICE_FAMILY = 1` in all six configs, portrait only. Ads: `adsCompiledIn` is a compile-time `bool.fromEnvironment` (test override ignored when `kReleaseMode`); every SDK/UMP entry (`MobileAdsInitializer.mayServe`, `UmpAdConsentService.gatherConsent/canRequestAds/isPrivacyOptionsRequired/showPrivacyOptions`, banner and interstitial loaders) checks it first; no native code calls GMA/UMP (only `FLTGoogleMobileAdsPlugin` registration); store workflows attach no `admob` group, pass no `ADMOB_*`/`QIRSH_ADS_ENABLED`, delete `AdMob.xcconfig` → empty `GADApplicationIdentifier` in Release, as in build 147. Sign-in vars added and enforced. Banners: last four only when exactly 4 digits, merchant cut at 40, no category shown as final, status line states queued/review. Signed-out Shortcut run throws and posts one content-free banner. DiskSpace removal justified (`#if DEBUG`). Native XCTests NOT run by me. **ACCEPT WITH FOLLOW-UP** (SP-03; linked-SDK network capture MDT item 8 still open).

**Accessibility.** Cap removed (`clamp(minScaleFactor: 0.8)`); measuring-only tests above the cap were replaced by an asserting gate. Gate run on my copy: `+122: All tests passed!` (no layout errors), with 117 printed truncations (SP-10). "Move to review" sets `pending`, keeps amount/category/provenance, enqueues the ledger update. **ACCEPT WITH FOLLOW-UP** (SP-10 must be registered and either fixed or owner-excepted; SP-09).

**Backend/ops.** Migration accepted (SP-05 comment fix). Admin on Next 15.5.29: route handler `params` awaited, `cookies()` awaited, auth tests pass; build not run. `prod_compare.sh` is read-only against production (drops only its own local DB). **ACCEPT WITH FOLLOW-UP** (SP-03, SP-04 in the plan).

**Legal and records.** Policy matches the code on consent, combined withdrawal, shared learning transition, deletion finality, catalog off with Cloud off, no ads. **ACCEPT WITH FOLLOW-UP** (SP-07).

**Test expectations changed in the range (app/test, supabase, tools).** Decided behaviour changes (accept): `backup_test` (replace→merge), `restore_then_sync_identity_test`, `restore_sync_identity_entities_test`, `transactions_backfill_identity_test` (tombstone → applied), `privacy_screen_deletion_test`, `delete_account_screen_test`, `smart_inbox_card_test` (label), `smart_inbox_status_cycle_test` (no UMP), `android_ci_compile_gate_test` + `codemagic_ios_store_pipeline_contract_test` (no iOS AdMob), `capture_queue_cap6_contract_test` (4th approved message), `capture_notify_v2_contract_test`, `build50_ownerless_fallback_pin_test` (moved, still pinned), `shared_category_learning_client_test`, `privacy_consent_management_test`, `privacy_copy_test`, country tests, `setup_consent_step_test`, `ios_privacy_manifest_test` (DiskSpace), `capture_push_test` / `notification_classification_test` (category no longer final), `spending_charts_test` (Western digits), `primary_screens_text_scale_test` (measurement-only cases removed, replaced by a stronger gate), `destructive_path_inventory_test` (audited, accurate). Weakened: `restore_recovery_test` (SP-08). Integration harness `local_device.dart`/`sync_e2e` changed without loosening assertions. Parser/AI test changes left to the other reviewer.

## Verdicts

| Area | Verdict |
|---|---|
| 1 Restore = merge | **REJECT** until SP-01 is fixed (or owner-excepted); SP-02 to known limitations or fixed |
| 2 Deletion final | ACCEPT WITH FOLLOW-UP |
| 3 Consent, language, countries | ACCEPT WITH FOLLOW-UP (SP-04) |
| 4 iOS | ACCEPT WITH FOLLOW-UP (SP-03) |
| 5 Accessibility | ACCEPT WITH FOLLOW-UP (SP-10, SP-09) |
| 6 Backend/ops | ACCEPT WITH FOLLOW-UP (SP-03, SP-05) |
| 7 Legal and records | ACCEPT WITH FOLLOW-UP (SP-07) |
| 8 Test integrity | ACCEPT WITH FOLLOW-UP (SP-06, SP-08) |

Reviewer reproduction tests (not in the repository) are kept at `/private/tmp/claude-501/-Users-luciq--claude-spares-spare-yEUVj2/1b6aaa41-9527-44a7-aa2c-8ab180862078/scratchpad/review-platform/keep/` (`restore_merge_attack_test.dart`, `large_text_uncovered_test.dart`); drop them into `app/test/` to re-run. The scratch copy, logs and the `review_platform` stack (with volumes) were removed.

## Not checked

Native XCTests (not run: build time/disk); a simulator or device; network capture of the linked GMA/UMP SDKs; the admin production build; a full trace of every pre-consent network client; queued iOS captures across deletion and account switch; iPad compatibility mode; the 30-day-legacy UI on a device; production (no access, none used); parsing/AI (other reviewer).

---

## Re-review at 7dd6efa8

Reviewer `review-platform`, model `claude-opus-5-5`, 2026-11-18. Read-only on the repository (this section is the only write). Runs were made on a `git archive 7dd6efa8` copy in the scratchpad and on my own local Supabase stack (project `review_platform`, ports 58321–58331), torn down afterwards.

### Runs

| Run | Result |
|---|---|
| My kept reproductions (`restore_merge_attack_test`, `large_text_uncovered_test`) + `restore_merge_rule_test` + `restore_recovery_test` (in memory) | `+46: All tests passed!` — both SP-01/SP-02 repros now pass |
| Own stack, dart-defines: `restore_then_sync_local_supabase_test` + `sync_e2e_local_supabase_test` | `+24 ~2: All tests passed!` (S9/S9b skipped, manifest entry) |
| Large-text gate, unplanted, full | `+128: All tests passed!` (matches the implementer's 128/128) |
| Large-text gate with a planted truncation (`linesUnlessLargeText` returns `normal` always), `QIRSH_LARGE_TEXT_SCREENS=Home` | **Fails** at 1.3x: "Home cut off: Set a budget to track your pace ; Income ; Paste SMS ; …" — the gate is real |
| Scratch semantics test (mine) on `SegmentedControl` and `AppPillTabBar` at 1.0x / 2.0x / 3.1x | `+6`: every option keeps `isButton`, `hasSelectedState`, tap action and its label; tapping moves `isSelected` to the tapped option; the callback gets the right value/index |
| `tools/deploy_set.sh` on a scratch clone with a planted line in `_shared/capture_auth.ts` and `_shared/sms_redaction.ts` | Every importer reported CHANGED, including transitive ones (`process-notification-retries` via `process_one.ts`, `send-push-broadcast` via `send.ts`, functions reached through `capture_push.ts`/`feature_flags.ts`) — correct |
| `tools/deploy_set.sh b6fc0dad 7dd6efa8` | **8 CHANGED**, not the 6 RELEASE-PLAN records: adds `merchant-category-contribution` (`_shared/sms_redaction.ts`) and `sync-captures` (`_shared/money_text.ts`) — see SP-11 |

### Status of the findings

| ID | Status | Note |
|---|---|---|
| SP-01 | **Fixed** | Merge never takes backup `merchant_category_map` rows; a row deleted/ignored on the device is never overwritten (`_deviceRowDeleted`) |
| SP-02 | **Fixed** | `_deviceHoldsUserData` counts accounts, cards and all user tables, user-confirmed rules and non-seed categories; a device with any account merges |
| SP-03 | **Fixed at 98e8e56d, regressed at 7dd6efa8** | Derivation tool is correct; the plan's recorded set is stale (SP-11) |
| SP-04 | **Partly fixed** | Matrix and options are in RELEASE-PLAN (c); whether 147's planning currency repair rewrites the server row is still "not traced" (stated honestly) |
| SP-05 | **Fixed** | Migration header, rollback header, `ai_spend_guard.ts` and RELEASE-PLAN (b)/(h) all state the PGRST202/42883 fail-open and the undo order |
| SP-06 | **Partly fixed** | S8 change is real (stricter: throws `:stale`, outboxes byte-identical, all "nothing sent as B" assertions kept). S12/S14 real. S9/S9b honestly skipped. S11 no longer covers "parked while the server lacks 0102" end to end (only in-process) |
| SP-07 | **Partly fixed** | P5→P4 fixed; code comments presenting open B24/B26 as decided remain (listed, not edited) |
| SP-08 | **Fixed** | Full-apply destination has no account, all 9 fault points incl. both delete points reached and asserted (`reached`) |
| SP-09 | **Fixed** | Twelve more screens in the gate |
| SP-10 | **Fixed** | Gate fails on ellipsis truncation; allowlist is 3 entries, each scoped to one screen and one regex; planted truncation fails. Known residual: text clipped without an ellipsis (`overflow: clip`/`fade`, fixed-height parents) is not detected |

### Attacks on the fixes

**"Device rules win" (SP-01 fix).** On any device that merges — including one holding a single empty account, which is every user who finished onboarding — **all** backup-only rules are dropped, learned and user-confirmed alike. The confirmation copy (`rpConfirmBody`) does say "rules that are only in the backup are not added" and defines the no-records case, but it is the same text whichever case applies, so the user is not told which path this restore will take, and it does not say how to get the rules back. The only ways back: Cloud rule sync (only if Cloud was on and the rules were synced; restore turns Cloud off until re-enabled), or removing the device's data so the restore becomes a full apply (which discards everything newer). For a never-Cloud user the backup's rules are effectively unrecoverable on a set-up device. Accepted trade-off, but it belongs in the known limitations (SP-12, S4).

**Onboarding classification.** Correct: a fresh install has no auto-seeded account (A-7), seeds only `DatabaseSeed.categories`, and onboarding offers restore (`/onboarding/check`) before account setup, so an onboarding restore is a full apply. Residual: a device whose DB carries a legacy category key no longer in `DatabaseSeed` would be classed "has data" and merge; not reachable on a fresh install.

**Deleted stays deleted.** It does not change recovery of a transaction deleted by mistake: a same-device deletion is always newer than the backup, so merge never revived it before either; the new guard matters only under clock skew. The only path to recover one is the full-apply route (remove device data, restore, losing everything newer). No in-app undo/trash for deleted transactions was found. State this in known limitations (part of SP-12).

**Stacked selectors.** `StackedChoices` wraps each option in `Semantics(button: true, selected: i == selectedIndex)` around a tap handler, min height 44, label without `maxLines`. My scratch test confirms semantics and selection at 1.0/2.0/3.1x. There is **no committed test** for the stacked branch's semantics or selection (the large-text gate checks layout only) — S4 test gap (SP-13).

**RELEASE-PLAN, read end to end as the owner.** Order (P0 read-only → P1 worker → P2 M1 → P3 retries-first then AI functions → P4 flags → P5 observe), stop conditions per step, kill switches and M1 undo order are coherent. Problems:
- **SP-11 (S3, REPRODUCED, round 2).** At the commit that now exists, `deploy_set.sh b6fc0dad 7dd6efa8` prints CHANGED for `merchant-category-contribution` (its `redactPii` behaviour changed: `To:`/`إلى` redaction now stops at a sentence end) and `sync-captures` (additive `isRewardFlow` export only). The plan records 6 CHANGED and "18 IDENTICAL"; at this commit `prod_compare` would not match, so P0 stops (fail-safe) and the package cannot be executed as written. The owner/privacy specialist must decide whether `merchant-category-contribution` ships with the new redaction (it governs what reaches shared learning) and the plan's lists must be regenerated at the final commit. Repro: `bash tools/deploy_set.sh b6fc0dad 7dd6efa8`.
- **SP-14 (S3, CODE-SUPPORTED, round 2).** The `process-notification-retries` v12 rollback source is "unknown, identify in P0" in (b), but P0's command list and stop conditions only cover the `account-deletion-worker` v5 source. If v12's source is not found, P3 deploys an un-rollbackable function with no stop condition. Add it to P0 (command and "no source found" stop).
- **SP-15 (S4, round 2).** Stale text: "closure-round changes are uncommitted (HEAD `d1212986`)"; (a) "Identical to HEAD: 21" vs "18 IDENTICAL" in the same section; the (g) "call-site contract" still reads as if the guard always fails closed (the deviation is noted in its lead-in only). Unverified assumptions the plan relies on and labels as such: the `79a063d8` sender refactor is "behaviour-preserving by design, not proven"; no undo is rehearsed against production; the 147 × new parser cell is still to be measured.

### Fresh verdicts

| Area | Verdict |
|---|---|
| 1 Restore = merge | **ACCEPT WITH FOLLOW-UP** (SP-12 known limitations: rules dropped on merge, no recovery of a mistaken deletion except full apply) |
| 2 Deletion final | ACCEPT WITH FOLLOW-UP (unchanged) |
| 3 Consent, language, countries | ACCEPT WITH FOLLOW-UP (SP-04 repair trace) |
| 4 iOS | ACCEPT WITH FOLLOW-UP (SP-14) |
| 5 Accessibility | **ACCEPT** (SP-13 test gap, non-ellipsis clipping undetected — both S4) |
| 6 Backend/ops | **ACCEPT WITH FOLLOW-UP — plan must be regenerated** at the final commit (SP-11, SP-14) before owner approval |
| 7 Legal and records | ACCEPT WITH FOLLOW-UP (SP-07 comments, SP-15) |
| 8 Test integrity | ACCEPT WITH FOLLOW-UP (SP-06 S11 end-to-end gap) |

### Not checked in this re-review

Native/simulator runs; `merchant-category-contribution` redaction correctness itself (parser/privacy reviewer's area); whether 147's planning currency repair rewrites the server row; the legal text; `tools/prod_compare.sh` (needs production); the whole backup suite (implementer reports `+316`; I ran the restore subset). The working tree has an unrelated uncommitted change to `tools/message_eval/run.sh` that is not mine.
