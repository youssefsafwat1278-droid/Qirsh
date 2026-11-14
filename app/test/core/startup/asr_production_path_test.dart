// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/router/app_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/auth/auth_coordinator.dart';
import 'package:money_companion/core/auth/auth_diagnostics.dart';
import 'package:money_companion/core/auth/owned_tls_socket.dart';
import 'package:money_companion/core/auth/refresh_transport.dart';
import 'package:money_companion/core/auth/session_files.dart';
import 'package:money_companion/core/auth/session_keychain.dart';
import 'package:money_companion/core/auth/session_record.dart';
import 'package:money_companion/core/auth/session_store.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/local_read_authority.dart';
import 'package:money_companion/core/startup/automatic_session_recovery.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../harness/asr_native_sim.dart';
import '../auth/session_fixtures.dart';
import '../auth/store_fakes.dart';
import '../auth/tls_fixture.dart';
import '../session/f2_fixture.dart';
import '../session/recording_secure_storage.dart';

/// ASR v7.2 Phase 4 (Astra R-INT): the production path end to end. The REAL
/// BootstrapRunner (coordinated SDK wiring, AppSession, AccountScopeHost,
/// LocalReadAuthority, CloudEgressGate, the capture registration service and
/// the AutomaticSessionRecovery it wires) over controlled boundaries only: an
/// in-memory Keychain, a scripted refresh channel, a mock HTTP transport and a
/// stateful simulated native side ([AsrNativeSim]).

const _url = 'https://abcdefghij.supabase.co';
const _uid = 'uid-asr-int';
const _channel = MethodChannel('money_companion/native_capture');

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class _LoopbackHttpOverrides extends HttpOverrides {}

class _RedirectContext extends Fake implements BuildContext {}

class _SpyNotifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<NotificationAppLaunchDetails?>
      getNotificationAppLaunchDetails() async => null;
}

/// The refresh exchange: scripted, never the network.
class _Script {
  int sends = 0;
  int opens = 0;

  /// The exchange cannot connect (the device is offline).
  bool offline = false;
  Completer<void>? hold;

  /// A real server's answer time (the phone's took a few hundred ms).
  Duration latency = Duration.zero;

  /// Thrown by the channel's quiescence (an unconfirmed descriptor closure).
  Object? quiesceError;
  RefreshHttpResult Function() result = () => ok();

  static RefreshHttpResult ok({String token = 'refresh-2', int expIn = 3600}) {
    final exp = _now() + expIn;
    return RefreshHttpResult(
        statusCode: 200,
        json: sessionJson(uid: _uid, exp: exp, refreshToken: token)
          ..['expires_at'] = exp,
        isRedirect: false);
  }
}

class _Channel implements RefreshChannel {
  _Channel(this.script);
  final _Script script;
  bool _sent = false;
  final Completer<void> _cancel = Completer<void>();

  @override
  bool get sent => _sent;
  @override
  Future<void> open() async {
    script.opens++;
    if (script.offline) throw const SocketException('offline');
  }
  @override
  Future<RefreshHttpResult> send(String refreshToken) {
    _sent = true;
    script.sends++;
    final hold = script.hold ??
        (script.latency == Duration.zero
            ? null
            : (Completer<void>()
              ..complete(Future<void>.delayed(script.latency))));
    if (hold == null) return Future.value(script.result());
    return Future.any([
      hold.future.then((_) => script.result()),
      _cancel.future.then<RefreshHttpResult>(
          (_) => throw const RefreshCancelled('cancel')),
    ]);
  }

  @override
  void cancel() {
    if (!_cancel.isCompleted) _cancel.complete();
  }

  @override
  void close() {}
  @override
  Future<void> quiesced() async {
    if (script.quiesceError != null) throw script.quiesceError!;
  }
}

/// The session Keychain whose plugin items ARE the app's secure storage (one
/// iOS Keychain in production): the strict ASR reads see what the app wrote.
class _Keychain extends FakeKeychain {
  _Keychain(this.storage);
  final RecordingSecureStorage storage;
  int failPluginReads = 0;

  /// A write this returns true for is lost before it lands: no item, and an
  /// `unknown` reply (Phase 4c B2: the record stays as it was).
  bool Function(String value)? dropWrite;

  @override
  Future<KeychainResult> write(String key, String value) async {
    if (dropWrite?.call(value) ?? false) {
      return const KeychainResult(KeychainStatus.unknown);
    }
    return super.write(key, value);
  }

  @override
  Future<KeychainResult> readPluginItem(String key) async {
    if (failPluginReads > 0) {
      failPluginReads--;
      return const KeychainResult(KeychainStatus.error);
    }
    final v = storage.data[key];
    return v == null
        ? const KeychainResult(KeychainStatus.absent)
        : KeychainResult(KeychainStatus.found, v);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final binding = TestWidgetsFlutterBinding.instance;
  final messenger = binding.defaultBinaryMessenger;
  final session = AppSession.instance;
  late Directory support;
  late RecordingSecureStorage storage;
  late _Keychain keychain;
  late AsrNativeSim sim;
  late _Script script;
  RefreshChannel Function()? refreshChannelFactory;
  late List<http.BaseRequest> requests;
  late List<http.BaseRequest> signIns;
  final runners = <BootstrapRunner>[];
  final coordinators = <AuthCoordinator>[];
  Timer? frames;

  setUp(() async {
    support = Directory.systemTemp.createTempSync('asr_int_');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    storage = RecordingSecureStorage().install();
    FlutterLocalNotificationsPlatform.instance = _SpyNotifications();
    SharedPreferences.setMockInitialValues({});
    CloudEgressGate.instance = CloudEgressGate(supabaseUrl: () => _url);
    ConsentAuthority.egressFrozen = false;
    ConsentAuthority.egressFreezeTag = '';
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    session.configureLocalRead(null);
    await session.wipeAndReset();
    keychain = _Keychain(storage);
    sim = AsrNativeSim(uid: _uid);
    script = _Script();
    refreshChannelFactory = null;
    requests = [];
    signIns = [];
    frames = Timer.periodic(const Duration(milliseconds: 20), (_) {
      binding.scheduleFrame();
      binding.handleBeginFrame(Duration.zero);
      binding.handleDrawFrame();
    });
  });

  tearDown(() async {
    sim.releaseParked();
    AutomaticSessionRecovery.active?.dispose();
    AutomaticSessionRecovery.active = null;
    // Every test starts in the background: recovery runs only on its resume.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    for (final r in runners) {
      try {
        await r.accountScope.lock();
        r.accountScope.dispose();
      } catch (_) {}
    }
    runners.clear();
    for (final c in coordinators) {
      c.dispose();
    }
    coordinators.clear();
    AuthCoordinator.active = null;
    try {
      if (Supabase.instance.isInitialized) await Supabase.instance.dispose();
    } catch (_) {}
    frames?.cancel();
    NativeCaptureBridge.debugTreatHostAsNative = false;
    messenger.setMockMethodCallHandler(_channel, null);
    ConsentAuthority.egressFrozen = false;
    ConsentAuthority.egressFreezeTag = '';
    CloudEgressGate.instance = CloudEgressGate();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    session.configureLocalRead(null);
    session.configureCaptureOwnerClear(null);
    support.deleteSync(recursive: true);
  });

  SessionStore newStore() => SessionStore(
        keychain: keychain,
        files: SessionFiles(support),
        origin: Uri.parse(_url),
        legacy: FakeLegacy(),
        localInstallDataPresent: () async => true,
      );

