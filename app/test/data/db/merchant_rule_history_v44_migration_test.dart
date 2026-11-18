// v43 -> v44: deletion history for saved category rules
// (lib/data/db/merchant_rule_history.dart). Forward-only and additive: three
// new tables and triggers on merchant_category_map. Existing rules keep
// working, no removal is invented for the past, no financial row is touched.
// Synthetic data only.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/data_wipe_service.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/database_seed.dart';
import 'package:money_companion/data/db/merchant_rule_history.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shop = 'Synthetic Rule Shop';
  const arabicShop = 'متجر اصطناعي';

  Future<AppDatabase> open() => AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );

  Future<int> scalar(AppDatabase db, String sql) async =>
      (await db.customSelect(sql).getSingle()).data.values.first as int;

  Future<int> count(AppDatabase db, String table) =>
      scalar(db, 'SELECT COUNT(*) FROM $table;');

  Future<List<String>> objects(AppDatabase db, String type) async => [
        for (final r in await db
            .customSelect("SELECT name FROM sqlite_master WHERE type = '$type' "
                "AND (name LIKE 'merchant_rule_%' OR name LIKE 'rule_history_%') "
                'ORDER BY name;')
            .get())
          r.read<String>('name'),
      ];

  /// A populated install, wound back to the exact v43 shape: saved rules and
  /// money, and none of the v44 tables or triggers.
  Future<AppDatabase> v43Fixture() async {
    final db = await open();
    final rules = DriftMerchantCategoryRepository(db);
    await rules.confirmMerchantCategory(
        rawMerchant: shop, categoryKey: 'restaurants', isUserConfirmed: true);
    await rules.confirmMerchantCategory(
        rawMerchant: arabicShop, categoryKey: 'shopping', isUserConfirmed: true);
    await db.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
      "VALUES ('acc-1', 'Main', 'SAR', 'bank', '2026-01-01', '2026-01-01');",
    );
    await db.customStatement(
      "INSERT INTO transactions(id, amount, currency, type, source, "
      "occurred_at, raw_message, parse_confidence, status, created_at, "
      "updated_at, account_id, direction, raw_merchant) VALUES "
      "('t-1', 12.5, 'SAR', 'payment', 'bank', '2026-09-01', 'v43', 0.9, "
      "'confirmed', '2026-01-01', '2026-01-01', 'acc-1', 'debit', '$shop');",
    );
    // The v30 exact-minor columns, as a real v43 install has them.
    await backfillNonPlanningMoneyV30(db);
    for (final trigger in await objects(db, 'trigger')) {
      await db.customStatement('DROP TRIGGER $trigger;');
    }
    for (final table in await objects(db, 'table')) {
      await db.customStatement('DROP TABLE $table;');
    }
    await db.customStatement('PRAGMA user_version = 43;');
    return db;
  }

  test('v43 -> v44 keeps rules and money, invents no removal, and marks the '
      'history as starting at the upgrade', () async {
    final db = await v43Fixture();
    addTearDown(db.close);
    expect(await objects(db, 'table'), isEmpty,
        reason: 'the fixture must really be the v43 shape');
    final rulesBefore = await db
        .customSelect('SELECT * FROM merchant_category_map ORDER BY id;')
        .get()
        .then((rows) => [for (final r in rows) r.data]);
    final moneyBefore = await db
        .customSelect('SELECT id, amount, amount_minor, currency, status, '
            'category_id FROM transactions;')
        .get()
        .then((rows) => [for (final r in rows) r.data]);

    await db.debugReinitialize();

    expect(await scalar(db, 'PRAGMA user_version;'), 44);
    expect(await objects(db, 'table'), [
      'merchant_rule_history',
      'merchant_rule_restore_choices',
      'merchant_rule_tombstones',
    ]);
    expect(
        await db
            .customSelect('SELECT * FROM merchant_category_map ORDER BY id;')
            .get()
            .then((rows) => [for (final r in rows) r.data]),
        rulesBefore,
        reason: 'no rule row is changed');
    expect(
        await db
            .customSelect('SELECT id, amount, amount_minor, currency, status, '
                'category_id FROM transactions;')
            .get()
            .then((rows) => [for (final r in rows) r.data]),
        moneyBefore,
        reason: 'no financial row is touched');
    final rules = DriftMerchantCategoryRepository(db);
    expect(await rules.userConfirmedCategoryFor(shop), 'restaurants');
    expect(await rules.userConfirmedCategoryFor(arabicShop), 'shopping');
    expect(await count(db, 'merchant_rule_tombstones'), 0,
        reason: 'no removal is invented for the past');
    expect(await count(db, 'merchant_rule_restore_choices'), 0);
    expect(await count(db, 'merchant_rule_history'), 1,
        reason: 'removals before the upgrade are unknown');

    // From now on a removal is recorded.
    await rules.forgetUserConfirmedRule(shop);
    final removal = await db
        .customSelect('SELECT * FROM merchant_rule_tombstones;')
        .getSingle();
    expect(removal.read<String>('merchant_key'),
        AppDatabase.normalizeMerchant(shop));
    expect(removal.read<String>('category_key'), 'restaurants');

    // Opening again is a no-op: the marker does not move.
    final since = await db
        .customSelect('SELECT history_since FROM merchant_rule_history;')
        .getSingle();
    await db.debugReinitialize();
    expect(
        (await db
                .customSelect('SELECT history_since FROM merchant_rule_history;')
                .getSingle())
            .data,
        since.data);
    expect(await count(db, 'merchant_rule_tombstones'), 1);
  });

  test('a new install has the tables, no history marker (its history is '
      'complete) and schema 44', () async {
    final db = await open();
    addTearDown(db.close);
    expect(await scalar(db, 'PRAGMA user_version;'), 44);
    expect(await objects(db, 'table'), hasLength(3));
    expect(await count(db, 'merchant_rule_history'), 0);
    expect(await count(db, 'merchant_rule_tombstones'), 0);
  });

  group('every way a saved rule is removed is recorded', () {
    late AppDatabase db;
    late DriftMerchantCategoryRepository rules;
    setUp(() async {
      db = await open();
      rules = DriftMerchantCategoryRepository(db);
    });
    tearDown(() => db.close());

    Future<Map<String, String>> removals() async => {
          for (final r in await db
              .customSelect('SELECT * FROM merchant_rule_tombstones;')
              .get())
            r.read<String>('merchant_key'): r.read<String>('category_key'),
        };

    test('Forget rule, for an English and an Arabic merchant', () async {
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: 'restaurants', isUserConfirmed: true);
      await rules.confirmMerchantCategory(
          rawMerchant: arabicShop,
          categoryKey: 'shopping',
          isUserConfirmed: true);
      await rules.forgetUserConfirmedRule(shop);
      await rules.forgetUserConfirmedRule(arabicShop);
      expect(await removals(), {
        AppDatabase.normalizeMerchant(shop): 'restaurants',
        AppDatabase.normalizeMerchant(arabicShop): 'shopping',
      });
    });

    test('Forget rule on a catalog merchant (the row goes back to the catalog '
        'mapping instead of being deleted)', () async {
      final seed = DatabaseSeed.merchantMappings.first;
      final name = seed.rawName;
      final chosen =
          seed.categoryKey == 'shopping' ? 'restaurants' : 'shopping';
      await rules.confirmMerchantCategory(
          rawMerchant: name, categoryKey: chosen, isUserConfirmed: true);
      expect(await removals(), isEmpty);
      await rules.forgetUserConfirmedRule(name);
      expect(await removals(), {AppDatabase.normalizeMerchant(name): chosen});
      expect((await rules.getLearnedCategoryMap())[name], seed.categoryKey,
          reason: 'the catalog mapping is back');
      expect(await count(db, 'merchant_category_map WHERE is_user_confirmed = 1'),
          0);
    });

    test('deleting the rule\'s category', () async {
      final categories = DriftCategoryRepository(db);
      final custom = await categories.createCategory(
          nameAr: 'فئة اصطناعية', icon: 'tag', color: '#000000', isIncome: false);
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: custom.key, isUserConfirmed: true);
      await categories.deleteCategory(custom.id);
      expect(await removals(),
          {AppDatabase.normalizeMerchant(shop): custom.key});
    });

    test('saving the rule again clears the removal; a catalog row is never '
        'recorded', () async {
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: 'restaurants', isUserConfirmed: true);
      await rules.forgetUserConfirmedRule(shop);
      expect(await removals(), hasLength(1));
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: 'shopping', isUserConfirmed: true);
      expect(await removals(), isEmpty);

      await db.customStatement(
          'DELETE FROM merchant_category_map WHERE is_user_confirmed = 0;');
      expect(await removals(), isEmpty);
    });

    test('an earlier removal never replaces a later one', () async {
      await recordMerchantRuleTombstone(
          db, 'SHOP', 'restaurants', '2026-07-02T00:00:00.000Z');
      await recordMerchantRuleTombstone(
          db, 'SHOP', 'shopping', '2026-07-01T00:00:00.000Z');
      expect(await removals(), {'SHOP': 'restaurants'});
      await recordMerchantRuleTombstone(
          db, 'SHOP', 'shopping', '2026-07-03T00:00:00.000Z');
      expect(await removals(), {'SHOP': 'shopping'});
    });

    test('retention: only the newest removals are kept, and pruning moves the '
        'history marker so older backup rules go to review', () async {
      await db.transaction(() async {
        for (var i = 0; i < merchantRuleTombstoneLimit; i++) {
          await db.customStatement(
              'INSERT INTO merchant_rule_tombstones(merchant_key, category_key, '
              "deleted_at) VALUES (?, 'shopping', ?);",
              [
                'SHOP $i',
                DateTime.utc(2026, 1, 1)
                    .add(Duration(minutes: i))
                    .toIso8601String(),
              ]);
        }
      });
      expect(await count(db, 'merchant_rule_tombstones'),
          merchantRuleTombstoneLimit);
      expect(await count(db, 'merchant_rule_history'), 0);

      await recordMerchantRuleTombstone(
          db, 'SHOP NEWEST', 'shopping', '2027-01-01T00:00:00.000Z');

      expect(await count(db, 'merchant_rule_tombstones'),
          merchantRuleTombstoneLimit);
      expect(await removals(), isNot(contains('SHOP 0')),
          reason: 'the oldest removal is the one pruned');
      expect(await removals(), contains('SHOP NEWEST'));
      expect(await count(db, 'merchant_rule_history'), 1);
    });

    test('"delete all my data" leaves no rule history behind', () async {
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: 'restaurants', isUserConfirmed: true);
      await rules.confirmMerchantCategory(
          rawMerchant: arabicShop,
          categoryKey: 'shopping',
          isUserConfirmed: true);
      await rules.forgetUserConfirmedRule(shop);
      await markMerchantRuleHistoryIncomplete(db);
      await db.customStatement(
          'INSERT INTO merchant_rule_restore_choices(merchant_key, '
          "raw_merchant, category_key, rule_updated_at) VALUES ('WAITING', "
          "'Waiting', 'shopping', '2026-01-01T00:00:00.000Z');");

      await DataWipeService(db).wipeAll();

      expect(await count(db, 'merchant_rule_tombstones'), 0,
          reason: 'the wipe itself must not be recorded as removals');
      expect(await count(db, 'merchant_rule_restore_choices'), 0);
      expect(await count(db, 'merchant_rule_history'), 0);
    });
  });
}
