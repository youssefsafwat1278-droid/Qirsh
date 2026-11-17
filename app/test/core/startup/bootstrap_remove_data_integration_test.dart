import 'package:money_companion/core/session/account_scope.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
// Test-only mock of the already-pinned SDK transitive preferences store.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as notifications;
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/tracking/user_activity_service.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/data/repositories/drift_sender_bank_mapping_repository.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import '../../harness/egress_test_support.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint;
// ignore: depend_on_referenced_packages
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:path/path.dart' as p;

import 'package:money_companion/core/auth/auth_coordinator.dart';
import 'package:money_companion/core/auth/refresh_transport.dart';
import 'package:money_companion/core/auth/session_files.dart';
import 'package:money_companion/core/auth/session_store.dart';

import '../auth/store_fakes.dart';
import '../session/f2_fixture.dart';
import '../session/recording_secure_storage.dart';

// F2 round 2 (R7) — the REAL BootstrapRunner.run() over injected platform
// channels, storage and auth client: the production startup orchestration
// decides what is adopted, bound, opened and admitted.

class _NoNotifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<NotificationAppLaunchDetails?>
      getNotificationAppLaunchDetails() async => null;
}

class _Queue implements CaptureQueueBridge {
  CaptureRemovalBarrierRead barrier = const CaptureRemovalBarrierRead.absent();
  final calls = <String>[];
  @override
  Future<CaptureRemovalBarrierRead> getCaptureRemovalBarrier() async {
    calls.add('get');
    return barrier;
  }

  @override
  Future<void> beginCaptureRemoval(String uid) async => calls.add('begin:$uid');
  @override
  Future<void> finishCaptureRemoval(String uid) async {
    calls.add('finish:$uid');
    barrier = const CaptureRemovalBarrierRead.absent();
  }

  @override
  Future<int> captureOwnerEpoch() async => 0;
  @override
  Future<bool> clearCaptureOwner({bool clearHint = false}) async => true;
  @override
  Future<void> publishCaptureOwner({
    required String uid,
    required bool cloud,
    required bool ai,
    required int version,
    required int expectedEpoch,
    int? transitionGeneration,
  }) async {}
}