  /// Process 1: an explicit, completed sign-in of [_uid] (local-read grant
  /// issued) with one row and Cloud ON (saved consent, both Dart layers, and
  /// the native lifetime the explicit enable left); then the process dies.
  Future<void> accountWithCloudOnThenKill() async {
    final first = BootstrapRunner(debugAuthClient: await F2Fixture.liveClient(_uid))
      ..captureQueue = AsrSimQueue(sim);
    runners.add(first);
    await first.run();
    await session.completeOnboarding(
        method: 'google', email: '$_uid@example.com', userId: _uid);
    expect(first.accountScope.activeUid, _uid);
    final db = first.accountScope.current!.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.customStatement(
        "INSERT INTO transactions(id, amount, amount_minor, currency, type, "
        "source, occurred_at, raw_message, parse_confidence, status, "
        "created_at, updated_at, raw_merchant, direction) VALUES "
        "('tx-1', 125.5, 12550, 'SAR', 'payment', 'manual', '$now', '', 1, "
        "'confirmed', '$now', '$now', 'Coffee Corner', 'debit');");
    final repo = DriftUserSettingsRepository(db);
    await repo.saveSettings((await repo.getSettings()).copyWith(
        cloudConsentState: ConsentState.accepted, cloudConsentVersion: 1));
    sim.seedLiveOn(transitionGeneration: 1, reservedVersion: 1);
    expect(storage.data[SecureLocalReadStore.storageKey], isNotNull,
        reason: 'the fixture must leave a local-read grant');
    await first.accountScope.detach();
    first.accountScope.dispose();
    runners.remove(first);
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    session.configureLocalRead(null);
    // What the dead process left durable (its detach above is the harness
    // releasing the scope, not part of the fixture).
    final on = jsonEncode({
      'v': 1,
      'records': {
        _uid: const CloudEgressRecord(
                state: EgressState.on,
                ownerUid: _uid,
                transitionGeneration: 1,
                reservedVersion: 1)
            .toJson()
      }
    });
    storage.data[CloudEgressStore.kSecureKey] = on;
    File(p.join(support.path, CloudEgressStore.kFileName))
        .writeAsStringSync(on);
  }

  /// Process 1 for a Cloud OFF user: the same explicit sign-in and row, and
  /// Cloud durably OFF at consent version 1 in settings, both Dart layers and
  /// native (the user turned Cloud OFF); then the process dies.
  Future<void> accountWithCloudOffThenKill({bool neverEnabled = false}) async {
    final first =
        BootstrapRunner(debugAuthClient: await F2Fixture.liveClient(_uid))
          ..captureQueue = AsrSimQueue(sim);
    runners.add(first);
    await first.run();
    await session.completeOnboarding(
        method: 'google', email: '$_uid@example.com', userId: _uid);
    final db = first.accountScope.current!.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.customStatement(
        "INSERT INTO transactions(id, amount, amount_minor, currency, type, "
        "source, occurred_at, raw_message, parse_confidence, status, "
        "created_at, updated_at, raw_merchant, direction) VALUES "
        "('tx-1', 125.5, 12550, 'SAR', 'payment', 'manual', '$now', '', 1, "
        "'confirmed', '$now', '$now', 'Coffee Corner', 'debit');");
    final repo = DriftUserSettingsRepository(db);
    await repo.saveSettings((await repo.getSettings()).copyWith(
        cloudConsentState: ConsentState.declined, cloudConsentVersion: 1));
    expect(storage.data[SecureLocalReadStore.storageKey], isNotNull);
    await first.accountScope.detach();
    first.accountScope.dispose();
    runners.remove(first);
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    session.configureLocalRead(null);
    final off = jsonEncode({
      'v': 1,
      'records': {
        _uid: const CloudEgressRecord(
                state: EgressState.off,
                ownerUid: _uid,
                transitionGeneration: 2,
                reservedVersion: 1)
            .toJson()
      }
    });
    if (neverEnabled) {
      // Declining Cloud on first use never starts an egress transition.
      expect(storage.data[CloudEgressStore.kSecureKey], isNull);
      expect(File(p.join(support.path, CloudEgressStore.kFileName)).existsSync(),
          isFalse);
    } else {
      storage.data[CloudEgressStore.kSecureKey] = off;
      File(p.join(support.path, CloudEgressStore.kFileName))
          .writeAsStringSync(off);
    }
    // The earlier admission's restrictive publication (and the ON→OFF
    // transition) left a live native owner with an agreed OFF record
    // (`SharedCaptureStore.publishRestrictiveCaptureOwner`).
    sim
      ..ownerAlive = true
      ..generation = 3
      ..lastGeneration = 3
      ..epoch = 1
      ..egress = AsrEgressRecord(
          state: 'OFF',
          transitionGeneration: 2,
          reservedVersion: 1,
          lifeGeneration: 3,
          lifeEpoch: 1);
  }

  /// The coordinated session record of [_uid], committed with an access token
  /// that expired [expiredAgo] seconds ago (the device was offline).
  Future<void> commitExpiredRecord({int expiredAgo = 600}) async {
    final store = newStore();
    await store.load();
    final r = SessionRecord(
      ns: store.ns,
      installId: store.installId!,
      seq: store.nextSeqFloor + 1,
      lifecycle: store.lifecycleFloor + 1,
      kind: RecordKind.session,
      owner: _uid,
      session: canonicalSession(sessionJson(
          uid: _uid, exp: _now() - expiredAgo, refreshToken: 'refresh-1')),
      admission: AdmissionDisposition.ordinary,
    );
    expect(await store.write(r), WriteOutcome.committed);
  }

  /// Process 2: a NEW process over the durable state (fresh gate, native
  /// counters kept by the sim), the real coordinated bootstrap.
  Future<BootstrapRunner> bootProcess() async {
    BootstrapRunner.debugResetSdkInitializationLatch();
    ConsentAuthority.egressFrozen = false;
    ConsentAuthority.egressFreezeTag = '';
    CloudEgressGate.instance = CloudEgressGate(supabaseUrl: () => _url);
    NativeCaptureBridge.debugTreatHostAsNative = true;
    messenger.setMockMethodCallHandler(_channel, sim.handle);
    session.configureConsentSdkClient(() {
      try {
        return Supabase.instance.client;
      } catch (_) {
        return null;
      }
    });
    final r = BootstrapRunner(
        debugSdk: BootstrapSdkTestConfig(
      url: _url,
      innerHttp: MockClient((request) async {
        if (request.url.path == '/auth/v1/token' &&
            request.url.queryParameters['grant_type'] == 'id_token') {
          // The explicit provider exchange (account control, not ordinary).
          signIns.add(request);
          final exp = _now() + 3600;
          final body = sessionJson(
              uid: _uid, exp: exp, refreshToken: 'explicit-1')
            ..['expires_at'] = exp;
          (body['user'] as Map)['email'] = '$_uid@example.com';
          return http.Response(jsonEncode(body), 200,
              headers: {'content-type': 'application/json'});
        }
        requests.add(request);
        return http.Response('[]', 200,
            headers: {'content-type': 'application/json'});
      }),
      authCoordinator: () async {
        final c = AuthCoordinator(
            store: newStore(),
            gate: CloudEgressGate.instance,
            channelFactory: () => refreshChannelFactory?.call() ?? _Channel(script));
        coordinators.add(c);
        return c;
      },
    ))
      ..captureQueue = AsrSimQueue(sim)
      ..debugCaptureIsIos = () => true;
    runners.add(r);
    await r.run();
    return r;
  }

  /// The app comes to the foreground (or, already there, the resume trigger
  /// fires again): the production ASR trigger, then its completion.
  Future<void> resume() async {
    if (binding.lifecycleState != AppLifecycleState.resumed) {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    } else {
      AutomaticSessionRecovery.active!.trigger();
    }
    await AutomaticSessionRecovery.active?.quiesced();
  }

  String diag() {
    final asr = AutomaticSessionRecovery.active;
    return 'lastStop=${asr?.lastStop} native=${sim.methods} '
        'unmodelled=${sim.unmodelled} local=${session.asrLocalReadOwner} '
        'status=${session.status}';
  }

  Future<String> replicaId(BootstrapRunner r) async => (await r
          .accountScope.current!.database
          .customSelect('SELECT replica_id FROM replica_meta;')
          .getSingle())
      .read<String>('replica_id');

  Future<int> rows(BootstrapRunner r) async => (await r
          .accountScope.current!.database
          .customSelect('SELECT COUNT(*) AS c FROM transactions;')
          .getSingle())
      .read<int>('c');

  /// Whether native has applied the successor's finish (SE4) yet: until then
  /// no ordinary request may reach the transport.
  var finishApplied = false;

  void observeEgressOrder() {
    finishApplied = false;
    sim.afterApply = (m) {
      if (m == 'finishCloudEgressEnable' &&
          sim.pending == null &&
          sim.egress?.state == 'ON') {
        finishApplied = true;
      }
    };
  }

