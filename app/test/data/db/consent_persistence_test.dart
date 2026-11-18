import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';

// WP-6 — versioned, per-replica consent: the v40 migration, the repository that
// assigns versions, and the per-uid persistence rules (survives sign-out, never
// crosses uids, a fresh replica starts unset so the user is asked again).

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

const _uidA = 'uid-aaaa';
const _uidB = 'uid-bbbb';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> memoryDb() => AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );

  Future<UserSettingsEntity> grant(
    DriftUserSettingsRepository repo, {
    ConsentState? cloud,
    ConsentState? ai,
  }) async {
    final current = await repo.getSettings();
    return repo.saveSettings(
        current.copyWith(cloudConsentState: cloud, aiConsentState: ai));
  }

  group('v40 migration', () {
    test('adds the version/time columns; explicit choices start at version 1',
        () async {
      final db = await memoryDb();
      addTearDown(db.close);
      // Wind back to a v39 shape: no consent version columns, one explicit
      // cloud choice, AI never asked.
      for (final c in const [
        'cloud_consent_version',
        'cloud_consent_at',
        'ai_consent_version',
        'ai_consent_at',
      ]) {
        await db.customStatement('ALTER TABLE user_settings DROP COLUMN $c;');
      }
      await db.customStatement(
          "UPDATE user_settings SET cloud_consent_state = 'accepted', "
          'cloud_processing_enabled = 1;');
      await db.customStatement('PRAGMA user_version = 39;');

      await db.debugReinitialize();

      expect(
          (await db.customSelect('PRAGMA user_version;').getSingle())
              .read<int>('user_version'),
          44); // v39 -> v40 (WP-6) -> v41 (WP-5, unrelated to consent)
      final s = await DriftUserSettingsRepository(db).getSettings();
      expect(s.cloudConsentState, ConsentState.accepted,
          reason: 'the migration never changes a consent value');
      expect(s.cloudConsentVersion, 1);
      expect(s.cloudConsentAt, isNull, reason: 'the time is unknown');
      expect(s.aiConsentState, ConsentState.unset);
      expect(s.aiConsentVersion, 0);
    });

    test('is idempotent: a replay keeps versions and values', () async {
      final db = await memoryDb();
      addTearDown(db.close);
      final repo = DriftUserSettingsRepository(db);
      await grant(repo, cloud: ConsentState.accepted);
      await db.customStatement('PRAGMA user_version = 39;');
      await db.debugReinitialize();
      await db.customStatement('PRAGMA user_version = 39;');
      await db.debugReinitialize();
      final s = await repo.getSettings();
      expect(s.cloudConsentState, ConsentState.accepted);
      expect(s.cloudConsentVersion, 1);
    });
  });

  group('versions are assigned by the repository and never decrease', () {
    test('a change bumps the shared version and stamps the time', () async {
      final db = await memoryDb();
      addTearDown(db.close);
      final repo = DriftUserSettingsRepository(db);
      var s = await repo.getSettings();
      expect(s.consentVersion, 0);
      expect(s.cloudConsentAt, isNull);

      s = await grant(repo, cloud: ConsentState.accepted);
      expect(s.cloudConsentVersion, 1);
      expect(s.aiConsentVersion, 0, reason: 'AI was not touched');
      expect(s.cloudConsentAt, isNotNull);

      s = await grant(repo, ai: ConsentState.accepted);
      expect(s.aiConsentVersion, 2);
      expect(s.cloudConsentVersion, 1, reason: 'cloud keeps its own version');
      expect(s.consentVersion, 2);

      s = await grant(repo, cloud: ConsentState.declined);
      expect(s.cloudConsentVersion, 3);
      expect(s.consentVersion, 3);

      final stored = await repo.getSettings();
      expect(stored.cloudConsentVersion, 3);
      expect(stored.aiConsentVersion, 2);
      expect(stored.aiConsentAt, isNotNull);
    });

    test('saving without a consent change never moves a version', () async {
      final db = await memoryDb();
      addTearDown(db.close);
      final repo = DriftUserSettingsRepository(db);
      await grant(repo, cloud: ConsentState.accepted);
      final before = await repo.getSettings();
      await repo.saveSettings(before.copyWith(theme: 'dark'));
      final after = await repo.getSettings();
      expect(after.consentVersion, before.consentVersion);
      expect(after.cloudConsentAt, before.cloudConsentAt);
    });

    test('a stale entity cannot lower or invent a version', () async {
      final db = await memoryDb();
      addTearDown(db.close);
      final repo = DriftUserSettingsRepository(db);
      final stale = await repo.getSettings(); // version 0
      await grant(repo, cloud: ConsentState.accepted); // 1
      await grant(repo, ai: ConsentState.accepted); // 2
      // The stale entity carries version 0 and a forged 99; neither is stored.
      await repo.saveSettings(stale.copyWith(
        theme: 'dark',
        cloudConsentState: ConsentState.accepted,
        aiConsentState: ConsentState.accepted,
        cloudConsentVersion: 99,
        aiConsentVersion: 0,
      ));
      final s = await repo.getSettings();
      expect(s.cloudConsentVersion, 1);
      expect(s.aiConsentVersion, 2);
      expect(s.consentVersion, 2);
    });

    test('a restore reset is a consent change: the version moves forward',
        () async {
      final db = await memoryDb();
      addTearDown(db.close);
      final repo = DriftUserSettingsRepository(db);
      await grant(repo,
          cloud: ConsentState.accepted, ai: ConsentState.accepted); // v1
      await db.runPostRestoreSetup();
      final s = await repo.getSettings();
      expect(s.cloudProcessingEnabled, isFalse);
      expect(s.aiConsentGranted, isFalse);
      expect(s.consentVersion, 2,
          reason: 'the OFF state must outrank the projected grant');
    });
  });

  group('per user, per device, in the user\'s own replica', () {
    late Directory support;
    ReplicaStore store() => ReplicaStore(requireCreationAuthority: false, appSupportDirectory: support.path);

    setUp(() {
      support = Directory.systemTemp.createTempSync('consent_replica_');
      FlutterSecureStorage.setMockInitialValues({});
    });
    tearDown(() {
      if (support.existsSync()) support.deleteSync(recursive: true);
    });

    test('consent survives sign-out (lock) and re-login of the same uid',
        () async {
      final s = store();
      var db = await s.openReplica(_uidA);
      await grant(DriftUserSettingsRepository(db),
          cloud: ConsentState.accepted, ai: ConsentState.accepted);
      await db.close(); // sign-out locks and closes; nothing is deleted

      db = await store().openReplica(_uidA);
      final settings = await DriftUserSettingsRepository(db).getSettings();
      expect(settings.cloudProcessingEnabled, isTrue);
      expect(settings.aiConsentGranted, isTrue);
      expect(settings.consentVersion, 1);
      await db.close();
    });

    test("uid A's consent never applies to uid B", () async {
      final s = store();
      final a = await s.openReplica(_uidA);
      await grant(DriftUserSettingsRepository(a),
          cloud: ConsentState.accepted, ai: ConsentState.accepted);
      await a.close();

      final b = await s.openReplica(_uidB);
      final settings = await DriftUserSettingsRepository(b).getSettings();
      expect(settings.cloudConsentState, ConsentState.unset);
      expect(settings.aiConsentState, ConsentState.unset);
      expect(settings.consentVersion, 0);
      await b.close();
    });

    test('a new replica (new device, or after Remove data) asks again',
        () async {
      final s = store();
      final first = await s.openReplica(_uidA);
      await grant(DriftUserSettingsRepository(first),
          cloud: ConsentState.accepted, ai: ConsentState.accepted);
      await first.close();

      await s.remove(_uidA); // Remove data from this device
      final fresh = await s.openReplica(_uidA);
      final settings = await DriftUserSettingsRepository(fresh).getSettings();
      expect(settings.cloudConsentState, ConsentState.unset,
          reason: 'unset means: not granted, ask the user');
      expect(settings.aiConsentState, ConsentState.unset);
      expect(settings.consentVersion, 0);
      await fresh.close();
    });
  });
}
