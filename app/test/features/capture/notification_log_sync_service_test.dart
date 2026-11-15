import 'dart:io';
import 'package:flutter/services.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/account_fence_store.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'ledger_admission_fixture.dart';
import '../../core/session/f2_fixture.dart';
import 'dart:convert';
import 'dart:async';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/features/announcements/announcements_screen.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/capture/services/notification_log_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/capture/services/notification_log_ownership.dart';
import 'package:money_companion/features/capture/services/notification_log_sync_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

SupabaseClient? _admittedClient;
MockClient? _forwardTo;
SupabaseClient _client(MockClient client) {
  _forwardTo = client;
  final admitted = _admittedClient!;
  expect(admitted.auth.currentUser, isNotNull);
  return admitted;
}

Future<http.Response> _forward(http.Request request) async {
  final copy = http.Request(request.method, request.url)
    ..headers.addAll(request.headers)..bodyBytes = request.bodyBytes;
  return http.Response.fromStream(await _forwardTo!.send(copy));
}

http.Response _json(Object body, http.BaseRequest request, {int status = 200}) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
    request: request,
  );
}

void main() {
  _notificationNativeImportStageA();
  _notificationInternalStageA();
  _notificationFiniteControls();
  _notificationMoreControls();
  group('original notification upload controls', () {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late NotificationLogService logService;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    logService = NotificationLogService(db, readOrigin: () async =>
      NotificationLogOrigin('qa-user', 'generation-1', isCurrent: () => true));
  });

  tearDown(() async {
    await db.close();
  });

  void uploadTest(String name, Future<void> Function() body) {
    group('admitted upload', () {
      late LedgerAdmissionFixture admission;
      setUp(() async {
        await db.close();
        final uid = name.startsWith('A, legacy') ? 'B' : 'qa-user';
        admission = await LedgerAdmissionFixture.open(uid);
        db = admission.database;
        logService = NotificationLogService(db, readOrigin: () async =>
            NotificationLogOrigin('qa-user', 'generation-1', isCurrent: () => true));
        _admittedClient = admission.ownClient(SupabaseClient('https://example.supabase.co', 'anon',
            authOptions: const AuthClientOptions(autoRefreshToken: false), httpClient: MockClient(_forward)));
        await F2Fixture.recoverSession_(_admittedClient!, uid);
        expect(_admittedClient!.auth.currentUser?.id, uid);
        expect(admission.fixture.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
      });
      tearDown(() async {
        try { await admission.finish(); }
        finally { _admittedClient = null; _forwardTo = null; }
      });
      test(name, body);
    });
  }

  void nativeImportTest(String name, Future<void> Function() body) {
    group('admitted native component', () {
      late LedgerAdmissionFixture admission;
      setUp(() async {
        await db.close();
        admission = await LedgerAdmissionFixture.open('B');
        db = admission.database;
      });
      tearDown(() async => admission.finish());
      test(name, body);
    });
  }

  uploadTest('A, legacy and old generation rows remain unsynced under B', () async {
    final id = await logService.recordCreated(channel: 'local_ios', notificationType: 'test');
    final unbound = NotificationLogService(db, readOrigin: () async => null);
    await unbound.recordCreated(channel: 'local_ios', notificationType: 'test');
    var requests = 0;
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'B', db: db, getAuthUserId: () async => 'B',
      readOrigin: () async => NotificationLogOrigin('B', 'generation-2', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(MockClient((r) async { requests++; return _json(<Object>[], r); })),
      getInstallId: () async => 'install');
    await sync.debugSyncBatch('B');
    expect(requests, 0);
    final rows = await db.customSelect('SELECT synced_at, sync_attempt_count FROM notification_log_events').get();
    expect(rows, hasLength(2));
    expect(rows.every((r) => r.readNullable<String>('synced_at') == null && r.read<int>('sync_attempt_count') == 0), isTrue);
    expect(id, isNotEmpty);
  });

  uploadTest('retained legacy queue cannot starve current scoped events', () async {
    final unbound = NotificationLogService(db, readOrigin: () async => null);
    for (var i = 0; i < 51; i++) {
      await unbound.recordCreated(channel: 'local_ios', notificationType: 'legacy');
    }
    final id = await logService.recordCreated(channel: 'local_ios', notificationType: 'current');
    final requests = <Map<String, dynamic>>[];
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db, getAuthUserId: () async => 'qa-user',
      readOrigin: () async => NotificationLogOrigin('qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(MockClient((r) async {
        requests.add(jsonDecode(r.body) as Map<String, dynamic>);
        return _json(<Object>[], r);
      })), getInstallId: () async => 'install');
    await sync.debugSyncBatch('qa-user');
    expect(requests, hasLength(1));
    expect(requests.single['id'], id);
    final retained = await db.customSelect('SELECT 1 FROM notification_log_events WHERE synced_at IS NULL').get();
    expect(retained, hasLength(51));
  });

  uploadTest('cloud OFF blocks upload and retains current event', () async {
    await logService.recordCreated(channel: 'local_ios', notificationType: 'test');
    var requests = 0;
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db, getAuthUserId: () async => 'qa-user',
      readOrigin: () async => NotificationLogOrigin('qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => false,
      getClient: () => _client(MockClient((r) async { requests++; return _json(<Object>[], r); })),
      getInstallId: () async => 'install');
    await sync.debugSyncBatch('qa-user');
    expect(requests, 0);
    final row = await db.customSelect('SELECT synced_at FROM notification_log_events').getSingle();
    expect(row.readNullable<String>('synced_at'), isNull);
  });

  uploadTest('revoked operation after install await has no upload or acknowledgement', () async {
    await logService.recordCreated(channel: 'local_ios', notificationType: 'test');
    var current = true;
    var requests = 0;
    final install = Completer<String>();
    final entered = Completer<void>();
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db, getAuthUserId: () async => 'qa-user',
      readOrigin: () async => NotificationLogOrigin('qa-user', 'generation-1', isCurrent: () => current),
      mayEgress: () async => true,
      getClient: () => _client(MockClient((r) async { requests++; return _json(<Object>[], r); })),
      getInstallId: () { entered.complete(); return install.future; });
    final work = sync.debugSyncBatch('qa-user');
    await entered.future;
    current = false;
    install.complete('install');
    await work;
    expect(requests, 0);
    final row = await db.customSelect('SELECT synced_at, sync_attempt_count FROM notification_log_events').getSingle();
    expect(row.readNullable<String>('synced_at'), isNull);
    expect(row.read<int>('sync_attempt_count'), 0);
  });

  uploadTest('revocation during upload prevents acknowledgement and retry mutation', () async {
    await logService.recordCreated(channel: 'local_ios', notificationType: 'test');
    var current = true;
    var requests = 0;
    final pending = Completer<http.Response>();
    final entered = Completer<void>();
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db, getAuthUserId: () async => 'qa-user',
      readOrigin: () async => NotificationLogOrigin('qa-user', 'generation-1', isCurrent: () => current),
      mayEgress: () async => true,
      getClient: () => _client(MockClient((r) { requests++; entered.complete(); return pending.future; })),
      getInstallId: () async => 'install');
    final work = sync.debugSyncBatch('qa-user');
    await entered.future;
    current = false;
    pending.complete(http.Response('[]', 200, headers: {'content-type': 'application/json'}));
    await work;
    expect(requests, 1);
    final row = await db.customSelect('SELECT synced_at, sync_attempt_count FROM notification_log_events').getSingle();
    expect(row.readNullable<String>('synced_at'), isNull);
    expect(row.read<int>('sync_attempt_count'), 0);
  });

  for (final changed in ['generation', 'SDK uid']) {
    uploadTest('$changed changes during consent await reject upload without mutating the row', () async {
      await logService.recordCreated(channel: 'local_ios', notificationType: 'test');
      var generation = 'generation-1';
      var sdkUid = 'qa-user';
      var requests = 0;
      final sync = NotificationLogSyncService(getCurrentAuthUserId: () => sdkUid, db: db,
        readOrigin: () async => NotificationLogOrigin('qa-user', 'generation-1',
          isCurrent: () => true, validate: () async => generation == 'generation-1'),
        getAuthUserId: () async => sdkUid,
        mayEgress: () async {
          if (changed == 'generation') generation = 'generation-2';
          if (changed == 'SDK uid') sdkUid = 'B';
          return true;
        },
        getClient: () => _client(MockClient((r) async { requests++; return _json(<Object>[], r); })),
        getInstallId: () async => 'install');
      await sync.debugSyncBatch('qa-user');
      expect(requests, 0);
      final row = await db.customSelect('SELECT synced_at, sync_attempt_count FROM notification_log_events').getSingle();
      expect(row.readNullable<String>('synced_at'), isNull);
      expect(row.read<int>('sync_attempt_count'), 0);
    });
  }

  uploadTest('SDK switch while origin validation is paused rejects final network effect', () async {
    await logService.recordCreated(channel: 'local_ios', notificationType: 'test');
    var sdkUid = 'qa-user';
    var validations = 0;
    var requests = 0;
    final entered = Completer<void>();
    final release = Completer<bool>();
    final sync = NotificationLogSyncService(db: db,
      getCurrentAuthUserId: () => sdkUid,
      getAuthUserId: () async => sdkUid,
      readOrigin: () async => NotificationLogOrigin('qa-user', 'generation-1',
        isCurrent: () => true, validate: () async {
          validations++;
          if (validations == 4) { entered.complete(); return release.future; }
          return true;
        }),
      mayEgress: () async => true,
      getClient: () => _client(MockClient((r) async { requests++; return _json(<Object>[], r); })),
      getInstallId: () async => 'install');
    final work = sync.debugSyncBatch('qa-user');
    await entered.future;
    sdkUid = 'B';
    release.complete(true);
    await work;
    expect(requests, 0);
    final row = await db.customSelect('SELECT synced_at, sync_attempt_count FROM notification_log_events').getSingle();
    expect(row.readNullable<String>('synced_at'), isNull);
    expect(row.read<int>('sync_attempt_count'), 0);
  });

  nativeImportTest('local history imports only sent Shortcut receipts for this owner without cloud', () async {
    NativeNotificationLogEvent event(int id, String type, String uid) =>
        NativeNotificationLogEvent(
          eventId: '00000000-0000-4000-8000-00000000000$id',
          notificationLogId: 'attempt-$id',
          eventType: type,
          channel: 'ios_shortcut_local',
          notificationType: 'new_transaction',
          originKind: 'native',
          ownerUid: uid,
          ownerGeneration: 2,
        );
    final sync = NotificationLogSyncService(
      db: db,
      readOrigin: () async => NotificationLogOrigin('B', 'local-B',
          nativeGeneration: 2, isCurrent: () => true),
      mayEgress: () async => false,
      getClient: () => throw StateError('local history used the network'),
      consumeNativeEvents: (_, __) async => [
        event(1, 'sent', 'B'),
        event(2, 'failed', 'B'),
        event(3, 'sent', 'A'),
      ],
      acknowledgeNativeEvent: (_) async => true,
    );
    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
    ]);
    final subscription = container.listen(shortcutHistoryProvider, (_, __) {});
    try {
      expect(await container.read(shortcutHistoryProvider.future), isEmpty);
      await sync.importNativeHistory();
      await sync.importNativeHistory();
      container.invalidate(shortcutHistoryProvider);
      final history = await container.read(shortcutHistoryProvider.future);
      expect(history.map((entry) => entry.id), ['shortcut:attempt-1']);
      expect(history.single.kind, 'new_transaction');
    } finally {
      subscription.close();
      container.dispose();
    }
  });

  nativeImportTest('native retrieval retry persists once and only acknowledges verified origin', () async {
    const event = NativeNotificationLogEvent(eventId: '00000000-0000-4000-8000-000000000001',
      notificationLogId: 'native-attempt', eventType: 'created', channel: 'ios_shortcut_local',
      notificationType: 'test', originKind: 'native', ownerUid: 'B', ownerGeneration: 2);
    var acknowledgements = 0;
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db,
      readOrigin: () async => NotificationLogOrigin('B', 'local-B', nativeGeneration: 2, isCurrent: () => true),
      consumeNativeEvents: (_, __) async => [event],
      acknowledgeNativeEvent: (e) async { expect(e.eventId, event.eventId); acknowledgements++; return false; });
    await sync.debugImportNativeEvents();
    await sync.debugImportNativeEvents();
    expect(await db.customSelect('SELECT 1 FROM notification_log_events').get(), hasLength(1));
    expect(acknowledgements, 2);
    await db.customUpdate("UPDATE notification_log_events SET payload_json = '{}' WHERE id = ?",
      variables: [Variable.withString('native:${event.eventId}')]);
    await sync.debugImportNativeEvents();
    expect(acknowledgements, 2, reason: 'conflicting persistence is never ownership proof');
  });

  nativeImportTest('persistence failure retains native event without acknowledging it', () async {
    await db.customStatement('DROP TABLE notification_log_events');
    var acknowledged = false;
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db,
      readOrigin: () async => NotificationLogOrigin('B', 'local-B', nativeGeneration: 2, isCurrent: () => true),
      consumeNativeEvents: (_, __) async => [const NativeNotificationLogEvent(
        eventId: '00000000-0000-4000-8000-000000000001', notificationLogId: 'native-attempt',
        eventType: 'created', channel: 'ios_shortcut_local', notificationType: 'test',
        originKind: 'native', ownerUid: 'B', ownerGeneration: 2)],
      acknowledgeNativeEvent: (_) async { acknowledged = true; return true; });
    await sync.debugImportNativeEvents();
    expect(acknowledged, isFalse);
  });

  nativeImportTest('revocation after persistence retains native event without acknowledgement', () async {
    var current = true;
    var validations = 0;
    var acknowledged = false;
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db,
      readOrigin: () async => NotificationLogOrigin('B', 'local-B', nativeGeneration: 2,
        isCurrent: () => current, validate: () async {
          validations++;
          // Entry, response, per-event, then the first post-insert boundary.
          if (validations == 4) current = false;
          return current;
        }),
      consumeNativeEvents: (_, __) async => [const NativeNotificationLogEvent(
        eventId: '00000000-0000-4000-8000-000000000001', notificationLogId: 'native-attempt',
        eventType: 'created', channel: 'ios_shortcut_local', notificationType: 'test',
        originKind: 'native', ownerUid: 'B', ownerGeneration: 2)],
      acknowledgeNativeEvent: (_) async { acknowledged = true; return true; });
    await sync.debugImportNativeEvents();
    expect(await db.customSelect('SELECT 1 FROM notification_log_events').get(), hasLength(1));
    expect(acknowledged, isFalse);
  });

  nativeImportTest('native importer rejects unbound, A and old B generation without relabeling', () async {
    NativeNotificationLogEvent event(String id, String? uid, int? generation) =>
      NativeNotificationLogEvent(eventId: '00000000-0000-4000-8000-000000000001', notificationLogId: id, eventType: 'created',
        channel: 'ios_shortcut_local', notificationType: 'test',
        originKind: uid == null ? null : 'native', ownerUid: uid, ownerGeneration: generation);
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db, getAuthUserId: () async => 'qa-user',
      readOrigin: () async => NotificationLogOrigin('B', 'local-B', nativeGeneration: 2, isCurrent: () => true),
      consumeNativeEvents: (uid, generation) async {
        expect(uid, 'B'); expect(generation, 2);
        return [event('unbound', null, null), event('A', 'A', 1), event('old-B', 'B', 1), event('current-B', 'B', 2)];
      });
    await sync.debugImportNativeEvents();
    final rows = await db.customSelect('SELECT notification_log_id, payload_json FROM notification_log_events').get();
    expect(rows, hasLength(1));
    expect(rows.single.read<String>('notification_log_id'), 'current-B');
    expect((jsonDecode(rows.single.read<String>('payload_json')) as Map)[NotificationLogOrigin.payloadKey],
      {'kind': 'native', 'uid': 'B', 'generation': 2});
  });

  nativeImportTest('native import continuation revoked during consume performs no database insert', () async {
    var current = true;
    final pending = Completer<List<NativeNotificationLogEvent>>();
    final entered = Completer<void>();
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db, getAuthUserId: () async => 'qa-user',
      readOrigin: () async => NotificationLogOrigin('B', 'local-B', nativeGeneration: 2, isCurrent: () => current),
      consumeNativeEvents: (_, __) { entered.complete(); return pending.future; });
    final work = sync.debugImportNativeEvents();
    try {
      await entered.future;
      current = false;
      pending.complete([const NativeNotificationLogEvent(eventId: '00000000-0000-4000-8000-000000000001', notificationLogId: 'B', eventType: 'created',
        channel: 'ios_shortcut_local', notificationType: 'test', originKind: 'native', ownerUid: 'B', ownerGeneration: 2)]);
      await work;
      expect(await db.customSelect('SELECT 1 FROM notification_log_events').get(), isEmpty);
    } finally {
      if (!pending.isCompleted) pending.complete(const []);
      await work;
    }
  });

  uploadTest('uploads each event as an upsert keyed by the same notification_log_id',
      () async {
    final logId = await logService.recordCreated(
      channel: NotificationLogChannel.localIos,
      notificationType: 'budget_warning',
      relatedEntityType: 'budget',
      relatedEntityId: 'budget-1',
    );
    await logService.recordSent(
      logId: logId,
      channel: NotificationLogChannel.localIos,
      notificationType: 'budget_warning',
    );

    final upserts = <Map<String, dynamic>>[];
    final http = MockClient((request) async {
      expect(request.method, 'POST');
      final decoded = jsonDecode(request.body);
      upserts.add(Map<String, dynamic>.from(decoded as Map));
      return _json(<Object>[], request);
    });
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );

    await sync.debugSyncBatch('qa-user');

    expect(upserts, hasLength(2));
    expect(upserts[0]['id'], logId);
    expect(upserts[0]['status'], 'pending');
    expect(upserts[1]['id'], logId);
    expect(upserts[1]['status'], 'sent');
    // Every unsynced row was marked synced after a successful upload.
    final remaining = await db
        .customSelect(
          'SELECT COUNT(*) AS total FROM notification_log_events WHERE synced_at IS NULL;',
        )
        .getSingle();
    expect(remaining.read<int>('total'), 0);
  });

  uploadTest('same-tick events still upload in insertion order', () async {
    // The ordering above used `id ASC` as its tie-breaker, and `id` is a
    // RANDOM 16-byte value. Two events for one notification normally share a
    // `created_at` tick — `recordCreated` is followed by `recordSent`
    // microseconds later — so the upload order was decided at random, and the
    // 'created after sent' regression this suite exists to prevent happened
    // roughly half the time. It surfaced as a flake: this file and
    // `local_notification_service_tracking_test` failed on alternate full-suite
    // runs and passed in isolation.
    //
    // Forcing an identical `created_at` on every row makes the tie-breaker the
    // ONLY thing that can order them, so this fails outright rather than
    // half the time.
    final logId = await logService.recordCreated(
      channel: NotificationLogChannel.localAndroid,
      notificationType: 'achievement',
    );
    await logService.recordSent(
      logId: logId,
      channel: NotificationLogChannel.localAndroid,
      notificationType: 'achievement',
    );
    await logService.recordOpened(
      logId: logId,
      channel: NotificationLogChannel.localAndroid,
      notificationType: 'achievement',
    );
    await db.customStatement(
      "UPDATE notification_log_events SET created_at = '2026-09-17T10:00:00.000Z';",
    );

    final statusesInOrder = <String>[];
    final http = MockClient((request) async {
      final decoded = jsonDecode(request.body) as Map;
      statusesInOrder.add(decoded['status'] as String);
      return _json(<Object>[], request);
    });
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );
    await sync.debugSyncBatch('qa-user');

    expect(statusesInOrder.indexOf('pending'),
        lessThan(statusesInOrder.indexOf('sent')),
        reason: 'created uploaded after sent — the row status regresses');
    expect(statusesInOrder.indexOf('sent'),
        lessThan(statusesInOrder.indexOf('opened')),
        reason: 'sent uploaded after opened');
  });

  uploadTest('processes events oldest-first so created never uploads after sent',
      () async {
    final logId = await logService.recordCreated(
      channel: NotificationLogChannel.localAndroid,
      notificationType: 'achievement',
    );
    await logService.recordSent(
      logId: logId,
      channel: NotificationLogChannel.localAndroid,
      notificationType: 'achievement',
    );
    await logService.recordOpened(
      logId: logId,
      channel: NotificationLogChannel.localAndroid,
      notificationType: 'achievement',
    );

    final statusesInOrder = <String>[];
    final http = MockClient((request) async {
      final decoded = jsonDecode(request.body) as Map;
      statusesInOrder.add(decoded['status'] as String);
      return _json(<Object>[], request);
    });
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );

    await sync.debugSyncBatch('qa-user');

    expect(statusesInOrder, ['pending', 'sent', 'opened']);
  });

  uploadTest('the opened upsert omits channel (cannot always be known at tap time)',
      () async {
    final logId = await logService.recordCreated(
      channel: NotificationLogChannel.apns,
      notificationType: 'new_transaction',
    );
    await db.customUpdate(
      "UPDATE notification_log_events SET synced_at = 'x' WHERE event_type = 'created';",
    );
    await logService.recordOpened(
      logId: logId,
      channel: NotificationLogChannel.apns,
      notificationType: 'new_transaction',
    );

    Map<String, dynamic>? openedBody;
    final http = MockClient((request) async {
      openedBody = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      return _json(<Object>[], request);
    });
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );

    await sync.debugSyncBatch('qa-user');

    expect(openedBody, isNotNull);
    expect(openedBody!.containsKey('channel'), isFalse);
    expect(openedBody!['status'], 'opened');
  });

  uploadTest(
      'if opened is recorded locally before sent (a real race between the '
      'plugin displaying and this attempt finishing), sync still uploads in '
      'chronological order — opened first, sent second', () async {
    final logId = await logService.recordCreated(
      channel: NotificationLogChannel.localIos,
      notificationType: 'goal_milestone',
    );
    // Tap happens before recordSent runs for this same attempt.
    await logService.recordOpened(
      logId: logId,
      channel: NotificationLogChannel.localIos,
      notificationType: 'goal_milestone',
    );
    await logService.recordSent(
      logId: logId,
      channel: NotificationLogChannel.localIos,
      notificationType: 'goal_milestone',
    );

    final statusesInOrder = <String>[];
    final http = MockClient((request) async {
      final decoded = jsonDecode(request.body) as Map;
      statusesInOrder.add(decoded['status'] as String);
      return _json(<Object>[], request);
    });
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );

    await sync.debugSyncBatch('qa-user');

    // The sync layer never reorders — it uploads in the order events
    // actually happened. The server-side monotonic-status trigger
    // (protect_notification_log_status in 0052_notification_logs.sql) is
    // what guarantees the row's final status doesn't regress from 'opened'
    // back down to 'sent' when the second upsert lands.
    expect(statusesInOrder, ['pending', 'opened', 'sent']);
  });

  uploadTest(
      'a failed upload stops the batch and is retried on the next pass instead of being skipped',
      () async {
    final logId = await logService.recordCreated(
      channel: NotificationLogChannel.localIos,
      notificationType: 'goal_milestone',
    );

    var calls = 0;
    final failingHttp = MockClient((request) async {
      calls++;
      return http.Response('server error', 500, request: request);
    });
    final failingSync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(failingHttp),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );
    await failingSync.debugSyncBatch('qa-user');
    expect(calls, 1);

    final byId = await db
        .customSelect(
          "SELECT synced_at, sync_attempt_count FROM notification_log_events WHERE notification_log_id = '$logId';",
        )
        .getSingle();
    expect(byId.readNullable<String>('synced_at'), isNull);
    expect(byId.read<int>('sync_attempt_count'), 1);

    final succeedingHttp =
        MockClient((request) async => _json(<Object>[], request));
    final succeedingSync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(succeedingHttp),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );
    await succeedingSync.debugSyncBatch('qa-user');
    final afterRetry = await db
        .customSelect(
          "SELECT synced_at FROM notification_log_events WHERE notification_log_id = '$logId';",
        )
        .getSingle();
    expect(afterRetry.readNullable<String>('synced_at'), isNotNull);
  });

  uploadTest(
      'exhausted events remain unsynced without additional network retries',
      () async {
    await logService.recordCreated(
      channel: NotificationLogChannel.localIos,
      notificationType: 'weekly_report',
    );
    final alwaysFailingHttp = MockClient(
        (request) async => http.Response('error', 500, request: request));
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(alwaysFailingHttp),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );

    // 8 failing attempts bump sync_attempt_count to 8 (NotificationLogSyncService's
    // _maxAttemptsPerEvent); later passes exclude the exhausted row.
    for (var i = 0; i < 9; i++) {
      await sync.debugSyncBatch('qa-user');
    }

    final row = await db
        .customSelect(
          "SELECT synced_at, sync_attempt_count FROM notification_log_events;",
        )
        .getSingle();
    expect(row.readNullable<String>('synced_at'), isNull);
    expect(row.read<int>('sync_attempt_count'), 8);
  });
  });
}

