import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/usecases/correct_category_usecase.dart';

import '../../harness/seed_test_account.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

Future<AppDatabase> _openDb() => seededDb(AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    ));

const _t = '2026-07-01T00:00:00.000Z';
const _merchant = 'ZARYAB DIMASHQI TRDG';

Future<String> _categoryId(AppDatabase db, String key) async => (await db
        .customSelect("SELECT id FROM categories WHERE key = '$key';")
        .getSingle())
    .read<String>('id');

Future<void> _insertMerchant(AppDatabase db, String id, String raw) =>
    db.customStatement(
      "INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, "
      "last_seen_at) VALUES ('$id', '$raw', "
      "'${AppDatabase.normalizeMerchant(raw)}', '$_t', '$_t');",
    );

Future<void> _insertTx(
  AppDatabase db,
  String id, {
  required String categoryId,
  required String provenance,
  String? merchantId,
  String source = 'bank',
  String raw = _merchant,
}) async {
  await db.customStatement(
    "INSERT INTO transactions(id, amount, currency, type, source, occurred_at, "
    "raw_message, parse_confidence, status, created_at, updated_at, "
    "account_id, direction, raw_merchant, merchant_id, category_id, "
    "category_source) VALUES ('$id', 12.5, 'SAR', 'payment', '$source', "
    "'$_t', 'sms', 0.9, 'confirmed', '$_t', '$_t', "
    "'$kDefaultAccountLocalId', 'debit', '$raw', "
    "${merchantId == null ? 'NULL' : "'$merchantId'"}, '$categoryId', "
    "'$provenance');",
  );
  await backfillNonPlanningMoneyV30(db);
}

