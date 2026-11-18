# Round 4: merge restore of saved category rules (`restore`)

Implementer model: `claude-fable-5-2` (Claude Fable 5.2), as stated in this session's system prompt. Working tree `release-readiness/v1`; nothing committed, staged, stashed or pushed. Synthetic data only.

Owner's instruction: "Complete merge restore for category rules. Restore missing rules, respect intentional deletions, and preserve newer manual edits. Test restore followed by sync and a repeated restore. For legacy backups that lack deletion history, make the ambiguity explicit and give the user a safe recovery choice. Do not silently discard a rule or resurrect one the user deleted."

## Outcome per requirement

| # | Requirement | Status |
|---|---|---|
| 1 | Record rule removals going forward; forward-only v43 → v44 with an upgrade test; history travels in the backup; bounded | DONE |
| 2 | Merge rule per merchant | DONE |
| 3 | Legacy ambiguity: listed, stored, user chooses add / leave out, per rule or all | DONE |
| 4 | Restore changes reach the cloud; a second device does not bring a removed rule back | DONE (one deliberate deviation in mechanism, below) |
| 5 | Idempotence; full apply restores rules and history as the backup holds them | DONE |
| 6 | SP-17 `hasCategoryForMerchant` ignores a deleted category | DONE |
| 7 | Confirmation and result copy, EN and AR | DONE |

Not done by me because the files are outside my paths (a ready patch is provided, see "Changes needed outside my paths"): listing the three new tables in `DataWipeService.wipedTables`, and five test files elsewhere that pin schema 43 / backup format 4.

## Design

The earlier implementer's direction (schema v44 with a tombstone table written by triggers) was kept; almost everything else was rewritten.

**Why triggers.** "Forget rule", category deletion (`DriftCategoryRepository.deleteCategory`, not my file) and a removal pulled from the cloud all end in a `DELETE` or a demotion (`is_user_confirmed` 1 → 0, when the row goes back to the catalog mapping) on `merchant_category_map`. Triggers on that table record every one of them, including any future path.

**Schema v44** (`app/lib/data/db/merchant_rule_history.dart`, additive; no existing row is read or changed):

- `merchant_rule_tombstones(merchant_key PK, category_key, deleted_at)`: one row per merchant whose saved rule was removed. Saving a rule for the merchant again deletes its row, so a merchant has a rule or a tombstone, never both.
- `merchant_rule_restore_choices(merchant_key PK, raw_merchant, category_key, rule_updated_at)`: backup rules waiting for the user's choice. Not rules; they categorise nothing.
- `merchant_rule_history(id = 1, history_since)`: at most one row. Absent means this database has recorded every removal since it was created. Present means removals before `history_since` are unknown.
- "When a rule was last changed" already exists (`merchant_category_map.updated_at`). A rule pulled from the cloud now takes the cloud's `updated_at` rather than the moment of the pull.

**No removal is invented for the past.** The v43 → v44 step only writes the marker row (`history_since` = upgrade time) on a database that already existed. A new install has no marker.

**Retention.** The newest 10000 tombstones are kept (`merchantRuleTombstoneLimit`). When older ones are pruned, `history_since` moves to that moment, so an older backup rule goes to the user's review instead of being trusted.

**Dropped from the earlier partial work:** the `sync_pending` column and the pre-push flush in the sync service, the `decision` column (a decision is recorded as the rule itself or as a tombstone), the `createdAt` plumbing through `RestorePlan`, and the change to `_categoryIdByKey`.

### Merge rule (device already holds records), per merchant

