import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/ownership_guard.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_smart_inbox_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_consent_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_import_ports.dart';
import 'package:money_companion/features/capture/services/capture_server_port.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

import '../../harness/egress_test_support.dart';

// A-12-min — CLOUD OFF = ZERO EGRESS. A network spy: every transport the
// capture path owns is a fake that records the call, and the tests assert the
// call list is EMPTY across admission, capture, sign-out, sign-in, resume, a
// 401 and Remove data. The only exceptions are the single, one-shot revoke
// INSIDE the user's own ON->OFF transition (CaptureDeviceRegistrationService.
// disableCloud, kRevokeAtCloudSwitchOff): the freeze comes first, the revoke is
// the last control-plane action of the ON state, OFF is committed whatever it
// does; and (approved 2026-11-12) the retry of THAT revoke when it did not land:
// the revoke only, its own owner, bounded backoff, never while ON, never after
// a newer grant the server acknowledged (see the last group).

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

typedef _Consent = ({bool cloud, bool ai, int version});

/// Every egress call lands in the ONE shared [calls] log.
class _SpyBackend extends CaptureBackendClient {
  _SpyBackend(this.calls)
      : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  final List<String> calls;
  Object? error;
  final deviceConsents = <({bool cloud, bool ai})>[];
  Future<void> Function()? onSetDevice;

  @override
  Future<String> registerDevice(
      {required String installId, String platform = 'ios'}) async {
    calls.add('registerDevice');
    if (error != null) throw error!;
    return 'device-secret';
  }

  @override
  Future<void> unlinkDevice(
      {required String installId, required String deviceSecret}) async {
    calls.add('unlinkDevice');
  }

  @override
  Future<void> setDeviceConsent({
    required String installId,
    required String deviceSecret,
    required bool aiConsentGranted,
    required bool cloudProcessingEnabled,
  }) async {
    calls.add('setDeviceConsent');
    deviceConsents.add((cloud: cloudProcessingEnabled, ai: aiConsentGranted));
    await onSetDevice?.call();
  }

  @override
  Future<void> registerPushToken({
    required String installId,
    required String deviceSecret,
    required String apnsToken,
    required String apnsEnvironment,
  }) async {
    calls.add('registerPushToken');
  }

  @override
  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    List<String> ackPayloadIds = const [],
  }) async {
    calls.add('syncCaptures');
    return const [];
  }

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
  }) async {
    calls.add('processIosSms');
  }
}

class _SpyConsent extends CaptureConsentClient {
  _SpyConsent(this.calls)
      : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  final List<String> calls;
  final links = <_Consent>[];
  final sets = <_Consent>[];
  Object? linkError;
  Object? setError;
  Future<void> Function()? onLink;
  Future<void> Function()? onSet;

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
    calls.add('link');
    await onLink?.call();
    if (linkError != null) throw linkError!;
    links.add((cloud: cloud, ai: ai, version: version));
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
    calls.add('set');
    await onSet?.call();
    if (setError != null) throw setError!;
    sets.add((cloud: cloud, ai: ai, version: version));
  }

  /// Astra G C.3: the one-shot `revoke_capture_consent` (JWT).
  final revokes = <_Consent>[];
  final revokeOwners = <String>[];
  final revokeGenerations = <int>[];
  RevokeResult revokeResult = const RevokeResult(ok: true, applied: true);

  @override
  Future<RevokeResult> revoke({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required String ownerUid,
    required int transitionGeneration,
    required int version,
  }) async {
    calls.add('revoke');
    revokeOwners.add(ownerUid);
    revokeGenerations.add(transitionGeneration);
    await onSet?.call();
    if (setError != null) throw setError!;
    revokes.add((cloud: false, ai: false, version: version));
    return revokeResult;
  }
}

