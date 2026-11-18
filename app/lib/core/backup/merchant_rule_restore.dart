import 'package:drift/drift.dart';

import '../../data/db/app_database.dart';
import '../../data/db/merchant_rule_history.dart';
import '../../data/repositories/drift_merchant_category_repository.dart';
import '../utils/id_generator.dart';

/// A backup rule the restore could neither add nor drop safely.
class RuleRestoreChoice {
  const RuleRestoreChoice({
    required this.merchantKey,
    required this.merchant,
    required this.categoryKey,
    required this.canAdd,
  });

  final String merchantKey;
  final String merchant;
  final String categoryKey;

  /// False while the rule's category does not exist (deleted) on this device.
  final bool canAdd;
}

enum _RuleAction { keep, write, review }

typedef _BackupRule = ({
  String key,
  String merchant,
  String categoryKey,
  String updatedAt,
  double confidence,
  _RuleAction action,
});

/// Restore of saved category rules (`merchant_category_map` rows the user
/// confirmed). Rule ids are install-local, so a rule is matched by its
/// merchant key and its category by the category key.
///
/// Merge (the device already holds records), per merchant:
///  * rule only on the device                    -> kept, always;
///  * rule on both                               -> the more recently changed
///    one wins, the device on a tie;
///  * rule only in the backup, removed here at or after its last change
///    (a tombstone, see merchant_rule_history.dart) -> stays removed;
///  * rule only in the backup, its category deleted on this device
///                                               -> the user's choice;
///  * rule only in the backup, and either the backup predates deletion
///    history (snapshot < v5) or this device's history does not reach back to
///    the rule's last change                     -> the user's choice;
///  * otherwise                                  -> restored.
/// "The user's choice" is a row in `merchant_rule_restore_choices`: it is not a
/// rule and categorises nothing until the user adds it.
///
/// Full apply (a device with no records): rules, tombstones, pending choices
/// and the history marker are written exactly as the backup holds them by the
/// generic table loop; a backup without history marks the history incomplete.
///
/// Cloud: a restored rule is not pushed blindly. The next rule sync pulls
/// first (so a removal the cloud holds and this device has not seen wins) and
/// then pushes every rule the cloud did not just deliver — the one-time
/// backfill of MerchantRuleSyncService, which is re-armed here.
class MerchantRuleRestore {
  MerchantRuleRestore(this._db);

  final AppDatabase _db;

  /// First snapshot version that carries deletion history.
  static const historySnapshotVersion = 5;

  static const historyTables = {
    'merchant_rule_history',
    'merchant_rule_tombstones',
    'merchant_rule_restore_choices',
  };

  static List<Map<String, dynamic>> _rows(
          Map<String, Object?> tables, String table) =>
      [
        for (final r in (tables[table] as List?) ?? const [])
          Map<String, dynamic>.from(r as Map<dynamic, dynamic>),
      ];

  static int? _ms(Object? value) => value is String
      ? DateTime.tryParse(value)?.toUtc().millisecondsSinceEpoch
      : null;

  Future<Map<String, Object?>?> _one(String sql, List<String> args) async =>
      (await _db.customSelect(sql, variables: [
        for (final a in args) Variable.withString(a)
      ]).getSingleOrNull())
          ?.data;

  Future<Map<String, Object?>?> _deviceRule(String key) => _one(
      'SELECT r.updated_at, c.key AS category_key '
      'FROM merchant_category_map r '
      'JOIN merchants m ON m.id = r.merchant_id '
      'LEFT JOIN categories c ON c.id = r.category_id '
      'WHERE m.normalized_name = ? AND r.is_user_confirmed = 1 LIMIT 1;',
      [key]);

  Future<Map<String, Object?>?> _deviceTombstone(String key) => _one(
      'SELECT deleted_at FROM merchant_rule_tombstones WHERE merchant_key = ?;',
      [key]);

  Future<bool> _categoryLive(String key) async =>
      await _one(
          'SELECT id FROM categories WHERE key = ? AND deleted_at IS NULL '
          'LIMIT 1;',
          [key]) !=
      null;

  /// How many backup rules a MERGE of [tables] would leave for the user's
  /// choice. Read-only; the same classification the restore applies.
  Future<int> reviewCount(
      Map<String, Object?> tables, int schemaVersion) async {
    final keys = {
      for (final r in await _classify(tables, schemaVersion))
        if (r.action == _RuleAction.review) r.key,
    };
    for (final c in await _incomingChoices(tables)) {
      keys.add(c['merchant_key'] as String);
    }
    return keys.length;
  }

