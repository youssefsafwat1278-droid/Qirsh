import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

// MALI-014 (Batch-5 closure) §Step-4 — the durable restore_operations journal is
// created and owned by the version-owned migration pipeline (schema v28): present
// on clean install, created on a realistic v27 -> v28 upgrade, idempotent on reopen,
// and constrained (single row per operation id).

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<int> userVersion(AppDatabase db) async =>
      (await db.customSelect('PRAGMA user_version;').getSingle())
          .read<int>('user_version');

  Future<bool> hasRestoreOps(AppDatabase db) async => (await db
              .customSelect(
                  "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name='restore_operations';")
              .getSingle())
          .read<int>('c') ==
      1;

  test('clean install is v28 and has the restore_operations table with a PK',
      () async {
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    addTearDown(db.close);
    expect(await userVersion(db), 44);
    expect(await hasRestoreOps(db), isTrue);
    // operation_id PRIMARY KEY: a duplicate insert must be rejected/replace, never
    // create a second row.
    await db.customStatement(
        "INSERT INTO restore_operations(operation_id, source_fingerprint, envelope_version, snapshot_schema_version, state, prepared_at) VALUES ('op', 'fp', 3, 3, 'prepared', 't');");
    var threw = false;
    try {
      await db.customStatement(
          "INSERT INTO restore_operations(operation_id, source_fingerprint, envelope_version, snapshot_schema_version, state, prepared_at) VALUES ('op', 'fp2', 3, 3, 'prepared', 't');");
    } catch (_) {
      threw = true;
    }
    expect(threw, isTrue, reason: 'operation_id is a primary key');
  });

  test('a realistic v27 database (no restore_operations) upgrades to v28 and gains '
      'the table; a reopen does not recreate it or lose data', () async {
    final dir = Directory.systemTemp.createTempSync('mali_v28_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/app.db';

    // Build a v28 DB, then simulate a pre-upgrade v27 file: drop the new table and
    // stamp user_version back to 27.
    var db = await AppDatabase.open(
        executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());
    await db.customStatement("INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, last_seen_at) VALUES ('m1','N','n','t','t');");
    await db.customStatement('DROP TABLE restore_operations;');
    await db.customStatement('PRAGMA user_version = 27;');
    expect(await hasRestoreOps(db), isFalse);
    await db.close();

    // Reopen → the versioned migration pipeline runs 27 -> 28 and creates the table.
    db = await AppDatabase.open(
        executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());
    expect(await userVersion(db), 44);
    expect(await hasRestoreOps(db), isTrue, reason: 'upgrade created the table');
    // Existing data preserved.
    expect(
        (await db.customSelect("SELECT COUNT(*) AS c FROM merchants WHERE id='m1';").getSingle())
            .read<int>('c'),
        1);
    await db.close();

    // Reopen again → no recreation, still v28, data intact (idempotent).
    db = await AppDatabase.open(
        executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());
    addTearDown(db.close);
    expect(await userVersion(db), 44);
    expect(await hasRestoreOps(db), isTrue);
  });
}
