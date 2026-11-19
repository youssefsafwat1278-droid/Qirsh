import 'package:drift/drift.dart';

import '../../data/db/app_database.dart';
import '../../data/db/merchant_rule_history.dart';
import '../../data/repositories/drift_merchant_category_repository.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
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

enum _RuleAction { keep, write, remove, review }

/// The backup's latest word on one merchant, and what the restore does with it.
typedef _BackupEntry = ({
  String key,
  String merchant,
  String categoryKey,
  RuleVersion version,
  String at,
  double confidence,
  _RuleAction action,
});

/// Restore of saved category rules (`merchant_category_map` rows the user
/// confirmed). Rule ids are install-local, so a rule is matched by its
/// merchant key and its category by the category key.
///
/// Merge (the device already holds records). Per merchant the backup holds a
/// rule or a recorded removal (the newer of the two), and so does the device;
/// ONE precedence rule decides ([ruleVersionSupersedes], shared with the cloud
/// pull): the backup's version replaces the device's only when it is strictly
/// newer; otherwise the device's stands.
///  * backup rule newer than the device rule      -> the backup's rule;
///  * backup rule newer than the device's removal -> restored;
///  * backup removal newer than the device rule   -> the rule is removed, and
///    the removal keeps the backup's time;
///  * anything not newer                          -> the device is unchanged;
///  * backup removal, nothing on the device       -> recorded;
///  * backup rule, nothing on the device          -> restored, UNLESS a removal
///    here cannot be ruled out: the backup predates deletion history
///    (snapshot < v5), or this device's history does not reach back to the
///    rule's last change. Then it is the user's choice.
/// A rule that would be written but whose category is deleted on this device
/// is never attached to another category: a device rule is kept, otherwise it
/// is the user's choice. "The user's choice" is a row in
/// `merchant_rule_restore_choices`: not a rule, it categorises nothing.
///
/// Full apply (a device with no records): rules, tombstones, pending choices
/// and the history marker are written exactly as the backup holds them by the
/// generic table loop; a backup without history marks the history incomplete.
///
/// Cloud: nothing a restore writes is pushed blindly. Every restore resets the
/// rule pull cursor and re-arms the rule backfill, so the next rule sync reads
/// EVERY cloud rule again through the same precedence rule (a newer cloud
/// removal or rule wins; a newer device rule or removal is queued) and only
/// after that pull completes pushes the rules the cloud has never seen.
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
      if (c['category_key'] == leftOutCategoryKey) continue;
      keys.add(c['merchant_key'] as String);
    }
    return keys.length;
  }

  /// The backup's version of every merchant it knows: its rule or its
  /// recorded removal, whichever is newer (the removal on a tie).
  Future<Map<String, _BackupEntry>> _backupVersions(
      Map<String, Object?> tables) async {
    final merchants = {for (final r in _rows(tables, 'merchants')) r['id']: r};
    final hasCategories = tables['categories'] is List;
    final categories = {
      for (final r in _rows(tables, 'categories')) r['id']: r
    };
    final out = <String, _BackupEntry>{};
    for (final t in _rows(tables, 'merchant_rule_tombstones')) {
      final key = t['merchant_key'];
      final at = t['deleted_at'];
      if (key is! String || key.isEmpty || at is! String) continue;
      out[key] = (
        key: key,
        merchant: key,
        categoryKey: '${t['category_key'] ?? ''}',
        version: RuleVersion.removal(RuleVersion.parse(at)),
        at: at,
        confidence: 1,
        action: _RuleAction.keep,
      );
    }
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
      final at = '${r['updated_at'] ?? ''}';
      final version = RuleVersion.rule(categoryKey, RuleVersion.parse(at));
      if (!ruleVersionSupersedes(version, out[key]?.version)) continue;
      out[key] = (
        key: key,
        merchant: m?['raw_name'] as String? ?? key,
        categoryKey: categoryKey,
        version: version,
        at: at,
        confidence: (r['confidence'] as num?)?.toDouble() ?? 1,
        action: _RuleAction.keep,
      );
    }
    return out;
  }

  Future<List<_BackupEntry>> _classify(
      Map<String, Object?> tables, int schemaVersion) async {
    final history = await _one(
        'SELECT history_since FROM merchant_rule_history WHERE id = 1;',
        const []);
    final historySince = _ms(history?['history_since']);
    final legacy = schemaVersion < historySnapshotVersion;

    final result = <_BackupEntry>[];
    for (final b in (await _backupVersions(tables)).values) {
      final held = await deviceRuleVersion(_db, b.key);
      final newer = ruleVersionSupersedes(b.version, held);
      _RuleAction action;
      if (b.version.isRemoval) {
        action = newer ? _RuleAction.remove : _RuleAction.keep;
      } else if (!newer) {
        action = _RuleAction.keep;
      } else {
        final deviceCategory = await _one(
            'SELECT deleted_at FROM categories WHERE key = ? LIMIT 1;',
            [b.categoryKey]);
        // A category only in the backup is added by the merge before the
        // rules.
        final categoryLive =
            deviceCategory == null || deviceCategory['deleted_at'] == null;
        final changed = b.version.at?.millisecondsSinceEpoch;
        final covered = history == null ||
            (changed != null &&
                historySince != null &&
                changed >= historySince);
        if (held != null && !held.isRemoval) {
          action = categoryLive ? _RuleAction.write : _RuleAction.keep;
        } else if (!categoryLive ||
            (held != null && await merchantRuleAwaitsUser(_db, b.key))) {
          // A newer rule than the user's "Leave out" does not overturn that
          // decision silently: the user chooses again.
          action = _RuleAction.review;
        } else if (held == null && (legacy || !covered)) {
          // Nothing on record here, and a removal cannot be ruled out.
          action = _RuleAction.review;
        } else {
          action = _RuleAction.write;
        }
      }
      result.add((
        key: b.key,
        merchant: b.merchant,
        categoryKey: b.categoryKey,
        version: b.version,
        at: b.at,
        confidence: b.confidence,
        action: action,
      ));
    }
    return result;
  }

  /// The backup's own undecided choices that are still undecided here: the
  /// device holds neither a rule nor a removal at least as recent.
  Future<List<Map<String, dynamic>>> _incomingChoices(
      Map<String, Object?> tables) async {
    final out = <Map<String, dynamic>>[];
    for (final c in _rows(tables, 'merchant_rule_restore_choices')) {
      final key = c['merchant_key'];
      final category = c['category_key'];
      if (key is! String || category is! String) continue;
      final held = await deviceRuleVersion(_db, key);
      if (category == leftOutCategoryKey) {
        // The backup's record of a "Leave out": kept where this device also
        // holds the removal.
        if (held != null && held.isRemoval) out.add(c);
        continue;
      }
      if (held != null &&
          (!held.isRemoval ||
              !ruleVersionSupersedes(
                  RuleVersion.rule(
                      category, RuleVersion.parse(c['rule_updated_at'])),
                  held))) {
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
    await _reconcileWithCloudNext();
    if (!merge) {
      if (schemaVersion < historySnapshotVersion) {
        // The restored rules come from an install whose removals are unknown.
        await markMerchantRuleHistoryIncomplete(_db);
      }
      return;
    }
    final entries = await _classify(tables, schemaVersion);
    final choices = await _incomingChoices(tables);
    for (final r in entries) {
      switch (r.action) {
        case _RuleAction.keep:
          break;
        case _RuleAction.remove:
          await _remove(r.key, r.categoryKey, r.version.at!);
        case _RuleAction.write:
          if (!await _write(r.key, r.categoryKey, r.at, r.confidence)) {
            await _savePending(r.key, r.merchant, r.categoryKey, r.at);
          }
        case _RuleAction.review:
          await _savePending(r.key, r.merchant, r.categoryKey, r.at);
      }
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
  }

  /// The backup recorded a removal newer than what this device holds: the
  /// device's rule (if any) goes, and the removal is recorded with the
  /// backup's time, not the moment of this restore.
  Future<void> _remove(String key, String categoryKey, DateTime at) async {
    await DriftMerchantCategoryRepository(_db).forgetUserConfirmedRule(key);
    await setMerchantRuleTombstone(_db, key, categoryKey, at);
    await _dropQueuedIntent(key);
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
    await _dropQueuedIntent(key);
    return true;
  }

  /// A queued intent for this merchant describes the pre-restore rule or
  /// removal. Left in place it would be pushed BEFORE the pull and would make
  /// the pull skip the merchant; the next sync queues the restored state
  /// itself once it has been compared with the cloud.
  Future<void> _dropQueuedIntent(String key) => _db.customStatement(
      'DELETE FROM planning_sync_outbox '
      "WHERE entity_type = 'merchant_rule' AND entity_id = ?;",
      [key]);

  /// The next rule sync must compare EVERY cloud rule with what this restore
  /// left on the device before anything restored is pushed: forget how far
  /// the rule pull had read, and re-arm the push of rules the cloud has never
  /// seen (which runs only after a pull that completed). Both are rows in
  /// `sync_cursors`, so the precondition survives restarts and failed syncs.
  Future<void> _reconcileWithCloudNext() => _db.customStatement(
      "DELETE FROM sync_cursors WHERE entity = 'merchant_rules' "
      "OR entity LIKE 'merchant_rules_backfill:%';");

  /// The undecided rules, for Settings → Learned rules.
  Future<List<RuleRestoreChoice>> pending() async {
    final rows = await _db.customSelect(
        'SELECT merchant_key, raw_merchant, category_key '
        'FROM merchant_rule_restore_choices WHERE category_key != ? '
        'ORDER BY raw_merchant, merchant_key;',
        variables: [Variable.withString(leftOutCategoryKey)]).get();
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
  /// for the cloud like any rule the user makes). Leaving it out is a removal
  /// made now, like "Forget rule": it is recorded, so no later restore or pull
  /// of an older cloud copy brings the rule back, and it is queued on [queue]
  /// so the rule is removed in the cloud and on the user's other devices too.
  /// (Signed out, nothing can be queued; the recorded removal is then sent by
  /// the first pull that meets the older cloud rule.) A rule the user has made
  /// for the merchant since is left alone.
  Future<void> decide(
    String merchantKey, {
    required bool add,
    Future<void> Function(String rawMerchant, String categoryKey)? save,
    PlanningOutboxQueue? queue,
  }) =>
      _db.transaction(() async {
        final row = await _one(
            'SELECT raw_merchant, category_key, rule_updated_at FROM '
            'merchant_rule_restore_choices WHERE merchant_key = ?;',
            [merchantKey]);
        final categoryKey = row?['category_key'] as String?;
        if (categoryKey == null || categoryKey == leftOutCategoryKey) return;
        if (add) {
          if (!await _categoryLive(categoryKey)) {
            throw StateError('rule_category_missing');
          }
          final raw = row!['raw_merchant'] as String;
          final merchant = AppDatabase.normalizeMerchant(raw) == merchantKey
              ? raw
              : merchantKey;
          await (save ??
              (m, c) => DriftMerchantCategoryRepository(_db)
                  .confirmMerchantCategory(
                      rawMerchant: m,
                      categoryKey: c,
                      isUserConfirmed: true))(merchant, categoryKey);
        } else if ((await deviceRuleVersion(_db, merchantKey))?.isRemoval ??
            true) {
          // Later than the rule it declines, whatever clock stamped that.
          await setMerchantRuleTombstone(
              _db,
              merchantKey,
              categoryKey,
              await nextMerchantRuleTime(_db, merchantKey,
                  notBefore: RuleVersion.parse(row!['rule_updated_at'])));
          if (DriftMerchantCategoryRepository.isSyncableMerchantKey(
              merchantKey)) {
            await queue?.enqueueMerchantRule(PlanningSyncOperation.delete,
                merchantKey: merchantKey, categoryKey: categoryKey);
          }
        }
        await _db.customStatement(
            'DELETE FROM merchant_rule_restore_choices WHERE merchant_key = ?;',
            [merchantKey]);
        final held = await deviceRuleVersion(_db, merchantKey);
        if (!add && held != null && held.isRemoval) {
          await markMerchantRuleLeftOut(
              _db, merchantKey, held.at?.toIso8601String() ?? '');
        }
      });
}
