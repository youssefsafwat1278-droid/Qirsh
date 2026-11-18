# Closure round 3: data integrity (`data`)

## Context

- **Model:** `claude-opus-5-5` (Opus 5.5). The only source for this is the session's system context, which says: "You are powered by the model named Opus 5.5. The exact model ID is claude-opus-5-5." I have no other way to check it.
- **Tree:** `.claude/worktrees/v1-readiness`, branch `release-readiness/v1`. HEAD was `d1212986` when I started; the candidate code is `5dae2e2d`.
- **Commit state:** I did not commit, stage or stash anything. Every scenario below ran on the **uncommitted working tree** on top of `d1212986`. The "before" runs used HEAD's `restore_backup_usecase.dart`, swapped in and then put back (a `cmp` check confirms it was restored).
- **Evidence language:**
  - "Local stack" means my own local Supabase: project `qirsh_v1_closure`, API on port 57321, CLI 2.117.0, with realtime and analytics excluded. It is not a hosted project. A local gate is not CI.
  - No simulator or device was used.
  - Anything described as code reading is NOT TESTED.
- **Data:** all of it is synthetic. Users are `*@proof.invalid`; merchants are named "Synthetic shop …".
- **Load:** the machine's load average was about 50–70 (other specialists were running). Some default 30 s / 5 s test timeouts fired under that load. I re-ran those tests with `--timeout 180–300s`, and every case that timed out passed (details below).

## 1. Restore = merge (decision 3.3; V1-020, V1-070): DONE, verified on the local stack

**Files changed:**
- `app/lib/core/backup/restore_backup_usecase.dart`. New `_mergeSnapshot` / `_mergeRow` / `_findDeviceRow` / `_backupIsNewer` / `_updateFromBackup` / `_verifyMergeAgainstPlan`, with the rule documented in a comment block.
- The `rpConfirmBody` value in `app_en.arb` and `app_ar.arb`.

### Merge rule (per row)

| Situation | Result |
|---|---|
| Device has no financial records (no transactions, budgets, goals, subscriptions or plans; a seeded account alone does not count) | **Full apply, exactly as before.** This covers new-device transfer, settings and streaks. |
| Row only in the backup | Restored. The startup backfill binds it to its cloud copy by id, so there is no duplicate. |
| Row only on the device (including unsynced creates) | Kept, with its queued outbox intent. |
| Row in both, and the table carries `updated_at` (accounts, transactions, cards, sender mappings, merchant→category) | The **strictly newer** copy wins; on a tie the device wins. When the backup wins, the row keeps its server identity, is marked `pending`, stale queued intents are dropped, and it is pushed as a guarded update. |
| Row in both, and the table has no timestamp in the backup (budgets, goals, plans, subscriptions, children…) | The device row is kept. |
| Deleted on the device after the backup (`status='ignored'` or `deleted_at` with a newer `updated_at`) | Stays deleted. It is not resurrected and causes no conflict. |
| Category or provenance changed by hand after the backup | Kept, because the device edit is newer. |
| Natural-key duplicate (category `key`, merchant `normalized_name`, sender id, active card account+last4, achievement key) | The device row is kept, and backup references are remapped to it. |
| Settings and streak singletons when merging | The device copy is kept. |
| Pull cursors | Kept when merging; reset on full apply, as before. |
| Cloud and Smart Analysis consent after any restore | Reset to off, unchanged. |

**Copy (`rpConfirmBody`, EN; the AR is equivalent MSA):** "The restore merges this backup into the data on this device. Records missing here are brought back. Anything you added, changed or deleted after the backup was made stays as it is now; when a record exists in both, the more recently edited copy is kept. On a device with no records yet, the whole backup is restored, settings included. Cloud and Smart Analysis are turned off after the restore until you turn them on again. Continue?"

### Scenarios on the real local stack

The test is `app/test/integration_local/restore_then_sync_local_supabase_test.dart`. It uses the real snapshot builder, the restore use case, the outboxes, push/pull, the startup backfill and a fence-admitted database. "Cloud on" means two sync cycles afterwards. Amounts are in KWD.

| # | Scenario | Before (HEAD use case) | After (working tree) |
|---|---|---|---|
| R1 | Backup holds A10, B20, C30. After the backup and a sync: B edited to 25, C deleted, D40 added. Then restore. | **FAIL.** Local and cloud went back to B20 and C30. | **PASS.** Device = cloud = A10, B25, D40, one copy each, no conflict. |
| R2 | Backup holds A. E50 was created and synced after the backup. | **FAIL.** Device `{A}`; E missing locally. | **PASS.** Device = cloud = A, E. |
| R3 | D40 created after the backup and never synced. | **FAIL.** D was lost. | **PASS.** D kept and pushed once. |
| R4 | Category changed by hand to `restaurants` after the backup. | **FAIL.** Came back as `shopping`. | **PASS.** Device and cloud have `category_id=restaurants`, `category_source=user`. |
| R5 | Row only in the cloud. | pass | pass. Arrives once through sync. |
| R6 | Row missing on the device but present in the backup and the cloud. | pass | pass. Restored and bound; cloud count is 2 with no duplicate. |

- **Commands:**
  ```
  source <scratch>/stack/stack.env
  cd app
  PUB_CACHE=$HOME/.pub-cache flutter test --no-pub --timeout 300s test/integration_local/restore_then_sync_local_supabase_test.dart
  ```
- **Results:** before, `+2 -4`; after, `+6: All tests passed!`.
- **Logs (scratch):** `data/restore_local_before.txt` and `data/restore_local_after.txt`. They include per-scenario `report()` dumps of the device rows, the outbox and the server rows.

### Fake-cloud unit tests

The new file is `app/test/core/backup/restore_merge_rule_test.dart`. It covers eight cases:
1. a synced deletion;
2. an unsynced deletion;
3. a newer edit;
4. an unsynced create;
5. a row missing locally;
6. a cloud-only row;
7. a manual category;
8. a newer copy in the backup that wins and is pushed as an update.

Before the change: 5 failed and 3 passed (cases 5, 6 and 8 already passed). After: 8/8 pass.

### Changed tests (the owner changed the behaviour from replace to merge)