| Situation | Result |
|---|---|
| Rule only on the device | Kept, always (also when the backup recorded a later removal of it) |
| Rule on both | The more recently changed wins; the device on a tie. If the backup wins but its category is deleted on this device, the device rule is kept |
| Rule only in the backup; a removal here (or recorded in the backup) at or after the rule's last change | Stays removed. Compared at millisecond resolution: SQLite stamps the removal in ms, Dart the rule in µs |
| Rule only in the backup; removed here earlier than the rule's last change (saved again on another phone) | Restored |
| Rule only in the backup; its category is deleted on this device | User's choice; "Add" is disabled while the category does not exist. Never attached to another category |
| Rule only in the backup; backup format < 5 (no deletion history) | User's choice |
| Rule only in the backup; format 5, but the rule's last change is older than this device's `history_since` | User's choice |
| Rule only in the backup; otherwise | Restored, with the backup's change time |
| A backup row without its merchant or category, or on a category deleted in the backup itself | Ignored: it was not a working rule in the source |
| Removals recorded in the backup | Joined to this device's history, except where the device holds a rule |
| Undecided rules carried in the backup | Stay undecided here unless the device has a rule or a later removal |

Full apply (a device with no records): rules, tombstones, undecided rules and the marker are written exactly as the backup holds them (the generic table loop). A backup without history marks the history as starting now. A device that holds only tombstones or undecided rules now counts as holding records and merges, so they are not thrown away.

### User's choice

- Confirmation dialog: when the restore will merge, a line states how many rules will wait for a choice (read-only, same classification the restore applies).
- After the restore: a dialog with the count and the explanation, "Not now" / "Review rules".
- Settings → Learned rules: the list (merchant, category), "Add" / "Leave out" per rule and "Add all" / "Leave all out". Stored in the database, so it survives a restart and travels in the next backup.
- "Add" saves the rule through the ordinary "remember" path (queued for the cloud, on-device model updated). "Leave out" records a removal on this device; later restores do not ask again. A rule the user makes for the merchant meanwhile supersedes the pending choice.

### Cloud (no server migration, no Edge Function change)

The cloud can already carry a rule removal: `user_merchant_rules.deleted_at` (migration `20261116180000`). No server change is needed.

Deliberate deviation from "queue it like a user's own change": a rule written by a restore is **not** put in the outbox. Push runs before pull, so a queued upsert would overwrite a removal that another device made and this device has not pulled yet, and bring the rule back everywhere. Instead the restore deletes the per-account `merchant_rules_backfill:` marker (and any stale queued intent for a merchant it rewrote). The next rule sync then pulls first, and the existing backfill pushes every rule the cloud did not just deliver. Rules added from the review list are the user's own action and are queued normally.

What happens between two devices:

- Device A removes a rule and syncs. Device B pulls the removal: its rule is removed and a tombstone is recorded, also when B never held the rule. A backup restored on B later does not bring it back.
- B restores a backup before it has pulled A's removal: the rule appears on B until the next sync, which pulls the removal first and removes it. It is not pushed back.
- Conflicts stay server-arrival last-writer-wins, as before.

Limits that remain (all existed before, none introduced here):

- A removal made while signed out is not queued (the outbox is auth-gated), so the cloud is not told.
- "Leave out" is recorded on this device only; it is not sent as a removal, because the cloud may hold that rule legitimately from another device.
- The cloud's `updated_at` is the arrival time, not the edit time. A client-supplied change time (new column, compared on upsert) would make cross-device ordering exact; it is not required for the behaviour above.
- A device still on build 147 hard-deletes on pull without a tombstone, so its own merge restore keeps the build-147 behaviour.

## Compatibility with build 147 (`b6fc0dad`)

- **Device database:** v44 is forward-only. Build 147 cannot open a v44 database (fails closed, `UnsupportedDatabaseVersionException`). No downgrade path, as for every earlier bump.
- **Backup written by this build (format 5), restored on build 147:** refused before any change with "backup from a newer app" (`restore_preparation.dart:30` and `restore_backup_usecase.dart:105` at `b6fc0dad`). Consequence: once a user's phone updates, its next backup is format 5, and another phone still on build 147 must update before it can restore it.
- **Backup written by build 147 (format 4), restored on this build:** supported. Merge: backup-only rules go to the user's choice. Full apply: every rule is restored and the history is marked as starting now.
- **Server:** unchanged. Both builds read and write `user_merchant_rules` the same way.

## Files changed

Production:

- `app/lib/data/db/merchant_rule_history.dart` (new): tables, triggers, helpers.
- `app/lib/data/db/app_database.dart`: schema 44, the v43 → v44 step, unconditional creation.
- `app/lib/core/backup/merchant_rule_restore.dart` (new): classification, merge, review list, decision.
- `app/lib/core/backup/restore_backup_usecase.dart`: calls it; history tables in the delete/restore order; format 5.
- `app/lib/core/backup/backup_snapshot_builder.dart`, `restore_compatibility.dart`: format 5, three tables.
- `app/lib/data/repositories/drift_merchant_category_repository.dart`: SP-17.
- `app/lib/features/planning_sync/services/merchant_rule_sync_service.dart`: a pulled removal is recorded; a pulled rule takes the cloud's change time.
- `app/lib/features/settings/learned_rules_screen.dart`, `app/lib/features/onboarding/restore_prompt_screen.dart`: review list, count, result dialog.
- `app/lib/l10n/app_en.arb`, `app_ar.arb` (+ generated): 8 new keys (`lrRestore*`), `rpConfirmBodyMerge` and `rpConfirmBody` rewritten. Arabic is MSA with Western digits.
- `tools/check_arch_guard.sh`, `app/CLAUDE.md`: schema number 44 only.

Tests added:

- `app/test/core/backup/merchant_rule_restore_test.dart` (29 tests): every row of the merge rule, ambiguity, idempotence, full apply, the verified pipeline, restore → sync → pull over an in-memory cloud, copy.
- `app/test/data/db/merchant_rule_history_v44_migration_test.dart` (9): upgrade from a v43 shape, new install, every removal path, retention, wipe.
- `app/test/core/backup/rule_restore_review_screen_test.dart` (6): the review list in EN and AR, at 2× text on 320×568.
- `app/test/core/backup/restore_confirmation_rule_count_test.dart` (4): the count in the confirmation.
- `app/test/integration_local/restore_then_sync_local_supabase_test.dart`: RR1–RR3 on a real local stack.
- `app/test/data/merchant_rule_deleted_category_test.dart`: SP-17.

## Existing expectations changed, and why

| File | Change | Reason |
|---|---|---|
| `test/core/backup/restore_merge_rule_test.dart` | Confirmation-copy test and a comment | The sentence "rules that are only in the backup are not added" is no longer true |
| `test/features/onboarding/restore_confirmation_path_test.dart` | Pinned merge phrases, EN and AR | Same copy change (requirement 7) |
| `test/core/backup/backup_test.dart`, `exact_backup_roundtrip_test.dart`, `restore_compatibility_test.dart` | Format 4 → 5 | Backup format bump |
| `test/architecture/coupons_isolation_test.dart` | `currentSchemaVersion = 4` → `5` | Same |
| `test/architecture/report_ads_guards_test.dart` | Schema pin 43 → 44 | Schema bump |
| `test/architecture/destructive_path_inventory_test.dart` | Two new entries with audit text: `merchant_rule_restore.dart` (3), `merchant_rule_history.dart` (6). `restore_backup_usecase.dart` stays within 18 | New statements, none deletes a rule or a financial row |
| `test/data/**` (12 files) | Schema pin 43 → 44; `migration_data_survival_test` range 31..44, 13 steps; `local_read_replica_test` "foreign" version 44 → 45 | Schema bump |

No assertion was removed or loosened and no test was skipped.

## Fails before, passes after

`before_probe_test.dart` (four expectations written only against API that existed before) was run against a `git archive` export of `HEAD` (`ca9719ff`, which does not contain this work) and against the working tree:

- HEAD export: `+0 -4`. A backup-only rule is not restored (`Expected: 'restaurants'  Actual: <null>`); `hasCategoryForMerchant` is true for a deleted category; no removal is recorded; the copy lacks the sentence.
- Working tree: `+4: All tests passed!`

The new test files themselves cannot compile against `HEAD` (they import the new files).

## Commands and results (working tree)

All from `app/` with `PUB_CACHE=$HOME/.pub-cache`.