  /// Everything a completed recovery leaves: the same owner, replica, rows and
  /// consent; ordinary admission; native ON for the successor lifetime only;
  /// no pending, hold, freeze or exclusion left; the gate permits.
  Future<void> expectRecovered(BootstrapRunner r,
      {required String replica,
      required int priorGeneration,
      String token = 'refresh-2',
      String stop = 'recovered'}) async {
    final asr = AutomaticSessionRecovery.active!;
    expect(asr.lastStop, stop, reason: diag());
    final coord = AuthCoordinator.active!;
    final c = coord.store.committed!;
    expect(c.owner, _uid);
    expect(c.credential, CredentialState.live);
    expect(c.admission, AdmissionDisposition.ordinary);
    expect(c.adoption, isNull, reason: 'finalization settled');
    expect(c.sdkSession!.refreshToken, token);
    expect(coord.sdkDigest, c.digest);
    expect(coord.asrExclusion, isNull);
    expect(session.status, SessionStatus.authenticated);
    expect(session.asrLocalReadOwner, isNull);
    final scope = r.accountScope.current!;
    expect(scope.uid, _uid);
    expect(scope.isLocalRead, isFalse);
    expect(await replicaId(r), replica, reason: 'the same replica');
    expect(await rows(r), 1, reason: 'nothing deleted');
    final settings =
        await DriftUserSettingsRepository(scope.database).getSettings();
    expect(settings.cloudProcessingEnabled, isTrue);
    expect(settings.consentVersion, 1, reason: 'no consent version reserved');
    final layers =
        await CloudEgressGate.instance.store.readDartOwnerLayers(_uid);
    expect(layers.records.map((x) => x.state), [EgressState.on, EgressState.on]);
    expect(layers.records.map((x) => x.transitionGeneration), [1, 1],
        reason: 'Dart ON untouched (no new Dart ON written)');
    // Native: ON for G' only, consumed evidence, nothing pending.
    expect(sim.pending, isNull);
    final e = sim.egress!;
    expect(e.state, 'ON');
    expect(e.retirement, isNull);
    expect(sim.generation, greaterThan(priorGeneration));
    expect(e.lifeGeneration, sim.generation);
    expect(e.successorOf, isNotNull);
    // Dart: no pending, hold, freeze or unsettled successor; the gate permits.
    final gate = CloudEgressGate.instance;
    expect((await gate.readPending()).blocks(_uid), isFalse);
    expect(gate.holdActive, isFalse);
    expect(gate.successorUnsettled, isFalse);
    expect(gate.terminalDenied, isFalse);
    expect(ConsentAuthority.egressFrozen, isFalse,
        reason: ConsentAuthority.egressFreezeTag);
    expect(await gate.permits(), isTrue);
  }

  /// SE1–SE4 exactly once each, in order, counter-bound, among the native
  /// calls from index [from].
  void expectSuccessorChain({int from = 0}) {
    final calls = sim.calls.skip(from).toList();
    final m = [for (final c in calls) c.method];
    List<MethodCall> of(String name) =>
        calls.where((c) => c.method == name).toList();
    expect(m.indexOf('inspectRecoveryEvidence'), isNonNegative, reason: diag());
    final publish = of('publishRestrictiveCaptureOwner')
        .where((c) => (c.arguments as Map)['successorEvidenceId'] != null)
        .toList();
    expect(publish, hasLength(1), reason: 'SE1 exactly once');
    final begin = of('beginCloudEgressEnable')
        .where((c) => (c.arguments as Map)['successorEvidenceId'] != null)
        .toList();
    expect(begin, hasLength(1), reason: 'SE2 exactly once');
    expect((of('writeCloudEgressEnableOn').single.arguments
            as Map)['expectedCounter'],
        isNotNull,
        reason: 'SE3 counter-bound');
    final finish = of('finishCloudEgressEnable').single.arguments as Map;
    expect(finish['abandon'], isFalse);
    expect(finish['expectedCounter'], isNotNull, reason: 'SE4 counter-bound');
    expect(m.indexOf('publishRestrictiveCaptureOwner'),
        lessThan(m.indexOf('beginCloudEgressEnable')));
    expect(m.indexOf('beginCloudEgressEnable'),
        lessThan(m.indexOf('writeCloudEgressEnableOn')));
    expect(m.indexOf('writeCloudEgressEnableOn'),
        lessThan(m.indexOf('finishCloudEgressEnable')));
    expect(sim.unmodelled, isEmpty);
  }

  test('cold start: expired session → local read → ASR recovers through '
      'SE1–SE5 (E2-b); owner, replica and consent unchanged', () async {
    await accountWithCloudOnThenKill();
    await commitExpiredRecord();
    final r = await bootProcess();
    expect(session.asrLocalReadOwner, _uid, reason: diag());
    expect(r.accountScope.current!.isLocalRead, isTrue);
    final replica = await replicaId(r);
    expect(await session.asrEligibilityDenial(_uid), isNull, reason: diag());
    observeEgressOrder();
    expect(requests, isEmpty, reason: 'nothing left the device in local read');
    final before = requests.length;
    final early = <int>[];
    sim.onCall = (_) {
      if (!finishApplied && requests.length != before) early.add(requests.length);
    };
    await resume();
    expect(early, isEmpty,
        reason: 'no ordinary egress before the successor settled');
    expect(sim.of('mintExpiryEvidenceForLiveOn'), hasLength(1),
        reason: 'cold start: E2-b conditional retirement of the live ON');
    expectSuccessorChain();
    expect(finishApplied, isTrue);
    await expectRecovered(r, replica: replica, priorGeneration: 3);
    expect(script.sends, 1, reason: 'exactly one refresh exchange');
  });