// Internal upload component only: debugSyncBatch omits public configuration
// AND native import. The default origin reader and real producer remain intact.
void _notificationInternalStageA() {
  const uid = 'notification-stageA-owner';
  const install = 'notification-stageA-install';
  Future<List<Map<String, Object?>>> events(AppDatabase database) async => [
    for (final row in await database.customSelect(
        'SELECT * FROM notification_log_events ORDER BY created_at ASC, rowid ASC;').get()) row.data,
  ];
  group('E4 notification internal upload', () {
    for (final disposition in ['QD001', 'QD002', 'success', 'ordinary503']) {
      final name = switch (disposition) {
        'QD001' => 'QD001 retires original authority before later event',
        'QD002' => 'QD002 retires original authority before later event',
        'success' => 'matched success ACKs ordered created and sent',
        _ => 'ordinary503 increments first attempt and stops later event',
      };
      test(name, () async {
        final admission = await LedgerAdmissionFixture.open(uid);
        final db = admission.database;
        final location = admission.location;
        Future<Object?>? producer;
        try {
          final cap = admission.fixture.session.captureLocalWorkAuthority()!;
          final origin = await readNotificationLogOrigin(db);
          expect(origin, isNotNull); expect(origin!.uid, uid);
          expect(origin.localGeneration, isNotEmpty);
          expect(origin.localGeneration, admission.fixture.storage.data['local_data_owner_generation']);
          expect(origin.nativeGeneration, isNull, reason: 'local host route, no native owner fabricated');
          expect(origin.isCurrent(), isTrue); expect(await origin.holds(), isTrue);
          final logService = NotificationLogService(db);
          final logId = await logService.recordCreated(channel: NotificationLogChannel.localIos,
              notificationType: 'budget_warning', relatedEntityType: 'budget',
              relatedEntityId: 'synthetic-budget');
          await logService.recordSent(logId: logId, channel: NotificationLogChannel.localIos,
              notificationType: 'budget_warning');
          final before = await events(db);
          expect(before, hasLength(2));
          expect(RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$')
              .hasMatch(logId), isTrue);
          expect(before.map((r) => r['event_type']), ['created', 'sent']);
          expect(before.map((r) => r['id']).toSet(), hasLength(2));
          for (final row in before) {
            expect(row['notification_log_id'], logId);
            expect(row['id'], isA<String>()); expect((row['id'] as String), isNotEmpty);
            expect(row['synced_at'], isNull); expect(row['sync_attempt_count'], 0);
            expect(row['channel'], NotificationLogChannel.localIos);
            expect(row['notification_type'], 'budget_warning');
            final payload = jsonDecode(row['payload_json'] as String) as Map;
            expect(payload[NotificationLogOrigin.payloadKey], {
              'kind': 'local', 'uid': uid, 'generation': origin.localGeneration,
            });
            expect(origin.owns(row['payload_json'] as String), isTrue);
          }
          expect(before.first['related_entity_type'], 'budget');
          expect(before.first['related_entity_id'], 'synthetic-budget');
          final expectedBodies = [for (var i = 0; i < before.length; i++) {
            'id': logId, 'user_id': uid, 'install_id': install,
            'notification_type': before[i]['notification_type'], 'channel': before[i]['channel'],
            if (before[i]['related_entity_type'] != null) 'related_entity_type': before[i]['related_entity_type'],
            if (before[i]['related_entity_id'] != null) 'related_entity_id': before[i]['related_entity_id'],
            if (Platform.isIOS || Platform.isAndroid) 'device_platform': Platform.isIOS ? 'ios' : 'android',
            'status': i == 0 ? 'pending' : 'sent',
            if (i == 0) 'created_at': before[i]['occurred_at'] else 'sent_at': before[i]['occurred_at'],
          }];
          final requests = <http.Request>[];
          final responses = <Object?>[];
          final raw = {'code': disposition == 'ordinary503' ? '503' : disposition,
            'message': disposition == 'ordinary503' ? 'ordinary server failure' : 'particular mutation refusal',
            'details': null, 'hint': null};
          final client = admission.ownClient(SupabaseClient('https://example.supabase.co', 'anon',
              authOptions: const AuthClientOptions(autoRefreshToken: false), httpClient: MockClient((request) async {
            requests.add(request);
            final Object? body = disposition == 'success' ? null : raw;
            responses.add(body);
            return http.Response(jsonEncode(body), disposition == 'success' ? 200 :
                disposition == 'ordinary503' ? 503 : 400,
                headers: {'content-type': 'application/json'}, request: request);
          })));
          await F2Fixture.recoverSession_(client, uid);
          expect(client.auth.currentUser?.id, uid);
          final sync = NotificationLogSyncService(db: db,
              getClient: () => client, getAuthUserId: () async => client.auth.currentUser?.id,
              getCurrentAuthUserId: () => client.auth.currentUser?.id,
              getInstallId: () async => install, mayEgress: () async => true);
          producer = sync.debugSyncBatch(uid).then<Object?>((_) => null, onError: (Object error) => error);
          final outcome = await producer;
          expect(requests, isNotEmpty);
          final first = requests.first;
          expect(first.method, 'POST'); expect(first.url.path, '/rest/v1/notification_logs');
          expect(first.url.queryParameters, {'on_conflict': 'id'});
          expect(first.headers['prefer'], contains('resolution=merge-duplicates'));
          expect(first.headers['prefer'], isNot(contains('return=representation')));
          expect(jsonDecode(first.body), expectedBodies.first);
          expect(responses.first, disposition == 'success' ? null : raw);
          if (disposition == 'QD001' || disposition == 'QD002') {
            // Primary current-API behavior RED. Later assertions are explicitly
            // unreached if this particular rejection leaves the real cap live.
            expect(outcome, isA<NotificationDeliveryStopped>());
            expect((outcome as NotificationDeliveryStopped).accepted, isTrue);
            expect(outcome.complete, isTrue);
            expect(cap.isCurrent, isFalse, reason: 'the rejected notification mutation retires its original owner');
            expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid))!.state,
                disposition == 'QD001' ? AccountFenceState.pending : AccountFenceState.gone);
            expect(requests, hasLength(1), reason: 'later sent event must not dispatch after the owner denial');
            expect(db.lifecycleState, DatabaseLifecycleState.closed);
            expect(await LedgerAdmissionFixture.inspectClosed(db, location, events), before);
          } else if (disposition == 'success') {
            expect(outcome, isNull); expect(cap.isCurrent, isTrue);
            expect(requests, hasLength(2)); expect(responses, [null, null]);
            expect(requests.last.method, 'POST'); expect(requests.last.url.path, '/rest/v1/notification_logs');
            expect(requests.last.url.queryParameters, {'on_conflict': 'id'});
            expect(jsonDecode(requests.last.body), expectedBodies.last);
            final after = await events(db);
            for (var i = 0; i < before.length; i++) {
              expect(after[i]['synced_at'], isNotNull); expect(after[i]['sync_attempt_count'], 0);
              for (final key in before[i].keys.where((k) => k != 'synced_at')) {
                expect(after[i][key], before[i][key], reason: key);
              }
            }
            expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid)), isNull);
          } else {
            expect(outcome, isNull); expect(cap.isCurrent, isTrue); expect(requests, hasLength(1));
            final after = await events(db);
            expect(after.first['sync_attempt_count'], 1); expect(after.first['synced_at'], isNull);
            for (final key in before.first.keys.where((k) => k != 'sync_attempt_count')) {
              expect(after.first[key], before.first[key], reason: key);
            }
            expect(after.last, before.last);
            expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid)), isNull);
          }
        } finally {
          try { await producer; } finally { await admission.finish(); }
        }
      });
    }
  });
}

