// A saved merchant rule whose category was deleted must not categorise
// anything: every rule lookup ignores it, and categorisation falls through to
// the next precedence level (shared learning, then the AI's own category).
// Synthetic data only.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/domain/services/learned_rule_precedence.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;
  late DriftMerchantCategoryRepository rules;
  const shop = 'Synthetic Rule Shop';

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    rules = DriftMerchantCategoryRepository(db);
    await rules.confirmMerchantCategory(
        rawMerchant: shop, categoryKey: 'restaurants', isUserConfirmed: true);
    expect(await rules.userConfirmedCategoryFor(shop), 'restaurants');
    // The category is deleted while the rule row is still there (an older
    // restore, a pull, or any path that skipped the rule cleanup).
    await db.customStatement("UPDATE categories SET deleted_at = "
        "'2026-07-01T00:00:00.000Z' WHERE key = 'restaurants';");
  });
  tearDown(() => db.close());

  test('every rule lookup ignores a rule whose category is deleted', () async {
    expect(await rules.userConfirmedCategoryFor(shop), isNull);
    expect(await rules.getUserConfirmedRules(), isEmpty);
    expect(await rules.getLearnedCategoryMap(), isNot(contains(shop)));
    // SP-17: the merchant has no usable category, so it is treated as new
    // (the user is asked to categorise it).
    expect(await rules.hasCategoryForMerchant(shop), isFalse);
    expect(await rules.hasCategoryForMerchant('متجر اصطناعي'), isFalse);
  });

  test('a rule on a live category still counts (English and Arabic)', () async {
    await rules.confirmMerchantCategory(
        rawMerchant: 'Synthetic Other Shop',
        categoryKey: 'shopping',
        isUserConfirmed: true);
    await rules.confirmMerchantCategory(
        rawMerchant: 'متجر اصطناعي',
        categoryKey: 'shopping',
        isUserConfirmed: true);
    expect(await rules.hasCategoryForMerchant('Synthetic Other Shop'), isTrue);
    expect(await rules.hasCategoryForMerchant('متجر اصطناعي'), isTrue);
  });

  test('categorisation falls through to the next precedence level', () async {
    expect(await learnedRuleCategoryFor(rules, shop), isNull,
        reason: 'no rule: the AI category is used');
    final shared = await learnedRuleCategoryFor(rules, shop,
        loadRemoteKeywords: () async => const [
              RemoteMerchantKeyword(
                id: 'kw-1',
                keyword: shop,
                categoryKey: 'shopping',
                language: 'en',
                countryCode: 'SA',
                priority: sharedLearningKeywordPriority,
                isActive: true,
                isDeleted: false,
                updatedAt: '2026-07-01T00:00:00.000Z',
              ),
            ]);
    expect(shared?.categoryKey, 'shopping');
    expect(shared?.userConfirmed, isFalse);
  });
}