  /// Polls (real time) until [done] holds.
  Future<void> until(bool Function() done,
      {Duration timeout = const Duration(seconds: 45), String? what}) async {
    final end = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('timed out: $what ${diag()}');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// A session-only recovery left Cloud exactly OFF: no Cloud transition in
  /// Dart or native, no ordinary request, and the gate still denies ordinary
  /// egress while it allows the session refresh.
  /// L2 (2026-11-14): a session-only recovery over a Cloud state that is not
  /// verified OFF recovers the session and never moves Cloud toward ON: no
  /// enable, no mint, no successor; the only native write is the restrictive
  /// owner publication, which leaves native OFF with the Cloud mirror off.
  void expectNativeCloudRestrictive(int nativeFrom) {
    final methods = sim.calls.skip(nativeFrom).map((c) => c.method).toSet();
    for (final m in [
      'mintExpiryEvidenceForLiveOn',
      'beginCloudEgressEnable',
      'writeCloudEgressEnableOn',
      'finishCloudEgressEnable',
    ]) {
      expect(methods.contains(m), isFalse, reason: m);
    }
    expect(
        sim.calls.skip(nativeFrom).where((c) =>
            c.method == 'publishRestrictiveCaptureOwner' &&
            (c.arguments as Map)['successorEvidenceId'] != null),
        isEmpty);
    expect(sim.egress?.state, 'OFF');
    expect(sim.mirror?['cloud'], isFalse);
  }

  Future<void> expectCloudStillOff(BootstrapRunner r, int nativeFrom,
      {bool dartAbsent = false}) async {
    final scope = r.accountScope.current!;
    final settings =
        await DriftUserSettingsRepository(scope.database).getSettings();
    expect(settings.cloudProcessingEnabled, isFalse);
    final layers =
        await CloudEgressGate.instance.store.readDartOwnerLayers(_uid);
    if (dartAbsent) {
      expect(layers.uncertain, isFalse);
      expect(layers.records, isEmpty,
          reason: 'session recovery must not invent a Cloud choice');
    } else {
      expect(
          layers.records.map((x) => x.state), [EgressState.off, EgressState.off]);
      expect(layers.records.map((x) => x.transitionGeneration), [2, 2]);
    }
    final methods = sim.calls.skip(nativeFrom).map((c) => c.method).toSet();
    for (final m in [
      'mintExpiryEvidenceForLiveOn',
      'beginCloudEgressEnable',
      'writeCloudEgressEnableOn',
      'finishCloudEgressEnable',
    ]) {
      expect(methods.contains(m), isFalse, reason: m);
    }
    expect(
        sim.calls.skip(nativeFrom).where((c) =>
            c.method == 'publishRestrictiveCaptureOwner' &&
            (c.arguments as Map)['successorEvidenceId'] != null),
        isEmpty);
    expect(sim.egress?.state ?? 'OFF', 'OFF');
    expect(sim.pending, isNull);
    expect(sim.unmodelled, isEmpty);
    expect(requests, isEmpty,
        reason: 'only the token exchange left the device');
    final gate = CloudEgressGate.instance;
    expect(await gate.permits(), isFalse);
    expect(await gate.permitsSessionRefresh(), isTrue);
    expect(gate.holdActive, isFalse);
    expect(gate.terminalDenied, isFalse);
    expect(ConsentAuthority.egressFrozen, isFalse,
        reason: ConsentAuthority.egressFreezeTag);
  }

  // Owner decision (2026-10-29): session-only recovery while Cloud is OFF.
  for (final cloudOn in [false, true]) {
    test('recovery presentation: Cloud ON=$cloudOn never routes through Auth '
        'before successful session publication', () async {
      if (cloudOn) {
        await accountWithCloudOnThenKill();
      } else {
        await accountWithCloudOffThenKill(neverEnabled: true);
      }
      await commitExpiredRecord();
      final runner = await bootProcess();
      await session.markWelcomeManifestoSeen();
      final reply = Completer<void>();
      script.hold = reply;
      // Hold the real identity write after writable scope publication. This
      // was the window where the router selected Auth despite recovery still
      // running and ultimately succeeding without a new provider sign-in.
      final identity = storage.holdOnce((op, key) =>
          op == 'write' && key == 'onboarding_current_account_v1');
      final state = GoRouterState(appRouter.configuration,
          uri: Uri(path: '/'), matchedLocation: '/', fullPath: '/',
          pathParameters: const {}, pageKey: const ValueKey('/'));
      try {
        final attempt = resume();
        await until(() => script.sends == 1, what: 'refresh request');
        reply.complete();
        await identity.reached.future.timeout(const Duration(seconds: 10));
        expect(AutomaticSessionRecovery.active!.running, isTrue);
        expect(AutomaticSessionRecovery.restoringSession.value, isTrue);
        expect(runner.accountScope.current!.isLocalRead, isFalse);
        expect(session.status, SessionStatus.sessionExpired);
        expect(await appRouter.configuration.topRedirect(_RedirectContext(), state),
            isNull, reason: 'stay on the recovery loader until adoption finishes');
        identity.release.complete();
        await attempt;
        expect(AutomaticSessionRecovery.active!.lastStop, 'recovered', reason: diag());
        expect(AutomaticSessionRecovery.restoringSession.value, isFalse);
        expect(session.status, SessionStatus.authenticated);
        expect(await appRouter.configuration.topRedirect(_RedirectContext(), state), isNull);
        expect(signIns, isEmpty, reason: 'no explicit sign-in was needed');
        if (cloudOn) {
          expect(sim.egress?.state, 'ON');
        } else {
          await expectCloudStillOff(runner, 0, dartAbsent: true);
        }
      } finally {
        if (!reply.isCompleted) reply.complete();
        if (!identity.release.isCompleted) identity.release.complete();
        await AutomaticSessionRecovery.active?.quiesced();
      }
    });
  }

  test(
      'Cloud OFF cold start: expired session → local read → the session '
      'alone recovers; Cloud stays OFF, owner, replica and rows unchanged',
      () async {
    await accountWithCloudOffThenKill();
    await commitExpiredRecord();
    final r = await bootProcess();
    expect(session.asrLocalReadOwner, _uid, reason: diag());
    final replica = await replicaId(r);
    expect(await session.asrEligibilityDenial(_uid), isNull, reason: diag());
    final nativeFrom = sim.calls.length;
    await resume();
    final asr = AutomaticSessionRecovery.active!;
    expect(asr.lastStop, 'recovered', reason: diag());
    expect(script.sends, 1, reason: 'exactly one refresh exchange');
    final coord = AuthCoordinator.active!;
    final c = coord.store.committed!;
    expect(c.admission, AdmissionDisposition.ordinary);
    expect(c.adoption, isNull);
    expect(c.sdkSession!.refreshToken, 'refresh-2');
    expect(coord.sdkDigest, c.digest);
    expect(coord.asrExclusion, isNull);
    expect(session.status, SessionStatus.authenticated);
    expect(session.asrLocalReadOwner, isNull);
    expect(r.accountScope.current!.isLocalRead, isFalse);
    expect(r.accountScope.current!.uid, _uid);
    expect(await replicaId(r), replica);
    expect(await rows(r), 1);
    await expectCloudStillOff(r, nativeFrom);
  });

  test('Cloud never enabled: expired session recovers without Cloud consent '
      'or egress records, preserving the replica', () async {
    await accountWithCloudOffThenKill(neverEnabled: true);
    await commitExpiredRecord();
    final r = await bootProcess();
    final replica = await replicaId(r);
    expect(session.asrLocalReadOwner, _uid, reason: diag());
    final nativeFrom = sim.calls.length;
    await resume();
    expect(AutomaticSessionRecovery.active!.lastStop, 'recovered', reason: diag());
    expect(script.sends, 1);
    expect(session.status, SessionStatus.authenticated);
    expect(session.asrLocalReadOwner, isNull);
    expect(r.accountScope.current!.isLocalRead, isFalse);
    expect(await replicaId(r), replica);
    expect(await rows(r), 1);
    await expectCloudStillOff(r, nativeFrom, dartAbsent: true);
  });

  test('L2: Cloud never enabled in Dart over native ON recovers the session '
      'only, Cloud only restricted', () async {
    await accountWithCloudOffThenKill(neverEnabled: true);
    sim.seedLiveOn(transitionGeneration: 1, reservedVersion: 1);
    await commitExpiredRecord();
    await bootProcess();
    final nativeFrom = sim.calls.length;
    await resume();
    expect(AutomaticSessionRecovery.active!.lastStop, 'recovered',
        reason: diag());
    expect(script.sends, 1);
    expect(session.status, SessionStatus.authenticated);
    expect(requests, isEmpty, reason: 'only the token exchange');
    expectNativeCloudRestrictive(nativeFrom);
  });

  test('Cloud OFF cold start recovers through the real gzip HTTPS transport',
      () async {
    final tls = await TlsFixture.create();
    if (tls == null) return markTestSkipped('openssl unavailable');
    final server =
        await HttpServer.bindSecure('localhost', 0, tls.serverContext);
    final received = <Map<String, dynamic>>[];
    final exchanges = <RefreshExchange>[];
    final serving = server.listen((req) async {
      received.add({
        'path': req.uri.path,
        'query': req.uri.queryParameters,
        'body': jsonDecode(await utf8.decodeStream(req)),
        'encoding': req.headers.value(HttpHeaders.acceptEncodingHeader),
      });
      final body = sessionJson(
          uid: _uid, exp: _now() + 3600, refreshToken: 'refresh-2');
      req.response.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.contentEncodingHeader, 'gzip');
      req.response.add(gzip.encode(utf8.encode(jsonEncode(body))));
      await req.response.close();
    });
    addTearDown(() async {
      for (final ex in exchanges) {
        ex.cancel();
        await ex.quiesced();
      }
      await serving.cancel();
      await server.close(force: true);
      await tls.dispose();
    });
    await accountWithCloudOffThenKill();
    await commitExpiredRecord();
    refreshChannelFactory = () {
      // Bypass the widget binding's canned HTTP 400 only for this loopback
      // TLS exchange; the app's ordinary transport remains the mock above.
      final ex = HttpOverrides.runWithHttpOverrides(
        () => RefreshExchange(
          tokenUri: Uri.parse(
              'https://localhost:${server.port}/auth/v1/token?grant_type=refresh_token'),
          apiKey: 'synthetic-anon-key',
          context: tls.clientContext,
        ),
        _LoopbackHttpOverrides(),
      );
      exchanges.add(ex);
      return ex;
    };
    final r = await bootProcess();
    final replica = await replicaId(r);
    final nativeFrom = sim.calls.length;
    await resume();

    expect(AutomaticSessionRecovery.active!.lastStop, 'recovered',
        reason: diag());
    expect(received, hasLength(1),
        reason: 'a valid compressed reply must not burn all three sends');
    expect(received.single, {
      'path': '/auth/v1/token',
      'query': {'grant_type': 'refresh_token'},
      'body': {'refresh_token': 'refresh-1'},
      'encoding': 'gzip',
    });
    final coord = AuthCoordinator.active!;
    final c = coord.store.committed!;
    expect(c.sdkSession!.refreshToken, 'refresh-2');
    expect(c.tokenDispatches, isNull);
    expect(c.refreshOp, isNull);
    expect(c.admission, AdmissionDisposition.ordinary);
    expect(c.adoption, isNull);
    expect(coord.sdkDigest, c.digest);
    expect(session.status, SessionStatus.authenticated);
    expect(session.asrLocalReadOwner, isNull);
    expect(r.accountScope.current!.isLocalRead, isFalse);
    expect(await replicaId(r), replica);
    expect(await rows(r), 1);
    await expectCloudStillOff(r, nativeFrom);
  });

