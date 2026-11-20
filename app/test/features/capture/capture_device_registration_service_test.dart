import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_consent_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

import '../../harness/egress_test_support.dart';
import '../../harness/paused_egress_support.dart';
import '../../harness/consent_session_support.dart';
import '../../core/session/f2_fixture.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _RotatingCaptureClient implements CaptureBackendClient {
  int registerDeviceCalls = 0;
  final pushSecrets = <String>[];

  @override
  Future<String> registerDevice({
    required String installId,
    String platform = 'ios',
  }) async {
    registerDeviceCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return 'fresh-device-secret';
  }

  @override
  Future<void> registerPushToken({
    required String installId,
    required String deviceSecret,
    required String apnsToken,
    required String apnsEnvironment,
  }) async {
    pushSecrets.add(deviceSecret);
    if (deviceSecret == 'stale-device-secret') {
      throw const CaptureBackendException('register_push_failed_401');
    }
  }

  @override
  Future<void> linkDevice({
    required String installId,
    required String deviceSecret,
    required String jwt,
  }) async {}

  @override
  Future<void> unlinkDevice({
    required String installId,
    required String deviceSecret,
  }) async {}

  @override
  Future<void> setDeviceConsent({
    required String installId,
    required String deviceSecret,
    required bool aiConsentGranted,
    required bool cloudProcessingEnabled,
  }) async {}

  @override
  Future<void> processIosSms({
    required String installId,
    required String deviceSecret,
    required String payloadId,
    required String smsText,
    required DateTime receivedAt,
    required bool allowAi,
    String? sender,
    String? locale,
    required String ownerUid,
    required int ownerGeneration,
    bool schemaV2 = false,
    int? textLength,
    bool? notificationDetails,
  }) async {}

  @override
  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    List<String> ackPayloadIds = const [],
  }) async =>
      const [];
}

class _RateLimitedCaptureClient extends _RotatingCaptureClient {
  int pushCalls = 0;

  @override
  Future<void> registerPushToken({
    required String installId,
    required String deviceSecret,
    required String apnsToken,
    required String apnsEnvironment,
  }) async {
    pushCalls++;
    throw const CaptureBackendException('register_push_failed_429');
  }
}

Map<String, Object?> _restrictiveReply(Map<Object?, Object?> args,
    {String? uid, int epochShift = 0, int versionShift = 0}) {
  final epoch = (args['expectedEpoch'] as int) + epochShift;
  final version = (args['version'] as int) + versionShift;
  return {
    'contractVersion': 1, 'operation': 'publishRestrictive', 'status': 'done',
    'owner': {'uid': uid ?? args['uid'], 'uidHash': List.filled(64, 'a').join(), 'generation': 7},
    'ownerGeneration': 7, 'ownerEpoch': epoch,
    'barrier': [for (final layer in ['file', 'keychain']) {'layer': layer, 'outcome': 'absent'}],
    'egress': [for (final layer in ['file', 'keychain']) {
      'layer': layer, 'outcome': 'verified', 'state': 'OFF',
      'transitionGeneration': 0, 'reservedVersion': version,
      'ownerGeneration': 7, 'ownerEpoch': epoch,
    }],
  };
}