void main() {
  _senderBootstrapConfigured();
  // Built for an UNCONFIGURED binary (debugAuthClient stands in for the SDK):
  // it runs in the define-free bulk stage. With the synthetic defines the
  // compile-time config routes startup through the real SDK and native
  // keychain instead, so ci_gates.sh selects only the configured group
  // (_senderBootstrapConfigured) there.
  group('original removal integration controls', () {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  late RecordingSecureStorage storage;
  late _Queue queue;
  final session = AppSession.instance;
  final runners = <BootstrapRunner>[];
  Timer? frames;

  setUp(() async {
    support = Directory.systemTemp.createTempSync('bootstrap_it_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    storage = RecordingSecureStorage().install();
    FlutterLocalNotificationsPlatform.instance = _NoNotifications();
    queue = _Queue();
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    await session.wipeAndReset();
    // Production waits for a frame after withdrawing a scope
    // (`WidgetsBinding.instance.endOfFrame`); a non-widget test has none, so
    // frames are driven by hand.
    final binding = TestWidgetsFlutterBinding.instance;
    frames = Timer.periodic(const Duration(milliseconds: 20), (_) {
      binding.scheduleFrame();
      binding.handleBeginFrame(Duration.zero);
      binding.handleDrawFrame();
    });
  });

  tearDown(() async {
    for (final r in [...runners]) {
      try {
        await r.accountScope.lock();
        r.accountScope.dispose();
      } catch (_) {}
    }
    frames?.cancel();
    runners.clear();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    session.configureCaptureOwnerClear(null);
    support.deleteSync(recursive: true);
  });

  Future<BootstrapRunner> boot({String? staleSessionOf}) async {
    final client = staleSessionOf == null
        ? null
        : await F2Fixture.liveClient(staleSessionOf);
    final runner = BootstrapRunner(debugAuthClient: client)
      ..captureQueue = queue;
    runners.add(runner);
    await runner.run();
    return runner;
  }

  Directory replicas() => Directory(p.join(support.path, 'replicas'));
  List<String> replicaDirs() => replicas().existsSync()
      ? [
          for (final e in replicas().listSync())
            if (e is Directory && !p.basename(e.path).startsWith('_'))
              p.basename(e.path),
        ]
      : [];
  List<String> keyWrites(int from) => [
        for (final a in storage.attempts.skip(from))
          if (a.startsWith('write:qirsh.db_key.')) a,
      ];
  List<String> admissionWrites(int from) => [
        for (final a in storage.attempts.skip(from))
          if (a.startsWith('write:$kMarkerKey=') ||
              a.startsWith('write:$kGenerationKey=') ||
              a.startsWith('write:qirsh.db_key.') ||
              (a.startsWith('write:qirsh.replicas.v1=') &&
                  a != 'write:qirsh.replicas.v1={}'))
            a,
      ];

  Future<void> signIn(String uid) => session.completeOnboarding(
      method: 'google', email: '$uid@example.com', userId: uid);

  test(
      'O-H1: one inert coordinator exists before any recovery or opener and '
      'is reused by retries and later runners', () async {
    final events = <String>[];
    String? stepAtCreation = 'unset';
    late BootstrapRunner first;
    first = BootstrapRunner(debugCoordinatorEvent: (event) {
      events.add(event);
      if (event == 'coordinator') stepAtCreation = first.lastStep;
    })
      ..captureQueue = queue;
    runners.add(first);
    await first.run();
    expect(events.first, 'coordinator',
        reason: 'before the first recovery, session load or Drift opener');
    expect(stepAtCreation, isNull, reason: 'no bootstrap step had started');
    final coordinator = first.debugCoordinator;
    expect(coordinator, isNotNull);
    expect(coordinator!.isInert, isTrue);
    expect(coordinator.mode, DatabaseAccessMode.closed);
    expect(coordinator.client.isHostIssued, isFalse);
    expect(DatabaseAccessBroker.discover(), isNotNull);

    // Retry of the retained runner: no replacement registration.
    await first.run();
    expect(identical(first.debugCoordinator, coordinator), isTrue);
    expect(events.where((e) => e == 'coordinator'), hasLength(1));

    // A rebuilt runner reuses the process-retained coordinator.
    await first.accountScope.lock();
    final second = BootstrapRunner(debugCoordinatorEvent: events.add)
      ..captureQueue = queue;
    runners.add(second);
    await second.run();
    expect(identical(second.debugCoordinator, coordinator), isTrue);
    expect(events.where((e) => e == 'coordinator'), hasLength(1));
    expect(events.where((e) => e == 'coordinator-reused'), hasLength(1));
    expect(coordinator.mode, DatabaseAccessMode.closed,
        reason: 'creating it granted nothing');
    expect(coordinator.client.isHostIssued, isFalse);
  });

  test(
      'O-H3: the real cold launch reserves its primary open as a launch-specific '
      'private reservation that grants nothing', () async {
    final first = await boot(staleSessionOf: 'uid-launch');
    await signIn('uid-launch');
    await first.accountScope.detach(); // the process dies while `active`
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    final restarted = await boot(staleSessionOf: 'uid-launch');
    expect(restarted.accountScope.activeUid, 'uid-launch',
        reason: 'the existing replica was opened at launch');
    final coordinator = restarted.debugCoordinator!;
    final reservation = session.debugDatabaseOpenReservation;
    expect(reservation, isNotNull);
    expect(reservation!.kind, DatabaseReservationKind.coldLaunchPrimary);
    expect(reservation.uid, 'uid-launch');
    expect(reservation.hasOpened, isTrue);
    expect(
        reservation.ownsDatabase(restarted.accountScope.current!.database),
        isTrue,
        reason: 'the real primary handle is the tracked one');
    expect(coordinator.pendingOpens, 0);
    expect(coordinator.openHolders, greaterThanOrEqualTo(1));
    // Reserving is bookkeeping: no job client, no mode, nothing promoted.
    expect(coordinator.mode, DatabaseAccessMode.closed);
    expect(coordinator.client.isHostIssued, isFalse);
    expect(reservation.isPromoted, isFalse);
  });

  test(
      'Stage2 real ended child lease permits pending removal on actual restart',
      () async {
    final first = await boot(staleSessionOf: 'uid-x');
    await signIn('uid-x');
    final replicasStore = ReplicaStore(appSupportDirectory: support.path);
    final location = await replicasStore.locationFor('uid-x');
    final hash = await replicasStore.uidHash('uid-x');
    await first.accountScope.lock();
    AppDatabase.dropProcessLiveness(location);
    final helper = File(p.join(support.path, 'ended_helper.dart'))
      ..writeAsStringSync(r'''import 'dart:io';
void main(List<String> a) {
  final lock = File(a[0]).openSync(mode: FileMode.write);
  lock.lockSync(FileLock.exclusive);
  Directory(a[1]).createSync();
  File('${a[1]}/ended.lease').writeAsStringSync('child-token\n$pid\nchild-instance');
  exit(0);
}
''');
    final child = await Process.run(
        'dart', [helper.path, location.plockPath, location.leaseDir]);
    expect(child.exitCode, 0, reason: '${child.stderr}');
    expect(File(p.join(location.leaseDir, 'ended.lease')).existsSync(), isTrue);
    storage.data[RemoveDataFlow.barrierKey] =
        jsonEncode({'uid': 'uid-x', 'uidHash': hash, 'revoke': true});
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    final from = storage.attempts.length;
    final restarted = await boot(staleSessionOf: 'uid-x');
    expect(storage.data.containsKey(RemoveDataFlow.barrierKey), isFalse);
    expect(storage.data[RemoveDataFlow.revokedKey], contains('uid-x'));
    expect(Directory(location.directory).existsSync(), isFalse);
    expect(storage.data.containsKey(location.keyName), isFalse);
    expect(restarted.accountScope.activeUid, isNull);
    expect(session.status, isNot(SessionStatus.authenticated));
    expect(keyWrites(from), isEmpty);
  });

  test(
      'Stage1 uncleared revoked marker blocks actual bootstrap legacy adoption',
      () async {
    storage.data[RemoveDataFlow.revokedKey] = '["uid-x"]';
    storage.data[kMarkerKey] = 'uid-x';
    final legacy = File(p.join(support.path, 'money_companion.sqlite'))
      ..writeAsBytesSync(List<int>.filled(64, 7));
    storage.gate = (op, key) async {
      if (op == 'read' && key == kMarkerKey) storage.data[kMarkerKey] = 'uid-x';
    };
    final from = storage.attempts.length;
    final runner = await boot();
    storage.gate = null;
    expect(legacy.existsSync(), isTrue);
    expect(replicaDirs(), isEmpty);
    expect(keyWrites(from), isEmpty);
    expect(
        storage.attempts
            .skip(from)
            .where((a) => a.startsWith('write:qirsh.replicas.v1=')),
        isEmpty);
    expect(runner.accountScope.activeUid, isNull);
    expect(session.status, isNot(SessionStatus.authenticated));
    expect(
        queue.calls
            .where((c) => c.startsWith('begin') || c.startsWith('finish')),
        isEmpty);
  });

  test(
      'R2-7 Remove data from an authenticated user through the real startup: '
      'revalidation and auth events during the removal attempt NOTHING for X; '
      'a restart with the stale session stays signed out; a fresh explicit '
      'login creates exactly one replica', () async {
    var runner = await boot(staleSessionOf: 'uid-x');
    debugPrint('IT-STEP before: await signIn(uid-x);');
    await signIn('uid-x');
    expect(session.status, SessionStatus.authenticated);
    expect(replicaDirs(), hasLength(1));
    expect(runner.accountScope.activeUid, 'uid-x');

    // Pause the removal after the scope swap, while the stale session is live.
    final hold = storage.holdOnce(
        (op, key) => op == 'delete' && key.startsWith(kConsentAskedKeyPrefix));
    final from = storage.attempts.length;
    final removal = session.removeDataFromDevice();
    debugPrint('IT-STEP before: await hold.reached.future;');
    await hold.reached.future;
    expect(runner.accountScope.activeUid, isNull,
        reason: 'the signed-out scope is published: the root remounts');
    final client = await F2Fixture.liveClient('uid-x');
    expect(await session.revalidateForShell(client), isFalse);
    await session.revalidateSupabaseSessionOnResume(client);
    await client.auth.refreshSession(); // tokenRefreshed on the bound listener
    await Future<void>.delayed(const Duration(milliseconds: 50));
    debugPrint('IT-STEP before: hold.release.complete();');
    hold.release.complete();
    await removal;
    await session.drainAdmissions();

    expect(admissionWrites(from), isEmpty,
        reason: 'ZERO attempted marker/generation/key/registry writes');
    expect(replicaDirs(), isEmpty);
    expect(
        storage.data.keys.where((k) => k.startsWith('qirsh.db_key.')), isEmpty);
    expect(storage.data.containsKey(kMarkerKey), isFalse);
    expect(session.status, isNot(SessionStatus.authenticated));
    expect(queue.calls, containsAllInOrder(['begin:uid-x', 'finish:uid-x']));

    // Restart with the stale persisted Supabase session of X.
    for (final r in [...runners]) {
      await r.accountScope.lock();
    }
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    final afterRemoval = storage.attempts.length;
    debugPrint('IT-STEP before: runner = await boot(staleSessionOf: uid');
    runner = await boot(staleSessionOf: 'uid-x');
    await session
        .revalidateSupabaseSessionOnResume(await F2Fixture.liveClient('uid-x'));
    await session.drainAdmissions();
    expect(admissionWrites(afterRemoval), isEmpty);
    expect(replicaDirs(), isEmpty);
    expect(runner.accountScope.activeUid, isNull);
    expect(session.status, isNot(SessionStatus.authenticated));

    // A fresh explicit login succeeds exactly once and creates one replica.
    debugPrint('IT-STEP before: final beforeLogin = storage.attempts.len');
    final beforeLogin = storage.attempts.length;
    await signIn('uid-x');
    expect(replicaDirs(), hasLength(1));
    expect(keyWrites(beforeLogin), hasLength(1));
    expect(runner.accountScope.activeUid, 'uid-x');
    expect(storage.data.containsKey(RemoveDataFlow.revokedKey), isFalse,
        reason: 'the explicit admission committed and lifted the revocation');
  });

  for (final (label, read) in [
    ('a native barrier of unknown uid', _present),
    ('a MALFORMED native barrier answer', _malformed),
  ]) {
    test(
        'R2-7 $label blocks the real launch: no legacy adoption, no auth '
        'bind/reconcile, no replica opened, nothing routed authenticated',
        () async {
      var runner = await boot(staleSessionOf: 'uid-y');
      await signIn('uid-y');
      expect(session.status, SessionStatus.authenticated);
      final hashDirs = replicaDirs();
      final yLocation = await runner.accountScope.store.locationFor('uid-y');
      final yKey = storage.data[yLocation.keyName];
      // A legacy database appears, and the native barrier becomes unreadable.
      final legacy = File(p.join(support.path, 'money_companion.sqlite'))
        ..writeAsBytesSync(List<int>.filled(64, 7));
      queue.barrier = read();
      for (final r in [...runners]) {
        await r.accountScope.lock();
      }
      session.debugResetAdmissionState();
      session.configureRemoveData(null);
      session.configureAccountScope(null);
      final from = storage.attempts.length;
      queue.calls.clear();

      runner = await boot(staleSessionOf: 'uid-y');
      await session.revalidateSupabaseSessionOnResume(
          await F2Fixture.liveClient('uid-y'));
      await session.drainAdmissions();

      expect(legacy.existsSync(), isTrue,
          reason: 'the legacy file was neither adopted nor quarantined');
      expect(Directory(p.join(replicas().path, '_quarantine')).existsSync(),
          isFalse);
      expect(runner.accountScope.activeUid, isNull,
          reason: 'only the signed-out scope is opened');
      expect(replicaDirs(), hashDirs, reason: 'no replica created or removed');
      expect(session.status, isNot(SessionStatus.authenticated));
      expect(admissionWrites(from), isEmpty);
      expect(
          queue.calls
              .where((c) => c.startsWith('begin') || c.startsWith('finish')),
          isEmpty,
          reason: 'no uid is guessed from the barrier');
      expect(storage.data[kMarkerKey], 'uid-y',
          reason: 'the marker is left alone, just not opened');

      // Control: once the barrier reads cleanly the same launch proceeds.
      queue.barrier = const CaptureRemovalBarrierRead.absent();
      for (final r in [...runners]) {
        await r.accountScope.lock();
      }
      session.debugResetAdmissionState();
      session.configureRemoveData(null);
      session.configureAccountScope(null);
      // Fixture teardown locked Y. Restore its pre-barrier active state so
      // an owned leftover is not mistaken for a pending legacy adoption.
      await runners.last.accountScope.store
          .setState('uid-y', ReplicaState.active);
      runner = await boot(staleSessionOf: 'uid-y');
      expect(legacy.existsSync(), isTrue,
          reason:
              'active non-adoptPending Y retains unrelated legacy leftover');
      expect(replicaDirs(), hashDirs);
      expect(File(yLocation.dbPath).existsSync(), isTrue);
      expect(storage.data[yLocation.keyName], yKey);
      expect(runner.accountScope.activeUid, 'uid-y');
    });
  }
  });
}

CaptureRemovalBarrierRead _present() => CaptureRemovalBarrierRead.parse(
    {'nonce': 'n', 'uidHash': 'h', 'startedAt': 't'});
CaptureRemovalBarrierRead _malformed() =>
    CaptureRemovalBarrierRead.parse({'nonce': 1});

/// The genuine seed SDK's serialized session, read by the runner's observing
/// store during its own first initialization. Writes/removals stay consistent
/// with later SDK recovery reads; this storage supplies no admission authority.
class _SenderBootstrapStorage extends LocalStorage {
  _SenderBootstrapStorage(this._session, {required this.onInitialize});
  String? _session;
  final void Function() onInitialize;
  @override
  Future<void> initialize() async => onInitialize();
  @override
  Future<bool> hasAccessToken() async => _session != null;
  @override
  Future<String?> accessToken() async => _session;
  @override
  Future<void> persistSession(String persistSessionString) async =>
      _session = persistSessionString;
  @override
  Future<void> removePersistedSession() async => _session = null;
}

void _senderBootstrapConfigured() {
  const exactConfig = String.fromEnvironment('SUPABASE_ENV') == 'local' &&
      String.fromEnvironment('SUPABASE_URL') == 'https://example.supabase.co' &&
      String.fromEnvironment('SUPABASE_ANON_KEY') == 'anon';
  group('configured real sender bootstrap receivers', () {
    setUpAll(notifications.AndroidFlutterLocalNotificationsPlugin.registerWith);
    for (final schedule in ['cold', 'same-uid', 'onboarding']) {
      test('$schedule actual publication owns sender work and strict completion', () async {
        const uid = 'uid-a';
        final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final previousGate = CloudEgressGate.instance;
        final previousPlugin = FlutterLocalNotificationsPlatform.instance;
        final restore = AccountFenceAuthority.replacePersistenceForTest();
        final gate = TestEgress(seedOn: true).install();
        final databases = <AppDatabase>{};
        final requests = <http.Request>[]; final unknown = <String>[];
        final dispatchProofs = <Map<String, Object?>>[];
        List<Map<String, Object?>>? expectedBody;
        final channelCalls = <String>[];
        final firstSend = Completer<void>(); final secondSend = Completer<void>();
        final followingPull = Completer<void>();
        Map<String, Object?>? successorAck;
        final releaseOld = Completer<void>();
        var sends = 0; var runnerTracking = false;
        Supabase? ownedSdk; SupabaseClient? seedClient;
        F2Fixture? fixture; BootstrapRunner? runner; Timer? frames;
        Future<void>? identity;
        void rememberSeed() { final db = fixture?.host.current?.database; if (db != null) databases.add(db); }
        void rememberRunner() { final db = runner?.accountScope.current?.database; if (db != null) databases.add(db); }
        final channels = <String>['plugins.flutter.io/path_provider', 'mali/device_timezone',
          'dexterous.com/flutter/local_notifications', 'money_companion/native_capture'];
        try {
          // Each case models a fresh process. An externally initialized SDK is
          // never accepted as proof; only the runner may initialize this one.
          Supabase? existingSdk;
          try { existingSdk = Supabase.instance; } on AssertionError { /* not initialized */ }
          expect(existingSdk, isNull);
          BootstrapRunner.debugResetSdkInitializationLatch();
          SharedPreferences.setMockInitialValues({});
          fixture = await F2Fixture.create(afterWithdraw: () async {});
          fixture.host.addListener(rememberSeed); rememberSeed();
          messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (call) async {
            channelCalls.add('path:${call.method}');
            if (const {'getApplicationSupportDirectory', 'getTemporaryDirectory', 'getApplicationDocumentsDirectory'}
                .contains(call.method)) {
              return fixture!.support.path;
            }
            unknown.add('path:${call.method}'); throw PlatformException(code: 'unexpected');
          });
          messenger.setMockMethodCallHandler(const MethodChannel('mali/device_timezone'), (call) async {
            channelCalls.add('timezone:${call.method}');
            if (call.method == 'getLocalTimezone') return 'UTC';
            unknown.add('timezone:${call.method}'); throw PlatformException(code: 'unexpected');
          });
          messenger.setMockMethodCallHandler(const MethodChannel('dexterous.com/flutter/local_notifications'), (call) async {
            channelCalls.add('notifications:${call.method}');
            if (call.method == 'initialize') return true;
            if (call.method == 'getNotificationAppLaunchDetails') return {'notificationLaunchedApp': false};
            if (call.method == 'pendingNotificationRequests') return <Object>[];
            if (call.method == 'cancelAll') return null;
            unknown.add('notifications:${call.method}'); throw PlatformException(code: 'unexpected');
          });
          messenger.setMockMethodCallHandler(const MethodChannel('money_companion/native_capture'), (call) async {
            channelCalls.add('capture:${call.method}');
            if (call.method == 'captureCapabilities') return '{}';
            if (call.method == 'setCaptureBackendConfig') return null;
            unknown.add('capture:${call.method}'); throw PlatformException(code: 'unexpected');
          });
          notifications.AndroidFlutterLocalNotificationsPlugin.registerWith();
          final innerHttp = MockClient((request) async {
            requests.add(request);
            final path = request.url.path;
            Object? body;
            if (request.method == 'POST' && path == '/rest/v1/sender_bank_mappings') {
              final sent = (jsonDecode(request.body) as List).cast<Map<String, dynamic>>();
              final cap = fixture!.session.captureLocalWorkAuthority();
              dispatchProofs.add({'scope': runner?.accountScope.current,
                'capUid': cap?.uid, 'capEpoch': cap?.epoch, 'current': cap?.isCurrent,
                'db': runner?.accountScope.current?.database});
              final mutationIndex = ++sends;
              if (!firstSend.isCompleted) firstSend.complete();
              if (sends == 2 && !secondSend.isCompleted) secondSend.complete();
              if (schedule == 'same-uid' && sends == 1) await releaseOld.future;
              body = [for (final row in sent) {...row,
                'id': '11223344-5566-4788-8899-aabbccddeeff',
                'updated_at': mutationIndex == 1 ? '2026-10-20T10:00:00Z' : '2026-10-20T11:00:00Z'}];
            } else if (request.method == 'GET' && path == '/rest/v1/sender_bank_mappings') {
              if (!followingPull.isCompleted) followingPull.complete();
              body = <Object>[];
            } else if (request.method == 'GET' && path == '/rest/v1/profiles') {
              body = {'onboarding_completed_at': schedule == 'onboarding' ? null : '2026-10-01T00:00:00Z'};
            } else if (request.method == 'PATCH' && path == '/rest/v1/profiles') {
              body = null;
            } else if (request.method == 'POST' && path == '/rest/v1/rpc/record_metric') {
              body = null;
            } else if (request.method == 'POST' && path == '/rest/v1/rpc/qirsh_server_capabilities') {
              body = {'sync_seq': false};
            } else if (request.method == 'POST' && path == '/rest/v1/rpc/mark_onboarding_completed') {
              body = null;
            } else { unknown.add('${request.method} $path ${request.body}'); body = {'code': 'unexpected'}; }
            return http.Response(jsonEncode(body), unknown.isEmpty ? 200 : 400,
                headers: {'content-type': 'application/json'}, request: request);
          });
          seedClient = await F2Fixture.liveClient(uid);
          fixture.session.configureAccountScope(fixture.host);
          await fixture.session.setIdentity(method: 'google', email: '$uid@example.com', userId: uid);
          if (schedule != 'onboarding') {
            await fixture.session.finishOnboarding(client: seedClient);
          }
          final seedSession = seedClient.auth.currentSession!;
          expect(seedSession.user.id, uid);
          expect(seedSession.isExpired, isFalse);
          final sdkStorage = _SenderBootstrapStorage(jsonEncode(seedSession.toJson()),
              // This callback runs from the actual SDK storage initialization,
              // after the SDK object exists, even if later initialization fails.
              onInitialize: () => ownedSdk ??= Supabase.instance);
          await UserActivityService.waitPendingActivityWork();
          final seedDB = fixture.host.current!.database;
          final settings = DriftUserSettingsRepository(seedDB);
          await settings.saveSettings((await settings.getSettings()).copyWith(cloudConsentState: ConsentState.accepted));
          final repo = DriftSenderBankMappingRepository(seedDB);
          final mapping = await repo.saveSuggestion(const SenderBankMappingDraft(senderId: 'bootstrap-bank',
              suggestedBankName: 'Bank', suggestedCountry: 'SA', confidence: .9));
          await repo.confirm(mappingId: mapping.id, bankKey: 'bank');
          final seeded = (await seedDB.customSelect('SELECT * FROM sender_bank_mappings;').getSingle()).data;
          expectedBody = [{
            'user_id': uid,
            for (final key in ['sender_id', 'normalized_sender_id', 'bank_key', 'suggested_bank_name',
              'suggested_country', 'confidence', 'reason', 'status', 'source', 'first_seen_at',
              'last_seen_at', 'confirmed_at', 'rejected_at', 'rejection_expires_at', 'created_at', 'deleted_at']) key: seeded[key],
            if (seeded['accepted_by'] != null) 'accepted_by': seeded['accepted_by'],
          }];
          await fixture.session.drainAdmissions();
          await fixture.host.detach(); await fixture.host.current!.database.close();
          fixture.session.configureAccountScope(null); fixture.session.configureRemoveData(null);
          expect(databases.every((db) => db.lifecycleState == DatabaseLifecycleState.closed), isTrue);
          final binding = TestWidgetsFlutterBinding.instance;
          frames = Timer.periodic(const Duration(milliseconds: 20), (_) {
            binding.scheduleFrame(); binding.handleBeginFrame(Duration.zero); binding.handleDrawFrame();
          });
          runner = BootstrapRunner(
            debugSdk: BootstrapSdkTestConfig(url: 'https://example.supabase.co',
                innerStorage: sdkStorage, innerHttp: innerHttp),
            debugAfterWithdraw: () async {}, debugStorageEvent: (_) {
            if (!runnerTracking) {
              runner!.accountScope.addListener(rememberRunner); runnerTracking = true;
            }
            rememberRunner();
          })..captureQueue = _Queue();
          await runner.run();
          expect(ownedSdk, same(Supabase.instance));
          expect(ownedSdk!.isInitialized, isTrue);
          expect(ownedSdk!.client.auth.currentSession!.user.id, uid);
          if (!runnerTracking) { runner.accountScope.addListener(rememberRunner); runnerTracking = true; }
          rememberRunner();
          expect(runner.accountScope.activeUid, uid);
          if (schedule == 'onboarding') {
            expect(fixture.session.status, SessionStatus.needsOnboarding);
            expect(sends, 0);
            await fixture.session.finishOnboarding();
          }
          await firstSend.future.timeout(const Duration(seconds: 10));
          final original = fixture.session.captureLocalWorkAuthority()!;
          if (schedule == 'same-uid') {
            identity = fixture.session.setIdentity(method: 'google', email: '$uid@example.com', userId: uid);
            await identity;
            expect(original.isCurrent, isFalse);
            await secondSend.future.timeout(const Duration(seconds: 10));
            await followingPull.future.timeout(const Duration(seconds: 10));
            successorAck = (await runner.accountScope.current!.database.customSelect(
                'SELECT * FROM sender_bank_mappings;').getSingle()).data;
            expect(successorAck['sync_status'], 'synced');
            expect(successorAck['server_updated_at'], '2026-10-20T11:00:00Z');
            releaseOld.complete();
          }
          // The barrier observes actual send/health/pull completion, not arrival.
          await runner.waitPendingSenderBankMappingSync();
          await runner.waitPendingBootstrapWork();
          await UserActivityService.waitPendingActivityWork();
          // A same-state notification is not a new readiness transition.
          final sentBeforeNotify = sends;
          final senderBeforeNotify = requests.where((r) => r.url.path == '/rest/v1/sender_bank_mappings' ||
              r.url.path == '/rest/v1/rpc/qirsh_server_capabilities').toList();
          final ackBeforeNotify = (await runner.accountScope.current!.database.customSelect(
              'SELECT * FROM sender_bank_mappings;').getSingle()).data;
          fixture.session.notifyListeners();
          await fixture.session.drainAdmissions();
          await runner.waitPendingSenderBankMappingSync();
          expect(requests.where((r) => r.url.path == '/rest/v1/sender_bank_mappings' ||
              r.url.path == '/rest/v1/rpc/qirsh_server_capabilities'), senderBeforeNotify);
          expect((await runner.accountScope.current!.database.customSelect(
              'SELECT * FROM sender_bank_mappings;').getSingle()).data, ackBeforeNotify);
          await runner.shutdownSenderBankMappingSync();
          expect(identical(runner.shutdownSenderBankMappingSync(), runner.shutdownSenderBankMappingSync()), isTrue);
          expect(sends, schedule == 'same-uid' ? 2 : 1);
          expect(sends, sentBeforeNotify);
          final actualDB = runner.accountScope.current!.database;
          final row = await actualDB.customSelect('SELECT sync_status FROM sender_bank_mappings;').getSingle();
          expect(row.read<String>('sync_status'), 'synced');
          if (successorAck != null) {
            expect((await actualDB.customSelect('SELECT * FROM sender_bank_mappings;').getSingle()).data, successorAck);
          }
          expect(requests.where((r) => r.method == 'GET' && r.url.path == '/rest/v1/sender_bank_mappings'), hasLength(1));
          for (final request in requests) {
            final path = request.url.path;
            final body = request.body.isEmpty ? null : jsonDecode(request.body);
            if (path == '/rest/v1/sender_bank_mappings' && request.method == 'POST') {
              expect(request.url.queryParameters['on_conflict'], 'user_id,normalized_sender_id');
              expect(request.url.queryParameters['select'], '*');
              expect(request.headers['prefer'], contains('return=representation'));
              expect(body, expectedBody); expect((body as List).single['user_id'], uid);
              expect(body.single['normalized_sender_id'], 'BOOTSTRAPBANK');
              expect(body.single['status'], 'confirmed');
            } else if (path == '/rest/v1/rpc/record_metric') {
              expect(body, {'p_metric_key': 'app_open', 'p_dimension': null});
            } else if (path == '/rest/v1/rpc/qirsh_server_capabilities' || path == '/rest/v1/rpc/mark_onboarding_completed') {
              expect(body, isNull);
            } else if (path == '/rest/v1/profiles' && request.method == 'PATCH') {
              expect(request.url.queryParameters['id'], 'eq.$uid');
              expect((body as Map).keys, ['last_seen_at']);
              expect(DateTime.parse(body['last_seen_at'] as String).isUtc, isTrue);
            } else if (path == '/rest/v1/profiles') {
              expect(request.url.queryParameters['select'], 'onboarding_completed_at');
              expect(request.url.queryParameters['id'], 'eq.$uid');
            }
          }
          expect(dispatchProofs, hasLength(sends));
          for (final proof in dispatchProofs) {
            expect(proof['capUid'], uid); expect(proof['current'], isTrue);
            expect(proof['capEpoch'], isA<int>()); expect(proof['db'], isNotNull);
            final scope = proof['scope'] as AccountScope;
            expect(scope.uid, uid); expect(identical(scope.database, proof['db']), isTrue);
          }
          if (schedule == 'same-uid') {
            expect(dispatchProofs[1]['capEpoch'], isNot(dispatchProofs[0]['capEpoch']));
          }
          expect(unknown, isEmpty);
          expect(channelCalls, isNotEmpty);
          expect(await gate.gate.permits(), isTrue);
        } catch (error, stack) {
          debugPrint('configured sender primary: $error\n$stack');
          rethrow;
        } finally {
          // Keep strict cleanup failures observable while still releasing every
          // owned resource if setup or the real SDK initialization failed early.
          final cleanupFailures = <(Object, StackTrace)>[];
          Future<void> cleanup(FutureOr<void> Function() action) async {
            try { await action(); }
            catch (error, stack) { cleanupFailures.add((error, stack)); }
          }
          ownedSdk?.client.auth.stopAutoRefresh();
          if (!releaseOld.isCompleted) releaseOld.complete();
          await cleanup(() async { await identity; });
          if (runner != null) {
            await cleanup(runner.shutdownSenderBankMappingSync);
            await cleanup(fixture!.session.drainAdmissions);
            await cleanup(runner.waitPendingBootstrapWork);
            await cleanup(UserActivityService.waitPendingActivityWork);
            // No replacement scope is opened solely to clean up a runner whose
            // first SDK initialization failed before publishing any database.
            if (runner.accountScope.current != null) {
              await cleanup(() async {
                await runner!.accountScope.lock(); rememberRunner();
              });
            }
            ownedSdk?.client.auth.stopAutoRefresh();
            await cleanup(runner.waitPendingBootstrapWork);
            await cleanup(UserActivityService.waitPendingActivityWork);
            await cleanup(() async { await runner!.accountScope.current?.database.close(); });
            await cleanup(runner.accountScope.dispose);
          }
          ownedSdk?.client.auth.stopAutoRefresh();
          if (fixture != null) {
            fixture.session.configureAccountScope(null); fixture.session.configureRemoveData(null);
            fixture.session.configureCaptureOwnerClear(null); fixture.session.configureCaptureOwnerPublish(null);
            await cleanup(() {
              expect(databases.every((db) => db.lifecycleState == DatabaseLifecycleState.closed), isTrue);
            });
            await cleanup(() async {
              expect(await AccountFenceAuthority.shared.initialize(), isTrue);
              expect(AccountFenceAuthority.shared.store.ready, isTrue);
            });
            await cleanup(fixture.dispose); rememberSeed();
            await cleanup(() {
              expect(databases.every((db) => db.lifecycleState == DatabaseLifecycleState.closed), isTrue);
            });
          }
          frames?.cancel();
          await cleanup(() async { await seedClient?.dispose(); });
          await cleanup(() async { await ownedSdk?.dispose(); });
          await cleanup(() { expect(unknown, isEmpty); });
          await cleanup(restore);
          CloudEgressGate.instance = previousGate;
          FlutterLocalNotificationsPlatform.instance = previousPlugin;
          for (final channel in channels) { messenger.setMockMethodCallHandler(MethodChannel(channel), null); }
          for (final failure in cleanupFailures) {
            debugPrint('configured sender cleanup: ${failure.$1}\n${failure.$2}');
          }
          if (cleanupFailures.isNotEmpty) {
            Error.throwWithStackTrace(cleanupFailures.first.$1, cleanupFailures.first.$2);
          }
        }
      });
    }
    // V1-054: the removal journeys of 'original removal integration controls',
    // nested here so they share this group's single define-gated skip site.
    _configuredRemovalJourneys();
  }, skip: !exactConfig ? 'Requires exact synthetic local/example/anon defines; no configured coverage otherwise.' : false);
}

