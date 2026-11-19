import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// The captured v42 fixture for the v42 -> v43 step
/// (`_applyV43CategoryProvenance`). migration_data_survival_test.dart allows
/// that step's one `UPDATE transactions` only because this file proves it on
/// the real pre-migration shape: no `category_source` column, no
/// `merchant_aliases` table, and bank rows that lost their merchant link.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> open() => AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );

  Future<int> userVersion(AppDatabase db) async =>
      (await db.customSelect('PRAGMA user_version;').getSingle())
          .read<int>('user_version');

  Future<void> insertTx(
    AppDatabase db,
    String id, {
    required String type,
    required String source,
    required String? merchant,
    required double amount,
  }) =>
      db.customStatement(
        "INSERT INTO transactions(id, amount, currency, type, source, "
        "occurred_at, raw_message, parse_confidence, status, created_at, "
        "updated_at, account_id, direction, raw_merchant) VALUES "
        "('$id', $amount, 'SAR', '$type', '$source', '2026-09-01', 'v42', "
        "0.9, 'confirmed', '2026-01-01', '2026-01-01', 'acc-1', 'debit', "
        "${merchant == null ? 'NULL' : "'$merchant'"});",
      );

  /// A populated install, then wound back to the exact v42 shape.
  Future<AppDatabase> v42Fixture() async {
    final db = await open();
    await db.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
      "VALUES ('acc-1', 'Main', 'SAR', 'bank', '2026-01-01', '2026-01-01');",
    );
    await insertTx(db, 'manual',
        type: 'payment', source: 'unknown', merchant: 'Corner Shop', amount: 5);
    await insertTx(db, 'bank-1',
        type: 'payment', source: 'bank', merchant: 'ZARYAB 12', amount: 10.5);
    await insertTx(db, 'bank-2',
        type: 'payment', source: 'card', merchant: 'zaryab  99', amount: 20.25);
    await insertTx(db, 'bank-linked',
        type: 'payment', source: 'bank', merchant: 'Other Store', amount: 3);
    await insertTx(db, 'imported',
        type: 'payment', source: 'imported', merchant: 'Imported Co', amount: 7);
    await insertTx(db, 'transfer',
        type: 'transfer', source: 'bank', merchant: 'Ahmed Ali', amount: 100);
    await insertTx(db, 'income',
        type: 'income', source: 'bank', merchant: 'Employer LLC', amount: 900);
    await insertTx(db, 'no-merchant',
        type: 'payment', source: 'bank', merchant: null, amount: 1);

    // Link one bank row the way v42 did, so the repair must leave it alone.
    await db.customStatement(
      "INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, "
      "last_seen_at) VALUES ('m-other', 'Other Store', "
      "'${AppDatabase.normalizeMerchant('Other Store')}', '2026-01-01', "
      "'2026-01-01');",
    );
    await db.customStatement(
        "UPDATE transactions SET merchant_id = NULL WHERE id <> 'bank-linked';");
    await db.customStatement(
        "UPDATE transactions SET merchant_id = 'm-other' "
        "WHERE id = 'bank-linked';");
    // A dangling link (merchant row gone) is repaired too.
    await db.customStatement('PRAGMA foreign_keys = OFF;');
    await db.customStatement(
        "UPDATE transactions SET merchant_id = 'gone' WHERE id = 'bank-2';");
    await db.customStatement('PRAGMA foreign_keys = ON;');

    // The real v42 shape.
    await db.customStatement('DROP TABLE merchant_aliases;');
    await db
        .customStatement('ALTER TABLE transactions DROP COLUMN category_source;');
    await db.customStatement(
        'ALTER TABLE transactions DROP COLUMN imported_from_file;');
    await db.customStatement('PRAGMA user_version = 42;');
    return db;
  }

  Future<Map<String, Map<String, Object?>>> rows(AppDatabase db) async {
    final out = <String, Map<String, Object?>>{};
    for (final r in await db
        .customSelect('SELECT t.id, t.category_source, t.imported_from_file, '
            't.merchant_id, '
            'm.normalized_name AS mn, t.amount FROM transactions t '
            'LEFT JOIN merchants m ON m.id = t.merchant_id;')
        .get()) {
      out[r.read<String>('id')] = r.data;
    }
    return out;
  }

  Future<(int, double)> money(AppDatabase db) async {
    final r = await db
        .customSelect('SELECT COUNT(*) AS n, COALESCE(SUM(amount),0) AS s '
            'FROM transactions;')
        .getSingle();
    return (r.read<int>('n'), r.read<double>('s'));
  }

  test('v42 -> v43 records provenance conservatively and repairs links',
      () async {
    final db = await v42Fixture();
    addTearDown(db.close);
    final cols = (await db
            .customSelect("SELECT name FROM pragma_table_info('transactions');")
            .get())
        .map((r) => r.read<String>('name'));
    expect(cols, isNot(contains('category_source')),
        reason: 'the fixture must really be the v42 shape');
    expect(cols, isNot(contains('imported_from_file')));
    final before = await money(db);
    expect(before.$1, 8);

    await db.debugReinitialize();

    expect(await userVersion(db), 45);
    expect(await money(db), before, reason: 'no row or amount may change');
    final r = await rows(db);

    expect(r['manual']!['category_source'], 'user',
        reason: 'a hand-entered row was chosen by the user');
    for (final id in [
      'bank-1',
      'bank-2',
      'bank-linked',
      'imported',
      'transfer',
      'income',
      'no-merchant',
    ]) {
      expect(r[id]!['category_source'], 'unknown',
          reason: '$id has no provable origin — it must stay unknown');
    }

    // Only a row whose source already says "imported" is marked imported;
    // nothing is guessed for the rest.
    for (final e in r.entries) {
      expect(e.value['imported_from_file'], e.key == 'imported' ? 1 : 0,
          reason: '${e.key} import marker');
    }

    // Deterministic relinking: same normalised key, one merchant.
    final zaryab = AppDatabase.normalizeMerchant('ZARYAB 12');
    expect(r['bank-1']!['mn'], zaryab);
    expect(r['bank-2']!['mn'], zaryab, reason: 'a dangling link is repaired');
    expect(r['bank-1']!['merchant_id'], r['bank-2']!['merchant_id']);
    expect(r['bank-linked']!['merchant_id'], 'm-other',
        reason: 'a valid link is never rewritten');
    expect(r['manual']!['mn'], AppDatabase.normalizeMerchant('Corner Shop'));
    expect(r['imported']!['mn'], AppDatabase.normalizeMerchant('Imported Co'));
    expect(r['transfer']!['merchant_id'], isNull);
    expect(r['income']!['merchant_id'], isNull);
    expect(r['no-merchant']!['merchant_id'], isNull);

    expect(
        await db
            .customSelect("SELECT 1 FROM sqlite_master WHERE type='table' "
                "AND name='merchant_aliases';")
            .getSingleOrNull(),
        isNotNull);
    expect(await db.customSelect('PRAGMA foreign_key_check;').get(), isEmpty);
  });

  test('replaying v43 (a crash mid-upgrade) changes nothing', () async {
    final db = await v42Fixture();
    addTearDown(db.close);
    await db.debugReinitialize();
    final first = await rows(db);
    final merchants = (await db
            .customSelect('SELECT COUNT(*) AS n FROM merchants;')
            .getSingle())
        .read<int>('n');

    // A later user choice must survive a replay untouched.
    await db.customStatement(
        "UPDATE transactions SET category_source = 'auto' WHERE id = 'bank-1';");
    await db.customStatement('PRAGMA user_version = 42;');
    await db.debugReinitialize();

    final second = await rows(db);
    expect(await userVersion(db), 45);
    expect(second['bank-1']!['category_source'], 'auto');
    second['bank-1'] = {...second['bank-1']!, 'category_source': 'unknown'};
    expect(second, first);
    expect(
        (await db.customSelect('SELECT COUNT(*) AS n FROM merchants;').getSingle())
            .read<int>('n'),
        merchants,
        reason: 'no duplicate merchants on replay');
  });
}