Future<List<Map<String,Object?>>> _notificationRows(AppDatabase db) async => [
  for(final row in await db.customSelect('SELECT * FROM notification_log_events ORDER BY rowid;').get()) row.data,
];
Future<void> _withNotification(Future<void> Function(LedgerAdmissionFixture admission,
    AppDatabase db, SupabaseClient client, List<http.Request> requests,
    void Function(Future<http.Response> Function(http.Request)) respond) body,
    {LedgerDatabaseProbe? probe}) async {
  final admission=await LedgerAdmissionFixture.open('notification-finite-owner',probe);
  final db=admission.database;final requests=<http.Request>[];
  Future<http.Response> Function(http.Request) handler=(r)async=>http.Response('null',200,
      headers:{'content-type':'application/json'},request:r);
  final client=admission.ownClient(SupabaseClient('https://example.supabase.co','anon',
      authOptions:const AuthClientOptions(autoRefreshToken:false),httpClient:MockClient((r){requests.add(r);return handler(r);})));
  try {
    await F2Fixture.recoverSession_(client,admission.uid);
    final producer=NotificationLogService(db);
    final id=await producer.recordCreated(channel:'local_ios',notificationType:'finite');
    await producer.recordSent(logId:id,channel:'local_ios',notificationType:'finite');
    expect(await _notificationRows(db),hasLength(2));
    await body(admission,db,client,requests,(next){handler=next;});
  } finally { probe?.before=null;probe?.afterSelect=null;await admission.finish(); }
}
NotificationLogSyncService _notificationSync(AppDatabase db,SupabaseClient client,
    {SupabaseClient Function()? getClient,String? Function()? current,Future<bool> Function()? consent}) =>
    NotificationLogSyncService(db:db,getClient:getClient??()=>client,
      getAuthUserId:()async=>client.auth.currentUser?.id,
      getCurrentAuthUserId:current??()=>client.auth.currentUser?.id,
      getInstallId:()async=>'finite-install',mayEgress:consent??()async=>true);
