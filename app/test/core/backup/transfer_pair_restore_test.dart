// The link between the two legs of an own-account transfer
// (transactions.transfer_group_id) survives backup -> restore; an older backup
// without it restores as unlinked; a merge restore keeps both legs exactly
// once. Synthetic data only.
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/transfer_pair_service.dart';
import 'package:money_companion/domain/finance/money.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

Future<AppDatabase> _openDb() async {
  final db = await AppDatabase.open(
    executor: NativeDatabase.memory(),
    keyStore: _MemoryKeyStore(),
  );
  for (final (id, order) in [('acc-a', 0), ('acc-b', 1)]) {
    await db.customStatement(
      "INSERT INTO accounts(id, name, currency, type, is_default, sort_order, "
      "created_at, updated_at) VALUES('$id', '$id', 'SAR', 'bank', "
      "${order == 0 ? 1 : 0}, $order, '2026-01-01T00:00:00Z', "
      "'2026-01-01T00:00:00Z');",
    );
  }
  return db;
}

Future<void> _savePair(AppDatabase db) => TransferPairService(
      db: db,
      transactions: DriftTransactionRepository(db),
      bills: DriftBillRepository(db),
    ).savePair(
      fromAccountId: 'acc-a',
      toAccountId: 'acc-b',
      amountOut: Money.parse('300', 'SAR'),
      amountIn: Money.parse('300', 'SAR'),
      currencyOut: 'SAR',
      currencyIn: 'SAR',
      occurredAt: DateTime.utc(2026, 7, 15, 10),
    );

Future<Map<String, (String?, String?, String)>> _legs(AppDatabase db) async =>
    {
      for (final r in await db
          .customSelect("SELECT id, account_id, transfer_group_id, status "
              "FROM transactions WHERE type = 'transfer';")
          .get())
        r.read<String>('id'): (
          r.readNullable<String>('account_id'),
          r.readNullable<String>('transfer_group_id'),
          r.read<String>('status'),
        ),
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

  test('backup -> restore keeps the group id on both legs', () async {
    await _savePair(source);
    final before = await _legs(source);
    expect(before, hasLength(2));
    expect(before.values.map((l) => l.$2).toSet(), hasLength(1));

    await RestoreBackupUseCase(target)(
        await BackupSnapshotBuilder(source).build());

    expect(await _legs(target), before);
  });

  test('an old backup without the column restores both legs unlinked',
      () async {
    await _savePair(source);
    final snapshot = await BackupSnapshotBuilder(source).build();
    for (final row in ((snapshot['tables'] as Map)['transactions'] as List)
        .cast<Map<String, Object?>>()) {
      row.remove('transfer_group_id');
    }

    await RestoreBackupUseCase(target)(snapshot);

    final legs = await _legs(target);
    expect(legs, hasLength(2));
    expect(legs.values.map((l) => l.$2).toSet(), {null});
  });

  test('a merge restore of a pair the device already holds keeps both legs once',
      () async {
    await _savePair(source);
    final snapshot = await BackupSnapshotBuilder(source).build();
    // The device already holds the same pair (an earlier restore of it).
    await RestoreBackupUseCase(target)(snapshot);
    final before = await _legs(target);
    expect(await RestoreBackupUseCase.restoreWillMerge(target), isTrue);

    await RestoreBackupUseCase(target)(
        await BackupSnapshotBuilder(source).build());

    expect(await _legs(target), before);
  });

  test('a merge restore into a device with its own data adds both legs',
      () async {
    await _savePair(source);
    // The device has its own, different pair with the same amount and time.
    await _savePair(target);
    final own = await _legs(target);

    await RestoreBackupUseCase(target)(
        await BackupSnapshotBuilder(source).build());

    final after = await _legs(target);
    expect(after, hasLength(4), reason: 'no leg is dropped as a duplicate');
    expect(after, containsPair(own.keys.first, own.values.first));
    final sourceLegs = await _legs(source);
    for (final e in sourceLegs.entries) {
      expect(after[e.key], e.value);
    }
  });
}
