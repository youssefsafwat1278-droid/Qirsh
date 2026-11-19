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

/// The time of a removal made now: later than the rule it removes, whose
/// time may come from another clock (the cloud's, a backup's) that runs ahead
/// of this device's.
const _afterOld = "MAX($_now, COALESCE(strftime('%Y-%m-%dT%H:%M:%fZ', "
    "OLD.updated_at, '+0.001 seconds'), $_now))";

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
  // Triggers are dropped and created again on every open, so a change to a
  // trigger body reaches databases that already have the old one.
  // A saved rule is removed either by deleting its row or by handing the row
  // back to the catalog mapping (is_user_confirmed 1 -> 0).
  for (final (name, event, extra) in const [
    ('delete', 'DELETE', ''),
    ('demote', 'UPDATE OF is_user_confirmed', ' AND NEW.is_user_confirmed = 0'),
  ]) {
    await db.customStatement('DROP TRIGGER IF EXISTS rule_history_$name;');
    await db.customStatement('''
      CREATE TRIGGER rule_history_$name
      BEFORE $event ON merchant_category_map
      WHEN OLD.is_user_confirmed = 1$extra
      BEGIN
        INSERT OR REPLACE INTO merchant_rule_tombstones(
          merchant_key, category_key, deleted_at)
        SELECT m.normalized_name, COALESCE(c.key, ''), $_afterOld
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
    await db
        .customStatement('DROP TRIGGER IF EXISTS rule_history_saved_$name;');
    await db.customStatement('''
      CREATE TRIGGER rule_history_saved_$name
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
  await db.customStatement('DROP TRIGGER IF EXISTS rule_history_bound;');
  await db.customStatement('''
    CREATE TRIGGER rule_history_bound
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
  await db.customStatement('DROP TRIGGER IF EXISTS rule_history_wipe;');
  await db.customStatement('''
    CREATE TRIGGER rule_history_wipe
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

/// The six triggers above, for the v43 -> v44 postcondition.
const merchantRuleHistoryTriggers = {
  'rule_history_delete',
  'rule_history_demote',
  'rule_history_saved_insert',
  'rule_history_saved_confirm',
  'rule_history_bound',
  'rule_history_wipe',
};

/// One side's latest word on a merchant's saved rule: the rule
/// ([categoryKey] set) or its removal ([categoryKey] null), and when.
///
/// The sides are the device, a backup and the cloud. Times: a device rule's
/// `updated_at`, a device removal's `deleted_at`, the same two columns of a
/// backup, and for the cloud the row's server `updated_at` (when the cloud
/// received that rule or that removal). Once a device change has been pushed
/// or pulled, the device copy carries the cloud's time.
class RuleVersion {
  const RuleVersion.rule(String this.categoryKey, this.at);
  const RuleVersion.removal(this.at) : categoryKey = null;

  final String? categoryKey;
  final DateTime? at;

  bool get isRemoval => categoryKey == null;

  static DateTime? parse(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}

/// THE precedence rule for saved rules, used by restore, pull and backfill.
///
/// [incoming] (from a backup or the cloud) replaces what the device [held]
/// only when it is STRICTLY newer, compared in whole milliseconds; otherwise
/// the device's state stands (a tie keeps the device). With nothing held, the
/// incoming version is taken. An incoming version whose time cannot be read
/// never replaces anything; a held removal whose time cannot be read stands;
/// a held rule whose time cannot be read gives way.
///
/// Milliseconds because SQLite stamps a removal in ms and Dart a rule in µs:
/// a rule removed in the millisecond it was saved must read as removed.
bool ruleVersionSupersedes(RuleVersion incoming, RuleVersion? held) {
  if (held == null) return true;
  final a = incoming.at?.millisecondsSinceEpoch;
  final b = held.at?.millisecondsSinceEpoch;
  if (a == null) return false;
  if (b == null) return !held.isRemoval;
  return a > b;
}

/// What this device holds for [merchantKey]: its saved rule (on a category
/// that still exists), else its recorded removal, else null.
Future<RuleVersion?> deviceRuleVersion(
    AppDatabase db, String merchantKey) async {
  final key = [Variable.withString(merchantKey)];
  final rule = await db
      .customSelect(
          'SELECT r.updated_at, c.key AS category_key '
          'FROM merchant_category_map r '
          'JOIN merchants m ON m.id = r.merchant_id '
          'JOIN categories c ON c.id = r.category_id '
          'WHERE m.normalized_name = ? AND r.is_user_confirmed = 1 '
          'AND c.deleted_at IS NULL LIMIT 1;',
          variables: key)
      .getSingleOrNull();
  if (rule != null) {
    return RuleVersion.rule(rule.read<String>('category_key'),
        RuleVersion.parse(rule.read<String>('updated_at')));
  }
  final removal = await db
      .customSelect(
          'SELECT deleted_at FROM merchant_rule_tombstones '
          'WHERE merchant_key = ?;',
          variables: key)
      .getSingleOrNull();
  return removal == null
      ? null
      : RuleVersion.removal(
          RuleVersion.parse(removal.read<String>('deleted_at')));
}

/// The time for a change the user makes NOW to [merchantKey]'s rule: the
/// present, but always later than the version it replaces (the device's rule
/// or removal), whose time may come from a clock that runs ahead of this
/// device's. A newer manual edit therefore always reads as newer.
Future<DateTime> nextMerchantRuleTime(AppDatabase db, String merchantKey,
    {DateTime? notBefore}) async {
  var at = DateTime.now().toUtc();
  final rows = await db.customSelect(
      'SELECT r.updated_at AS t FROM merchant_category_map r '
      'JOIN merchants m ON m.id = r.merchant_id '
      'WHERE m.normalized_name = ?1 AND r.is_user_confirmed = 1 '
      'UNION ALL SELECT deleted_at FROM merchant_rule_tombstones '
      'WHERE merchant_key = ?1;',
      variables: [Variable.withString(merchantKey)]).get();
  for (final previous in [
    for (final r in rows) RuleVersion.parse(r.read<String>('t')),
    notBefore,
  ].nonNulls) {
    if (!at.isAfter(previous)) {
      at = previous.add(const Duration(milliseconds: 1));
    }
  }
  return at;
}

/// Stamps the saved rule of [merchantKey] with [at]: the time of the version
/// (backup or cloud) it now equals.
Future<void> setMerchantRuleTime(
        AppDatabase db, String merchantKey, DateTime at) =>
    db.customStatement(
        'UPDATE merchant_category_map SET updated_at = ? '
        'WHERE is_user_confirmed = 1 AND merchant_id = '
        '(SELECT id FROM merchants WHERE normalized_name = ?);',
        [at.toUtc().toIso8601String(), merchantKey]);

/// Records the removal of [merchantKey]'s saved rule with exactly the time
/// [at] of the version (backup or cloud) that removed it — not the present
/// moment, which the trigger stamps when the rule row goes.
Future<void> setMerchantRuleTombstone(
        AppDatabase db, String merchantKey, String categoryKey, DateTime at) =>
    db.customStatement(
        'INSERT OR REPLACE INTO merchant_rule_tombstones('
        'merchant_key, category_key, deleted_at) VALUES (?, ?, ?);',
        [merchantKey, categoryKey, at.toUtc().toIso8601String()]);

/// The user's "Leave out" of a restored rule is kept as a row of
/// `merchant_rule_restore_choices` with an EMPTY category key: it is not a
/// choice to show (see [MerchantRuleRestore.pending]), it travels in backups
/// with the other rows, the wipe clears it, and the trigger that clears the
/// merchant's removal when a rule is saved again clears it too.
const leftOutCategoryKey = '';

/// Marks [merchantKey]'s recorded removal as the user's "Leave out".
Future<void> markMerchantRuleLeftOut(
        AppDatabase db, String merchantKey, String at) =>
    offerMerchantRuleChoice(
        db, merchantKey, merchantKey, leftOutCategoryKey, at);

/// Whether a rule for [merchantKey] newer than the device's removal must go to
/// the user instead of being applied: the removal is the user's "Leave out",
/// or a rule for it already waits for the user's choice.
Future<bool> merchantRuleAwaitsUser(AppDatabase db, String merchantKey) async =>
    await db.customSelect(
        'SELECT 1 FROM merchant_rule_restore_choices WHERE merchant_key = ?;',
        variables: [Variable.withString(merchantKey)]).getSingleOrNull() !=
    null;

/// Puts [merchantKey]'s rule for [categoryKey], changed at [at], on the
/// user's list of rules to choose (Settings → Learned rules), replacing the
/// "Leave out" mark or an older waiting choice. It is not a rule and
/// categorises nothing until the user adds it; the removal stays recorded.
Future<void> offerMerchantRuleChoice(AppDatabase db, String merchantKey,
        String rawMerchant, String categoryKey, String at) =>
    db.customStatement(
        'INSERT OR REPLACE INTO merchant_rule_restore_choices('
        'merchant_key, raw_merchant, category_key, rule_updated_at) '
        'VALUES (?, ?, ?, ?);',
        [merchantKey, rawMerchant, categoryKey, at]);

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