Map<String, Object?> _revokedReply(Map<Object?, Object?> args) => {
  'contractVersion': 1, 'operation': 'revoke', 'status': 'done',
  for (final key in ['operationId', 'transitionGeneration', 'reservedVersion', 'ownerGeneration', 'ownerEpoch']) key: args[key],
  'barrier': [for (final layer in ['file', 'keychain']) {'layer': layer, 'outcome': 'absent'}],
  'egress': [for (final layer in ['file', 'keychain']) {
    'layer': layer, 'outcome': 'verified', 'state': 'OFF',
    for (final key in ['operationId', 'transitionGeneration', 'reservedVersion', 'ownerGeneration', 'ownerEpoch']) key: args[key],
  }],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DriftUserSettingsRepository settingsRepository;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      'qirsh_capture_device_secret': 'stale-device-secret',
    });
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    settingsRepository = DriftUserSettingsRepository(db);
    final settings = await settingsRepository.getSettings();
    // Astra H2.2: ON needs the explicit-enable record as well as the consent.
    await CloudEgressGate.instance.enable(owner: '', reservedVersion: 1);
    await settingsRepository.saveSettings(
      settings.copyWith(cloudConsentState: ConsentState.accepted),
    );
  });

  tearDown(() async => db.close());

  group('N2 restrictive owner publication', () {
    const channel = MethodChannel('money_companion/native_capture');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late F2Fixture f;
    late CloudEgressGate previousGate;
    late EgressRig rig;
    late List<MethodCall> calls;
    late CaptureBackendClient client;
    late Map<String, Object?> Function(Map<Object?, Object?>) reply;
    var backendCalls = 0;
    AdmissionAuthority? committed;

    setUp(() async {
      f = await F2Fixture.create();
      previousGate = CloudEgressGate.instance;
      rig = EgressRig();
      CloudEgressGate.instance = rig.gate;
      NativeCaptureBridge.debugTreatHostAsNative = true;
      calls = [];
      backendCalls = 0;
      committed = null;
      reply = (args) => _restrictiveReply(args);
      client = CaptureBackendClient(supabaseUrl: 'https://example.test', anonKey: 'test',
        httpClient: MockClient((_) async {
          backendCalls++;
          return http.Response('{}', 500);
        }));
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'captureOwnerEpoch') return 2;
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        if (call.method == 'publishCaptureOwner') {
          return {'uid': args['uid'], 'uidHash': List.filled(64, 'a').join(), 'generation': 7};
        }
        if (call.method == 'publishRestrictiveCaptureOwner') return reply(args);
        if (call.method == 'revokeCaptureAuthorizationLifetime') return _revokedReply(args);
        throw StateError('unexpected native operation ${call.method}');
      });
    });

    tearDown(() async {
      f.session.configureCaptureOwnerPublish(null);
      await f.dispose();
      NativeCaptureBridge.debugTreatHostAsNative = false;
      messenger.setMockMethodCallHandler(channel, null);
      CloudEgressGate.instance = previousGate;
    });

    // The real service for the exact DB of the committed callback, forwarding
    // its authority rather than capturing ordinary onboarding work.
    CaptureDeviceRegistrationService serviceFor(String uid) {
      final database = f.host.current!.database;
      return CaptureDeviceRegistrationService(
        settingsRepository: DriftUserSettingsRepository(database), client: client, gate: rig.gate,
        isIos: () => true, isBackendConfigured: () => true,
        readSession: () => (uid: uid, jwt: 'test-jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
        isCurrentScope: () => identical(f.host.current?.database, database),
      );
    }

    Future<RestrictiveCaptureOwnerReceipt?> hook(String uid, AdmissionAuthority authority) {
      committed = authority;
      return serviceFor(uid).publishRestrictiveOwner(admissionAuthority: authority);
    }

    List<MethodCall> published() => calls.where((c) => c.method == 'publishRestrictiveCaptureOwner').toList();

    test('committed onboarding OFF publishes a verified restrictive owner with zero backend calls', () async {
      f.session.configureCaptureOwnerPublish(hook);
      await freshSignIn(f, 'uid-x');
      expect(backendCalls, 0);
      expect(published(), hasLength(1));
      expect(calls.where((c) => c.method == 'publishCaptureOwner'), isEmpty);
      expect(f.session.captureLocalWorkAuthority(), isNull);
      expect(f.session.captureConsentCapability(), isNotNull);
      // The service returns the strictly confirmed receipt, not a Boolean.
      final receipt = await serviceFor('uid-x').publishRestrictiveOwner(admissionAuthority: committed!);
      expect(receipt, isNotNull);
      expect(receipt!.confirms(uid: 'uid-x', expectedEpoch: 2, version: receipt.phase.egress.first.reservedVersion!), isTrue);
      expect(backendCalls, 0);
    });

    for (final (name, tamper) in <(String, Map<String, Object?> Function(Map<Object?, Object?>))>[
      ('another epoch', (args) => _restrictiveReply(args, epochShift: 1)),
      ('another version', (args) => _restrictiveReply(args, versionShift: 1)),
      ('another uid', (args) => _restrictiveReply(args, uid: 'uid-other')),
    ]) {
      test('a reply for $name is not a receipt and nothing is fenced', () async {
        reply = tamper;
        f.session.configureCaptureOwnerPublish(hook);
        await freshSignIn(f, 'uid-x');
        expect(committed, isNotNull);
        expect(await serviceFor('uid-x').publishRestrictiveOwner(admissionAuthority: committed!), isNull);
        f.session.markSessionInvalid();
        await f.session.nativeLifecycleSettled();
        expect(calls.where((c) => c.method == 'revokeCaptureAuthorizationLifetime'), isEmpty);
        expect(backendCalls, 0);
      });
    }

    test('a service holding an old authority publishes nothing after sign-out', () async {
      f.session.configureCaptureOwnerPublish(hook);
      await freshSignIn(f, 'uid-x');
      final old = committed!;
      final service = serviceFor('uid-x');
      await f.session.signOut();
      calls.clear();
      expect(await service.publishRestrictiveOwner(admissionAuthority: old), isNull);
      expect(published(), isEmpty);
      expect(backendCalls, 0);
    });
  });

  test('401 rotates a stale device secret once across concurrent APNs syncs',
      () async {
    final client = _RotatingCaptureClient();
    var nativeConfigWrites = 0;
    final service = CaptureDeviceRegistrationService(
      settingsRepository: settingsRepository,
      client: client,
      storage: const FlutterSecureStorage(),
      isIos: () => true,
      isBackendConfigured: () => true,
      loadInstallId: () async => 'install-id',
      writeNativeBackendConfig: ({
        required cloudProcessingEnabled,
        required installId,
        deviceSecret,
        required backendUrl,
        required anonKey,
        required aiConsentGranted,
        String? ownerUid,
        int? transitionGeneration,
      }) async {
        expect(cloudProcessingEnabled, isTrue);
        expect(deviceSecret, 'fresh-device-secret');
        nativeConfigWrites++;
      },
    );
    const token = ApnsTokenInfo(
      token: 'apns-token',
      environment: 'sandbox',
    );

    await Future.wait([
      service.syncApnsToken(token),
      service.syncApnsToken(token),
    ]);

    expect(client.registerDeviceCalls, 1);
    expect(nativeConfigWrites, 1);
    expect(
      client.pushSecrets.where((secret) => secret == 'fresh-device-secret'),
      hasLength(1),
    );
    expect(await service.readDeviceSecret(), 'fresh-device-secret');
  });

  test('APNs 429 never blocks native capture state and is backed off',
      () async {
    final client = _RateLimitedCaptureClient();
    var enabledNativeWrites = 0;
    final service = CaptureDeviceRegistrationService(
      settingsRepository: settingsRepository,
      client: client,
      storage: const FlutterSecureStorage(),
      isIos: () => true,
      isBackendConfigured: () => true,
      loadInstallId: () async => 'install-id',
      loadApnsToken: () async => const ApnsTokenInfo(
        token: 'same-apns-token',
        environment: 'sandbox',
      ),
      writeNativeBackendConfig: ({
        required cloudProcessingEnabled,
        required installId,
        deviceSecret,
        required backendUrl,
        required anonKey,
        required aiConsentGranted,
        String? ownerUid,
        int? transitionGeneration,
      }) async {
        if (cloudProcessingEnabled) enabledNativeWrites++;
      },
    );

    await service.syncNativeState();
    await service.syncNativeState();

    expect(enabledNativeWrites, 2);
    expect(client.pushCalls, 1);
    expect(await service.readDeviceSecret(), 'stale-device-secret');
  });

  // ── MALI-060n Android consent-propagation tail ────────────────────────────

  CaptureDeviceRegistrationService androidService(_ConsentRecordingClient c) =>
      CaptureDeviceRegistrationService(
        settingsRepository: settingsRepository,
        client: c,
        storage: const FlutterSecureStorage(),
        isIos: () => false,
        isAndroid: () => true,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-id',
      );

  Future<void> setConsent({required bool ai, required bool cloud}) async {
    final s = await settingsRepository.getSettings();
    await settingsRepository.saveSettings(s.copyWith(
      aiConsentState: ai ? ConsentState.accepted : ConsentState.declined,
      cloudConsentState: cloud ? ConsentState.accepted : ConsentState.declined,
    ));
  }

  test('Android default OFF: no registration, no consent push', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: false, cloud: false);
    final client = _ConsentRecordingClient();
    await androidService(client).syncBackendState();
    expect(client.registeredPlatforms, isEmpty);
    expect(client.consentCalls, isEmpty);
    expect(await androidService(client).readDeviceSecret(), isNull);
  });

  test('Android enable: registers android device and pushes consent true',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: true, cloud: true);
    final client = _ConsentRecordingClient();
    final service = androidService(client);
    await service.syncBackendState();
    expect(client.registeredPlatforms, ['android']);
    expect(client.consentCalls.last, (ai: true, cloud: true));
    expect(await service.readDeviceSecret(), 'android-secret');
  });

  // A-12-min R6 (updated truthfully): this test used to pin a consent push on
  // every OFF sync of a relaunched app. Cloud OFF = ZERO EGRESS on Android too:
  // an existing secret does not make an OFF sync talk to the server.
  test('Android OFF (relaunched): zero egress even with an existing secret',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'qirsh_capture_device_secret': 'existing-secret',
    });
    await setConsent(ai: false, cloud: false);
    final client = _ConsentRecordingClient();
    await androidService(client).syncBackendState();
    expect(client.registeredPlatforms, isEmpty);
    expect(client.consentCalls, isEmpty);
  });

  // Astra G C.3 (updated truthfully): this test used to pin the legacy
  // device-secret revoke on Android ("stored secret + was ON"). That is NOT
  // ownership proof: with no frozen-owner JWT and uid-bound ack nothing is sent
  // and the status is NOT_ATTEMPTED. Local OFF still completes and never retries.
  test('Android: no JWT/ack -> no revoke (NOT_ATTEMPTED); OFF syncs never send',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: true, cloud: true);
    final client = _ConsentRecordingClient();
    final service = androidService(client);
    await service.syncBackendState();
    expect(client.consentCalls.last, (ai: true, cloud: true));
    client.consentCalls.clear();

    await service.disableCloud(
        commitLocalOff: () => setConsent(ai: false, cloud: false));
    expect(client.consentCalls, isEmpty,
        reason: 'a stored secret + was-ON is never a revoke authorisation');
    expect((await service.serverRevocation())!.status,
        ServerRevocation.notAttempted);
    await service.syncBackendState();
    await service.syncBackendState();
    expect(client.consentCalls, isEmpty);

    // A relaunch (new instance) sends nothing.
    await androidService(client).syncBackendState();
    expect(client.consentCalls, isEmpty);
    expect(client.registeredPlatforms, ['android'], reason: 'no re-register');
  });

  // A-12-min R6 (updated truthfully): this test used to pin a server revoke on a
  // RELAUNCHED app. The revoke is the one-shot closing act of the user's own
  // ON->OFF toggle in a running process (proven in cloud_off_zero_egress_test);
  // a relaunch with OFF settings and an old Cloud-ON ack sends nothing.
  test('iOS OFF after a relaunch: native config OFF, zero server calls',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'qirsh_capture_device_secret': 'existing-secret',
      // The server last acknowledged (cloud, ai) = (on, on) for this user.
      'qirsh_capture_consent_ack': 'uid-a|1|1|1',
    });
    // Cloud is the master gate. Keep the local AI preference accepted to prove
    // the iOS cloud-OFF branch does not preserve that stale grant server-side.
    await setConsent(ai: true, cloud: false);
    final client = _ConsentRecordingClient();
    final consent = _V2ConsentServer();
    final nativeWrites = <({bool ai, bool cloud})>[];
    final service = CaptureDeviceRegistrationService(
      settingsRepository: settingsRepository,
      client: client,
      consentClient: consent,
      readSession: () => (uid: 'uid-a', jwt: 'jwt-a'),
      readReplicaOwnerUid: () async => 'uid-a',
      writeConsentMirror: ({
        required uid,
        required cloud,
        required ai,
        required version,
      int? transitionGeneration,
      }) async {},
      storage: const FlutterSecureStorage(),
      isIos: () => true,
      isAndroid: () => false,
      isBackendConfigured: () => true,
      loadInstallId: () async => 'install-id',
      writeNativeBackendConfig: ({
        required cloudProcessingEnabled,
        required installId,
        deviceSecret,
        required backendUrl,
        required anonKey,
        required aiConsentGranted,
        String? ownerUid,
        int? transitionGeneration,
      }) async {
        nativeWrites.add((
          ai: aiConsentGranted,
          cloud: cloudProcessingEnabled,
        ));
      },
    );

    await service.syncBackendState();

    expect(nativeWrites, [(ai: false, cloud: false)]);
    expect(client.registeredPlatforms, isEmpty);
    // WP-6: iOS no longer uses the build-50 device-secret consent call; the v2
    // (JWT, versioned) call carries the revocation, AI forced off by cloud.
    expect(client.consentCalls, isEmpty);
    expect(consent.sets, isEmpty, reason: 'no revoke at startup/resume');
    expect(consent.links, isEmpty);
  });

  test('Android offline registration fails closed without throwing', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: true, cloud: true);
    final client = _ConsentRecordingClient()..registerThrows = true;
    await androidService(client).syncBackendState(); // must not throw
    expect(client.consentCalls, isEmpty);
    expect(await androidService(client).readDeviceSecret(), isNull);
  });

  test('Android consent-push failure is swallowed (retried next sync)',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'qirsh_capture_device_secret': 'existing-secret',
    });
    await setConsent(ai: true, cloud: true);
    final client = _ConsentRecordingClient()..consentThrows = true;
    await androidService(client).syncBackendState(); // must not throw
  });

  // ── WP1 registration status ───────────────────────────────────────────────

  const sentinel = 'SENTINEL-secret-message-do-not-leak';

  CaptureDeviceRegistrationService iosService(
    _ConsentRecordingClient c, {
    ApnsTokenLoader? loadApnsToken,
  }) =>
      CaptureDeviceRegistrationService(
        settingsRepository: settingsRepository,
        client: c,
        storage: const FlutterSecureStorage(),
        isIos: () => true,
        isAndroid: () => false,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-id',
        writeNativeBackendConfig: ({
          required cloudProcessingEnabled,
          required installId,
          deviceSecret,
          required backendUrl,
          required anonKey,
          required aiConsentGranted,
          String? ownerUid,
          int? transitionGeneration,
        }) async {},
        loadApnsToken: loadApnsToken ?? () async => null,
      );

  test('H2.2 an upgrade with persisted consent ON and NO durable record is NOT '
      'ON: nothing is adopted, only an explicit enable writes ON', () async {
    final egress = TestEgress(resolved: false).install(); // no record
    egress.owner = '';
    final s = await settingsRepository.getSettings();
    await settingsRepository.saveSettings(
        s.copyWith(cloudConsentState: ConsentState.accepted));
    expect((await settingsRepository.getSettings()).cloudProcessingEnabled,
        isTrue);

    final service = CaptureDeviceRegistrationService(
      settingsRepository: settingsRepository,
      client: _ConsentRecordingClient(),
      storage: const FlutterSecureStorage(),
      isIos: () => true,
      isAndroid: () => false,
      isBackendConfigured: () => true,
      loadInstallId: () async => 'install-id',
      // An explicit enable needs an admitted scope. This fixture declares its
      // own session (no AppSession admission concept), like its siblings.
      readSession: () => (uid: 'uid-h22', jwt: 'jwt'),
      writeNativeBackendConfig: ({
        required cloudProcessingEnabled,
        required installId,
        deviceSecret,
        required backendUrl,
        required anonKey,
        required aiConsentGranted,
        String? ownerUid,
        int? transitionGeneration,
      }) async {},
      loadApnsToken: () async => null,
    );
    expect(egress.gate.isResolved, isFalse);
    await service.resolvePendingDisable();

    expect(egress.gate.isResolved, isTrue);
    expect((await egress.gate.view(owner: '')).record, isNull,
        reason: 'no ON record was adopted');
    expect(egress.secure.writes + egress.file.writes, 0);
    expect(await egress.gate.permits(), isFalse);
    expect((await settingsRepository.getSettings()).cloudProcessingEnabled,
        isFalse,
        reason: 'effective consent = persisted AND durable ON: shown as off');

    await service.syncBackendState();
    expect((await egress.gate.view(owner: '')).record, isNull);

    await service.enableCloudForTest(commitLocalOn: () async {
      final cur = await settingsRepository.getSettings();
      await settingsRepository.saveSettings(
          cur.copyWith(cloudConsentState: ConsentState.accepted));
    });
    expect((await egress.gate.view(owner: '')).record!.state, EgressState.on);
    expect(await egress.gate.permits(), isTrue);
  });

  group('APNs registration carries the transition generation (H3 request)', () {
    const channel = MethodChannel('money_companion/native_capture');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;

    CaptureDeviceRegistrationService defaultLoaderService() =>
        CaptureDeviceRegistrationService(
          settingsRepository: settingsRepository,
          client: _ConsentRecordingClient(),
          storage: const FlutterSecureStorage(),
          isIos: () => true,
          isAndroid: () => false,
          isBackendConfigured: () => true,
          loadInstallId: () async => 'install-id',
          writeNativeBackendConfig: ({
            required cloudProcessingEnabled,
            required installId,
            deviceSecret,
            required backendUrl,
            required anonKey,
            required aiConsentGranted,
            String? ownerUid,
            int? transitionGeneration,
          }) async {},
          // No loadApnsToken: the real default, which calls the native bridge.
        );

    setUp(() {
      calls = [];
      NativeCaptureBridge.debugTreatHostAsNative = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
    });
    tearDown(() {
      NativeCaptureBridge.debugTreatHostAsNative = false;
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('the bridge sends the transitionGeneration key', () async {
      await NativeCaptureBridge.registerForRemoteNotifications(
          transitionGeneration: 7);
      final call = calls.singleWhere(
          (c) => c.method == 'registerForRemoteNotifications');
      expect(call.arguments, {'transitionGeneration': 7});
    });

    test('the service passes the CURRENT generation of the active owner, only '
        'while the gate permits', () async {
      final gen =
          (await CloudEgressGate.instance.view(owner: '')).record!.transitionGeneration;
      await defaultLoaderService().syncBackendState();
      final call = calls.where((c) => c.method == 'registerForRemoteNotifications');
      expect(call, isNotEmpty);
      expect(call.first.arguments, {'transitionGeneration': gen});

      // Cloud OFF (durable OFF record): the native registration is never asked.
      calls.clear();
      final freeze = await CloudEgressGate.instance
          .beginDisabling(owner: '', reservedVersion: 3);
      await CloudEgressGate.instance.commitOff(freeze);
      await defaultLoaderService().syncBackendState();
      expect(
          calls.where((c) => c.method == 'registerForRemoteNotifications'),
          isEmpty);
    });
  });

  const connected =
      CaptureRegistrationStatus(CaptureRegistrationPhase.connected);
  CaptureRegistrationStatus failed(String code) =>
      CaptureRegistrationStatus(CaptureRegistrationPhase.failed, code);

  test('status starts notRequested', () {
    expect(iosService(_ConsentRecordingClient()).status.value.phase,
        CaptureRegistrationPhase.notRequested);
  });

  test('iOS registerDevice throw: failed(register_failed), still propagates; '
      'retry never throws and reaches connected', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final client = _ConsentRecordingClient()..registerThrowsMessage = sentinel;
    final service = iosService(client);
    await expectLater(service.syncBackendState(), throwsA(anything));
    expect(service.status.value, failed('register_failed'));
    expect(service.status.value.failureCode, isNot(contains(sentinel)));

    await service.retry(); // still failing: must not throw
    expect(service.status.value, failed('register_failed'));

    client.registerThrowsMessage = null;
    await service.retry();
    expect(service.status.value, connected);
  });

  test('iOS consent off: notRequested and no registerDevice call', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: false, cloud: false);
    final client = _ConsentRecordingClient();
    final service = iosService(client);
    await service.syncBackendState();
    expect(service.status.value.phase, CaptureRegistrationPhase.notRequested);
    expect(client.registeredPlatforms, isEmpty);
  });

  test('iOS consent link failure while granting: consent_sync_failed',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: true, cloud: true);
    final consent = _V2ConsentServer()..linkThrows = true;
    final service = CaptureDeviceRegistrationService(
      settingsRepository: settingsRepository,
      client: _ConsentRecordingClient(),
      consentClient: consent,
      readSession: () => (uid: 'uid-a', jwt: 'jwt-a'),
      readReplicaOwnerUid: () async => 'uid-a',
      writeConsentMirror: ({
        required uid,
        required cloud,
        required ai,
        required version,
      int? transitionGeneration,
      }) async {},
      readOwnerEpoch: () async => 0,
      publishOwner: ({
        required uid,
        required cloud,
        required ai,
        required version,
        required expectedEpoch,
      int? transitionGeneration,
        }) async {},
      storage: const FlutterSecureStorage(),
      isIos: () => true,
      isAndroid: () => false,
      isBackendConfigured: () => true,
      loadInstallId: () async => 'install-id',
      writeNativeBackendConfig: ({
        required cloudProcessingEnabled,
        required installId,
        deviceSecret,
        required backendUrl,
        required anonKey,
        required aiConsentGranted,
        String? ownerUid,
        int? transitionGeneration,
      }) async {},
      loadApnsToken: () async => null,
    );
    await service.syncBackendState(); // swallow behaviour unchanged
    expect(service.status.value, failed('consent_sync_failed'));
  });

  test('iOS failed consent push during revocation stays notRequested',
      () async {
    FlutterSecureStorage.setMockInitialValues(
        {'qirsh_capture_device_secret': 'existing'});
    await setConsent(ai: false, cloud: false);
    final client = _ConsentRecordingClient()..consentThrows = true;
    final service = iosService(client);
    await service.syncBackendState();
    expect(service.status.value.phase, CaptureRegistrationPhase.notRequested);
  });

  test('iOS APNs failure is best-effort: still connected', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final service = iosService(
      _ConsentRecordingClient(),
      loadApnsToken: () async => throw StateError(sentinel),
    );
    await service.syncBackendState();
    expect(service.status.value, connected);
  });

  test('Android registerDevice throw: failed(register_failed), no throw',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: true, cloud: true);
    final client = _ConsentRecordingClient()..registerThrowsMessage = sentinel;
    final service = androidService(client);
    await service.syncBackendState();
    expect(service.status.value, failed('register_failed'));
    expect(service.status.value.failureCode, isNot(contains(sentinel)));

    client.registerThrowsMessage = null;
    await service.retry();
    expect(service.status.value, connected);
  });

  test('overlapping syncs: an older failing run cannot taint the newer run',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: true, cloud: true);
    final client = _GatedRegisterClient();
    final service = androidService(client);
    final older = service.syncBackendState();
    await client.firstRegisterStarted.future;
    final newer = service.syncBackendState();
    await newer;
    expect(service.status.value, connected);
    client.firstRegister.completeError(const CaptureBackendException('x'));
    await older;
    expect(service.status.value, connected);
  });

  test('Android consent off: notRequested', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: false, cloud: false);
    final service = androidService(_ConsentRecordingClient());
    await service.syncBackendState();
    expect(service.status.value.phase, CaptureRegistrationPhase.notRequested);
  });

  test('Android setDeviceConsent failure: consent_sync_failed', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await setConsent(ai: true, cloud: true);
    final service =
        androidService(_ConsentRecordingClient()..consentThrows = true);
    await service.syncBackendState();
    expect(service.status.value, failed('consent_sync_failed'));
  });
}