- **`test/core/backup/backup_test.dart`:** "restore replaces existing data" became "restore keeps existing data the backup does not have".
- **`test/core/backup/restore_then_sync_identity_test.dart`:** R1, R2 and the tombstone test now assert merge. A newer synced edit is kept, rows created later are kept, and a synced deletion stays deleted with no conflict. The old version asserted "restored values win" and "tombstone becomes a conflict".
- **`test/core/backup/restore_sync_identity_entities_test.dart`:**
  - When merging, rows, identity, base tokens and `synced` are untouched, and cursors are kept.
  - A new "new device (no records)" case asserts the full-apply identity (`srv:` identity kept, `pending`).
  - A queued edit and its intent survive.
  - I removed the `_children` constant, which my edit had orphaned.
- **`test/core/backup/restore_recovery_test.dart`:** every fault point now runs on both paths (merge, and full apply on a new device). The delete-phase faults run on full apply only, because merge deletes nothing. No assertion was loosened; the rollback checks are identical on both paths.
- **`test/integration_local/restore_then_sync_local_supabase_test.dart`:** R1 and R2 now expect merge, and R3–R8 were added.

## 2. Deletion is final (decision 3.4; V1-006, V1-062): DONE locally; deploy is an owner action

**Copy (EN and AR, values only):**
- `deleteAccountIntro`, `deleteAccountConfirmBody`, `privDeleteAccountBody`: deletion is final and cannot be undone, covers backups and the profile photo, and some server steps take a few minutes. None of them mentions "immediately" or 30 days.
- `deleteAccountAcceptedBody` (orchestrator note from `ops`): it used to say "You can check or cancel it in Privacy & data". It now says deletion has started, is final and **cannot be cancelled**, and may take a few minutes. AR: «الحذف نهائي ولا يمكن إلغاؤه».
- Legacy notice: `privScheduledForDeletion`, `privCancelDeleteTitle/Body`, `privCancelDeletion`, `privCancelFailed`. The old 30-day request "will not be carried out; the account is still active". The button now only *clears the notice*.
- I checked all `deleteAccount*`, `privDelete*`, `privCancel*` and `privScheduled*` keys in both languages; none has any other cancel/undo/30-day deletion wording left. `deleteAccountConfirmBodyScheduled` and `deleteAccountPendingBody` were already consistent.
- **Consistency with `docs/legal/PRIVACY_POLICY.md` §5 (ops):** the policy says deletion "is final — there is no undo period", that background steps "can take a few minutes", and that the legacy 30-day request "will not be carried out". **The app copy matches; I found no mismatch.**

**Test:** `test/features/settings/delete_account_screen_test.dart`, the decision 3.4 test. It asserts `permanent`, `cannot be undone` and `apple`, with no `immediate`/`30 days` (EN) and no `على الفور`/`30` (AR). It also asserts that the accepted body says "cannot be cancelled" / «لا يمكن إلغاؤه» and contains no cancel offer. Before the arb change this test failed on the old `immediate` assertion and the accepted-body line; after, it passes.

**Server verification on the local stack.** The new file is `supabase/functions/account-deletion-worker/local_stack_integration_test.ts`. It runs the real coordinator and adapter, real GoTrue reauthentication with the code read from Mailpit, the real sealer, Storage and auth admin, and the real inline and worker handlers. Apple is stubbed. Without the env variables it is skipped (4 ignored).

| Test | Result after the change (working tree) | Before: deployed worker v5 shape, i.e. the pre-`9e19c3e4` `storage_erasure.ts` in a scratch copy |
|---|---|---|
| D1: inline deletion completes. Auth, profile, transactions, both backups and `profile-photos/<uid>/avatar` all go to 0; the old token can no longer insert or upload. | ok | **FAILED**: `profile-photos: 1` left |
| D2: the request is only accepted; the worker alone finishes it. | ok | **FAILED**: photo left |
| D3: injected Storage failure makes inline return `in_progress` (auth still present). The worker run reports `processed 2, retry_scheduled 1, completed 1`, and the claim's PGRST303 clock skew is retried (`retryWorkerClaim`). Everything ends at 0. | ok | **FAILED**: photo left |
| D4: a later sign-up with the same email gets a new uid with 0 data and 0 objects. | ok | ok |

- **Commands:**
  ```
  source <scratch>/stack/stack.env
  cd supabase/functions
  deno test -A account-deletion-worker/local_stack_integration_test.ts
  ```
  - After: `4 passed | 0 failed`. Before (v5 copy): `1 passed | 3 failed`.
  - `deno lint account-deletion-worker/` is clean.
  - The deletion unit tests: 157 passed.
  - `deno.lock` is unchanged.
- **No return through sync:** after D1–D3 the old session cannot write rows or objects, and D4 shows a new identity starts empty. On the device, `DataWipeService` clears both outboxes and the capture work tables (`data_wipe_service_test.dart` passes).

**The 30-day machinery is consistent and I left it in place:**
- **Server:** `request_account_deletion` raises QD003 (0117). The `purge-scheduled-deletions-job` cron is unscheduled. `legacy_queue_guard` refuses `account_purge_queue` inserts. The `cancel_account_deletion` RPC still exists; it only clears `profiles.delete_scheduled_at`. The `purge-scheduled-deletions` function is unchanged and unreachable on a schedule.
- **App:** `AccountDeletionService.getStatus` / `cancelDeletion` and `_PendingDeletionCard` in `privacy_screen.dart` are not my files. They now show the "will not be carried out / clear notice" copy.
- No production cleanup was done.

## 3. Signed out and account switch: VERIFIED on the local stack (existing behaviour; no product change)

These two new local-stack tests are in `restore_then_sync_local_supabase_test.dart`:
- **R7.** A creates an account and a transaction, unsynced, on a database the fence admitted for A. B signs in on the same device, and every push (accounts, ledger, planning) runs.
  - Result: 0 rows under B and 0 under A, and A's intent is kept.
  - When A signs back in, a sync delivers exactly A's row to A, and B still has 0.
- **R8.** A signs out with queued changes and every push runs. Result: 0 rows sent, and the intent is kept.

Result: `+2: All tests passed!` (`data/switch_r7r8.txt`).

