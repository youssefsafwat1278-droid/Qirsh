// Cold-start background capture drain, executed end to end: the REAL
// HeadlessCaptureDrain -> BootstrapRunner.runHeadless (the real launch steps:
// session load, admission, replica registry, keys, Drift open through the real
// coordinator) -> a provider container built from the SAME account-scope
// overrides as the foreground graph -> the real leased LegacyCaptureDrain.
// Mocked: platform channels (path_provider, secure storage, notifications, the
// native capture queue + lease), the auth HTTP endpoint and the AI endpoint.
// Every message is synthetic.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/core/session/rebootstrap_service.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/features/capture/background/background_capture_drain.dart';
import 'package:money_companion/features/capture/background/headless_capture_drain.dart';
import 'package:money_companion/features/capture/services/legacy_capture_drain.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
// Test-only mock of the already-pinned SDK transitive preferences store.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/session/recording_secure_storage.dart';
import '../../../harness/egress_test_support.dart';
import '../../../domain/local_v2_support.dart';

class _NoNotifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<NotificationAppLaunchDetails?>
      getNotificationAppLaunchDetails() async => null;
}

class _Queue implements CaptureQueueBridge {
  CaptureRemovalBarrierRead barrier = const CaptureRemovalBarrierRead.absent();
  @override
  Future<CaptureRemovalBarrierRead> getCaptureRemovalBarrier() async =>
      barrier;
  @override
  Future<void> beginCaptureRemoval(String uid) async {}
  @override
  Future<void> finishCaptureRemoval(String uid) async {}
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

/// The native durable queue + the process-wide drain lease, as the channel
/// exposes them. Everything else on the channel is "not implemented".
class _Native {
  final items = <Map<String, Object?>>[];
  final acked = <String>[];
  final calls = <String>[];
  String? lease;
  int _leases = 0;
  void Function(String id)? onAck;

  /// Runs (awaited, once) when a drain first reads the queue.
  Future<void> Function()? onFirstPeek;

  /// Payload ids whose acknowledgement "dies" (process killed after commit).
  final dieOnAck = <String>{};

  void add(String id, String text) => items.add({
        'id': id,
        'text': text,
        'sender': 'SNB',
        'source': 'sms',
        'receivedAtEpochMs': DateTime.utc(2026, 4, 8, 9, 45).millisecondsSinceEpoch,
      });

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'acquireCaptureDrainLease':
        if (lease != null) return {'granted': false};
        lease = 'lease-${++_leases}';
        return {'granted': true, 'token': lease};
      case 'releaseCaptureDrainLease':
        if ((call.arguments as Map)['token'] != lease) return false;
        lease = null;
        return true;
      case 'scheduleBackgroundCaptureDrain':
      case 'cancelBackgroundCaptureDrain':
        return null;
      case 'peekPendingSharedMessages':
        final first = onFirstPeek;
        onFirstPeek = null;
        await first?.call();
        return items.isEmpty ? null : jsonEncode(items);
      case 'acknowledgeSharedMessage':
        final id = (call.arguments as Map)['payloadId'] as String;
        if (dieOnAck.remove(id)) return false;
        acked.add(id);
        items.removeWhere((i) => i['id'] == id);
        onAck?.call(id);
        return true;
    }
    throw MissingPluginException();
  }

  int get queueReads => calls.where((c) => c == 'peekPendingSharedMessages').length;
}

