// v44 -> v45: transactions.transfer_group_id links the two legs of a transfer
// between the user's own accounts. Additive only: one nullable column and an
// index, no row rewritten. Synthetic data only.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> open() => AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );

  Future<int> userVersion(AppDatabase db) async =>
      (await db.customSelect('PRAGMA user_version;').getSingle())
          .read<int>('user_version');

  Future<Set<String>> columns(AppDatabase db) async => {
        for (final r in await db
            .customSelect("SELECT name FROM pragma_table_info('transactions');")
            .get())
          r.read<String>('name'),
      };

  Future<bool> hasIndex(AppDatabase db) async =>
      (await db
          .customSelect("SELECT 1 AS x FROM sqlite_master WHERE type = 'index' "
              "AND name = 'idx_transactions_transfer_group';")
          .getSingleOrNull()) !=
      null;

  test('a fresh install is at 45 with the column and its index', () async {
    final db = await open();
    addTearDown(db.close);
    expect(await userVersion(db), 45);
    expect(await columns(db), contains('transfer_group_id'));
    expect(await hasIndex(db), isTrue);
  });

  test('v44 -> v45 keeps every row and adds a NULL column', () async {
    final db = await open();
    addTearDown(db.close);
    await db.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
      "VALUES ('acc-1', 'Main', 'SAR', 'bank', '2026-01-01', '2026-01-01');",
    );
    for (final (id, type, direction) in [
      ('t-pay', 'payment', 'debit'),
      ('t-out', 'transfer', 'debit'),
      ('t-in', 'transfer', 'credit'),
    ]) {
      await db.customStatement(
        "INSERT INTO transactions(id, amount, currency, type, source, "
        "occurred_at, raw_message, parse_confidence, status, created_at, "
        "updated_at, account_id, direction) VALUES ('$id', 12.5, 'SAR', "
        "'$type', 'bank', '2026-09-01', 'v44', 0.9, 'confirmed', "
        "'2026-01-01', '2026-01-01', 'acc-1', '$direction');",
      );
    }
    await backfillNonPlanningMoneyV30(db);
    // Let the always-on repairs (system category backfill) settle first, so
    // the comparison below sees only what the v45 step does.
    await db.debugReinitialize();
    // Wind back to the exact v44 shape: no index, no column.
    await db.customStatement(
        'DROP INDEX IF EXISTS idx_transactions_transfer_group;');
    await db.customStatement(
        'ALTER TABLE transactions DROP COLUMN transfer_group_id;');
    await db.customStatement('PRAGMA user_version = 44;');
    expect(await columns(db), isNot(contains('transfer_group_id')));
    final before = await db
        .customSelect('SELECT * FROM transactions ORDER BY id;')
        .get()
        .then((rows) => [for (final r in rows) r.data]);

    await db.debugReinitialize();

    expect(await userVersion(db), 45);
    expect(await hasIndex(db), isTrue);
    final after = await db
        .customSelect('SELECT * FROM transactions ORDER BY id;')
        .get()
        .then((rows) => [for (final r in rows) r.data]);
    expect(after, hasLength(before.length));
    for (var i = 0; i < before.length; i++) {
      final row = Map.of(after[i]);
      expect(row.remove('transfer_group_id'), isNull);
      expect(row, before[i], reason: 'no existing value may change');
    }
  });
}
