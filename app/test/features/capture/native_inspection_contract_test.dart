import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';

import '../../core/session/f2_fixture.dart';
import '../../harness/native_enable_sim.dart';
import '../../harness/paused_egress_support.dart';

// R16 (Astra R45): the Dart interpretation of the REAL native inspection
// contract. `SharedCaptureStore.cloudEgressPending` never answers `done`: with
// no pending entry it answers `noBarrier` (both barrier layers `absent`, the
// egress layers carrying the lifetime owner generation/epoch), with entries
// `pending` / `incomplete`, otherwise `uncertain` / `conflict`. These replies
// are written out literally, as AppDelegate's `transitionMap` emits them, so the
// tests do not depend on the scripted simulator.

class _Spy extends DriftUserSettingsRepository {
  _Spy(AppDatabase db)
      : database = db,
        super(db);
  final AppDatabase database;
  int saved = 0;
  @override
  void afterConsentChoice(ConsentCapability capability, ConsentChoices choices) {
    saved++;
  }
}

class _NoNetwork implements CaptureBackendClient {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('unexpected network operation');
  }
}

const _cloudOnly =
    ConsentChoices(cloud: ConsentState.accepted, ai: ConsentState.declined);

Map<String, Object?> _absent(String layer) =>
    {'layer': layer, 'outcome': 'absent'};

