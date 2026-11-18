import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_crypto.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/encrypted_backup_service.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show StorageException;
import '../../harness/seed_test_account.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

// Light Argon2id params to keep tests fast.
BackupCrypto _fastCrypto() => BackupCrypto(
      kdf: Argon2id(
        memory: 64,
        parallelism: 1,
        iterations: 1,
        hashLength: 32,
      ),
      cipher: AesGcm.with256bits(),
    );

Future<AppDatabase> _openDb() => seededDb(AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    ));

void main() {
  // A restore mirrors the restored language into the keychain for the unlock
  // prompt (core/security/lock_prompt_language.dart); this suite has no
  // keychain, so it gets an in-memory one.
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  // ── EncryptedBackupBlob serialization ──────────────────────────────────────
  group('EncryptedBackupBlob', () {
    test('toBytes / fromBytes roundtrip is lossless', () {
      const original = EncryptedBackupBlob(
        version: 1,
        salt: [1, 2, 3, 4],
        nonce: [5, 6, 7],
        cipherText: [10, 20, 30, 40],
        mac: [99, 88, 77],
      );
      final restored = EncryptedBackupBlob.fromBytes(original.toBytes());

      expect(restored.version, original.version);
      expect(restored.salt, original.salt);
      expect(restored.nonce, original.nonce);
      expect(restored.cipherText, original.cipherText);
      expect(restored.mac, original.mac);
    });

    test('toBytes produces valid UTF-8 JSON with required fields', () {
      const blob = EncryptedBackupBlob(
        version: 1,
        salt: [0],
        nonce: [0],
        cipherText: [0],
        mac: [0],
      );
      final json =
          jsonDecode(utf8.decode(blob.toBytes())) as Map<String, dynamic>;
      expect(json['version'], 1);
      expect(json['kdf'], 'argon2id');
      expect(json['cipher'], 'aes-256-gcm');
      for (final key in ['salt', 'nonce', 'cipherText', 'mac']) {
        expect(json.containsKey(key), isTrue, reason: 'missing field: $key');
      }
    });
  });

  // ── BackupCrypto ────────────────────────────────────────────────────────────
  group('BackupCrypto', () {
    test('encrypt then decrypt returns original JSON', () async {
      final crypto = _fastCrypto();
      const payload = {'hello': 'world', 'number': 42};
      const passphrase = 'test-passphrase';

      final blob =
          await crypto.encryptJson(json: payload, passphrase: passphrase);
      final recovered =
          await crypto.decryptJson(blob: blob, passphrase: passphrase);

      expect(recovered['hello'], 'world');
      expect(recovered['number'], 42);
    });

    test('wrong passphrase throws SecretBoxAuthenticationError', () async {
      final crypto = _fastCrypto();
      final blob = await crypto.encryptJson(
        json: {'secret': 'data'},
        passphrase: 'correct',
      );

      await expectLater(
        () => crypto.decryptJson(blob: blob, passphrase: 'wrong'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('encrypted blob survives toBytes / fromBytes before decryption',
        () async {
      final crypto = _fastCrypto();
      const payload = {'round': 'trip'};
      final blob = await crypto.encryptJson(
        json: payload,
        passphrase: 'abc',
        salt: List.generate(16, (i) => i),
      );

      final deserialized = EncryptedBackupBlob.fromBytes(blob.toBytes());
      final recovered =
          await crypto.decryptJson(blob: deserialized, passphrase: 'abc');

      expect(recovered['round'], 'trip');
    });

    test('randomBytes returns requested length', () {
      expect(_fastCrypto().randomBytes(16).length, 16);
      expect(_fastCrypto().randomBytes(32).length, 32);
    });

    test('nested JSON survives encrypt / decrypt', () async {
      final crypto = _fastCrypto();
      final payload = {
        'tables': {
          'transactions': [
            {'id': 'txn-1', 'amount': 150.5},
          ],
        },
      };
      final blob = await crypto.encryptJson(json: payload, passphrase: 'pass');
      final recovered =
          await crypto.decryptJson(blob: blob, passphrase: 'pass');

      final txns = (recovered['tables']['transactions'] as List)
          .cast<Map<String, dynamic>>();
      expect(txns.first['id'], 'txn-1');
      expect(txns.first['amount'], 150.5);
    });
  });

  // ── BackupSnapshotBuilder ──────────────────────────────────────────────────
  group('BackupSnapshotBuilder', () {
    late AppDatabase db;
    setUp(() async => db = await _openDb());
    tearDown(() async => db.close());

    test('snapshot has required top-level keys', () async {
      final snapshot = await BackupSnapshotBuilder(db).build();
      expect(snapshot['version'], 4);
      expect(snapshot['schemaVersion'],
          BackupSnapshotBuilder.currentSchemaVersion);
      expect(snapshot.containsKey('createdAt'), isTrue);
      expect(snapshot.containsKey('privacy'), isTrue);
      expect(snapshot.containsKey('tables'), isTrue);
    });

    test('snapshot includes all expected tables', () async {
      final snapshot = await BackupSnapshotBuilder(db).build();
      final tables = snapshot['tables'] as Map<String, dynamic>;
      for (final table in [
        'transactions',
        'budgets',
        'goals',
        'goal_contributions',
        'merchant_category_map',
        'merchants',
        'achievements',
        'streaks',
        'user_settings',
        'subscriptions',
        'bill_payments',
        'plans',
        'plan_transaction_links',
      ]) {
        expect(tables.containsKey(table), isTrue,
            reason: 'missing table: $table');
      }
    });

    test('privacy block has correct values', () async {
      final snapshot = await BackupSnapshotBuilder(db).build();
      final privacy = snapshot['privacy'] as Map<String, dynamic>;
      expect(privacy['rawMessageExcluded'], isTrue);
      expect(privacy['serverReadableFinancialData'], isFalse);
    });

    test('fresh DB snapshot has empty transactions list', () async {
      final snapshot = await BackupSnapshotBuilder(db).build();
      final tables = snapshot['tables'] as Map<String, dynamic>;
      expect(tables['transactions'], isEmpty);
    });

    test('createdAt is a valid ISO-8601 UTC timestamp', () async {
      final snapshot = await BackupSnapshotBuilder(db).build();
      final ts = DateTime.tryParse(snapshot['createdAt'] as String);
      expect(ts, isNotNull);
      expect(ts!.isUtc, isTrue);
    });
  });

  // ── RestoreBackupUseCase ───────────────────────────────────────────────────
  group('RestoreBackupUseCase', () {
    late AppDatabase db;
    setUp(() async => db = await _openDb());
    tearDown(() async => db.close());

    Map<String, dynamic> emptySnapshot({
      List<Map<String, dynamic>> merchants = const [],
      List<Map<String, dynamic>> transactions = const [],
    }) {
      return {
        'version': 1,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'tables': {
          'merchants': merchants,
          'merchant_category_map': <Map<String, dynamic>>[],
          'transactions': transactions,
          'budgets': <Map<String, dynamic>>[],
          'goals': <Map<String, dynamic>>[],
          'goal_contributions': <Map<String, dynamic>>[],
          'achievements': <Map<String, dynamic>>[],
          'streaks': <Map<String, dynamic>>[],
          'user_settings': <Map<String, dynamic>>[],
          'subscriptions': <Map<String, dynamic>>[],
        },
      };
    }

    test('restore adds transactions to DB', () async {
      final snapshot = emptySnapshot(
        merchants: [
          {
            'id': 'm1',
            'raw_name': 'مطعم الرياض',
            'normalized_name': 'riyad_rest',
            'first_seen_at': '2024-01-01T00:00:00.000Z',
            'last_seen_at': '2024-01-01T00:00:00.000Z',
          },
        ],
        transactions: [
          {
            'id': 'txn-1',
            'amount': 150.0,
            'currency': 'SAR',
            'merchant_id': 'm1',
            'raw_merchant': 'مطعم الرياض',
            'category_id': null,
            'type': 'expense',
            'source': 'sms',
            'card_last4': '1234',
            'balance_after': null,
            'occurred_at': '2024-01-01T12:00:00.000Z',
            'parse_confidence': 0.95,
            'status': 'confirmed',
            'created_at': '2024-01-01T12:00:00.000Z',
            'updated_at': '2024-01-01T12:00:00.000Z',
          },
        ],
      );

      await RestoreBackupUseCase(db)(snapshot);

      final rows =
          await db.customSelect('SELECT id, amount FROM transactions;').get();
      expect(rows.length, 1);
      expect(rows.first.data['id'], 'txn-1');
      expect(rows.first.data['amount'], 150.0);
    });

    // Decision 3.3 (restore = merge): a record this device holds that the
    // backup lacks is kept. Previously pinned "restore replaces existing data".
    test('restore keeps existing data the backup does not have', () async {
      await db.customInsert(
        "INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, last_seen_at) "
        "VALUES ('m-old', 'old', 'old_norm', '2024-01-01', '2024-01-01');",
      );
      await db.customInsert(
        "INSERT INTO transactions(id, amount, currency, merchant_id, raw_merchant, "
        "category_id, type, source, occurred_at, parse_confidence, status, created_at, "
        "updated_at, raw_message) "
        "VALUES ('old-txn', 999, 'SAR', 'm-old', 'old', NULL, 'expense', 'manual', "
        "'2024-01-01', 1.0, 'confirmed', '2024-01-01', '2024-01-01', 'msg');",
      );
      await backfillNonPlanningMoneyV30(db);

      await RestoreBackupUseCase(db)(emptySnapshot());

      final rows = await db.customSelect('SELECT id FROM transactions;').get();
      expect(rows.map((r) => r.read<String>('id')), ['old-txn']);
    });

    test('restore sets raw_message placeholder on transactions', () async {
      final snapshot = emptySnapshot(
        merchants: [
          {
            'id': 'm1',
            'raw_name': 'test',
            'normalized_name': 'test_norm',
            'first_seen_at': '2024-01-01',
            'last_seen_at': '2024-01-01',
          },
        ],
        transactions: [
          {
            'id': 't1',
            'amount': 10.0,
            'currency': 'SAR',
            'merchant_id': 'm1',
            'raw_merchant': 'test',
            'category_id': null,
            'type': 'expense',
            'source': 'sms',
            'card_last4': null,
            'balance_after': null,
            'occurred_at': '2024-01-01',
            'parse_confidence': 1.0,
            'status': 'confirmed',
            'created_at': '2024-01-01',
            'updated_at': '2024-01-01',
          },
        ],
      );

      await RestoreBackupUseCase(db)(snapshot);

      final row = await db.customSelect(
        'SELECT raw_message FROM transactions WHERE id = ?;',
        variables: [const Variable<String>('t1')],
      ).getSingle();
      expect(
        row.data['raw_message'],
        '[restored: raw message intentionally excluded]',
      );
    });

    test('snapshot → restore → snapshot produces same table keys', () async {
      final original = await BackupSnapshotBuilder(db).build();
      await RestoreBackupUseCase(db)(original);
      final after = await BackupSnapshotBuilder(db).build();

      final originalTables = original['tables'] as Map<String, dynamic>;
      final afterTables = after['tables'] as Map<String, dynamic>;
      expect(afterTables.keys.toSet(), originalTables.keys.toSet());
    });

    // ── H1: schema-version upper-bound validation ────────────────────────────
    //
    // A backup written by a NEWER app build could carry a schemaVersion this
    // build doesn't know how to fully apply — post-restore migrations are
    // only defined up to currentSchemaVersion, so silently proceeding could
    // leave the DB structurally present but semantically half-migrated, with
    // no error surfaced to the user. Restoring must reject any schemaVersion
    // greater than currentSchemaVersion, and must do so BEFORE the
    // delete/restore transaction touches the existing local data.

    test('lower schema version than current is accepted', () async {
      // A version BELOW current must never be rejected as "newer". Use a REAL
      // snapshot (which carries the required tables) relabeled to current-1:
      // an EMPTY current-1 snapshot is correctly rejected for a missing required
      // table (see the completeness suite), so version-acceptance is proven with
      // a complete snapshot, not an empty one.
      final snapshot = {
        ...await BackupSnapshotBuilder(db).build(),
        'schemaVersion': RestoreBackupUseCase.currentSchemaVersion - 1,
      };

      await expectLater(RestoreBackupUseCase(db)(snapshot), completes);
    });

    test('schema version equal to current is accepted', () async {
      // A real current-version snapshot carries the required tables (seeded
      // catalog, default account, user_settings); the preflight rejects only a
      // NEWER format, not the current one. (An empty v3 snapshot is correctly
      // rejected — see the completeness suite's truncation tests.)
      final snapshot = await BackupSnapshotBuilder(db).build();
      expect(
          snapshot['schemaVersion'], RestoreBackupUseCase.currentSchemaVersion);
      await expectLater(RestoreBackupUseCase(db)(snapshot), completes);
    });

    test('missing schema version is accepted (pre-versioning backups)',
        () async {
      final snapshot = emptySnapshot(); // no 'schemaVersion' key at all

      await expectLater(RestoreBackupUseCase(db)(snapshot), completes);
    });

    test(
        'invalid (non-positive/non-int) schema version is accepted, '
        'floored to the oldest known version', () async {
      for (final invalid in [0, -1, 'not-a-number', null]) {
        final snapshot = {...emptySnapshot(), 'schemaVersion': invalid};
        await expectLater(RestoreBackupUseCase(db)(snapshot), completes);
      }
    });

    test(
        'higher schema version than current is rejected BEFORE any existing '
        'local data is touched', () async {
      await db.customInsert(
        "INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, last_seen_at) "
        "VALUES ('m-keep', 'keep', 'keep_norm', '2024-01-01', '2024-01-01');",
      );
      await db.customInsert(
        "INSERT INTO transactions(id, amount, currency, merchant_id, raw_merchant, "
        "category_id, type, source, occurred_at, parse_confidence, status, created_at, "
        "updated_at, raw_message) "
        "VALUES ('keep-txn', 42, 'SAR', 'm-keep', 'keep', NULL, 'expense', 'manual', "
        "'2024-01-01', 1.0, 'confirmed', '2024-01-01', '2024-01-01', 'msg');",
      );
      await backfillNonPlanningMoneyV30(db);
      final snapshot = {
        ...emptySnapshot(),
        'schemaVersion': RestoreBackupUseCase.currentSchemaVersion + 1,
      };

      await expectLater(
        RestoreBackupUseCase(db)(snapshot),
        throwsA(isA<BackupException>()),
      );

      // The existing row must survive — rejection happened before the
      // delete/restore transaction, not mid-way through it.
      final rows = await db.customSelect('SELECT id FROM transactions;').get();
      expect(rows.map((r) => r.data['id']), ['keep-txn']);
    });

    test(
        'a failure mid-restore still restores PRAGMA foreign_keys — it must '
        'not stay OFF for the rest of the connection\'s lifetime', () async {
      final snapshot = {
        ...emptySnapshot(),
        'tables': {
          ...emptySnapshot()['tables'] as Map<String, dynamic>,
          // A column that doesn't exist on `budgets` fails the INSERT
          // partway through the restore loop, after PRAGMA foreign_keys has
          // already been set OFF.
          'budgets': [
            {'id': 'b1', 'no_such_column': 'boom'},
          ],
        },
      };

      await expectLater(RestoreBackupUseCase(db)(snapshot), throwsException);

      final pragma = await db.customSelect('PRAGMA foreign_keys;').getSingle();
      expect(pragma.data.values.first, 1,
          reason: 'foreign_keys must be back ON after the failure, not left '
              'OFF by the aborted restore');
    });
  });

  // ── backupStorageExceptionMessage ──────────────────────────────────────────
  group('backupStorageExceptionMessage', () {
    test('404 status returns bucket-setup message', () {
      final msg = backupStorageExceptionMessage(
        const StorageException('Not found', statusCode: '404'),
      );
      expect(msg, contains('backups'));
      expect(msg, contains('Supabase'));
    });

    test('"bucket not found" in body returns bucket-setup message', () {
      final msg = backupStorageExceptionMessage(
        const StorageException('Bucket not found', statusCode: '500'),
      );
      expect(msg, contains('backups'));
    });

    test('other error includes original exception message', () {
      final msg = backupStorageExceptionMessage(
        const StorageException('network timeout', statusCode: '503'),
      );
      expect(msg, contains('network timeout'));
    });
  });
}