void _notificationFiniteControls() {
  group('E4 notification finite',(){
    test('last synchronous getter retirement blocks actual builder',()async {
      final probe=LedgerDatabaseProbe();var reads=0;var armed=false;var clientReads=0;var retired=false;
      await _withNotification((a,db,client,requests,respond)async {
        final before=await _notificationRows(db);
        probe.before=(sql)async {if(sql.startsWith('SELECT * FROM notification_log_events WHERE id')) {
          reads++;if(reads==2)armed=true;
        }};
        final sync=_notificationSync(db,client,getClient:(){if(armed)clientReads++;return client;},current:(){
          if(clientReads==2&&!retired){retired=true;CloudEgressGate.instance.advanceEpoch();}
          return client.auth.currentUser?.id;
        });
        final result=await sync.debugSyncBatch(a.uid).then<Object?>((_)=>null,onError:(Object e)=>e);
        expect(armed,isTrue);expect(retired,isTrue);expect(result,isA<NotificationDeliveryStopped>());
        expect(requests,isEmpty);expect(await _notificationRows(db),before);
      },probe:probe);
    });
    test('local preflight 55 is propagated without remote deferred disposition',()async {
      final probe=LedgerDatabaseProbe();var reads=0;var reached=false;
      await _withNotification((a,db,client,requests,respond)async {
        final before=await _notificationRows(db);
        probe.before=(sql)async {if(sql.startsWith('SELECT * FROM notification_log_events WHERE id')&&++reads==2){
          reached=true;throw const PostgrestException(message:'local preflight witness',code:'55P03');
        }};
        final result=await _notificationSync(db,client).debugSyncBatch(a.uid).then<Object?>((_)=>null,onError:(Object e)=>e);
        expect(reached,isTrue);expect(result,isA<PostgrestException>());
        expect((result as PostgrestException).message,'local preflight witness');
        expect(requests,isEmpty);probe.before=null;expect(await _notificationRows(db),before);
      },probe:probe);
    });
  });
}