typedef _Published = ({
  String uid,
  bool cloud,
  bool ai,
  int version,
  int epoch,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DriftUserSettingsRepository repo;
  late List<String> calls;
  late _SpyBackend backend;
  late _SpyConsent consent;
  late List<_Published> published;
  late int epoch;
  late int apnsLoads;
  late List<bool> nativeConfigs;
  late List<({String uid, bool cloud, bool ai, int version})> mirrors;
  Object? nativeConfigError;
  CaptureSession? session;
  String? replicaOwner;
  late Directory markerDir;
  late TestEgress egress;

  /// Every native consent withdrawal the service asked for, with what was true
  /// at that moment: Dart egress frozen? how many requests had left already?
  late List<({String uid, bool frozen, int callsBefore})> withdrawals;
  NativeEgressWithdrawal? withdrawReport;
  Object? withdrawError;

  CaptureDeviceRegistrationService service({
    bool backendConfigured = true,
    bool revoke = kRevokeAtCloudSwitchOff,
    Duration timeout = kCloudOffRevokeTimeout,
    FlutterSecureStorage? storage,
    Future<Directory> Function()? markerDirectory,
    List<Duration> backoff = kRevokeRetryBackoff,
    DateTime Function()? now,
    bool android = false,
  }) =>
      CaptureDeviceRegistrationService(
        withdrawNativeEgress: (uid) async {
          withdrawals.add((
            uid: uid,
            frozen: ConsentAuthority.egressFrozen,
            callsBefore: calls.length,
          ));
          if (withdrawError != null) throw withdrawError!;
          return withdrawReport;
        },
        revokeAtSwitchOff: revoke,
        revokeTimeout: timeout,
        revokeRetryBackoff: backoff,
        now: now,
        markerDirectory: markerDirectory ?? () async => markerDir,
        settingsRepository: repo,
        client: backend,
        consentClient: consent,
        storage: storage ?? const FlutterSecureStorage(),
        isIos: () => !android,
        isAndroid: () => android,
        isBackendConfigured: () => backendConfigured,
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
          nativeConfigs.add(cloudProcessingEnabled);
          if (nativeConfigError != null) throw nativeConfigError!;
        },
        loadApnsToken: () async {
          apnsLoads++;
          return null;
        },
        readSession: () => session,
        readReplicaOwnerUid: () async => replicaOwner,
        writeConsentMirror: ({
          required uid,
          required cloud,
          required ai,
          required version,
        int? transitionGeneration,
        }) async {
          mirrors.add((uid: uid, cloud: cloud, ai: ai, version: version));
        },
        readOwnerEpoch: () async => epoch,
        publishOwner: ({
          required uid,
          required cloud,
          required ai,
          required version,
          required expectedEpoch,
        int? transitionGeneration,
          }) async {
          published.add((
            uid: uid,
            cloud: cloud,
            ai: ai,
            version: version,
            epoch: expectedEpoch,
          ));
        },
      );

  Future<void> save(
      {ConsentState? cloud, ConsentState? ai, bool enable = true}) async {
    final s = await repo.getSettings();
    // Astra H2.2: Cloud becomes ON only through an explicit enable, which also
    // writes the durable ON record. A test that grants consent models that.
    if (enable &&
        (cloud == ConsentState.accepted || ai == ConsentState.accepted)) {
      final cur = (await egress.gate.view(owner: replicaOwner ?? '')).record;
      if (cur == null || cur.state != EgressState.on) {
        await egress.gate
            .enable(owner: replicaOwner ?? '', reservedVersion: s.consentVersion + 1);
      }
    }
    await repo
        .saveSettings(s.copyWith(cloudConsentState: cloud, aiConsentState: ai));
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    repo = DriftUserSettingsRepository(db);
    calls = [];
    backend = _SpyBackend(calls);
    consent = _SpyConsent(calls);
    published = [];
    epoch = 0;
    apnsLoads = 0;
    nativeConfigs = [];
    mirrors = [];
    nativeConfigError = null;
    ConsentAuthority.egressFrozen = false;
    session = (uid: 'uid-a', jwt: 'jwt-a');
    replicaOwner = 'uid-a';
    markerDir = Directory.systemTemp.createTempSync('cloud_off_marker');
    withdrawals = [];
    withdrawError = null;
    withdrawReport = const NativeEgressWithdrawal(
        mirror: 'restricted',
        config: 'restricted',
        egress: 'restricted',
        inflightBefore: 0,
        cancelled: 0);
    egress = TestEgress()..owner = 'uid-a';
    egress.install();
  });
  tearDown(() async {
    ConsentAuthority.egressFrozen = false;
    if (markerDir.existsSync()) markerDir.deleteSync(recursive: true);
    await db.close();
  });

  group('Cloud OFF sends nothing', () {
    test('admission publishes the owner LOCALLY with a Cloud-OFF mirror',
        () async {
      await save(cloud: ConsentState.declined);

      await service().linkToCurrentUser();

      expect(calls, isEmpty);
      expect(published, hasLength(1));
      expect(published.single.uid, 'uid-a');
      expect(published.single.cloud, isFalse);
      expect(published.single.ai, isFalse);
    });

    test('an unset consent (a brand-new user) is OFF too', () async {
      await service().linkToCurrentUser();
      expect(calls, isEmpty);
      expect(published.single.cloud, isFalse);
    });

    test('local publication needs neither a configured backend nor a secret',
        () async {
      await service(backendConfigured: false).linkToCurrentUser();
      expect(calls, isEmpty);
      expect(published, hasLength(1));
    });

    test('capture / resume / startup syncs repeat with zero calls', () async {
      final s = service();
      for (var i = 0; i < 4; i++) {
        await s.syncBackendState();
      }
      await s.syncNativeState();
      await s.retry();
      expect(calls, isEmpty);
      expect(apnsLoads, 0, reason: 'no APNs registration while OFF');
    });

    test('an existing secret does not make OFF talk to the server', () async {
      FlutterSecureStorage.setMockInitialValues(
          {'qirsh_capture_device_secret': 'old-secret'});
      final s = service();
      await s.syncBackendState();
      await s.linkToCurrentUser();
      expect(calls, isEmpty);
    });

    test('sign-in of another user: still zero calls, owner published locally',
        () async {
      final s = service();
      await s.linkToCurrentUser();
      session = (uid: 'uid-b', jwt: 'jwt-b');
      replicaOwner = 'uid-b';
      await s.linkToCurrentUser();
      expect(calls, isEmpty);
      expect(published.map((p) => p.uid), ['uid-a', 'uid-b']);
    });

    test('sign-out and Remove data (the unlink hook) send nothing', () async {
      FlutterSecureStorage.setMockInitialValues(
          {'qirsh_capture_device_secret': 'old-secret'});
      final s = service();
      await s.syncBackendState();
      await s.unlinkCurrentDevice();
      expect(calls, isEmpty);
    });

    test('a 401-shaped backend is never even called, so nothing recovers',
        () async {
      backend.error = const CaptureBackendException('register_failed_401');
      consent.linkError = const CaptureBackendException('link_device_failed_401');
      consent.setError = const CaptureBackendException('set_consent_failed_401');
      final s = service();
      await s.linkToCurrentUser();
      await s.syncBackendState();
      await s.unlinkCurrentDevice();
      expect(calls, isEmpty);
    });

    test(
        'a 401 recovery never re-registers when Cloud is switched OFF while '
        'the link is in flight', () async {
      FlutterSecureStorage.setMockInitialValues(
          {'qirsh_capture_device_secret': 'stale-secret'});
      await save(cloud: ConsentState.accepted);
      consent.onLink = () async {
        await save(cloud: ConsentState.declined); // the user flips OFF mid-link
        throw const CaptureBackendException('link_device_failed_401');
      };
      await service().linkToCurrentUser();
      expect(calls, ['link'], reason: 'no registerDevice after the OFF toggle');
    });

    test('Cloud OFF with no admitted replica / session publishes nothing',
        () async {
      session = null;
      await service().linkToCurrentUser();
      session = (uid: 'uid-b', jwt: 'j');
      await service().linkToCurrentUser(); // replica belongs to uid-a
      expect(published, isEmpty);
      expect(calls, isEmpty);
    });

    test('the legacy server port treats OFF as "not configured": zero calls',
        () async {
      final port = BackendCaptureServerPort(
        settingsRepository: repo,
        registrationService: service(),
        captureSyncService: _unusedSync(),
        client: backend,
        backendConfigured: true,
        loadInstallId: () async => 'install-id',
      );
      expect((await port.fetchResults()).status,
          CaptureFetchStatus.notConfigured);
      await port.acknowledge(const ['x']);
      expect(calls, isEmpty);
    });
  });

  group('publication is a compare-and-swap on the owner epoch', () {
    test('the epoch read BEFORE the publish is the one passed to native',
        () async {
      epoch = 7;
      await service().linkToCurrentUser();
      expect(published.single.epoch, 7);
    });

    test('a failed native publish (cleared since) leaves no owner, no throw',
        () async {
      final s = CaptureDeviceRegistrationService(
        settingsRepository: repo,
        client: backend,
        consentClient: consent,
        storage: const FlutterSecureStorage(),
        isIos: () => true,
        isAndroid: () => false,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-id',
        readSession: () => session,
        readReplicaOwnerUid: () async => replicaOwner,
        readOwnerEpoch: () async => 1,
        publishOwner: ({
          required uid,
          required cloud,
          required ai,
          required version,
          required expectedEpoch,
        int? transitionGeneration,
          }) async =>
            throw const CaptureQueueException('owner_changed'),
      );
      await s.linkToCurrentUser(); // _linkOnce swallows: fail closed
      expect(calls, isEmpty);
    });
  });

  // E1 — the user-ratified Cloud ON->OFF transition (disableCloud).
  group('E1: the ON->OFF transition (disableCloud)', () {
    var commits = 0;
    Future<void> commit() async {
      commits++;
      await save(cloud: ConsentState.declined);
    }

    Future<void> pump() async {
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    Future<CaptureDeviceRegistrationService> linkedOn(
        {bool revoke = kRevokeAtCloudSwitchOff,
        Duration timeout = kCloudOffRevokeTimeout}) async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      final s = service(revoke: revoke, timeout: timeout);
      await s.syncBackendState();
      expect(consent.links, hasLength(1));
      calls.clear();
      commits = 0;
      return s;
    }

    CaptureSyncService syncSvc(
            CaptureDeviceRegistrationService reg, List<String> authCalls) =>
        CaptureSyncService(
          settingsRepository: repo,
          transactionRepository: DriftTransactionRepository(db),
          dedupStore: DriftDedupStore(db),
          smartInboxRepository: DriftSmartInboxRepository(db),
          suspectedDuplicateRepository:
              DriftSuspectedDuplicateRepository(db),
          registrationService: reg,
          ownershipGuard: _Guard(),
          currentUserId: () => 'uid-a',
          client: backend,
          backendConfigured: true,
          loadInstallId: () async => 'install-id',
          authorizeUpload: (id) async {
            authCalls.add(id);
            return const CaptureUploadAuthorization(
                CaptureUploadDecision.allowed,
                ownerUid: 'uid-a',
                allowAi: true);
          },
        );

    const pending = SharedCapturedMessage(
        id: 'p1',
        text: 'x',
        source: CapturedMessageSource.iosShare,
        status: 'pendingSend');

    /// Every egress path the app has, run once; callers assert [calls].
    Future<void> everyPath(CaptureDeviceRegistrationService s,
        List<String> authCalls) async {
      final sync = syncSvc(s, authCalls);
      await s.syncBackendState();
      await s.syncNativeState();
      await s.retry();
      await s.linkToCurrentUser();
      await s.isLinkedForCloud();
      await s.syncApnsToken(
          const ApnsTokenInfo(token: 'tok', environment: 'sandbox'));
      await service().syncBackendState(); // the other (startup) instance
      await sync.sync();
      await sync.retryPendingSend(pending);
    }

    test('POINT 1: during a hanging revoke every other egress path is silent '
        'and native is already restrictive; OFF commits after it settles',
        () async {
      final s = await linkedOn();
      final gate = Completer<void>();
      consent.onSet = () => gate.future;
      final authCalls = <String>[];
      final nativeStart = nativeConfigs.length;

      final done = s.disableCloud(commitLocalOff: commit);
      await _waitFor(() => calls.contains('revoke'));
      expect(calls, ['revoke'], reason: 'the revoke is in flight');
      expect(ConsentAuthority.egressFrozen, isTrue);
      expect((await repo.getSettings()).cloudProcessingEnabled, isTrue,
          reason: 'OFF is committed only after the revoke settles');
      // Native: restricted BEFORE the revoke left, mirror restrictive.
      expect(nativeConfigs.skip(nativeStart), [false]);
      expect(mirrors.last.cloud, isFalse);
      expect(mirrors.last.ai, isFalse);
      final nativeBefore = nativeConfigs.length;
      final mirrorsBefore = mirrors.length;

      await everyPath(s, authCalls);

      expect(calls, ['revoke'], reason: 'zero new requests while frozen');
      expect(authCalls, isEmpty, reason: 'native authorize is never asked');
      expect(nativeConfigs.length, nativeBefore);
      expect(mirrors.length, mirrorsBefore, reason: 'no widening, no republish');
      expect(await s.isLinkedForCloud(), isFalse);
      final authority = ConsentAuthority(repo.getSettings);
      // Astra G (updated truthfully): catalog and auth are no longer exempt.
      for (final c in EgressClass.values) {
        expect(await authority.allows(c), isFalse, reason: '$c');
      }
      expect(commits, 0);

      gate.complete();
      await done;
      expect(commits, 1);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect(consent.revokes.single.cloud, isFalse);
      expect(consent.revokes.single.ai, isFalse);
      expect(consent.revokes.single.version,
          (await repo.getSettings()).consentVersion,
          reason: 'the revoke carries the next consent version');
    });

    test('POINT 1: a link that was already in flight cannot widen the mirror '
        'after the freeze', () async {
      await save(cloud: ConsentState.accepted);
      final linkGate = Completer<void>();
      consent.onLink = () => linkGate.future;
      final s = service();
      final link = s.linkToCurrentUser();
      await _waitFor(() => calls.contains('link'));
      // Hold the transition open (the local commit hangs) while the link ends.
      final commitGate = Completer<void>();
      final disable = s.disableCloud(commitLocalOff: () async {
        await commitGate.future;
        await commit();
      });
      await pump();
      linkGate.complete();
      await link;
      commitGate.complete();
      await disable;
      expect(published, isEmpty, reason: 'a frozen publish is refused');
      expect(mirrors.every((m) => !m.cloud), isTrue);
    });

    test('POINT 2: concurrent double toggle, repeated sync, relaunch: one '
        'revoke', () async {
      final s = await linkedOn();
      final other = service();
      final a = s.disableCloud(commitLocalOff: commit);
      final b = s.disableCloud(commitLocalOff: commit);
      final c = other.disableCloud(commitLocalOff: commit);
      await Future.wait([a, b, c]);
      expect(calls, ['revoke']);
      expect(commits, 1, reason: 'one transition, one commit');

      for (var i = 0; i < 3; i++) {
        await s.syncBackendState();
      }
      await service().syncBackendState(); // relaunch
      await service().resolvePendingDisable();
      expect(calls, ['revoke']);

      // A later, separate toggle of an already-OFF state sends nothing either.
      await s.disableCloud(commitLocalOff: commit);
      expect(calls, ['revoke']);
    });

    for (final failure in <String, Object>{
      'exception': const CaptureBackendException('offline'),
      '401': const CaptureBackendException('revoke_failed_401'),
    }.entries) {
      test('POINT 3: a revoke failing with ${failure.key} still commits '
          'OFF and never throws', () async {
        final s = await linkedOn();
        consent.setError = failure.value;
        await s.disableCloud(commitLocalOff: commit);
        expect(commits, 1);
        expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
        expect(ConsentAuthority.egressFrozen, isFalse);
        expect(calls, ['revoke'], reason: 'no 401 recovery, no link, no register');
      });
    }

    test('POINT 3: a timed-out revoke still commits OFF', () async {
      final s = await linkedOn(timeout: const Duration(milliseconds: 50));
      consent.onSet = () => Completer<void>().future; // never answers
      await s.disableCloud(commitLocalOff: commit);
      expect(commits, 1);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(calls, ['revoke']);
    });

    test('POINT 3: a native-restriction failure does not block OFF either',
        () async {
      final s = await linkedOn();
      nativeConfigError = StateError('native down');
      await s.disableCloud(commitLocalOff: commit);
      expect(commits, 1);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
    });

    test('POINT 4: after a failure no ordinary path re-sends the revoke, and '
        'the approved retry waits for its backoff', () async {
      final s = await linkedOn();
      consent.setError = const CaptureBackendException('offline');
      await s.disableCloud(commitLocalOff: commit);
      consent.setError = null;
      for (var i = 0; i < 3; i++) {
        await s.syncBackendState(); // sync / resume
      }
      await s.unlinkCurrentDevice();
      await s.linkToCurrentUser();
      final relaunched = service();
      await relaunched.resolvePendingDisable();
      await relaunched.syncBackendState();
      await Future<void>.delayed(const Duration(milliseconds: 200)); // timers
      expect(calls, ['revoke'],
          reason: 'one attempt until the retry backoff elapses');
    });

    test('POINT 4: a durable consumed revoke_attempt for this (owner, '
        'generation) blocks a second send', () async {
      final s = await linkedOn();
      final gen =
          (await CloudEgressGate.instance.view()).record!.transitionGeneration +
              1;
      await const FlutterSecureStorage().write(
          key: 'qirsh.capture_revoke_attempt.v1',
          value:
              '{"owner":"uid-a","transition_generation":$gen,"consumed":true}');
      await s.disableCloud(commitLocalOff: commit);
      expect(calls, isEmpty);
      expect(commits, 1);
    });

    test('POINT 5: once OFF is committed the spy sees zero egress until an '
        'explicit enable', () async {
      final s = await linkedOn();
      await s.disableCloud(commitLocalOff: commit);
      calls.clear();
      apnsLoads = 0;
      final nativeAfterOff = nativeConfigs.length;
      final authCalls = <String>[];

      await everyPath(s, authCalls); // sync, resume, capture, replay
      // sign-out, sign-in of another user, relaunch
      await s.unlinkCurrentDevice();
      session = null;
      await s.syncBackendState();
      session = (uid: 'uid-b', jwt: 'jwt-b');
      replicaOwner = 'uid-b';
      await s.linkToCurrentUser();
      final relaunched = service();
      await relaunched.resolvePendingDisable();
      await relaunched.syncBackendState();
      await relaunched.linkToCurrentUser();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(calls, isEmpty);
      expect(authCalls, isEmpty);
      expect(apnsLoads, 0);
      expect(nativeConfigs.skip(nativeAfterOff).every((c) => !c), isTrue);
      expect(await s.isLinkedForCloud(), isFalse);

      // The persistent OFF gate: a bare save of ON (no explicit enable) is NOT
      // honoured; it is reverted to OFF and nothing is sent.
      session = (uid: 'uid-a', jwt: 'jwt-a');
      replicaOwner = 'uid-a';
      await save(cloud: ConsentState.accepted, enable: false);
      await relaunched.syncBackendState();
      expect(calls, isEmpty);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);

      // Explicit enable: a NEW generation, then egress resumes (link).
      final offGen =
          (await CloudEgressGate.instance.view()).record!.transitionGeneration;
      await relaunched.enableCloudForTest(
          commitLocalOn: () => save(cloud: ConsentState.accepted));
      expect((await CloudEgressGate.instance.view()).record!.transitionGeneration,
          greaterThan(offGen));
      await relaunched.syncBackendState();
      expect(calls, contains('link'));
    });

    Future<void> plantDisabling(String owner) async {
      final g = CloudEgressGate.instance;
      final cur = (await g.view(owner: owner)).record;
      await g.writeRecord(CloudEgressRecord(
        state: EgressState.disabling,
        ownerUid: owner,
        transitionGeneration: (cur?.transitionGeneration ?? 0) + 1,
        reservedVersion: 9,
      ));
    }

    test('a crash with a DISABLING record: relaunch commits OFF, sends no '
        'revoke, and leaves a durable OFF', () async {
      await linkedOn(); // ON, acked; then the process "dies" mid-transition
      await plantDisabling('uid-a');

      final relaunched = service();
      await relaunched.resolvePendingDisable();

      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(calls, isEmpty);
      expect((await CloudEgressGate.instance.view()).record!.state,
          EgressState.off,
          reason: 'clearing DISABLING only after durable OFF is written');
      expect(await const FlutterSecureStorage().read(key: 'qirsh_capture_consent_ack'),
          isNull);
      expect(await relaunched.isLinkedForCloud(), isFalse);
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect((await relaunched.serverRevocation())!.status,
          ServerRevocation.notAttempted);
      await relaunched.syncBackendState();
      await relaunched.syncBackendState();
      expect(calls, isEmpty, reason: 'never retried');
    });

    test('a crash marker is completed by the first sync as well, before any '
        'egress', () async {
      await linkedOn();
      await plantDisabling('uid-a');
      await service().syncBackendState();
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(calls, isEmpty);
    });

    test('a marker left by ANOTHER replica owner is neither applied here nor '
        'discarded (C.5)', () async {
      await linkedOn();
      await plantDisabling('uid-other');
      await service().resolvePendingDisable();
      expect((await repo.getSettings()).cloudProcessingEnabled, isTrue);
      expect(
          (await CloudEgressGate.instance.view(owner: 'uid-other'))
              .record!
              .state,
          EgressState.disabling);
      // uid-a's own state is evaluated independently and is untouched.
      expect((await CloudEgressGate.instance.view()).record!.state,
          EgressState.on);
    });

    test('kRevokeAtCloudSwitchOff = false: freeze + commit, zero requests',
        () async {
      final s = await linkedOn(revoke: false);
      final done = s.disableCloud(commitLocalOff: commit);
      await done;
      expect(calls, isEmpty);
      expect(commits, 1);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(nativeConfigs.last, isFalse);
      expect(mirrors.last.cloud, isFalse);
      expect(ConsentAuthority.egressFrozen, isFalse);
    });

    test('the OFF branch of syncBackendState never sends a revoke, even right '
        'after the save', () async {
      final s = await linkedOn();
      await save(cloud: ConsentState.declined); // a bare save, no transition
      await s.syncBackendState();
      await s.syncBackendState();
      expect(calls, isEmpty);
    });

    test('withdrawal revokes a possibly applied grant whose receipt was lost',
        () async {
      await save(cloud: ConsentState.accepted);
      consent.linkError = const CaptureBackendException('offline');
      final s = service();
      await s.syncBackendState();
      calls.clear();
      commits = 0;
      await s.disableCloud(commitLocalOff: commit);
      expect(calls, ['revoke']);
      expect(commits, 1);
    });

    test('sign-out while ON still unlinks once; the ack is cleared first',
        () async {
      final s = await linkedOn();
      await s.unlinkCurrentDevice();
      expect(calls, ['unlinkDevice']);
      calls.clear();
      await s.unlinkCurrentDevice();
      expect(calls, isEmpty);
    });

    test('ON->ON changes (AI only) are not a transition; OFF->ON is not',
        () async {
      final s = service();
      final base = await repo.getSettings();
      final on = base.copyWith(
          cloudConsentState: ConsentState.accepted,
          aiConsentState: ConsentState.accepted);
      final aiOff = on.copyWith(aiConsentState: ConsentState.declined);
      final off = on.copyWith(
          cloudConsentState: ConsentState.declined,
          aiConsentState: ConsentState.declined);
      expect(s.isDisablingCloud(on, aiOff), isFalse);
      expect(s.isDisablingCloud(off, on), isFalse);
      expect(s.isDisablingCloud(on, off), isTrue);
    });

    test('the revoke is one named constant, bounded by a short timeout', () {
      expect(kRevokeAtCloudSwitchOff, isTrue);
      expect(kCloudOffRevokeTimeout, lessThanOrEqualTo(const Duration(seconds: 5)));
    });
  });

  group('E1 Android: the same transition, no platform carve-out', () {
    CaptureDeviceRegistrationService android({
      bool revoke = kRevokeAtCloudSwitchOff,
      Duration timeout = kCloudOffRevokeTimeout,
    }) =>
        CaptureDeviceRegistrationService(
          revokeAtSwitchOff: revoke,
          revokeTimeout: timeout,
          settingsRepository: repo,
          client: backend,
          consentClient: consent,
          storage: const FlutterSecureStorage(),
          isIos: () => false,
          isAndroid: () => true,
          isBackendConfigured: () => true,
          loadInstallId: () async => 'install-id',
          readSession: () => session,
          readReplicaOwnerUid: () async => replicaOwner,
        );

    var commits = 0;
    Future<void> commit() async {
      commits++;
      await save(cloud: ConsentState.declined, ai: ConsentState.declined);
    }

    Future<CaptureDeviceRegistrationService> androidOn(
        {bool revoke = kRevokeAtCloudSwitchOff,
        Duration timeout = kCloudOffRevokeTimeout}) async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      final s = android(revoke: revoke, timeout: timeout);
      await s.syncBackendState();
      // Astra G C.3/P7: the Android ON path links its row to the owner with the
      // JWT link, exactly like iOS (it used to push the device-secret consent).
      expect(calls, ['registerDevice', 'link']);
      calls.clear();
      commits = 0;
      return s;
    }

    test('OFF: zero calls across startup, resume, retry and sign-out',
        () async {
      FlutterSecureStorage.setMockInitialValues(
          {'qirsh_capture_device_secret': 'old-secret'});
      final s = android();
      for (var i = 0; i < 3; i++) {
        await s.syncBackendState();
      }
      await s.retry();
      await s.unlinkCurrentDevice(); // iOS-only link; nothing on Android
      expect(calls, isEmpty);
    });

    test('OFF with no secret: no registerDevice either', () async {
      await android().syncBackendState();
      expect(calls, isEmpty);
    });

    test('POINTS 1+2: freeze during a hanging revoke, exactly one revoke, '
        'then OFF and silence (also after relaunch)', () async {
      final s = await androidOn();
      final gate = Completer<void>();
      consent.onSet = () => gate.future;

      final done = s.disableCloud(commitLocalOff: commit);
      await _waitFor(() => calls.contains('revoke'));
      expect(calls, ['revoke']);
      for (var i = 0; i < 3; i++) {
        await s.syncBackendState();
      }
      await android().syncBackendState();
      expect(calls, ['revoke'], reason: 'frozen: nothing else');
      expect((await repo.getSettings()).cloudProcessingEnabled, isTrue);

      gate.complete();
      await done;
      expect(commits, 1);
      expect(consent.revokes.last.cloud, isFalse);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);

      await s.syncBackendState();
      await android().syncBackendState(); // relaunch
      expect(calls, ['revoke'], reason: 'POINT 5: silence');
    });

    test('POINTS 3+4: a failing or timed-out revoke still commits OFF and is '
        'not re-sent before the approved retry backoff', () async {
      final s = await androidOn(timeout: const Duration(milliseconds: 50));
      consent.onSet = () => Completer<void>().future;
      await s.disableCloud(commitLocalOff: commit);
      expect(commits, 1);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect((await s.serverRevocation())!.status, ServerRevocation.unconfirmed);
      consent.onSet = null;
      await s.syncBackendState();
      await android().syncBackendState();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, ['revoke']);
    });

    test('a relaunch before the toggle still sends the one revoke (authorised '
        'by the uid-bound ack + the frozen-owner JWT, NOT by the stored '
        'secret)', () async {
      await androidOn();
      final relaunched = android();
      await relaunched.disableCloud(commitLocalOff: commit);
      expect(calls, ['revoke']);
      expect(commits, 1);
    });

    test('POINT 5 / no secret: nothing to revoke, OFF still commits',
        () async {
      commits = 0;
      await save(cloud: ConsentState.accepted);
      await android().disableCloud(commitLocalOff: commit);
      expect(calls, isEmpty);
      expect(commits, 1);
    });

    test('revoke seam false: freeze and commit with zero requests', () async {
      final s = await androidOn(revoke: false);
      await s.disableCloud(commitLocalOff: commit);
      expect(calls, isEmpty);
      expect(commits, 1);
    });

    test('a crash with a DISABLING record commits OFF on relaunch, no revoke',
        () async {
      await androidOn();
      await CloudEgressGate.instance.writeRecord(const CloudEgressRecord(
        state: EgressState.disabling,
        ownerUid: 'uid-a',
        transitionGeneration: 9,
        reservedVersion: 9,
      ));
      await android().syncBackendState();
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect((await repo.getSettings()).aiConsentGranted, isFalse);
      expect(calls, isEmpty);
    });

    test('an AI-only OFF on Android is a transition; ON->ON is not', () async {
      final s = android();
      final base = await repo.getSettings();
      final both = base.copyWith(
          cloudConsentState: ConsentState.accepted,
          aiConsentState: ConsentState.accepted);
      expect(
          s.isDisablingCloud(
              both, both.copyWith(aiConsentState: ConsentState.declined)),
          isFalse);
      expect(
          s.isDisablingCloud(
              both.copyWith(cloudConsentState: ConsentState.declined),
              both.copyWith(
                  cloudConsentState: ConsentState.declined,
                  aiConsentState: ConsentState.declined)),
          isTrue);
    });
  });

  group('E1 fail-closed: the local OFF write fails', () {
    var failCommit = true;
    Future<void> commit() async {
      if (failCommit) throw StateError('local OFF write failed');
      await save(cloud: ConsentState.declined);
    }

    Future<CaptureDeviceRegistrationService> linkedOn() async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      final s = service();
      await s.syncBackendState();
      expect(consent.links, hasLength(1));
      calls.clear();
      failCommit = true;
      return s;
    }

    Future<EgressState?> stateOf() async =>
        (await CloudEgressGate.instance.view(owner: 'uid-a')).record?.state;

    test('freeze stays, Cloud is NOT restored, DISABLING persists in both '
        'stores, and nothing more is sent', () async {
      final s = await linkedOn();
      await expectLater(
          s.disableCloud(commitLocalOff: commit), throwsStateError);
      expect(consent.revokes, hasLength(1), reason: 'the one revoke, nothing more');
      calls.clear();
      expect(ConsentAuthority.egressFrozen, isTrue);
      expect((await repo.getSettings()).cloudProcessingEnabled, isTrue);
      expect(await stateOf(), EgressState.disabling);
      expect(egress.secure.value, contains('DISABLING'));
      expect(egress.file.value, contains('DISABLING'));
      for (final reg in [s, service()]) {
        await reg.syncBackendState();
        expect(await reg.isLinkedForCloud(), isFalse);
      }
      for (final c in EgressClass.values) {
        expect(
            ConsentAuthority.decide(c, await repo.getSettings()), isFalse,
            reason: '$c must stay denied while frozen');
      }
      expect(calls, isEmpty);
    });

    test('next launch completes OFF from DISABLING, sends no revoke, and '
        'writes durable OFF', () async {
      final s = await linkedOn();
      await expectLater(
          s.disableCloud(commitLocalOff: commit), throwsStateError);
      calls.clear();
      ConsentAuthority.egressFrozen = false; // a new process
      final relaunched = service();
      await relaunched.resolvePendingDisable();
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect(await stateOf(), EgressState.off);
      await relaunched.syncBackendState();
      expect(calls, isEmpty, reason: 'no revoke, no egress after OFF');
    });

    test('mixed-store crash: DISABLING only in the FILE (secure write failed) '
        'still lets the next launch complete OFF', () async {
      final s = await linkedOn();
      egress.secure.failWrites = true;
      await expectLater(
          s.disableCloud(commitLocalOff: commit), throwsStateError);
      expect(egress.file.value, contains('DISABLING'));
      expect(egress.secure.value, isNot(contains('DISABLING')));
      egress.secure.failWrites = false;
      calls.clear();
      ConsentAuthority.egressFrozen = false; // a new process
      await service().resolvePendingDisable();
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(await stateOf(), EgressState.off);
      expect(calls, isEmpty);
    });

    test('mixed-store crash: DISABLING only in SECURE storage (file write '
        'failed) overrides the absent file', () async {
      final s = await linkedOn();
      egress.file.failWrites = true;
      await expectLater(
          s.disableCloud(commitLocalOff: commit), throwsStateError);
      expect(egress.secure.value, contains('DISABLING'));
      egress.file.failWrites = false;
      ConsentAuthority.egressFrozen = false;
      await service().resolvePendingDisable();
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(await stateOf(), EgressState.off);
    });

    test('a relaunch whose OFF write fails again stays frozen with zero '
        'egress', () async {
      final s = await linkedOn();
      await expectLater(
          s.disableCloud(commitLocalOff: commit), throwsStateError);
      calls.clear();
      ConsentAuthority.egressFrozen = false; // a new process
      final failingRepo = _FailingSaveRepo(db);
      final relaunched = CaptureDeviceRegistrationService(
        settingsRepository: failingRepo,
        client: backend,
        consentClient: consent,
        storage: const FlutterSecureStorage(),
        markerDirectory: () async => markerDir,
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
        readSession: () => session,
        readReplicaOwnerUid: () async => replicaOwner,
      );
      await relaunched.resolvePendingDisable();
      expect(ConsentAuthority.egressFrozen, isTrue);
      await relaunched.syncBackendState();
      expect(await relaunched.isLinkedForCloud(), isFalse);
      expect(calls, isEmpty);
      expect(await stateOf(), EgressState.disabling,
          reason: 'kept for the next try; never reopened');
    });

    test('state unreadable in BOTH stores: fail closed, no egress', () async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      egress.secure.failReads = true;
      egress.file.failReads = true;
      final s = service();
      await s.syncBackendState();
      expect(calls, isEmpty);
      expect(await s.isLinkedForCloud(), isFalse);
    });

    test('UI: a failed local OFF write is swallowed by the privacy screen path '
        '(fail closed, no crash)', () async {
      // Source pin: privacy_screen catches the disableCloud failure and returns
      // without any further sync.
      final src =
          File('lib/features/settings/privacy_screen.dart').readAsStringSync();
      final i = src.indexOf('await registration.disableCloud(');
      expect(i, greaterThan(0));
      final tail = src.substring(i, i + 400);
      expect(tail, contains('} catch (_) {'));
      expect(tail, contains('return;'));
    });
  });

  group('R5: the legacy device-credential calls need a uid-bound ack', () {
    test('B\'s failed link never falls through to the legacy contract',
        () async {
      // A is linked (ack A, Cloud ON); the projection still belongs to A.
      await save(cloud: ConsentState.accepted);
      final s = service();
      await s.syncBackendState();
      expect(await s.isLinkedForCloud(), isTrue);

      // A -> B: B's link fails.
      session = (uid: 'uid-b', jwt: 'jwt-b');
      replicaOwner = 'uid-b';
      consent.linkError = const CaptureBackendException('offline');
      calls.clear();
      final port = BackendCaptureServerPort(
        settingsRepository: repo,
        registrationService: s,
        captureSyncService: _unusedSync(),
        client: backend,
        backendConfigured: true,
        loadInstallId: () async => 'install-id',
      );

      expect(await s.isLinkedForCloud(), isFalse);
      expect((await port.fetchResults()).status,
          CaptureFetchStatus.notConfigured);
      await port.acknowledge(const ['x']);
      expect(calls.where((c) => c == 'syncCaptures'), isEmpty,
          reason: 'no legacy sync-captures while the projection is still A\'s');
    });

    test('A -> B -> A: nothing legacy before A re-links', () async {
      await save(cloud: ConsentState.accepted);
      final s = service();
      await s.syncBackendState(); // A linked
      session = (uid: 'uid-b', jwt: 'jwt-b');
      replicaOwner = 'uid-b';
      // B explicitly enabled Cloud (Astra H2.2: no adoption of an absent record).
      await egress.gate.enable(owner: 'uid-b', reservedVersion: 5);
      await s.syncBackendState(); // B links: the single ack slot is now B's
      session = (uid: 'uid-a', jwt: 'jwt-a');
      replicaOwner = 'uid-a';
      calls.clear();

      expect(await s.isLinkedForCloud(), isFalse,
          reason: 'the projection is B\'s; A has no ack until it re-links');
      final port = BackendCaptureServerPort(
        settingsRepository: repo,
        registrationService: _NoRelink(s),
        captureSyncService: _unusedSync(),
        client: backend,
        backendConfigured: true,
        loadInstallId: () async => 'install-id',
      );
      await port.fetchResults();
      expect(calls.where((c) => c == 'syncCaptures'), isEmpty);

      await s.linkToCurrentUser(); // A re-links
      expect(await s.isLinkedForCloud(), isTrue);
    });
  });

  // Approved 2026-11-12 (product owner): a revoke whose one-shot send did not
  // land is persisted and retried with bounded backoff, ONLY the revoke
  // (identifiers only), only for its own signed-in owner, only while Cloud stays
  // OFF at its generation, never after a newer grant. Nothing else is sent and
  // local consent never reopens.
  group('the retry of a revoke that did not land (approved 2026-11-12)', () {
    late DateTime clock;
    const backoff = [Duration(seconds: 30), Duration(minutes: 1)];
    var commits = 0;
    Future<void> commitOff() async {
      commits++;
      await save(cloud: ConsentState.declined, ai: ConsentState.declined);
    }

    Future<void> commitOn() async {
      await save(
          cloud: ConsentState.accepted, ai: ConsentState.accepted, enable: false);
    }

    final made = <CaptureDeviceRegistrationService>[];
    CaptureDeviceRegistrationService svc({bool android = false}) {
      final s = service(backoff: backoff, now: () => clock, android: android);
      made.add(s);
      return s;
    }

    setUp(() {
      clock = DateTime.utc(2026, 11, 12, 20);
      commits = 0;
      made.clear();
    });
    tearDown(() {
      for (final s in made) {
        s.dispose();
      }
    });

    Future<CaptureDeviceRegistrationService> offWithMissedRevoke(
        {bool android = false}) async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      final s = svc(android: android);
      await s.syncBackendState();
      expect(consent.links, hasLength(1));
      consent.setError = const CaptureBackendException('offline');
      await s.disableCloud(commitLocalOff: commitOff);
      consent.setError = null;
      expect(commits, 1);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      calls.clear();
      consent.revokeOwners.clear();
      consent.revokeGenerations.clear();
      return s;
    }

    void elapse(Duration d) => clock = clock.add(d);

    test('stays pending; not resent before its backoff; then once, only the '
        'revoke, and silence after the server confirmed', () async {
      final s = await offWithMissedRevoke();
      final gen = await s.pendingRevocationGeneration('uid-a');
      expect(gen, isNotNull);
      await s.syncBackendState();
      expect(calls, isEmpty, reason: 'backoff not elapsed');

      elapse(const Duration(seconds: 31));
      await s.syncBackendState();
      expect(calls, ['revoke']);
      expect(consent.revokeOwners, ['uid-a']);
      expect(consent.revokeGenerations, [gen]);
      expect(await s.pendingRevocationGeneration('uid-a'), isNull);
      expect((await s.serverRevocation())!.status, ServerRevocation.confirmed);

      elapse(const Duration(hours: 3));
      for (var i = 0; i < 3; i++) {
        await s.syncBackendState();
      }
      await svc().syncBackendState(); // a relaunched instance
      expect(calls, ['revoke'], reason: 'confirmed: never again');
      final settings = await repo.getSettings();
      expect(settings.cloudProcessingEnabled, isFalse);
      expect(settings.aiConsentGranted, isFalse,
          reason: 'the retry never reopens local consent');
    });

    test('a failing retry backs off (bounded: the last step repeats) and '
        'keeps the record', () async {
      final s = await offWithMissedRevoke();
      consent.setError = const CaptureBackendException('offline');
      elapse(const Duration(seconds: 31));
      await s.syncBackendState();
      expect(calls, ['revoke']);
      await s.syncBackendState();
      elapse(const Duration(seconds: 59));
      await s.syncBackendState();
      expect(calls, ['revoke'], reason: 'next step is 1 min');
      elapse(const Duration(seconds: 2));
      await s.syncBackendState();
      expect(calls, ['revoke', 'revoke']);
      elapse(const Duration(seconds: 61));
      await s.syncBackendState();
      expect(calls, ['revoke', 'revoke', 'revoke'], reason: 'capped at 1 min');
      expect(await s.pendingRevocationGeneration('uid-a'), isNotNull);
    });

    test('only for the same signed-in owner: never while signed out or for '
        'another account', () async {
      final s = await offWithMissedRevoke();
      elapse(const Duration(seconds: 31));

      session = null;
      await s.syncBackendState();
      expect(calls, isEmpty, reason: 'signed out');

      session = (uid: 'uid-b', jwt: 'jwt-b');
      replicaOwner = 'uid-b';
      egress.owner = 'uid-b';
      await svc().syncBackendState();
      expect(calls, isEmpty, reason: "B never sends A's revoke");

      session = (uid: 'uid-a', jwt: 'jwt-a');
      replicaOwner = 'uid-a';
      egress.owner = 'uid-a';
      await s.syncBackendState();
      expect(calls, ['revoke']);
      expect(consent.revokeOwners, ['uid-a']);
    });

    test('an explicit re-enable (Off -> On) is never revoked: the record is '
        'dormant while ON and ends once the server acknowledged the grant',
        () async {
      final s = await offWithMissedRevoke();
      await s.enableCloudForTest(commitLocalOn: commitOn);
      elapse(const Duration(hours: 2));
      await s.syncBackendState(); // retry first (dormant), then the ON link
      expect(calls, isNot(contains('revoke')));
      expect(calls, contains('link'), reason: 'the ON state reaches the server');
      await s.syncBackendState(); // the acknowledged grant supersedes it
      expect(calls, isNot(contains('revoke')));
      expect(await s.pendingRevocationGeneration('uid-a'), isNull);
      expect((await repo.getSettings()).cloudProcessingEnabled, isTrue);
    });

    test('a newer ON in the gate record alone: nothing is sent while ON',
        () async {
      final s = await offWithMissedRevoke();
      await egress.gate.enable(owner: 'uid-a', reservedVersion: 99);
      elapse(const Duration(seconds: 31));
      await s.syncBackendState();
      expect(consent.revokeOwners, isEmpty);
    });

    test('Off -> On (acknowledged) -> Off: only the newest revoke is retried',
        () async {
      final s = await offWithMissedRevoke();
      final g1 = (await s.pendingRevocationGeneration('uid-a'))!;
      await s.enableCloudForTest(commitLocalOn: commitOn);
      await s.syncBackendState(); // the ON reaches the server (ack)
      consent.setError = const CaptureBackendException('offline');
      await s.disableCloud(commitLocalOff: commitOff);
      consent.setError = null;
      final g2 = (await s.pendingRevocationGeneration('uid-a'))!;
      expect(g2, greaterThan(g1));
      calls.clear();
      consent.revokeGenerations.clear();
      elapse(const Duration(seconds: 31));
      await s.syncBackendState();
      expect(calls, ['revoke']);
      expect(consent.revokeGenerations, [g2]);
      expect(await s.pendingRevocationGeneration('uid-a'), isNull);
    });

    test('Off -> On (never reached the server) -> Off: the server still holds '
        'the FIRST grant, so the revoke is kept, moved to the new generation '
        'and sent once', () async {
      final s = await offWithMissedRevoke();
      final g1 = (await s.pendingRevocationGeneration('uid-a'))!;
      await s.enableCloudForTest(commitLocalOn: commitOn); // offline: no sync
      await s.disableCloud(commitLocalOff: commitOff);
      expect(calls, isNot(contains('revoke')),
          reason: 'no acknowledgment: the one-shot sends nothing');
      final g2 = (await s.pendingRevocationGeneration('uid-a'))!;
      expect(g2, greaterThan(g1));
      elapse(const Duration(seconds: 31));
      await s.syncBackendState();
      expect(calls, ['revoke']);
      expect(consent.revokeGenerations, [g2]);
      expect(await s.pendingRevocationGeneration('uid-a'), isNull);
    });

    for (final answer in <String, Object>{
      'stale_generation': const RevokeResult(
          ok: true, applied: false, reason: 'stale_generation'),
      'owner_mismatch': const RevokeResult(
          ok: true, applied: false, reason: 'owner_mismatch'),
      '409': const CaptureBackendException('revoke_failed_409'),
    }.entries) {
      test('a server answer that can never apply (${answer.key}) ends it',
          () async {
        final s = await offWithMissedRevoke();
        if (answer.value is RevokeResult) {
          consent.revokeResult = answer.value as RevokeResult;
        } else {
          consent.setError = answer.value;
        }
        elapse(const Duration(seconds: 31));
        await s.syncBackendState();
        expect(calls, ['revoke']);
        expect(await s.pendingRevocationGeneration('uid-a'), isNull);
        elapse(const Duration(hours: 2));
        await s.syncBackendState();
        expect(calls, ['revoke']);
      });
    }

    test('a 401 (e.g. an expired session) keeps it for a later attempt',
        () async {
      final s = await offWithMissedRevoke();
      consent.setError = const CaptureBackendException('revoke_failed_401');
      elapse(const Duration(seconds: 31));
      await s.syncBackendState();
      expect(calls, ['revoke']);
      expect(await s.pendingRevocationGeneration('uid-a'), isNotNull);
    });

    test('the record is durable BEFORE the one-shot send (a crash mid-send '
        "leaves it) and is removed only by the server's answer", () async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      final s = svc();
      await s.syncBackendState();
      final hang = Completer<void>();
      consent.onSet = () => hang.future;
      final done = s.disableCloud(commitLocalOff: commitOff);
      await _waitFor(() => calls.contains('revoke'));
      expect(await svc().pendingRevocationGeneration('uid-a'), isNotNull,
          reason: 'what a crash right now would leave behind');
      hang.complete();
      await done;
      consent.onSet = null;
      expect(await s.pendingRevocationGeneration('uid-a'), isNull);
    });

    test('Android: the same retry, the same limits', () async {
      final s = await offWithMissedRevoke(android: true);
      await s.syncBackendState();
      expect(calls, isEmpty);
      elapse(const Duration(seconds: 31));
      await s.syncBackendState();
      expect(calls, ['revoke']);
      expect(await s.pendingRevocationGeneration('uid-a'), isNull);
    });
  });


  // iOS privacy fix (field bug, build 143). After the user confirmed Cloud /
  // Smart Analysis OFF, the DISABLING allocation was refused because ANOTHER
  // account's native record on the device could not be verified
  // (`unverified[owners=11;native_other:native_egress_evidence_unverified]`),
  // and the native restriction ran only after that allocation, so the App
  // Intent kept uploading. Now: the native withdrawal runs FIRST and
  // independently, and a restrictive write is judged on its own owner only.
  group('iOS privacy fix: the native withdrawal comes first', () {
    const old = 'uid-old';
    late Map<String, CloudEgressRecord> nativeRecords;
    var nativeWriteFails = false;

    /// The device of the field report: uid-a ON in every layer, and an account
    /// that signed in long ago whose native evidence cannot be verified.
    Future<void> fieldDevice({bool settingsOn = true}) async {
      nativeWriteFails = false;
      nativeRecords = {
        'uid-a': const CloudEgressRecord(
            state: EgressState.on,
            ownerUid: 'uid-a',
            transitionGeneration: 3,
            reservedVersion: 3),
      };
      egress = TestEgress(
        native: NativeEgressSlot(
          read: (o) async {
            if (o == old) {
              throw const FormatException(
                  'native_egress_uncertain:lifetime_fields_unbound');
            }
            return nativeRecords[o];
          },
          readLayers: (o) async {
            if (o == old) {
              throw const FormatException('native_egress_evidence_unverified');
            }
            final r = nativeRecords[o];
            return [if (r != null) r, if (r != null) r];
          },
          write: (r) async {
            if (nativeWriteFails) throw StateError('native write failed');
            nativeRecords[r.ownerUid] = r;
          },
        ),
      )..owner = 'uid-a';
      egress.install();
      final body = jsonEncode({
        'v': 1,
        'records': {
          'uid-a': nativeRecords['uid-a']!.toJson(),
          old: const CloudEgressRecord(
                  state: EgressState.on,
                  ownerUid: old,
                  transitionGeneration: 8,
                  reservedVersion: 8)
              .toJson(),
        }
      });
      egress.secure.value = body;
      egress.file.value = body;
      await save(
          cloud: settingsOn ? ConsentState.accepted : ConsentState.declined,
          ai: settingsOn ? ConsentState.accepted : ConsentState.declined,
          enable: false);
    }

    Future<void> commitOff() =>
        save(cloud: ConsentState.declined, ai: ConsentState.declined);

    Future<CloudEgressRecord?> recordOf(String owner) async =>
        (await egress.gate.view(owner: owner)).record;

    test('field reproduction: another account\'s unverifiable record no longer '
        'blocks this owner\'s OFF, and is left untouched', () async {
      await fieldDevice();
      final oldBefore = egress.secure.value!.contains('"$old"');

      await service().disableCloud(commitLocalOff: commitOff);

      expect(withdrawals.map((w) => w.uid), ['uid-a']);
      expect((await recordOf('uid-a'))!.state, EgressState.off);
      expect(nativeRecords['uid-a']!.state, EgressState.off);
      expect(ConsentAuthority.egressFrozen, isFalse, reason: 'OFF is durable');
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(oldBefore, isTrue);
      final oldAfter = (await egress.gate.store.read(owner: old)).records[old];
      expect(oldAfter!.state, EgressState.on, reason: 'never applied, never rewritten');
      expect(oldAfter.transitionGeneration, 8);
      expect(calls, isEmpty);
    });

    test('a WIDENING write still verifies every account (fail closed)',
        () async {
      await fieldDevice();
      final widened = await egress.gate.store.writeAllocated(
          'uid-a',
          (g) => CloudEgressRecord(
              state: EgressState.on,
              ownerUid: 'uid-a',
              transitionGeneration: g,
              reservedVersion: 9));
      expect(widened, isNull);
      expect(CloudEgressStore.lastWriteRefusal,
          'unverified[owners=2;native_other:native_egress_evidence_unverified]',
          reason: 'privacy-safe: a count and allowlisted reasons, no uid');
      expect(CloudEgressStore.lastWriteRefusal, isNot(contains('uid')));
    });

    test('native consent-write failure: the withdrawal already closed native; '
        'Dart stays frozen, nothing is sent, the failure is reported', () async {
      await fieldDevice();
      // Every consent-state layer refuses the write (Dart secure, Dart file
      // and the native egress write the Dart transition makes).
      egress.secure.failWrites = true;
      egress.file.failWrites = true;
      nativeWriteFails = true;

      await expectLater(service().disableCloud(commitLocalOff: commitOff),
          throwsA(isA<CloudDisableException>()));

      expect(withdrawals, hasLength(1));
      expect(withdrawals.single.frozen, isTrue);
      expect(ConsentAuthority.egressFrozen, isTrue,
          reason: 'no durable OFF: Dart egress stays denied');
      expect(ConsentAuthority.egressFreezeTag, startsWith('disable:begin:'));
      expect(calls, isEmpty);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      for (final c in EgressClass.values) {
        expect(await ConsentAuthority(repo.getSettings).allows(c), isFalse);
      }
    });

    test('the native withdrawal itself failing never blocks the local OFF',
        () async {
      await fieldDevice();
      withdrawError = StateError('channel down');

      await service().disableCloud(commitLocalOff: commitOff);

      expect(withdrawals, hasLength(1));
      expect(CaptureDeviceRegistrationService.lastNativeWithdrawal,
          'disable:native_withdraw_failed');
      expect((await recordOf('uid-a'))!.state, EgressState.off);
      expect(nativeRecords['uid-a']!.state, EgressState.off,
          reason: 'the Dart transition still restricts native on its own');
    });

    test('race: the withdrawal runs while Dart egress is already frozen and '
        'before any request of the transition (drain, revoke)', () async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      final s = service();
      await s.syncBackendState();
      expect(consent.links, hasLength(1));
      calls.clear();
      withdrawals.clear();
      withdrawReport = const NativeEgressWithdrawal(
          mirror: 'restricted',
          config: 'restricted',
          egress: 'restricted',
          inflightBefore: 1,
          cancelled: 1);

      await s.disableCloud(commitLocalOff: commitOff);

      expect(withdrawals, hasLength(1));
      expect(withdrawals.single.frozen, isTrue);
      expect(withdrawals.single.callsBefore, 0,
          reason: 'nothing left before the native paths were closed');
      expect(calls, ['revoke'], reason: 'only the content-free revoke follows');
      expect(CaptureDeviceRegistrationService.lastNativeWithdrawal,
          'disable:mirror=restricted;config=restricted;egress=restricted;'
          'inflight_before=1;cancelled=1');
    });

    test('restart with the field state (settings OFF, record ON): native is '
        'closed first, then the record is aligned OFF', () async {
      await fieldDevice(settingsOn: false);

      await service().syncBackendState();

      expect(withdrawals.map((w) => w.uid), ['uid-a']);
      expect(CaptureDeviceRegistrationService.lastNativeWithdrawal,
          startsWith('reconcile_align_off:'));
      expect((await recordOf('uid-a'))!.state, EgressState.off);
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect(calls, isEmpty);
    });

    test('restart while a disable is pending (DISABLING): native is closed '
        'before OFF is committed, no revoke is replayed', () async {
      await fieldDevice();
      await egress.gate.writeRecord(const CloudEgressRecord(
          state: EgressState.disabling,
          ownerUid: 'uid-a',
          transitionGeneration: 4,
          reservedVersion: 4));

      await service().syncBackendState();

      expect(withdrawals.map((w) => w.uid), ['uid-a']);
      expect(CaptureDeviceRegistrationService.lastNativeWithdrawal,
          startsWith('pending_disable:'));
      expect((await recordOf('uid-a'))!.state, EgressState.off);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(calls, isEmpty);
    });

    // D-SO1 (found on device 2026-11-13): a start-up reconciliation aligned
    // Cloud consent down without telling native, so the App Intent kept
    // uploading SMS text while the app showed Cloud as off.
    group('D-SO1: a start-up downgrade closes native first', () {
      Future<void> settingsOnWithoutEnable() => save(
          cloud: ConsentState.accepted,
          ai: ConsentState.accepted,
          enable: false);

      test('activation record MISSING while settings are ON', () async {
        await settingsOnWithoutEnable();

        await service().syncBackendState();

        expect(withdrawals.map((w) => w.uid), ['uid-a']);
        expect(withdrawals.single.callsBefore, 0,
            reason: 'native is closed before any request of this start');
        expect(CaptureDeviceRegistrationService.lastNativeWithdrawal,
            startsWith('reconcile_record_missing:'));
        expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
        expect(ConsentAuthority.egressFrozen, isFalse);
        expect(calls, isEmpty, reason: 'no upload, no link, no revoke');
      });

      test('activation record DISABLED (OFF) while settings are ON', () async {
        await egress.gate.writeRecord(const CloudEgressRecord(
            state: EgressState.off,
            ownerUid: 'uid-a',
            transitionGeneration: 2,
            reservedVersion: 2));
        await settingsOnWithoutEnable();

        await service().syncBackendState();

        expect(withdrawals.map((w) => w.uid), ['uid-a']);
        expect(CaptureDeviceRegistrationService.lastNativeWithdrawal,
            startsWith('reconcile_record_disabled:'));
        expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
        expect((await recordOf('uid-a'))!.state, EgressState.off);
        expect(calls, isEmpty);
      });

      for (final record in ['missing', 'disabled']) {
        test('$record: the native close cannot be confirmed -> Dart stays '
            'frozen, settings still go OFF, nothing is sent', () async {
          if (record == 'disabled') {
            await egress.gate.writeRecord(const CloudEgressRecord(
                state: EgressState.off,
                ownerUid: 'uid-a',
                transitionGeneration: 2,
                reservedVersion: 2));
          }
          await settingsOnWithoutEnable();
          withdrawError = StateError('channel down');

          await service().syncBackendState();

          expect(withdrawals, hasLength(1));
          expect(ConsentAuthority.egressFrozen, isTrue);
          expect(ConsentAuthority.egressFreezeTag,
              'reconcile_record_$record:native_unconfirmed');
          expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
          expect(calls, isEmpty);
          for (final c in EgressClass.values) {
            expect(await ConsentAuthority(repo.getSettings).allows(c), isFalse);
          }
        });
      }

      test('restart in the state an older build left (settings OFF, record '
          'missing): native is closed once per process, never frozen', () async {
        await settingsOnWithoutEnable();
        await service().syncBackendState(); // the downgrade itself
        withdrawals.clear();

        final restarted = service(); // a new process
        await restarted.syncBackendState();
        await restarted.syncBackendState();

        expect(withdrawals.map((w) => w.uid), ['uid-a'],
            reason: 'once per process, not on every reconciliation');
        expect(CaptureDeviceRegistrationService.lastNativeWithdrawal,
            startsWith('reconcile_record_missing:'));
        expect(ConsentAuthority.egressFrozen, isFalse);
        expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
        expect(calls, isEmpty);
      });

      test('restart, settings already OFF, native unreachable: not frozen '
          '(Dart sends nothing as it is) and the repair is retried', () async {
        withdrawError = StateError('channel down');
        final s = service();

        await s.syncBackendState();
        await s.syncBackendState();

        expect(withdrawals.length, greaterThan(1),
            reason: 'retried on later reconciliations until confirmed');
        expect(ConsentAuthority.egressFrozen, isFalse);
        expect(calls, isEmpty);
      });

      test('an App Intent upload in flight during the downgrade is cancelled '
          'by the same native call, before any Dart request', () async {
        await settingsOnWithoutEnable();
        withdrawReport = const NativeEgressWithdrawal(
            mirror: 'restricted',
            config: 'restricted',
            egress: 'absent',
            inflightBefore: 1,
            cancelled: 1);

        await service().syncBackendState();

        expect(withdrawals.single.callsBefore, 0);
        expect(CaptureDeviceRegistrationService.lastNativeWithdrawal,
            'reconcile_record_missing:mirror=restricted;config=restricted;'
            'egress=absent;inflight_before=1;cancelled=1');
        expect(calls, isEmpty);
      });

      test('Android has no native lane: the downgrade is unchanged', () async {
        await settingsOnWithoutEnable();

        await service(android: true).syncBackendState();

        expect(withdrawals, isEmpty);
        expect(ConsentAuthority.egressFrozen, isFalse);
        expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      });
    });

    test('offline disable, then connectivity: only the content-free revoke '
        'is retried, nothing is uploaded, nothing is reopened', () async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      var clock = DateTime.utc(2026, 11, 13);
      final s = service(
          backoff: const [Duration(seconds: 30)], now: () => clock);
      await s.syncBackendState();
      consent.setError = const CaptureBackendException('offline');
      await s.disableCloud(commitLocalOff: commitOff);
      consent.setError = null;
      expect(withdrawals, hasLength(1), reason: 'closed while offline');
      expect(await s.pendingRevocationGeneration('uid-a'), isNotNull);
      calls.clear();

      clock = clock.add(const Duration(seconds: 31)); // connectivity is back
      await s.syncBackendState();
      await s.syncBackendState();

      expect(calls, ['revoke']);
      expect(withdrawals, hasLength(1), reason: 'OFF is settled: no re-run');
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      s.dispose();
    });

    test('a deliberate later re-enable is not overridden: no withdrawal and '
        'no stale revoke after it', () async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      var clock = DateTime.utc(2026, 11, 13);
      final s = service(
          backoff: const [Duration(seconds: 30)], now: () => clock);
      await s.syncBackendState();
      consent.setError = const CaptureBackendException('offline');
      await s.disableCloud(commitLocalOff: commitOff);
      consent.setError = null;
      calls.clear();

      await s.enableCloudForTest(
          commitLocalOn: () => save(
              cloud: ConsentState.accepted,
              ai: ConsentState.accepted,
              enable: false));
      clock = clock.add(const Duration(hours: 2));
      await s.syncBackendState();
      await s.syncBackendState();
      await service().syncBackendState(); // a relaunch

      expect(withdrawals, hasLength(1), reason: 'only the user-confirmed OFF');
      expect(calls, isNot(contains('revoke')));
      expect((await recordOf('uid-a'))!.state, EgressState.on);
      expect((await repo.getSettings()).cloudProcessingEnabled, isTrue);
      s.dispose();
    });
  });

  test('the retry timer fires by itself while the app runs (real clock)',
      () async {
    await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
    final s = service(backoff: const [Duration(milliseconds: 40)]);
    await s.syncBackendState();
    consent.setError = const CaptureBackendException('offline');
    await s.disableCloud(
        commitLocalOff: () =>
            save(cloud: ConsentState.declined, ai: ConsentState.declined));
    consent.setError = null;
    calls.clear();
    await _waitFor(() => calls.isNotEmpty, limit: const Duration(seconds: 3));
    final sw = Stopwatch()..start();
    while (await service().pendingRevocationGeneration('uid-a') != null &&
        sw.elapsed < const Duration(seconds: 3)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    s.dispose();
    expect(calls, ['revoke']);
    expect(await service().pendingRevocationGeneration('uid-a'), isNull);
  });
}

