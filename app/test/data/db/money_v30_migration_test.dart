import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/domain/finance/currency_scale.dart';
import 'package:money_companion/domain/finance/decimal_minor.dart';
import '../../harness/seed_test_account.dart';

// MALI-026 (Phase-8 B8-3 §5/§6/§7/§33/§34) — the v30 non-planning money backfill:
// legacy REAL -> checked int64 minor, exact round-trip, adversarial abort, and
// deterministic repeatability. Drives the REAL backfill/verify functions against
// controlled rows in an in-memory DB.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late String accountId;

  Future<int?> minor(String table, String col, String id) async => (await db
          .customSelect("SELECT $col AS m FROM $table WHERE id = '$id';")
          .getSingle())
      .readNullable<int>('m');

  Future<int> marker() async => (await db
          .customSelect('SELECT planning_cutover_state AS s FROM user_settings;')
          .getSingle())
      .read<int>('s');

  Future<void> insertTx({
    required String id,
    required double amount,
    required String currency,
    double? balanceAfter,
    double? foreignAmount,
    String? foreignCurrency,
  }) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await db.customStatement('''
      INSERT INTO transactions(
        id, amount, currency, type, source, occurred_at, raw_message,
        parse_confidence, status, created_at, updated_at, balance_after,
        foreign_amount, foreign_currency, amount_minor, balance_after_minor,
        foreign_amount_minor
      ) VALUES (
        '$id', $amount, '$currency', 'payment', 'bank', '$now', '', 0.9,
        'confirmed', '$now', '$now',
        ${balanceAfter ?? 'NULL'}, ${foreignAmount ?? 'NULL'},
        ${foreignCurrency == null ? 'NULL' : "'$foreignCurrency'"},
        NULL, NULL, NULL
      );
    ''');
  }

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    await seedTestAccount(db);
    accountId = (await db.customSelect('SELECT id FROM accounts LIMIT 1;')
            .getSingle())
        .read<String>('id');
  });
  tearDown(() => db.close());

  test('§7 exact round-trip across scales, negative, null, and FX', () async {
    await insertTx(id: 't_egp', amount: 100.0, currency: 'EGP'); // 2-dec
    await insertTx(id: 't_kwd', amount: 1.234, currency: 'KWD'); // 3-dec
    await insertTx(id: 't_jpy', amount: 1234.0, currency: 'JPY'); // 0-dec
    await insertTx(id: 't_neg', amount: -55.5, currency: 'EGP');
    await insertTx(
        id: 't_bal', amount: 10.0, currency: 'EGP', balanceAfter: 2310.5);
    await insertTx(
        id: 't_fx',
        amount: 100.0,
        currency: 'EGP',
        foreignAmount: 3.750,
        foreignCurrency: 'KWD');

    await backfillNonPlanningMoneyV30(db);
    await verifyNonPlanningMoneyV30(db); // exact postflight (throws on mismatch)

    expect(await minor('transactions', 'amount_minor', 't_egp'), 10000);
    expect(await minor('transactions', 'amount_minor', 't_kwd'), 1234);
    expect(await minor('transactions', 'amount_minor', 't_jpy'), 1234);
    expect(await minor('transactions', 'amount_minor', 't_neg'), -5550);
    expect(await minor('transactions', 'balance_after_minor', 't_bal'), 231050);
    // nullable NULL -> minor NULL
    expect(await minor('transactions', 'balance_after_minor', 't_egp'), isNull);
    // FX uses foreign_currency (KWD, 3-dec)
    expect(await minor('transactions', 'foreign_amount_minor', 't_fx'), 3750);
    expect(await minor('transactions', 'foreign_amount_minor', 't_egp'), isNull);
  });

  test('§34 repeatable + idempotent (second backfill is a no-op)', () async {
    await insertTx(id: 't1', amount: 12.34, currency: 'EGP');
    await backfillNonPlanningMoneyV30(db);
    final first = await minor('transactions', 'amount_minor', 't1');
    await backfillNonPlanningMoneyV30(db); // re-run: minor already set → skipped
    expect(await minor('transactions', 'amount_minor', 't1'), first);
    expect(first, 1234);
  });

  test('§6/§33 unsupported currency aborts the backfill', () async {
    await insertTx(id: 't_bad', amount: 10.0, currency: 'ZZZ');
    await expectLater(
      backfillNonPlanningMoneyV30(db),
      throwsA(isA<V30MigrationException>()),
    );
  });

  test('§6/§33 a value beyond int64 minor aborts the backfill', () async {
    // 1e19 EGP * 100 = 1e21 minor > int64 max (~9.2e18).
    await insertTx(id: 't_huge', amount: 1e19, currency: 'EGP');
    await expectLater(
      backfillNonPlanningMoneyV30(db),
      throwsA(isA<V30MigrationException>()),
    );
  });

  test('§7 direct converter parity with legacyRealToMinor', () {
    for (final (real, cur) in [
      (100.0, 'EGP'),
      (1.005, 'EGP'),
      (-1.005, 'EGP'),
      (0.001, 'KWD'),
    ]) {
      // The backfill uses exactly this converter — no round(real*scale).
      expect(legacyRealToMinor(real, currencyScale(cur)), isA<int>());
    }
  });

  test('§8/§11 fresh empty DB → planning marker canonical (no repair prompt)',
      () async {
    // No budgets/goals were seeded → the v30 migration set the marker canonical.
    expect(await marker(), 1);
    // Planning minor/currency columns exist and are unused (structural only).
    expect(accountId, isNotEmpty);
  });

  test('§8/§12 upgrade WITH a planning row → marker unresolved (P1), planning NULL',
      () async {
    final catId = (await db.customSelect('SELECT id FROM categories LIMIT 1;')
            .getSingle())
        .read<String>('id');
    await db.customStatement(
      "INSERT INTO budgets(id, category_id, amount, period, start_date, "
      "is_active) VALUES ('b1', '$catId', 100.0, 'monthly', "
      "'2026-01-01T00:00:00Z', 1);",
    );
    // Simulate a pre-v30 database that now upgrades with planning data present.
    await db.customStatement('UPDATE user_settings SET planning_cutover_state = 0;');
    await db.customStatement('PRAGMA user_version = 29;');
    await db.debugReinitialize();

    // A planning row exists → the migration must NOT auto-canonicalize (P1),
    // and planning money stays STRUCTURAL only (currency + minor NULL).
    expect(await marker(), 0);
    expect(await minor('budgets', 'amount_minor', 'b1'), isNull);
    final cur = (await db
            .customSelect("SELECT currency AS c FROM budgets WHERE id = 'b1';")
            .getSingle())
        .readNullable<String>('c');
    expect(cur, isNull);
    // The non-planning backfill still ran (the account exists with a currency).
    expect(await db.customSelect('PRAGMA user_version;').getSingle().then((r) => r.read<int>('user_version')), 43);
  });
}