void _notificationMoreControls() {
  group('E4 notification bounded controls',(){
    for(final busyThenSuccess in [true,false]) {
      test('actual 55 immutable retry success=$busyThenSuccess',()async {
        await _withNotification((a,db,client,requests,respond)async {
          final before=await _notificationRows(db);
          respond((r)async {
            final busy=!busyThenSuccess||requests.length==1;
            return http.Response(jsonEncode(busy?{'code':'55P03','message':'busy','details':null,'hint':null}:null),
              busy?500:200,headers:{'content-type':'application/json'},request:r);
          });
          await _notificationSync(db,client).debugSyncBatch(a.uid);
          final after=await _notificationRows(db);
          expect(requests,hasLength(3));
          expect(requests.take(busyThenSuccess?2:3).map((r)=>r.body).toSet(),hasLength(1));
          if(busyThenSuccess){expect(after.every((r)=>r['synced_at']!=null),isTrue);}
          else {expect(after,before);}
          expect(after.map((r)=>r['sync_attempt_count']),[0,0]);
          expect(a.fixture.session.captureLocalWorkAuthority()!.isCurrent,isTrue);
          expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(a.uid)),isNull);
        });
      });
    }
    for(final ordinary in [false,true]) {
      test('late ${ordinary?'ordinary error':'success'} preserves changed full row',()async {
        await _withNotification((a,db,client,requests,respond)async {
          final reached=Completer<void>();final release=Completer<void>();Future<Object?>? running;
          respond((r)async {if(!reached.isCompleted)reached.complete();await release.future;
            return http.Response(jsonEncode(ordinary?{'code':'503','message':'ordinary','details':null,'hint':null}:null),
              ordinary?503:200,headers:{'content-type':'application/json'},request:r);});
          try {
            running=_notificationSync(db,client).debugSyncBatch(a.uid).then<Object?>((_)=>null,onError:(Object e)=>e);
            await reached.future;
            await db.customStatement("UPDATE notification_log_events SET error_reason='new local semantic value',sync_attempt_count=4 WHERE rowid=(SELECT min(rowid) FROM notification_log_events);");
            final newer=(await _notificationRows(db)).first;
            release.complete();expect(await running,isNull);
            final after=await _notificationRows(db);expect(after.first,newer);
            expect(requests,hasLength(ordinary?1:2));
            if(!ordinary)expect(after.last['synced_at'],isNotNull);
          }finally {if(!release.isCompleted)release.complete();await running;}
        });
      });
    }
    test('actual queued failed and opened payload shapes retain exact fields',()async {
      await _withNotification((a,db,client,requests,respond)async {
        final service=NotificationLogService(db);final logId=(await _notificationRows(db)).first['notification_log_id'] as String;
        await service.recordQueued(logId:logId,channel:'local_ios',notificationType:'finite');
        await service.recordFailed(logId:logId,channel:'local_ios',notificationType:'finite',error:StateError('synthetic bounded failure'));
        await service.recordOpened(logId:logId,channel:'local_ios',notificationType:'finite');
        final before=await _notificationRows(db);expect(before,hasLength(5));
        await _notificationSync(db,client).debugSyncBatch(a.uid);
        expect(requests,hasLength(5));
        for(var i=0;i<before.length;i++) {
          final row=before[i];final type=row['event_type'];
          final expected=<String,Object?>{'id':logId,'user_id':a.uid,'install_id':'finite-install',
            'notification_type':'finite',if(type!='opened')'channel':'local_ios',
            if(Platform.isIOS||Platform.isAndroid)'device_platform':Platform.isIOS?'ios':'android',
            'status':type=='created'?'pending':type,
            '${type=='created'?'created':type}_at':row['occurred_at'],
            if(type=='failed')'error_code':row['error_code'],if(type=='failed')'error_reason':row['error_reason'],
          };
          expect(requests[i].method,'POST');expect(requests[i].url.path,'/rest/v1/notification_logs');
          expect(requests[i].url.queryParameters,{'on_conflict':'id'});expect(jsonDecode(requests[i].body),expected);
        }
        expect((await _notificationRows(db)).every((r)=>r['synced_at']!=null&&r['sync_attempt_count']==0),isTrue);
      });
    });
    test('local ACK failure has no remote replay or business attempt',()async {
      final probe=LedgerDatabaseProbe();var reached=false;
      await _withNotification((a,db,client,requests,respond)async {
        final before=await _notificationRows(db);
        probe.before=(sql)async {if(sql.startsWith('UPDATE notification_log_events SET synced_at')){
          reached=true;throw StateError('controlled local ACK');
        }};
        final result=await _notificationSync(db,client).debugSyncBatch(a.uid).then<Object?>((_)=>null,onError:(Object e)=>e);
        expect(reached,isTrue);expect(result,isA<StateError>());expect(requests,hasLength(1));
        probe.before=null;expect(await _notificationRows(db),before);
      },probe:probe);
    });
    test('factory raw QD is unproven and cannot hold owner',()async {
      var reads=0;var armed=false;var clientReads=0;final probe=LedgerDatabaseProbe();
      await _withNotification((a,db,client,requests,respond)async {
        final before=await _notificationRows(db);
        probe.before=(sql)async{if(sql.startsWith('SELECT * FROM notification_log_events WHERE id')&&++reads==2)armed=true;};
        final result=await _notificationSync(db,client,getClient:(){
          if(armed&&++clientReads==2)throw const PostgrestException(message:'factory only',code:'QD002');return client;
        }).debugSyncBatch(a.uid).then<Object?>((_)=>null,onError:(Object e)=>e);
        expect(clientReads,2);expect(result,isA<NotificationDeliveryStopped>());
        expect((result as NotificationDeliveryStopped).reason,NotificationDeliveryStopReason.nonMutationRefusal);
        expect(requests,isEmpty);expect(await _notificationRows(db),before);
        expect(a.fixture.session.captureLocalWorkAuthority()!.isCurrent,isTrue);
        expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(a.uid)),isNull);
      },probe:probe);
    });
    test('particular denial during held readiness accepts original negative lifetime',()async {
      await _withNotification((a,db,client,requests,respond)async {
        final before=await _notificationRows(db);final location=a.location;
        final reached=Completer<void>();final release=Completer<void>();Future<Object?>? running;Future<bool>? loading;
        final retired=Completer<void>();
        void listener(){if(a.fixture.session.status==SessionStatus.sessionExpired&&!retired.isCompleted)retired.complete();}
        a.fixture.session.addListener(listener);
        respond((r)async{reached.complete();await release.future;return http.Response(jsonEncode(
          {'code':'QD001','message':'pending','details':null,'hint':null}),400,headers:{'content-type':'application/json'},request:r);});
        try {
          running=_notificationSync(db,client).debugSyncBatch(a.uid).then<Object?>((_)=>null,onError:(Object e)=>e);
          await reached.future;
          final readiness=a.fixture.storage.holdOnce((op,key)=>op=='read'&&key==AccountFenceStore.storageKey);
          loading=AccountFenceAuthority.shared.initialize();
          await readiness.reached.future;
          try {
            release.complete();
            expect(await Future.any([retired.future.then((_)=>true),running.then((_)=>false)]),isTrue);
            expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(a.uid))!.state,AccountFenceState.pending);
          }finally {if(!readiness.release.isCompleted)readiness.release.complete();}
          final result=await running;await loading;
          expect(result,isA<NotificationDeliveryStopped>());expect((result as NotificationDeliveryStopped).accepted,isTrue);expect(result.complete,isTrue);
          expect(requests,hasLength(1));expect(await LedgerAdmissionFixture.inspectClosed(db,location,_notificationRows),before);
        }finally {
          a.fixture.session.removeListener(listener);
          if(!release.isCompleted)release.complete();
          await running;await loading;
        }
      });
    });
    test('same UID successor rejects original negative response',()async {
      await _withNotification((a,db,client,requests,respond)async {
        final before=await _notificationRows(db);final old=a.fixture.session.captureLocalWorkAuthority()!;
        final reached=Completer<void>();final release=Completer<void>();Future<Object?>? running;
        respond((r)async{reached.complete();await release.future;return http.Response(jsonEncode(
          {'code':'QD002','message':'gone','details':null,'hint':null}),400,headers:{'content-type':'application/json'},request:r);});
        try {
          running=_notificationSync(db,client).debugSyncBatch(a.uid).then<Object?>((_)=>null,onError:(Object e)=>e);
          await reached.future;await a.fixture.signIn(a.uid);
          expect(old.isCurrent,isFalse);expect(a.fixture.session.captureLocalWorkAuthority()!.isCurrent,isTrue);
          release.complete();final result=await running;expect(result,isA<NotificationDeliveryStopped>());
          expect((result as NotificationDeliveryStopped).accepted,isFalse);expect(result.complete,isFalse);
          expect(requests,hasLength(1));expect(await _notificationRows(a.fixture.host.current!.database),before);
          expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(a.uid)),isNull);
        }finally {if(!release.isCompleted)release.complete();await running;}
      });
    });
    test('started atomic ACK settles before physical close begins',()async {
      final probe=LedgerDatabaseProbe();final reached=Completer<void>();final release=Completer<void>();
      var terminal=false;var closeBeforeTerminal=false;Future<Object?>? running;Future<void>? successor;
      await _withNotification((a,db,client,requests,respond)async {
        probe.before=(sql)async{if(sql.startsWith('UPDATE notification_log_events SET synced_at')&&!reached.isCompleted){
          terminal=false;reached.complete();await release.future;
        }};
        probe.afterTransactionSettled=(){if(reached.isCompleted)terminal=true;};
        probe.onClose=(){if(!terminal)closeBeforeTerminal=true;};
        final closeBaseline=probe.closeAttempts;
        try {
          running=_notificationSync(db,client).debugSyncBatch(a.uid).then<Object?>((_)=>null,onError:(Object e)=>e);
          await reached.future;
          successor=a.fixture.signIn('notification-next-owner');
          await Future<void>.delayed(Duration.zero);
          expect(probe.closeAttempts,closeBaseline);
          release.complete();await running;await successor;
          expect(terminal,isTrue);expect(closeBeforeTerminal,isFalse);expect(probe.closeAttempts,closeBaseline+1);
          expect(requests,hasLength(1));expect(db.lifecycleState,DatabaseLifecycleState.closed);
        }finally {if(!release.isCompleted)release.complete();await running;await successor;}
      },probe:probe);
    });
  });
}


