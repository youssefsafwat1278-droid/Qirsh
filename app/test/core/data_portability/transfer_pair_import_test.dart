// A portable export -> import keeps the link between the two legs of an
// own-account transfer; a file from before the column imports them unlinked.
// Synthetic data only.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/data_portability/drift_financial_exporter.dart';
import 'package:money_companion/core/data_portability/drift_financial_importer.dart';
import 'package:money_companion/core/data_portability/qirsh_package_codec.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/transfer_pair_service.dart';
import 'package:money_companion/domain/finance/money.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _database() async {
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

Future<Map<String, (String?, String?, String?)>> _legs(AppDatabase db) async =>
    {
      for (final r in await db
          .customSelect("SELECT id, account_id, transfer_group_id, direction "
              "FROM transactions WHERE type = 'transfer';")
          .get())
        r.read<String>('id'): (
          r.readNullable<String>('account_id'),
          r.readNullable<String>('transfer_group_id'),
          r.readNullable<String>('direction'),
        ),
    };

void main() {
  late AppDatabase source;
  late AppDatabase target;

  setUp(() async {
    source = await _database();
    target = await _database();
    await TransferPairService(
      db: source,
      transactions: DriftTransactionRepository(source),
      bills: DriftBillRepository(source),
    ).savePair(
      fromAccountId: 'acc-a',
      toAccountId: 'acc-b',
      amountOut: Money.parse('300', 'SAR'),
      amountIn: Money.parse('300', 'SAR'),
      currencyOut: 'SAR',
      currencyIn: 'SAR',
      occurredAt: DateTime.utc(2026, 7, 15, 10),
    );
  });
  tearDown(() async {
    await source.close();
    await target.close();
  });

  Future<QirshPackageData> exported() async => decodeQirshPackage(
      (await DriftFinancialExporter(source).exportFinancialPackage()).bytes);

  for (final mode in ImportMode.values) {
    test('export -> import (${mode.name}) keeps the link', () async {
      final before = await _legs(source);
      expect(before.values.map((l) => l.$2).toSet(), hasLength(1));
      await DriftFinancialImporter(target).importPackage(await exported(), mode);
      expect(await _legs(target), before);
    });
  }

  test('a file from before the column imports both legs unlinked', () async {
    final package = await exported();
    for (final row in package.tables['transactions']!.rows) {
      row.remove('transfer_group_id');
    }
    await DriftFinancialImporter(target)
        .importPackage(package, ImportMode.merge);
    final legs = await _legs(target);
    expect(legs, hasLength(2));
    expect(legs.values.map((l) => l.$2).toSet(), {null});
  });
}