String _jwt(String uid) {
  String segment(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final exp = DateTime.now().add(const Duration(hours: 1));
  return '${segment({'alg': 'none', 'typ': 'JWT'})}.'
      '${segment({'exp': exp.millisecondsSinceEpoch ~/ 1000, 'sub': uid})}.';
}

/// Counts every auth-endpoint request (egress).
int _authRequests = 0;

Future<SupabaseClient> _client(String uid) async {
  final user = {
    'id': uid,
    'aud': 'authenticated',
    'email': '$uid@example.com',
    'app_metadata': <String, dynamic>{},
    'user_metadata': <String, dynamic>{},
    'created_at': '2026-10-01T00:00:00Z',
  };
  final client = SupabaseClient(
    'https://example.supabase.co',
    'public-anon-key',
    httpClient: MockClient((request) async {
      _authRequests++;
      if (request.url.path.endsWith('/user')) {
        return http.Response(jsonEncode(user), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{}', 200);
    }),
  );
  await client.auth.recoverSession(jsonEncode({
    'access_token': _jwt(uid),
    'token_type': 'bearer',
    'refresh_token': 'refresh-$uid',
    'user': user,
  }));
  _authRequests = 0;
  return client;
}

/// The account (the egress fixture seeds a durable Cloud ON record for it).
const _uid = 'uid-a';

String _purchase(int amount) =>
    'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR $amount.00\n'
    'لدى:SHOP\nفي:2026-04-08 12:45\nالرصيد:SAR 9,000.00';

/// A spawned isolate is another engine of the same process (same VM, same
/// IsolateNameServer, its own statics): it runs the foreground bootstrap's
/// reclaim step and then proves the coordinator name is free for it.
Future<void> _foregroundEngine(SendPort reply) async {
  final outcome = await DatabaseAccessBroker.reclaimFromHeadless();
  const name = 'qirsh.database_access_broker.O.v1';
  final port = ReceivePort();
  final took = IsolateNameServer.registerPortWithName(port.sendPort, name);
  if (took) IsolateNameServer.removePortNameMapping(name);
  port.close();
  reply.send([outcome.name, took]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const captureChannel = MethodChannel('money_companion/native_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final session = AppSession.instance;
  late Directory support;
  late _Queue queue;
  late _Native native;
  final runners = <BootstrapRunner>[];
  Timer? frames;

  setUp(() async {
    DatabaseAccessBroker.debugResetForTest();
    SharedPreferences.setMockInitialValues({});
    support = Directory.systemTemp.createTempSync('headless_drain_');
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path);
    RecordingSecureStorage().install();
    FlutterLocalNotificationsPlatform.instance = _NoNotifications();
    queue = _Queue();
    native = _Native();
    ReplicaFreeze.instance.thaw();
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
    runners.clear();
    frames?.cancel();
    NativeCaptureBridge.debugTreatHostAsNative = false;
    messenger.setMockMethodCallHandler(captureChannel, null);
    ReplicaFreeze.instance.thaw();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    session.configureCaptureOwnerClear(null);
    DatabaseAccessBroker.debugResetForTest();
    support.deleteSync(recursive: true);
  });

  /// The process dies; the next "process" starts with fresh statics.
  Future<void> processDeath(BootstrapRunner runner) async {
    await runner.accountScope.detach();
    runners.remove(runner);
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    DatabaseAccessBroker.debugResetForTest();
  }

  /// A foreground launch + sign-in that leaves an admitted replica, then the
  /// process is killed with the app backgrounded.
  Future<void> installSignedIn() async {
    final runner = BootstrapRunner(debugAuthClient: await _client(_uid))
      ..captureQueue = queue;
    runners.add(runner);
    await runner.run();
    await session.completeOnboarding(
        method: 'google', email: '$_uid@example.com', userId: _uid);
    expect(runner.accountScope.activeUid, _uid);
    await processDeath(runner);
  }

  /// The OS scheduler fires with no engine: the native queue is live from now.
  Future<HeadlessCaptureDrain> headless({
    List<Override> overrides = const [],
  }) async {
    NativeCaptureBridge.debugTreatHostAsNative = true;
    messenger.setMockMethodCallHandler(captureChannel, native.handle);
    final runner = BootstrapRunner(debugAuthClient: await _client(_uid))
      ..captureQueue = queue;
    runners.add(runner);
    return HeadlessCaptureDrain(
      runner: runner,
      prepareInstallPresentation: () async => true,
      overrides: overrides,
    );
  }

  /// Reads the replica of [_uid] after the headless run released it.
  Future<List<String>> committed() async {
    final runner = BootstrapRunner(debugAuthClient: await _client(_uid))
      ..captureQueue = queue;
    runners.add(runner);
    NativeCaptureBridge.debugTreatHostAsNative = false;
    messenger.setMockMethodCallHandler(captureChannel, null);
    await runner.run();
    final db = runner.accountScope.current!.database;
    return (await db
            .customSelect('SELECT id FROM transactions ORDER BY rowid;')
            .get())
        .map((r) => r.read<String>('id'))
        .toList();
  }

  test(
      'cold start with a queued capture: the real pipeline commits ONE '
      'transaction keyed by the payload id, acks it, releases everything',
      () async {
    await installSignedIn();
    native.add('p-1', _purchase(45));
    final drain = await headless();
    final outcome = await drain.run();
    expect(outcome, BackgroundDrainOutcome.done);
    expect(drain.released, isTrue,
        reason: 'database closed and coordinator name released');
    expect(native.acked, ['p-1']);
    expect(native.lease, isNull, reason: 'the drain lease was released');
    expect(DatabaseAccessBroker.discover(), isNull);
    final ids = await committed();
    expect(ids, hasLength(1));
    expect(ids.single, contains('p-1'),
        reason: 'tx.id derives from the payload id (idempotent)');
  });

  test('signed out: no queue read, no egress, nothing opened', () async {
    native.add('p-1', _purchase(45));
    final drain = await headless();
    expect(await drain.run(), BackgroundDrainOutcome.deferred);
    expect(drain.released, isTrue);
    expect(native.queueReads, 0);
    expect(native.acked, isEmpty);
    expect(_authRequests, 0);
  });

  test('removal barrier present: no queue read, no egress', () async {
    await installSignedIn();
    native.add('p-1', _purchase(45));
    queue.barrier = const CaptureRemovalBarrierRead.malformed();
    final drain = await headless();
    expect(await drain.run(), BackgroundDrainOutcome.deferred);
    expect(drain.released, isTrue);
    expect(native.queueReads, 0);
    expect(native.acked, isEmpty);
    expect(_authRequests, 0);
    queue.barrier = const CaptureRemovalBarrierRead.absent();
    expect(await committed(), isEmpty);
  });

  test('frozen replica: no queue read, nothing committed', () async {
    await installSignedIn();
    native.add('p-1', _purchase(45));
    ReplicaFreeze.instance.freeze();
    final drain = await headless();
    expect(await drain.run(), BackgroundDrainOutcome.deferred);
    expect(drain.released, isTrue);
    expect(native.queueReads, 0);
    expect(native.acked, isEmpty);
    ReplicaFreeze.instance.thaw();
    expect(await committed(), isEmpty);
  });

  group('consent (AI-first, re-read before every AI request)', () {
    late List<String> aiRequests;
    late DriftUserSettingsRepository headlessSettings;

    Future<void> setConsent({required bool ai}) async =>
        headlessSettings.saveSettings((await headlessSettings.getSettings())
            .copyWith(
                cloudConsentState: ConsentState.accepted,
                aiConsentState:
                    ai ? ConsentState.accepted : ConsentState.declined));

    /// The real LegacyCaptureDrain over the HEADLESS container's database,
    /// with only the AI endpoint faked (no backend upload path).
    List<Override> aiOverrides() => [
          legacyCaptureDrainProvider.overrideWith((ref) {
            final db = ref.watch(appDatabaseProvider);
            final settings = headlessSettings = DriftUserSettingsRepository(db);
            final txRepo = DriftTransactionRepository(db);
            final ingest = IngestCapturedMessageUseCase(AddTransactionUseCase(
              transactionRepository: txRepo,
              merchantCategoryRepository: DriftMerchantCategoryRepository(db),
              suspectedDuplicateRepository:
                  DriftSuspectedDuplicateRepository(db),
              accountRepository: DriftAccountRepository(db),
              dedupStore: DriftDedupStore(db),
              parserIsolate: const FakeParserIsolate(),
              aiClient: SupabaseAiParserClient(
                edgeFunctionUrl:
                    'https://example.supabase.co/functions/v1/parse-sms',
                getAnonJwt: () async => 'jwt',
                httpClient: MockClient((request) async {
                  aiRequests.add('parse-sms');
                  return http.Response(
                      jsonEncode({'is_transaction': false}), 200,
                      headers: {'content-type': 'application/json'});
                }),
              ),
              loadAiConsent: () async => ConsentAuthority.decide(
                  EgressClass.aiProcessing, await settings.getSettings()),
              aiPrimarySelected: () async {
                final s = await settings.getSettings();
                return s.cloudProcessingEnabled && s.aiConsentGranted;
              },
              findSameTextCapture: txRepo.findSameTextCapture,
              installId: 'install',
            ));
            return LegacyCaptureDrain(
              captureSync: ref.watch(captureSyncServiceProvider),
              ingest: ingest,
              loadSettings: settings.getSettings,
              retryLedger: ref.watch(captureRetryLedgerProvider),
              flag: (key) => key == 'android_capture_ai_enabled',
              uploadsNatively: () => false,
              aiAvailable: () => true,
            );
          }),
        ];

    late CloudEgressGate previousGate;
    setUp(() {
      aiRequests = [];
      // The user explicitly enabled Cloud: a durable ON record exists.
      previousGate = CloudEgressGate.instance;
      TestEgress(seedOn: true).install();
    });
    tearDown(() => CloudEgressGate.instance = previousGate);

    test('consent revoked: no AI request at all; processed on device',
        () async {
      await installSignedIn();
      native
        ..add('p-1', _purchase(10))
        ..add('p-2', _purchase(20))
        // The replica's stored consent at drain time: Cloud on, AI off.
        ..onFirstPeek = () => setConsent(ai: false);
      final drain = await headless(overrides: aiOverrides());
      await drain.run();
      expect(aiRequests, isEmpty);
      expect(native.acked, ['p-1', 'p-2']);
    });

    test(
        'AI-first while consented; revoked mid-drain: the next item makes no '
        'AI request', () async {
      await installSignedIn();
      native
        ..add('p-1', _purchase(10))
        ..add('p-2', _purchase(20))
        ..onFirstPeek = () => setConsent(ai: true);
      native.onAck = (id) {
        if (id == 'p-1') unawaited(setConsent(ai: false));
      };
      final drain = await headless(overrides: aiOverrides());
      await drain.run();
      expect(aiRequests, hasLength(1),
          reason: 'AI-first for the first item, consent re-read for the next');
      expect(native.acked, ['p-1', 'p-2']);
    });
  });

  test(
      'a foreground bootstrap arriving mid-drain: the headless run stops at '
      'the item boundary and releases; the foreground takes over; no '
      'duplicate', () async {
    await installSignedIn();
    native
      ..add('p-1', _purchase(10))
      ..add('p-2', _purchase(20))
      ..add('p-3', _purchase(30));
    final foreground = Completer<List<Object?>>();
    final replies = ReceivePort();
    replies.listen((m) => foreground.complete(m as List<Object?>));
    native.onAck = (id) {
      // Another engine of the process starts its launch bootstrap now.
      if (id == 'p-1') {
        unawaited(Isolate.spawn(_foregroundEngine, replies.sendPort));
      }
    };
    final drain = await headless();
    final outcome = await drain.run();
    final result = await foreground.future;
    replies.close();
    expect(outcome, BackgroundDrainOutcome.cancelled);
    expect(drain.released, isTrue);
    expect(result, ['released', true],
        reason: 'the foreground got the coordinator after the release');
    expect(native.acked.first, 'p-1');
    expect(native.acked.length, lessThan(3),
        reason: 'stopped at an item boundary, not at the end of the queue');
    final left = [for (final i in native.items) i['id']];

    // The foreground's own drain processes the rest, once.
    native.onAck = null;
    final runner = BootstrapRunner(debugAuthClient: await _client(_uid))
      ..captureQueue = queue;
    runners.add(runner);
    await runner.run();
    final container = ProviderContainer(overrides: [
      appDatabaseProvider
          .overrideWithValue(runner.accountScope.current!.database),
    ]);
    addTearDown(container.dispose);
    await runLeasedCaptureDrain(
      lease: CaptureDrainLease(),
      holder: 'foreground',
      ledger: container.read(captureRetryLedgerProvider),
      drain: () => runHeadlessCapturePass(container, isActive: () => true),
    );
    expect(native.acked, ['p-1', 'p-2', 'p-3']);
    expect(left, isNot(contains('p-1')));
    final ids = (await runner.accountScope.current!.database
            .customSelect('SELECT id FROM transactions;')
            .get())
        .map((r) => r.read<String>('id'))
        .toList();
    expect(ids, hasLength(3));
    expect(ids.toSet(), hasLength(3));
  });

  test(
      'killed after a commit but before its ack: the restarted run recovers '
      'it exactly once', () async {
    await installSignedIn();
    native
      ..add('p-1', _purchase(10))
      ..add('p-2', _purchase(20));
    native.dieOnAck.add('p-1');
    final first = await headless();
    await first.run();
    expect(native.acked, ['p-2']);
    expect(native.items.map((i) => i['id']), ['p-1'],
        reason: 'never acknowledged: still queued');
    await processDeath(first.runner);

    final second = await headless();
    expect(await second.run(), BackgroundDrainOutcome.done);
    expect(native.acked, ['p-2', 'p-1']);
    expect(native.items, isEmpty);
    final ids = await committed();
    expect(ids, hasLength(2), reason: 'p-1 committed once, not twice');
  });

  group('coordinator reclaim protocol', () {
    const name = 'qirsh.database_access_broker.O.v1';
    const marker = 'qirsh.database_access_broker.O.v1.headless';

    test('no coordinator: nothing to reclaim', () async {
      expect(await DatabaseAccessBroker.reclaimFromHeadless(),
          HeadlessYield.none);
    });

    test('a holder not marked headless is never asked (fails closed at once)',
        () async {
      final foreign = ReceivePort();
      final asked = <Object?>[];
      foreign.listen(asked.add);
      IsolateNameServer.registerPortWithName(foreign.sendPort, name);
      final watch = Stopwatch()..start();
      expect(await DatabaseAccessBroker.reclaimFromHeadless(),
          HeadlessYield.foregroundHolder);
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(asked, isEmpty);
      foreign.close();
    });

    test('a dead headless registration: unresponsive after the bound',
        () async {
      final dead = ReceivePort();
      IsolateNameServer.registerPortWithName(dead.sendPort, marker);
      IsolateNameServer.registerPortWithName(dead.sendPort, name);
      dead.close();
      expect(
          await DatabaseAccessBroker.reclaimFromHeadless(
              timeout: const Duration(milliseconds: 200)),
          HeadlessYield.unresponsive);
      expect(IsolateNameServer.lookupPortByName(name), isNotNull,
          reason: 'never unregisters or replaces anything itself');
    });

    test('a headless holder that cannot finish in time: stillRunning',
        () async {
      final stuck = ReceivePort();
      stuck.listen((m) {
        if (m is List && m.length == 2 && m[1] is SendPort) {
          (m[1] as SendPort).send(const ['yielding']);
        }
      });
      IsolateNameServer.registerPortWithName(stuck.sendPort, marker);
      IsolateNameServer.registerPortWithName(stuck.sendPort, name);
      expect(
          await DatabaseAccessBroker.reclaimFromHeadless(
              timeout: const Duration(milliseconds: 200)),
          HeadlessYield.stillRunning);
      stuck.close();
    });

    test('a foreground coordinator answers denied and never yields',
        () async {
      final foreground = DatabaseAccessBroker.createInert();
      expect(foreground.isHeadless, isFalse);
      // Ask it as another engine would (its own statics: a spawned isolate).
      final replies = ReceivePort();
      final answer = Completer<Object?>();
      replies.listen(answer.complete);
      DatabaseAccessBroker.discover();
      IsolateNameServer.lookupPortByName(name)!
          .send(['qirsh.coordinator.yield.v1', replies.sendPort]);
      expect(await answer.future, ['denied']);
      expect(foreground.yieldRequested, isFalse);
      replies.close();
    });

    test(
        'a headless coordinator is marked, never doubled, and its release '
        'unregisters both names', () async {
      final broker = DatabaseAccessBroker.createHeadless();
      expect(IsolateNameServer.lookupPortByName(marker), isNotNull);
      expect(() => DatabaseAccessBroker.createHeadless(),
          throwsA(isA<DatabaseAccessUnavailable>()));
      expect(broker.releaseHeadless(), isTrue);
      expect(IsolateNameServer.lookupPortByName(name), isNull);
      expect(IsolateNameServer.lookupPortByName(marker), isNull);
    });
  });
}