// Native primitives below are explicit component callbacks: the real bridge's
// consume/ACK APIs require Platform.isIOS even with debugTreatHostAsNative.
class _NativeImportStageProbe extends LedgerDatabaseProbe {
  final trace = <String>[];
  bool get insertTerminal => trace.contains('insert-terminal');

  @override
  Future<int> runInsert(String sql, List<Object?> args) async {
    final target = sql.contains('INSERT OR IGNORE INTO notification_log_events');
    if (target) trace.add('insert-enter');
    try {
      return await super.runInsert(sql, args);
    } finally {
      if (target) trace.add('insert-terminal');
    }
  }
}

class _NativeImportStageFixture {
  _NativeImportStageFixture(this.admission, this.probe);
  final LedgerAdmissionFixture admission;
  final _NativeImportStageProbe probe;
  final nativeCalls = <MethodCall>[];
  final unexpectedNative = <String>[];
  final unexpectedHttp = <http.Request>[];
  final consumed = <List<Object>>[];
  final acknowledged = <NativeNotificationLogEvent>[];
  final pending = <NativeNotificationLogEvent>[];
  final owned = <Future<void>>[];
  int nativeGeneration = 7;
  bool nativeBarrier = false;
  Future<bool> Function(NativeNotificationLogEvent)? acknowledge;

