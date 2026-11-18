import 'dart:io';

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

// MALI-046n — the migration pipeline must OWN `user_version`. Production opens the
// database with `enableMigrations: false` so Drift installs a NoVersionDelegate and
// never stamps `user_version = schemaVersion` at open; the pipeline then observes the
// real on-disk version and is the sole writer of the version. These tests mirror the
// production configuration with file-backed databases (the genuine open sequence).
//
// Flip this to `true` to characterize the pre-fix framework behavior (the bug):
// Drift stamps 27 at open, the downgrade guard never fires, and version-gated repairs
// are skipped — several assertions below then fail, which is the MALI-046n regression.
const bool _productionMigrationsFlag = false;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  var seq = 0;
  setUp(() => tmpDir = Directory.systemTemp.createTempSync('mali_ver'));
  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  File newDbFile() => File('${tmpDir.path}/db_${seq++}.sqlite');

  AppDatabase openUninit(File f, {bool? enableMigrations}) =>
      AppDatabase.createForTesting(
        executor: NativeDatabase(
          f,
          enableMigrations: enableMigrations ?? _productionMigrationsFlag,
        ),
        keyStore: _MemoryKeyStore(),
      );

  Future<int> userVersion(AppDatabase db) async =>
      (await db.customSelect('PRAGMA user_version;').getSingle())
          .read<int>('user_version');

  Future<bool> columnExists(AppDatabase db, String t, String c) async =>
      (await db.customSelect('PRAGMA table_info($t);').get())
          .any((r) => r.read<String>('name') == c);

  Future<int> count(AppDatabase db, String sql) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $sql;').getSingle())
          .read<int>('n');

  test(
      'production open config leaves user_version at the on-disk value; '
      'framework migrations would overwrite it (MALI-046n root cause)', () async {
    final dbProd = openUninit(newDbFile()); // production config (false)
    addTearDown(dbProd.close);
    expect(await userVersion(dbProd), 0,
        reason: 'no framework stamp under the production open config');

    final dbFramework = openUninit(newDbFile(), enableMigrations: true);
    addTearDown(dbFramework.close);
    expect(await userVersion(dbFramework), 44,
        reason: 'framework stamps schemaVersion (33) — the behavior the fix disables');
  });

  test('fresh database (production config) initializes forward to 35', () async {
    final db = openUninit(newDbFile());
    addTearDown(db.close);
    await db.initialize();
    expect(await userVersion(db), 44);
    expect(await count(db, 'accounts'), 0,
        reason: 'A-7: a fresh database has no silent default account');
    expect(await count(db, 'categories'), greaterThan(0));
  });

  test(
      'a genuine legacy on-disk version is OBSERVED before any framework stamp, '
      'so the version<9 gate runs (adds transactions.foreign_amount)', () async {
    final db = openUninit(newDbFile());
    addTearDown(db.close);
    // A v8-era shape: transactions WITHOUT foreign_amount/foreign_currency, which
    // are added ONLY inside the `if (version < 9)` compatibility block.
    await db.customStatement('''
      CREATE TABLE transactions(
        id TEXT PRIMARY KEY, amount REAL NOT NULL, currency TEXT NOT NULL,
        merchant_id TEXT NULL, raw_merchant TEXT NULL, category_id TEXT NULL,
        type TEXT NOT NULL, source TEXT NOT NULL, card_last4 TEXT NULL,
        balance_after REAL NULL, occurred_at TEXT NOT NULL, raw_message TEXT NOT NULL,
        parse_confidence REAL NOT NULL, status TEXT NOT NULL,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    ''');
    await db.customStatement('''
      CREATE TABLE categories(
        id TEXT PRIMARY KEY, key TEXT NOT NULL UNIQUE, name_ar TEXT NOT NULL,
        icon TEXT NOT NULL, color TEXT NOT NULL, is_income INTEGER NOT NULL,
        sort_order INTEGER NOT NULL);
    ''');
    await db.customStatement('''
      CREATE TABLE merchants(
        id TEXT PRIMARY KEY, raw_name TEXT NOT NULL,
        normalized_name TEXT NOT NULL UNIQUE, first_seen_at TEXT NOT NULL,
        last_seen_at TEXT NOT NULL);
    ''');
    await db.customStatement(
      "INSERT INTO transactions(id, amount, currency, type, source, occurred_at, "
      "raw_message, parse_confidence, status, created_at, updated_at) VALUES "
      "('legacy_tx', 5, 'SAR', 'payment', 'bank', '2026-01-01', 'm', 0.9, "
      "'confirmed', '2026-01-01', '2026-01-01');",
    );
    await db.customStatement('PRAGMA user_version = 8;');
    expect(await columnExists(db, 'transactions', 'foreign_amount'), isFalse);

    await db.initialize();

    expect(await userVersion(db), 44);
    expect(await columnExists(db, 'transactions', 'foreign_amount'), isTrue,
        reason: 'version<9 gate fired — real on-disk version (8) was observed');
    expect(await count(db, "transactions WHERE id='legacy_tx'"), 1,
        reason: 'legacy data preserved');
  });

  test('reopening the same file persists user_version 35 without re-migrating',
      () async {
    final f = newDbFile();
    final db1 = openUninit(f);
    await db1.initialize();
    await db1.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
      "VALUES ('marker', 'M', 'SAR', 'bank', '2026-01-01', '2026-01-01');",
    );
    await backfillNonPlanningMoneyV30(db1);
    await db1.close();

    final db2 = openUninit(f);
    addTearDown(db2.close);
    expect(await userVersion(db2), 44,
        reason: 'the pipeline owns user_version and persisted the current '
            'target to disk; reopening observes it before initialize runs');
    await db2.initialize(); // idempotent no-op
    expect(await userVersion(db2), 44);
    expect(await count(db2, "accounts WHERE id='marker'"), 1);
  });

  test(
      'a newer-than-app on-disk version FAILS CLOSED and is never stamped down',
      () async {
    final f = newDbFile();
    final db1 = openUninit(f);
    await db1.initialize();
    await db1.customStatement('PRAGMA user_version = 999;');
    await db1.close();

    final db2 = openUninit(f);
    addTearDown(db2.close);
    await expectLater(
      db2.initialize(),
      throwsA(isA<UnsupportedDatabaseVersionException>()),
    );
    expect(await userVersion(db2), 999,
        reason: 'fail closed: version untouched, NOT stamped to 28');
  });
}