/// The server port only touches its sync service on a replay; these tests never
/// reach it.
CaptureSyncService _unusedSync() => _Unused();


class _FailingSaveRepo extends DriftUserSettingsRepository {
  _FailingSaveRepo(super.db);
  @override
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity settings) async =>
      throw StateError('local OFF write failed');
}

/// Waits (wall clock, bounded) until [cond] holds. Real file I/O now precedes
/// the revoke (the second disable_pending store), so counting microtask turns
/// is not a valid wait under parallel load.
Future<void> _waitFor(bool Function() cond,
    {Duration limit = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  while (!cond() && sw.elapsed < limit) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

class _Unused implements CaptureSyncService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected ${invocation.memberName}');
}

/// The server port normally re-runs `syncBackendState` (which would re-link A
/// at once); this view lets the test observe the state BEFORE the re-link.
class _NoRelink implements CaptureDeviceRegistrationService {
  _NoRelink(this._inner);
  final CaptureDeviceRegistrationService _inner;
  @override
  Future<void> syncBackendState() async {}
  @override
  Future<bool> isLinkedForCloud() => _inner.isLinkedForCloud();
  @override
  Future<String?> readDeviceSecret() => _inner.readDeviceSecret();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected ${invocation.memberName}');
}

class _Guard extends OwnershipGuard {
  final AdmissionToken current =
      const AdmissionToken(ownerUid: 'uid-a', generation: 'gen-a');

  @override
  Future<AdmissionToken> capture() async => current;

  @override
  Future<bool> isCurrent(AdmissionToken token) async => token == current;
}
