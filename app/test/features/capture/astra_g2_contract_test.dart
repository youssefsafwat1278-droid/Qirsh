import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_consent_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';

import '../../harness/egress_test_support.dart';

// Astra G2: P1/P2/P4/P5/P6/P7 at the registration-service level. Required tests
// (section D): 2 stale link after an owner switch, 3 stale mirror / config /
// finally after the generation advances, 4 mixed-store crash recovery, 5 corrupt
// or unreadable store, 6 a transport active across the OFF transition, 7 the
// Dart background paths in DISABLING and after OFF, 8 Android stale-secret /
// account-switch revoke.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _Backend extends CaptureBackendClient {
  _Backend(this.calls)
      : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  final List<String> calls;
  Future<void> Function()? onRegister;

  @override
  Future<String> registerDevice(
      {required String installId, String platform = 'ios'}) async {
    calls.add('registerDevice');
    await onRegister?.call();
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
  }
}

class _Consent extends CaptureConsentClient {
  _Consent(this.calls)
      : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  final List<String> calls;
  final links = <({String jwt, int generation, int version})>[];
  final sets = <({int generation, int version})>[];
  final revokes = <({String jwt, String owner, int generation, int version})>[];
  Future<void> Function()? onLink;
  Future<void> Function()? onSet;
  Future<void> Function()? onRevoke;
  Object? revokeError;
  RevokeResult revokeResult = const RevokeResult(ok: true, applied: true);

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
    links.add((jwt: jwt, generation: clientGeneration, version: version));
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
    sets.add((generation: clientGeneration, version: version));
  }

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
    await onRevoke?.call();
    if (revokeError != null) throw revokeError!;
    revokes.add((
      jwt: jwt,
      owner: ownerUid,
      generation: transitionGeneration,
      version: version
    ));
    return revokeResult;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DriftUserSettingsRepository repo;
  late List<String> calls;
  late _Backend backend;
  late _Consent consent;
  late TestEgress egress;
  late List<({String uid, bool cloud, int version, int? gen})> published;
  late List<({String uid, bool cloud, int? gen})> mirrors;
  late List<({bool cloud, String? owner, int? gen})> configs;
  CaptureSession? session;
  String? replicaOwner;

  CaptureDeviceRegistrationService service({
    bool android = false,
    CaptureBackendClient? client,
    Duration timeout = const Duration(seconds: 1),
    DriftUserSettingsRepository? settings,
  }) =>
      CaptureDeviceRegistrationService(
        revokeTimeout: timeout,
        settingsRepository: settings ?? repo,
        client: client ?? backend,
        consentClient: consent,
        storage: const FlutterSecureStorage(),
        isIos: () => !android,
        isAndroid: () => android,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-id',
        loadApnsToken: () async => null,
        readSession: () => session,
        readReplicaOwnerUid: () async => replicaOwner,
        readOwnerEpoch: () async => 0,
        writeNativeBackendConfig: ({
          required cloudProcessingEnabled,
          required installId,
          deviceSecret,
          required backendUrl,
          required anonKey,
          required aiConsentGranted,
          String? ownerUid,
          int? transitionGeneration,
        }) async =>
            configs.add((
              cloud: cloudProcessingEnabled,
              owner: ownerUid,
              gen: transitionGeneration
            )),
        writeConsentMirror: ({
          required uid,
          required cloud,
          required ai,
          required version,
          int? transitionGeneration,
        }) async =>
            mirrors.add((uid: uid, cloud: cloud, gen: transitionGeneration)),
        publishOwner: ({
          required uid,
          required cloud,
          required ai,
          required version,
          required expectedEpoch,
          int? transitionGeneration,
        }) async =>
            published.add((
              uid: uid,
              cloud: cloud,
              version: version,
              gen: transitionGeneration
            )),
      );

  Future<void> save({ConsentState? cloud, ConsentState? ai}) async {
    final s = await repo.getSettings();
    // Astra H2.2: Cloud becomes ON only through an explicit enable, which also
    // writes the durable ON record. A test that grants consent models that.
    if (cloud == ConsentState.accepted || ai == ConsentState.accepted) {
      final cur = (await egress.gate.view(owner: replicaOwner ?? '')).record;
      if (cur == null || cur.state != EgressState.on) {
        await egress.gate
            .enable(owner: replicaOwner ?? '', reservedVersion: s.consentVersion + 1);
      }
    }
    await repo
        .saveSettings(s.copyWith(cloudConsentState: cloud, aiConsentState: ai));
  }

  Future<void> commitOff() =>
      save(cloud: ConsentState.declined, ai: ConsentState.declined);

  Future<CaptureDeviceRegistrationService> linkedOn(
      {bool android = false}) async {
    await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
    final s = service(android: android);
    await s.syncBackendState();
    calls.clear();
    return s;
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    repo = DriftUserSettingsRepository(db);
    calls = [];
    backend = _Backend(calls);
    consent = _Consent(calls);
    published = [];
    mirrors = [];
    configs = [];
    session = (uid: 'uid-a', jwt: 'jwt-a');
    replicaOwner = 'uid-a';
    egress = TestEgress(drain: const Duration(milliseconds: 150))
      ..owner = 'uid-a';
    egress.install();
  });
  tearDown(() async {
    ConsentAuthority.egressFrozen = false;
    await db.close();
  });

  Future<EgressState?> stateOf(String owner) async =>
      (await egress.gate.view(owner: owner)).record?.state;

  // ── test 2 ──────────────────────────────────────────────────────────────
  group('2: a stale link callback after an owner switch', () {
    test('writes no ack and publishes no owner for the old uid', () async {
      await save(cloud: ConsentState.accepted);
      final hold = Completer<void>();
      consent.onLink = () => hold.future;
      final s = service();
      final link = s.linkToCurrentUser();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, contains('link'));

      // A -> B while A's link is in flight (the account hooks advance the epoch).
      session = (uid: 'uid-b', jwt: 'jwt-b');
      replicaOwner = 'uid-b';
      egress.gate.advanceEpoch();
      hold.complete();
      await link;

      expect(await s.consentAckSnapshot(), isNull,
          reason: 'no ack for the stale link, for A or for B');
      expect(published, isEmpty);
      expect(
          await const FlutterSecureStorage().read(key: 'qirsh_capture_consent_ack'),
          isNull);
    });

    test('an owner/session switch WITHOUT an epoch bump is caught too',
        () async {
      await save(cloud: ConsentState.accepted);
      final hold = Completer<void>();
      consent.onLink = () => hold.future;
      final s = service();
      final link = s.linkToCurrentUser();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      session = (uid: 'uid-b', jwt: 'jwt-b');
      replicaOwner = 'uid-b';
      hold.complete();
      await link;
      expect(published, isEmpty);
      expect(
          await const FlutterSecureStorage().read(key: 'qirsh_capture_consent_ack'),
          isNull);
    });

    test('link and set carry the client transition generation (C.2)',
        () async {
      await save(cloud: ConsentState.accepted);
      final s = service();
      await s.linkToCurrentUser();
      final gen = (await egress.gate.view(owner: 'uid-a')).record!
          .transitionGeneration;
      expect(consent.links.single.generation, gen);
      await save(ai: ConsentState.declined);
      await s.syncBackendState();
      expect(consent.sets.single.generation, gen);
    });
  });

  // ── test 3 ──────────────────────────────────────────────────────────────
  group('3: stale mirror / config / finally after the generation advances', () {
    test('a consent set that returns after the epoch advanced widens no mirror '
        'and writes no ack', () async {
      final s = await linkedOn();
      mirrors.clear();
      await save(ai: ConsentState.declined);
      final hold = Completer<void>();
      consent.onSet = () => hold.future;
      final sync = s.syncBackendState();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final mirrorsBeforeAnswer = mirrors.length;
      egress.gate.advanceEpoch();
      hold.complete();
      await sync;
      expect(mirrors.length, mirrorsBeforeAnswer,
          reason: 'the stale answer wrote no (widened) mirror');
      final ack = await s.consentAckSnapshot();
      expect(ack!.ai, isTrue, reason: 'the stale answer did not move the ack');
    });

    test('a native config write after a stale registration round trip is '
        'dropped', () async {
      await save(cloud: ConsentState.accepted);
      final hold = Completer<void>();
      backend.onRegister = () => hold.future;
      final s = service();
      final sync = s.syncNativeState();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      configs.clear();
      egress.gate.advanceEpoch(); // a transition began
      hold.complete();
      await sync;
      expect(configs.where((c) => c.cloud), isEmpty,
          reason: 'no widening native config from a stale callback');
    });

    test('the disable callback never writes the NEW owner after an account '
        'switch; the old owner keeps its marker', () async {
      final s = await linkedOn();
      var committed = false;
      final hold = Completer<void>();
      consent.onRevoke = () => hold.future;
      final done = s.disableCloud(commitLocalOff: () async {
        committed = true;
        await commitOff();
      });
      await Future<void>.delayed(const Duration(milliseconds: 250));
      // The account switches while the revoke is still in flight.
      session = (uid: 'uid-b', jwt: 'jwt-b');
      replicaOwner = 'uid-b';
      hold.complete();
      await expectLater(done, throwsA(isA<CloudDisableException>()));
      expect(committed, isFalse);
      expect((await repo.getSettings()).cloudProcessingEnabled, isTrue,
          reason: 'B\'s replica was never written by A\'s callback');
      expect(await stateOf('uid-a'), EgressState.disabling,
          reason: 'A\'s marker stays for A\'s next admission');
      expect(ConsentAuthority.egressFrozen, isFalse,
          reason: 'B is evaluated independently');
    });

    test('an old callback cannot mutate newer state even after the barrier '
        'cleared (epoch, not a flag)', () async {
      await save(cloud: ConsentState.accepted);
      final hold = Completer<void>();
      consent.onLink = () => hold.future;
      final s = service();
      final stale = s.linkToCurrentUser();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      egress.gate.advanceEpoch(); // barrier up ...
      // ... barrier cleared: nothing frozen, same uid again.
      ConsentAuthority.egressFrozen = false;
      hold.complete();
      await stale;
      expect(published, isEmpty);
      expect(await s.consentAckSnapshot(), isNull);
    });
  });

  // ── test 4 + P5 ─────────────────────────────────────────────────────────
  group('4/P5: crash recovery and reconciliation', () {
    Future<void> plant(String owner, EgressState state, int gen) =>
        egress.gate.writeRecord(CloudEgressRecord(
            state: state,
            ownerUid: owner,
            transitionGeneration: gen,
            reservedVersion: 9));

    test('an A marker found while B is active is neither applied nor '
        'discarded; B runs independently; A is completed when admitted again',
        () async {
      await save(cloud: ConsentState.accepted);
      await plant('uid-a', EgressState.disabling, 4);
      replicaOwner = 'uid-b';
      session = (uid: 'uid-b', jwt: 'jwt-b');
      // B explicitly enabled Cloud (Astra H2.2: no adoption of an absent record).
      await egress.gate.enable(owner: 'uid-b', reservedVersion: 10);
      final s = service();
      await s.resolvePendingDisable();
      expect((await repo.getSettings()).cloudProcessingEnabled, isTrue,
          reason: 'never applied to B');
      expect(await stateOf('uid-a'), EgressState.disabling,
          reason: 'never discarded');
      expect(ConsentAuthority.egressFrozen, isFalse);
      await s.syncBackendState(); // B's own flow still works
      expect(calls, contains('link'));
      expect(await stateOf('uid-b'), EgressState.on);
      expect(await stateOf('uid-a'), EgressState.disabling);

      // A is admitted again: the marker is completed locally, no revoke.
      calls.clear();
      replicaOwner = 'uid-a';
      session = (uid: 'uid-a', jwt: 'jwt-a');
      await service().resolvePendingDisable();
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
      expect(await stateOf('uid-a'), EgressState.off);
      expect(calls, isEmpty);
    });

    test('recovery retries local OFF only: the revoke is never replayed at '
        'startup (not even with a consumed attempt and a live JWT)', () async {
      final s = await linkedOn();
      await plant('uid-a', EgressState.disabling, 7);
      await const FlutterSecureStorage().write(
          key: 'qirsh.capture_revoke_attempt.v1',
          value: '{"owner":"uid-a","transition_generation":7,"consumed":true}');
      ConsentAuthority.egressFrozen = false;
      for (var i = 0; i < 3; i++) {
        await service().resolvePendingDisable();
        await service().syncBackendState();
      }
      await s.retry();
      expect(calls.where((c) => c == 'revoke' || c == 'set'), isEmpty);
      expect((await service().serverRevocation())!.status,
          ServerRevocation.unconfirmed,
          reason: 'attempt consumed, outcome unknown: UNCONFIRMED, not retried');
    });

    test('the DISABLING record in one store only still overrides the other '
        '(secure only / file only)', () async {
      for (final fileOnly in [true, false]) {
        egress = TestEgress()..owner = 'uid-a';
        egress.install();
        await egress.gate
            .beginDisabling(owner: 'uid-a', reservedVersion: 2);
        (fileOnly ? egress.secure : egress.file).value = null;
        expect(await stateOf('uid-a'), EgressState.disabling);
      }
    });

    test('uncertain durable state at startup fails closed: frozen, no egress, '
        'nothing committed', () async {
      await linkedOn();
      egress.file.value = 'garbage';
      final s = service();
      await s.resolvePendingDisable();
      expect(ConsentAuthority.egressFrozen, isTrue);
      expect(await s.isLinkedForCloud(), isFalse);
      await s.syncBackendState();
      expect(calls, isEmpty);
      expect((await repo.getSettings()).cloudProcessingEnabled, isTrue,
          reason: 'uncertainty does not rewrite settings');
    });
  });

  // ── test 5 ──────────────────────────────────────────────────────────────
  group('5: a corrupt or unreadable store denies egress', () {
    for (final mode in ['corrupt file', 'corrupt secure', 'unreadable secure',
        'unreadable file']) {
      test(mode, () async {
        final s = await linkedOn();
        switch (mode) {
          case 'corrupt file':
            egress.file.value = '{"v":2}';
          case 'corrupt secure':
            egress.secure.value = 'nope';
          case 'unreadable secure':
            egress.secure.failReads = true;
          case 'unreadable file':
            egress.file.failReads = true;
        }
        await s.syncBackendState();
        await s.linkToCurrentUser();
        expect(await s.isLinkedForCloud(), isFalse);
        expect(calls, isEmpty);
        expect(await ConsentAuthority(repo.getSettings)
            .allows(EgressClass.financialSync), isFalse);
      });
    }

    test('a failed DISABLING write in every store: no revoke, local OFF still '
        'attempted, the UI is told, egress stays denied', () async {
      final s = await linkedOn();
      egress.secure.failWrites = true;
      egress.file.failWrites = true;
      var committed = false;
      await expectLater(
          s.disableCloud(commitLocalOff: () async {
            committed = true;
            await commitOff();
          }),
          throwsA(isA<CloudDisableException>()));
      expect(calls, isEmpty, reason: 'no revoke without a durable DISABLING');
      expect(committed, isTrue);
      expect(ConsentAuthority.egressFrozen, isTrue);
    });
  });

  // ── test 6 ──────────────────────────────────────────────────────────────
  group('6: a transport already active across the OFF transition', () {
    test('commit waits for the bounded drain; the in-flight request is '
        'cancelled and has no state effect', () async {
      final s = await linkedOn();
      final inner = Completer<http.Response>();
      final gated = CaptureBackendClient(
        supabaseUrl: 'https://x.invalid',
        anonKey: 'anon',
        httpClient: GatedHttpClient(MockClient((_) => inner.future)),
      );
      final inflight = gated.syncCaptures(
          installId: 'install-id', deviceSecret: 'device-secret');
      final inflightResult = expectLater(
          inflight, throwsA(isA<EgressDeniedException>()),
          reason: 'cancelled at the drain bound: no result reaches the caller');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(egress.gate.inFlightCount, 1);

      final sw = Stopwatch()..start();
      Duration? commitAt;
      await s.disableCloud(commitLocalOff: () async {
        commitAt = sw.elapsed;
        await commitOff();
      });
      await inflightResult;
      expect(commitAt, greaterThanOrEqualTo(const Duration(milliseconds: 140)),
          reason: 'OFF is committed only after the (150 ms) bounded drain');
      expect(egress.gate.inFlightCount, 0);
      // The late answer changes nothing.
      inner.complete(http.Response('{"captures":[]}', 200));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await stateOf('uid-a'), EgressState.off);
      expect((await repo.getSettings()).cloudProcessingEnabled, isFalse);
    });

    test('a request that completes inside the drain still has no effect '
        '(epoch advanced), and commit does not wait the full bound', () async {
      final s = await linkedOn();
      final inner = Completer<http.Response>();
      final gated = CaptureBackendClient(
        supabaseUrl: 'https://x.invalid',
        anonKey: 'anon',
        httpClient: GatedHttpClient(MockClient((_) => inner.future)),
      );
      final inflight = gated.syncCaptures(
          installId: 'install-id', deviceSecret: 'device-secret');
      final outcome = inflight.then<Object?>((v) => v, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      Timer(const Duration(milliseconds: 30),
          () => inner.complete(http.Response('{"captures":[]}', 200)));
      Duration? commitAt;
      final sw = Stopwatch()..start();
      await s.disableCloud(commitLocalOff: () async {
        commitAt = sw.elapsed;
        await commitOff();
      });
      expect(await outcome, isA<EgressDeniedException>());
      expect(commitAt, lessThan(const Duration(milliseconds: 140)));
    });
  });

  // ── test 7 ──────────────────────────────────────────────────────────────
  group('7: Dart background / resume transports in DISABLING and after OFF',
      () {
    test('syncCaptures, processIosSms, consent link and an AI-style call send '
        'nothing in DISABLING and after OFF', () async {
      final s = await linkedOn();
      var sent = 0;
      final inner = MockClient((request) async {
        sent++;
        return http.Response(
            request.url.path.endsWith('/link-capture-device')
                ? '{"ok":true,"applied":true}'
                : '{"captures":[]}',
            200);
      });
      final gated = CaptureBackendClient(
          supabaseUrl: 'https://x.invalid',
          anonKey: 'anon',
          httpClient: GatedHttpClient(inner));
      final consentClient = CaptureConsentClient(
          supabaseUrl: 'https://x.invalid',
          anonKey: 'anon',
          httpClient: GatedHttpClient(inner));

      Future<int> attempts() async {
        var ok = 0;
        for (final f in <Future<Object?> Function()>[
          () => gated.syncCaptures(installId: 'i', deviceSecret: 's'),
          () => gated.processIosSms(
              installId: 'i',
              deviceSecret: 's',
              payloadId: 'p',
              smsText: 'x',
              receivedAt: DateTime.utc(2026),
              allowAi: false,
              ownerUid: 'uid-a',
              ownerGeneration: 1),
          () => consentClient.link(
              installId: 'i',
              deviceSecret: 's',
              jwt: 'j',
              cloud: true,
              ai: false,
              version: 1,
              clientGeneration: 1),
          () => gated.registerPushToken(
              installId: 'i',
              deviceSecret: 's',
              apnsToken: 't',
              apnsEnvironment: 'sandbox'),
        ]) {
          try {
            await f();
            ok++;
          } on EgressDeniedException {
            // denied at admission
          }
        }
        return ok;
      }

      expect(await attempts(), greaterThan(0), reason: 'ON: admitted');
      final onSent = sent;

      // DISABLING (a hung revoke) ...
      final hold = Completer<void>();
      consent.onRevoke = () => hold.future;
      final done = s.disableCloud(commitLocalOff: commitOff);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await stateOf('uid-a'), EgressState.disabling);
      expect(await attempts(), 0);
      expect(sent, onSent);
      hold.complete();
      await done;

      // ... and after OFF.
      expect(await stateOf('uid-a'), EgressState.off);
      expect(await attempts(), 0);
      expect(sent, onSent);
    });
  });

  // ── test 8 + P2/P7 ──────────────────────────────────────────────────────
  group('8: Android revoke authorisation (stale secret / account switch)', () {
    test('Android links its device row to the owner with the JWT link on the '
        'ON path (same as iOS)', () async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      await service(android: true).syncBackendState();
      expect(calls, ['registerDevice', 'link']);
      expect(consent.links.single.jwt, 'jwt-a');
    });

    test('stored secret + was ON is NOT enough: no frozen-owner JWT, no revoke '
        '(NOT_ATTEMPTED)', () async {
      final s = await linkedOn(android: true);
      session = null; // signed out / token gone
      await s.disableCloud(commitLocalOff: commitOff);
      expect(calls.where((c) => c == 'revoke' || c == 'setDeviceConsent'),
          isEmpty);
      expect((await s.serverRevocation())!.status,
          ServerRevocation.notAttempted);
      expect(await stateOf('uid-a'), EgressState.off, reason: 'local OFF done');
    });

    test('a secret but no uid-bound ack: no revoke', () async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      await const FlutterSecureStorage()
          .write(key: 'qirsh_capture_device_secret', value: 'stale-secret');
      final s = service(android: true);
      await s.disableCloud(commitLocalOff: commitOff);
      expect(calls.where((c) => c == 'revoke'), isEmpty);
      expect((await s.serverRevocation())!.status,
          ServerRevocation.notAttempted);
    });

    test('account switch: B\'s JWT is never used for A\'s transition, and '
        'B\'s state is never touched', () async {
      final s = await linkedOn(android: true);
      session = (uid: 'uid-b', jwt: 'jwt-b'); // JWT of ANOTHER owner
      await s.disableCloud(commitLocalOff: commitOff);
      expect(consent.revokes, isEmpty);
      expect(calls.where((c) => c == 'revoke'), isEmpty);
      expect(await stateOf('uid-b'), isNull);
      expect((await s.serverRevocation())!.status,
          ServerRevocation.notAttempted);
    });

    test('an ack that belongs to another uid is not an authorisation',
        () async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      await const FlutterSecureStorage().write(
          key: 'qirsh_capture_device_secret', value: 'device-secret');
      await const FlutterSecureStorage()
          .write(key: 'qirsh_capture_consent_ack', value: 'uid-b|1|1|1');
      await service(android: true).disableCloud(commitLocalOff: commitOff);
      expect(consent.revokes, isEmpty);
    });

    test('the frozen owner\'s JWT + ack: exactly ONE revoke, bound to the '
        'frozen owner / generation / version', () async {
      final s = await linkedOn(android: true);
      final reserved = (await repo.getSettings()).consentVersion + 1;
      await s.disableCloud(commitLocalOff: commitOff);
      expect(consent.revokes, hasLength(1));
      final r = consent.revokes.single;
      expect((r.jwt, r.owner, r.version), ('jwt-a', 'uid-a', reserved));
      expect(r.generation,
          (await egress.gate.view(owner: 'uid-a')).record!.transitionGeneration);
      expect((await s.serverRevocation())!.status, ServerRevocation.confirmed);
    });
  });

  group('P2: the one-shot revoke', () {
    test('outcomes map to CONFIRMED / UNCONFIRMED; nothing claims content was '
        'nulled', () async {
      for (final c in <(String, RevokeResult?, Object?, ServerRevocation)>[
        ('applied', const RevokeResult(ok: true, applied: true), null,
            ServerRevocation.confirmed),
        ('already revoked',
            const RevokeResult(ok: true, applied: false, reason: 'already_revoked'),
            null, ServerRevocation.confirmed),
        ('no-op row', const RevokeResult(ok: true, applied: false,
            reason: 'owner_mismatch'), null, ServerRevocation.unconfirmed),
        ('not ok', const RevokeResult(ok: false, applied: false), null,
            ServerRevocation.unconfirmed),
        ('http failure', null, const CaptureBackendException('revoke_failed_500'),
            ServerRevocation.unconfirmed),
      ]) {
        FlutterSecureStorage.setMockInitialValues({});
        egress = TestEgress()..owner = 'uid-a';
        egress.install();
        calls.clear();
        consent = _Consent(calls);
        if (c.$2 != null) consent.revokeResult = c.$2!;
        consent.revokeError = c.$3;
        await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
        final s = service();
        await s.syncBackendState();
        await s.disableCloud(commitLocalOff: commitOff);
        expect((await s.serverRevocation())!.status, c.$4, reason: c.$1);
        expect(calls.where((x) => x == 'revoke'), hasLength(1), reason: c.$1);
        await save(cloud: ConsentState.accepted);
      }
    });

    test('a timed-out revoke is UNCONFIRMED, local OFF completes, never retried',
        () async {
      final s = await linkedOn();
      consent.onRevoke = () => Completer<void>().future;
      final svc = service(timeout: const Duration(milliseconds: 60));
      await svc.disableCloud(commitLocalOff: commitOff);
      expect((await svc.serverRevocation())!.status,
          ServerRevocation.unconfirmed);
      expect(await stateOf('uid-a'), EgressState.off);
      expect(calls.where((c) => c == 'revoke'), hasLength(1));
      await s.syncBackendState();
      expect(calls.where((c) => c == 'revoke'), hasLength(1));
    });

    test('inputs are frozen at DISABLING: owner, generation, reserved version '
        'are in the durable record before anything is sent', () async {
      await linkedOn();
      final s = service();
      final reserved = (await repo.getSettings()).consentVersion + 1;
      final seen = Completer<CloudEgressRecord>();
      consent.onRevoke = () async {
        seen.complete((await egress.gate.view(owner: 'uid-a')).record!);
      };
      await s.disableCloud(commitLocalOff: commitOff);
      final rec = await seen.future;
      expect(rec.state, EgressState.disabling);
      expect(rec.reservedVersion, reserved);
      expect(consent.revokes.single.generation, rec.transitionGeneration);
      expect(consent.revokes.single.version, reserved);
    });

    test('the consumed revoke_attempt is durable BEFORE the send and separate '
        'from the DISABLING record', () async {
      await linkedOn();
      final s = service();
      String? attemptAtSend;
      consent.onRevoke = () async {
        attemptAtSend = await const FlutterSecureStorage()
            .read(key: 'qirsh.capture_revoke_attempt.v1');
      };
      await s.disableCloud(commitLocalOff: commitOff);
      expect(attemptAtSend, contains('"consumed":true'));
      expect(attemptAtSend, contains('"owner":"uid-a"'));
      expect(egress.secure.value, isNot(contains('revoke_attempt')));
    });

    test('if the attempt record cannot be written nothing is sent', () async {
      // Both slots of the revoke_attempt fail: simulate with a throwing storage.
      await linkedOn();
      final s = CaptureDeviceRegistrationService(
        settingsRepository: repo,
        client: backend,
        consentClient: consent,
        storage: _NoAttemptStorage(),
        markerDirectory: () async => throw StateError('fs down'),
        isIos: () => true,
        isAndroid: () => false,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-id',
        readSession: () => session,
        readReplicaOwnerUid: () async => replicaOwner,
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
        writeConsentMirror: ({
          required uid,
          required cloud,
          required ai,
          required version,
          int? transitionGeneration,
        }) async {},
      );
      await s.disableCloud(commitLocalOff: commitOff);
      expect(calls.where((c) => c == 'revoke'), isEmpty);
    });
  });

  group('P6 / enable', () {
    test('identity + OFF or unset consent: one atomic restrictive publish, no '
        'network', () async {
      for (final cloud in [ConsentState.declined, ConsentState.unset]) {
        published.clear();
        await save(cloud: cloud);
        await service().linkToCurrentUser();
        expect(calls, isEmpty);
        expect(published.single.cloud, isFalse);
        expect(published.single.uid, 'uid-a');
      }
    });

    test('uncertain authority publishes nothing (fail closed)', () async {
      await save(cloud: ConsentState.declined);
      egress.file.value = '###';
      await service().linkToCurrentUser();
      expect(published, isEmpty);
      expect(calls, isEmpty);
    });

    test('a publish carries the transition generation', () async {
      await save(cloud: ConsentState.accepted);
      await service().linkToCurrentUser();
      expect(published.single.gen, isNotNull);
    });

    test('enableCloud advances to a strictly greater generation and version, '
        'then the ON path runs', () async {
      final s = await linkedOn();
      await s.disableCloud(commitLocalOff: commitOff);
      final off = (await egress.gate.view(owner: 'uid-a')).record!;
      calls.clear();
      await s.enableCloudForTest(
          commitLocalOn: () => save(cloud: ConsentState.accepted));
      final on = (await egress.gate.view(owner: 'uid-a')).record!;
      expect(on.state, EgressState.on);
      expect(on.transitionGeneration, greaterThan(off.transitionGeneration));
      expect(on.reservedVersion, greaterThan(off.reservedVersion));
      await s.syncBackendState();
      expect(calls, contains('link'));
      expect(consent.links.last.generation, on.transitionGeneration);
    });
  });
}

/// Fails every write of the revoke attempt (and nothing else).
class _NoAttemptStorage extends FlutterSecureStorage {
  _NoAttemptStorage();
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (key == 'qirsh.capture_revoke_attempt.v1') throw StateError('keychain');
    return super.write(key: key, value: value);
  }
}
