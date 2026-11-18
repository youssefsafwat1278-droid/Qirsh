import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/domain/finance/currency_scale.dart';
import 'package:money_companion/domain/finance/decimal_minor.dart';

// MALI-026 (B8-3 Step 5 Commit 4 §11/§2/§1) — v30 schema inventory reconciliation,
// deterministic migration repeatability, and the exact-rounding fixture edges.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _openV30() =>
    AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

Future<Set<String>> _columns(AppDatabase db, String table) async {
  final rows = await db.customSelect('PRAGMA table_info($table);').get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── §11 schema inventory reconciliation ───────────────────────────────────

  test('§11 the v30 schema carries exactly 20 persisted _minor columns + the 3 '
      'authority columns; every field is owned', () async {
    final db = await _openV30();
    addTearDown(db.close);

    // Exactly 20 minor columns in the authoritative map.
    expect(kV30MinorColumns.length, 20);

    // Every declared _minor column actually exists in the live schema.
    final tables = kV30MinorColumns.map((c) => c.table).toSet();
    final cols = {for (final t in tables) t: await _columns(db, t)};
    for (final c in kV30MinorColumns) {
      expect(cols[c.table], contains(c.minorColumn),
          reason: '${c.table}.${c.minorColumn} missing from v30 schema');
    }

    // The 3 planning authority columns.
    expect(await _columns(db, 'budgets'), contains('currency'));
    expect(await _columns(db, 'goals'), contains('currency'));
    expect(await _columns(db, 'user_settings'), contains('planning_cutover_state'));

    // The database converges on the app's current target version. The v30 MONEY
    // contract asserted above is unchanged by later additive bumps (v31 added
    // only the refetchable coupon catalog cache).
    final v = await db.customSelect('PRAGMA user_version;').getSingle();
    expect(v.read<int>('user_version'), 44);
  });

  // ── §2 deterministic migration repeatability ──────────────────────────────

  test('§2 identical fixtures migrate to IDENTICAL minor/currency (independent '
      'runs, no iteration-order dependence)', () async {
    Future<List<Map<String, Object?>>> runOnce() async {
      final db = await _openV30();
      addTearDown(db.close);
      // A v29-shaped fixture: REAL + currency, `_minor` NULL (post-upgrade state).
      for (final t in [
        ('a', 12.34, 'EGP'),
        ('b', 1000.0, 'JPY'),
        ('c', 1.005, 'KWD'),
        ('d', -50.50, 'SAR'),
      ]) {
        await db.customInsert(
          'INSERT INTO transactions(id, amount, currency, raw_merchant, type, '
          'source, occurred_at, raw_message, parse_confidence, status, '
          'created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?);',
          variables: [
            Variable.withString(t.$1),
            Variable.withReal(t.$2),
            Variable.withString(t.$3),
            Variable.withString('m'),
            Variable.withString('payment'),
            Variable.withString('manual'),
            Variable.withString('2026-08-01T00:00:00.000Z'),
            Variable.withString('r'),
            Variable.withReal(1.0),
            Variable.withString('confirmed'),
            Variable.withString('2026-08-01T00:00:00.000Z'),
            Variable.withString('2026-08-01T00:00:00.000Z'),
          ],
        );
      }
      await backfillNonPlanningMoneyV30(db);
      final rows = await db
          .customSelect('SELECT id, amount_minor, currency FROM transactions '
              'ORDER BY id;')
          .get();
      return rows
          .map((r) => {
                'id': r.read<String>('id'),
                'minor': r.read<int>('amount_minor'),
                'currency': r.read<String>('currency'),
              })
          .toList();
    }

    final first = await runOnce();
    final second = await runOnce();
    expect(second, first, reason: 'migration is not deterministic');
    // Spot-check the exact expected minors (scale-correct).
    expect(first.firstWhere((r) => r['id'] == 'a')['minor'], 1234); // EGP 12.34
    expect(first.firstWhere((r) => r['id'] == 'b')['minor'], 1000); // JPY 1000
    expect(first.firstWhere((r) => r['id'] == 'c')['minor'], 1005); // KWD 1.005
    expect(first.firstWhere((r) => r['id'] == 'd')['minor'], -5050); // SAR -50.50
  });

  // ── §1 exact-rounding fixture edges ───────────────────────────────────────

  test('§1 half-away rounding at the scale boundary (1.005 / -1.005) and a valid '
      'large-but-in-range value', () {
    // 1.005 KWD (3-dec) → 1005 minor exactly (decimal string path).
    expect(parseExactDecimalToMinor('1.005', currencyScale('KWD')), 1005);
    expect(parseExactDecimalToMinor('-1.005', currencyScale('KWD')), -1005);
    // 1.005 as a 2-dec currency rounds HALF-AWAY-FROM-ZERO → 101 (not banker's 100).
    expect(legacyRealToMinor(1.005, currencyScale('EGP')), 101);
    expect(legacyRealToMinor(-1.005, currencyScale('EGP')), -101);
    // A valid large in-range value round-trips exactly (well under int64 max).
    expect(parseExactDecimalToMinor('90000000000.00', currencyScale('EGP')),
        9000000000000);
  });
}