In both cases the fence stopped delivery (`*DeliveryStopped`) before anything was sent; the outbox owner stamp is a second layer. These tests check existing behaviour, so they pass both before and after. **No "fail before" exists, because nothing in the product changed.**

Also run:
- `ledger_outbox_correctness_test.dart --plain-name owner` (owner_mismatch parking, NULL-owner stamping, no-session intent): 7/7 pass.
- `data_wipe_service_test.dart` passes.
- `prepared_deletion_local_removal_test.dart`: its own 5 s internal timeouts fired under load. See the gates section; it is UNVERIFIED here.

**Pre-existing harness breakage (not caused by me, not fixed):** `test/integration_local/sync_e2e_local_supabase_test.dart` fails all 16 scenarios at HEAD with `AccountsDeliveryStopped:unbound` / `PlanningDeliveryStopped:unbound`. Its `Device.open()` opens a database the account fence never admitted. The scenario S8 "stale owner" is therefore not runnable today. R7 replaces it, using the fence-admitted fixture. To fix the harness, `Device.open` should go through `LedgerAdmissionFixture` the way `openSignedIn` does.

**Queued iOS captures** (the App Group `SharedCaptureStore`, `capture_import_service`) are owned by `ai`/iOS. They are NOT TESTED by me.

## 4. Structural migrations: none

No Drift or SQL migration was needed. The schema stays at v43, so no upgrade fixture applies. The V1-033 upgrade fixtures are not addressed here.

## 5. Gate check script: described, not created

`tools/backend_behaviour.sh` already exists, untracked; `ops` owns it. It is a dedicated-Postgres SQL proof runner that **refuses** to run against a Supabase dev stack, so I did not add a conflicting file.

**Proposed addition for `ops`.** Add an opt-in stage to `tools/ci_gates.sh`, run only when `LOCAL_SUPABASE_URL` points at a loopback stack, with these steps:

```
source "$STACK_ENV"     # LOCAL_SUPABASE_URL/ANON_KEY/SERVICE_ROLE_KEY, LOCAL_MAILPIT_URL
(cd supabase/functions && deno test -A account-deletion-worker/local_stack_integration_test.ts)
(cd app && PUB_CACHE=$HOME/.pub-cache flutter test --no-pub --timeout 300s \
    test/integration_local/restore_then_sync_local_supabase_test.dart)
```

It should fail if any test is reported as ignored or skipped while the env is set.

## Gates run (working tree)

### `flutter analyze --no-pub`

- **Files:**
  - `restore_backup_usecase.dart`
  - `test/core/backup/`
  - `delete_account_screen_test.dart`
  - `privacy_screen_deletion_test.dart`
  - `restore_then_sync_local_supabase_test.dart`
  - `lib/l10n/`
- **Result:** "No issues found!"
- The first run had one warning (`_children`, orphaned by my edit). I removed it before the re-run.

### `flutter test --no-pub -j 2 --timeout 240s`

Run over `test/core/backup/` (all of it), `delete_account_screen_test.dart` and every test that references a key I changed. The latter are:
- `privacy_screen_deletion_test.dart`
- `privacy_controls_contrast_test.dart`
- `restore_confirmation_cancel_surface_test.dart` and the others listed by the grep in `data/arb_tests.txt`.

**Results:**
- **First run:** `+335 -4`.
  - One failure was the decision 3.4 test in `delete_account_screen_test.dart`. This is the expected "before" for the `deleteAccountAcceptedBody` assertion: generated l10n had not yet been regenerated.
  - Three failures were in `privacy_screen_deletion_test.dart`. That file looked for the old literal Arabic button text «إلغاء الحذف».
- **Change to that test:**
  - It now finds the button via `lookupAppL10n(ar).privCancelDeletion`.
  - Two `findsNothing` checks still searched for the old literal «حسابك مجدول للحذف», which would now pass trivially. They now look for the new notice text «لن يُنفَّذ طلب حذف».
  - The file is not explicitly listed among my paths. I edited it only because it asserted the deletion strings I own. Its behavioural assertions are unchanged.
- **After `gen-l10n` and that fix:**
  - `delete_account_screen_test.dart`, `privacy_screen_deletion_test.dart` and `privacy_controls_contrast_test.dart` all pass.
  - The whole backup directory passed in the first run.

`PUB_CACHE=$HOME/.pub-cache flutter gen-l10n` was run after the last arb edit.

### `prepared_deletion_local_removal_test.dart` (core/session): UNVERIFIED in this run. Superseded: it passes 30/30 with `-j 1` at low load; see the follow-up section.

This file is not mine and I did not change it. In this run it failed with its own internal `TimeoutException after 0:00:05` at load average **~495**. Each run failed a different set of tests: 1, then 2, then 8. I attribute this to machine load, not to my change: `data_wipe_service.dart` is unchanged, and none of its assertions involve my code. It should be re-run on an idle machine or in CI.

### Local-stack test `sync_e2e_local_supabase_test.dart`

It fails at HEAD as well, for the harness reason given in item 3.

## Unverified

- The new copy has not been seen on a simulator or device.
- Not checked against a hosted project or CI.
- iOS queued-capture isolation on account switch (owned by `ai`).
- The "cloud tombstone becomes a conflict" path on **full apply**. It is a new-device restore whose backup holds a row that the cloud has since deleted. The fake-cloud test shows a conflict; the merge path does not hit it.

## Compatibility

- Backups v1–v4 restore as before on an empty device.
- On a device that already holds data, v<4 backups merge, and their missing `_minor` columns are set to NULL on rows where the backup wins (the existing sanitizer recomputes them).
- No schema, RPC or API change.
- An old app talking to a new server is unaffected.

## Changes needed in files I do not own

1. **Done in the follow-up.** **`app/lib/features/capture/services/transactions_backfill_service.dart`** (`ai`): on full apply, when the local row has `server_id IS NULL`, is not pending and its cloud copy is a tombstone, apply the tombstone locally (`status='ignored'`) instead of raising a conflict.
2. **`app/lib/features/settings/privacy_screen.dart`:** optional. The legacy pending card could link straight to "Delete my account and all my data". The copy is already correct.
3. **Done in the follow-up.** **`test/integration_local/local_device.dart` / `sync_e2e_local_supabase_test.dart`:** route `Device.open()` through a fence-admitted database (see item 3).
4. **`docs/legal/**`** (`ops`): already consistent. Wording to keep: "Deletion is final and cannot be undone or cancelled; it covers your account, its data, your cloud backups and your profile photo; some server steps can take a few minutes; a 30-day request from an earlier version will not be carried out."

