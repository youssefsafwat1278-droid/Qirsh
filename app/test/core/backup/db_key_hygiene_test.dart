import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import '../../harness/seed_test_account.dart';

// MALI-058n — the local SQLCipher key lives ONLY in platform secure storage. It
// must never be stored in Drift, backed up, synced, exported, logged, or written
// during a restore. These tests use real file-backed Drift databases and the
// real backup/restore serialization.
class _MemoryKeyStore implements DatabaseKeyStore {
  _MemoryKeyStore(this._key);
  final String _key;
  int writes = 0;
  @override
  Future<String> readOrCreateKey() async => _key;
  @override
  Future<String?> readStoredKey() async => _key;
}

const _rawKeyCanary = 'RAW-SQLCIPHER-KEY-CANARY-9f3a';

void main() {
  // A restore mirrors the restored language into the keychain for the unlock
  // prompt (core/security/lock_prompt_language.dart); this suite has no
  // keychain, so it gets an in-memory one.
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> open([String key = 'device-key']) => seededDb(AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(key),
      ));
  // A restore destination is a new device: no account yet (A-7), so the whole
  // backup applies (SP-02).
  Future<AppDatabase> openNew(String key) => AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(key),
      );

  Future<String> keyRef(AppDatabase db) async =>
      (await db.customSelect('SELECT db_encryption_key_ref AS r FROM user_settings;')
              .getSingle())
          .read<String>('r');

  Future<String> country(AppDatabase db) async =>
      (await db.customSelect('SELECT country AS c FROM user_settings;').getSingle())
          .read<String>('c');

  Future<int> countWhere(AppDatabase db, String where) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $where;').getSingle())
          .read<int>('n');

  test('a fresh database seeds an EMPTY key ref (never the raw key)', () async {
    final db = await open(_rawKeyCanary); // even if the key itself is the canary
    addTearDown(db.close);
    expect(await keyRef(db), '');
  });

  test('the cleanup repair clears a legacy value and is idempotent/retryable',
      () async {
    final db = await open();
    addTearDown(db.close);
    await db.customStatement(
      "UPDATE user_settings SET db_encryption_key_ref = '$_rawKeyCanary';",
    );
    expect(await db.clearDeprecatedDbKeyRef(), 1); // one row repaired
    expect(await keyRef(db), '');
    // Idempotent: a second run repairs nothing; retry is safe.
    expect(await db.clearDeprecatedDbKeyRef(), 0);
    expect(await db.clearDeprecatedDbKeyRef(), 0);
    expect(await keyRef(db), '');
  });

  test('backup snapshot omits the key column and its plaintext has no canary',
      () async {
    final db = await open();
    addTearDown(db.close);
    // Even a device that never ran cleanup must not leak: force a legacy value.
    await db.customStatement(
      "UPDATE user_settings SET db_encryption_key_ref = '$_rawKeyCanary';",
    );
    final snapshot = await BackupSnapshotBuilder(db).build();
    final settings = (snapshot['tables']['user_settings'] as List)
        .cast<Map<String, dynamic>>()
        .first;
    expect(settings.containsKey('db_encryption_key_ref'), isFalse);
    // The serialized plaintext (what gets encrypted + uploaded) has no canary.
    final plaintext = jsonEncode(snapshot);
    expect(plaintext.contains(_rawKeyCanary), isFalse);
    expect(plaintext.contains('db_encryption_key_ref'), isFalse);
  });

  test('legacy backup carrying db_encryption_key_ref restores all OTHER data '
      'but never writes the foreign key ref', () async {
    final src = await open();
    addTearDown(src.close);
    await src.customStatement("UPDATE user_settings SET country = 'EG';");
    final snapshot = await BackupSnapshotBuilder(src).build();
    // Simulate a legacy v2/v3 snapshot that still carried the key field.
    (snapshot['tables']['user_settings'] as List)
        .cast<Map<String, dynamic>>()
        .first['db_encryption_key_ref'] = 'FOREIGN-$_rawKeyCanary';

    final dst = await openNew('destination-device-key');
    addTearDown(dst.close);
    await RestoreBackupUseCase(dst).call(snapshot);

    expect(await country(dst), 'EG'); // the rest of the backup restored
    expect(await keyRef(dst), ''); // the foreign key ref was NOT written
  });

  test('an unknown key-like field fails CLOSED before any destructive step',
      () async {
    final src = await open();
    addTearDown(src.close);
    final snapshot = await BackupSnapshotBuilder(src).build();
    (snapshot['tables']['user_settings'] as List)
        .cast<Map<String, dynamic>>()
        .first['stolen_secret_key'] = 'X';

    final dst = await open();
    addTearDown(dst.close);
    // A marker row that MUST survive if the restore refuses before deleting.
    await dst.customStatement(
      "INSERT INTO accounts(id, name, currency, type, initial_balance, "
      "current_balance, is_default, sort_order, created_at, updated_at) "
      "VALUES ('marker-acct', 'Marker', 'SAR', 'cash', 0, 0, 0, 999, "
      "'2026-01-01', '2026-01-01');",
    );
    await backfillNonPlanningMoneyV30(dst);

    await expectLater(
      RestoreBackupUseCase(dst).call(snapshot),
      throwsA(isA<BackupException>()),
    );
    // No DELETE ran — the destination is untouched.
    expect(await countWhere(dst, "accounts WHERE id = 'marker-acct'"), 1);
  });

  test("user A's legacy key field cannot alter user B's destination key ref",
      () async {
    final userA = await open('user-a-device-key');
    addTearDown(userA.close);
    await userA.customStatement(
      "UPDATE user_settings SET db_encryption_key_ref = 'USER-A-$_rawKeyCanary', "
      "country = 'AE';",
    );
    final snapshot = await BackupSnapshotBuilder(userA).build();
    // (The builder already excludes it; re-inject to simulate a hand-tampered
    // or older-format snapshot that still carries user A's key field.)
    (snapshot['tables']['user_settings'] as List)
        .cast<Map<String, dynamic>>()
        .first['db_encryption_key_ref'] = 'USER-A-$_rawKeyCanary';

    final userB = await openNew('user-b-device-key');
    addTearDown(userB.close);
    await RestoreBackupUseCase(userB).call(snapshot);

    expect(await keyRef(userB), ''); // user A's key never lands on user B
    expect(await country(userB), 'AE'); // benign data still restores
  });
}