class _ConsentRecordingClient extends _RotatingCaptureClient {
  final registeredPlatforms = <String>[];
  final consentCalls = <({bool ai, bool cloud})>[];
  bool registerThrows = false;
  String? registerThrowsMessage;
  bool consentThrows = false;

  @override
  Future<String> registerDevice({
    required String installId,
    String platform = 'ios',
  }) async {
    if (registerThrows) throw const CaptureBackendException('offline');
    final message = registerThrowsMessage;
    if (message != null) throw CaptureBackendException(message);
    registeredPlatforms.add(platform);
    return 'android-secret';
  }

  @override
  Future<void> setDeviceConsent({
    required String installId,
    required String deviceSecret,
    required bool aiConsentGranted,
    required bool cloudProcessingEnabled,
  }) async {
    if (consentThrows) throw const CaptureBackendException('offline');
    consentCalls.add((ai: aiConsentGranted, cloud: cloudProcessingEnabled));
  }
}

class _V2ConsentServer extends CaptureConsentClient {
  _V2ConsentServer()
      : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  final sets = <({bool cloud, bool ai, int version})>[];
  final links = <({bool cloud, bool ai, int version})>[];
  bool linkThrows = false;

  @override
  Future<void> link({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
  required int clientGeneration,
  }) async {
    links.add((cloud: cloud, ai: ai, version: version));
    if (linkThrows) throw const CaptureBackendException('offline');
  }

  @override
  Future<void> setConsent({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
  required int clientGeneration,
  }) async {
    sets.add((cloud: cloud, ai: ai, version: version));
  }
}

class _GatedRegisterClient extends _ConsentRecordingClient {
  final firstRegisterStarted = Completer<void>();
  final firstRegister = Completer<String>();
  var _calls = 0;

  @override
  Future<String> registerDevice({
    required String installId,
    String platform = 'ios',
  }) {
    if (_calls++ == 0) {
      firstRegisterStarted.complete();
      return firstRegister.future;
    }
    return super.registerDevice(installId: installId, platform: platform);
  }
}