  test(
      'Cloud OFF normal mode: the routine scheduler refreshes the session '
      'before it expires, with nothing else leaving the device', () async {
    await accountWithCloudOffThenKill();
    await commitExpiredRecord();
    final r = await bootProcess();
    final nativeFrom = sim.calls.length;
    // The recovery's token expires in 125 s; the routine op is due at 35 s.
    script.result = () => _Script.ok(
        token: 'refresh-${script.sends + 1}',
        expIn: script.sends == 1 ? 125 : 3600);
    await resume();
    expect(AutomaticSessionRecovery.active!.lastStop, 'recovered',
        reason: diag());
    await until(() => script.sends == 2,
        timeout: const Duration(seconds: 60), what: 'routine refresh');
    await until(
        () =>
            AuthCoordinator.active!.store.committed?.sdkSession?.refreshToken ==
            'refresh-3',
        what: 'routine commit');
    final coord = AuthCoordinator.active!;
    // The install follows the commit.
    await until(() => coord.sdkDigest == coord.store.committed!.digest,
        what: 'routine install');
    expect(session.status, SessionStatus.authenticated);
    expect(session.asrLocalReadOwner, isNull);
    await expectCloudStillOff(r, nativeFrom);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
      'L2: Cloud OFF normal mode: a native-only pending enable does not stop '
      'the routine refresh; nothing else leaves the device', () async {
    await accountWithCloudOffThenKill();
    await commitExpiredRecord();
    await bootProcess();
    script.result = () => _Script.ok(
        token: 'refresh-${script.sends + 1}',
        expIn: script.sends == 1 ? 125 : 3600);
    await resume();
    expect(AutomaticSessionRecovery.active!.lastStop, 'recovered',
        reason: diag());
    sim.pending = {'ownerUid': _uid, 'operationId': 'native-only'};
    expect(await CloudEgressGate.instance.permitsSessionRefresh(), isTrue);
    expect(await CloudEgressGate.instance.permits(), isFalse);
    // The routine op is due at 35 s.
    await until(() => script.sends == 2,
        timeout: const Duration(seconds: 60), what: 'routine refresh');
    expect(session.status, SessionStatus.authenticated);
    expect(requests, isEmpty, reason: 'only the token exchange');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
      'L2: Cloud OFF with native ON (layers disagree) recovers the session '
      'only, Cloud only restricted', () async {
    await accountWithCloudOffThenKill();
    sim.seedLiveOn(transitionGeneration: 1, reservedVersion: 1);
    await commitExpiredRecord();
    await bootProcess();
    final nativeFrom = sim.calls.length;
    await resume();
    expect(AutomaticSessionRecovery.active!.lastStop, 'recovered',
        reason: diag());
    expect(script.sends, 1);
    expect(session.status, SessionStatus.authenticated);
    expect(requests, isEmpty, reason: 'only the token exchange');
    expectNativeCloudRestrictive(nativeFrom);
  });

  test('PROBE latency', () async {
    AuthDiagnostics.debugReset();
    await accountWithCloudOffThenKill();
    await commitExpiredRecord();
    script.latency = const Duration(milliseconds: 400);
    await bootProcess();
    await resume();
    await Future<void>.delayed(const Duration(seconds: 20));
    // ignore: avoid_print
    print('PROBE ${diag()}\n${AuthDiagnostics.entries.value.join('\n')}');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a second cold recovery preserves the grant and restores the same replica', () async {
    AuthDiagnostics.debugReset();
    await accountWithCloudOffThenKill();
    await commitExpiredRecord();
    script.latency = const Duration(milliseconds: 400);
    script.result = () => _Script.ok(token: 'refresh-${script.sends + 1}');
    final r1 = await bootProcess();
    final originalReplica = await replicaId(r1);
    await resume();
    expect(AutomaticSessionRecovery.active!.lastStop, 'recovered');
    // The process dies (as the tear-down models it); the token expires.
    AutomaticSessionRecovery.active?.dispose();
    AutomaticSessionRecovery.active = null;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // Process death closes handles; it does not perform a sign-out/registry lock.
    await r1.accountScope.detach();
    await session.debugResetAuthBinding();
    r1.accountScope.dispose();
    runners.remove(r1);
    for (final c in coordinators) {
      c.dispose();
    }
    coordinators.clear();
    AuthCoordinator.active = null;
    if (Supabase.instance.isInitialized) await Supabase.instance.dispose();
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    session.configureLocalRead(null);
    final store = newStore();
    await store.load();
    final c = store.committed!;
    final grantBefore = LocalReadGrantRecord.tryDecode(
        storage.data[SecureLocalReadStore.storageKey]);
    expect(grantBefore!.state, LocalReadGrantState.committed);
    expect(grantBefore.uid, _uid);

    expect(
        await store.write(c.copyWith(
            seq: c.seq + 1,
            session: canonicalSession(sessionJson(
                uid: _uid,
                exp: _now() - 600,
                refreshToken: c.sdkSession!.refreshToken!)))),
        WriteOutcome.committed);
    final second = await bootProcess();
    final grantAfter = LocalReadGrantRecord.tryDecode(
        storage.data[SecureLocalReadStore.storageKey]);
    expect(grantAfter!.operationId, grantBefore.operationId);
    expect(second.accountScope.current!.isLocalRead, isTrue);
    await resume();
    await Future<void>.delayed(const Duration(seconds: 20));
    expect(AutomaticSessionRecovery.active!.lastStop, 'recovered',
        reason: diag());
    expect(script.sends, 2);
    expect(session.status, SessionStatus.authenticated);
    expect(second.accountScope.current!.isLocalRead, isFalse);
    expect(second.accountScope.current!.uid, _uid);
    expect(await replicaId(second), originalReplica);
    expect(await rows(second), 1);

  }, timeout: const Timeout(Duration(minutes: 2)));

  // Astra (Cloud OFF review) B1: native absence is not proof of OFF.
  test(
      'L2: Cloud OFF with no native record recovers the session only, '
      'Cloud only restricted', () async {
    await accountWithCloudOffThenKill();
    sim.egress = null;
    await commitExpiredRecord();
    await bootProcess();
    final nativeFrom = sim.calls.length;
    await resume();
    expect(AutomaticSessionRecovery.active!.lastStop, 'recovered',
        reason: diag());
    expect(script.sends, 1);
    expect(session.status, SessionStatus.authenticated);
    expectNativeCloudRestrictive(nativeFrom);
  });

  /// Cold start and a first recovery whose new token expires [expiresIn]
  /// seconds later, while the device has gone offline. The process now holds
  /// its OWN native lifetime: the successor G' (SE1 receipt, rebound to the
  /// successor's enable at SE3). The shell's resume revalidation then sees the
  /// expired SDK session: the plain-expiry fence (§7.2) retires G' and mints
  /// expiry evidence, and the scope moves to local read.
  Future<({BootstrapRunner runner, int nativeMark})> recoveredThenWarmExpiry(
      {int expiresIn = 125}) async {
    await accountWithCloudOnThenKill();
    await commitExpiredRecord();
    final r = await bootProcess();
    // One exchange answers (the recovery's); then the device is offline.
    script.result = () {
      script.offline = true;
      return _Script.ok(expIn: expiresIn);
    };
    await resume();
    expect(AutomaticSessionRecovery.active!.lastStop, 'recovered',
        reason: diag());
    final successor = sim.generation;
    // Real time: the SDK reads the wall clock (expiry margin 30 s), and the
    // recovery's install needs more than 120 s of remaining lifetime.
    await until(
        () => Supabase.instance.client.auth.currentSession?.isExpired ?? false,
        timeout: Duration(seconds: expiresIn),
        what: 'sdk expiry');
    // Publishing local read can start ASR immediately, before this helper
    // returns. Observe the native calls before the transition starts.
    final nativeMark = sim.calls.length;
    await session.revalidateSupabaseSessionOnResume(Supabase.instance.client);
    await until(() => session.asrLocalReadOwner == _uid, what: 'local read');
    await session.nativeLifecycleSettled();
    final e = sim.egress!;
    expect(sim.of('revokeCaptureAuthorizationLifetime'), hasLength(1),
        reason: diag());
    expect(e.state, 'OFF');
    expect(e.evidence, isNotNull, reason: 'the expiry fence minted evidence');
    expect(e.evidence!['ownerGeneration'], successor,
        reason: 'the fence retired exactly the successor lifetime G\'');
    expect(r.accountScope.current!.isLocalRead, isTrue);
    expect(await CloudEgressGate.instance.permits(), isFalse);
    expect(await session.asrEligibilityDenial(_uid), isNull, reason: diag());
    return (runner: r, nativeMark: nativeMark);
  }

  test('warm expiry: a recovered process expires again offline → its own '
      'fence evidence (E2-a) → ASR recovers through SE1–SE5 to G\'\'',
      () async {
    final (runner: r, nativeMark: mark) = await recoveredThenWarmExpiry();
    final replica = await replicaId(r);
    final prior = sim.generation;
    script.result = () => _Script.ok(token: 'refresh-3');
    script.offline = false;
    observeEgressOrder();
    final before = requests.length;
    final early = <int>[];
    sim.onCall = (_) {
      if (!finishApplied && requests.length != before) early.add(requests.length);
    };
    await resume();
    expect(early, isEmpty,
        reason: 'no ordinary egress before the successor settled');
    expect(sim.calls.skip(mark).where((call) =>
        call.method == 'mintExpiryEvidenceForLiveOn'), isEmpty,
        reason: 'warm expiry: E2-a, the fence\'s own evidence');
    expectSuccessorChain(from: mark);
    await expectRecovered(r,
        replica: replica, priorGeneration: prior, token: 'refresh-3');
  }, timeout: const Timeout(Duration(minutes: 4)));

  // ── failures ─────────────────────────────────────────────────────────────

  Future<BootstrapRunner> coldLocalRead() async {
    await accountWithCloudOnThenKill();
    await commitExpiredRecord();
    final r = await bootProcess();
    expect(session.asrLocalReadOwner, _uid, reason: diag());
    return r;
  }

  bool successorCall(MethodCall c) =>
      (c.arguments as Map?)?['successorEvidenceId'] != null;

  /// What a run that never withdrew local read leaves: the same read-only
  /// scope and rows, nothing ordinary egresses, and no hold or exclusion.
  Future<void> expectStillLocalRead(BootstrapRunner r) async {
    expect(session.asrLocalReadOwner, _uid, reason: diag());
    expect(r.accountScope.current!.isLocalRead, isTrue);
    expect(await rows(r), 1);
    final gate = CloudEgressGate.instance;
    expect(gate.holdActive, isFalse);
    expect(AuthCoordinator.active!.asrExclusion, isNull);
    expect(await gate.permits(), isFalse);
    expect(requests, isEmpty, reason: 'nothing ordinary left the device');
  }

  /// A recovery whose successor was retired: signed in on the same replica
  /// and rows, finalization settled, nothing pending, native OFF — Cloud
  /// restrictive, nothing ordinary egresses.
  Future<void> expectRetiredSignedIn(BootstrapRunner r,
      {required String replica, required String stop}) async {
    final asr = AutomaticSessionRecovery.active!;
    expect(asr.lastStop, stop, reason: diag());
    final coord = AuthCoordinator.active!;
    final c = coord.store.committed!;
    expect(c.adoption, isNull, reason: 'finalization settled');
    expect(c.admission, AdmissionDisposition.ordinary);
    expect(coord.asrExclusion, isNull);
    expect(session.status, SessionStatus.authenticated);
    expect(r.accountScope.current!.isLocalRead, isFalse);
    expect(await replicaId(r), replica);
    expect(await rows(r), 1);
    expect(sim.pending, isNull);
    expect(sim.egress!.state, 'OFF', reason: 'G\' retired, never left ON');
    final gate = CloudEgressGate.instance;
    expect((await gate.readPending()).blocks(_uid), isFalse);
    expect(gate.successorUnsettled, isFalse);
    expect(gate.holdActive, isFalse);
    expect(await gate.permits(), isFalse);
    expect(requests, isEmpty);
  }

  test('foreground loss before acceptance cancels the exchange (decision a): '
      'nothing installed, local read and evidence kept; a later resume '
      'recovers', () async {
    final r = await coldLocalRead();
    script.hold = Completer<void>();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await until(() => script.sends == 1, what: 'exchange sent');
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final asr = AutomaticSessionRecovery.active!;
    await asr.quiesced();
    script.hold!.complete(); // the late response: nobody accepts it
    script.hold = null;
    expect(asr.lastStop, startsWith('refresh:'), reason: diag());
    final c = AuthCoordinator.active!.store.committed!;
    expect(c.sdkSession!.refreshToken, 'refresh-1',
        reason: 'the late response was never installed');
    expect(c.adoption, isNull);
    expect(sim.calls.where(successorCall), isEmpty, reason: 'no SE1/SE2');
    expect(sim.egress!.evidence, isNotNull, reason: 'evidence kept');
    await expectStillLocalRead(r);
    final replica = await replicaId(r);
    await resume();
    await expectRecovered(r, replica: replica, priorGeneration: 3);
  });

  test('an uncertain finalizing write is resolved before branching (B2) and '
      'the recovery completes', () async {
    final r = await coldLocalRead();
    final replica = await replicaId(r);
    var lost = 0;
    keychain.onWrite = (v) {
      final rec = SessionRecord.decode(v);
      if (lost == 0 && rec.adoption?.state == AdoptionState.finalizing) {
        lost++;
        keychain.loseNextWriteReply = true;
      }
    };
    await resume();
    expect(lost, 1);
    expectSuccessorChain();
    await expectRecovered(r, replica: replica, priorGeneration: 3);
  });

  test('native finish applied but unanswered (8 s timeout): the lost-reply '
      'rule reads it finished and the recovery completes', () async {
    final r = await coldLocalRead();
    final replica = await replicaId(r);
    sim.fault('finishCloudEgressEnable', AsrSimFault.noReply);
    await resume();
    expect(sim.of('inspectSuccessor'), hasLength(1));
    await expectRecovered(r, replica: replica, priorGeneration: 3);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('native finish never executed and unanswered: read as not executed, '
      'the successor is compensated exactly; signed in, Cloud restrictive, '
      'nothing ordinary egresses', () async {
    final r = await coldLocalRead();
    final replica = await replicaId(r);
    sim.fault('finishCloudEgressEnable', AsrSimFault.noReplyBeforeApply);
    await resume();
    final asr = AutomaticSessionRecovery.active!;
    expect(asr.lastStop, 'recovered', reason: diag());
    expect(sim.of('inspectSuccessor'), hasLength(1));
    // Settled by restrict + abandon of exactly this op.
    expect(sim.methods, containsAllInOrder(
        ['restrictCloudEgressEnable', 'finishCloudEgressEnable']));
    expect(sim.pending, isNull);
    expect(sim.egress!.state, 'OFF');
    final c = AuthCoordinator.active!.store.committed!;
    expect(c.adoption, isNull, reason: 'settled, so finalization completed');
    expect(session.status, SessionStatus.authenticated);
    expect(r.accountScope.current!.isLocalRead, isFalse);
    expect(await replicaId(r), replica);
    expect(await rows(r), 1);
    final gate = CloudEgressGate.instance;
    expect((await gate.readPending()).blocks(_uid), isFalse);
    expect(gate.holdActive, isFalse);
    expect(await gate.permits(), isFalse,
        reason: 'native is restrictive: no ordinary egress');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('foreground inactive after accepted refresh finishes adoption without signing out', () async {
    final r = await coldLocalRead();
    final replica = await replicaId(r);
    sim.onCall = (method) {
      if (method == 'beginCloudEgressEnable') {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      }
    };
    await resume();
    expect(binding.lifecycleState, AppLifecycleState.inactive);
    expect(AutomaticSessionRecovery.active!.lastStop, 'recovered', reason: diag());
    expect(session.status, SessionStatus.authenticated);
    expect(await replicaId(r), replica);
    expect(sim.egress!.state, 'ON');
    expect(signIns, isEmpty);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await AutomaticSessionRecovery.active!.quiesced();
  });

  test('foreground loss after withdrawal (decision c): compensated exactly, '
      'sign-in screen, terminal denial, data preserved', () async {
    final r = await coldLocalRead();
    sim.onCall = (m) {
      if (m == 'beginCloudEgressEnable') {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      }
    };
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final asr = AutomaticSessionRecovery.active!;
    await asr.quiesced();
    expect(asr.lastStop, 'failed_after_withdrawal', reason: diag());
    // Native: the successor never stays enabled.
    expect(sim.pending, isNull, reason: diag());
    expect(sim.egress!.state, 'OFF');
    final gate = CloudEgressGate.instance;
    expect(gate.terminalDenied, isTrue);
    expect(gate.holdActive, isFalse);
    expect(await gate.permits(), isFalse);
    expect((await gate.readPending()).blocks(_uid), isFalse);
    final coord = AuthCoordinator.active!;
    expect(coord.asrExclusion, isNull);
    expect(coord.store.committed!.adoption?.state, AdoptionState.failed);
    expect(session.status, isNot(SessionStatus.authenticated));
    expect(session.asrLocalReadOwner, isNull);
    expect(requests, isEmpty);
    // Data preserved: the replica and its rows are still on disk.
    expect(storage.data['local_data_owner_uid'], _uid);
    final entry = await r.accountScope.store.list();
    expect(entry, isNotEmpty);
  });

  test('B2: an unsettled finalization keeps finalizing (generic capture '
      'reconciliation blocked, no egress) and is reconciled first, in order, '
      'by the next trigger', () async {
    final r = await coldLocalRead();
    final replica = await replicaId(r);
    sim.fault('finishCloudEgressEnable', AsrSimFault.noReply);
    sim.fault('inspectSuccessor', AsrSimFault.platformError);
    sim.fault('retireSuccessor', AsrSimFault.platformError);
    await resume();
    final asr = AutomaticSessionRecovery.active!;
    final coord = AuthCoordinator.active!;
    // The finish ran natively but nothing could be confirmed or settled.
    expect(coord.store.committed!.adoption?.state, AdoptionState.finalizing,
        reason: diag());
    expect(asr.unsettledFinalizationOwner, _uid);
    final gate = CloudEgressGate.instance;
    expect(gate.successorUnsettled, isTrue,
        reason: 'generic capture reconciliation is blocked');
    expect(await gate.permits(), isFalse,
        reason: 'the Dart pending still denies');
    expect(requests, isEmpty);
    // The next trigger (the backoff retry) reconciles before anything else.
    await until(() => coord.store.committed!.adoption == null,
        what: 'ordered reconciliation');
    await asr.quiesced();
    // Phase 4c: a finish that may have run is retired, never cleared to ON,
    // whatever native reports now — the failed retirement is retried.
    expect(sim.of('retireSuccessor'), hasLength(2), reason: diag());
    await expectRetiredSignedIn(r, replica: replica, stop: 'finalization');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('Phase 4c B2: a loss after the confirmed finish whose retirement fails '
      'keeps the retirement required: the retry retires G\' instead of '
      'completing with native ON', () async {
    final r = await coldLocalRead();
    final replica = await replicaId(r);
    sim.afterApply = (m) {
      if (m == 'finishCloudEgressEnable') {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      }
    };
    sim.fault('retireSuccessor', AsrSimFault.platformError);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final asr = AutomaticSessionRecovery.active!;
    await asr.quiesced();
    sim.afterApply = null;
    final coord = AuthCoordinator.active!;
    final a = coord.store.committed!.adoption;
    expect(a?.state, AdoptionState.finalizing, reason: diag());
    expect(a?.successor?.finish, FinishState.confirmed);
    expect(sim.egress!.state, 'ON', reason: 'the retirement failed');
    expect(await CloudEgressGate.instance.permits(), isFalse,
        reason: 'the Dart pending still denies');
    expect(requests, isEmpty);
    // The retry (on the next resume) must retire, not clear to ON.
    await resume();
    await until(() => coord.store.committed!.adoption == null,
        what: 'ordered reconciliation');
    await asr.quiesced();
    expect(sim.of('retireSuccessor'), hasLength(2), reason: diag());
    await expectRetiredSignedIn(r, replica: replica, stop: 'finalization');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('Phase 4c B2: an unresolvable finalizing write selects no branch — the '
      'successor stays restrictive and the exclusion held; once readable, '
      'the landed write is reconciled, never signed out', () async {
    final r = await coldLocalRead();
    final replica = await replicaId(r);
    keychain.onWrite = (v) {
      if (SessionRecord.decode(v).adoption?.state ==
          AdoptionState.finalizing) {
        keychain.loseNextWriteReply = true;
        keychain.readStatus = KeychainStatus.error;
      }
    };
    await resume();
    keychain.onWrite = null;
    final asr = AutomaticSessionRecovery.active!;
    final coord = AuthCoordinator.active!;
    expect(asr.lastStop, 'adoption_unresolved', reason: diag());
    expect(asr.adoptionUnresolved, isTrue);
    expect(coord.asrExclusion, isNotNull, reason: 'exclusion kept');
    expect(sim.pending, isNotNull, reason: 'native barrier kept');
    expect(sim.of('finishCloudEgressEnable'), isEmpty);
    expect(sim.of('retireSuccessor'), isEmpty);
    final gate = CloudEgressGate.instance;
    expect(gate.terminalDenied, isFalse, reason: 'no failure branch taken');
    expect(gate.holdActive, isFalse);
    expect(await gate.permits(), isFalse);
    expect(session.status, SessionStatus.authenticated, reason: 'not signed out');
    expect(requests, isEmpty);
    // Readable again: the durable `finalizing{awaiting}` is reconciled.
    keychain.readStatus = null;
    await resume();
    await until(() => !asr.adoptionUnresolved && coord.store.committed!.adoption == null,
        what: 'resolution');
    await asr.quiesced();
    expect(coord.asrExclusion, isNull);
    expect(sim.of('finishCloudEgressEnable').where(
        (c) => (c.arguments as Map)['abandon'] == false), isEmpty,
        reason: 'never an automatic finish of awaiting');
    expect(sim.pending, isNull);
    expect(sim.egress!.state, 'OFF');
    expect(coord.store.committed!.admission, AdmissionDisposition.ordinary);
    expect(session.status, SessionStatus.authenticated);
    expect(r.accountScope.current!.isLocalRead, isFalse);
    expect(await replicaId(r), replica);
    expect(await rows(r), 1);
    expect(await gate.permits(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('Phase 4c B2: an unresolvable finalizing write that never landed is, '
      'once readable, the failure after withdrawal (sign-in, data kept)',
      () async {
    final r = await coldLocalRead();
    keychain.dropWrite = (v) {
      if (SessionRecord.decode(v).adoption?.state !=
          AdoptionState.finalizing) {
        return false;
      }
      keychain.dropWrite = null;
      keychain.readStatus = KeychainStatus.error;
      return true;
    };
    await resume();
    final asr = AutomaticSessionRecovery.active!;
    final coord = AuthCoordinator.active!;
    expect(asr.lastStop, 'adoption_unresolved', reason: diag());
    expect(CloudEgressGate.instance.terminalDenied, isFalse);
    keychain.readStatus = null;
    await resume();
    await until(() => !asr.adoptionUnresolved, what: 'resolution');
    await asr.quiesced();
    expect(coord.store.committed!.adoption?.state, AdoptionState.failed,
        reason: diag());
    expect(coord.asrExclusion, isNull);
    final gate = CloudEgressGate.instance;
    expect(gate.terminalDenied, isTrue);
    expect(sim.pending, isNull);
    expect(sim.egress!.state, 'OFF');
    expect(session.status, isNot(SessionStatus.authenticated));
    expect(requests, isEmpty);
    expect(storage.data['local_data_owner_uid'], _uid, reason: 'data kept');
    expect(await r.accountScope.store.list(), isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('Phase 4c B2: releasing the successor freeze keeps a foreign freeze '
      'taken meanwhile (Cloud disable)', () async {
    final r = await coldLocalRead();
    final replica = await replicaId(r);
    sim.onCall = (m) {
      if (m == 'writeCloudEgressEnableOn') ConsentAuthority.freeze('disable');
    };
    await resume();
    sim.onCall = null;
    expect(AutomaticSessionRecovery.active!.lastStop, 'recovered',
        reason: diag());
    expect(await replicaId(r), replica);
    expect(ConsentAuthority.egressFrozen, isTrue,
        reason: 'the newer freeze survives the successor\'s release');
    expect(ConsentAuthority.egressFreezeTag, 'disable');
    expect(await CloudEgressGate.instance.permits(), isFalse);
  });

  test('Phase 4c B1: a removal barrier that appears after eligibility stops '
      'ASR without running removal recovery; the barrier stays owned by the '
      'removal workflow and nothing is deleted', () async {
    final r = await coldLocalRead();
    final hash = await r.accountScope.store.uidHash(_uid);
    // A well-formed record of a removal of this uid (local only), as the
    // removal workflow writes it — recovery WOULD execute it.
    final barrier = jsonEncode(
        {'uid': _uid, 'uidHash': hash, 'revoke': true, 'localOnly': true});
    keychain.onWrite = (v) {
      if (SessionRecord.decode(v).adoption?.state == AdoptionState.pending) {
        storage.data['qirsh.removal_barrier.v1'] = barrier;
      }
    };
    await resume();
    keychain.onWrite = null;
    final asr = AutomaticSessionRecovery.active!;
    expect(asr.lastStop, isNot('recovered'), reason: diag());
    expect(storage.data['qirsh.removal_barrier.v1'], barrier,
        reason: 'the barrier is not consumed by ASR');
    expect(storage.data['local_data_owner_uid'], _uid,
        reason: 'ownership not cleared');
    expect((await r.accountScope.store.list()).map((e) => e.uidHash),
        contains(hash),
        reason: 'the replica is not removed');
    expect(sim.calls.where(successorCall), isEmpty, reason: 'no SE1');
    expect(requests, isEmpty);
  });

  test('logout from local read while the exchange is in flight: the late '
      'response is never installed, nothing is published, the record is '
      'removed', () async {
    final r = await coldLocalRead();
    script.hold = Completer<void>();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await until(() => script.sends == 1, what: 'exchange sent');
    // The local-read shell's logout: the local sign-out, then the durable
    // removal of the session record (§4.9).
    await session.signOut();
    await AuthCoordinator.logout(Supabase.instance.client.auth);
    script.hold!.complete();
    script.hold = null;
    final asr = AutomaticSessionRecovery.active!;
    await asr.quiesced();
    expect(asr.lastStop, isNot('recovered'), reason: diag());
    final coord = AuthCoordinator.active!;
    final c = coord.store.committed;
    expect(c == null || c.isTombstone, isTrue, reason: 'record removed');
    expect(Supabase.instance.client.auth.currentSession?.refreshToken,
        isNot('refresh-2'));
    expect(sim.calls.where(successorCall), isEmpty);
    expect(session.status, isNot(SessionStatus.authenticated));
    expect(session.asrLocalReadOwner, isNull);
    expect(CloudEgressGate.instance.holdActive, isFalse);
    expect(coord.asrExclusion, isNull);
    expect(requests.where((q) => q.url.path.startsWith('/rest/')), isEmpty);
    final hash = await r.accountScope.store.uidHash(_uid);
    expect((await r.accountScope.store.list()).map((e) => e.uidHash),
        contains(hash),
        reason: 'logout deletes nothing: the replica stays registered');
  });

  test('a pending Remove data denies ASR before any exchange', () async {
    final r = await coldLocalRead();
    storage.data['qirsh.removal_barrier.v1'] = '{"op":"pending"}';
    await resume();
    final asr = AutomaticSessionRecovery.active!;
    expect(asr.lastStop, 'elig', reason: diag());
    expect(script.sends, 0);
    expect(sim.calls.where(successorCall), isEmpty);
    expect(sim.of('mintExpiryEvidenceForLiveOn'), isEmpty);
    await expectStillLocalRead(r);
  });

  test('Phase 4c B8: after an unconfirmed transport closure the explicit '
      'sign-in handover fails promptly and the provider exchange never runs',
      () async {
    await coldLocalRead();
    script.quiesceError = const TransportCloseUnconfirmed();
    await resume();
    final coord = AuthCoordinator.active!;
    expect(coord.transportUnconfirmed, isTrue, reason: diag());
    expect(CloudEgressGate.instance.terminalDenied, isTrue);
    final client = Supabase.instance.client;
    final attempt = session.beginAuthAttempt();
    var invoked = 0;
    await expectLater(
        AuthAttemptZone.run(
            attempt.intent,
            () => CloudEgressGate.instance.runAccountControl(
                AccountControlOp.signIn,
                () => coord.explicitExchange(attempt.intent, () {
                      invoked++;
                      return client.auth.signInWithIdToken(
                          provider: OAuthProvider.apple,
                          idToken: 'apple-id-token',
                          nonce: 'raw-nonce');
                    }),
                attempt: true))
            .timeout(const Duration(seconds: 5)),
        throwsA(isA<ExplicitRefused>()));
    expect(invoked, 0);
    expect(signIns, isEmpty, reason: 'no authentication exchange started');
    expect(coord.explicitExclusion, isNull);
  });

  test('explicit re-authentication while the exchange is in flight: ASR '
      'yields, the explicit sign-in wins, no successor is published',
      () async {
    final r = await coldLocalRead();
    script.hold = Completer<void>();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await until(() => script.sends == 1, what: 'exchange sent');
    // The auth screen's sign-in (Reconnect from local read): the attempt is
    // captured first, then SupabaseAuthService's account-control exchange
    // (attempt zone → gate → the coordinator's explicit exchange).
    final client = Supabase.instance.client;
    final attempt = session.beginAuthAttempt();
    expect(attempt.intent, isNot(0));
    final coord0 = AuthCoordinator.active!;
    await AuthAttemptZone.run(
        attempt.intent,
        () => CloudEgressGate.instance.runAccountControl(
            AccountControlOp.signIn,
            () => coord0.explicitExchange(
                attempt.intent,
                () => client.auth.signInWithIdToken(
                    provider: OAuthProvider.apple,
                    idToken: 'apple-id-token',
                    nonce: 'raw-nonce')),
            attempt: true));
    script.hold?.complete(); // the ASR exchange's late response
    script.hold = null;
    await session.setIdentity(
      method: 'apple',
      email: '$_uid@example.com',
      userId: _uid,
      attempt: attempt,
      sessionCurrent: () =>
          client.auth.currentSession?.user.id == _uid &&
          !(client.auth.currentSession?.isExpired ?? true),
    );
    final asr = AutomaticSessionRecovery.active!;
    await asr.quiesced();
    expect(asr.lastStop, isNot('recovered'), reason: diag());
    expect(signIns, hasLength(1));
    final coord = AuthCoordinator.active!;
    expect(coord.store.committed!.sdkSession!.refreshToken, 'explicit-1',
        reason: 'the explicit session is the committed one');
    expect(client.auth.currentSession!.refreshToken, 'explicit-1');
    expect(sim.calls.where(successorCall), isEmpty,
        reason: 'no successor of the expiry evidence');
    expect(session.status, SessionStatus.authenticated, reason: diag());
    final scope = r.accountScope.current!;
    expect(scope.uid, _uid);
    expect(scope.isLocalRead, isFalse);
    expect(await rows(r), 1);
    expect(coord.asrExclusion, isNull);
    expect(CloudEgressGate.instance.holdActive, isFalse);
  });
}
