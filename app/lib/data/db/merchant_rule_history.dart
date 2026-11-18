import 'package:drift/drift.dart';

import 'app_database.dart';

/// v44 — deletion history for saved category rules (`merchant_category_map`
/// rows with `is_user_confirmed = 1`), so a merge restore can tell "removed on
/// purpose" from "never here".
///
///  * `merchant_rule_tombstones`: one row per merchant whose saved rule the
///    user removed, and when. Written by triggers on `merchant_category_map`,
///    so EVERY removal is recorded whoever issues it (Forget rule, category
///    deletion, a deletion pulled from the cloud). Saving a rule for the
///    merchant again removes its tombstone: a merchant has a rule or a
///    tombstone, never both.
///  * `merchant_rule_restore_choices`: backup rules a restore could neither
///    add nor drop safely, waiting for the user's choice. They are not rules
///    and never categorise anything.
///  * `merchant_rule_history`: at most one row. Absent = this database has
///    recorded every removal since it was created. Present = removals before
///    `history_since` are unknown (a database upgraded from v43, a full restore
///    of a backup without history, or pruned tombstones).
///
/// Retention: the newest [merchantRuleTombstoneLimit] tombstones are kept. When
/// older ones are pruned, `history_since` moves to that moment, so a backup
/// rule older than it goes to the user's review instead of being trusted.
const int merchantRuleTombstoneLimit = 10000;

const _now = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')";

Future<void> createMerchantRuleHistory(AppDatabase db) async {
  await db.customStatement('''
    CREATE TABLE IF NOT EXISTS merchant_rule_history(
      id INTEGER PRIMARY KEY CHECK(id = 1),
      history_since TEXT NOT NULL
    );
  ''');
  await db.customStatement('''
    CREATE TABLE IF NOT EXISTS merchant_rule_tombstones(
      merchant_key TEXT PRIMARY KEY,
      category_key TEXT NOT NULL,
      deleted_at TEXT NOT NULL
    );
  ''');
  await db.customStatement('''
    CREATE TABLE IF NOT EXISTS merchant_rule_restore_choices(
      merchant_key TEXT PRIMARY KEY,
      raw_merchant TEXT NOT NULL,
      category_key TEXT NOT NULL,
      rule_updated_at TEXT NOT NULL
    );
  ''');
  // A saved rule is removed either by deleting its row or by handing the row
  // back to the catalog mapping (is_user_confirmed 1 -> 0).
  for (final (name, event, extra) in const [
    ('delete', 'DELETE', ''),
    ('demote', 'UPDATE OF is_user_confirmed', ' AND NEW.is_user_confirmed = 0'),
  ]) {
    await db.customStatement('''
      CREATE TRIGGER IF NOT EXISTS rule_history_$name
      BEFORE $event ON merchant_category_map
      WHEN OLD.is_user_confirmed = 1$extra
      BEGIN
        INSERT OR REPLACE INTO merchant_rule_tombstones(
          merchant_key, category_key, deleted_at)
        SELECT m.normalized_name, COALESCE(c.key, ''), $_now
        FROM merchants m LEFT JOIN categories c ON c.id = OLD.category_id
        WHERE m.id = OLD.merchant_id;
      END;
    ''');
  }
  // A rule saved again supersedes the removal and any pending choice.
  for (final (name, event, extra) in const [
    ('insert', 'INSERT', ''),
    (
      'confirm',
      'UPDATE OF is_user_confirmed',
      ' AND OLD.is_user_confirmed = 0'
    ),
  ]) {
    await db.customStatement('''
      CREATE TRIGGER IF NOT EXISTS rule_history_saved_$name
      AFTER $event ON merchant_category_map
      WHEN NEW.is_user_confirmed = 1$extra
      BEGIN
        DELETE FROM merchant_rule_tombstones WHERE merchant_key =
          (SELECT normalized_name FROM merchants WHERE id = NEW.merchant_id);
        DELETE FROM merchant_rule_restore_choices WHERE merchant_key =
          (SELECT normalized_name FROM merchants WHERE id = NEW.merchant_id);
      END;
    ''');
  }
  await db.customStatement('''
    CREATE TRIGGER IF NOT EXISTS rule_history_bound
    AFTER INSERT ON merchant_rule_tombstones
    WHEN (SELECT COUNT(*) FROM merchant_rule_tombstones) >
      $merchantRuleTombstoneLimit
    BEGIN
      INSERT OR REPLACE INTO merchant_rule_history(id, history_since)
      VALUES (1, $_now);
      DELETE FROM merchant_rule_tombstones WHERE merchant_key IN (
        SELECT merchant_key FROM merchant_rule_tombstones
        ORDER BY deleted_at DESC, merchant_key
        LIMIT -1 OFFSET $merchantRuleTombstoneLimit
      );
    END;
  ''');
  // "Delete all my data" / sign-out (DataWipeService) empties
  // merchant_category_map, which the triggers above record as removals, and
  // deletes user_settings last. The history is personal data (merchant names)
  // and those were not the user's removals: clear it with the settings row, so
  // the wipe is complete whatever order its table list is in.
  await db.customStatement('''
    CREATE TRIGGER IF NOT EXISTS rule_history_wipe
    AFTER DELETE ON user_settings
    BEGIN
      DELETE FROM merchant_rule_tombstones;
      DELETE FROM merchant_rule_restore_choices;
      DELETE FROM merchant_rule_history;
    END;
  ''');
}

/// Removals before now are unknown. [keepEarlier] leaves an existing marker
/// alone (the v43 -> v44 step, which may run again).
Future<void> markMerchantRuleHistoryIncomplete(AppDatabase db,
        {bool keepEarlier = false}) =>
    db.customStatement('INSERT OR ${keepEarlier ? 'IGNORE' : 'REPLACE'} INTO '
        'merchant_rule_history(id, history_since) VALUES (1, $_now);');

/// Records that the saved rule of [merchantKey] was removed at [deletedAt]
/// (ISO-8601). An existing later removal is kept.
Future<void> recordMerchantRuleTombstone(AppDatabase db, String merchantKey,
    String categoryKey, String deletedAt) async {
  final existing = await db.customSelect(
      'SELECT deleted_at FROM merchant_rule_tombstones WHERE merchant_key = ?;',
      variables: [Variable.withString(merchantKey)]).getSingleOrNull();
  final held = DateTime.tryParse(existing?.read<String>('deleted_at') ?? '');
  final incoming = DateTime.tryParse(deletedAt);
  if (incoming == null || (held != null && !incoming.isAfter(held))) return;
  await db.customStatement(
      'INSERT OR REPLACE INTO merchant_rule_tombstones('
      'merchant_key, category_key, deleted_at) VALUES (?, ?, ?);',
      [merchantKey, categoryKey, incoming.toUtc().toIso8601String()]);
}