Future<Map<String, Map<String, Object?>>> _rows(AppDatabase db) async => {
      for (final r in await db
          .customSelect('SELECT t.id, t.category_source, t.merchant_id, '
              'm.normalized_name AS mn FROM transactions t '
              'LEFT JOIN merchants m ON m.id = t.merchant_id;')
          .get())
        r.read<String>('id'): r.data,
    };

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase source;
  late AppDatabase target;

  setUp(() async {
    source = await _openDb();
    target = await _openDb();
  });

  tearDown(() async {
    await source.close();
    await target.close();
  });

  Future<void> seedHistory() async {
    final food = await _categoryId(source, 'restaurants');
    await _insertMerchant(source, 'm-1', _merchant);
    await _insertTx(source, 'tx-user',
        categoryId: food, provenance: 'user', merchantId: 'm-1');
    await _insertTx(source, 'tx-rule',
        categoryId: food, provenance: 'rule', merchantId: 'm-1');
    await _insertTx(source, 'tx-auto',
        categoryId: food, provenance: 'auto', merchantId: 'm-1');
    await _insertTx(source, 'tx-edit',
        categoryId: food, provenance: 'auto', merchantId: 'm-1');
  }

  CorrectCategoryUseCase useCase(AppDatabase db) => CorrectCategoryUseCase(
        transactionRepository: DriftTransactionRepository(db),
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
      );

  test('provenance and merchant links survive backup -> restore', () async {
    await seedHistory();
    final before = await _rows(source);

    await RestoreBackupUseCase(target)(
        await BackupSnapshotBuilder(source).build());

    final after = await _rows(target);
    for (final id in ['tx-user', 'tx-rule', 'tx-auto', 'tx-edit']) {
      expect(after[id]!['category_source'], before[id]!['category_source'],
          reason: '$id provenance must survive a restore');
      expect(after[id]!['merchant_id'], 'm-1');
    }
  });

  test('a restored row with a missing or dangling link is relinked exactly',
      () async {
    await seedHistory();
    final food = await _categoryId(source, 'restaurants');
    await _insertTx(source, 'tx-unlinked',
        categoryId: food, provenance: 'auto', raw: 'zaryab  dimashqi trdg 42');
    final snapshot = await BackupSnapshotBuilder(source).build();
    // A dangling id (its merchant row is not in the backup).
    final txs = (snapshot['tables'] as Map)['transactions'] as List;
    for (final row in txs.cast<Map<String, Object?>>()) {
      if (row['id'] == 'tx-auto') row['merchant_id'] = 'missing-merchant';
    }

    await RestoreBackupUseCase(target)(snapshot);

    final after = await _rows(target);
    final key = AppDatabase.normalizeMerchant(_merchant);
    expect(after['tx-unlinked']!['mn'], key,
        reason: 'same normalised name -> the same merchant, deterministically');
    expect(after['tx-unlinked']!['merchant_id'], 'm-1');
    expect(after['tx-auto']!['merchant_id'], 'm-1',
        reason: 'a dangling link is repaired to the existing merchant');
    expect(after['tx-unlinked']!['category_source'], 'auto',
        reason: 'relinking never touches provenance');
  });

  test('a backup from before category_source restores every row as unknown',
      () async {
    await seedHistory();
    final snapshot = await BackupSnapshotBuilder(source).build();
    // An old backup simply has no such key on its rows.
    final txs = (snapshot['tables'] as Map)['transactions'] as List;
    for (final row in txs.cast<Map<String, Object?>>()) {
      row.remove('category_source');
    }

    await RestoreBackupUseCase(target)(snapshot);

    final after = await _rows(target);
    expect(after.values.map((r) => r['category_source']).toSet(), {'unknown'});
    // Unknown is excluded from a bulk update by default.
    final repo = DriftTransactionRepository(target);
    final plan = await useCase(target).previewPastUpdate(
        transaction: (await repo.getById('tx-edit'))!,
        categoryKey: 'groceries');
    expect(plan.eligible, isEmpty);
    expect(plan.excludedCount(PastUpdateExclusion.unknownOrigin), 3);
  });

  test('after a restore a hand-picked category is still protected', () async {
    await seedHistory();
    await RestoreBackupUseCase(target)(
        await BackupSnapshotBuilder(source).build());

    final repo = DriftTransactionRepository(target);
    final plan = await useCase(target).previewPastUpdate(
        transaction: (await repo.getById('tx-edit'))!,
        categoryKey: 'groceries');
    expect(plan.eligible.map((t) => t.id).toSet(), {'tx-rule', 'tx-auto'});
    expect(plan.excluded[PastUpdateExclusion.chosenByYou]!.map((t) => t.id),
        ['tx-user']);
    expect(plan.totalExcluded, 1);
  });

  test('the file-import marker survives backup -> restore and stays protected',
      () async {
    await seedHistory();
    await source.customStatement(
        "UPDATE transactions SET imported_from_file = 1 WHERE id = 'tx-rule';");
    final snapshot = await BackupSnapshotBuilder(source).build();
    await RestoreBackupUseCase(target)(snapshot);

    final marks = {
      for (final r in await target
          .customSelect('SELECT id, source, imported_from_file FROM transactions')
          .get())
        r.read<String>('id'): (r.read<String>('source'), r.read<int>('imported_from_file')),
    };
    expect(marks['tx-rule'], ('bank', 1),
        reason: 'the marker is restored and the original source kept');
    expect(marks['tx-auto'], ('bank', 0));

    final repo = DriftTransactionRepository(target);
    final plan = await useCase(target).previewPastUpdate(
        transaction: (await repo.getById('tx-edit'))!,
        categoryKey: 'groceries',
        overrides: const PastUpdateOverrides(includeUnknown: true));
    expect(plan.excluded[PastUpdateExclusion.imported]!.map((t) => t.id),
        ['tx-rule']);
    expect(plan.eligible.map((t) => t.id), ['tx-auto']);

    // An older backup has no such key: rows restore as not imported.
    final old = await BackupSnapshotBuilder(source).build();
    for (final row in ((old['tables'] as Map)['transactions'] as List)
        .cast<Map<String, Object?>>()) {
      row.remove('imported_from_file');
    }
    final again = await _openDb();
    addTearDown(again.close);
    await RestoreBackupUseCase(again)(old);
    expect(
        (await again
                .customSelect('SELECT DISTINCT imported_from_file AS v FROM transactions')
                .get())
            .map((r) => r.read<int>('v'))
            .toSet(),
        {0});
  });
}