## Owner actions

1. Deploy `account-deletion-worker`, `delete-account-immediate` and `_shared/storage_erasure.ts` at `9e19c3e4` or later. The v5 shape leaves profile photos behind (D1–D3 "before").
2. After that deploy, audit production `profile-photos` for objects whose owner is no longer in `auth.users`, and remove them. This is an owner action; nobody mutates production in this round.
3. Decide whether to drop the dormant `cancel_account_deletion` / `purge-scheduled-deletions` in a later release.

## Local stack lifecycle

- Started and stopped by me: project `qirsh_v1_closure`, ports 57321–57330.
- `frasaaaaa` and `qirsh_proof` were not touched.
- Torn down with `supabase stop --no-backup`, which also removes its volumes.
- The scratch copy `data/v5fns` was deleted.

---

## Follow-up (orchestrator extension): backfill fixes, sync e2e harness, deletion-test re-run

The orchestrator extended my paths to cover `transactions_backfill_service.dart`, `local_device.dart` and `sync_e2e_local_supabase_test.dart`.

**Disk and stack:** I checked `df -h /` before starting (19 GB free). I rebuilt the stack `qirsh_v1_closure` on the same ports (57321–57330), from a scratch copy of `supabase/` with all 135 migrations applied. It was torn down afterwards with `supabase stop --no-backup`, which also removes its volumes, and the scratch directory was deleted.

### Correction to section 1 (important)

The earlier local-stack runs of `restore_then_sync_local_supabase_test.dart` were run **without** `--dart-define=SUPABASE_URL/SUPABASE_ANON_KEY`.

- Without them `SupabaseConfig.isConfigured` is false, so the startup reconcile backfill returned `skippedGuest`.
- Those runs therefore exercised push and pull but **not the backfill**.
- **Change:** the suite now asserts `SupabaseConfig.isConfigured` in `setUpAll`, so it can no longer run in that degraded mode.
- **Fresh results, with the dart-defines:**
  - **Before** (HEAD `restore_backup_usecase.dart` and HEAD `transactions_backfill_service.dart` swapped in, then restored and checked with `cmp`): `+3 -7`. R1, R2, R3, R4, R6, R9 and R9b fail; R5, R7 and R8 pass.
  - **After** (working tree): `+10: All tests passed!` (R1–R9b).
  - Logs: `data/restore_local_before2.txt` and `data/restore_local_after2.txt`.

### (1) A backup row whose cloud copy was deleted on a new-device full restore: FIXED

File: `app/lib/features/capture/services/transactions_backfill_service.dart`, the `own`-identity branch.

**Cause.** A row reaches this branch with `server_id IS NULL`, not queued on the ledger outbox, and with a cloud copy carrying `deleted_at`. The service used to bind it as `conflict`. **Fix:**
- If the local row's `sync_status` is not `pending`, the service now applies the cloud deletion: `status='ignored'`, `updated_at=now`, bound to the cloud row, `synced`. This mirrors what `LedgerSyncService._processTombstone` does on pull.
- A row with a `pending` local change still becomes a conflict for the user.

**Second bug found on the same path, also fixed.** Re-binding to a row the outbox push had written compared `direction` and `transaction_type` using only the backfill's own mapping.
- The push derives direction from the type when none is stored (`LedgerPayloadCodec`). The backfill mapped a missing direction to `unknown`.
- So every restored row with no stored direction (any manual entry, for example) became a **false conflict** on a new-device restore, even when its money matched exactly. This is why R6 and R9's row A failed at HEAD.
- **Fix:** the comparison now accepts either the backfill's mapping or the push's (`LedgerPayloadCodec.serverDirection` / `serverTransactionType`). Money checks are unchanged.
- **Import added:** `ledger_payload.dart`.
- **Scope:** the edit is confined to the comparison and the tombstone branch. Insert payloads are unchanged. No UI files touched.

**Tests:** `app/test/features/capture/transactions_backfill_identity_test.dart`, fake backend.
- **Changed, because the owner's decision changes the behaviour:** the old test "tombstone → bound and flagged as a conflict" is now "takes the cloud deletion: not re-inserted, not resurrected, no conflict". It asserts the row is gone locally, `synced`, bound to the cloud row, and that there is exactly one cloud row.
  - Before the fix it failed (`Expected: empty, Actual: {t-A: 10.00}`).
  - After the fix it passes.
