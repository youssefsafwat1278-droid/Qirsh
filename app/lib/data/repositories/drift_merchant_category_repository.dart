import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/repositories/merchant_category_repository.dart';
import '../db/app_database.dart';
import '../db/database_seed.dart';
import '../db/sql_value_codec.dart';

class DriftMerchantCategoryRepository implements MerchantCategoryRepository {
  DriftMerchantCategoryRepository(this._db);

  final AppDatabase _db;

  @override
  Future<bool> hasCategoryForMerchant(String rawMerchant) async {
    final normalized = AppDatabase.normalizeMerchant(rawMerchant);
    final row = await _db.customSelect(
      '''
        SELECT merchant_category_map.id
        FROM merchant_category_map
        INNER JOIN merchants ON merchants.id = merchant_category_map.merchant_id
        WHERE merchants.normalized_name = ?
        LIMIT 1;
      ''',
      variables: [Variable.withString(normalized)],
    ).getSingleOrNull();
    return row != null;
  }

  @override
  Future<void> confirmMerchantCategory({
    required String rawMerchant,
    required String categoryKey,
    required bool isUserConfirmed,
    double confidence = 1,
  }) async {
    final merchantId = await _resolveOrCreateMerchantId(rawMerchant);
    final categoryId = await _categoryIdByKey(categoryKey);
    if (categoryId == null) {
      throw StateError('Unknown category key: $categoryKey');
    }

    final existing = await _db.customSelect(
      'SELECT id FROM merchant_category_map WHERE merchant_id = ? LIMIT 1;',
      variables: [Variable.withString(merchantId)],
    ).getSingleOrNull();

    if (existing == null) {
      await _db.customInsert(
        '''
          INSERT INTO merchant_category_map(
            id, merchant_id, category_id, is_user_confirmed, confidence, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?);
        ''',
        variables: [
          Variable.withString(IdGenerator.next()),
          Variable.withString(merchantId),
          Variable.withString(categoryId),
          Variable.withInt(boolToSql(isUserConfirmed)),
          Variable.withReal(confidence),
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
        ],
      );
      return;
    }

    await _db.customUpdate(
      '''
        UPDATE merchant_category_map
        SET category_id = ?, is_user_confirmed = ?, confidence = ?, updated_at = ?
        WHERE merchant_id = ?;
      ''',
      variables: [
        Variable.withString(categoryId),
        Variable.withInt(boolToSql(isUserConfirmed)),
        Variable.withReal(confidence),
        Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
        Variable.withString(merchantId),
      ],
    );
  }

  @override
  Future<Map<String, String>> getLearnedCategoryMap() async {
    final rows = await _db.customSelect(
      '''
        SELECT merchants.raw_name AS raw_name, categories.key AS category_key
        FROM merchant_category_map
        INNER JOIN merchants ON merchants.id = merchant_category_map.merchant_id
        INNER JOIN categories ON categories.id = merchant_category_map.category_id;
      ''',
    ).get();

    return {
      for (final row in rows)
        row.read<String>('raw_name'): row.read<String>('category_key'),
    };
  }

  @override
  Future<List<LearnedMerchantRule>> getUserConfirmedRules() async {
    final rows = await _db.customSelect(
      '''
        SELECT merchants.raw_name AS raw_name, categories.key AS category_key
        FROM merchant_category_map
        INNER JOIN merchants ON merchants.id = merchant_category_map.merchant_id
        INNER JOIN categories ON categories.id = merchant_category_map.category_id
        WHERE merchant_category_map.is_user_confirmed = 1
        ORDER BY merchant_category_map.updated_at DESC, merchants.raw_name;
      ''',
    ).get();
    return [
      for (final row in rows)
        LearnedMerchantRule(
          rawMerchant: row.read<String>('raw_name'),
          categoryKey: row.read<String>('category_key'),
        ),
    ];
  }

  @override
  Future<void> forgetUserConfirmedRule(String rawMerchant) async {
    final normalized = AppDatabase.normalizeMerchant(rawMerchant);
    final merchant = await _db.customSelect(
      'SELECT id FROM merchants WHERE normalized_name = ? LIMIT 1;',
      variables: [Variable.withString(normalized)],
    ).getSingleOrNull();
    if (merchant == null) return;
    final merchantId = merchant.read<String>('id');

    // A user rule on a catalog merchant overwrote the seed row (the map is one
    // row per merchant), so forgetting it restores that seed mapping.
    SeededMerchantMapping? seed;
    for (final m in DatabaseSeed.merchantMappings) {
      if (AppDatabase.normalizeMerchant(m.rawName) == normalized) {
        seed = m;
        break;
      }
    }
    final seedCategoryId =
        seed == null ? null : await _categoryIdByKey(seed.categoryKey);
    if (seed != null && seedCategoryId != null) {
      await _db.customUpdate(
        '''
          UPDATE merchant_category_map
          SET category_id = ?, is_user_confirmed = 0, confidence = ?, updated_at = ?
          WHERE merchant_id = ? AND is_user_confirmed = 1;
        ''',
        variables: [
          Variable.withString(seedCategoryId),
          Variable.withReal(seed.confidence),
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
          Variable.withString(merchantId),
        ],
      );
      return;
    }
    await _db.customUpdate(
      'DELETE FROM merchant_category_map '
      'WHERE merchant_id = ? AND is_user_confirmed = 1;',
      variables: [Variable.withString(merchantId)],
      updateKind: UpdateKind.delete,
    );
  }

  Future<String?> _categoryIdByKey(String categoryKey) async {
    final row = await _db.customSelect(
      'SELECT id FROM categories WHERE key = ? LIMIT 1;',
      variables: [Variable.withString(categoryKey)],
    ).getSingleOrNull();
    return row?.read<String>('id');
  }

  Future<String> _resolveOrCreateMerchantId(String rawMerchant) async {
    final normalized = AppDatabase.normalizeMerchant(rawMerchant);
    final existing = await _db.customSelect(
      'SELECT id FROM merchants WHERE normalized_name = ? LIMIT 1;',
      variables: [Variable.withString(normalized)],
    ).getSingleOrNull();
    if (existing != null) {
      final merchantId = existing.read<String>('id');
      await _db.customUpdate(
        'UPDATE merchants SET last_seen_at = ? WHERE id = ?;',
        variables: [
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
          Variable.withString(merchantId),
        ],
      );
      return merchantId;
    }

    final merchantId = IdGenerator.next();
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customInsert(
      '''
        INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, last_seen_at)
        VALUES (?, ?, ?, ?, ?);
      ''',
      variables: [
        Variable.withString(merchantId),
        Variable.withString(rawMerchant),
        Variable.withString(normalized),
        Variable.withString(now),
        Variable.withString(now),
      ],
    );
    return merchantId;
  }
}
