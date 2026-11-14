import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_consent_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';

import '../core/session/f2_fixture.dart';
import '../harness/egress_test_support.dart';

/// Adversarial: Cloud across an account switch (scenarios 10 and 13).
///
/// Scenario 10 runs the sign-out unlink through the REAL path: AppSession.signOut
/// takes the ticket from the real CaptureDeviceRegistrationService, which posts
/// through the real CaptureBackendClient -> GatedHttpClient -> CloudEgressGate
/// (process instance). Only the socket (MockClient) and the consent link RPC
/// are faked.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _ConsentServer extends CaptureConsentClient {
  _ConsentServer() : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  final links = <String>[];
  @override
  Future<void> link({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
    required int clientGeneration,
  }) async =>
      links.add(jwt);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('10: A Cloud ON -> sign out -> B Cloud OFF', () {
    late F2Fixture f;
    late TestEgress egress;
    late CloudEgressGate oldGate;
    late List<http.Request> wire;
    late AppDatabase dbA;
    late AppDatabase dbB;

    setUp(() async {
      oldGate = CloudEgressGate.instance;
      f = await F2Fixture.create();
      egress = TestEgress(seedOn: true)..owner = 'uid-a';
      egress.install();
      wire = [];
      CaptureDeviceRegistrationService.debugResetUnlinkTarget();
      dbA = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      dbB = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    });
    tearDown(() async {
      ConsentAuthority.egressFrozen = false;
      AppSession.instance.configureCaptureUnlinkTicket(null);
      CaptureDeviceRegistrationService.debugResetUnlinkTarget();
      await dbA.close();
      await dbB.close();
      await f.dispose();
      CloudEgressGate.instance = oldGate;
    });

    CaptureDeviceRegistrationService serviceFor(
        AppDatabase db, CaptureSession? Function() session, String owner) {
      final backend = CaptureBackendClient(
        supabaseUrl: 'https://example.supabase.co',
        anonKey: 'anon-key',
        // The production transport: the process gate in front of the socket.
        httpClient: GatedHttpClient(MockClient((request) async {
          wire.add(request);
          if (request.url.path.endsWith('/register-device')) {
            return http.Response(
                jsonEncode({'deviceSecret': 'secret-$owner'}), 200);
          }
          return http.Response('{}', 200);
        })),
      );
      return CaptureDeviceRegistrationService(
        settingsRepository: DriftUserSettingsRepository(db),
        client: backend,
        consentClient: _ConsentServer(),
        storage: const FlutterSecureStorage(),
        isIos: () => true,
        isAndroid: () => false,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-1',
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
        readSession: session,
        readReplicaOwnerUid: () async => owner,
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
        gate: egress.gate,
      );
    }

    Future<void> setCloud(AppDatabase db, ConsentState cloud) async {
      final repo = DriftUserSettingsRepository(db);
      final s = await repo.getSettings();
      await repo.saveSettings(s.copyWith(cloudConsentState: cloud));
    }

    test(
        "A's sign-out sends exactly ONE unlink POST, admitted through the real "
        'gate after the lifecycle fence; B (Cloud OFF) sends nothing',
        () async {
      await f.signIn('uid-a');
      await setCloud(dbA, ConsentState.accepted);
      CaptureSession? sessionA = (uid: 'uid-a', jwt: 'jwt-a');
      final a = serviceFor(dbA, () => sessionA, 'uid-a');
      await a.linkToCurrentUser();
      expect(await a.consentAckSnapshot(), isNotNull,
          reason: 'A is linked with Cloud ON');
      final beforeSignOut = wire.length;

      // The worst realistic state at sign-out: the lifecycle fence is up and
      // ordinary egress is frozen. Ordinary traffic must be refused...
      egress.gate.denyForLifecycleLoss();
      ConsentAuthority.egressFrozen = true;
      await expectLater(
          GatedHttpClient(MockClient((r) async {
            wire.add(r);
            return http.Response('{}', 200);
          })).post(Uri.parse(
              'https://example.supabase.co/functions/v1/sync-captures')),
          throwsA(isA<EgressDeniedException>()));

      // ...and the sign-out unlink must still reach the server.
      await AppSession.instance.signOut();
      sessionA = null;
      await pumpEventQueue(times: 50);

      final sent = wire.skip(beforeSignOut).toList();
      expect(sent.map((r) => '${r.method} ${r.url.path}'),
          ['POST /functions/v1/unlink-capture-device']);
      final body = jsonDecode(sent.single.body) as Map<String, dynamic>;
      expect(body, {'installId': 'install-1', 'deviceSecret': 'secret-uid-a'});
      expect(sent.single.headers['Authorization'], 'Bearer anon-key',
          reason: "no user JWT of A leaves after A's sign-out");
      expect(
          await const FlutterSecureStorage()
              .read(key: 'qirsh_capture_consent_ack'),
          isNull);
      expect(egress.gate.inFlightCount, 0);

      // B signs in with Cloud OFF: nothing more leaves for B.
      egress.gate.releaseLifecycleDenial();
      ConsentAuthority.egressFrozen = false;
      egress.owner = 'uid-b';
      await f.signIn('uid-b');
      await setCloud(dbB, ConsentState.declined);
      final b = serviceFor(dbB, () => (uid: 'uid-b', jwt: 'jwt-b'), 'uid-b');
      await b.linkToCurrentUser();
      await AppSession.instance.signOut();
      await pumpEventQueue(times: 50);
      expect(
          wire
              .skip(beforeSignOut)
              .where((r) => r.url.path.endsWith('unlink-capture-device')),
          hasLength(1),
          reason: 'exactly one unlink overall (B never linked)');
      expect(wire.skip(beforeSignOut + 1), isEmpty,
          reason: 'B with Cloud OFF sends nothing');
    });
  });

  group('10b: A linked in an EARLIER process', () {
    late F2Fixture f;
    late TestEgress egress;
    late CloudEgressGate oldGate;
    late List<http.Request> wire;
    late AppDatabase dbA;

    setUp(() async {
      oldGate = CloudEgressGate.instance;
      f = await F2Fixture.create();
      egress = TestEgress(seedOn: true)..owner = 'uid-a';
      egress.install();
      wire = [];
      CaptureDeviceRegistrationService.debugResetUnlinkTarget();
      dbA = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    });
    tearDown(() async {
      ConsentAuthority.egressFrozen = false;
      AppSession.instance.configureCaptureUnlinkTicket(null);
      CaptureDeviceRegistrationService.debugResetUnlinkTarget();
      await dbA.close();
      await f.dispose();
      CloudEgressGate.instance = oldGate;
    });

    CaptureDeviceRegistrationService serviceA() =>
        CaptureDeviceRegistrationService(
          settingsRepository: DriftUserSettingsRepository(dbA),
          client: CaptureBackendClient(
            supabaseUrl: 'https://example.supabase.co',
            anonKey: 'anon-key',
            httpClient: GatedHttpClient(MockClient((request) async {
              wire.add(request);
              if (request.url.path.endsWith('/register-device')) {
                return http.Response(
                    jsonEncode({'deviceSecret': 'secret-a'}), 200);
              }
              return http.Response('{}', 200);
            })),
          ),
          consentClient: _ConsentServer(),
          storage: const FlutterSecureStorage(),
          isIos: () => true,
          isAndroid: () => false,
          isBackendConfigured: () => true,
          loadInstallId: () async => 'install-1',
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
          gate: egress.gate,
        );

    test(
        'relaunch with a frozen Cloud view, then sign-out: the install is '
        'still unlinked from A', () async {
      await f.signIn('uid-a');
      final repo = DriftUserSettingsRepository(dbA);
      await repo.saveSettings((await repo.getSettings())
          .copyWith(cloudConsentState: ConsentState.accepted));
      await serviceA().linkToCurrentUser(); // process 1: linked, ack written
      expect(
          await const FlutterSecureStorage()
              .read(key: 'qirsh_capture_consent_ack'),
          isNotNull);

      // Process 2: the in-memory unlink target is gone. This launch the
      // ownerless/native read froze Cloud, so the startup link-check is blocked.
      CaptureDeviceRegistrationService.debugResetUnlinkTarget();
      ConsentAuthority.egressFrozen = true;
      await serviceA().linkToCurrentUser();
      final before = wire.length;

      await AppSession.instance.signOut();
      await pumpEventQueue(times: 50);

      expect(
          wire
              .skip(before)
              .where((r) => r.url.path.endsWith('/unlink-capture-device')),
          hasLength(1),
          reason: "A's server link must be cut, or A's pushes keep reaching "
              'this phone for the next user');
    });
  });

  group('13: leftover native pending / uncertainty of A', () {
    test(
        "A's held pending enable (Dart layers + native pending_held) neither "
        "makes B's Cloud view uncertain nor blocks B's admission", () async {
      const aHeld = true;
      final native = NativeEgressSlot(
        read: (o) async {
          if (o == 'uid-a' && aHeld) {
            throw const FormatException('native_egress_uncertain:pending_held');
          }
          return null;
        },
        write: (_) async {},
      );
      final egress = TestEgress(native: native).install();
      final gate = egress.gate;
      // B is ON (B enabled Cloud earlier).
      await gate.writeRecord(const CloudEgressRecord(
          state: EgressState.on,
          ownerUid: 'uid-b',
          transitionGeneration: 1,
          reservedVersion: 1));
      // A left a pending-enable record in the secure Dart pending layer.
      final pending = jsonEncode({
        'v': 1,
        'pending': {
          'uid-a': {
            'owner_uid': 'uid-a',
            'transition_generation': 2,
            'reserved_version': 2,
            'operation': 'op-a',
          }
        }
      });
      egress.pendingSecure.value = pending;
      egress.owner = 'uid-b';
      expect(await gate.pendingBlocks(owner: 'uid-a'), isTrue,
          reason: 'the fixture really is a held pending of A');

      final view = await gate.view(owner: 'uid-b');
      expect(view.uncertain, isFalse,
          reason: 'problems=${view.readout.problems}');
      expect(await gate.pendingBlocks(owner: 'uid-b'), isFalse);
      final t = await gate.admit();
      gate.release(t);
      expect((await gate.view(owner: 'uid-a')).uncertain, isTrue,
          reason: "A's own view is still uncertain");
    });
  });
}