/// A live (unexpired) SDK session of [uid] as the SDK persists it, issued by
/// [_configuredUrl] so the coordinated session store accepts it.
String _configuredSession(String uid) => jsonEncode(_configuredSessionJson(uid));

Map<String, Object> _configuredSessionJson(String uid) {
  String b64(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  return {
    'access_token':
        '${b64({'alg': 'none'})}.${b64({'sub': uid, 'exp': exp, 'iss': '$_configuredUrl/auth/v1'})}.s',
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-$uid',
    'user': {
      'id': uid,
      'email': '$uid@example.com',
      'app_metadata': <String, Object>{},
      'user_metadata': <String, Object>{},
      'aud': 'authenticated',
      'created_at': '2026-10-01T00:00:00Z',
    },
    'expires_at': exp,
  };
}

const _configuredUrl = 'https://example.supabase.co';

class _ConfiguredNoRefresh implements RefreshChannel {
  @override
  bool get sent => false;
  @override
  Future<void> open() async => throw StateError('no network in this test');
  @override
  Future<RefreshHttpResult> send(String refreshToken) =>
      throw StateError('no network in this test');
  @override
  void cancel() {}
  @override
  void close() {}
  @override
  Future<void> quiesced() async {}
}

/// The configured-build port (V1-054) of the journeys in 'original removal
/// integration controls'. Startup runs the REAL `Supabase.initialize` and the
/// production coordinated (ASR) session path: an [AuthCoordinator] over a
/// [SessionStore] whose Keychain is an in-memory fake (the native Keychain
/// channel cannot run in a host test). The stale session of X is the SDK
/// session the app persisted before (imported once, then re-served from the
/// store on every restart). Every restart is a new process: the SDK and the
/// coordinator of the previous one are disposed.
void _configuredRemovalJourneys() {
  group('removal journeys', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late Directory support;
    late RecordingSecureStorage storage;
    late _Queue queue;
    late FakeKeychain keychain;
    late FakeLegacy legacy;
    final session = AppSession.instance;
    final runners = <BootstrapRunner>[];
    final coordinators = <AuthCoordinator>[];
    final exchanges = <String>[];
    String? exchangeUid;
    Timer? frames;

    Future<void> endProcess() async {
      for (final c in coordinators) {
        c.dispose();
      }
      coordinators.clear();
      AuthCoordinator.active = null;
      try {
        if (Supabase.instance.isInitialized) await Supabase.instance.dispose();
      } catch (_) {}
      BootstrapRunner.debugResetSdkInitializationLatch();
    }

    setUp(() async {
      support = Directory.systemTemp.createTempSync('bootstrap_cfg_it_');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
      storage = RecordingSecureStorage().install();
      FlutterLocalNotificationsPlatform.instance = _NoNotifications();
      SharedPreferences.setMockInitialValues({});
      CloudEgressGate.instance = CloudEgressGate();
      queue = _Queue();
      keychain = FakeKeychain();
      legacy = FakeLegacy();
      exchanges.clear();
      exchangeUid = null;
      await endProcess();
      session.debugResetAdmissionState();
      session.configureRemoveData(null);
      session.configureAccountScope(null);
      await session.wipeAndReset();
      final binding = TestWidgetsFlutterBinding.instance;
      frames = Timer.periodic(const Duration(milliseconds: 20), (_) {
        binding.scheduleFrame();
        binding.handleBeginFrame(Duration.zero);
        binding.handleDrawFrame();
      });
    });

    tearDown(() async {
      for (final r in [...runners]) {
        try {
          await r.accountScope.lock();
          r.accountScope.dispose();
        } catch (_) {}
      }
      frames?.cancel();
      runners.clear();
      await endProcess();
      CloudEgressGate.instance = CloudEgressGate();
      session.configureRemoveData(null);
      session.configureAccountScope(null);
      session.configureCaptureOwnerClear(null);
      support.deleteSync(recursive: true);
    });

    BootstrapSdkTestConfig sdk() => BootstrapSdkTestConfig(
          url: _configuredUrl,
          // No backend: the explicit provider exchange returns a fresh session
          // of [exchangeUid]; every other request is answered locally, empty.
          innerHttp: MockClient((request) async {
            if (request.url.path == '/auth/v1/token' &&
                request.url.queryParameters['grant_type'] == 'id_token') {
              exchanges.add(exchangeUid!);
              return http.Response(jsonEncode(_configuredSessionJson(exchangeUid!)), 200,
                  headers: {'content-type': 'application/json'});
            }
            return http.Response('[]', 200,
                headers: {'content-type': 'application/json'});
          }),
          authCoordinator: () async {
            final c = AuthCoordinator(
                store: SessionStore(
                  keychain: keychain,
                  files: SessionFiles(support),
                  origin: Uri.parse(_configuredUrl),
                  legacy: legacy,
                  localInstallDataPresent: () async => true,
                ),
                gate: CloudEgressGate.instance,
                channelFactory: _ConfiguredNoRefresh.new);
            coordinators.add(c);
            return c;
          },
        );

    /// A new process. [staleSessionOf]: the SDK session of that uid is
    /// persisted (imported on the first launch; re-served by the store after).
    Future<BootstrapRunner> boot({String? staleSessionOf}) async {
      await endProcess();
      if (staleSessionOf != null && keychain.items.isEmpty) {
        legacy.value = _configuredSession(staleSessionOf);
      }
      final runner = BootstrapRunner(debugSdk: sdk())..captureQueue = queue;
      runners.add(runner);
      await runner.run();
      if (staleSessionOf != null) {
        expect(Supabase.instance.client.auth.currentSession?.user.id,
            staleSessionOf,
            reason: 'the configured SDK holds the persisted session');
      }
      return runner;
    }

    Directory replicas() => Directory(p.join(support.path, 'replicas'));
    List<String> replicaDirs() => replicas().existsSync()
        ? [
            for (final e in replicas().listSync())
              if (e is Directory && !p.basename(e.path).startsWith('_'))
                p.basename(e.path),
          ]
        : [];
    List<String> keyWrites(int from) => [
          for (final a in storage.attempts.skip(from))
            if (a.startsWith('write:qirsh.db_key.')) a,
        ];
    List<String> admissionWrites(int from) => [
          for (final a in storage.attempts.skip(from))
            if (a.startsWith('write:$kMarkerKey=') ||
                a.startsWith('write:$kGenerationKey=') ||
                a.startsWith('write:qirsh.db_key.') ||
                (a.startsWith('write:qirsh.replicas.v1=') &&
                    a != 'write:qirsh.replicas.v1={}'))
              a,
        ];

    /// An explicit sign-in through the production configured path: attempt
    /// zone -> gate account control -> coordinator exchange -> admission.
    Future<void> signIn(String uid) async {
      final client = Supabase.instance.client;
      final attempt = session.beginAuthAttempt();
      final coord = AuthCoordinator.active!;
      exchangeUid = uid;
      await AuthAttemptZone.run(
          attempt.intent,
          () => CloudEgressGate.instance.runAccountControl(
              AccountControlOp.signIn,
              () => coord.explicitExchange(
                  attempt.intent,
                  () => client.auth.signInWithIdToken(
                      provider: OAuthProvider.google,
                      idToken: 'google-id-token')),
              attempt: true));
      expect(exchanges.last, uid);
      await session.setIdentity(
        method: 'google',
        email: '$uid@example.com',
        userId: uid,
        attempt: attempt,
        sessionCurrent: () =>
            client.auth.currentSession?.user.id == uid &&
            !(client.auth.currentSession?.isExpired ?? true),
      );
      await session.finishOnboarding();
    }

    test(
        'O-H1: one inert coordinator exists before any recovery or opener and '
        'is reused by retries and later runners', () async {
      // A fresh process: the configured group's earlier tests ran in this
      // isolate and left the process-retained coordinator behind.
      DatabaseAccessBroker.debugResetForTest();
      final events = <String>[];
      String? stepAtCreation = 'unset';
      late BootstrapRunner first;
      first = BootstrapRunner(
          debugSdk: sdk(),
          debugCoordinatorEvent: (event) {
            events.add(event);
            if (event == 'coordinator') stepAtCreation = first.lastStep;
          })
        ..captureQueue = queue;
      runners.add(first);
      await first.run();
      expect(events.first, 'coordinator',
          reason: 'before the first recovery, session load or Drift opener');
      expect(stepAtCreation, isNull, reason: 'no bootstrap step had started');
      final coordinator = first.debugCoordinator;
      expect(coordinator, isNotNull);
      expect(coordinator!.isInert, isTrue);
      expect(coordinator.mode, DatabaseAccessMode.closed);
      expect(coordinator.client.isHostIssued, isFalse);
      expect(DatabaseAccessBroker.discover(), isNotNull);

      // Retry of the retained runner: no replacement registration.
      await first.run();
      expect(identical(first.debugCoordinator, coordinator), isTrue);
      expect(events.where((e) => e == 'coordinator'), hasLength(1));

      // A rebuilt runner reuses the process-retained coordinator.
      await first.accountScope.lock();
      final second =
          BootstrapRunner(debugSdk: sdk(), debugCoordinatorEvent: events.add)
            ..captureQueue = queue;
      runners.add(second);
      await second.run();
      expect(identical(second.debugCoordinator, coordinator), isTrue);
      expect(events.where((e) => e == 'coordinator'), hasLength(1));
      expect(events.where((e) => e == 'coordinator-reused'), hasLength(1));
      expect(coordinator.mode, DatabaseAccessMode.closed,
          reason: 'creating it granted nothing');
      expect(coordinator.client.isHostIssued, isFalse);
    });

    test(
        'O-H3: the real cold launch reserves its primary open as a '
        'launch-specific private reservation that grants nothing', () async {
      final first = await boot(staleSessionOf: 'uid-launch');
      await signIn('uid-launch');
      await first.accountScope.detach(); // the process dies while `active`
      session.debugResetAdmissionState();
      session.configureRemoveData(null);
      session.configureAccountScope(null);
      final restarted = await boot(staleSessionOf: 'uid-launch');
      expect(restarted.accountScope.activeUid, 'uid-launch',
          reason: 'the existing replica was opened at launch');
      final coordinator = restarted.debugCoordinator!;
      final reservation = session.debugDatabaseOpenReservation;
      expect(reservation, isNotNull);
      expect(reservation!.kind, DatabaseReservationKind.coldLaunchPrimary);
      expect(reservation.uid, 'uid-launch');
      expect(reservation.hasOpened, isTrue);
      expect(
          reservation.ownsDatabase(restarted.accountScope.current!.database),
          isTrue,
          reason: 'the real primary handle is the tracked one');
      expect(coordinator.pendingOpens, 0);
      expect(coordinator.openHolders, greaterThanOrEqualTo(1));
      expect(coordinator.mode, DatabaseAccessMode.closed);
      expect(coordinator.client.isHostIssued, isFalse);
      expect(reservation.isPromoted, isFalse);
    });

    test(
        'Stage2 real ended child lease permits pending removal on actual '
        'restart', () async {
      final first = await boot(staleSessionOf: 'uid-x');
      await signIn('uid-x');
      final replicasStore = ReplicaStore(appSupportDirectory: support.path);
      final location = await replicasStore.locationFor('uid-x');
      final hash = await replicasStore.uidHash('uid-x');
      await first.accountScope.lock();
      AppDatabase.dropProcessLiveness(location);
      final helper = File(p.join(support.path, 'ended_helper.dart'))
        ..writeAsStringSync(r'''import 'dart:io';
void main(List<String> a) {
  final lock = File(a[0]).openSync(mode: FileMode.write);
  lock.lockSync(FileLock.exclusive);
  Directory(a[1]).createSync();
  File('${a[1]}/ended.lease').writeAsStringSync('child-token\n$pid\nchild-instance');
  exit(0);
}
''');
      final child = await Process.run(
          'dart', [helper.path, location.plockPath, location.leaseDir]);
      expect(child.exitCode, 0, reason: '${child.stderr}');
      expect(
          File(p.join(location.leaseDir, 'ended.lease')).existsSync(), isTrue);
      storage.data[RemoveDataFlow.barrierKey] =
          jsonEncode({'uid': 'uid-x', 'uidHash': hash, 'revoke': true});
      session.debugResetAdmissionState();
      session.configureRemoveData(null);
      session.configureAccountScope(null);
      final from = storage.attempts.length;
      final restarted = await boot(staleSessionOf: 'uid-x');
      expect(storage.data.containsKey(RemoveDataFlow.barrierKey), isFalse);
      expect(storage.data[RemoveDataFlow.revokedKey], contains('uid-x'));
      expect(Directory(location.directory).existsSync(), isFalse);
      expect(storage.data.containsKey(location.keyName), isFalse);
      expect(restarted.accountScope.activeUid, isNull);
      expect(session.status, isNot(SessionStatus.authenticated));
      expect(keyWrites(from), isEmpty);
    });

    test(
        'Stage1 uncleared revoked marker blocks actual bootstrap legacy '
        'adoption', () async {
      storage.data[RemoveDataFlow.revokedKey] = '["uid-x"]';
      storage.data[kMarkerKey] = 'uid-x';
      final legacyDb = File(p.join(support.path, 'money_companion.sqlite'))
        ..writeAsBytesSync(List<int>.filled(64, 7));
      storage.gate = (op, key) async {
        if (op == 'read' && key == kMarkerKey) {
          storage.data[kMarkerKey] = 'uid-x';
        }
      };
      final from = storage.attempts.length;
      final runner = await boot();
      storage.gate = null;
      expect(legacyDb.existsSync(), isTrue);
      expect(replicaDirs(), isEmpty);
      expect(keyWrites(from), isEmpty);
      expect(
          storage.attempts
              .skip(from)
              .where((a) => a.startsWith('write:qirsh.replicas.v1=')),
          isEmpty);
      expect(runner.accountScope.activeUid, isNull);
      expect(session.status, isNot(SessionStatus.authenticated));
      expect(
          queue.calls
              .where((c) => c.startsWith('begin') || c.startsWith('finish')),
          isEmpty);
    });

    test(
        'R2-7 Remove data from an authenticated user through the real '
        'startup: revalidation and auth events during the removal attempt '
        'NOTHING for X; a restart with the stale session stays signed out; a '
        'fresh explicit login creates exactly one replica', () async {
      var runner = await boot(staleSessionOf: 'uid-x');
      await signIn('uid-x');
      expect(session.status, SessionStatus.authenticated);
      expect(replicaDirs(), hasLength(1));
      expect(runner.accountScope.activeUid, 'uid-x');

      // Pause the removal after the scope swap, while the stale session is live.
      final hold = storage.holdOnce((op, key) =>
          op == 'delete' && key.startsWith(kConsentAskedKeyPrefix));
      final from = storage.attempts.length;
      final removal = session.removeDataFromDevice();
      await hold.reached.future;
      expect(runner.accountScope.activeUid, isNull,
          reason: 'the signed-out scope is published: the root remounts');
      // The configured SDK client is the one AppSession bound at startup.
      final client = Supabase.instance.client;
      expect(client.auth.currentSession?.user.id, 'uid-x',
          reason: 'the stale session of X is still live in the SDK');
      expect(await session.revalidateForShell(client), isFalse);
      await session.revalidateSupabaseSessionOnResume(client);
      // The SDK's own refresh of X on the bound client (with a coordinator it
      // is routed to ASR, which has no network here).
      try {
        await client.auth.refreshSession();
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 50));
      hold.release.complete();
      await removal;
      await session.drainAdmissions();

      expect(admissionWrites(from), isEmpty,
          reason: 'ZERO attempted marker/generation/key/registry writes');
      expect(replicaDirs(), isEmpty);
      expect(storage.data.keys.where((k) => k.startsWith('qirsh.db_key.')),
          isEmpty);
      expect(storage.data.containsKey(kMarkerKey), isFalse);
      expect(session.status, isNot(SessionStatus.authenticated));
      expect(queue.calls, containsAllInOrder(['begin:uid-x', 'finish:uid-x']));

      // Restart with the stale persisted Supabase session of X.
      for (final r in [...runners]) {
        await r.accountScope.lock();
      }
      session.debugResetAdmissionState();
      session.configureRemoveData(null);
      session.configureAccountScope(null);
      final afterRemoval = storage.attempts.length;
      runner = await boot(staleSessionOf: 'uid-x');
      await session.revalidateSupabaseSessionOnResume(Supabase.instance.client);
      await session.drainAdmissions();
      expect(admissionWrites(afterRemoval), isEmpty);
      expect(replicaDirs(), isEmpty);
      expect(runner.accountScope.activeUid, isNull);
      expect(session.status, isNot(SessionStatus.authenticated));

      // A fresh explicit login succeeds exactly once and creates one replica.
      final beforeLogin = storage.attempts.length;
      await signIn('uid-x');
      expect(replicaDirs(), hasLength(1));
      expect(keyWrites(beforeLogin), hasLength(1));
      expect(runner.accountScope.activeUid, 'uid-x');
      expect(storage.data.containsKey(RemoveDataFlow.revokedKey), isFalse,
          reason: 'the explicit admission committed and lifted the revocation');
    });

    for (final (label, read) in [
      ('a native barrier of unknown uid', _present),
      ('a MALFORMED native barrier answer', _malformed),
    ]) {
      test(
          'R2-7 $label blocks the real launch: no legacy adoption, no auth '
          'bind/reconcile, no replica opened, nothing routed authenticated',
          () async {
        var runner = await boot(staleSessionOf: 'uid-y');
        await signIn('uid-y');
        expect(session.status, SessionStatus.authenticated);
        final hashDirs = replicaDirs();
        final yLocation = await runner.accountScope.store.locationFor('uid-y');
        final yKey = storage.data[yLocation.keyName];
        // A legacy database appears, and the native barrier becomes unreadable.
        final legacyDb = File(p.join(support.path, 'money_companion.sqlite'))
          ..writeAsBytesSync(List<int>.filled(64, 7));
        queue.barrier = read();
        for (final r in [...runners]) {
          await r.accountScope.lock();
        }
        session.debugResetAdmissionState();
        session.configureRemoveData(null);
        session.configureAccountScope(null);
        final from = storage.attempts.length;
        queue.calls.clear();

        runner = await boot(staleSessionOf: 'uid-y');
        await session
            .revalidateSupabaseSessionOnResume(Supabase.instance.client);
        await session.drainAdmissions();

        expect(legacyDb.existsSync(), isTrue,
            reason: 'the legacy file was neither adopted nor quarantined');
        expect(Directory(p.join(replicas().path, '_quarantine')).existsSync(),
            isFalse);
        expect(runner.accountScope.activeUid, isNull,
            reason: 'only the signed-out scope is opened');
        expect(replicaDirs(), hashDirs, reason: 'no replica created or removed');
        expect(session.status, isNot(SessionStatus.authenticated));
        expect(admissionWrites(from), isEmpty);
        expect(
            queue.calls
                .where((c) => c.startsWith('begin') || c.startsWith('finish')),
            isEmpty,
            reason: 'no uid is guessed from the barrier');
        expect(storage.data[kMarkerKey], 'uid-y',
            reason: 'the marker is left alone, just not opened');

        // Control: once the barrier reads cleanly the same launch proceeds.
        queue.barrier = const CaptureRemovalBarrierRead.absent();
        for (final r in [...runners]) {
          await r.accountScope.lock();
        }
        session.debugResetAdmissionState();
        session.configureRemoveData(null);
        session.configureAccountScope(null);
        await runners.last.accountScope.store
            .setState('uid-y', ReplicaState.active);
        runner = await boot(staleSessionOf: 'uid-y');
        expect(legacyDb.existsSync(), isTrue,
            reason:
                'active non-adoptPending Y retains unrelated legacy leftover');
        expect(replicaDirs(), hashDirs);
        expect(File(yLocation.dbPath).existsSync(), isTrue);
        expect(storage.data[yLocation.keyName], yKey);
        expect(runner.accountScope.activeUid, 'uid-y');
      });
    }
  });
}