/// What native returns for a completed enable: nothing pending, ON in both
/// egress layers bound to the owner lifetime.
Map<String, Object?> _nativeInspect({
  String status = 'noBarrier',
  List<Map<String, Object?>>? barrier,
  List<Map<String, Object?>>? egress,
  required int generation,
  required int version,
  required int ownerGeneration,
  required int ownerEpoch,
  Map<String, Object?> Function(Map<String, Object?> layer)? tweak,
}) {
  Map<String, Object?> on(String layer) => {
        'layer': layer,
        'outcome': 'verified',
        'state': 'ON',
        'transitionGeneration': generation,
        'reservedVersion': version,
        'ownerGeneration': ownerGeneration,
        'ownerEpoch': ownerEpoch,
      };
  return {
    'contractVersion': 1,
    'operation': 'inspect',
    'status': status,
    'barrier': barrier ?? [_absent('file'), _absent('keychain')],
    'egress': egress ??
        [
          for (final l in ['file', 'keychain'])
            tweak == null ? on(l) : tweak(on(l)),
        ],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('money_companion/native_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late EgressRig rig;
  late F2Fixture f;
  late NativeEnableSim sim;
  late _NoNetwork net;
  late CloudEgressGate previousGate;
  late _Spy settings;
  Map<String, Object?> Function()? inspectReply;

  Future<RestrictiveCaptureOwnerReceipt?> publish(
      String uid, AdmissionAuthority authority) async {
    final epoch = await NativeCaptureBridge.captureOwnerEpoch();
    return NativeCaptureBridge.publishRestrictiveCaptureOwner(
        uid: uid, version: 0, expectedEpoch: epoch);
  }

  Future<void> signIn(String uid) async {
    final sdk = await F2Fixture.liveClient(uid);
    f.session.configureConsentSdkClient(() => sdk);
    await f.signIn(uid);
  }

  CaptureDeviceRegistrationService service() => CaptureDeviceRegistrationService(
        settingsRepository: settings,
        gate: rig.gate,
        client: net,
        isIos: () => true,
        isBackendConfigured: () => true,
        readSession: () => f.host.activeUid == null
            ? null
            : (uid: f.host.activeUid!, jwt: 'jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        isCurrentScope: () =>
            identical(f.host.current?.database, settings.database),
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
      );

  ConsentLocalWork work() {
    final capability = f.session.captureConsentCapability()!;
    return ConsentLocalWork(
        capability,
        <T>(action) =>
            f.session.runConsentLocalOperation(capability, action));
  }

  Future<Object?> accept(CaptureDeviceRegistrationService s) =>
      applyConsentChoice(
        scope: work(),
        repository: settings,
        writer: settings,
        service: s,
        cloud: true,
        ai: true,
      ).then<Object?>((_) => null, onError: (Object e) => e);

  Map<String, Object?> completed({
    String status = 'noBarrier',
    List<Map<String, Object?>>? barrier,
    List<Map<String, Object?>>? egress,
    int? generation,
    int? version,
    int? ownerGeneration,
    int? ownerEpoch,
    Map<String, Object?> Function(Map<String, Object?> layer)? tweak,
  }) =>
      _nativeInspect(
        status: status,
        barrier: barrier,
        egress: egress,
        generation: generation ?? sim.egressGeneration,
        version: version ?? sim.egressVersion,
        ownerGeneration: ownerGeneration ?? sim.ownerGeneration,
        ownerEpoch: ownerEpoch ?? sim.ownerEpoch,
        tweak: tweak,
      );

  setUp(() async {
    previousGate = CloudEgressGate.instance;
    rig = EgressRig();
    CloudEgressGate.instance = rig.gate;
    ConsentAuthority.egressFrozen = false;
    net = _NoNetwork();
    sim = NativeEnableSim();
    inspectReply = null;
    NativeCaptureBridge.debugTreatHostAsNative = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final reply = inspectReply;
      if (call.method == 'getCloudEgressPending' && reply != null) {
        sim.calls.add(call);
        return reply();
      }
      return sim.handle(call);
    });
    f = await F2Fixture.create();
    f.session.configureCaptureOwnerClear(() async {
      sim.ownerAlive = false;
      sim.ownerEpoch++;
      return true;
    });
    f.session.configureCaptureOwnerPublish(publish);
    await signIn('uid-x');
    settings = _Spy(f.host.current!.database);
  });

  tearDown(() async {
    for (final h in sim.holds.values) {
      if (!h.isCompleted) h.complete();
    }
    await pumpEventQueue(times: 30);
    f.session.configureCaptureOwnerPublish(null);
    f.session.debugResetAdmissionState();
    await f.dispose();
    NativeCaptureBridge.debugTreatHostAsNative = false;
    messenger.setMockMethodCallHandler(channel, null);
    ConsentAuthority.egressFrozen = false;
    CloudEgressGate.instance = previousGate;
  });

  Future<CaptureDeviceRegistrationService> completedCloudOnly() async {
    final s = service();
    await s.enableCloud(
        write: ConsentWrite(f.session.captureConsentCapability()!, _cloudOnly));
    return s;
  }

  group('R16 completed native ON, as native really answers it', () {
    test('noBarrier + ON in both egress layers of this lifecycle is verified',
        () async {
      final s = await completedCloudOnly();
      inspectReply = () => completed();
      expect(await s.liveOnVerified(owner: 'uid-x'), isTrue);
    });

    test('truthful partial: Accept completes AI with a plain save, no second '
        'native enable', () async {
      final s = await completedCloudOnly();
      inspectReply = () => completed();
      expect(settings.saved, 1);
      final err = await accept(s);
      expect(err, isNull);
      final row = await settings.getSettings();
      expect(row.cloudProcessingEnabled, isTrue);
      expect(row.aiConsentGranted, isTrue);
      expect(settings.saved, 2);
      expect(sim.of('beginCloudEgressEnable'), hasLength(1));
      expect(sim.of('finishCloudEgressEnable'), hasLength(1));
      expect(net.calls, 0);
    });
  });

  group('R16 every other native inspection is not a verified ON', () {
    final cases = <String, Map<String, Object?> Function()>{};

    void expectUnverified(String name, Map<String, Object?> Function() reply) {
      test(name, () async {
        final s = await completedCloudOnly();
        inspectReply = reply;
        expect(await s.liveOnVerified(owner: 'uid-x'), isFalse);
        final before = settings.saved;
        final err = await accept(s);
        expect(err, isA<CloudEnableWithdrawFirstException>());
        expect(settings.saved, before);
        expect(sim.of('beginCloudEgressEnable'), hasLength(1));
        expect(net.calls, 0);
      });
    }

    cases.addAll({
      'status done is not a native inspection status': () =>
          completed(status: 'done'),
      'status pending (a barrier is outstanding)': () => completed(
              status: 'pending',
              barrier: [
                for (final l in ['file', 'keychain'])
                  {
                    'layer': l,
                    'outcome': 'verified',
                    'operationId': 'a' * 32,
                    'transitionGeneration': sim.egressGeneration,
                    'reservedVersion': sim.egressVersion,
                    'ownerGeneration': sim.ownerGeneration,
                    'ownerEpoch': sim.ownerEpoch,
                  }
              ]),
      'status incomplete (one layer only)': () => completed(status: 'incomplete'),
      'status uncertain (unreadable or corrupt)': () =>
          completed(status: 'uncertain'),
      'status conflict (the layers disagree)': () =>
          completed(status: 'conflict'),
      'status ownerMismatch': () => completed(status: 'ownerMismatch'),
      'status stale': () => completed(status: 'stale'),
      'noBarrier but a barrier layer is not absent': () => completed(barrier: [
            _absent('file'),
            {'layer': 'keychain', 'outcome': 'unreadable'}
          ]),
      'missing physical egress reports': () => completed(egress: const []),
      'one egress layer absent': () => completed(egress: [
            _absent('file'),
            completed()['egress']! is List
                ? (completed()['egress'] as List).last as Map<String, Object?>
                : <String, Object?>{},
          ]),
      'an egress layer OFF': () =>
          completed(tweak: (l) => l['layer'] == 'keychain' ? {...l, 'state': 'OFF'} : l),
      'an egress layer DISABLING': () => completed(
          tweak: (l) =>
              l['layer'] == 'file' ? {...l, 'state': 'DISABLING'} : l),
      'an egress layer unreadable': () => completed(
          tweak: (l) =>
              l['layer'] == 'file' ? {...l, 'outcome': 'unreadable'} : l),
      'generation mismatch': () =>
          completed(generation: sim.egressGeneration + 1),
      'reserved version mismatch': () =>
          completed(version: sim.egressVersion + 1),
      'successor owner generation': () =>
          completed(ownerGeneration: sim.ownerGeneration + 1),
      'successor owner epoch': () => completed(ownerEpoch: sim.ownerEpoch + 1),
      'lifetime evidence missing': () => completed(
          tweak: (l) => {...l}
            ..remove('ownerGeneration')
            ..remove('ownerEpoch')),
      'a retirement (operationId) on the ON entry': () => completed(
          tweak: (l) => {...l, 'operationId': 'b' * 32}),
    });
    cases.forEach(expectUnverified);

    test('a null and a thrown inspection are not verified', () async {
      final s2 = await completedCloudOnly();
      sim.fault('getCloudEgressPending', SimFault.nullReply);
      expect(await s2.liveOnVerified(owner: 'uid-x'), isFalse);
      sim.fault('getCloudEgressPending', SimFault.platformError);
      expect(await s2.liveOnVerified(owner: 'uid-x'), isFalse);
    });

    test('the native owner is not this owner', () async {
      final s2 = await completedCloudOnly();
      inspectReply = () => completed();
      sim.ownerAlive = false;
      expect(await s2.liveOnVerified(owner: 'uid-x'), isFalse);
    });
  });

  group('R16 explicit retry over an unbound pending reads noBarrier', () {
    test('empty native egress evidence refuses cleanup without changing state',
        () async {
      sim.fault('beginCloudEgressEnable', SimFault.nullReply);
      expect(await accept(service()), isA<CloudEnableIncompleteException>());
      final before = (rig.pendingSecure.value, rig.pendingFile.value,
          rig.secure.value, rig.file.value);
      final begins = sim.of('beginCloudEgressEnable').length;
      final writes = sim.of('writeCloudEgressEnableOn').length;
      final publishes = sim.of('publishRestrictiveCaptureOwner').length;
      inspectReply = () => {
            'contractVersion': 1,
            'operation': 'inspect',
            'status': 'noBarrier',
            'barrier': [_absent('file'), _absent('keychain')],
            'egress': const <Object?>[],
          };
      final err = await accept(service());
      expect(err, isA<CloudEnableIncompleteException>());
      expect((err as CloudEnableIncompleteException).reason,
          startsWith('preflight_uncertain'));
      expect((rig.pendingSecure.value, rig.pendingFile.value,
          rig.secure.value, rig.file.value), before);
      expect(sim.of('beginCloudEgressEnable').length, begins);
      expect(sim.of('writeCloudEgressEnableOn').length, writes);
      expect(sim.of('publishRestrictiveCaptureOwner').length, publishes);
      expect(settings.saved, 0);
      expect(net.calls, 0);
      expect((await rig.gate.readPending()).blocks('uid-x'), isTrue);
    });

    test('native noBarrier with no ON: the denied-stage pending is cleared and '
        'a fresh enable completes', () async {
      sim.fault('beginCloudEgressEnable', SimFault.nullReply);
      expect(await accept(service()), isA<CloudEnableIncompleteException>());
      expect((await rig.gate.readPending()).blocks('uid-x'), isTrue);
      inspectReply = () => {
            'contractVersion': 1,
            'operation': 'inspect',
            'status': 'noBarrier',
            'barrier': [_absent('file'), _absent('keychain')],
            'egress': [_absent('file'), _absent('keychain')],
          };
      final err = await accept(service());
      expect(err, isNull);
      expect((await settings.getSettings()).cloudProcessingEnabled, isTrue);
      expect(settings.saved, 1);
      expect((await rig.gate.readPending()).blocks('uid-x'), isFalse);
      expect(sim.egressState, 'ON');
    });

    test('native uncertain / incomplete / conflict keep it denied', () async {
      for (final status in ['uncertain', 'incomplete', 'conflict']) {
        sim.fault('beginCloudEgressEnable', SimFault.nullReply);
        expect(await accept(service()), isA<CloudEnableIncompleteException>());
        inspectReply = () => {
              'contractVersion': 1,
              'operation': 'inspect',
              'status': status,
              'barrier': [_absent('file'), _absent('keychain')],
              'egress': const <Object?>[],
            };
        // Straight into the resume (the route refuses an unresolved pending
        // before it gets here; the resume itself must stay conservative too).
        expect(
            await service()
                .enableCloud(
                    write: ConsentWrite(
                        f.session.captureConsentCapability()!, _cloudOnly))
                .then<Object?>((_) => null, onError: (Object e) => e),
            isA<CloudEnableIncompleteException>(),
            reason: status);
        expect(await accept(service()), isA<CloudEnableWithdrawFirstException>(),
            reason: '$status: the route never enables over it');
        expect((await rig.gate.readPending()).blocks('uid-x'), isTrue,
            reason: status);
        expect(settings.saved, 0, reason: status);
        // Reset the Dart pending for the next status.
        final p = (await rig.gate.readPending()).agreed('uid-x') ??
            (await rig.gate.readPending()).partial('uid-x');
        await rig.gate.clearPendingEnable(p!);
        inspectReply = null;
      }
    });
  });
}