- **New:** "a row with a local change still waiting to be sent is a conflict, never silently deleted". It passes before and after; it guards the new condition.
- **New:** "a row with no stored direction is compared the way the outbox push wrote it". Before the fix it got `conflict` (fail); after the fix, `synced` (pass).
- **Local stack:** new tests in `restore_then_sync_local_supabase_test.dart`.
  - **R9.** Device 1 syncs A and B, takes a backup, deletes B and syncs. It then leaves the process, and a new admitted device does a full apply and turns Cloud on.
  - **R9b.** Same, but the first ledger pull after Cloud on is interrupted, so the backfill meets the tombstone first.
  - **Before:** both FAIL. B is resurrected locally and both A and B end up `conflict`.
  - **After:** both PASS. Device = cloud = A only, no conflict, and the cloud holds 2 rows (A plus B's tombstone; nothing re-inserted).
  - Logs: `data/r9_before.txt` and `data/r9_after.txt`.
- **Regression run:**
  - Command: `flutter test -j 2 --timeout 240s` over every `test/features/capture/*backfill*`, `test/core/backup/`, `test/core/sync/` and `startup_sync_reconcile_service_test.dart`.
  - Result: `+498: All tests passed!`
  - `flutter analyze` on the touched files: no issues.

### (2) Sync e2e harness on a fence-admitted database

**Pre-existing, not from this round.** `git diff 5dae2e2d d1212986 -- app/ supabase/` is empty. The only working-tree changes in sync, session or capture code are mine (backfill) and another specialist's `capture_notification_content.dart`.
- The harness was last changed in `b28bb001` (2026-10-02).
- The fence's `captureForDatabase`/`unbound` stop arrived later, in `2f414b15` (2026-10-24).
- So all 16 scenarios already failed at `5dae2e2d`, with `*DeliveryStopped:unbound`.
- This is established from history and the empty diff. I did not check out `5dae2e2d`, because checkouts are not allowed.

**Harness change:**
- **`local_device.dart`:** `Device.open()` now admits a fresh database for the signed-in user through `LedgerAdmissionFixture`, the real fence host. `close()` finishes the fixture. The fence admits one database per process, so opening a second device closes the previous one; this is documented in the code. The unused in-memory key store and its imports were removed.
- **`sync_e2e_local_supabase_test.dart`:** calls `openDevice()`, which wraps `Device.open()` and removes from the probe's request count only the `POST /rest/v1/rpc/mark_onboarding_completed` made by the admission sign-in. Every other request stays counted.
- No assertion was changed or removed.

**Real result:** the full suite, run with dart-defines on the local stack, gives `+10 -6` (it was `+0 -16`). CLEANUP reports 17 users removed and 0 user rows left. Log: `data/sync_e2e_after.txt`.
- **Pass:** S1, S2, S3, S3b, S4, S5, S6, S7, S10, S13.
- **S8 (stale owner).** The scenario switches to user B on A's admitted database. The fence now stops delivery outright (`AccountsDeliveryStopped:stale`, thrown) **before** anything is sent, so the test's expected path (push returns `pushed 0` and rows are parked `owner_mismatch`) is never reached.
  - Safety holds: R7 shows nothing reaches B or A, and A's intent is kept and delivered when A returns.
  - This is a **test expectation older than the fence**, not a product failure. Updating it is a decision for the test's owner; I did not loosen it.
- **S9 and S9b (two devices used side by side).** They fail with `connection was closed`, because device 1 is used after device 2 opens.
  - **Harness limitation:** one admitted database per process. Not a product finding.
  - Needs either a two-process harness or a design where devices take turns.
- **S11.** Asserts the server still has `chk_user_transactions_amount_positive` (i.e. 0102 not applied). The stack has `chk_user_transactions_amount_or_awaiting_fx` because 0102 is applied.
  - **Outdated assumption about server state** (0100–0102 are now active). Not product.
- **S12.** Asserts the server has no `accepted_by` (0100 deferred). 0100 is applied. Same outdated assumption.
- **S14.** `before.pushed` was expected to be 0 but was 1. A debug run showed:
  - the budget **was** parked correctly (`exact_money_transport_unverified`, nothing sent to `user_budgets`);
  - the one push was a `settings` row (`POST /rest/v1/user_settings`) that the admission sign-in queues on a fresh admitted database.
  - This is a harness side effect, not a product failure. I did not filter it, because the assertion counts pushed entities, not requests.

### (3) `prepared_deletion_local_removal_test.dart`, alone with `-j 1`

Load average 9.2 at start and 13.8 at end: `+30: All tests passed!` (`data/prepared_deletion_j1.txt`). The earlier failures were load timeouts.

### Changed-files summary for this follow-up

- `app/lib/features/capture/services/transactions_backfill_service.dart` (tombstone branch, direction/type comparison, one import)
- `app/test/features/capture/transactions_backfill_identity_test.dart`
- `app/test/integration_local/restore_then_sync_local_supabase_test.dart` (R9, R9b, `isConfigured` guard)
- `app/test/integration_local/local_device.dart`
- `app/test/integration_local/sync_e2e_local_supabase_test.dart`

**Run command for the local suites:**
```
flutter test --no-pub --dart-define=SUPABASE_URL=$LOCAL_SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$LOCAL_SUPABASE_ANON_KEY <file>
```

---

## Follow-up 2: skip/ignore manifest for D1–D4 (gate on `7cab5e8b`)

**Problem:** `tools/check_test_skips.mjs` failed with "UNEXPECTED deno ignored test" for D1–D4. These tests are ignored whenever no local stack is configured.

### Changes

- **`tools/test_skip_manifest.json`:**
  - New credential group `localSupabaseStack` = `LOCAL_SUPABASE_URL`, `LOCAL_SUPABASE_ANON_KEY`, `LOCAL_SUPABASE_SERVICE_ROLE_KEY`, `LOCAL_MAILPIT_URL`. These are a loopback stack's local keys, never production credentials.
  - Four `deno.expectedIgnored` entries, one per test (`nameContains` "D1 …" through "D4 …"), each with `group: localSupabaseStack`, `class: live-external`, `finding: V1-062`, `removeWhen: a local Supabase stack runs in CI`, and `mustRunWhenPrereq: true`.
  - So with all four variables set, a D-test that is still ignored FAILS the gate; a partly configured stack FAILS as `PARTIAL`; and a D-test missing from the output while no stack is configured FAILS as a stale entry.
- **`tools/check_test_skips.mjs`:** unchanged. The checker is not weakened.
- **`supabase/tests/skip_manifest_node_test.mjs`:**
  - The clean credential environment also blanks the four `LOCAL_*` variables.
  - Four new tests:
    - ignored with no stack configured → pass;
    - stack configured but still ignored → fail ("localSupabaseStack are PRESENT");
    - partly configured → fail (PARTIAL);
    - D4 missing while no stack is configured → fail (stale entry).
- **`account-deletion-worker/local_stack_integration_test.ts`:** comment only. The header pointed at a script that does not exist (`tools/local_backend_behaviour.sh`); it now points at this report. Test names are unchanged; `deno lint` and `deno fmt --check` are clean.

### Verification (run the way `tools/ci_gates.sh` runs it)

The environment had no `LOCAL_*` or `SUPABASE_*` variables set.

- `( cd supabase/functions && deno test --allow-all )`: `1058 passed | 0 failed | 6 ignored`. The six are the two live-Postgres claims plus D1–D4.
- `node --test --test-reporter=tap supabase/tests/*.mjs`: exit 0.
- `node tools/check_test_skips.mjs --node <tap> --deno <deno> --flutter app/test`:
  - **Before**, with HEAD's manifest via `SKIP_MANIFEST_PATH`: exit 1, four "UNEXPECTED deno ignored test" errors.
  - **After:** "skip/ignore manifest satisfied", exit 0. Totals: node 89 skips, deno 6 ignored, flutter 39 skip sites.
- `node --test supabase/tests/skip_manifest_node_test.mjs supabase/tests/ci_gates_contract_node_test.mjs`: 28 pass, 0 fail.
- `deno.lock` is unchanged.

### `tools/backend_behaviour.sh`: not changed

It is not a small addition:
- the script requires `BACKEND_PG_HOST` at the top;
- it refuses any cluster that is not dedicated to it, by design, because it drops and re-creates a cluster-wide role;
- it explicitly says never to point it at a Supabase dev stack.

A local-stack stage would need its own entry point and its own safety checks. That is `ops`' decision, so the commands are documented here instead.

### Local-stack gate: exact commands

All paths are relative to the worktree root.

```bash
S=<scratch>/stack                     # scratch COPY of supabase/ (config.toml, migrations, functions, templates)
# config.toml in the copy: project_id = "qirsh_v1_closure"; api 57321, db 57322, shadow 57330,
# pooler 57329, studio 57323, inbucket 57324, analytics 57327 (enabled = false), inspector 57328
supabase start --workdir "$S" -x studio,vector,logflare,imgproxy,postgres-meta,realtime
# write $S/stack.env (mode 600) from `supabase status --workdir "$S" -o env`:
#   LOCAL_SUPABASE_URL=API_URL  LOCAL_SUPABASE_ANON_KEY=ANON_KEY
#   LOCAL_SUPABASE_SERVICE_ROLE_KEY=SERVICE_ROLE_KEY  LOCAL_MAILPIT_URL=MAILPIT_URL
#   (LOCAL_SUPABASE_DB_URL=DB_URL, LOCAL_SUPABASE_JWT_SECRET=JWT_SECRET)
source "$S/stack.env"

# D1-D4 (decision 3.4): must report "4 passed", never "ignored"
( cd supabase/functions && deno test -A account-deletion-worker/local_stack_integration_test.ts )

# R1-R9b (decision 3.3, restore = merge; account switch R7/R8): must report "+10: All tests passed!"
( cd app && PUB_CACHE=$HOME/.pub-cache flutter test --no-pub --timeout 300s \
    --dart-define=SUPABASE_URL=$LOCAL_SUPABASE_URL \
    --dart-define=SUPABASE_ANON_KEY=$LOCAL_SUPABASE_ANON_KEY \
    test/integration_local/restore_then_sync_local_supabase_test.dart )

# Optional: the sync e2e suite (since Follow-up 3: "+14 ~2: All tests passed!"; S9/S9b NOT RUN)
( cd app && PUB_CACHE=$HOME/.pub-cache flutter test --no-pub --timeout 300s \
    --dart-define=SUPABASE_URL=$LOCAL_SUPABASE_URL \
    --dart-define=SUPABASE_ANON_KEY=$LOCAL_SUPABASE_ANON_KEY \
    test/integration_local/sync_e2e_local_supabase_test.dart )

supabase stop --workdir "$S" --no-backup   # removes the stack and its volumes
```

**If those commands run inside `ci_gates.sh` with the stack env sourced:** the `localSupabaseStack` group is present, so the skip checker requires D1–D4 to run. The Flutter suite asserts `SupabaseConfig.isConfigured`, so a run without the dart-defines fails instead of silently skipping the backfill.

---

## Follow-up 3: independent review findings SP-01, SP-02, SP-06, SP-08 (HEAD `98e8e56d`)

Source: `docs/releases/version-1/evidence/audits/T-review-platform-and-records.md`. The reviewer's two reproduction tests (`scratchpad/review-platform/keep/restore_merge_attack_test.dart`) are included as the first two new tests below. Nothing committed.

### How each restorable table records an intentional deletion

| Table | How a deletion is known on the device | Merge rule now |
|---|---|---|
| transactions | soft: `status='ignored'`, newer `updated_at` | device row deleted → stays deleted, even against a backup copy with a later timestamp (new guard) |
| accounts | soft: `deleted_at` | same guard |
| cards | soft: `deleted_at` (+ outbox delete) | same guard |
| sender_bank_mappings | soft: `deleted_at` + `updated_at` | same guard |
| budgets, goals, subscriptions, plans | soft: `deleted_at` (+ status) | device row always kept (no `updated_at` in the backup) |
| goal_contributions, bill_payments, plan_transaction_links | soft: `deleted_at` | device row always kept |
| categories | soft: `deleted_at`; no `updated_at` | device row always kept; matched by `key` |
| local_offer_savings | soft: `state='reversed'` | device row always kept |
| merchants | never deleted | device row kept; matched by `normalized_name` |
| achievements, streaks, user_settings | no user deletion | device row kept unless the backup is newer (settings, streak) |
| **merchant_category_map (saved rules)** | **nothing.** "Forget rule" and category deletion hard-delete the row; the only trace is a transient outbox intent and the cloud tombstone | **device is authoritative: backup rules are neither added nor applied on merge.** A merge cannot tell "removed after the backup" from "never here", so it does not guess. Full apply (a device with no records) still restores all rules. Rules saved in the cloud come back through rule sync when Cloud is on. |

Design choice: no migration. Recording rule deletions going forward would need a tombstone column (schema v44) and changes to the repository, which I do not own. The device-authoritative rule fixes every reported symptom without that:
- a resurrected rule can no longer outrank AI categorisation;
- a rule can no longer arrive un-queued to the cloud;
- a rule can no longer point at a category deleted on the device.

The trade-off: on a merge, a rule that exists only in the backup is not restored. The copy now says so.

### SP-02: choosing full apply

`_deviceHoldsFinancialData` (transactions, budgets, goals, subscriptions, plans) is replaced by `_deviceHoldsUserData`. It returns true if the device has any of the following:
- accounts, cards, transactions, budgets, goals, goal contributions, subscriptions, bill payments, plans, plan links, sender mappings or offer savings;
- a user-confirmed rule;
- a category whose `key` is not a `DatabaseSeed` key (a custom category).

Seeded catalog rows, learned merchants and automatic mappings, achievements, streak and settings do not count. A-7 makes a fresh install have zero accounts, and the onboarding restore check (`/onboarding/check`) runs before account setup, so a new phone still gets the full apply.

New behaviour: a device where the user already made an account (even an empty one) now merges. Its settings are kept when they are newer, and the backup's accounts join it.

### Updated merge-rule table (replaces the first two rows and the "Deleted on the device" row in section 1)

| Situation | Result |
|---|---|
| Device has no user record (no account, card, transaction, planning record, sender mapping, saved rule or custom category) | Full apply, exactly as before, settings and rules included. |
| Device holds any user record | Merge, per the section 1 table. |
| Deleted on the device (`deleted_at` set; a transaction `ignored`) | Stays deleted, **whatever the backup's timestamp**. |
| Saved merchant rule (merchant_category_map) on merge | The device's rules are kept exactly. Backup rules are not added and do not overwrite. |

**Copy (`rpConfirmBody`).** Two sentences changed in EN and AR (MSA, Western digits); `gen-l10n` was re-run.

EN now reads: "…the more recently edited copy is kept. Saved category rules for merchants stay as they are on this device; rules that are only in the backup are not added. On a device with no records yet (no accounts, transactions, plans, rules or custom categories), the whole backup is restored, settings and rules included. Cloud…"

AR: «وتبقى قواعد تصنيف التجار المحفوظة على هذا الجهاز كما هي، ولا تُضاف القواعد الموجودة في النسخة فقط. وعلى جهاز لا يحتوي على سجلات بعد (لا حسابات ولا عمليات ولا خطط ولا قواعد ولا فئات مخصصة) تُستعاد النسخة كاملة بما فيها الإعدادات والقواعد.»

### Tests: fail before, pass after

These are in `app/test/core/backup/restore_merge_rule_test.dart`. The "before" run used HEAD's `restore_backup_usecase.dart` (swapped in temporarily, then restored byte for byte) with the new tests. Logs: `data/fu3_before2.txt` and `data/fu3_after.txt`.

| Test | Before | After |
|---|---|---|
| SP-01: a saved rule removed after the backup stays removed (reviewer) | FAIL (`restaurants` came back) | pass |
| SP-01: rules of a category deleted after the backup do not come back, and no rule points at a deleted category | FAIL (the custom category's rule came back) | pass |
| SP-01: a rule changed after the backup keeps the newer choice | pass (guard) | pass |
| A device deletion is kept against a backup copy with a later timestamp (another clock) | FAIL (`confirmed`) | pass |
| SP-02: an account created after the backup on a device with no transactions is kept (reviewer) | FAIL (`['acc']`) | pass |
| SP-02: a custom category and a saved rule made after the backup on a device with no account or transaction are kept | FAIL (full apply wiped them) | pass |
| A device with no records of its own still takes the whole backup, settings included | pass (guard) | pass |
| The confirmation copy states the rule and the "no records" definition (EN and AR) | FAIL (text absent) | pass |

The file result is `+16: All tests passed!`.

### SP-08: delete-phase rollback coverage (`restore_recovery_test.dart`)

- **Full-apply destination.** It now opens with no account (A-7). `seedNewDevice` populates it with:
  - settings country `PRESERVE-ME`;
  - seeded categories marked server-backed (synced);
  - a learned merchant with an automatic mapping;
  - an unlocked achievement;
  - a streak.

  All 9 fault points are run, including `afterFirstDelete` and `afterSeveralDeletes`. Each must roll back to the identical full-database digest.
- **Non-vacuity.** Every fault case now asserts that the fault point was actually reached on that path (`reached`).
- **Merge path.** Unchanged: `seedRich` with 7 fault points. A new test proves a committed merge never reaches the delete phase: the callback sees `afterFirstInsert` but neither delete point, and every device transaction survives.
- **Results.** With SP-02 in place and the old destination (which had a seeded account), the two delete-phase cases failed, because the merge was taken and nothing was deleted. Now: `+20: All tests passed!`.

### SP-02 knock-on: existing tests updated to the decided behaviour (no assertion removed or loosened)

Each of these restored onto a destination that had a seeded test account and expected the full apply (settings country taken from the backup). Under SP-02 such a device merges. The destination is now a new device with no account, which is what the scenarios describe.

- `backup_device_transfer_test.dart`: the target device no longer gets `seedTestAccount`.
- `db_key_isolation_test.dart`: `openNew` (no account) for the destination in "restore makes ZERO key-store calls".
- `db_key_hygiene_test.dart`: `openNew` for the destinations in "legacy backup carrying db_encryption_key_ref…" and "user A's legacy key field…".
- `backup_key_state_atomicity_test.dart`: `openNewDevice` for the destinations in RB4 H-23 and H-20.
- `restore_sync_identity_entities_test.dart`, "new device (no records yet)".
  - **Before:** the device held an account and a card, which made it not a new device.
  - **Now:** the backup is taken with them, they are removed, and the full apply must rebind the identity of the synced seeded categories and settings.
  - Accounts and cards are no longer in that loop, because a full apply can no longer replace one (a device that has one merges, and the merge keeps identity; covered by the per-entity merge tests in the same file). New assertion: the card is restored.

Backup suites (`test/core/backup`, `test/features/backup`): `+316: All tests passed!` (`data/fu3_backup2.txt`).

### SP-06: sync e2e scenarios (`test/integration_local/sync_e2e_local_supabase_test.dart`)

Before (HEAD, local stack with dart-defines): `+10 -6` (S8, S9, S11, S12, S9b, S14), in `data/fu3_e2e_before.txt`.

| Scenario | Change | Why it is not a weakening |
|---|---|---|
| S8 stale owner | Under B, the accounts, ledger and planning pushes must each throw an `AccountFenceDeliveryCancellation` ending `:stale`. This replaces "returns pushed 0 and parks rows `owner_mismatch`". The ledger and planning outboxes must be **byte-identical** before and after. All the "nothing sent as B / B has nothing / A unchanged / A drains after returning" assertions are kept. | The fence (`2f414b15`) stops delivery as a whole before any request; per-row parking is no longer the mechanism. The same guarantees are asserted, and the outbox check is stricter (exact rows instead of a status). |
| S9, S9b two-device conflict | `skip: _twoDevicesNotRun` ("NOT RUN: two devices side by side need two processes…"), plus a manifest entry (count 2, `removeWhen` a two-process harness). | They cannot run in one process: the fence admits one database per process, so device 1 is closed when device 2 opens. They are reported as skipped/not run, never as passing. The conflict rules are covered in-process against the fake backend only (`conflict_resolver_test`, `planning_entities_sync_service_test`, `d_sync_fixes_*`): **not end-to-end.** |
| S11 awaiting-FX | Asserts the current server: `chk_user_transactions_amount_or_awaiting_fx` exists and `qirsh_server_capabilities` exists. The capability is verified on the first probe; both rows push (one POST each); the FX row is exact (amount 0, 50 USD). | 0102 is applied. The old apply/rollback dance cannot be reproduced: the 0102 rollback drops `qirsh_server_capabilities()`, which later migrations extended, and re-applying 0102 would not restore those keys. "Parked while the server lacks 0102" remains covered in-process (`ledger_outbox_correctness_test`), not end-to-end. |
| S12 sender mapping | The column `accepted_by` must exist (0100 applied). A user-confirmed mapping pushes and its remote `accepted_by` is NULL. | Same push, `synced` and row assertions. The column-absent check becomes a value check against the current schema. |
| S14 capabilities | Before saving the budget, the settings row that the admission sign-in queues is delivered (`parked 0`, outbox empty). Every budget assertion is unchanged. | It removes a harness side effect; it does not filter what is counted. |

After: `+14 ~2: All tests passed!`. The ~2 are S9 and S9b, NOT RUN. CLEANUP: 15 users removed, 0 rows left. Log: `data/fu3_e2e_after.txt`.

Restore suite R1–R9b on the same stack: `+10: All tests passed!` (`data/fu3_restore_local.txt`). Stack: `qirsh_v1_closure`, ports 57321–57330, analytics off, dart-defines present; `df -h /` showed 19 GiB free. It was then stopped with `--no-backup`: 0 containers and 0 volumes left, and the stack directory was deleted. `frasaaaaa` and `qirsh_proof` were not touched.

### Skip manifest

`tools/test_skip_manifest.json` has one new Flutter entry (S9/S9b, described above). Run as `ci_gates.sh` runs it (`--node <tap> --deno <out> --flutter app/test`, using my earlier node and deno outputs; neither side changed in this follow-up): `✓ skip/ignore manifest satisfied`. Before the entry was added, it reported 2 × "UNEXPECTED flutter skip". `node --test supabase/tests/skip_manifest_node_test.mjs`: 19/19 pass.

### Changes needed in files I do not own

- ~~`DriftMerchantCategoryRepository.userConfirmedCategoryFor` should require `categories.deleted_at IS NULL`.~~ Done (orchestrator granted the file), see below.
- Optional, owner decision: a rule tombstone (v44 `deleted_at` on `merchant_category_map`, with "Forget rule" and category deletion setting it instead of hard-deleting). That would let a merge restore backup-only rules safely.

### Suites run (working tree, shared with other specialists' uncommitted edits)

| Suite | Result |
|---|---|
| `test/core/backup` + `test/features/backup` | `+316: All tests passed!` |
| `test/architecture`, `test/core/sync`, `test/features/planning_sync`, `test/data`, `test/features/capture`, `test/l10n`, `test/features/settings`, `restore_confirmation_cancel_surface_test` | `+4333 ~2 -1` (`data/fu3_suites.txt`) |

- **The one failure is not in my area.** It is `capture_sync_service_test.dart` "V1-001 residuals: every not_completed case… changes no total" (a long declined message is kept as a transaction). It comes from the parser files changed in the working tree by another specialist (`app/lib/engine/parser/*`, uncommitted). I did not touch it.
- **`destructive_path_inventory_test`:** all 5 tests pass. The statement count for `restore_backup_usecase.dart` is unchanged at 18. My change adds no DELETE, DROP or wipe; the new `_deviceHoldsUserData` and `_deviceRowDeleted` are SELECTs.
- **`flutter analyze --no-pub`:** clean on `restore_backup_usecase.dart`, `lib/l10n`, `test/core/backup` and `test/integration_local`.

**Deleted-category rules (orchestrator extension).** `DriftMerchantCategoryRepository`: `userConfirmedCategoryFor`, `getUserConfirmedRules` (rules list, cloud backfill) and `getLearnedCategoryMap` (learned-map seed) now require `categories.deleted_at IS NULL`. Categorisation then falls through to shared learning, then to the AI category, without an error.
Test `app/test/data/merchant_rule_deleted_category_test.dart`: 2 tests, failing before (`'restaurants'` returned, rule outranked the AI) and passing after. Related rule/capture/categorisation suites plus `test/architecture`: `+675 ~1: All tests passed!`; analyze clean.

### SP-12 (re-review at `7dd6efa8`): the confirmation names the restore that applies

- **Code.**
  - `RestoreBackupUseCase.restoreWillMerge(db)` is a new static, read-only method. It holds the same check the restore itself uses (`_deviceHoldsUserData` now calls it).
  - The restore prompt is the only confirmation dialog; the backup screen opens it through `/backup/restore`. Before showing the dialog, it reads this decision and shows one text:
    - `rpConfirmBodyMerge` (merge): what is kept, what is added, that a deleted transaction is not brought back, and that rules that exist only in the backup are not added;
    - `rpConfirmBodyFull` (full): the backup is restored as it is, settings and rules included.
  - If the database cannot be read (only in tests without one), the dialog shows the existing text that describes both cases (`rpConfirmBody`).
  - EN and AR (MSA, Western digits); `gen-l10n` was re-run.
- **Timing.** Data can change between the dialog and the commit. Only one direction is plausible (the device gains a record, so the restore merges instead of applying in full), and it is the safe one.
- **Test.** New `app/test/features/onboarding/restore_confirmation_path_test.dart`, 4 cases (EN/AR × merge/full). Before: all 4 failed (the dialog showed the combined text). After: `+4`, all passing.
- **Existing test updated to the decided behaviour.** `restore_confirmation_cancel_surface_test` (fresh database) now expects `rpConfirmBodyFull`.
- **Suites.** Onboarding, visual_parity, backup screen, `large_text_overflow_test`, the tap-target test, `test/architecture` and `test/l10n`: `+1473 ~1: All tests passed!`. `flutter analyze` is clean.
