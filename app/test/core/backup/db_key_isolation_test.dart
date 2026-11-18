import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import '../../harness/seed_test_account.dart';

// MALI-058n (closure) — restore can never mutate the destination installation's
// SQLCipher key, and a missing key never falls back to backup data.
class _SpyKeyStore implements DatabaseKeyStore {
  _SpyKeyStore(this._stored);
  final String? _stored;
  int readOrCreateCalls = 0;
  int readStoredCalls = 0;

  @override
  Future<String> readOrCreateKey() async {
    readOrCreateCalls++;
    return _stored ?? 'minted';
  }

  @override
  Future<String?> readStoredKey() async {
    readStoredCalls++;
    return _stored;
  }
}

const _foreignKeyCanary = 'FOREIGN-KEY-B-CANARY-4c1d';

void main() {
  // A restore mirrors the restored language into the keychain for the unlock
  // prompt (core/security/lock_prompt_language.dart); this suite has no
  // keychain, so it gets an in-memory one.
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> open(DatabaseKeyStore ks) =>
      seededDb(AppDatabase.open(executor: NativeDatabase.memory(), keyStore: ks));
  // A restore destination is a new device: no account yet (A-7), so the whole
  // backup applies (SP-02).
  Future<AppDatabase> openNew(DatabaseKeyStore ks) =>
      AppDatabase.open(executor: NativeDatabase.memory(), keyStore: ks);

  Future<String> keyRef(AppDatabase db) async =>
      (await db.customSelect('SELECT db_encryption_key_ref AS r FROM user_settings;')
              .getSingle())
          .read<String>('r');

  test('restore makes ZERO key-store calls; destination key A is untouched and '
      'foreign key B never lands in Drift', () async {
    final dstKeyStore = _SpyKeyStore('key-A');
    final dst = await openNew(dstKeyStore);
    addTearDown(dst.close);

    final src = await open(_SpyKeyStore('key-src'));
    addTearDown(src.close);
    await src.customStatement("UPDATE user_settings SET country = 'KW';");
    final snapshot = await BackupSnapshotBuilder(src).build();
    // A legacy/foreign snapshot that still carries user A's key material.
    (snapshot['tables']['user_settings'] as List)
        .cast<Map<String, dynamic>>()
        .first['db_encryption_key_ref'] = 'key-B-$_foreignKeyCanary';

    final callsBefore = dstKeyStore.readOrCreateCalls + dstKeyStore.readStoredCalls;
    await RestoreBackupUseCase(dst).call(snapshot);

    // The restore use case holds no key-store reference at all: it cannot pass
    // key B to a database opener or a secure-storage writer.
    expect(dstKeyStore.readOrCreateCalls + dstKeyStore.readStoredCalls,
        callsBefore);
    // Secure storage still holds key A; the foreign value never reached Drift.
    expect(await dstKeyStore.readStoredKey(), 'key-A');
    expect(await keyRef(dst), '');
    expect(await keyRef(dst), isNot(contains(_foreignKeyCanary)));
    // ...and the benign data DID restore.
    expect(
      (await dst
              .customSelect('SELECT country AS c FROM user_settings;')
              .getSingle())
          .read<String>('c'),
      'KW',
    );
  });

  test('missing key + existing DB → typed key-unavailable; no new key, no delete, '
      'backup never consulted as a DB credential', () async {
    final spy = _SpyKeyStore(null); // key absent

    await expectLater(
      seededDb(AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: spy,
        databaseFileExists: () async => true, // an encrypted DB exists
      )),
      throwsA(isA<LocalDatabaseKeyUnavailableException>()),
    );

    // Never minted a replacement key (which would mask the loss). open() has NO
    // reference to any backup/restore path, so — structurally — it cannot read a
    // key from a backup snapshot as a database credential, and it performs no
    // deletion on this throwing path.
    expect(spy.readOrCreateCalls, 0);
  });
}
