import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/replica_recovery.dart';
import 'package:money_companion/core/privacy/data_wipe_service.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/data/db/app_database.dart';

// WP-7 staging: the device-local settings (consent, preferences) are seeded into
// the fresh replica before the pull. The fresh replica already holds a pristine
// seeded settings row with its own id, so the seed must UPDATE that row to the
// device's, leaving exactly one authoritative row (never an INSERT OR REPLACE
// beside it, never an unordered LIMIT 1 choice).

class _NoLookup implements LedgerServerLookup {
  @override
  Future<Map<String, Map<String, dynamic>>> byClientRequestId(
          Set<String> ids) async =>
      {};
}

void main() {
  late AppDatabase old;
  late AppDatabase fresh;

  setUp(() async {
    old = await AppDatabase.open(executor: NativeDatabase.memory());
    fresh = await AppDatabase.open(executor: NativeDatabase.memory());
  });
  tearDown(() async {
    await old.close();
    await fresh.close();
  });

  ReplicaRecovery recovery() =>
      ReplicaRecovery(old: old, fresh: fresh, lookup: _NoLookup());

  Future<int> rows(AppDatabase db) async => (await db
          .customSelect('SELECT COUNT(*) AS n FROM user_settings')
          .getSingle())
      .read<int>('n');

  Future<void> deviceConsent() async {
    await old.customStatement(
        "UPDATE user_settings SET cloud_consent_state = 'accepted', "
        "cloud_processing_enabled = 1, cloud_consent_version = 3, "
        "currency = 'EGP'");
    await old.customStatement(
        'INSERT OR IGNORE INTO consent_version_watermark(id, watermark, reserved) '
        'VALUES (1, 0, 0)');
    await old.customStatement(
        'UPDATE consent_version_watermark SET watermark = 5 WHERE id = 1');
  }

  test(
      'the pristine seed is updated in place: exactly one row, the device '
      'consent and preferences, the watermark carried', () async {
    await deviceConsent();
    final oldId =
        (await old.customSelect('SELECT id FROM user_settings').getSingle())
            .read<String>('id');
    final seededId =
        (await fresh.customSelect('SELECT id FROM user_settings').getSingle())
            .read<String>('id');
    expect(seededId, isNot(oldId),
        reason: 'the two replicas seed distinct ids');

    await recovery().seedDeviceLocalState();

    expect(await rows(fresh), 1);
    final row =
        await fresh.customSelect('SELECT * FROM user_settings').getSingle();
    expect(row.read<String>('id'), oldId);
    expect(row.read<String>('cloud_consent_state'), 'accepted');
    expect(row.read<int>('cloud_consent_version'), 3);
    expect(row.read<String>('currency'), 'EGP');
    final marks = await fresh
        .customSelect('SELECT watermark FROM consent_version_watermark')
        .getSingle();
    expect(marks.read<int>('watermark'), 5);
    await recovery().verify();
  });

  test('a populated or ambiguous target is refused, never merged or deleted',
      () async {
    await deviceConsent();
    await fresh.customStatement(
        "UPDATE user_settings SET cloud_consent_state = 'declined', "
        'cloud_consent_version = 1');
    await expectLater(recovery().seedDeviceLocalState(),
        throwsA(isA<RecoveryIncompleteException>()));
    expect(await rows(fresh), 1);
    expect(
        (await fresh
                .customSelect(
                    'SELECT cloud_consent_state AS s FROM user_settings')
                .getSingle())
            .read<String>('s'),
        'declined');
  });

  test(
      'a crash after the seed: the retry recognizes its own seed, even after '
      'a pull touched server fields, and changes nothing', () async {
    await deviceConsent();
    await recovery().seedDeviceLocalState();
    await fresh.customStatement(
        "UPDATE user_settings SET server_id = 'srv', sync_status = 'synced', "
        "display_name = 'From server'");
    await recovery().seedDeviceLocalState(); // the retried phase
    expect(await rows(fresh), 1);
    final row =
        await fresh.customSelect('SELECT * FROM user_settings').getSingle();
    expect(row.read<String>('cloud_consent_state'), 'accepted');
    expect(row.read<String>('display_name'), 'From server',
        reason: 'the retry never overwrites');
    await recovery().verify();
  });

  test('a retry whose consent no longer matches the device row is refused',
      () async {
    await deviceConsent();
    await recovery().seedDeviceLocalState();
    await fresh.customStatement(
        "UPDATE user_settings SET cloud_consent_state = 'declined'");
    await expectLater(recovery().seedDeviceLocalState(),
        throwsA(isA<RecoveryIncompleteException>()));
  });

  test(
      'a target with edited preferences but unset consent is not the default '
      'seed: refused, never overwritten', () async {
    await deviceConsent();
    await fresh.customStatement("UPDATE user_settings SET currency = 'KWD'");
    await expectLater(recovery().seedDeviceLocalState(),
        throwsA(isA<RecoveryIncompleteException>()));
    expect(
        (await fresh
                .customSelect('SELECT currency AS c FROM user_settings')
                .getSingle())
            .read<String>('c'),
        'KWD');
  });

  test('v41 migration creates nullable provenance without granting consent', () async {
    await fresh.customStatement('DROP TABLE consent_version_watermark');
    await fresh.customStatement('PRAGMA user_version = 41');
    await fresh.debugReinitialize();
    final columns = await fresh.customSelect('PRAGMA table_info(consent_version_watermark)').get();
    expect(columns.any((r) => r.read<String>('name') == 'seed_source_fingerprint'), isTrue);
    expect(await fresh.customSelect('SELECT * FROM consent_version_watermark').get(), isEmpty);
    expect((await fresh.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 44);
  });

  test('seed provenance is excluded from backup and cleared by wipe, frontier retained', () async {
    await deviceConsent();
    await recovery().seedDeviceLocalState();
    final mark = await fresh.customSelect('SELECT * FROM consent_version_watermark').getSingle();
    expect(mark.read<String?>('seed_source_fingerprint'), isNotNull);
    final snapshot = await BackupSnapshotBuilder(fresh).build();
    expect(snapshot.containsKey('consent_version_watermark'), isFalse);
    expect(snapshot.toString(), isNot(contains(mark.read<String>('seed_source_fingerprint'))));
    await DataWipeService(fresh).wipeAll();
    final wiped = await fresh.customSelect('SELECT * FROM consent_version_watermark').getSingle();
    expect(wiped.read<String?>('seed_source_fingerprint'), isNull);
    expect(wiped.read<int>('watermark'), 5);
  });

  test('independently populated same-id settings are not seed provenance',
      () async {
    final id =
        (await old.customSelect('SELECT id FROM user_settings').getSingle())
            .read<String>('id');
    await fresh.customStatement('UPDATE user_settings SET id = ?', [id]);
    await expectLater(recovery().seedDeviceLocalState(),
        throwsA(isA<RecoveryIncompleteException>()));
  });

  for (final column in [
    'merchant_personalization_enabled',
    'planning_cutover_state',
    'server_revision'
  ]) {
    test('nondefault $column is not a pristine seed', () async {
      final edited = column == 'planning_cutover_state' ? 0 : 1;
      await fresh.customStatement('UPDATE user_settings SET $column = $edited');
      await expectLater(recovery().seedDeviceLocalState(),
          throwsA(isA<RecoveryIncompleteException>()));
      expect(
          (await fresh
                  .customSelect('SELECT $column FROM user_settings')
                  .getSingle())
              .read<int>(column),
          edited);
    });
  }

  test(
      'two settings rows in the staging replica fail verification before any '
      'pull or swap', () async {
    await fresh.customStatement(
        "INSERT INTO user_settings(id, display_name, country, currency, language, "
        "theme, input_method, notifications_json, db_encryption_key_ref) "
        "SELECT 'other-row', display_name, country, currency, language, theme, "
        "input_method, notifications_json, db_encryption_key_ref FROM user_settings");
    expect(await rows(fresh), 2);
    await expectLater(
        recovery().verify(), throwsA(isA<RecoveryIncompleteException>()));
    await expectLater(recovery().seedDeviceLocalState(),
        throwsA(isA<RecoveryIncompleteException>()));
  });

  test('an ambiguous source (not exactly one settings row) is refused',
      () async {
    await old.customStatement(
        "INSERT INTO user_settings(id, display_name, country, currency, language, "
        "theme, input_method, notifications_json, db_encryption_key_ref) "
        "SELECT 'dup', display_name, country, currency, language, theme, "
        "input_method, notifications_json, db_encryption_key_ref FROM user_settings");
    await expectLater(recovery().seedDeviceLocalState(),
        throwsA(isA<RecoveryIncompleteException>()));
  });
}
