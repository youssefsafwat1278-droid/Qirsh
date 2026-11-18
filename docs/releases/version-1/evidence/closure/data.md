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