  AppDatabase get db => admission.database;
  String get uid => admission.uid;
  late final NativeNotificationLogEvent event = NativeNotificationLogEvent(
      eventId: '00000000-0000-4000-8000-000000000071',
      notificationLogId: 'native-import-stageA-log',
      eventType: 'created', channel: 'ios_shortcut_local',
      notificationType: 'native-stageA', relatedEntityType: 'budget',
      relatedEntityId: 'native-stageA-budget', errorCode: null,
      errorReason: null, occurredAt: DateTime.utc(2026, 10, 1, 12),
      originKind: 'native', ownerUid: uid, ownerGeneration: 7);

  NotificationLogSyncService service() => NotificationLogSyncService(
      db: db,
      // No readOrigin override: actual host/session/storage + native primitive.
      consumeNativeEvents: (owner, generation) async {
        consumed.add([owner, generation]);
        return [for (final item in pending)
          if (item.ownerUid == owner && item.ownerGeneration == generation) item];
      },
      acknowledgeNativeEvent: (item) async {
        acknowledged.add(item);
        if (acknowledge != null) return acknowledge!(item);
        return removeFromComponentQueue(item);
      });

  bool removeFromComponentQueue(NativeNotificationLogEvent item) {
    if (nativeBarrier || item.ownerUid != uid ||
        item.ownerGeneration != nativeGeneration) {
      return false;
    }
    final before = pending.length;
    pending.removeWhere((candidate) => candidate.eventId == item.eventId &&
        candidate.ownerUid == item.ownerUid &&
        candidate.ownerGeneration == item.ownerGeneration);
    return pending.length != before;
  }

  Future<void> track(Future<void> future) {
    owned.add(future);
    return future;
  }

  void checkNativeCalls() {
    expect(unexpectedNative, isEmpty);
    expect(unexpectedHttp, isEmpty, reason: 'all unexpected HTTP remains externally visible');
    expect(nativeCalls, isNotEmpty);
    for (final call in nativeCalls) {
      expect(call.method, 'getCaptureOwner');
      expect(call.arguments, isNull);
    }
  }
}

Future<void> _withNativeImportStageA(
    Future<void> Function(_NativeImportStageFixture) body) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final probe = _NativeImportStageProbe();
  final admission = await LedgerAdmissionFixture.open('native-import-stageA-owner', probe);
  final fixture = _NativeImportStageFixture(admission, probe);
  const channel = MethodChannel('money_companion/native_capture');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final priorFlag = NativeCaptureBridge.debugTreatHostAsNative;
  NativeCaptureBridge.debugTreatHostAsNative = true;
  messenger.setMockMethodCallHandler(channel, (call) async {
    fixture.nativeCalls.add(call);
    if (call.method == 'getCaptureOwner' && call.arguments == null) {
      return {'uid': fixture.uid, 'uidHash': 'synthetic-native-owner-hash',
        'generation': fixture.nativeGeneration};
    }
    fixture.unexpectedNative.add(call.method);
    throw StateError('unexpected native StageA method: ${call.method}');
  });
  fixture.pending.add(fixture.event);
  Object? primaryError;
  StackTrace? primaryStack;
  final cleanupErrors = <(Object, StackTrace)>[];
  try {
    expect(identical(admission.fixture.host.current!.database, fixture.db), isTrue);
    expect(await AccountFenceAuthority.shared.capture(
        admission.fixture.session, admission.fixture.host), isNotNull);
    final origin = await readNotificationLogOrigin(fixture.db);
    expect(origin, isNotNull);
    expect(origin!.uid, fixture.uid);
    expect(origin.localGeneration,
        admission.fixture.storage.data['local_data_owner_generation']);
    expect(origin.nativeGeneration, 7);
    expect(origin.isCurrent(), isTrue);
    expect(await origin.holds(), isTrue);
    await body(fixture);
  } catch (error, stack) {
    primaryError = error;
    primaryStack = stack;
  } finally {
    try {
      await Future.wait(fixture.owned);
    } catch (error, stack) {
      cleanupErrors.add((error, stack));
    }
    try {
      fixture.checkNativeCalls();
    } catch (error, stack) {
      cleanupErrors.add((error, stack));
    }
    NativeCaptureBridge.debugTreatHostAsNative = priorFlag;
    messenger.setMockMethodCallHandler(channel, null);
    try {
      await admission.finish();
    } catch (error, stack) {
      cleanupErrors.add((error, stack));
    }
  }
  if (primaryError != null) {
    for (final (error, stack) in cleanupErrors) {
      printOnFailure('additional native-import cleanup failure: $error\n$stack');
    }
    Error.throwWithStackTrace(primaryError, primaryStack!);
  }
  if (cleanupErrors.isNotEmpty) {
    for (final (error, stack) in cleanupErrors.skip(1)) {
      printOnFailure('additional native-import cleanup failure: $error\n$stack');
    }
    Error.throwWithStackTrace(cleanupErrors.first.$1, cleanupErrors.first.$2);
  }
}

void _checkNativeStageRow(Map<String, Object?> row, NativeNotificationLogEvent event) {
  expect(row['id'], 'native:${event.eventId}');
  expect(row['notification_log_id'], event.notificationLogId);
  expect(row['event_type'], event.eventType);
  expect(row['channel'], event.channel);
  expect(row['notification_type'], event.notificationType);
  expect(row['related_entity_type'], event.relatedEntityType);
  expect(row['related_entity_id'], event.relatedEntityId);
  expect(row['error_code'], event.errorCode);
  expect(row['error_reason'], event.errorReason);
  expect(row['occurred_at'], '2026-10-01T12:00:00.000Z');
  expect(row['created_at'], isNotNull);
  expect(row['synced_at'], isNull);
  expect(row['sync_attempt_count'], 0);
  expect(jsonDecode(row['payload_json']! as String), {
    NotificationLogOrigin.payloadKey: {
      'kind': 'native', 'uid': event.ownerUid, 'generation': event.ownerGeneration,
    },
  });
}

class _NativeImportCallerPhase implements SyncPhaseLifecycle {
  _NativeImportCallerPhase(this.authority, this.handle, this.database);
  final AccountFenceAuthority authority;
  final AccountFenceHandle handle;
  @override
  final AppDatabase database;
  bool callerCurrent = true;
  @override
  bool get isCurrent => callerCurrent && authority.isCurrentForDatabase(handle, database);
  @override
  Future<T> runLocal<T>(Future<T> Function() action) {
    if (!isCurrent) throw const StaleAdmissionException();
    return authority.runCurrentLocal(handle, database, () {
      if (!isCurrent) throw const StaleAdmissionException();
      return action();
    });
  }
}

