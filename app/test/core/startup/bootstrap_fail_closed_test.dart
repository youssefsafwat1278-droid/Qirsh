import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../session/recording_secure_storage.dart';

// O-BX (C1) — fail-closed coordinator creation. The REAL BootstrapRunner.run(): after removal-first handling and BEFORE
// ordinary replica recovery, adoption, retired purge and service init, an
// expired or absent SDK session with a valid grant restores the account's own
// replica read-only. Every effect is observed as an attempt.

class _SpyNotifications extends FlutterLocalNotificationsPlatform {
  static int initCalls = 0;
  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() async {
    initCalls++;
    return null;
  }
}

class _Queue implements CaptureQueueBridge {
  CaptureRemovalBarrierRead barrier = const CaptureRemovalBarrierRead.absent();
  @override
  Future<CaptureRemovalBarrierRead> getCaptureRemovalBarrier() async => barrier;
  @override
  Future<void> beginCaptureRemoval(String uid) async {}
  @override
  Future<void> finishCaptureRemoval(String uid) async {
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
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  late RecordingSecureStorage storage;
  late _Queue queue;
  final session = AppSession.instance;
  final runners = <BootstrapRunner>[];
  final clients = <SupabaseClient>[];
  Timer? frames;

  setUp(() async {
    support = Directory.systemTemp.createTempSync('bootstrap_lr_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    storage = RecordingSecureStorage().install();
    FlutterLocalNotificationsPlatform.instance = _SpyNotifications();
    _SpyNotifications.initCalls = 0;
    queue = _Queue();
    DatabaseAccessBroker.debugResetForTest();
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    session.configureLocalRead(null);
    await session.wipeAndReset();
    final binding = TestWidgetsFlutterBinding.instance;
    frames = Timer.periodic(const Duration(milliseconds: 20), (_) {
      binding.scheduleFrame();
      binding.handleBeginFrame(Duration.zero);
      binding.handleDrawFrame();
    });
  });

  tearDown(() async {
    DatabaseAccessBroker.debugResetForTest();
    for (final r in [...runners]) {
      try {
        await r.accountScope.lock();
        r.accountScope.dispose();
      } catch (_) {}
    }
    for (final c in clients) {
      await c.dispose();
    }
    clients.clear();
    frames?.cancel();
    runners.clear();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    session.configureLocalRead(null);
    session.configureCaptureOwnerClear(null);
    support.deleteSync(recursive: true);
  });

  SupabaseClient absentClient() {
    final c = SupabaseClient('http://127.0.0.1:55321', 'synthetic-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((_) async => http.Response('{}', 200)));
    clients.add(c);
    return c;
  }

  const name = 'qirsh.database_access_broker.O.v1';
  final foreignPorts = <ReceivePort>[];

  tearDown(() {
    IsolateNameServer.removePortNameMapping(name);
    for (final port in foreignPorts) {
      port.close();
    }
    foreignPorts.clear();
  });

  /// A coordinator that is registered under the name but is not ours.
  SendPort foreignCoordinator({bool dead = false}) {
    final port = ReceivePort();
    foreignPorts.add(port);
    expect(IsolateNameServer.registerPortWithName(port.sendPort, name), isTrue);
    final send = port.sendPort;
    if (dead) port.close();
    return send;
  }

  List<String> tree() => [
        for (final e in Directory(support.path).listSync(recursive: true))
          p.relative(e.path, from: support.path),
      ]..sort();

  bool isCoordinatorFailure(Object e) =>
      e.toString().contains('BootstrapCoordinatorUnavailable');

  /// Every way coordinator creation can fail, and what it must NOT have done.
  final failures = <String, void Function()>{
    'name collision': () => foreignCoordinator(),
    'dead coordinator (stale port under the name)': () =>
        foreignCoordinator(dead: true),
    'missing root isolate token': () =>
        DatabaseAccessBroker.debugHideRootToken = true,
  };

  for (final failure in failures.entries) {
    test('${failure.key}: startup fails closed with zero opens, recovery, '
        'adoption or maintenance, and a failed retry stays denied', () async {
      failure.value();
      final registered = IsolateNameServer.lookupPortByName(name);
      final events = <String>[];
      final from = storage.attempts.length;
      final before = tree();
      final runner = BootstrapRunner(
          debugAuthClient: absentClient(), debugStorageEvent: events.add)
        ..captureQueue = queue;
      runners.add(runner);

      await expectLater(runner.run(), throwsA(predicate(isCoordinatorFailure)));
      expect(runner.debugCoordinator, isNull);
      expect(runner.lastStep, isNull, reason: 'no bootstrap step started');
      expect(events, isEmpty, reason: 'no opener, liveness or native open');
      expect(storage.attempts.skip(from), isEmpty,
          reason: 'no key, salt, registry, owner marker or grant access');
      expect(tree(), before, reason: 'no file or directory created');
      expect(_SpyNotifications.initCalls, 0);
      expect(session.localReadActive, isFalse, reason: 'no local-read fallback');
      expect(DatabaseAccessBroker.hasRetained, isFalse);

      // Retry: still denied, nothing opened, nothing unregistered or fabricated.
      await expectLater(runner.run(), throwsA(predicate(isCoordinatorFailure)));
      expect(events, isEmpty);
      expect(storage.attempts.skip(from), isEmpty);
      expect(tree(), before);
      expect(runner.debugCoordinator, isNull);
      expect(DatabaseAccessBroker.hasRetained, isFalse,
          reason: 'a retry never fabricates a replacement coordinator');
      expect(IsolateNameServer.lookupPortByName(name), registered,
          reason: 'another registration is never removed');
    });
  }

  test('clearing the cause does not let a retry fabricate an empty coordinator',
      () async {
    foreignCoordinator();
    final events = <String>[];
    final runner = BootstrapRunner(
        debugAuthClient: absentClient(), debugStorageEvent: events.add)
      ..captureQueue = queue;
    runners.add(runner);
    await expectLater(runner.run(), throwsA(predicate(isCoordinatorFailure)));
    IsolateNameServer.removePortNameMapping(name); // the old holder may still live
    await expectLater(runner.run(), throwsA(predicate(isCoordinatorFailure)));
    expect(DatabaseAccessBroker.hasRetained, isFalse);
    expect(IsolateNameServer.lookupPortByName(name), isNull,
        reason: 'nothing was registered by the retry');
    expect(events, isEmpty);
  });

  test('a retained coordinator whose name was lost is unproven: denied, '
      'never re-registered', () async {
    final first = BootstrapRunner(debugAuthClient: absentClient())
      ..captureQueue = queue;
    runners.add(first);
    await first.run();
    expect(DatabaseAccessBroker.hasRetained, isTrue);
    await first.accountScope.lock();
    IsolateNameServer.removePortNameMapping(name);
    final events = <String>[];
    final second = BootstrapRunner(
        debugAuthClient: absentClient(), debugStorageEvent: events.add)
      ..captureQueue = queue;
    runners.add(second);
    await expectLater(second.run(), throwsA(predicate(isCoordinatorFailure)));
    expect(events, isEmpty);
    expect(IsolateNameServer.lookupPortByName(name), isNull);
  });

  test('a proven live retained coordinator is reused by a retry', () async {
    final events = <String>[];
    final runner = BootstrapRunner(
        debugAuthClient: absentClient(), debugCoordinatorEvent: events.add)
      ..captureQueue = queue;
    runners.add(runner);
    await runner.run();
    final coordinator = runner.debugCoordinator;
    expect(coordinator, isNotNull);
    await runner.run();
    expect(identical(runner.debugCoordinator, coordinator), isTrue);
    expect(events.where((e) => e == 'coordinator'), hasLength(1));
  });

  test('run() is single-flight: a second call while one is in flight joins it',
      () async {
    final reads = <String>[];
    storage.gate = (op, key) async {
      if (op == 'read') reads.add(key);
    };
    String? held;
    final hold = storage.holdOnce((op, key) {
      if (op != 'read') return false;
      held = key;
      return true;
    });
    final runner = BootstrapRunner(debugAuthClient: absentClient())
      ..captureQueue = queue;
    runners.add(runner);

    final first = runner.run();
    await hold.reached.future;
    final second = runner.run();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(reads.where((k) => k == held), isEmpty,
        reason: 'no second run reached the step the first is held at');

    hold.release.complete();
    final results = await Future.wait([first, second]);
    expect(identical(results[0], results[1]), isTrue);
  });

  test('a failed device-salt read is not cached: the next call reads again',
      () async {
    var failNext = true;
    storage.gate = (op, key) async {
      if (op == 'read' && key == ReplicaStore.saltKey && failNext) {
        failNext = false;
        throw PlatformException(code: '-25308', message: 'interaction');
      }
    };
    final store = ReplicaStore(appSupportDirectory: support.path);
    await expectLater(store.uidHash('u1'), throwsA(isA<PlatformException>()));
    expect(await store.uidHash('u1'), hasLength(32));
  });
}
