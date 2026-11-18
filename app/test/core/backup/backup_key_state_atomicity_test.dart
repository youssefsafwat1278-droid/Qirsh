@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/core/backup/backup_crypto.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/encrypted_backup_service.dart';
import 'package:money_companion/core/backup/remote_backup_store.dart';
import 'package:money_companion/core/backup/remote_backup_state.dart';
import 'package:money_companion/core/backup/restore_controller.dart';
import 'package:money_companion/core/backup/restore_result.dart';
import 'package:money_companion/core/backup/restore_service.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../harness/seed_test_account.dart';

const _ownerKey = 'backup_owner_uid';
const _enabledKey = 'backup_enabled';
const _envelopeVersionKey = 'backup_envelope_version';
const _recoveryKey = 'backup_recovery_code';
const _keySlotsKey = 'backup_key_slots';
const _localKeyKey = 'backup_local_key';
const _saltKey = 'backup_salt';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-db-key';

  @override
  Future<String?> readStoredKey() async => 'test-db-key';
}

/// A storage double that models the important crash boundary: the selected
/// operation takes effect, then control is lost before the next await.
class _FaultStorage extends FlutterSecureStorage {
  _FaultStorage(Map<String, String> initial) : values = {...initial};

  final Map<String, String> values;
  final List<String> operations = [];
  String? failAfterOperation;

  void _after(String operation) {
    operations.add(operation);
    if (failAfterOperation == operation) {
      failAfterOperation = null;
      throw StateError('injected secure-storage interruption');
    }
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    _after('write:$key');
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    operations.add('read:$key');
    return values[key];
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
    _after('delete:$key');
  }
}

class _MemoryRemoteStore implements RemoteBackupStore {
  _MemoryRemoteStore(this.ownerId);

  @override
  final String ownerId;

  final Map<String, Uint8List> objects = {};
  RemoteBackupMetadata? current;
  int putCount = 0;

  @override
  Future<void> putObject(String path, Uint8List bytes) async {
    putCount++;
    objects[path] = Uint8List.fromList(bytes);
  }

  @override
  Future<int?> objectSize(String path) async => objects[path]?.length;

  @override
  Future<Uint8List> getObject(String path, {required int maxBytes}) async {
    final bytes = objects[path];
    if (bytes == null) {
      throw const RemoteBackupException(
        RemoteBackupErrorKind.remoteObjectMissing,
      );
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> deleteObject(String path) async {
    objects.remove(path);
  }

  @override
  Future<List<String>> listObjects(String prefix) async =>
      objects.keys.where((path) => path.startsWith(prefix)).toList();

  @override
  Future<void> commitGeneration(
    RemoteBackupMetadata metadata, {
    String? expectedPrevGenerationId,
  }) async {
    current = metadata;
  }

  @override
  Future<RemoteBackupMetadata?> readCurrentGeneration() async => current;

  @override
  Future<void> clearGeneration() async {
    current = null;
  }
}

class _FastEnableCrypto extends BackupCrypto {
  @override
  List<int> randomBytes(int length) =>
      List<int>.generate(length, (index) => index + 1);

  @override
  Future<List<BackupKeySlot>> createV3KeySlots({
    required List<int> contentKey,
    required String passphrase,
    String? recoveryCode,
  }) async =>
      const [
        BackupKeySlot(
          type: 'password',
          salt: [1],
          nonce: [2],
          cipherText: [3],
          mac: [4],
        ),
        BackupKeySlot(
          type: 'recovery',
          salt: [5],
          nonce: [6],
          cipherText: [7],
          mac: [8],
        ),
      ];
}

Future<void> _recoverSessionAs(SupabaseClient client, String userId) async {
  String segment(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final token = '${segment({'alg': 'none', 'typ': 'JWT'})}.'
      '${segment({
        'exp': DateTime.now()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch ~/
            1000,
        'sub': userId,
      })}.';
  await client.auth.recoverSession(jsonEncode({
    'access_token': token,
    'token_type': 'bearer',
    'user': {'id': userId},
  }));
}

