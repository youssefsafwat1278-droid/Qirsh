// ignore_for_file: depend_on_referenced_packages

// Adversarial scenarios 1 and 27. The production-path harness below is a
// verbatim copy of test/core/startup/asr_production_path_test.dart (its tests
// removed), because that harness lives inside its main(); only the tests at
// the end of main() are new.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/auth/auth_coordinator.dart';
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

import '../harness/asr_native_sim.dart';
import '../core/auth/session_fixtures.dart';
import '../core/auth/store_fakes.dart';
import '../core/session/f2_fixture.dart';
import '../core/session/recording_secure_storage.dart';

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
    final first =
        BootstrapRunner(debugAuthClient: await F2Fixture.liveClient(_uid))
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
      expect(
          File(p.join(support.path, CloudEgressStore.kFileName)).existsSync(),
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
          final body =
              sessionJson(uid: _uid, exp: exp, refreshToken: 'explicit-1')
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
            channelFactory: () =>
                refreshChannelFactory?.call() ?? _Channel(script));
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

  Future<String> replicaId(BootstrapRunner r) async =>
      (await r.accountScope.current!.database
              .customSelect('SELECT replica_id FROM replica_meta;')
              .getSingle())
          .read<String>('replica_id');

  Future<int> rows(BootstrapRunner r) async =>
      (await r.accountScope.current!.database
              .customSelect('SELECT COUNT(*) AS c FROM transactions;')
              .getSingle())
          .read<int>('c');

  /// Polls (real time) until [done] holds.
  Future<void> until(bool Function() done,
      {Duration timeout = const Duration(seconds: 45), String? what}) async {
    final end = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('timed out: $what ${diag()}');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Overwrites both Dart layers of [_uid] with [secure] / [file] states.
  void writeDartLayers(EgressState secure, EgressState file) {
    String body(EgressState st) => jsonEncode({
          'v': 1,
          'records': {
            _uid: CloudEgressRecord(
                    state: st,
                    ownerUid: _uid,
                    transitionGeneration: 3,
                    reservedVersion: 1)
                .toJson()
          }
        });
    storage.data[CloudEgressStore.kSecureKey] = body(secure);
    File(p.join(support.path, CloudEgressStore.kFileName))
        .writeAsStringSync(body(file));
  }

  // ── failures ─────────────────────────────────────────────────────────────

  Future<BootstrapRunner> coldLocalRead() async {
    await accountWithCloudOnThenKill();
    await commitExpiredRecord();
    final r = await bootProcess();
    expect(session.asrLocalReadOwner, _uid, reason: diag());
    return r;
  }

  // ── Adversarial (scenarios 1 and 27) ─────────────────────────────────────

  /// The auth screen's explicit Apple sign-in through the production path
  /// (attempt zone → gate account control → coordinator exchange → admission).
  Future<void> explicitSignIn() async {
    final client = Supabase.instance.client;
    final attempt = session.beginAuthAttempt();
    final coord = AuthCoordinator.active!;
    await AuthAttemptZone.run(
        attempt.intent,
        () => CloudEgressGate.instance.runAccountControl(
            AccountControlOp.signIn,
            () => coord.explicitExchange(
                attempt.intent,
                () => client.auth.signInWithIdToken(
                    provider: OAuthProvider.apple,
                    idToken: 'apple-id-token',
                    nonce: 'raw-nonce')),
            attempt: true));
    await session.setIdentity(
      method: 'apple',
      email: '$_uid@example.com',
      userId: _uid,
      attempt: attempt,
      sessionCurrent: () =>
          client.auth.currentSession?.user.id == _uid &&
          !(client.auth.currentSession?.isExpired ?? true),
    );
  }

  test(
      'ADV-1: a leftover Dart DISABLING, then an explicit sign-in: the '
      'sign-in succeeds and the DISABLING is completed to OFF afterwards',
      () async {
    final r = await (() async {
      await accountWithCloudOffThenKill();
      writeDartLayers(EgressState.disabling, EgressState.disabling);
      sim.seedLiveOn(transitionGeneration: 1, reservedVersion: 1);
      await commitExpiredRecord();
      final r = await bootProcess();
      await resume();
      expect(AutomaticSessionRecovery.diagnostic.value, 'elig:frozen');
      expect(session.asrLocalReadOwner, _uid);
      return r;
    })();

    await explicitSignIn();
    await AutomaticSessionRecovery.active?.quiesced();
    await session.nativeLifecycleSettled();
    await until(() => !ConsentAuthority.egressFrozen,
        timeout: const Duration(seconds: 5),
        what: 'post-admission reconciliation');

    expect(signIns, hasLength(1), reason: 'the sign-in exchange was admitted');
    expect(session.status, SessionStatus.authenticated, reason: diag());
    expect(r.accountScope.current!.isLocalRead, isFalse);
    expect(await rows(r), 1);
    final layers =
        await CloudEgressGate.instance.store.readDartOwnerLayers(_uid);
    expect(layers.records.map((x) => x.state), everyElement(EgressState.off),
        reason: 'the leftover DISABLING is completed after the sign-in');
    final settings =
        await DriftUserSettingsRepository(r.accountScope.current!.database)
            .getSettings();
    expect(settings.cloudProcessingEnabled, isFalse);
  });

  test(
    'ADV-27a: Cloud ON — the app is backgrounded while the recovery is '
    'adopting the refreshed session: the user is NOT signed out',
    () async {
      final r = await coldLocalRead();
      final replica = await replicaId(r);
      sim.onCall = (m) {
        if (m == 'beginCloudEgressEnable') {
          binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        }
      };
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await AutomaticSessionRecovery.active!.quiesced();
      sim.onCall = null;
      // Expected: either recovered, or still in local read so that the next
      // resume recovers. Never the sign-in screen.
      final stillUsable = session.status == SessionStatus.authenticated ||
          session.asrLocalReadOwner == _uid;
      expect(stillUsable, isTrue,
          reason:
              'backgrounding during refresh signed the user out: ${diag()}');
      await resume();
      expect(session.status, SessionStatus.authenticated, reason: diag());
      expect(await replicaId(r), replica);
      expect(await rows(r), 1);
    },
    // Known limitation, kept by design (decision (c), §11.4): iOS may
    // suspend a backgrounded process mid-write, so an adoption never
    // continues once the app is paused. Fail-closed outcome: Cloud ON →
    // sign-in screen; Cloud OFF → local read stays, Reconnect needed.
    skip: 'design: adoption never continues in the background (decision c)',
  );

  test(
    'ADV-27b: Cloud OFF — the app is backgrounded while the recovery is '
    'adopting the refreshed session: the user is NOT signed out',
    () async {
      await accountWithCloudOffThenKill();
      await commitExpiredRecord();
      final r = await bootProcess();
      expect(session.asrLocalReadOwner, _uid, reason: diag());
      var paused = false;
      keychain.onWrite = (v) {
        final rec = SessionRecord.decode(v);
        if (!paused && rec.adoption?.state == AdoptionState.pending) {
          paused = true;
          binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        }
      };
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await AutomaticSessionRecovery.active!.quiesced();
      keychain.onWrite = null;
      expect(paused, isTrue, reason: 'the adoption was reached: ${diag()}');
      final stillUsable = session.status == SessionStatus.authenticated ||
          session.asrLocalReadOwner == _uid;
      expect(stillUsable, isTrue,
          reason:
              'backgrounding during refresh signed the user out: ${diag()}');
      await resume();
      expect(session.status, SessionStatus.authenticated, reason: diag());
      expect(await rows(r), 1);
    },
    // Known limitation, kept by design (decision (c), §11.4): iOS may
    // suspend a backgrounded process mid-write, so an adoption never
    // continues once the app is paused. Fail-closed outcome: Cloud ON →
    // sign-in screen; Cloud OFF → local read stays, Reconnect needed.
    skip: 'design: adoption never continues in the background (decision c)',
  );
}
