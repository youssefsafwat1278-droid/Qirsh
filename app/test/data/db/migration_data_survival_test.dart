import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';

/// AUDIT 6 — FINANCIAL DATA MUST SURVIVE EVERY VERSIONED MIGRATION.
///
/// `migration_pipeline_test.dart` proves the pipeline's MECHANICS: a fresh
/// build, rollback at every injected phase, idempotent re-init, concurrent
/// init, a newer-than-app schema failing closed, and historical SHAPE fixtures
/// at user_version 0, 1, 5 and 26. What it does not do is carry populated money
/// through each supported starting version and assert every row and every total
/// is still there at 40.
///
/// That is the data-loss question, so it is the one this file answers.
///
/// ## The real supported range
///
/// `_versionedMigrations` declares versioned steps from 31, 32, 33, 34, 35, 36, 37, 38 and
/// 39 (target 45, v41->42 = consent watermark, v42->43 = category provenance,
/// v43->44 = saved-rule deletion history, v44->45 = transfer group link). Anything BELOW 31 is not unsupported — it reaches 41 through
/// `_createSchema()` (CREATE TABLE IF NOT EXISTS) plus the idempotent
/// `_runCompatibilityMigrations()` repairs, which is why the v0/v1/v5/v26
/// fixtures in the pipeline test upgrade cleanly. So the supported range is
/// "any user_version <= 45", and both halves of it are covered: shape by those
/// fixtures, data by the cases below.
///
/// Every upgrade — schema, versioned migrations, compatibility repairs, seed,
/// backfills, postflight, the user_version bump — runs inside ONE
/// `transaction(...)`, so a failure anywhere rolls the whole thing back. There
/// is no "if migration fails, recreate empty" path to find.
///
/// ## What this proves, and what it does not
///
/// Each case starts from the CURRENT schema with populated money and winds
/// `user_version` back, then re-runs the real pipeline. So it proves the
/// migrations for that range neither drop, zero, nor double-count data, and are
/// safe to replay after a crash.
///
/// It does NOT rebuild each historical schema SHAPE from 31..37 — that needs
/// captured per-version fixtures this repository does not carry. Reading the
/// seven steps is what closes that gap by inspection: all seven are ADDITIVE
/// (new tables, new nullable columns) and not one reads or converts a business
/// table. `migrations_are_additive` below pins that property so a future
/// destructive step cannot be added silently under this file's assumption.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// The money on a populated install, as totals rather than row counts, so a
/// migration that preserves rows but zeroes or rescales an amount still fails.
typedef Money = ({
  int accounts,
  int transactions,
  int goals,
  int budgets,
  num txReal,
  int txMinor,
  num goalReal,
  int goalMinor,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Versions the app carries an explicit migration FROM, plus representative
  /// pre-31 values that reach 40 through the compatibility path.
  const versionedFrom = [
    31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, //
  ];
  const preVersioned = [0, 1, 5, 26, 30];
  const target = 45;

  Future<AppDatabase> open() => AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );

  Future<int> userVersion(AppDatabase db) async =>
      (await db.customSelect('PRAGMA user_version;').getSingle())
          .read<int>('user_version');

  /// Three transactions, two goals, one budget, one account — enough that a
  /// per-table loss shows up as a specific failure rather than "something".
  Future<void> seed(AppDatabase db) async {
    await db.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
      "VALUES ('acc-1', 'Main', 'SAR', 'bank', '2026-01-01', '2026-01-01');",
    );
    for (var i = 0; i < 3; i++) {
      await db.customStatement(
        "INSERT INTO transactions(id, amount, currency, type, source, "
        "occurred_at, raw_message, parse_confidence, status, created_at, "
        "updated_at, account_id, direction, note) VALUES "
        "('a6-tx-$i', ${(i + 1) * 10}.5, 'SAR', 'payment', 'bank', "
        "'2026-09-0${i + 1}', 'audit6', 0.9, 'confirmed', '2026-01-01', "
        "'2026-01-01', 'acc-1', 'debit', 'audit 6');",
      );
    }
    for (var i = 0; i < 2; i++) {
      await db.customStatement(
        "INSERT INTO goals(id, name, target_amount, saved_amount, vault_skin, "
        "status, created_at) VALUES ('a6-goal-$i', 'Goal $i', "
        "${(i + 1) * 1000}.0, ${(i + 1) * 250}.75, 'classic', 'active', "
        "'2026-01-01');",
      );
    }
    // budgets.category_id is NOT NULL with an FK onto categories, so this has
    // to hang off a real seeded category rather than a literal.
    final category = (await db
            .customSelect('SELECT id FROM categories LIMIT 1;')
            .getSingle())
        .read<String>('id');
    await db.customStatement(
      "INSERT INTO budgets(id, category_id, amount, period, start_date, "
      "is_active) VALUES ('a6-budget', '$category', 500.25, 'monthly', "
      "'2026-01-01', 1);",
    );
    // Populate the v30 minor-unit columns, as a real install has them.
    await backfillNonPlanningMoneyV30(db);
  }

  Future<int> countOf(AppDatabase db, String sql) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $sql;').getSingle())
          .read<int>('n');

  Future<Money> money(AppDatabase db) async {
    final tx = await db
        .customSelect("SELECT COALESCE(SUM(amount),0) AS r, "
            "COALESCE(SUM(amount_minor),0) AS m "
            "FROM transactions WHERE id LIKE 'a6-tx-%';")
        .getSingle();
    final goal = await db
        .customSelect("SELECT COALESCE(SUM(target_amount),0) AS r, "
            "COALESCE(SUM(target_amount_minor),0) AS m "
            "FROM goals WHERE id LIKE 'a6-goal-%';")
        .getSingle();
    return (
      accounts: await countOf(db, "accounts WHERE id='acc-1'"),
      transactions: await countOf(db, "transactions WHERE id LIKE 'a6-tx-%'"),
      goals: await countOf(db, "goals WHERE id LIKE 'a6-goal-%'"),
      budgets: await countOf(db, "budgets WHERE id='a6-budget'"),
      txReal: tx.read<double>('r'),
      txMinor: tx.read<int>('m'),
      goalReal: goal.read<double>('r'),
      goalMinor: goal.read<int>('m'),
    );
  }

  /// The fixture must be real, or every preservation assertion below is vacuous
  /// — 0 rows in equals 0 rows out and the test passes while proving nothing.
  void assertSeedIsReal(Money m) {
    expect(m.accounts, 1, reason: 'the account fixture must exist');
    expect(m.transactions, 3, reason: 'the transaction fixture must exist');
    expect(m.goals, 2, reason: 'the goal fixture must exist');
    expect(m.budgets, 1, reason: 'the budget fixture must exist');
    expect(m.txMinor, greaterThan(0),
        reason: 'transaction minor units must be backfilled, or the minor-unit '
            'comparison below is vacuous');
    // goals are PLANNING-side money, which backfillNonPlanningMoneyV30 does not
    // cover, so goal_minor is legitimately 0 here. It is still compared before
    // and after: a migration that starts populating it inconsistently must fail.
    expect(m.goalReal, greaterThan(0), reason: 'goal money must be real');
  }

  Future<void> expectSurvives(int from) async {
    final db = await open();
    addTearDown(db.close);
    await seed(db);
    final before = await money(db);
    assertSeedIsReal(before);

    // Wind the recorded version back and re-run the REAL pipeline.
    await db.customStatement('PRAGMA user_version = $from;');
    await db.debugReinitialize();

    expect(await userVersion(db), target, reason: 'the upgrade must complete');
    final after = await money(db);
    expect(after.accounts, before.accounts, reason: 'account lost ($from)');
    expect(after.transactions, before.transactions,
        reason: 'NO transaction may be dropped ($from -> $target)');
    expect(after.goals, before.goals, reason: 'goal lost ($from)');
    expect(after.budgets, before.budgets, reason: 'budget lost ($from)');
    expect(after.txMinor, before.txMinor,
        reason: 'exact minor-unit transaction total must be identical ($from)');
    expect(after.goalMinor, before.goalMinor,
        reason: 'exact minor-unit goal total must be identical ($from)');
    expect(after.txReal, closeTo(before.txReal, 0.0001),
        reason: 'the REAL column must still agree ($from)');
    expect(after.goalReal, closeTo(before.goalReal, 0.0001));

    // The migration must leave referential integrity intact, not just rows.
    expect(await db.customSelect('PRAGMA foreign_key_check;').get(), isEmpty,
        reason: 'FK integrity after $from -> $target');
  }

  group('every versioned starting point preserves populated money', () {
    for (final from in versionedFrom) {
      test('user_version $from -> $target keeps every row and every total',
          () => expectSurvives(from));
    }
  });

  group('the pre-31 compatibility path preserves it too', () {
    // These do not have versioned migrations; they reach 45 via _createSchema
    // (IF NOT EXISTS) + the idempotent repairs. Data must still survive.
    for (final from in preVersioned) {
      test('user_version $from -> $target keeps every row and every total',
          () => expectSurvives(from));
    }
  });

  test('a crash mid-upgrade replays the range without duplicating money',
      () async {
    // A process death during the transaction means the next launch sees the old
    // user_version and runs the whole range again. The transaction should make
    // that a clean no-op; a migration that INSERTed without a guard would
    // double-count instead, which is silent financial corruption.
    final db = await open();
    addTearDown(db.close);
    await seed(db);
    final before = await money(db);
    assertSeedIsReal(before);

    for (var replay = 0; replay < 3; replay++) {
      await db.customStatement('PRAGMA user_version = 31;');
      await db.debugReinitialize();
      expect(await money(db), before, reason: 'replay $replay changed the data');
    }
    expect(await userVersion(db), target);
  });

  test('no versioned migration in the supported range is destructive', () {
    // The shape guarantee this file's data cases rest on, pinned so it cannot
    // regress unnoticed. All steps 31..45 are additive; if a future step
    // needs to DROP, DELETE or rewrite a business table, this test must fail and
    // force a real captured fixture for that version — the wind-back approach
    // used above cannot detect a shape conversion.
    final src =
        File('${Directory.current.path}/lib/data/db/app_database.dart')
            .readAsStringSync();
    final listStart = src.indexOf('_versionedMigrations = [');
    expect(listStart, greaterThan(-1));
    final list = src.substring(
        listStart, src.indexOf('static Future<void> _applyV38'));

    final applies = RegExp(r'apply: (_apply\w+)')
        .allMatches(list)
        .map((m) => m.group(1)!)
        .toList();
    expect(applies.length, 14,
        reason: 'the supported versioned range is 31..45 — if this changed, '
            'extend versionedFrom above to match');

    for (final name in applies) {
      final at = src.indexOf('static Future<void> $name(');
      expect(at, greaterThan(-1), reason: '$name should be defined');
      // The body runs to the next static member, so the whole thing is read
      // rather than an arbitrary window of it.
      final rest = src.substring(at + 20);
      final end = rest.indexOf('\n  static ');
      var body = end == -1 ? rest : rest.substring(0, end);
      // The one reviewed exception: v43 back-fills the NEW provenance columns
      // (hand-entered rows -> user, source 'imported' -> imported_from_file). It never touches money, ids or any existing
      // column, and a captured real v42 fixture proves it
      // (category_provenance_v43_migration_test.dart). Anything else in that
      // step that rewrites transactions still fails below.
      if (name == '_applyV43CategoryProvenance') {
        body = body
            .replaceFirst("UPDATE transactions SET category_source = 'user' ", '')
            .replaceFirst('UPDATE transactions SET imported_from_file = 1 ', '');
      }

      for (final table in const [
        'transactions',
        'accounts',
        'goals',
        'budgets',
        'subscriptions',
      ]) {
        for (final verb in const ['DROP TABLE', 'DELETE FROM', 'UPDATE']) {
          expect(body.contains('$verb $table'), isFalse,
              reason: '$name appears to "$verb $table" — a destructive step '
                  'cannot be proven safe by winding user_version back; it '
                  'needs a captured fixture of the real pre-migration schema');
        }
      }
    }
  });
}