Future<SupabaseClient> _signedInClient(String userId) async {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'public-anon-key',
    httpClient: MockClient((_) async => Response('{}', 200)),
  );
  await _recoverSessionAs(client, userId);
  return client;
}

Map<String, String> _accountAState() => {
      _ownerKey: 'A',
      _enabledKey: '1',
      _envelopeVersionKey: '3',
      _recoveryKey: 'A-RECOVERY',
      _keySlotsKey: jsonEncode([
        const BackupKeySlot(
          type: 'password',
          salt: [11],
          nonce: [12],
          cipherText: [13],
          mac: [14],
        ).toJson(),
      ]),
      _localKeyKey: base64Encode(List<int>.filled(32, 99)),
      _saltKey: base64Encode(List<int>.filled(16, 88)),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> openMemory() => seededDb(AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      ));
  // A restore destination is a new device: no account yet (A-7), so the whole
  // backup, settings included, applies (SP-02).
  Future<AppDatabase> openNewDevice() => AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );

  group('H-23 — enable key-state publication is fail-closed', () {
    // Non-vacuity: with the prior owner-first implementation, every case below
    // left owner=B and enabled=1. In particular, interruption after owner wrote
    // made status true over A's untouched key and backupNow published with it.
    for (final fault in const [
      'write:$_ownerKey',
      'write:$_envelopeVersionKey',
      'write:$_recoveryKey',
      'write:$_keySlotsKey',
      'write:$_localKeyKey',
      'delete:$_saltKey',
    ]) {
      test('interruption after $fault never publishes mixed account state',
          () async {
        final db = await openMemory();
        addTearDown(db.close);
        final storage = _FaultStorage(_accountAState())
          ..failAfterOperation = fault;
        final remote = _MemoryRemoteStore('B');
        final service = EncryptedBackupService(
          database: db,
          client: await _signedInClient('B'),
          storage: storage,
          crypto: _FastEnableCrypto(),
          remoteStore: remote,
          readLocalDataOwnerUid: () async => 'B',
        );

        await expectLater(
          service.enable(passphrase: 'new-passphrase'),
          throwsA(isA<StateError>()),
        );

        expect((await service.status()).enabled, isFalse,
            reason: 'owner/enabled must not publish before all exact successor '
                'values are verified');
        await service.backupNow();
        expect(remote.putCount, 0,
            reason: 'B must never upload with A\'s stale or mixed key state');
        expect(
          storage.values[_ownerKey] == 'B' &&
              storage.values[_enabledKey] == '1',
          isFalse,
          reason: 'the trusted owner+enabled pair must remain unpublished',
        );
      });
    }

    test('material is written and read back before owner; enabled is final',
        () async {
      final db = await openMemory();
      addTearDown(db.close);
      final storage = _FaultStorage(_accountAState())
        ..failAfterOperation = 'write:$_ownerKey';
      final service = EncryptedBackupService(
        database: db,
        client: await _signedInClient('B'),
        storage: storage,
        crypto: _FastEnableCrypto(),
        remoteStore: _MemoryRemoteStore('B'),
        readLocalDataOwnerUid: () async => 'B',
      );

      await expectLater(
        service.enable(passphrase: 'new-passphrase'),
        throwsA(isA<StateError>()),
      );

      final ownerWrite = storage.operations.indexOf('write:$_ownerKey');
      for (final key in const [
        _envelopeVersionKey,
        _recoveryKey,
        _keySlotsKey,
        _localKeyKey,
      ]) {
        expect(storage.operations.indexOf('write:$key'), lessThan(ownerWrite));
        expect(storage.operations.indexOf('read:$key'), lessThan(ownerWrite),
            reason: '$key must be verified before ownership is published');
      }
      expect(storage.operations, isNot(contains('write:$_enabledKey')),
          reason: 'enabled is the final commit marker');
    });
  });

  group('RB4 H-23 — restore publication is bound to prepared admission', () {
    test(
        'A → B after DB commit but before publication never exposes A key as B-owned',
        () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_data_owner_uid': 'A',
        'local_data_owner_generation': 'generation-A',
      });
      final source = await openMemory();
      final destination = await openNewDevice();
      addTearDown(source.close);
      addTearDown(destination.close);
      await source.customStatement("UPDATE user_settings SET country = 'EG';");
      await destination
          .customStatement("UPDATE user_settings SET country = 'BEFORE';");

      final crypto = BackupCrypto(
        kdf: Argon2id(
          memory: BackupEnvelopeLimits.minMemoryKib,
          parallelism: 1,
          iterations: 1,
          hashLength: 32,
        ),
      );
      const passphrase = 'restore-passphrase';
      final snapshot = await BackupSnapshotBuilder(source).build();
      final blob = await crypto.encryptEnvelopeV3(
        json: snapshot,
        schemaVersion: BackupSnapshotBuilder.currentSchemaVersion,
        passphrase: passphrase,
      );
      final bytes = blob.toBytes();
      final remote = _MemoryRemoteStore('A');
      const path = 'A/g/restore.enc';
      remote.objects[path] = bytes;
      remote.current = RemoteBackupMetadata(
        generationId: 'restore-generation-race',
        objectPath: path,
        envelopeVersion: 3,
        sizeBytes: bytes.length,
        blobSha256: sha256Hex(bytes),
        operationId: 'restore-operation-race',
      );
      final storage = _FaultStorage(_accountAState());
      final client = await _signedInClient('A');
      var localOwner = 'A';
      var sawCommittedDatabaseBeforeSwitch = false;
      final service = EncryptedBackupService(
        database: destination,
        client: client,
        storage: storage,
        crypto: crypto,
        remoteStore: remote,
        readLocalDataOwnerUid: () async => localOwner,
        afterRestore: () async {
          // RestoreService invokes this only after the journal+data transaction
          // committed and strictly before EncryptedBackupService publishes keys.
          final country = (await destination
                  .customSelect('SELECT country FROM user_settings LIMIT 1;')
                  .getSingle())
              .read<String>('country');
          sawCommittedDatabaseBeforeSwitch = country == 'EG';
          await _recoverSessionAs(client, 'B');
          localOwner = 'B';
          FlutterSecureStorage.setMockInitialValues({
            'local_data_owner_uid': 'B',
            'local_data_owner_generation': 'generation-B',
          });
        },
      );

      final plan = await service.prepareRestore(passphrase: passphrase);
      final result = await service.commitRestore(
        confirmation: RestoreConfirmation.forTest(plan),
      );

      expect(sawCommittedDatabaseBeforeSwitch, isTrue,
          reason: 'the A→B change must occur after the DB commit');
      expect(result.outcome, RestoreOutcome.committedPendingBackupState);
      expect(result.isCommitted, isTrue);
      expect(
        result.warnings,
        contains(RestoreService.backupStateOwnershipConflictWarning),
      );
      expect(
        storage.values[_ownerKey] == 'B' && storage.values[_enabledKey] == '1',
        isFalse,
        reason: "A's restored key must never publish as B-owned and enabled",
      );
      expect((await service.status()).enabled, isFalse,
          reason: 'B must see the retained A state as foreign');
      await service.backupNow();
      expect(remote.putCount, 0,
          reason: "B must not encrypt or upload with A's key material");
    });
  });

  group('H-20 — post-commit key-state failure is truthful and retryable', () {
    test(
        'reports committed-pending, then a fresh service retries without replay',
        () async {
      const userId = 'B';
      FlutterSecureStorage.setMockInitialValues({
        'local_data_owner_uid': userId,
        'local_data_owner_generation': 'generation-1',
      });
      final source = await openMemory();
      final destination = await openNewDevice();
      addTearDown(source.close);
      addTearDown(destination.close);
      await source.customStatement("UPDATE user_settings SET country = 'EG';");
      await destination
          .customStatement("UPDATE user_settings SET country = 'BEFORE';");

      final crypto = BackupCrypto(
        kdf: Argon2id(
          memory: BackupEnvelopeLimits.minMemoryKib,
          parallelism: 1,
          iterations: 1,
          hashLength: 32,
        ),
      );
      const passphrase = 'restore-passphrase';
      final snapshot = await BackupSnapshotBuilder(source).build();
      final blob = await crypto.encryptEnvelopeV3(
        json: snapshot,
        schemaVersion: BackupSnapshotBuilder.currentSchemaVersion,
        passphrase: passphrase,
      );
      final bytes = blob.toBytes();
      final remote = _MemoryRemoteStore(userId);
      const path = 'B/g/restore.enc';
      remote.objects[path] = bytes;
      remote.current = RemoteBackupMetadata(
        generationId: 'restore-generation',
        objectPath: path,
        envelopeVersion: 3,
        sizeBytes: bytes.length,
        blobSha256: sha256Hex(bytes),
        operationId: 'restore-operation',
      );
      final storage = _FaultStorage(_accountAState())
        ..failAfterOperation = 'write:$_localKeyKey';
      final client = await _signedInClient(userId);

      EncryptedBackupService newService() => EncryptedBackupService(
            database: destination,
            client: client,
            storage: storage,
            crypto: crypto,
            remoteStore: remote,
            readLocalDataOwnerUid: () async => userId,
          );

      final firstService = newService();
      RestoreResult? firstResult;
      var firstAcknowledged = false;
      final firstController = RestoreController(
        prepare: () => firstService.prepareRestore(passphrase: passphrase),
        mutate: (confirmation) async {
          firstResult =
              await firstService.commitRestore(confirmation: confirmation);
          return firstResult!;
        },
        reestablish: firstService.verifyRestoredDatabaseUsable,
        acknowledge: (operationId) async {
          firstAcknowledged = true;
          await firstService.acknowledgeRestore(operationId: operationId);
        },
      );
      addTearDown(firstController.dispose);

      await firstController.beginPreparation();
      await firstController.confirm();

      expect(firstResult?.outcome, RestoreOutcome.committedPendingBackupState);
      expect(firstResult?.isCommitted, isTrue);
      expect(firstResult?.databaseUnchanged, isFalse);
      expect(
        firstController.value.phase,
        RestoreUiPhase.committedPendingBackupState,
        reason: 'a committed restore must never reach failedWithoutChanges',
      );
      expect(firstAcknowledged, isFalse,
          reason: 'the journal must retain the durable retry guard');
      expect(
        (await destination
                .customSelect('SELECT country FROM user_settings LIMIT 1;')
                .getSingle())
            .read<String>('country'),
        'EG',
        reason:
            'the destructive restore committed before key persistence failed',
      );
      expect((await firstService.status()).enabled, isFalse,
          reason: 'the interrupted key generation remains fail-closed');

      // Model a new launch: all in-memory prepared state is gone. Changing this
      // committed row proves the durable journal prevents destructive replay.
      await destination.customStatement(
          "UPDATE user_settings SET country = 'AFTER-COMMIT';");
      final retryService = newService();
      final retryController = RestoreController(
        prepare: () => retryService.prepareRestore(passphrase: passphrase),
        mutate: (confirmation) =>
            retryService.commitRestore(confirmation: confirmation),
        reestablish: retryService.verifyRestoredDatabaseUsable,
        acknowledge: (operationId) =>
            retryService.acknowledgeRestore(operationId: operationId),
      );
      addTearDown(retryController.dispose);

      await retryController.beginPreparation();
      await retryController.confirm();

      expect(retryController.value.phase, RestoreUiPhase.completed);
      expect(storage.values[_ownerKey], userId);
      expect(storage.values[_enabledKey], '1');
      expect((await retryService.status()).enabled, isTrue);
      expect(
        (await destination
                .customSelect('SELECT country FROM user_settings LIMIT 1;')
                .getSingle())
            .read<String>('country'),
        'AFTER-COMMIT',
        reason:
            'retry completes key state only; it must not reapply the snapshot',
      );
    });

    test('committed journal replay under B cannot publish A key state',
        () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_data_owner_uid': 'A',
        'local_data_owner_generation': 'generation-A',
      });
      final source = await openMemory();
      final destination = await openMemory();
      addTearDown(source.close);
      addTearDown(destination.close);
      await source.customStatement("UPDATE user_settings SET country = 'EG';");

      final crypto = BackupCrypto(
        kdf: Argon2id(
          memory: BackupEnvelopeLimits.minMemoryKib,
          parallelism: 1,
          iterations: 1,
          hashLength: 32,
        ),
      );
      const passphrase = 'restore-passphrase';
      final snapshot = await BackupSnapshotBuilder(source).build();
      final blob = await crypto.encryptEnvelopeV3(
        json: snapshot,
        schemaVersion: BackupSnapshotBuilder.currentSchemaVersion,
        passphrase: passphrase,
      );
      final bytes = blob.toBytes();
      final remote = _MemoryRemoteStore('A');
      const path = 'A/g/replay.enc';
      remote.objects[path] = bytes;
      remote.current = RemoteBackupMetadata(
        generationId: 'restore-generation-replay',
        objectPath: path,
        envelopeVersion: 3,
        sizeBytes: bytes.length,
        blobSha256: sha256Hex(bytes),
        operationId: 'restore-operation-replay-account',
      );
      final storage = _FaultStorage(_accountAState());
      final client = await _signedInClient('A');
      var localOwner = 'A';

      EncryptedBackupService newService() => EncryptedBackupService(
            database: destination,
            client: client,
            storage: storage,
            crypto: crypto,
            remoteStore: remote,
            readLocalDataOwnerUid: () async => localOwner,
          );

      final firstService = newService();
      final firstPlan =
          await firstService.prepareRestore(passphrase: passphrase);
      final firstResult = await firstService.commitRestore(
        confirmation: RestoreConfirmation.forTest(firstPlan),
      );
      expect(firstResult.outcome, RestoreOutcome.success);
      expect(storage.values[_ownerKey], 'A');
      expect(storage.values[_enabledKey], '1');

      // Simulate a new launch/account admission. The remote operation id still
      // resolves to A's committed journal entry, but preparation now belongs to B.
      await destination.customStatement(
          "UPDATE user_settings SET country = 'AFTER-COMMIT';");
      await _recoverSessionAs(client, 'B');
      localOwner = 'B';
      FlutterSecureStorage.setMockInitialValues({
        'local_data_owner_uid': 'B',
        'local_data_owner_generation': 'generation-B',
      });

      final replayService = newService();
      final replayPlan =
          await replayService.prepareRestore(passphrase: passphrase);
      final replayResult = await replayService.commitRestore(
        confirmation: RestoreConfirmation.forTest(replayPlan),
      );

      expect(replayResult.outcome, RestoreOutcome.committedPendingBackupState);
      expect(replayResult.isCommitted, isTrue);
      expect(
        replayResult.warnings,
        contains(RestoreService.backupStateOwnershipConflictWarning),
      );
      expect(storage.values[_ownerKey], 'A',
          reason: 'journal replay must not relabel A material as B-owned');
      expect(storage.values[_enabledKey], '1',
          reason: 'the intact A publication may remain enabled only for A');
      expect((await replayService.status()).enabled, isFalse);
      await replayService.backupNow();
      expect(remote.putCount, 0,
          reason: "B must not encrypt or upload with A's restored key");
      expect(
        (await destination
                .customSelect('SELECT country FROM user_settings LIMIT 1;')
                .getSingle())
            .read<String>('country'),
        'AFTER-COMMIT',
        reason: 'the committed snapshot must not be destructively replayed',
      );
    });
  });
}
