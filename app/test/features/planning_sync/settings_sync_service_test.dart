import '../capture/ledger_admission_fixture.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/usecases/user_settings_usecases.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';

import '../../harness/fake_cas_server.dart';
import 'package:money_companion/features/planning_sync/services/planning_startup_registration_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _FakeRemote implements PlanningRemoteSink, PlanningRemoteSource {
  final rows = <String, Map<String, Map<String, dynamic>>>{};
  bool forceCasConflict = false;
  bool forceGuardConflict = false;
  int consentUpdateFailuresRemaining = 0;
  int casCalls = 0;
  int guardedUpdateCalls = 0;

  /// NEW-H-4: when set, fetching this table throws — a transport failure for
  /// exactly one entity, which the pull swallows into an incomplete result.
  String? failFetchTable;
  SyncCursor? settingsFetchAfter;

  /// WP-5: the last field patch an update sent (to assert what left the device).
  Map<String, dynamic>? lastPatch;

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    required SyncCursor after,
    int limit = 200,
  }) async {
    if (failFetchTable == table) {
      throw StateError('injected transport failure for $table');
    }
    if (table == 'user_settings') settingsFetchAfter = after;
    return (rows[table]?.values ?? const <Map<String, dynamic>>[])
        .take(limit)
        .map(Map<String, dynamic>.from)
        .toList();
  }

  @override
  Future<Map<String, dynamic>?> findByLocalId(
          String table, String userId, String localId) async =>
      rows[table]?[localId];


  @override
  Future<Map<String, dynamic>?> guardedTombstone(
          String table, String serverId, String? expectedUpdatedAt) async =>
      {'id': serverId};

  @override
  Future<Map<String, dynamic>?> fetchRowState(
          String table, String serverId) async =>
      null;

  @override
  Future<Map<String, dynamic>> upsert(
      String table, Map<String, dynamic> row) async {
    final localId = row['local_id'] as String;
    final now = DateTime.utc(2026, 7, 5, 1).toIso8601String();
    final existing = rows[table]?[localId];
    final saved = {
      ...?existing,
      ...row,
      'id': existing?['id'] ?? 'server-$localId',
      'updated_at': now,
      'revision': (existing?['revision'] as num?)?.toInt() ?? 1,
      'deleted_at': null,
    };
    rows.putIfAbsent(table, () => {})[localId] = saved;
    return {
      'id': saved['id'],
      'updated_at': now,
      'revision': saved['revision'],
    };
  }

  @override
  Future<String?> fetchServerUpdatedAt(String table, String serverId) async {
    for (final r in rows[table]?.values ?? const <Map<String, dynamic>>[]) {
      if (r['id'] == serverId) return r['updated_at'] as String?;
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>?> updateByServerId(
      String table, String serverId, Map<String, dynamic> row) async {
    guardedUpdateCalls++;
    lastPatch = Map<String, dynamic>.from(row);
    final carriesConsent = row.containsKey('cloud_processing_enabled');
    if (carriesConsent && consentUpdateFailuresRemaining > 0) {
      consentUpdateFailuresRemaining--;
      return null;
    }
    final tableRows = rows.putIfAbsent(table, () => {});
    String? localId;
    for (final entry in tableRows.entries) {
      if (entry.value['id'] == serverId) {
        localId = entry.key;
        break;
      }
    }
    localId ??= row['local_id'] as String?;
    if (localId == null) return null;
    final existing = tableRows[localId] ?? const <String, dynamic>{};
    final now = DateTime.utc(2026, 7, 5, 2).toIso8601String();
    final revision = ((existing['revision'] as num?)?.toInt() ?? 0) + 1;
    tableRows[localId] = {
      ...existing,
      ...row,
      'id': serverId,
      'local_id': localId,
      'updated_at': now,
      'revision': revision,
      'deleted_at': null,
    };
    return {'id': serverId, 'updated_at': now, 'revision': revision};
  }

  @override
  Future<Map<String, dynamic>?> guardedUpdateByServerId(
    String table,
    String serverId,
    String expectedUpdatedAt,
    Map<String, dynamic> row,
  ) async {
    // C-6: no concurrent writer is modelled here; guard REJECTION is covered in
    // planning_guarded_update_atomicity_test.dart.
    if (forceGuardConflict) return null;
    return updateByServerId(table, serverId, row);
  }


}

Future<AppDatabase> _openDb() => AppDatabase.open(
    executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

PlanningOutboxQueue _queue(AppDatabase db) => PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );

PlanningPushService _push(AppDatabase db, PlanningOutboxQueue q, _FakeRemote r,
        {bool revisionCasEnabled = false}) =>
    PlanningPushService(
        mayEgress: () async => true,
        db: db,
        queue: q,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: r,
        casGate: revisionCasEnabled ? casGate(db) : null,
        casRemote: revisionCasEnabled ? FakeCasServer() : null);

PlanningPullService _pull(
        AppDatabase db, PlanningOutboxQueue q, _FakeRemote r) =>
    PlanningPullService(
        db: db,
        isEnabled: (_) => true,
        // C-3: covers settings-pull MECHANICS; consent is asserted in
        // financial_pull_consent_test.dart.
        mayEgress: () async => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: r,
        outboxQueue: q);

Future<String?> _col(AppDatabase db, String col) async {
  final row = await db
      .customSelect('SELECT $col AS v FROM user_settings LIMIT 1;')
      .getSingle();
  return row.readNullable<String>('v');
}

Future<int?> _intCol(AppDatabase db, String col) async {
  final row = await db
      .customSelect('SELECT $col AS v FROM user_settings LIMIT 1;')
      .getSingle();
  return row.readNullable<int>('v');
}

Map<String, dynamic> _remoteSettingsRow({
  String theme = 'remote-light',
  bool aiConsentGranted = true,
  bool cloudProcessingEnabled = true,
  int revision = 2,
}) =>
    {
      'id': 'server-user_settings',
      'local_id': 'user_settings',
      'display_name': 'Remote User',
      'phone_number': null,
      'date_of_birth': null,
      'theme': theme,
      'currency': 'USD',
      'language': 'en',
      'country': 'US',
      'input_method': 'manual',
      'notifications_json': '{}',
      'privacy_mode_enabled': true,
      'ai_consent_granted': aiConsentGranted,
      'cloud_processing_enabled': cloudProcessingEnabled,
      'updated_at': 'remote-ts-$revision',
      'revision': revision,
      'deleted_at': null,
    };

late LedgerAdmissionFixture _parentAdmission;

void main() {
  // A settings pull mirrors the pulled language into the keychain for the
  // unlock prompt (core/security/lock_prompt_language.dart); this suite has no
  // keychain, so it gets an in-memory one.
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _FakeRemote remote;
  late PlanningOutboxQueue queue;
  late DriftUserSettingsRepository settings;

  setUp(() async {
    _parentAdmission = await LedgerAdmissionFixture.open('user-1');
    db = _parentAdmission.database;
    remote = _FakeRemote();
    queue = _queue(db);
    settings = DriftUserSettingsRepository(db, outboxQueue: queue);
  });
  tearDown(() => _parentAdmission.finish());

  /// Binds the local singleton to the server row — production state after the
  /// first pull. Ordinary updates only queue once bound; explicit pre-bind
  /// consent changes are the security exception exercised below.
  ///
  /// A-3 (G17): an update with no stored base token now fetches the server row
  /// and guards on it, so the bound server row must actually exist.
  Future<void> bind() async {
    remote.rows.putIfAbsent('user_settings', () => {})['user_settings'] ??= {
      'id': 'server-user_settings',
      'local_id': 'user_settings',
      'updated_at': DateTime.utc(2026, 7, 5).toIso8601String(),
      'revision': 1,
      'deleted_at': null,
    };
    await db.customStatement(
        "UPDATE user_settings SET server_id = 'server-user_settings';");
  }

  test(
      'changing a cloud setting pushes cloud + profile columns, never '
      'device-local/security ones', () async {
    await bind();
    final s = await settings.getSettings();
    await settings.saveSettings(
        s.copyWith(theme: 'dark', currency: 'AED', displayName: 'يوسف'));

    final result = await _push(db, queue, remote).push();
    expect(result.failed, 0);

    final serverRow = remote.rows['user_settings']!['user_settings']!;
    expect(serverRow['theme'], 'dark');
    expect(serverRow['currency'], 'AED');
    // Profile fields sync since migration 0063 — a sign-out wipe used to
    // destroy the user's name/phone/birth date permanently.
    expect(serverRow['display_name'], 'يوسف');
    expect(serverRow.containsKey('phone_number'), isTrue);
    expect(serverRow.containsKey('date_of_birth'), isTrue);
    // Device-local / security columns must NEVER be sent.
    expect(serverRow.containsKey('db_encryption_key_ref'), isFalse);
    expect(serverRow.containsKey('avatar_path'), isFalse);
    // Singleton: constant local_id.
    expect(serverRow['local_id'], 'user_settings');
  });

  test('cloud revocation queues and pushes both server consent flags OFF',
      () async {
    await bind();
    final s = await settings.getSettings();
    await settings.saveSettings(s.copyWith(
      // The local AI preference may remain accepted, but cloud is the master
      // gate: neither server authority may retain an effective/stale AI grant.
      aiConsentState: ConsentState.accepted,
      cloudConsentState: ConsentState.declined,
    ));

    final queued = await db.customSelect('''
      SELECT payload_json FROM planning_sync_outbox
      WHERE entity_type = 'settings'
      LIMIT 1;
    ''').getSingle();
    final payload =
        jsonDecode(queued.read<String>('payload_json')) as Map<String, dynamic>;
    expect(payload['ai_consent_granted'], isFalse);
    expect(payload['cloud_processing_enabled'], isFalse);

    final result = await _push(db, queue, remote).push();
    expect(result.failed, 0);
    final serverRow = remote.rows['user_settings']!['user_settings']!;
    expect(serverRow['ai_consent_granted'], isFalse);
    expect(serverRow['cloud_processing_enabled'], isFalse);
  });

  test(
      'consent revoked before first bind is queued as CREATE and reaches server OFF',
      () async {
    final initial = await settings.getSettings();
    await settings.saveSettings(initial.copyWith(
      aiConsentState: ConsentState.accepted,
      cloudConsentState: ConsentState.accepted,
    ));
    final accepted = await settings.getSettings();
    await settings.saveSettings(accepted.copyWith(
      aiConsentState: ConsentState.declined,
      cloudConsentState: ConsentState.declined,
    ));

    final queued = await db.customSelect('''
      SELECT operation, payload_json FROM planning_sync_outbox
      WHERE entity_type = 'settings'
      LIMIT 1;
    ''').getSingle();
    final payload =
        jsonDecode(queued.read<String>('payload_json')) as Map<String, dynamic>;
    expect(queued.read<String>('operation'), PlanningSyncOperation.create.name);
    expect(payload['ai_consent_granted'], isFalse);
    expect(payload['cloud_processing_enabled'], isFalse);

    final result = await _push(db, queue, remote).push();
    expect(result.pushed, 1);
    final serverRow = remote.rows['user_settings']!['user_settings']!;
    expect(serverRow['ai_consent_granted'], isFalse);
    expect(serverRow['cloud_processing_enabled'], isFalse);
  });

  test(
      'pull bind preserves a pending local consent OFF and requeues it against the server base',
      () async {
    final initial = await settings.getSettings();
    await settings.saveSettings(initial.copyWith(
      aiConsentState: ConsentState.accepted,
      cloudConsentState: ConsentState.accepted,
    ));
    final accepted = await settings.getSettings();
    await settings.saveSettings(accepted.copyWith(
      aiConsentState: ConsentState.declined,
      cloudConsentState: ConsentState.declined,
    ));
    remote.rows['user_settings'] = {
      'user_settings': _remoteSettingsRow(theme: 'remote-dark'),
    };

    await _pull(db, queue, remote).pull();

    expect(await _col(db, 'server_id'), 'server-user_settings');
    expect(await _intCol(db, 'ai_consent_granted'), 0);
    expect(await _intCol(db, 'cloud_processing_enabled'), 0);
    final pending = await db.customSelect('''
      SELECT COUNT(*) AS n FROM planning_sync_outbox
      WHERE entity_type = 'settings' AND status = 'pending';
    ''').getSingle();
    expect(pending.read<int>('n'), 1,
        reason: 'the pull bind must leave the local OFF intent durable');

    await _push(db, queue, remote).push();
    final serverRow = remote.rows['user_settings']!['user_settings']!;
    expect(serverRow['ai_consent_granted'], isFalse);
    expect(serverRow['cloud_processing_enabled'], isFalse);
    expect(serverRow['theme'], 'remote-dark',
        reason:
            'rebasing the revocation must not restore stale local settings');
  });

  test('capability on: settings are field last-writer-wins (never CAS); a '
      'failed consent acknowledgement keeps the durable intent', () async {
    await db.customStatement('''
      UPDATE user_settings
      SET server_id = 'server-user_settings',
          server_updated_at = 'base-ts', server_revision = 1,
          sync_status = 'synced',
          ai_consent_granted = 1, cloud_processing_enabled = 1,
          ai_consent_state = 'accepted', cloud_consent_state = 'accepted';
    ''');
    remote.rows['user_settings'] = {
      'user_settings': _remoteSettingsRow(theme: 'remote-dark', revision: 2),
    };
    remote.consentUpdateFailuresRemaining = 1;

    final current = await settings.getSettings();
    await settings.saveSettings(current.copyWith(
      theme: 'newer-local-theme',
      cloudConsentState: ConsentState.declined,
    ));

    final firstAttempt =
        await _push(db, queue, remote, revisionCasEnabled: true).push();

    expect(firstAttempt.failed, 1);
    expect(
        remote.rows['user_settings']!['user_settings']![
            'cloud_processing_enabled'],
        isTrue);
    final retained = await db.customSelect('''
      SELECT COUNT(*) AS n FROM planning_sync_outbox
      WHERE entity_type = 'settings' AND status = 'pending';
    ''').getSingle();
    expect(retained.read<int>('n'), 1,
        reason: 'a failed OFF acknowledgement must retain the durable intent');

    await db.customStatement('''
      UPDATE planning_sync_outbox SET next_retry_at = NULL
      WHERE entity_type = 'settings';
    ''');
    final result =
        await _push(db, queue, remote, revisionCasEnabled: true).push();

    expect(result.pushed, 1);
    expect(result.conflicts, 0, reason: 'settings never raise a conflict');
    final serverRow = remote.rows['user_settings']!['user_settings']!;
    expect(serverRow['ai_consent_granted'], isFalse);
    expect(serverRow['cloud_processing_enabled'], isFalse);
    expect(serverRow['theme'], 'newer-local-theme',
        reason: 'the field this device changed is last-writer-wins');
  });

  test('explicit ON survives the account timestamp advanced by its preceding OFF '
      'in legacy transport', () async {
    await db.customStatement('''
      UPDATE user_settings SET server_id = 'server-user_settings',
          server_updated_at = 'before-revoke', sync_status = 'synced',
          ai_consent_state = 'declined', cloud_consent_state = 'declined',
          cloud_processing_enabled = 0, ai_consent_granted = 0;
    ''');
    remote.rows['user_settings'] = {
      'user_settings': {
        ..._remoteSettingsRow(theme: 'other-device-theme'),
        'updated_at': 'after-revoke',
        'cloud_processing_enabled': false,
        'ai_consent_granted': false,
      },
    };
    remote.forceGuardConflict = true;
    final current = await settings.getSettings();
    final saved = await settings.saveSettings(current.copyWith(
        cloudConsentState: ConsentState.accepted,
        aiConsentState: ConsentState.accepted));
    final result = await _push(db, queue, remote).push();
    expect(result.pushed, 1);
    expect(result.conflicts, 0);
    expect(remote.lastPatch!.keys.toSet(),
        {'cloud_processing_enabled', 'ai_consent_granted', 'consent_version'});
    final row = remote.rows['user_settings']!['user_settings']!;
    expect(row['cloud_processing_enabled'], isTrue);
    expect(row['ai_consent_granted'], isTrue);
    expect(row['consent_version'], saved.consentVersion);
    expect(row['theme'], 'other-device-theme');
    expect(await queue.pendingItems(entityType: 'settings'), isEmpty);
  });

  test('explicit settings flush sends no unrelated planning rows', () async {
    await bind();
    final category = await DriftCategoryRepository(db, outboxQueue: queue)
        .createCategory(nameAr: 'Test', icon: 'test', color: '#000000',
            isIncome: false);
    final current = await settings.getSettings();
    await settings.saveSettings(current.copyWith(
        cloudConsentState: ConsentState.accepted));
    final result = await _push(db, queue, remote).pushSettings();
    expect(result.pushed, 1);
    expect(remote.rows['user_settings'], isNotEmpty);
    expect(remote.rows['user_categories'], isNull);
    final remaining = await queue.pendingItems(entityType: 'category');
    expect(remaining.map((item) => item.entityId), [category.id]);
  });

  test('field LWW sends ONLY the changed fields and never consent unless the '
      'user changed it', () async {
    await db.customStatement('''
      UPDATE user_settings
      SET server_id = 'server-user_settings',
          server_updated_at = 'base-ts', server_revision = 1,
          sync_status = 'synced', theme = 'local-light',
          ai_consent_granted = 1, cloud_processing_enabled = 1,
          ai_consent_state = 'accepted', cloud_consent_state = 'accepted';
    ''');
    // Another device changed language and (separately) switched consent OFF.
    remote.rows['user_settings'] = {
      'user_settings': {
        ..._remoteSettingsRow(theme: 'remote-dark', revision: 2),
        'language': 'xx',
        'cloud_processing_enabled': false,
        'ai_consent_granted': false,
      },
    };

    final current = await settings.getSettings();
    await settings.saveSettings(current.copyWith(theme: 'local-dark'));
    final r = await _push(db, queue, remote, revisionCasEnabled: true).push();

    expect(r.pushed, 1);
    expect(r.conflicts, 0);
    expect(remote.lastPatch!.keys.toSet(), {'theme'},
        reason: 'only the field this device changed leaves the device');
    final serverRow = remote.rows['user_settings']!['user_settings']!;
    expect(serverRow['theme'], 'local-dark');
    expect(serverRow['language'], 'xx', reason: 'the other device kept its field');
    expect(serverRow['cloud_processing_enabled'], isFalse,
        reason: 'consent is never overwritten by an ordinary settings write');
  });

  test('pull updates cloud columns but preserves device-local columns',
      () async {
    // Seed a local avatar_path + key ref that must survive a pull.
    await db.customStatement(
      "UPDATE user_settings SET avatar_path='/local/avatar.png', "
      "db_encryption_key_ref='device-key-ref', theme='light';",
    );
    remote.rows['user_settings'] = {
      'user_settings': {
        'id': 'server-user_settings',
        'local_id': 'user_settings',
        'display_name': 'يوسف',
        'phone_number': null, // server never had it → local value must survive
        'theme': 'dark',
        'currency': 'USD',
        'language': 'en',
        'country': 'US',
        'input_method': 'manual',
        'notifications_json': '{}',
        'privacy_mode_enabled': true,
        'ai_consent_granted': true,
        'cloud_processing_enabled': true,
        'updated_at': DateTime.utc(2026, 7, 5).toIso8601String(),
        'deleted_at': null,
      },
    };
    await db.customStatement(
      "UPDATE user_settings SET phone_number='0500000000';",
    );

    await _pull(db, queue, remote).pull();

    expect(await _col(db, 'theme'), 'dark'); // cloud updated
    expect(await _col(db, 'currency'), 'USD');
    // Profile restored from the server (the sign-out wipe survivor path).
    expect(await _col(db, 'display_name'), 'يوسف');
    // Server-null profile field keeps the local value instead of erasing it.
    expect(await _col(db, 'phone_number'), '0500000000');
    // Device-local preserved.
    expect(await _col(db, 'avatar_path'), '/local/avatar.png');
    expect(await _col(db, 'db_encryption_key_ref'), 'device-key-ref');
  });

  test(
      'WP-6: an explicit grant pushes its consent_version, the proof the '
      'server needs before a TRUE counts', () async {
    await bind();
    final s = await settings.getSettings();
    await settings.saveSettings(s.copyWith(
        cloudConsentState: ConsentState.accepted,
        aiConsentState: ConsentState.accepted));

    expect((await _push(db, queue, remote).push()).failed, 0);

    final serverRow = remote.rows['user_settings']!['user_settings']!;
    expect(serverRow['cloud_processing_enabled'], isTrue);
    expect(serverRow['ai_consent_granted'], isTrue);
    expect(serverRow['consent_version'], 1);
  });

  test(
      'WP-6: a server TRUE consent is never adopted as consent by a pull '
      '(state, effective grant and version all stay unset)', () async {
    remote.rows['user_settings'] = {
      'user_settings': {
        ..._remoteSettingsRow(
            aiConsentGranted: true, cloudProcessingEnabled: true),
        'consent_version': 7,
        'updated_at': DateTime.utc(2026, 7, 5).toIso8601String(),
      },
    };

    await _pull(db, queue, remote).pull();

    expect(await _col(db, 'theme'), 'remote-light', reason: 'the pull ran');
    final s = await settings.getSettings();
    expect(s.cloudConsentState, ConsentState.unset);
    expect(s.aiConsentState, ConsentState.unset);
    expect(s.cloudProcessingEnabled, isFalse);
    expect(s.aiConsentGranted, isFalse);
    expect(s.consentVersion, 0,
        reason: 'the server version is never copied into the authority');
    expect(await _intCol(db, 'cloud_processing_enabled'), 0);
    expect(await _intCol(db, 'ai_consent_granted'), 0);
  });

  test('multi-device: device A change pulls to device B as one settings row',
      () async {
    await bind();
    final s = await settings.getSettings();
    await settings.saveSettings(s.copyWith(theme: 'dark'));
    await _push(db, queue, remote).push();

    final dbB = await _openDb();
    addTearDown(() async => dbB.close());
    await _pull(dbB, _queue(dbB), remote).pull();

    expect(await _col(dbB, 'theme'), 'dark');
    // Still exactly one settings row (singleton, not duplicated).
    final count = await dbB
        .customSelect('SELECT COUNT(*) AS c FROM user_settings;')
        .getSingle();
    expect(count.read<int>('c'), 1);
  });

  test('local deliveries survive overlapping appends, an older settings pull and a stale save', () async {
    await bind();
    final old = await settings.getSettings();
    NotificationHistoryEntry entry(int id) => NotificationHistoryEntry(
      id: 'notif_$id',
      kind: 'test',
      title: 'Message $id',
      body: '',
      sentAt: DateTime.utc(2026, 11, id),
    );
    await Future.wait([
      settings.appendNotificationHistory(entry(1), isCurrent: () => true),
      settings.appendNotificationHistory(entry(2), isCurrent: () => true),
    ]);
    remote.rows['user_settings'] = {
      'user_settings': _remoteSettingsRow(theme: 'remote-light'),
    };
    await _pull(db, queue, remote).pull();
    final load = LoadNotificationPreferencesUseCase(settings);
    expect((await load()).inboxState.history.map((entry) => entry.id),
        ['notif_2', 'notif_1']);
    await settings.saveSettings(old.copyWith(theme: 'dark'));
    expect((await load()).inboxState.history.map((entry) => entry.id),
        ['notif_2', 'notif_1']);
  });

  test('local pending edit is not overwritten by pull (conflict guard)',
      () async {
    await bind();
    final s = await settings.getSettings();
    await settings.saveSettings(s.copyWith(theme: 'dark')); // sets pending
    // Server has a different value but local edit is still pending.
    remote.rows['user_settings'] = {
      'user_settings': {
        'id': 'server-user_settings',
        'local_id': 'user_settings',
        'theme': 'light',
        'currency': 'SAR',
        'language': 'ar',
        'country': 'SA',
        'input_method': 'auto',
        'notifications_json': '{}',
        'privacy_mode_enabled': false,
        'ai_consent_granted': true,
        'cloud_processing_enabled': true,
        'updated_at': DateTime.utc(2026, 7, 5).toIso8601String(),
        'deleted_at': null,
      },
    };

    final result = await _pull(db, queue, remote).pull();

    expect(result.conflicts, greaterThanOrEqualTo(1));
    expect(await _col(db, 'theme'), 'dark'); // local edit preserved
  });

  test(
      'unbound singleton (post-wipe defaults) is NEVER pushed as an update — '
      'cloud settings cannot be clobbered before the first pull', () async {
    // No bind(): server_id is NULL, as right after a sign-out wipe. Automatic
    // writers (notification history) save settings within seconds of sign-in.
    final s = await settings.getSettings();
    await settings.saveSettings(s.copyWith(country: 'SA', currency: 'SAR'));

    final result = await _push(db, queue, remote).push();
    expect(result.pushed, 0, reason: 'nothing may be queued while unbound');
    expect(remote.rows['user_settings'], isNull,
        reason: 'the reseeded defaults must not overwrite the cloud row');
  });

  // ── Audit NEW-H-3 — pre-bind revocation must be CONSENT-ONLY ──────────────

  test(
      'NEW-H-3: pre-bind revocation reaches the server OFF without touching '
      'any other remote settings/profile field', () async {
    // The production-risk state: the user's REAL cloud row exists (created by
    // another device) with non-default values …
    remote.rows['user_settings'] = {
      'user_settings': _remoteSettingsRow(theme: 'remote-light'),
    };
    // … while THIS device is fresh/wiped: local defaults, no server_id, and no
    // pull has run yet. The user revokes cloud consent immediately.
    final s = await settings.getSettings();
    await settings.saveSettings(s.copyWith(
      aiConsentState: ConsentState.declined,
      cloudConsentState: ConsentState.declined,
    ));

    // Push runs BEFORE the first pull (the engine's real ordering).
    final result = await _push(db, queue, remote).push();
    expect(result.failed, 0);

    final serverRow = remote.rows['user_settings']!['user_settings']!;
    // The revocation landed …
    expect(serverRow['ai_consent_granted'], isFalse);
    expect(serverRow['cloud_processing_enabled'], isFalse);
    // … and EVERY unrelated remote field is untouched. Against the pre-fix
    // full-row CREATE this fails: the merge-upsert wrote this device's
    // defaults/nulls over the real values (display_name → null, currency →
    // SAR, country → SA, theme → default).
    expect(serverRow['display_name'], 'Remote User');
    expect(serverRow['phone_number'], isNull);
    expect(serverRow['currency'], 'USD');
    expect(serverRow['country'], 'US');
    expect(serverRow['language'], 'en');
    expect(serverRow['theme'], 'remote-light');
    expect(serverRow['input_method'], 'manual');
    expect(serverRow['notifications_json'], '{}');
    expect(serverRow['privacy_mode_enabled'], isTrue);
  });

  test(
      'NEW-H-3: the consent-only push does NOT bind the row — the pre-bind '
      'guard keeps blocking automatic default writes afterwards', () async {
    remote.rows['user_settings'] = {
      'user_settings': _remoteSettingsRow(theme: 'remote-light'),
    };
    final s = await settings.getSettings();
    await settings.saveSettings(s.copyWith(
      aiConsentState: ConsentState.declined,
      cloudConsentState: ConsentState.declined,
    ));
    await _push(db, queue, remote).push();

    // Still unbound: binding belongs to the genuine pull merge, not to the
    // narrow consent write (binding here would lift the guard and let the next
    // automatic update push this device's defaults over the cloud row).
    expect(await _col(db, 'server_id'), isNull);

    // An automatic (non-consent) settings write while still unbound …
    final after = await settings.getSettings();
    await settings.saveSettings(after.copyWith(country: 'SA', currency: 'SAR'));
    final second = await _push(db, queue, remote).push();
    expect(second.pushed, 0,
        reason: 'the pre-bind guard must still block non-consent updates');
    final serverRow = remote.rows['user_settings']!['user_settings']!;
    expect(serverRow['currency'], 'USD',
        reason: 'defaults must never clobber the cloud row post-consent-push');
    expect(serverRow['country'], 'US');
  });

  test(
      'NEW-H-3: pre-bind revocation with NO remote row creates a minimal '
      'consent authority row (server defaults stay authoritative)', () async {
    final s = await settings.getSettings();
    await settings.saveSettings(s.copyWith(
      aiConsentState: ConsentState.declined,
      cloudConsentState: ConsentState.declined,
    ));

    final result = await _push(db, queue, remote).push();
    expect(result.failed, 0);

    final serverRow = remote.rows['user_settings']!['user_settings']!;
    expect(serverRow['ai_consent_granted'], isFalse);
    expect(serverRow['cloud_processing_enabled'], isFalse);
    // The insert carried ONLY the consent authority — no client default may
    // masquerade as server state for a brand-new row.
    expect(serverRow.containsKey('display_name'), isFalse);
    expect(serverRow.containsKey('theme'), isFalse);
    expect(serverRow.containsKey('currency'), isFalse);
    expect(serverRow.containsKey('country'), isFalse);
    expect(serverRow.containsKey('language'), isFalse);
    expect(serverRow.containsKey('notifications_json'), isFalse);
    expect(serverRow.containsKey('privacy_mode_enabled'), isFalse);
  });

  test('NEW-H-3: repeating the same pre-bind revocation stays idempotent',
      () async {
    remote.rows['user_settings'] = {
      'user_settings': _remoteSettingsRow(theme: 'remote-light'),
    };
    final s = await settings.getSettings();
    await settings.saveSettings(s.copyWith(
      aiConsentState: ConsentState.declined,
      cloudConsentState: ConsentState.declined,
    ));
    await _push(db, queue, remote).push();
    // The same intent again (e.g. a retried save after restart).
    final again = await settings.getSettings();
    await settings.saveSettings(again.copyWith(
      aiConsentState: ConsentState.declined,
      cloudConsentState: ConsentState.declined,
    ));
    await _push(db, queue, remote).push();

    final serverRow = remote.rows['user_settings']!['user_settings']!;
    expect(serverRow['ai_consent_granted'], isFalse);
    expect(serverRow['cloud_processing_enabled'], isFalse);
    expect(serverRow['display_name'], 'Remote User');
    expect(serverRow['currency'], 'USD');
    expect(serverRow['theme'], 'remote-light');
  });

  // ── Audit NEW-H-4 — registration must not CREATE from an unproven pull ────

  /// The engine's exact post-pull sequence (planning_sync_engine.dart): derive
  /// the settings authority from the REAL pull result, register, then push.
  /// The wiring itself is pinned by the source-scrape contract in
  /// planning_startup_registration_service_test.dart.
  Future<void> engineTail(_FakeRemote r) async {
    var settingsPullCompleted = false;
    try {
      final result = await _pull(db, queue, r).pull();
      settingsPullCompleted = result.completedEntities
          .contains(PlanningOutboxQueue.settingsEntityType);
    } catch (_) {}
    final registration = PlanningStartupRegistrationService(
      db: db,
      queue: queue,
      isEnabled: (_) => true,
    );
    await registration.registerMissingRows(
        settingsPullCompleted: settingsPullCompleted);
    await _push(db, queue, remote).push();
  }

  for (final legacyStatus in [null, 'conflict', 'synced']) {
    test(
        switch (legacyStatus) {
          'conflict' => 'first settings restore retries an unbound conflict',
          'synced' => 'first settings restore repairs a premature binding',
          _ => 'first settings restore follows an explicit Cloud and AI grant',
        },
        () async {
      final initial = await settings.getSettings();
      final language = initial.language == 'en' ? 'ar' : 'en';
      const phone = '+15550100123';
      remote.rows['user_settings'] = {
        'user_settings': {
          ..._remoteSettingsRow(),
          'phone_number': phone,
          'language': language,
        },
      };
      final granted = await settings.saveSettings(initial.copyWith(
        cloudConsentState: ConsentState.accepted,
        aiConsentState: ConsentState.accepted,
      ));
      final pushed = await _push(db, queue, remote).push();
      expect(pushed.pushed, 1);
      expect(await _col(db, 'server_id'), isNull);
      if (legacyStatus != null) {
        await db.customStatement(
            "UPDATE user_settings SET sync_status = '$legacyStatus';");
        if (legacyStatus == 'synced') await bind();
        await writeSyncCursor(
          db,
          'planning_settings',
          SyncCursor.fromServerRow(remote.rows['user_settings']!['user_settings']!),
        );
      }

      await engineTail(remote);

      final restored = await settings.getSettings();
      expect(await _col(db, 'server_id'), 'server-user_settings');
      expect(remote.settingsFetchAfter?.id, isEmpty);
      expect(restored.phoneNumber, phone);
      expect(restored.country, 'US');
      expect(restored.currency, 'USD');
      expect(restored.language, language);
      expect(restored.cloudConsentState, ConsentState.accepted);
      expect(restored.aiConsentState, ConsentState.accepted);
      expect(restored.consentVersion, granted.consentVersion);
      final serverRow = remote.rows['user_settings']!['user_settings']!;
      expect(serverRow['phone_number'], phone);
      expect(serverRow['country'], 'US');
      expect(serverRow['currency'], 'USD');
      expect(serverRow['language'], language);

      await engineTail(remote);
      expect(remote.settingsFetchAfter?.id, 'server-user_settings',
          reason: 'subsequent syncs use the incremental cursor again');
    });
  }

  test(
      'NEW-H-4: a FAILED settings pull never lets registration clobber the '
      'existing remote row with fresh-device defaults', () async {
    // The user's REAL cloud row exists …
    remote.rows['user_settings'] = {
      'user_settings': _remoteSettingsRow(theme: 'remote-light'),
    };
    // … this device is wiped/unbound, and the settings fetch FAILS (transport).
    remote.failFetchTable = 'user_settings';

    await engineTail(remote);

    final settingsQueued = await db.customSelect('''
      SELECT COUNT(*) AS n FROM planning_sync_outbox
      WHERE entity_type = 'settings';
    ''').getSingle();
    expect(settingsQueued.read<int>('n'), 0,
        reason: 'no durable poisoned CREATE may exist after a failed pull');
    final serverRow = remote.rows['user_settings']!['user_settings']!;
    expect(serverRow['display_name'], 'Remote User');
    expect(serverRow['phone_number'], isNull);
    expect(serverRow['currency'], 'USD');
    expect(serverRow['country'], 'US');
    expect(serverRow['theme'], 'remote-light');
    expect(serverRow['ai_consent_granted'], isTrue,
        reason: 'nothing at all may be written from the unproven state');

    // Next cycle: the pull succeeds → the remote singleton binds and wins;
    // registration then finds a bound row and still creates nothing.
    remote.failFetchTable = null;
    await engineTail(remote);
    expect(await _col(db, 'server_id'), 'server-user_settings');
    final afterRecovery = await db.customSelect('''
      SELECT COUNT(*) AS n FROM planning_sync_outbox
      WHERE entity_type = 'settings' AND operation = 'create';
    ''').getSingle();
    expect(afterRecovery.read<int>('n'), 0);
    expect(remote.rows['user_settings']!['user_settings']!['display_name'],
        'Remote User');
  });

  test(
      'NEW-H-4: a COMPLETED pull that confirms remote absence still bootstraps '
      'the genuinely new user with the initial full row', () async {
    // No remote row anywhere; the pull completes and proves absence.
    await engineTail(remote);

    final serverRow = remote.rows['user_settings']?['user_settings'];
    expect(serverRow, isNotNull,
        reason: 'CONFIRMED_ABSENT must still allow the initial bootstrap');
    expect(serverRow!['cloud_processing_enabled'], isNotNull);
    expect(await _col(db, 'server_id'), isNotNull,
        reason: 'the legitimate bootstrap binds the row');
  });

  test(
      'a pre-bind settings edit cannot block registration after remote absence '
      'is confirmed', () async {
    final before = await settings.getSettings();
    await settings.saveSettings(before.copyWith(
      language: 'ar', currency: 'EGP', country: 'EG', displayName: 'New User',
    ));
    final held = await db.customSelect(
      "SELECT id, status, failure_class FROM planning_sync_outbox "
      "WHERE entity_type = 'settings';",
    ).getSingle();
    expect(held.read<String>('status'), 'parked');
    expect(held.read<String>('failure_class'), 'dependency_wait');

    await engineTail(remote);

    final serverRow = remote.rows['user_settings']?['user_settings'];
    expect(serverRow, isNotNull,
        reason: 'the held edit must become the initial CREATE once the pull '
            'confirms there is no remote settings row');
    expect(serverRow!['language'], 'ar');
    expect(serverRow['currency'], 'EGP');
    expect(serverRow['display_name'], 'New User');
    expect(await _col(db, 'server_id'), 'server-user_settings');
    final remaining = await db.customSelect(
      "SELECT COUNT(*) AS n FROM planning_sync_outbox "
      "WHERE entity_type = 'settings';",
    ).getSingle();
    expect(remaining.read<int>('n'), 0);
  });

  for (final blocker in [
    'other owner', 'missing owner', 'in flight', 'consent only', 'different hold',
    'ambiguous rows',
  ]) {
    test('registration cannot promote a settings edit with $blocker', () async {
      final before = await settings.getSettings();
      await settings.saveSettings(before.copyWith(currency: 'EGP'));
      switch (blocker) {
        case 'other owner':
          await db.customStatement(
              "UPDATE planning_sync_outbox SET owner_uid = 'other-user';");
        case 'missing owner':
          await db.customStatement(
              'UPDATE planning_sync_outbox SET owner_uid = NULL;');
        case 'in flight':
          await db.customStatement(
              'UPDATE planning_sync_outbox SET in_flight_seq = op_seq;');
        case 'consent only':
          final held = await db.customSelect(
              'SELECT payload_json FROM planning_sync_outbox;').getSingle();
          final payload = jsonDecode(held.read<String>('payload_json')) as Map;
          payload['consent_only'] = true;
          await db.customStatement(
              'UPDATE planning_sync_outbox SET payload_json = ?;',
              [jsonEncode(payload)]);
        case 'different hold':
          await db.customStatement(
              "UPDATE planning_sync_outbox SET failure_class = 'auth_required';");
        case 'ambiguous rows':
          final held = await db.customSelect(
              'SELECT * FROM planning_sync_outbox;').getSingle();
          await db.customStatement(
              'INSERT INTO planning_sync_outbox(id, entity_type, entity_id, '
              'operation, payload_json, attempt_count, status, failure_class, '
              'created_at, updated_at, op_seq, owner_uid, operation_id) '
              "VALUES ('second-held', 'settings', ?, 'update', ?, 0, 'parked', "
              "'dependency_wait', ?, ?, 1, 'user-1', ?);", [
                held.read<String>('entity_id'), held.read<String>('payload_json'),
                held.read<String>('created_at'), held.read<String>('updated_at'),
                '00000000-0000-4000-8000-000000000001',
              ]);
      }
      final beforeRows = (await db.customSelect(
          'SELECT * FROM planning_sync_outbox ORDER BY id;').get())
          .map((r) => r.data).toList();
      await PlanningStartupRegistrationService(
        db: db, queue: queue, isEnabled: (_) => true,
      ).registerMissingRows(settingsPullCompleted: true);
      final afterRows = (await db.customSelect(
          'SELECT * FROM planning_sync_outbox ORDER BY id;').get())
          .map((r) => r.data).toList();
      expect(afterRows, beforeRows,
          reason: 'registration cannot release or rewrite unrelated work');
      expect(await _col(db, 'server_id'), isNull);
    });
  }

  test(
      'a pre-bind settings edit stays held when the settings pull fails and '
      'restores the existing remote preferences on retry', () async {
    remote.rows['user_settings'] = {
      'user_settings': _remoteSettingsRow(theme: 'remote-light'),
    };
    remote.failFetchTable = 'user_settings';
    final before = await settings.getSettings();
    await settings.saveSettings(before.copyWith(currency: 'EGP', country: 'EG'));

    await engineTail(remote);

    expect(await _col(db, 'server_id'), isNull);
    expect(remote.rows['user_settings']!['user_settings']!['currency'], 'USD');
    final held = await db.customSelect(
      "SELECT status FROM planning_sync_outbox WHERE entity_type = 'settings';",
    ).getSingle();
    expect(held.read<String>('status'), 'parked');

    remote.failFetchTable = null;
    await engineTail(remote);

    expect(await _col(db, 'server_id'), 'server-user_settings');
    expect(await _col(db, 'currency'), 'USD');
    expect(remote.rows['user_settings']!['user_settings']!['currency'], 'USD');
  });

  test(
      'NEW-H-4: an explicit consent OFF still propagates narrowly while the '
      'settings pull keeps failing', () async {
    remote.rows['user_settings'] = {
      'user_settings': _remoteSettingsRow(theme: 'remote-light'),
    };
    remote.failFetchTable = 'user_settings';
    final s = await settings.getSettings();
    await settings.saveSettings(s.copyWith(
      aiConsentState: ConsentState.declined,
      cloudConsentState: ConsentState.declined,
    ));

    await engineTail(remote);

    final serverRow = remote.rows['user_settings']!['user_settings']!;
    expect(serverRow['ai_consent_granted'], isFalse,
        reason: 'a failed pull must not block the revocation');
    expect(serverRow['cloud_processing_enabled'], isFalse);
    expect(serverRow['display_name'], 'Remote User',
        reason: 'the revocation stays consent-only even alongside NEW-H-4');
    expect(serverRow['currency'], 'USD');
    expect(serverRow['theme'], 'remote-light');
  });

  test(
      'NEW-H-3: a pre-bind ON toggled back OFF ends OFF on the server — a '
      'stale ON cannot outlive the newer revocation', () async {
    remote.rows['user_settings'] = {
      'user_settings': _remoteSettingsRow(
          theme: 'remote-light',
          aiConsentGranted: false,
          cloudProcessingEnabled: false),
    };
    final s = await settings.getSettings();
    await settings.saveSettings(s.copyWith(
      aiConsentState: ConsentState.accepted,
      cloudConsentState: ConsentState.accepted,
    ));
    final on = await settings.getSettings();
    await settings.saveSettings(on.copyWith(
      aiConsentState: ConsentState.declined,
      cloudConsentState: ConsentState.declined,
    ));

    await _push(db, queue, remote).push();
    final serverRow = remote.rows['user_settings']!['user_settings']!;
    expect(serverRow['ai_consent_granted'], isFalse);
    expect(serverRow['cloud_processing_enabled'], isFalse);
    expect(serverRow['display_name'], 'Remote User',
        reason: 'the consent path must stay narrow in every toggle sequence');
  });
}