  Future<List<_BackupRule>> _classify(
      Map<String, Object?> tables, int schemaVersion) async {
    final merchants = {for (final r in _rows(tables, 'merchants')) r['id']: r};
    final hasCategories = tables['categories'] is List;
    final categories = {
      for (final r in _rows(tables, 'categories')) r['id']: r
    };
    final backupTombstones = {
      for (final r in _rows(tables, 'merchant_rule_tombstones'))
        r['merchant_key']: _ms(r['deleted_at']),
    };
    final history = await _one(
        'SELECT history_since FROM merchant_rule_history WHERE id = 1;',
        const []);
    final historySince = _ms(history?['history_since']);
    final legacy = schemaVersion < historySnapshotVersion;

    final result = <_BackupRule>[];
    for (final r in _rows(tables, 'merchant_category_map')) {
      if (r['is_user_confirmed'] != 1) continue;
      final m = merchants[r['merchant_id']];
      // A v2 backup carries no categories: its rules point at this install's.
      final c = categories[r['category_id']] ??
          (hasCategories
              ? null
              : await _one(
                  'SELECT key, deleted_at FROM categories WHERE id = ?;',
                  ['${r['category_id']}']));
      final key = m?['normalized_name'];
      final categoryKey = c?['key'];
      // A row without its merchant or category, or on a category deleted in
      // the backup itself, was not a working rule there.
      if (key is! String ||
          key.isEmpty ||
          categoryKey is! String ||
          c?['deleted_at'] != null) {
        continue;
      }
      final updatedAt = '${r['updated_at'] ?? ''}';
      final changed = _ms(updatedAt);
      final deviceCategory = await _one(
          'SELECT deleted_at FROM categories WHERE key = ? LIMIT 1;',
          [categoryKey]);
      // A category only in the backup is added by the merge before the rules.
      final categoryLive =
          deviceCategory == null || deviceCategory['deleted_at'] == null;
      final device = await _deviceRule(key);

      _RuleAction action;
      if (device != null) {
        final deviceChanged = _ms(device['updated_at']);
        final backupNewer = changed != null &&
            (deviceChanged == null || changed > deviceChanged);
        action =
            backupNewer && categoryLive && device['category_key'] != categoryKey
                ? _RuleAction.write
                : _RuleAction.keep;
      } else {
        final tombstone = await _deviceTombstone(key);
        final removedHere = _ms(tombstone?['deleted_at']);
        final removals = [removedHere, backupTombstones[key]].nonNulls;
        // Millisecond resolution: a removal is stamped by SQLite (ms), the
        // rule by Dart (µs), so "same millisecond" means removed afterwards.
        // A removal on record whose time (or the rule's) cannot be read counts.
        final removed =
            changed == null || (tombstone != null && removedHere == null)
                ? tombstone != null
                : removals.any((t) => t >= changed);
        final covered = history == null ||
            (changed != null &&
                historySince != null &&
                changed >= historySince);
        if (removed) {
          action = _RuleAction.keep;
        } else if (!categoryLive || legacy || !covered) {
          action = _RuleAction.review;
        } else {
          action = _RuleAction.write;
        }
      }
      result.add((
        key: key,
        merchant: m?['raw_name'] as String? ?? key,
        categoryKey: categoryKey,
        updatedAt: updatedAt,
        confidence: (r['confidence'] as num?)?.toDouble() ?? 1,
        action: action,
      ));
    }
    return result;
  }

  /// The backup's own undecided choices that are still undecided here.
  Future<List<Map<String, dynamic>>> _incomingChoices(
      Map<String, Object?> tables) async {
    final out = <Map<String, dynamic>>[];
    for (final c in _rows(tables, 'merchant_rule_restore_choices')) {
      final key = c['merchant_key'];
      if (key is! String || await _deviceRule(key) != null) continue;
      final tombstone = await _deviceTombstone(key);
      final removed = _ms(tombstone?['deleted_at']);
      final changed = _ms(c['rule_updated_at']);
      if (tombstone != null &&
          (removed == null || changed == null || removed >= changed)) {
        continue;
      }
      out.add(c);
    }
    return out;
  }

  Future<void> _savePending(
          String key, String merchant, String categoryKey, String updatedAt) =>
      _db.customStatement(
          'INSERT OR REPLACE INTO merchant_rule_restore_choices('
          'merchant_key, raw_merchant, category_key, rule_updated_at) '
          'VALUES (?, ?, ?, ?);',
          [key, merchant, categoryKey, updatedAt]);

  /// Runs inside the restore transaction, after the generic table loop (so the
  /// backup's categories and merchants are already on the device).
  Future<void> apply(Map<String, Object?> tables, int schemaVersion,
      {required bool merge}) async {
    if (!merge) {
      if (schemaVersion < historySnapshotVersion) {
        // The restored rules come from an install whose removals are unknown.
        await markMerchantRuleHistoryIncomplete(_db);
      }
      await _rearmCloudBackfill();
      return;
    }
    final rules = await _classify(tables, schemaVersion);
    final choices = await _incomingChoices(tables);
    // The backup's removals join this device's history, except where the
    // device holds a rule (a rule on the device is always kept).
    for (final t in _rows(tables, 'merchant_rule_tombstones')) {
      final key = t['merchant_key'];
      final deletedAt = t['deleted_at'];
      if (key is! String || deletedAt is! String) continue;
      if (await _deviceRule(key) != null) continue;
      await recordMerchantRuleTombstone(
          _db, key, '${t['category_key'] ?? ''}', deletedAt);
    }
    var written = false;
    for (final r in rules) {
      if (r.action == _RuleAction.keep) continue;
      if (r.action == _RuleAction.review ||
          !await _write(r.key, r.categoryKey, r.updatedAt, r.confidence)) {
        await _savePending(r.key, r.merchant, r.categoryKey, r.updatedAt);
        continue;
      }
      written = true;
    }
    for (final c in choices) {
      await _db.customStatement(
          'INSERT OR IGNORE INTO merchant_rule_restore_choices('
          'merchant_key, raw_merchant, category_key, rule_updated_at) '
          'VALUES (?, ?, ?, ?);',
          [
            c['merchant_key'],
            '${c['raw_merchant'] ?? c['merchant_key']}',
            '${c['category_key'] ?? ''}',
            '${c['rule_updated_at'] ?? ''}',
          ]);
    }
    if (written) await _rearmCloudBackfill();
  }

