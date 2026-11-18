// Round 4 — merge restore of saved category rules ("Remember for this
// merchant"). Owner: "Restore missing rules, respect intentional deletions,
// and preserve newer manual edits. Test restore followed by sync and a
// repeated restore. For legacy backups that lack deletion history, make the
// ambiguity explicit and give the user a safe recovery choice. Do not silently
// discard a rule or resurrect one the user deleted."
//
// Real restore use case, snapshot builder, rule repository, category
// repository, planning outbox and rule sync service over an in-memory cloud.
// Synthetic data only.
import 'dart:convert';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/merchant_rule_restore.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/core/backup/restore_preparation.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/merchant_rule_history.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/merchant_rule_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../features/capture/ledger_admission_fixture.dart';
import 'fake_ledger_cloud.dart';
import 'restore_sync_device.dart';

/// In-memory `user_merchant_rules` for one user: one row per merchant key,
/// server-owned `updated_at`, tombstones instead of deletes.
class _RuleCloud implements MerchantRuleRemote {
  final rows = <String, Map<String, dynamic>>{};
  final pushedKeys = <String>[];
  var _clock = 0;

  String _tick() => DateTime.utc(2027, 1, 1)
      .add(Duration(seconds: ++_clock))
      .toIso8601String();

  @override
  Future<List<Map<String, dynamic>>> upsert(Map<String, dynamic> row) async {
    final key = row['merchant_key'] as String;
    pushedKeys.add(key);
    rows[key] = {
      'id': rows[key]?['id'] ?? 'srv-${rows.length + 1}',
      'merchant_key': key,
      'category_key': row['category_key'],
      'deleted_at': row['deleted_at'],
      'updated_at': _tick(),
    };
    return [Map.of(rows[key]!)];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
      {required SyncCursor after, int limit = 200}) async {
    final sorted = rows.values.toList()
      ..sort((a, b) =>
          (a['updated_at'] as String).compareTo(b['updated_at'] as String));
    return sorted
        .where((r) =>
            after.id.isEmpty ||
            normalizeCursorTimestamp(r['updated_at'])
                    .compareTo(after.updatedAt) >
                0)
        .take(limit)
        .map(Map<String, dynamic>.from)
        .toList();
  }

  /// A write made by another device of the same user.
  void otherDevice(String key, String category, {String? deletedAt}) {
    rows[key] = {
      'id': rows[key]?['id'] ?? 'srv-${rows.length + 1}',
      'merchant_key': key,
      'category_key': category,
      'deleted_at': deletedAt,
      'updated_at': _tick(),
    };
  }

  /// Live rules: merchant key -> category key.
  Map<String, Object?> live() => {
        for (final r in rows.values)
          if (r['deleted_at'] == null) r['merchant_key'] as String: r['category_key'],
      };
}