void _notificationNativeImportStageA() {
  group('E4 native import real lifetime', () {
    test('current persistence precedes ACK', () async {
      await _withNativeImportStageA((f) async {
        Map<String, Object?>? atAck;
        f.acknowledge = (event) async {
          // Observe the actual row before the component ACK removes anything.
          atAck = (await f.db.customSelect(
              'SELECT * FROM notification_log_events WHERE id = ?',
              variables: [Variable.withString('native:${event.eventId}')])
              .getSingle()).data;
          f.probe.trace.add('ack');
          return f.removeFromComponentQueue(event);
        };
        await f.track(f.service().debugImportNativeEvents());
        expect(f.consumed, [[f.uid, 7]]);
        expect(f.acknowledged, hasLength(1));
        expect(identical(f.acknowledged.single, f.event), isTrue);
        expect(atAck, isNotNull);
        _checkNativeStageRow(atAck!, f.event);
        expect(f.probe.trace.indexOf('insert-terminal'),
            lessThan(f.probe.trace.indexOf('ack')));
        final rows = await _notificationRows(f.db);
        expect(rows, [atAck]);
        expect(f.pending, isEmpty);
        expect(f.admission.fixture.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
      });
    });

    test('held INSERT and explicit switch close ordering', () async {
      await _withNativeImportStageA((f) async {
        final location = f.admission.location;
        final original = f.admission.fixture.session.captureLocalWorkAuthority()!;
        final entered = Completer<void>();
        final release = Completer<void>();
        final beforeWrites = List<String>.of(f.admission.fixture.storage.attempts);
        Object? nestedError;
        Object? importError;
        var retiredReadbacks = 0;
        Future<void>? importer;
        Future<void>? successor;
        f.probe.before = (sql) async {
          if (sql.contains('INSERT OR IGNORE INTO notification_log_events') && !entered.isCompleted) {
            try {
              await f.admission.fixture.session.setIdentity(method: 'google',
                  userId: 'native-import-reentrant-successor');
            } catch (error) {
              nestedError = error;
            }
            entered.complete();
            await release.future;
          }
          if (!original.isCurrent && sql.startsWith('SELECT * FROM notification_log_events WHERE id')) {
            retiredReadbacks++;
          }
        };
        f.probe.onClose = () => f.probe.trace.add('close-begin');
        f.probe.onClosed = () => f.probe.trace.add('close-end');
        try {
          importer = f.track(f.service().debugImportNativeEvents().then<void>((_) {},
              onError: (Object error) { importError = error; }));
          await entered.future;
          expect(nestedError, isA<StateError>().having((e) => e.message,
              'exact reservation refusal', 'identity_transition_inside_local_operation'));
          expect(f.admission.fixture.storage.attempts, beforeWrites);
          expect(original.isCurrent, isTrue);
          expect(identical(f.admission.fixture.host.current!.database, f.db), isTrue);
          expect(f.consumed, [[f.uid, 7]]);
          expect(f.probe.insertTerminal, isFalse);
          successor = f.track(f.admission.fixture.signIn('native-import-stageA-successor'));
          expect(original.isCurrent, isFalse);
          release.complete();
          await importer;
          await successor;
          expect(importError, isA<NotificationDeliveryStopped>().having(
              (e) => e.reason, 'retired original', NotificationDeliveryStopReason.stale));
          expect(f.probe.insertTerminal, isTrue);
          expect(f.db.lifecycleState, DatabaseLifecycleState.closed);
          expect(f.probe.trace, contains('close-end'));
          expect(retiredReadbacks, 0);
          expect(f.acknowledged, isEmpty);
          expect(f.pending, [f.event]);
          expect(f.admission.fixture.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
          expect(await _notificationRows(f.admission.fixture.host.current!.database), isEmpty);
          final retained = await LedgerAdmissionFixture.inspectClosed(f.db, location, _notificationRows);
          expect(retained, hasLength(1));
          _checkNativeStageRow(retained.single, f.event);
          printOnFailure('native import trace: ${f.probe.trace}');
          expect(f.probe.trace.indexOf('insert-terminal'),
              lessThan(f.probe.trace.indexOf('close-begin')),
              reason: 'physical close must wait for the whole reserved INSERT Future');
        } finally {
          if (!release.isCompleted) release.complete();
          await importer;
          await successor;
        }
      });
    });

    test('changed native generation after readback retains event', () async {
      await _withNativeImportStageA((f) async {
        final original = f.admission.fixture.session.captureLocalWorkAuthority()!;
        final entered = Completer<void>();
        final release = Completer<void>();
        Future<void>? importer;
        f.probe.afterSelect = (sql) async {
          if (sql.startsWith('SELECT * FROM notification_log_events WHERE id') && !entered.isCompleted) {
            f.probe.trace.add('readback-returned');
            entered.complete();
            await release.future;
          }
        };
        try {
          importer = f.track(f.service().debugImportNativeEvents());
          await entered.future;
          expect(f.probe.insertTerminal, isTrue);
          expect(f.consumed, [[f.uid, 7]]);
          f.nativeGeneration = 8;
          expect(original.isCurrent, isTrue);
          release.complete();
          await importer;
          expect(f.probe.trace, contains('readback-returned'));
          expect(f.acknowledged, isEmpty);
          expect(f.pending, [f.event]);
          final rows = await _notificationRows(f.db);
          expect(rows, hasLength(1));
          _checkNativeStageRow(rows.single, f.event);
          expect(original.isCurrent, isTrue);
        } finally {
          if (!release.isCompleted) release.complete();
          await importer;
        }
      });
    });
    test('public original phase retirement during consume blocks internal SQL', () async {
      await _withNativeImportStageA((f) async {
        final authority = AccountFenceAuthority.shared;
        final handle = await authority.captureForDatabase(f.admission.fixture.session, f.db);
        expect(handle, isNotNull);
        final caller = _NativeImportCallerPhase(authority, handle!, f.db);
        final phase = SyncPhaseBinding()..bind(caller);
        final original = f.admission.fixture.session.captureLocalWorkAuthority()!;
        final origin = await readNotificationLogOrigin(f.db);
        expect(origin, isNotNull);
        final before = await _notificationRows(f.db);
        final requests = f.unexpectedHttp;
        final client = f.admission.ownClient(SupabaseClient('https://example.supabase.co', 'anon',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
            httpClient: MockClient((request) async {
              requests.add(request);
              throw StateError('unexpected native public witness HTTP: ${request.url}');
            })));
        await F2Fixture.recoverSession_(client, f.uid);
        final entered = Completer<void>();
        final release = Completer<void>();
        var inserts = 0;
        var readbacks = 0;
        Object? outcome;
        Future<void>? producer;
        f.probe.before = (sql) async {
          if (sql.contains('INSERT OR IGNORE INTO notification_log_events')) inserts++;
          if (sql.startsWith('SELECT * FROM notification_log_events WHERE id')) readbacks++;
        };
        final service = NotificationLogSyncService(db: f.db,
            getClient: () => client, getAuthUserId: () async => client.auth.currentUser?.id,
            getCurrentAuthUserId: () => client.auth.currentUser?.id,
            getInstallId: () async => 'native-import-public-install', mayEgress: () async => true,
            consumeNativeEvents: (uid, generation) async {
              f.consumed.add([uid, generation]);
              entered.complete();
              await release.future;
              return List<NativeNotificationLogEvent>.of(f.pending);
            }, acknowledgeNativeEvent: (event) async {
              f.acknowledged.add(event);
              return f.removeFromComponentQueue(event);
            });
        try {
          producer = f.track(service.syncWithPhase(phase).then<void>((_) {},
              onError: (Object error) { outcome = error; }));
          await entered.future;
          expect(f.consumed, [[f.uid, 7]]);
          caller.callerCurrent = false;
          expect(authority.isCurrentForDatabase(handle, f.db), isTrue);
          expect(original.isCurrent, isTrue);
          expect(origin!.isCurrent(), isTrue);
          expect(await origin.holds(), isTrue);
          expect(client.auth.currentUser?.id, f.uid);
          expect(phase.isCurrent, isFalse);
          release.complete();
          await producer;
          expect(outcome, isA<NotificationDeliveryStopped>().having(
              (e) => e.reason, 'caller-only retirement', NotificationDeliveryStopReason.stale));
          expect(inserts, 0);
          expect(readbacks, 0);
          expect(f.acknowledged, isEmpty);
          expect(f.pending, [f.event]);
          expect(await _notificationRows(f.db), before);
          expect(authority.isCurrentForDatabase(handle, f.db), isTrue);
          expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(f.uid)), isNull);
        } finally {
          if (!release.isCompleted) release.complete();
          await producer;
        }
      });
    });
  });
}