  /// Writes the backup's rule for [key] with the backup's own change time, so
  /// a repeated restore finds it unchanged. False when its merchant or live
  /// category is not on the device.
  Future<bool> _write(String key, String categoryKey, String updatedAt,
      double confidence) async {
    final merchant = await _one(
        'SELECT id FROM merchants WHERE normalized_name = ?;', [key]);
    final category = await _one(
        'SELECT id FROM categories WHERE key = ? AND deleted_at IS NULL;',
        [categoryKey]);
    if (merchant == null || category == null) return false;
    final merchantId = merchant['id'] as String;
    final existing = await _one(
        'SELECT id FROM merchant_category_map WHERE merchant_id = ?;',
        [merchantId]);
    if (existing == null) {
      await _db.customStatement(
          'INSERT INTO merchant_category_map(id, merchant_id, category_id, '
          'is_user_confirmed, confidence, updated_at) VALUES (?, ?, ?, 1, ?, ?);',
          [
            IdGenerator.next(),
            merchantId,
            category['id'],
            confidence,
            updatedAt
          ]);
    } else {
      await _db.customStatement(
          'UPDATE merchant_category_map SET category_id = ?, '
          'is_user_confirmed = 1, confidence = ?, updated_at = ? '
          'WHERE merchant_id = ?;',
          [category['id'], confidence, updatedAt, merchantId]);
    }
    // A queued intent for this merchant describes the pre-restore rule (or its
    // removal); the re-armed backfill queues the restored one after the pull.
    await _db.customStatement(
        'DELETE FROM planning_sync_outbox '
        "WHERE entity_type = 'merchant_rule' AND entity_id = ?;",
        [key]);
    return true;
  }

  Future<void> _rearmCloudBackfill() => _db.customStatement(
      "DELETE FROM sync_cursors WHERE entity LIKE 'merchant_rules_backfill:%';");

  /// The undecided rules, for Settings → Learned rules.
  Future<List<RuleRestoreChoice>> pending() async {
    final rows = await _db
        .customSelect('SELECT merchant_key, raw_merchant, category_key '
            'FROM merchant_rule_restore_choices '
            'ORDER BY raw_merchant, merchant_key;')
        .get();
    return [
      for (final r in rows)
        RuleRestoreChoice(
          merchantKey: r.read<String>('merchant_key'),
          merchant: r.read<String>('raw_merchant'),
          categoryKey: r.read<String>('category_key'),
          canAdd: await _categoryLive(r.read<String>('category_key')),
        ),
    ];
  }

  /// The user's choice for one undecided rule. Adding saves it through [save]
  /// (the caller's ordinary "remember for this merchant" path, so it is queued
  /// for the cloud like any rule the user makes). Leaving it out records a
  /// removal on this device, so no later restore offers or adds it again; a
  /// rule the user has made for the merchant since is left alone.
  Future<void> decide(
    String merchantKey, {
    required bool add,
    Future<void> Function(String rawMerchant, String categoryKey)? save,
  }) =>
      _db.transaction(() async {
        final row = await _one(
            'SELECT raw_merchant, category_key FROM '
            'merchant_rule_restore_choices WHERE merchant_key = ?;',
            [merchantKey]);
        if (row == null) return;
        final categoryKey = row['category_key'] as String;
        if (add) {
          if (!await _categoryLive(categoryKey)) {
            throw StateError('rule_category_missing');
          }
          final raw = row['raw_merchant'] as String;
          final merchant = AppDatabase.normalizeMerchant(raw) == merchantKey
              ? raw
              : merchantKey;
          await (save ??
              (m, c) => DriftMerchantCategoryRepository(_db)
                  .confirmMerchantCategory(
                      rawMerchant: m,
                      categoryKey: c,
                      isUserConfirmed: true))(merchant, categoryKey);
        } else if (await _deviceRule(merchantKey) == null) {
          await recordMerchantRuleTombstone(_db, merchantKey, categoryKey,
              DateTime.now().toUtc().toIso8601String());
        }
        await _db.customStatement(
            'DELETE FROM merchant_rule_restore_choices WHERE merchant_key = ?;',
            [merchantKey]);
      });
}