void main() {
  late LedgerAdmissionFixture admission;
  late Device d;
  late AppDatabase db;
  late DriftMerchantCategoryRepository rules;
  late _RuleCloud cloud;

  const shop = 'Synthetic Rule Shop';
  const arabicShop = 'متجر اصطناعي';
  String key(String merchant) => AppDatabase.normalizeMerchant(merchant);

  PlanningOutboxQueue queue() => PlanningOutboxQueue(
      db: db, isSyncEnabled: (_) => true, getAuthUserId: () async => uid);

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    admission = await LedgerAdmissionFixture.open(uid);
    db = admission.database;
    d = Device(db, FakeLedgerCloud());
    // The device holds a record of its own, so every restore here MERGES.
    await d.seedAccount();
    rules = DriftMerchantCategoryRepository(db, outboxQueue: queue());
    cloud = _RuleCloud();
  });
  tearDown(() => admission.finish());

  Future<void> remember(String merchant, String category) =>
      rules.confirmMerchantCategory(
          rawMerchant: merchant, categoryKey: category, isUserConfirmed: true);

  Future<String?> ruleFor(String merchant) =>
      rules.userConfirmedCategoryFor(merchant);

  Future<List<Map<String, Object?>>> table(String name, String order) async => [
        for (final r in await db
            .customSelect('SELECT * FROM $name ORDER BY $order;')
            .get())
          r.data,
      ];

  Future<List<String>> pending() async => [
        for (final c in await MerchantRuleRestore(db).pending())
          '${c.merchant}=${c.categoryKey}',
      ];

  Future<Map<String, Object?>> tombstones() async => {
        for (final r in await table('merchant_rule_tombstones', 'merchant_key'))
          r['merchant_key'] as String: r['deleted_at'],
      };

  Future<List<String>> outbox() async => [
        for (final r in await db
            .customSelect('SELECT entity_id, operation, payload_json '
                "FROM planning_sync_outbox WHERE entity_type = 'merchant_rule' "
                'ORDER BY entity_id;')
            .get())
          '${r.read<String>('operation')} ${r.read<String>('entity_id')}='
              '${(jsonDecode(r.read<String>('payload_json')) as Map)['category_key']}',
      ];

  Future<void> clearOutbox() => db.customStatement(
      "DELETE FROM planning_sync_outbox WHERE entity_type = 'merchant_rule';");

  /// The rule is simply not on this device (the backup came from another
  /// phone): no rule and no record of a removal.
  Future<void> absentHere(String merchant) async {
    await db.customStatement(
        'DELETE FROM merchant_category_map WHERE merchant_id IN '
        '(SELECT id FROM merchants WHERE normalized_name = ?);',
        [key(merchant)]);
    await db.customStatement(
        'DELETE FROM merchant_rule_tombstones WHERE merchant_key = ?;',
        [key(merchant)]);
    await clearOutbox();
  }

  /// The same snapshot as a build without deletion history wrote it (v4).
  Map<String, dynamic> legacy(Map<String, dynamic> backup) => {
        ...backup,
        'version': 4,
        'schemaVersion': 4,
        'tables': {
          for (final e in (backup['tables'] as Map).entries)
            if (!MerchantRuleRestore.historyTables.contains(e.key))
              e.key as String: e.value,
        },
      };

  Map<String, dynamic> backupRule(Map<String, dynamic> backup, String merchant) {
    final tables = backup['tables'] as Map;
    final merchantId = (tables['merchants'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((m) => m['normalized_name'] == key(merchant))['id'];
    return (tables['merchant_category_map'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((r) => r['merchant_id'] == merchantId);
  }

  String categoryId(Map<String, dynamic> backup, String categoryKey) =>
      ((backup['tables'] as Map)['categories'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((c) => c['key'] == categoryKey)['id'] as String;

  Future<Map<String, Object?>> state() async => {
        'rules': await table(
            'merchant_category_map WHERE is_user_confirmed = 1', 'merchant_id'),
        'tombstones': await tombstones(),
        'pending': await table('merchant_rule_restore_choices', 'merchant_key'),
        'history': await table('merchant_rule_history', 'id'),
        'outbox': await outbox(),
      };

  MerchantRuleSyncService syncService() => MerchantRuleSyncService(
        db: db,
        queue: queue(),
        remote: cloud,
        getAuthUserId: () async => uid,
        mayEgress: () async => true,
        serverReady: () async => true,
      );

  Future<Map<String, String>> deviceRules() async => {
        for (final r in await rules.getUserConfirmedRules())
          key(r.rawMerchant): r.categoryKey,
      };

  group('merge rule, per merchant', () {
    test('a rule only in the backup, on a device with full deletion history, '
        'is restored (English and Arabic merchant)', () async {
      await remember(shop, 'restaurants');
      await remember(arabicShop, 'shopping');
      final backup = await d.backup();
      final changedAt = backupRule(backup, shop)['updated_at'];
      await absentHere(shop);
      await absentHere(arabicShop);

      await d.restore(backup);

      expect(await ruleFor(shop), 'restaurants');
      expect(await ruleFor(arabicShop), 'shopping');
      expect(await pending(), isEmpty, reason: 'nothing ambiguous');
      expect(
          (await table(
                  'merchant_category_map WHERE is_user_confirmed = 1', 'id'))
              .map((r) => r['updated_at']),
          contains(changedAt),
          reason: 'the restored rule keeps its own change time');
    });

    test('a rule removed after the backup stays removed, and is not offered '
        'for review', () async {
      await remember(shop, 'restaurants');
      await remember(arabicShop, 'shopping');
      final backup = await d.backup();
      await rules.forgetUserConfirmedRule(shop);
      await rules.forgetUserConfirmedRule(arabicShop);
      expect(await tombstones(), hasLength(2),
          reason: 'Forget rule records the removal');

      await d.restore(backup);
      await d.restore(backup);

      expect(await ruleFor(shop), isNull);
      expect(await ruleFor(arabicShop), isNull);
      expect(await pending(), isEmpty);
    });

    test('a removal in the same millisecond as the rule was saved still counts',
        () async {
      await remember(shop, 'restaurants');
      final backup = await d.backup();
      await rules.forgetUserConfirmedRule(shop);
      // SQLite stamps the removal in milliseconds, Dart the rule in
      // microseconds: the removal reads as 0.9 ms BEFORE the rule it removed.
      backupRule(backup, shop)['updated_at'] = '2026-07-06T10:00:00.123900Z';
      await db.customStatement(
          'UPDATE merchant_rule_tombstones SET deleted_at = ?;',
          ['2026-07-06T10:00:00.123Z']);

      await d.restore(backup);
      expect(await ruleFor(shop), isNull);
      expect(await pending(), isEmpty);
    });

    test('rules of a category deleted after the backup stay removed and '
        'nothing points at the deleted category', () async {
      final categories = DriftCategoryRepository(db, outboxQueue: queue());
      final custom = await categories.createCategory(
          nameAr: 'فئة اصطناعية', icon: 'tag', color: '#000000', isIncome: false);
      await remember(shop, custom.key);
      final backup = await d.backup();
      await categories.deleteCategory(custom.id);
      expect(await tombstones(), contains(key(shop)),
          reason: 'category deletion records the removal of its rules');

      await d.restore(backup);

      expect(await ruleFor(shop), isNull);
      expect(await pending(), isEmpty);
      expect(
          await db
              .customSelect('SELECT m.id FROM merchant_category_map m '
                  'JOIN categories c ON c.id = m.category_id '
                  'WHERE c.deleted_at IS NOT NULL;')
              .get(),
          isEmpty);
    });

    test('a rule changed after the backup keeps the newer choice', () async {
      await remember(shop, 'restaurants');
      final backup = await d.backup();
      await remember(shop, 'shopping');

      await d.restore(backup);
      expect(await ruleFor(shop), 'shopping');
    });

    test('a rule the backup changed more recently wins, with the backup\'s '
        'change time; a tie keeps the device rule', () async {
      await remember(shop, 'restaurants');
      await remember(arabicShop, 'restaurants');
      final backup = await d.backup();
      // Another phone changed the first rule later than this device did.
      backupRule(backup, shop)
        ..['category_id'] = categoryId(backup, 'shopping')
        ..['updated_at'] = '2099-01-01T00:00:00.000Z';
      // Same change time, different category: the device's is kept.
      backupRule(backup, arabicShop)['category_id'] =
          categoryId(backup, 'shopping');

      await d.restore(backup);

      expect(await ruleFor(shop), 'shopping');
      expect(await ruleFor(arabicShop), 'restaurants');
      await d.restore(backup);
      expect(await ruleFor(shop), 'shopping');
      expect(await ruleFor(arabicShop), 'restaurants');
    });

    test('a rule only on the device is kept, even when the backup recorded a '
        'later removal of it', () async {
      final backup = await d.backup();
      await remember(shop, 'restaurants');
      (backup['tables'] as Map)['merchant_rule_tombstones'] = [
        {
          'merchant_key': key(shop),
          'category_key': 'restaurants',
          'deleted_at': '2099-01-01T00:00:00.000Z',
        }
      ];

      await d.restore(backup);
      expect(await ruleFor(shop), 'restaurants');
      expect(await tombstones(), isEmpty);
    });

    test('a rule saved again on another phone after it was removed here is '
        'restored (the newer manual edit)', () async {
      await remember(shop, 'restaurants');
      final backup = await d.backup();
      await rules.forgetUserConfirmedRule(shop);
      backupRule(backup, shop)['updated_at'] = '2099-01-01T00:00:00.000Z';

      await d.restore(backup);
      expect(await ruleFor(shop), 'restaurants');
      expect(await tombstones(), isEmpty,
          reason: 'a merchant has a rule or a removal, never both');
    });

    test('removals recorded in the backup join this device\'s history, so an '
        'older backup cannot bring those rules back later', () async {
      await remember(shop, 'restaurants');
      final older = await d.backup();
      await rules.forgetUserConfirmedRule(shop);
      final newer = await d.backup();
      expect((newer['tables'] as Map)['merchant_rule_tombstones'],
          hasLength(1),
          reason: 'the backup carries the removal');
      // A second phone that never held the rule or its removal.
      await db.customStatement('DELETE FROM merchant_rule_tombstones;');

      await d.restore(newer);
      expect(await tombstones(), contains(key(shop)));
      await d.restore(older);
      expect(await ruleFor(shop), isNull);
      expect(await pending(), isEmpty);
    });
  });

  group('ambiguity', () {
    test('a backup without deletion history: backup-only rules are listed, '
        'not added and not dropped, until the user chooses', () async {
      await remember(shop, 'restaurants');
      await remember(arabicShop, 'shopping');
      final backup = legacy(await d.backup());
      await absentHere(shop);
      await absentHere(arabicShop);

      expect(await MerchantRuleRestore(db).reviewCount(
              (backup['tables'] as Map).cast<String, Object?>(), 4),
          2,
          reason: 'the confirmation can say how many before anything changes');
      await d.restore(backup);

      expect(await pending(),
          unorderedEquals(['$shop=restaurants', '$arabicShop=shopping']));
      expect(await ruleFor(shop), isNull,
          reason: 'an undecided rule categorises nothing');
      expect(await rules.hasCategoryForMerchant(shop), isFalse);
      expect(await rules.getLearnedCategoryMap(), isNot(contains(shop)));
      expect(await outbox(), isEmpty, reason: 'nothing to sync yet');

      // "Add": the rule is saved like any rule the user makes, and queued.
      await MerchantRuleRestore(db)
          .decide(key(shop), add: true, save: remember);
      expect(await ruleFor(shop), 'restaurants');
      expect(await outbox(), ['update ${key(shop)}=restaurants']);

      // "Leave out": recorded as a removal on this device.
      await MerchantRuleRestore(db).decide(key(arabicShop), add: false);
      expect(await ruleFor(arabicShop), isNull);
      expect(await tombstones(), contains(key(arabicShop)));
      expect(await pending(), isEmpty);

      // The same backup again: decided rules are not asked about again.
      final decided = await state();
      await d.restore(backup);
      expect(await pending(), isEmpty);
      expect(await ruleFor(shop), 'restaurants');
      expect(await ruleFor(arabicShop), isNull);
      expect(await state(), decided);
    });

    test('undecided rules are stored: they survive a repeated restore and '
        'travel in the next backup', () async {
      await remember(shop, 'restaurants');
      final backup = legacy(await d.backup());
      await absentHere(shop);
      await d.restore(backup);
      final stored = await table('merchant_rule_restore_choices', 'merchant_key');
      expect(stored.single['merchant_key'], key(shop));

      await d.restore(backup);
      expect(await table('merchant_rule_restore_choices', 'merchant_key'),
          stored);

      final next = await d.backup();
      expect((next['tables'] as Map)['merchant_rule_restore_choices'],
          hasLength(1));
    });

    test('a device upgraded from a build without deletion history: a backup '
        'rule older than the upgrade is ambiguous, a newer one is restored',
        () async {
      await remember(shop, 'restaurants');
      await remember(arabicShop, 'shopping');
      final backup = await d.backup();
      backupRule(backup, shop)['updated_at'] = '2026-01-01T00:00:00.000Z';
      backupRule(backup, arabicShop)['updated_at'] = '2099-01-01T00:00:00.000Z';
      await absentHere(shop);
      await absentHere(arabicShop);
      // What the v43 -> v44 step records on an existing database.
      await markMerchantRuleHistoryIncomplete(db);

      await d.restore(backup);

      expect(await pending(), ['$shop=restaurants']);
      expect(await ruleFor(shop), isNull);
      expect(await ruleFor(arabicShop), 'shopping');
    });

    test('a backup rule whose category is deleted on this device is never '
        'attached to anything: it waits, and cannot be added', () async {
      final categories = DriftCategoryRepository(db, outboxQueue: queue());
      final custom = await categories.createCategory(
          nameAr: 'فئة اصطناعية', icon: 'tag', color: '#000000', isIncome: false);
      await remember(shop, custom.key);
      final backup = await d.backup();
      await absentHere(shop);
      await categories.deleteCategory(custom.id);

      await d.restore(backup);

      expect(await ruleFor(shop), isNull);
      final choice = (await MerchantRuleRestore(db).pending()).single;
      expect(choice.canAdd, isFalse);
      await expectLater(
          MerchantRuleRestore(db).decide(key(shop), add: true, save: remember),
          throwsStateError);
      expect(await pending(), hasLength(1), reason: 'the choice is kept');
      expect(
          await db
              .customSelect('SELECT m.id FROM merchant_category_map m '
                  'JOIN categories c ON c.id = m.category_id '
                  'WHERE c.deleted_at IS NOT NULL;')
              .get(),
          isEmpty);
    });

    test('a rule the user makes for the merchant supersedes the pending '
        'choice', () async {
      await remember(shop, 'restaurants');
      final backup = legacy(await d.backup());
      await absentHere(shop);
      await d.restore(backup);
      expect(await pending(), hasLength(1));

      await remember(shop, 'shopping');
      expect(await pending(), isEmpty);
      await d.restore(backup);
      expect(await ruleFor(shop), 'shopping');
      expect(await pending(), isEmpty);
    });
  });

  test('restoring the same backup twice gives the same state as once',
      () async {
    await remember('Synthetic Kept Shop', 'restaurants');
    await remember('Synthetic Missing Shop', 'shopping');
    await remember('Synthetic Removed Shop', 'restaurants');
    await remember('Synthetic Edited Shop', 'restaurants');
    final backup = await d.backup();
    await absentHere('Synthetic Missing Shop');
    await rules.forgetUserConfirmedRule('Synthetic Removed Shop');
    await remember('Synthetic Edited Shop', 'shopping');

    await d.restore(backup);
    final once = await state();
    await d.restore(backup);
    expect(await state(), once);
    expect(await deviceRules(), {
      key('Synthetic Kept Shop'): 'restaurants',
      key('Synthetic Missing Shop'): 'shopping',
      key('Synthetic Edited Shop'): 'shopping',
    });
  });

  group('full apply (a device with no records)', () {
    Future<void> emptyDevice() async {
      await db.customStatement('DELETE FROM merchant_category_map '
          'WHERE is_user_confirmed = 1;');
      await db.customStatement('DELETE FROM merchant_rule_tombstones;');
      await db.customStatement('DELETE FROM merchant_rule_restore_choices;');
      await db.customStatement('DELETE FROM merchant_rule_history;');
      await db.customStatement('DELETE FROM accounts;');
      await clearOutbox();
      expect(await RestoreBackupUseCase.restoreWillMerge(db), isFalse);
    }

    test('rules, removals, undecided rules and the history marker are '
        'restored exactly as the backup holds them', () async {
      await remember(shop, 'restaurants');
      await remember(arabicShop, 'shopping');
      await remember('Synthetic Removed Shop', 'restaurants');
      await rules.forgetUserConfirmedRule('Synthetic Removed Shop');
      await markMerchantRuleHistoryIncomplete(db);
      await db.customStatement(
          'INSERT INTO merchant_rule_restore_choices(merchant_key, '
          "raw_merchant, category_key, rule_updated_at) VALUES ('SYNTHETIC "
          "WAITING SHOP', 'Synthetic Waiting Shop', 'shopping', "
          "'2026-01-01T00:00:00.000Z');");
      final before = await state();
      final backup = await d.backup();
      await emptyDevice();

      await d.restore(backup);

      final after = await state();
      expect(after['rules'], before['rules']);
      expect(after['tombstones'], before['tombstones']);
      expect(after['pending'], before['pending']);
      expect(after['history'], before['history']);
    });

    test('a backup without deletion history restores every rule and marks '
        'this device\'s history as starting now', () async {
      await remember(shop, 'restaurants');
      await remember(arabicShop, 'shopping');
      final backup = legacy(await d.backup());
      await emptyDevice();

      await d.restore(backup);

      expect(await ruleFor(shop), 'restaurants');
      expect(await ruleFor(arabicShop), 'shopping');
      expect(await pending(), isEmpty);
      expect(await table('merchant_rule_history', 'id'), hasLength(1));
    });

    test('a device that only remembers removals merges instead, so the '
        'removals are not thrown away', () async {
      await remember(shop, 'restaurants');
      final backup = await d.backup();
      await rules.forgetUserConfirmedRule(shop);
      await db.customStatement('DELETE FROM accounts;');
      expect(await RestoreBackupUseCase.restoreWillMerge(db), isTrue);

      await d.restore(backup);
      expect(await ruleFor(shop), isNull);
    });
  });

  group('the verified pipeline accepts the rule history', () {
    Future<void> viaPlan(Map<String, dynamic> backup) async {
      final snapshot =
          (jsonDecode(jsonEncode(backup)) as Map).cast<String, dynamic>();
      final plan = RestorePreparation.build(
        snapshot: snapshot,
        envelopeVersion: 3,
        sourceBytes: utf8.encode(jsonEncode(backup)),
        operationId: 'op-rules',
      );
      await RestoreBackupUseCase(db)(
        <String, dynamic>{
          'schemaVersion': plan.snapshotSchemaVersion,
          'tables': plan.tables,
        },
        plan: plan,
      );
    }

    test('merge: more undecided rules than the backup carried is not a '
        'row-count mismatch', () async {
      await remember(shop, 'restaurants');
      await remember(arabicShop, 'shopping');
      final backup = await d.backup();
      await absentHere(shop);
      await absentHere(arabicShop);
      await markMerchantRuleHistoryIncomplete(db);

      await viaPlan(backup);
      expect(await pending(), hasLength(2));
    });

    test('full apply of a current backup verifies', () async {
      await remember(shop, 'restaurants');
      await rules.forgetUserConfirmedRule(shop);
      await remember(arabicShop, 'shopping');
      final backup = await d.backup();
      await db.customStatement('DELETE FROM merchant_category_map '
          'WHERE is_user_confirmed = 1;');
      await db.customStatement('DELETE FROM merchant_rule_tombstones;');
      await db.customStatement('DELETE FROM accounts;');

      await viaPlan(backup);
      expect(await ruleFor(arabicShop), 'shopping');
      expect(await tombstones(), contains(key(shop)));
    });
  });

  group('restore, then sync, then pull', () {
    test('a restored rule reaches the cloud once and device and cloud agree; '
        'a second sync sends nothing more', () async {
      await remember(shop, 'restaurants');
      await remember(arabicShop, 'shopping');
      await syncService().sync();
      expect(cloud.live(), {key(shop): 'restaurants', key(arabicShop): 'shopping'});
      final backup = await d.backup();
      // Lost on this device and in the cloud copy of this user (e.g. the
      // backup is from a phone that never synced these).
      await absentHere(shop);
      cloud.rows.remove(key(shop));
      cloud.pushedKeys.clear();

      await d.restore(backup);
      expect(await ruleFor(shop), 'restaurants');
      await syncService().sync();

      expect(cloud.live(), await deviceRules());
      expect(cloud.live()[key(shop)], 'restaurants');
      final sent = cloud.pushedKeys.length;
      await syncService().sync();
      expect(cloud.pushedKeys, hasLength(sent));
      expect(cloud.live(), await deviceRules());
    });

    test('a rule removed here stays removed on device and cloud after '
        'restore and sync', () async {
      await remember(shop, 'restaurants');
      await syncService().sync();
      final backup = await d.backup();
      await rules.forgetUserConfirmedRule(shop);
      await syncService().sync();
      expect(cloud.live(), isEmpty);

      await d.restore(backup);
      await syncService().sync();
      await syncService().sync();

      expect(await ruleFor(shop), isNull);
      expect(cloud.live(), isEmpty,
          reason: 'the restore must not push the removed rule back');
    });

    test('a removal still queued for the cloud survives the restore and is '
        'delivered', () async {
      await remember(shop, 'restaurants');
      await syncService().sync();
      final backup = await d.backup();
      await rules.forgetUserConfirmedRule(shop); // delete intent queued

      await d.restore(backup);
      await syncService().sync();

      expect(await ruleFor(shop), isNull);
      expect(cloud.live(), isEmpty);
    });

    test('a removal made on another device that this one has not pulled yet '
        'wins over the restored rule: it is not pushed back', () async {
      await remember(shop, 'restaurants');
      await syncService().sync();
      final backup = await d.backup();
      await absentHere(shop);
      cloud.otherDevice(key(shop), 'restaurants',
          deletedAt: '2027-01-02T00:00:00.000Z');
      cloud.pushedKeys.clear();

      await d.restore(backup);
      expect(await ruleFor(shop), 'restaurants',
          reason: 'this device had no way to know yet');
      await syncService().sync();

      expect(await ruleFor(shop), isNull);
      expect(cloud.live(), isEmpty);
      expect(cloud.pushedKeys, isNot(contains(key(shop))));
      // And it is now on record here: the backup cannot bring it back.
      await d.restore(backup);
      await syncService().sync();
      expect(await ruleFor(shop), isNull);
      expect(cloud.live(), isEmpty);
    });

    test('a removal pulled from the cloud for a rule this device never held '
        'is remembered: a later restore does not add the rule', () async {
      await remember(shop, 'restaurants');
      final backup = await d.backup();
      await absentHere(shop);
      cloud.otherDevice(key(shop), 'restaurants',
          deletedAt: '2099-01-01T00:00:00.000Z');
      await syncService().sync();
      expect(await tombstones(), contains(key(shop)));

      await d.restore(backup);
      expect(await ruleFor(shop), isNull);
      expect(await pending(), isEmpty);
    });

    test('a rule the backup changed more recently replaces a stale queued '
        'edit, and the cloud ends with the restored rule', () async {
      await remember(shop, 'restaurants'); // queued, not yet pushed
      final backup = await d.backup();
      backupRule(backup, shop)
        ..['category_id'] = categoryId(backup, 'shopping')
        ..['updated_at'] = '2099-01-01T00:00:00.000Z';

      await d.restore(backup);
      await syncService().sync();

      expect(await ruleFor(shop), 'shopping');
      expect(cloud.live(), {key(shop): 'shopping'});
    });

    test('a rule added from the review list is pushed like a rule the user '
        'makes; one left out sends nothing', () async {
      await remember(shop, 'restaurants');
      await remember(arabicShop, 'shopping');
      final backup = legacy(await d.backup());
      await absentHere(shop);
      await absentHere(arabicShop);
      await d.restore(backup);
      await syncService().sync();
      expect(cloud.live(), isEmpty, reason: 'undecided rules are not synced');

      await MerchantRuleRestore(db)
          .decide(key(shop), add: true, save: remember);
      await MerchantRuleRestore(db).decide(key(arabicShop), add: false);
      await syncService().sync();

      expect(cloud.live(), {key(shop): 'restaurants'});
      expect(cloud.live(), await deviceRules());
    });
  });

  test('the backup carries the rule history and declares format 5', () async {
    await remember(shop, 'restaurants');
    await rules.forgetUserConfirmedRule(shop);
    final backup = await d.backup();
    expect(backup['schemaVersion'], 5);
    expect(BackupSnapshotBuilder.backedUpTables,
        containsAll(MerchantRuleRestore.historyTables));
    final removal = ((backup['tables'] as Map)['merchant_rule_tombstones']
            as List)
        .single as Map;
    expect(removal['merchant_key'], key(shop));
    expect(removal['category_key'], 'restaurants');
  });

  test('the restore confirmation says what happens to saved rules, in English '
      'and Arabic', () {
    final en = lookupAppL10n(const Locale('en'));
    final ar = lookupAppL10n(const Locale('ar'));
    for (final body in [en.rpConfirmBodyMerge, en.rpConfirmBody]) {
      expect(body, isNot(contains('are not added')));
      expect(body, contains('deleted'));
      expect(body, contains('Learned rules'));
    }
    expect(en.rpConfirmBodyMerge, contains('a rule missing here is added'));
    expect(en.rpConfirmBodyMerge,
        contains('a rule you deleted here stays deleted'));
    expect(en.rpConfirmBodyMerge, contains('neither adds nor discards it'));
    for (final body in [ar.rpConfirmBodyMerge, ar.rpConfirmBody]) {
      expect(body, isNot(contains('ولا تُضاف القواعد الموجودة في النسخة فقط')));
      expect(body, contains('القواعد المحفوظة'));
    }
    expect(ar.rpConfirmBodyMerge, contains('تُضاف القاعدة غير الموجودة هنا'));
    expect(ar.rpConfirmBodyMerge, contains('وتبقى القاعدة التي حذفتها هنا محذوفة'));
    expect(ar.rpConfirmBodyMerge, contains('فلن يضيفها ولن يتجاهلها'));
    expect(en.lrRestoreCount(1), contains('1 rule'));
    expect(en.lrRestoreCount(3), contains('3 rules'));
    expect(ar.lrRestoreCount(3), contains('3'));
    expect(en.lrRestoreExplanation, contains('did not add them'));
    expect(en.lrRestoreExplanation, contains('did not discard them'));
    expect(ar.lrRestoreExplanation, contains('فلم يُضفها ولم يتجاهلها'));
  });
}
