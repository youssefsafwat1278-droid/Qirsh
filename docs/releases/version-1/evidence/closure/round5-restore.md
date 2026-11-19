# Round 5: merge restore of category rules against cloud sync

Working tree on `release-readiness/v1` at `2f9931cb`, nothing committed, nothing deployed. Reviews answered: V Part B (R4R-01..07) and W (AR-08..10). Continues the interrupted partial work recorded in `round4-restore.md` ("Review fixes"); this file supersedes it where they differ. Synthetic data only.

## The precedence rule (written once: `ruleVersionSupersedes`, `app/lib/data/db/merchant_rule_history.dart`)

For one merchant key, every side holds either a **rule** or a **removal**, with a time: the device (`merchant_category_map.updated_at` / `merchant_rule_tombstones.deleted_at`), a backup (the same two columns), the cloud (the row's server `updated_at`). An incoming version (backup or cloud) replaces the device's only when it is **strictly newer, in whole milliseconds**; on a tie or when older, the device's version stands, and if it differs from the cloud row it is queued for the cloud. So the newest of {local edit, local removal, backup row, cloud row, cloud removal} wins, and a tie keeps the local one.

- Restore (`MerchantRuleRestore._classify`), the pull (`MerchantRuleSyncService._apply`) and the backfill (runs only after a completed pull, so every cloud row was first compared by the same rule) all call it.
- Pulled removals are recorded with the cloud's time, not "now". A same-category pull takes the cloud's time. After a push the device copy takes the time the cloud stored.
- A change the user makes now is stamped `max(now, previous + 1 ms)` (`nextMerchantRuleTime`, and the removal triggers), so a manual edit or removal is always newer than what it replaced, even when that came from a clock running ahead.
- One exception, for "Leave out" (below): a newer rule against the user's "Leave out" is not applied but goes back on the review list.

## Findings

| Finding | Fix | Test (status) |
|---|---|---|
| R4R-01 / AR-08..10: restored rule pushed over an unread removal; no push before a successful pull | (Correction, see "Review X" below: at `e5881120` this held for the backfill and restored rules only; queued user changes, including "Leave out", were still pushed before the pull.) Backfill only after a pull that completed; every restore deletes the rule pull cursor and the backfill markers (stored, survives restarts); restore drops queued intents for merchants it changed; the pull compares times and queues the newer device state | `merchant_rule_precedence_test.dart` "R4R-01 the pull fails once after a restore…", "R4R-01 the very first backfill also waits…" (pass) |
| AR-08 backup removal ignored when the device holds the old rule | A backup removal newer than the device rule removes it, with the backup's time | precedence tables "backup removal newer than device rule" (pass) |
| AR-09 older unread cloud change overwrites a restored newer edit | Same rule; the device's newer rule stands and is pushed | "AR-09 a restored newer edit is kept…" (pass) |
| AR-10 same-category pull keeps old time; pulled removal stamped "now" | Cloud time adopted in both cases | "AR-10 a pull of the same category…", "AR-10 a pulled removal is not re-stamped…" (pass) |
| R4R-02 "Leave out" and signed-out removals undone by a pull | "Leave out" is a removal made now: recorded, marked (a row of `merchant_rule_restore_choices` with an empty category key, never shown as a choice), and queued for the cloud. An older cloud rule does not bring it back and the removal is queued. A genuinely newer cloud rule (or newer backup rule) is NOT applied: it returns to the review list, the removal stays recorded | "R4R-02 / A4 Leave out while the cloud still holds the rule…", "R4R-02 a cloud rule genuinely newer than Leave out…", "R4R-02 the record of Leave out travels in a backup…", "R4R-02 Leave out while signed out, … clock that runs ahead…", "R4R-02 a backup rule newer than Leave out…", "R4R-02 / A3 a rule forgotten while signed out…" (pass) |
| R4R-03 "Leave all out" on one tap | Confirmation dialog with count and consequence; Cancel changes nothing | `rule_restore_review_screen_test.dart` "Leave all out does nothing until it is confirmed…" (EN, AR) and the large-text case (pass) |
| R4R-04 result dialog untested; nothing points to pending rules after "Not now"; count silently missing if `reviewCount` throws | Widget test of the real restore → result dialog → "Review rules". Settings tile subtitle showing the pending count: **outside my files, delivered as a patch** (below). If `reviewCount` throws, the merge confirmation still says in words that undecidable rules wait for a choice in Settings → Learned rules; left as is | `restore_result_rule_review_test.dart` (EN, AR, pass) |
| R4R-05 clock skew | `max(now, previous + 1 ms)` for local changes; synced copies carry the server's time. Remains: a backup or unsynced change from a device whose clock ran ahead can beat a later change made elsewhere (inherent to last-writer-wins, as for every other table) | precedence "within one side" and migration "a removal made now is later than the rule…" (pass) |
| R4R-06 postcondition checks tables only; trigger bodies frozen | Postcondition checks the four tables and six triggers; triggers dropped and recreated on every open | `merchant_rule_history_v44_migration_test.dart` (pass) |
| R4R-07 full apply keeps the rule cursor | Cursor reset on every restore | "R4R-07 a full apply makes the next sync read every cloud rule again…" (pass) |

## Before / after

A scratch harness written only against APIs that exist at `2f9931cb` (`scratchpad/round5/zz_round5_head_repro_test.dart`, not in the repo) ran on a clean `2f9931cb` worktree and on this tree:

| Reproduction | `2f9931cb` | this tree |
|---|---|---|
| R4R-01 / A1 failed pull after restore | FAIL (cloud `restaurants`, pushed back) | pass |
| R4R-02 / A4 Leave out, unread cloud rule | FAIL (rule back) | pass |
| R4R-02 / A3 signed-out removal | FAIL (rule back) | pass |
| AR-08 newer backup removal | FAIL (rule kept) | pass |
| AR-09 newer restored edit | FAIL (`restaurants`) | pass |
| AR-10 pulled removal time | FAIL (backup edit lost) | pass |
| AR-10 same-category pull time | FAIL (older backup won) | pass |
| R4R-03 one tap on Leave all out | FAIL (all removed) | pass |

Mutation: with the new "Leave out" guard in the pull disabled, the three pull-side "Leave out vs newer rule" tests fail; restored, they pass. R4R-07 has no HEAD reproduction (it uses the new test helpers); it passes here.

## Restore → sync → restore stability

Every row of the precedence tables (backup × device, cloud × device, backup × cloud) restores twice, syncs twice and checks device and cloud agree; "R4R-02 / A4" and "restore, sync, then a second device…" restore again after sync and check nothing changes and nothing is offered again.

## Legacy backups (format < 5, no deletion history)

A backup rule with nothing on the device is never added silently: it goes to the review list (Add / Leave out per rule, Add all / Leave all out with confirmation). A rule the device holds, or a removal the device recorded, is compared by the precedence rule. "Leave out" is durable across sync and later restores; only a later change to the rule (another device, newer backup) brings it back to the list, never straight into use.

## Commands and results (from `app/`)

- `PUB_CACHE=$HOME/.pub-cache flutter gen-l10n` (after the copy change), then `PUB_CACHE=$HOME/.pub-cache flutter analyze`: **No issues found!**
- `PUB_CACHE=$HOME/.pub-cache flutter test --no-pub -j 2 test/core/backup test/data test/features/settings test/features/planning_sync test/core/privacy test/architecture`: **+3360 ~2 -2**. The two failures are both in `test/architecture/head_completeness_test.dart` and come from the other agents' uncommitted files (`supabase/functions/process-ios-sms/meaning_gate.ts` / `parse.ts` -> untracked `completion_certainty.ts`; `app/test/engine/privacy/outbound_payload_test.dart` -> untracked `tools/acceptance/privacy_acceptance_expected.json`); none of my files is involved.
- Rule suites alone (`merchant_rule_precedence_test`, `merchant_rule_restore_test`, `rule_restore_review_screen_test`, `restore_result_rule_review_test`, `merchant_rule_history_v44_migration_test`, `merchant_rule_sync_service_test`, `restore_merge_rule_test`, `restore_confirmation_rule_count_test`, `backup_completeness_test`, `data_wipe_service_test`, `destructive_path_inventory_test`): **+176, all passed**.
- Before/after harness: `2f9931cb` **+0 -8**; this tree **+8**.

## Files changed

`app/lib/core/backup/merchant_rule_restore.dart`, `app/lib/data/db/merchant_rule_history.dart`, `app/lib/data/db/app_database.dart` (v44 postcondition), `app/lib/data/repositories/drift_merchant_category_repository.dart`, `app/lib/features/planning_sync/services/merchant_rule_sync_service.dart`, `app/lib/features/settings/learned_rules_screen.dart`, `app/lib/l10n/app_en.arb`, `app/lib/l10n/app_ar.arb` + generated `app_localizations*.dart`; tests `app/test/core/backup/merchant_rule_precedence_test.dart`, `fake_rule_cloud.dart`, `merchant_rule_restore_test.dart`, `rule_restore_review_screen_test.dart`, `restore_result_rule_review_test.dart`, `app/test/data/db/merchant_rule_history_v44_migration_test.dart`; docs `round4-restore.md` (placeholder → pointer here), this file. No new schema version and no new table: the "Leave out" mark is a row of the existing v44 `merchant_rule_restore_choices` with an empty category key. It is excluded from the review list and the confirmation count, travels in backups (imported where the device also holds the removal), is cleared by the existing trigger when a rule is saved again and by the wipe trigger. A first attempt with a separate table was dropped because it needed outside changes (backup coverage guard, wipe list, destructive-statement inventory).

## Outside-path patch

`/private/tmp/claude-501/-Users-luciq--claude-spares-spare-yEUVj2/1b6aaa41-9527-44a7-aa2c-8ab180862078/scratchpad/round5/restore-outside.patch`: `app/lib/features/settings/settings_screen.dart`, the "Learned rules" tile subtitle shows "N rules from your backup need your choice" while any wait (R4R-04 "Not now"). Checked with `git apply --check` and `flutter analyze` (0 issues) applied temporarily, then reverted. Not applied.

## Not verified

- No local Supabase stack run in this round (the integration file `restore_then_sync_local_supabase_test.dart` was edited by the previous implementer, whose stack result in `round4-restore.md` I did not reproduce); in-memory fake cloud only, with the server clock running ahead of the device.
- No device or simulator run; the whole Flutter suite was not run.
- The "Leave out" mark is imported by a merge restore only where the device also holds the removal; a full restore takes it as is.
- A rule waiting for a choice while the device holds NO removal (legacy backup, nothing here) is still replaced by a cloud rule for that merchant, as before: the cloud already holds it, so nothing is resurrected.
- A device on build 147 still applies cloud rules without comparing times.

---

# Review X (X-R1, X-R2): pull first, then push

Review X of `e5881120` (`docs/releases/version-1/evidence/audits/X-round5-review.md`) rejected restore on two S2 findings. Working tree on `d658dbce`, nothing committed.

**Correction.** The claim above "no push before a successful pull" was wrong at `e5881120`. It held for the backfill and for restored rules, but `MerchantRuleSyncService._run` pushed the outbox BEFORE the pull. The server's upsert has no time guard, so a queued "Leave out" (X-R1) or an older offline edit (X-R2, pre-existing) overwrote a newer change made on another device.

**Fix** (`app/lib/features/planning_sync/services/merchant_rule_sync_service.dart` only):
- Every run pulls first. A push happens only after a pull that completed in the same run; if the pull fails (any page), nothing is pushed and the queue is kept.
- The sign-out flush (`push()`) follows the same order: pull, then push (without the backfill).
- During the pull, each queued local change is compared with the cloud's version of its merchant by the one rule (`ruleVersionSupersedes`, the device's change carrying its own stamp). If the cloud's version is newer, the queued change is dropped from the outbox and never sent, and the cloud's version is taken by the normal path. For a losing "Leave out" that path is the existing exception: the newer cloud rule goes on the review list, it is neither applied nor removed. If the queued change is at least as recent, it stands and is pushed after the pull.
- No server change: `user_merchant_rules` has no conditional (updated_at-guarded) update, so none is used.

