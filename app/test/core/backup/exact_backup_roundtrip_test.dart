import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/planning_cutover.dart';

// MALI-026 (B8-3 Step 5 §5) — the exact backup round-trip: a canonical v30 DB →
// v4 backup → fresh DB → restore must preserve Money IDENTITY (minorUnits +
// currency), NOT approximate decimal equality. Covers 0/2/3-decimal currencies,
// negative, nullable, FX, every money-bearing entity, a value > 2^53 minor, and
// near the signed-int64 boundary (all in a non-planning field, where the exact
// minor is authoritative and the lossy REAL shadow is irrelevant).

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  // A restore mirrors the restored language into the keychain for the unlock
  // prompt (core/security/lock_prompt_language.dart); this suite has no
  // keychain, so it gets an in-memory one.
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> open() =>
      AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

  const now = '2026-08-01T00:00:00.000Z';

  Future<void> seedCanonical(AppDatabase db) async {
    final categoryId = (await db
            .customSelect('SELECT id FROM categories LIMIT 1;')
            .getSingle())
        .read<String>('id');

    // Account: 2-decimal SAR, a NEGATIVE current balance, a NULL credit_limit.
    await db.customStatement(
      "INSERT INTO accounts(id,name,currency,type,initial_balance,current_balance,"
      "credit_limit,available_credit,is_default,sort_order,created_at,updated_at) "
      "VALUES ('acc-x','X','SAR','bank',1234.56,-50.00,NULL,100.00,0,5,'$now','$now');",
    );

    Future<void> tx(String id, double amount, String currency, String type,
        {double? foreignAmount, String? foreignCurrency}) async {
      await db.customInsert(
        'INSERT INTO transactions(id, amount, currency, raw_merchant, category_id, '
        'type, source, occurred_at, raw_message, parse_confidence, status, '
        'created_at, updated_at, foreign_amount, foreign_currency) '
        'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);',
        variables: [
          Variable.withString(id),
          Variable.withReal(amount),
          Variable.withString(currency),
          Variable.withString('Shop'),
          Variable.withString(categoryId),
          Variable.withString(type),
          Variable.withString('manual'),
          Variable.withString(now),
          Variable.withString('RAW'),
          Variable.withReal(1.0),
          Variable.withString('confirmed'),
          Variable.withString(now),
          Variable.withString(now),
          if (foreignAmount == null)
            const Variable(null)
          else
            Variable.withReal(foreignAmount),
          if (foreignCurrency == null)
            const Variable(null)
          else
            Variable.withString(foreignCurrency),
        ],
      );
    }

    await tx('tx-jpy', 1000, 'JPY', 'payment'); // 0-decimal
    await tx('tx-neg', -12.34, 'EGP', 'refund'); // negative, 2-decimal
    await tx('tx-fx', 100.000, 'KWD', 'payment', // 3-decimal + FX
        foreignAmount: 32.50, foreignCurrency: 'SAR');
    await tx('tx-big', 0, 'JPY', 'payment'); // amount_minor overridden below

    // Subscription: EGP, nullable manual_paid/total_purchase left null.
    await db.customStatement(
      "INSERT INTO merchants(id,raw_name,normalized_name,first_seen_at,"
      "last_seen_at) VALUES ('m-x','Net','net','$now','$now');",
    );
    await db.customStatement(
      "INSERT INTO subscriptions(id,merchant_id,amount,period,next_due_date,"
      "is_confirmed,reminder_on,name,type,currency,frequency,created_at,status) "
      "VALUES ('sub-x','m-x',49.99,'monthly','$now',1,1,'Net','subscription','EGP',"
      "'monthly','$now','active');",
    );
    // Plan: SAR.
    await db.customStatement(
      "INSERT INTO plans(id,name,budget_amount,currency,start_date,end_date,"
      "account_ids,card_last4s,status,created_at) VALUES "
      "('plan-x','Trip',2000.00,'SAR','$now','$now','','','active','$now');",
    );

    // Populate every NON-planning `_minor` consistently from REAL.
    await backfillNonPlanningMoneyV30(db);

    // A value > 2^53 minor + near the int64 boundary — authoritative minor set
    // directly (the REAL shadow cannot represent it; the exact minor must survive).
    await db.customStatement(
      "UPDATE transactions SET amount_minor = 9007199254740993 WHERE id='tx-jpy';",
    );
    await db.customStatement(
      "UPDATE transactions SET amount_minor = 9223372036854775807 WHERE id='tx-big';",
    );

    // Planning (canonical): budget (EGP), goal (KWD 3-dec) + contribution.
    await db.customStatement(
      "INSERT INTO budgets(id,category_id,currency,amount,amount_minor,period,"
      "start_date,is_active,last_notified_spent_amount,"
      "last_notified_spent_amount_minor,last_notified_period_start) VALUES "
      "('bud-x','$categoryId','EGP',500.00,50000,'monthly','$now',1,0,0,'$now');",
    );
    await db.customStatement(
      "INSERT INTO goals(id,name,currency,target_amount,target_amount_minor,"
      "saved_amount,saved_amount_minor,last_notified_saved_amount,"
      "last_notified_saved_amount_minor,vault_skin,status,created_at) VALUES "
      "('goal-x','G','KWD',1.005,1005,0.250,250,0,0,'classic','active','$now');",
    );
    await db.customStatement(
      "INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at) "
      "VALUES ('gc-x','goal-x',0.125,125,'$now');",
    );
  }

  Future<Map<String, Object?>> readMoney(
      AppDatabase db, String sql) async {
    return (await db.customSelect(sql).getSingle()).data;
  }

  test('§5 canonical v30 DB → v4 backup → fresh DB → restore preserves Money '
      'identity across every currency scale, sign, null, FX and int64 extreme',
      () async {
    final src = await open();
    addTearDown(src.close);
    await seedCanonical(src);
    final snapshot = await BackupSnapshotBuilder(src).build();

    // Sanity: the snapshot serializes minor as decimal-integer STRINGS (§2).
    final wire = jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>;
    final txRows = ((wire['tables'] as Map)['transactions'] as List)
        .cast<Map<String, dynamic>>();
    final bigRow = txRows.firstWhere((r) => r['id'] == 'tx-big');
    expect(bigRow['amount_minor'], '9223372036854775807');
    expect(bigRow['amount_minor'], isA<String>());
    expect(wire['schemaVersion'], 5);

    final dst = await open();
    addTearDown(dst.close);
    await RestoreBackupUseCase(dst).call(snapshot);

    // Every money field: minor + currency identical after the round-trip.
    Future<void> same(String table, String id, List<String> minorCols,
        {String currencyCol = 'currency'}) async {
      final cols = [...minorCols, currencyCol].join(', ');
      final a = await readMoney(
          src, "SELECT $cols FROM $table WHERE id='$id';");
      final b = await readMoney(
          dst, "SELECT $cols FROM $table WHERE id='$id';");
      expect(b, a, reason: '$table.$id');
    }

    await same('accounts', 'acc-x', [
      'initial_balance_minor',
      'current_balance_minor',
      'credit_limit_minor',
      'available_credit_minor',
    ]);
    await same('transactions', 'tx-jpy', ['amount_minor']);
    await same('transactions', 'tx-neg', ['amount_minor']);
    await same('transactions', 'tx-fx', ['amount_minor', 'foreign_amount_minor'],
        currencyCol: 'foreign_currency');
    await same('transactions', 'tx-big', ['amount_minor']);
    await same('subscriptions', 'sub-x',
        ['amount_minor', 'manual_paid_amount_minor']);
    await same('plans', 'plan-x', ['budget_amount_minor']);
    await same('budgets', 'bud-x',
        ['amount_minor', 'last_notified_spent_amount_minor']);
    await same('goals', 'goal-x', ['target_amount_minor', 'saved_amount_minor']);
    // Contribution has no currency of its own — assert the exact minor only.
    final gcA = await readMoney(
        src, "SELECT amount_minor FROM goal_contributions WHERE id='gc-x';");
    final gcB = await readMoney(
        dst, "SELECT amount_minor FROM goal_contributions WHERE id='gc-x';");
    expect(gcB, gcA);

    // Spot-check the exact extremes survived verbatim.
    final big = await dst
        .customSelect("SELECT amount_minor AS m FROM transactions WHERE id='tx-big';")
        .getSingle();
    expect(big.read<int>('m'), 9223372036854775807);
    final over2p53 = await dst
        .customSelect("SELECT amount_minor AS m FROM transactions WHERE id='tx-jpy';")
        .getSingle();
    expect(over2p53.read<int>('m'), 9007199254740993);
  });

  test('§4 a v4/exact snapshot restores into a CANONICAL DB with NO repair '
      'prompt and identical planning currency/minor', () async {
    final src = await open();
    addTearDown(src.close);
    await seedCanonical(src);
    final snapshot = await BackupSnapshotBuilder(src).build();

    final dst = await open();
    addTearDown(dst.close);
    // A canonical (P3) live coordinator would DEMAND a repair for a currency-less
    // legacy payload; a v4 snapshot carries planning currency, so the preflight is
    // satisfied and no decision is required.
    await RestoreBackupUseCase(
      dst,
      coordinator:
          const FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical),
    ).call(snapshot); // must NOT throw RestorePlanningRepairRequiredException

    final b = await dst
        .customSelect("SELECT currency, amount_minor AS m FROM budgets WHERE id='bud-x';")
        .getSingle();
    expect(b.read<String>('currency'), 'EGP');
    expect(b.read<int>('m'), 50000);
    final g = await dst
        .customSelect("SELECT currency, target_amount_minor AS t FROM goals WHERE id='goal-x';")
        .getSingle();
    expect(g.read<String>('currency'), 'KWD');
    expect(g.read<int>('t'), 1005);
    // Marker reconciled to canonical from the actual restored data.
    final marker = await dst
        .customSelect('SELECT planning_cutover_state AS s FROM user_settings LIMIT 1;')
        .getSingle();
    expect(marker.read<int>('s'), 1);
  });
}
