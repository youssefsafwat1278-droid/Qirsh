// Phase-7 Batch-2 §MALI-073n / §13 — schema v29 migration discipline for the
// additive hot-path indexes: clean install, realistic v28→v29 upgrade, idempotent
// reopen (no duplicate creation), postflight index inventory, rollback preservation,
// and version ownership (a newer DB is refused, not silently downgraded).
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

const _newIndexes = [
  'idx_transactions_account_occurred',
  'idx_transactions_category_id',
];

Future<int> _userVersion(AppDatabase db) async =>
    (await db.customSelect('PRAGMA user_version;').getSingle()).read<int>('user_version');

Future<List<String>> _indexNames(AppDatabase db) async {
  final rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND name IN ('idx_transactions_account_occurred', 'idx_transactions_category_id') "
        'ORDER BY name;',
      )
      .get();
  return rows.map((r) => r.read<String>('name')).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> openFile(String path) => AppDatabase.open(
      executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());

  late Directory dir;
  late String dbPath;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('mali_v29_');
    dbPath = '${dir.path}/app.db';
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('clean install stamps v29 and creates both hot-path indexes', () async {
    final db = await openFile(dbPath);
    expect(await _userVersion(db), 44);
    expect(await _indexNames(db), _newIndexes);
    await db.close();
  });

  test('realistic v28→v29 upgrade recreates the indexes and bumps the version',
      () async {
    // Establish a full DB, then simulate a v28 on-disk state: drop the v29 indexes
    // and roll user_version back to 28 (exactly what an older build left behind).
    final first = await openFile(dbPath);
    for (final idx in _newIndexes) {
      await first.customStatement('DROP INDEX IF EXISTS $idx;');
    }
    await first.customStatement('PRAGMA user_version = 28;');
    expect(await _userVersion(first), 28);
    expect(await _indexNames(first), isEmpty);
    await first.close();

    // Reopen → the version-owned pipeline upgrades: recreates the indexes and
    // stamps v29 (last, inside the migration transaction).
    final upgraded = await openFile(dbPath);
    expect(await _userVersion(upgraded), 44);
    expect(await _indexNames(upgraded), _newIndexes);
    await upgraded.close();
  });

  test('repeated open does not duplicate or error on the indexes', () async {
    final a = await openFile(dbPath);
    await a.close();
    final b = await openFile(dbPath);
    // Exactly two matching indexes — CREATE INDEX IF NOT EXISTS is a no-op the 2nd
    // time; no duplicate objects, no error.
    expect(await _indexNames(b), _newIndexes);
    expect(await _userVersion(b), 44);
    await b.close();
  });

  test('a rolled-back (interrupted) upgrade preserves the previous schema state',
      () async {
    // Bring the DB to a v28-shaped state (no v29 indexes, version 28) and simulate
    // an upgrade transaction that fails AFTER creating one index but BEFORE the
    // version bump: the whole transaction must roll back — version stays 28 and
    // NEITHER index persists (atomicity), never a half-applied v29.
    final seed = await openFile(dbPath);
    for (final idx in _newIndexes) {
      await seed.customStatement('DROP INDEX IF EXISTS $idx;');
    }
    await seed.customStatement('PRAGMA user_version = 28;');
    try {
      await seed.transaction(() async {
        await seed.customStatement(
          'CREATE INDEX idx_transactions_account_occurred '
          'ON transactions(account_id, occurred_at);',
        );
        await seed.customStatement('PRAGMA user_version = 30;');
        throw StateError('injected mid-upgrade failure');
      });
    } catch (_) {}
    expect(await _userVersion(seed), 28, reason: 'version bump rolled back');
    expect(await _indexNames(seed), isEmpty, reason: 'index creation rolled back');
    await seed.close();

    // A clean reopen still completes the real upgrade deterministically.
    final ok = await openFile(dbPath);
    expect(await _userVersion(ok), 44);
    expect(await _indexNames(ok), _newIndexes);
    await ok.close();
  });

  // Version ownership (a newer-than-app schema is refused, not downgraded) is a
  // pre-existing guard covered by migration_pipeline_test.dart /
  // migration_version_ownership_test.dart; the v29 bump only updates its expected
  // supportedVersion. It is not re-tested here to avoid duplicating that coverage.
}