**Tests** (`app/test/core/backup/merchant_rule_precedence_test.dart`, with `fake_rule_cloud.dart` gaining `failFetchNumber`). All four failed on the tree before the fix and pass after:

| Test | Before | After |
|---|---|---|
| "X-R1 a queued Leave out is not pushed over a newer rule another device saved before this sync…" | FAIL: cloud `removed` | pass: cloud keeps `shopping`, device removed, merchant back on the list, outbox empty |
| "X-R2 an older queued edit does not overwrite another device's later edit; a newer queued edit still wins" | FAIL: `groceries` overwrote `shopping` | pass (both directions) |
| "no push unless the pull of the same run completed: a pull failing on page 2…" | FAIL: pushed in the failing run | pass |
| "the push-only flush (sign-out) also pulls first…" | FAIL: cloud `removed` | pass |

Two existing tests changed setup, not expectation of behaviour:
- "R4R-02 / A4": the cloud's copy is now stamped before the "Leave out" (it was written by the fake cloud's clock, which runs a month ahead of the device, so under pull-first it read as newer and went back on the list; that clock-ahead case is the separate signed-out test, which still passes).
- The page-2 test allows the one-time backfill to re-send, with the same values, the two rules the broken run had already read.

Still passing: restore→sync→restore (all precedence tables), R4R-01 (pull fails once after restore), "Leave out"→pull→restore ("the record of Leave out travels in a backup", "a backup rule newer than Leave out"), and the review-screen and result-dialog tests.

