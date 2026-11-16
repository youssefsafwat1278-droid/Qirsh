import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/data_portability/drift_financial_exporter.dart';
import 'package:money_companion/core/data_portability/drift_financial_importer.dart';
import 'package:money_companion/core/data_portability/qirsh_package_codec.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/usecases/correct_category_usecase.dart';
import '../../harness/seed_test_account.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _database() => seededDb(AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    ));

const _t = '2026-07-01T00:00:00.000Z';
const _merchant = 'ZARYAB DIMASHQI TRDG';

/// File export -> import used to drop every merchant link (the export carries
/// only the merchant NAME), so "also update past" found nothing to update.
/// Imports now rebuild links deterministically, while the rows themselves stay
/// protected: a file says nothing trustworthy about who chose a category.
void main() {
  late AppDatabase source;
  late AppDatabase target;

  setUp(() async {
    source = await _database();
    target = await _database();
  });
  tearDown(() async {
    await source.close();
    await target.close();
  });

  Future<String> categoryId(AppDatabase db, String key) async => (await db
          .customSelect("SELECT id FROM categories WHERE key = '$key';")
          .getSingle())
      .read<String>('id');

  Future<void> seed() async {
    final food = await categoryId(source, 'restaurants');
    await source.customStatement(
      "INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, "
      "last_seen_at) VALUES ('m-1', '$_merchant', "
      "'${AppDatabase.normalizeMerchant(_merchant)}', '$_t', '$_t');",
    );
    for (final (id, prov, raw, type) in [
      ('tx-1', 'user', _merchant, 'payment'),
      ('tx-2', 'rule', '$_merchant 77', 'payment'),
      ('tx-3', 'auto', _merchant, 'payment'),
      ('tx-transfer', 'auto', 'Ahmed Ali', 'transfer'),
    ]) {
      await source.customStatement(
        "INSERT INTO transactions(id, amount, currency, type, source, "
        "occurred_at, raw_message, parse_confidence, status, created_at, "
        "updated_at, account_id, direction, raw_merchant, merchant_id, "
        "category_id, category_source) VALUES ('$id', 12.5, 'SAR', '$type', "
        "'bank', '$_t', 'sms', 0.9, 'confirmed', '$_t', '$_t', "
        "'$kDefaultAccountLocalId', 'debit', '$raw', "
        "${type == 'transfer' ? 'NULL' : "'m-1'"}, '$food', '$prov');",
      );
    }
    await backfillNonPlanningMoneyV30(source);
  }

  Future<void> importInto(AppDatabase db) async {
    final bytes =
        (await DriftFinancialExporter(source).exportFinancialPackage()).bytes;
    await DriftFinancialImporter(db)
        .importPackage(decodeQirshPackage(bytes), ImportMode.merge);
  }

  Future<Map<String, Map<String, Object?>>> rows(AppDatabase db) async => {
        for (final r in await db
            .customSelect('SELECT t.id, t.category_source, t.merchant_id, '
                't.source, m.normalized_name AS mn FROM transactions t '
                'LEFT JOIN merchants m ON m.id = t.merchant_id;')
            .get())
          r.read<String>('id'): r.data,
      };

  CorrectCategoryUseCase useCase(AppDatabase db) => CorrectCategoryUseCase(
        transactionRepository: DriftTransactionRepository(db),
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
      );

  test('an imported file rebuilds merchant links by the exact normalised name',
      () async {
    await seed();
    await importInto(target);

    final r = await rows(target);
    final key = AppDatabase.normalizeMerchant(_merchant);
    for (final id in ['tx-1', 'tx-2', 'tx-3']) {
      expect(r[id]!['mn'], key, reason: '$id must be linked again');
    }
    expect({r['tx-1']!['merchant_id'], r['tx-2']!['merchant_id']}.length, 1,
        reason: 'digits/spacing variants are the same stable merchant');
    expect(r['tx-transfer']!['merchant_id'], isNull,
        reason: 'a transfer names a person, never a merchant');
  });

  test('imported rows are marked, keep their source, and stay out of a bulk update',
      () async {
    await seed();
    await importInto(target);

    final r = await rows(target);
    expect(r.values.map((e) => e['category_source']).toSet(), {'unknown'},
        reason: 'a file cannot vouch for who chose a category');
    final marks = await target
        .customSelect('SELECT id, source, imported_from_file FROM transactions')
        .get();
    expect(marks.map((m) => m.read<int>('imported_from_file')).toSet(), {1});
    expect(marks.map((m) => m.read<String>('source')), isNot(contains('imported')),
        reason: 'the original bank/SMS source is kept, not overwritten');

    final repo = DriftTransactionRepository(target);
    final plan = await useCase(target).previewPastUpdate(
        transaction: (await repo.getById('tx-1'))!, categoryKey: 'groceries');
    // The merchant is linked, so the rows ARE found — and all are protected.
    expect(plan.eligible, isEmpty);
    expect(plan.excluded[PastUpdateExclusion.imported]!
            .map((t) => t.id)
            .toSet(),
        {'tx-2', 'tx-3'},
        reason: 'both are found via the rebuilt link, and both are excluded');
    expect(plan.totalExcluded, 2);

    // "Include unknown origin" never pulls imported rows in.
    final withUnknown = await useCase(target).previewPastUpdate(
        transaction: (await repo.getById('tx-1'))!,
        categoryKey: 'groceries',
        overrides: const PastUpdateOverrides(includeUnknown: true));
    expect(withUnknown.eligible, isEmpty);
    expect(withUnknown.excludedCount(PastUpdateExclusion.imported), 2);

    // Only the separate imported opt-in does.
    final withImported = await useCase(target).previewPastUpdate(
        transaction: (await repo.getById('tx-1'))!,
        categoryKey: 'groceries',
        overrides: const PastUpdateOverrides(includeImported: true));
    expect(withImported.eligible.map((t) => t.id).toSet(), {'tx-2', 'tx-3'});
  });


  Future<void> importAgain(AppDatabase db, ImportMode mode) async {
    final bytes =
        (await DriftFinancialExporter(source).exportFinancialPackage()).bytes;
    await DriftFinancialImporter(db)
        .importPackage(decodeQirshPackage(bytes), mode);
  }

  test('a future import keeps the marker on rows already imported', () async {
    await seed();
    await importInto(target);
    for (final mode in ImportMode.values) {
      await importAgain(target, mode);
    }
    final marks = await target
        .customSelect('SELECT imported_from_file FROM transactions')
        .get();
    expect(marks.map((m) => m.read<int>('imported_from_file')).toSet(), {1});
  });

  Future<(String, String)> categoryOf(AppDatabase db, String id) async {
    final r = await db
        .customSelect('SELECT category_id, category_source FROM transactions '
            "WHERE id = '$id';")
        .getSingle();
    return (r.read<String>('category_id'), r.read<String>('category_source'));
  }

  for (final mode in ImportMode.values) {
    test('re-importing (${mode.name}) changes provenance only with the category',
        () async {
      await seed();
      await importInto(target);
      final food = await categoryId(target, 'restaurants');
      final groceries = await categoryId(target, 'groceries');

      // Later the user picks categories by hand on this device: tx-1 keeps
      // the file's category, tx-2 moves away from it.
      await target.customStatement(
          "UPDATE transactions SET category_source = 'user' "
          "WHERE id IN ('tx-1', 'tx-2');");
      await target.customStatement(
          "UPDATE transactions SET category_id = '$groceries' "
          "WHERE id = 'tx-2';");

      await importAgain(target, mode);
      await importAgain(target, mode);

      expect(await categoryOf(target, 'tx-1'), (food, 'user'),
          reason: 'the file agrees with the category: the hand pick is kept');
      if (mode == ImportMode.merge) {
        expect(await categoryOf(target, 'tx-2'), (groceries, 'user'),
            reason: 'merge never overwrites an existing row');
      } else {
        expect(await categoryOf(target, 'tx-2'), (food, 'unknown'),
            reason: 'the file replaced the category, so its origin is unknown');
      }
      expect((await rows(target)).length, 4,
          reason: 'a repeated import never duplicates rows');
    });
  }
}