| Command | Result |
|---|---|
| `flutter analyze --no-pub` (whole app) | 1 warning, not in my files: `test/features/capture/follow_up6_final_effect_test.dart:145` `unused_element_parameter` (another implementer's new file). My files: 0 issues |
| `flutter test --no-pub -j 2 test/core/backup` | `+342: All tests passed!` |
| `flutter test --no-pub -j 2 test/data` | `+1011: All tests passed!` |
| `flutter test --no-pub -j 2 test/architecture` | `+540 ~1 -1`: the one failure is `head_completeness_test.dart` (another implementer's uncommitted Deno fixture, see "Not verified"); the destructive inventory and the two updated pins pass |
| `flutter test … test/l10n test/features/settings/learned_rules_*_test.dart test/features/onboarding/restore_* test/features/common/large_text_overflow_test.dart test/architecture/public_copy_truthfulness_test.dart …` | all passed except the wipe classification test below |
| `bash tools/check_arch_guard.sh` | `ARCH GUARD PASS` |
| `flutter gen-l10n` | run; generated files updated |
| Drift codegen | not needed: the schema is hand-written SQL, no `*.g.dart` is tracked |

Local stack: scratch copy of `supabase/`, project `qirsh_v1_round4`, API 56321, DB 56322 (shadow 56330, pooler 56329, studio 56323, inbucket 56324, analytics off, inspector 56328), started with `-x studio,vector,logflare,imgproxy,postgres-meta,realtime,edge-runtime`, all migrations applied. With `--dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON_KEY=…`:

- `test/integration_local/restore_then_sync_local_supabase_test.dart`: `+13: All tests passed!` (R1–R9b unchanged, plus RR1–RR3).
- `test/integration_local/sync_e2e_local_supabase_test.dart`: `+14 ~2: All tests passed!` (same as before).

The stack was stopped with `supabase stop --no-backup`; no `round4` container or volume remains; `frasaaaaa` and `qirsh_proof` were not touched. Disk free stayed at 18–19 GB.

## Changes needed outside my paths

Ready patch (passes `git apply --check`): `/private/tmp/claude-501/-Users-luciq--claude-spares-spare-yEUVj2/1b6aaa41-9527-44a7-aa2c-8ab180862078/scratchpad/restore/patch/round4-restore-outside-paths.patch`

1. `app/lib/core/privacy/data_wipe_service.dart`: add `'merchant_rule_tombstones'`, `'merchant_rule_restore_choices'`, `'merchant_rule_history'` to `wipedTables`, after `'merchant_category_map'`. Until then `test/core/privacy/data_wipe_service_test.dart` "every schema table is classified as wiped or intentionally preserved" **fails** (it requires every table to be listed). The wipe itself is already complete: a trigger clears the three tables when the wipe deletes `user_settings`, proven by `merchant_rule_history_v44_migration_test.dart` ('"delete all my data" leaves no rule history behind').
2. Schema pin 43 → 44 in `test/core/session/replica_recovery_settings_seed_test.dart:151`, `test/core/startup/startup_deferral_test.dart:68`, `test/features/coupons/coupon_cache_test.dart:71,98,123,364`, `test/performance/schema_v29_migration_test.dart:58,79,91,122`.
3. Backup format pin 4 → 5 in `test/performance/backup_streaming_plaintext_test.dart:74`.

I ran those five test files: every failure is on exactly the pinned line (11 assertions). I did not run them with the patch applied.

## Not verified

- The result dialog after a committed restore ("Review rules") has no widget test; the confirmation count, the review list and the logic behind them do.
- No device or simulator run; no real backup envelope (encrypted) round trip beyond the existing suites.
- The whole Flutter suite was not run (shared machine); only the suites named above.
- `test/architecture/head_completeness_test.dart` fails on another implementer's uncommitted Deno fixture (`sms_redaction_head_diff_test.ts`); unrelated to this work.
- A replica rebootstrap (WP-7) starts a new database, whose history is "complete" from its creation; removals made on the old replica reach it only through the cloud.