**Remaining limits.**
- A change written on another device between this run's pull and its push can still be overwritten (no server-side guard); the window is one run.
- Times compared across devices come from different clocks until a change has been through the cloud; a device clock far ahead or behind still decides a race (R4R-05).
- After an interrupted first pull, the one-time backfill re-sends rules the device already took from the cloud (same values).

**Commands** (from `app/`): `PUB_CACHE=$HOME/.pub-cache flutter analyze`, then `PUB_CACHE=$HOME/.pub-cache flutter test --no-pub -j 2 test/core/backup test/data test/features/settings test/features/planning_sync test/core/privacy test/architecture test/integration_local`. Results: analyze **No issues found!**; the full run gave **+3365 ~34 -1**, the one failure being `test/architecture/destructive_path_inventory_test.dart` counting the new outbox `DELETE` in `merchant_rule_sync_service.dart`. I recorded it in that inventory (count 1 → 2, with the reason) and re-ran the inventory and precedence tests: **+81, all passed**. (`~34` skips are `test/integration_local`, which needs a local stack; no stack was started.)

Files changed for review X: `merchant_rule_sync_service.dart`, `test/core/backup/merchant_rule_precedence_test.dart`, `test/core/backup/fake_rule_cloud.dart`, `test/architecture/destructive_path_inventory_test.dart` (outside my original list: inventory entry only), this file.
