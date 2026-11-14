import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/cloud_resume_reminder.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/session/f2_fixture.dart';
import '../harness/egress_test_support.dart';
import '../harness/native_enable_sim.dart';
import '../harness/paused_egress_support.dart';

// Adversarial Cloud/AI lifecycle attacks (scenarios 15-23 + cross-account).
// The REAL AppSession / per-uid Drift / CloudEgressGate / registration service;
// native is the scripted NativeEnableSim through the real MethodChannel. No
// test touches a network: the capture backend throws on any call.

class _NoNetwork implements CaptureBackendClient {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('unexpected network operation');
  }
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
  late CloudEgressGate gate;

  Future<void> signIn(String uid) async {
    final sdk = await F2Fixture.liveClient(uid);
    f.session.configureConsentSdkClient(() => sdk);
    await f.signIn(uid);
  }

  DriftUserSettingsRepository repo() =>
      DriftUserSettingsRepository(f.host.current!.database);

  CaptureDeviceRegistrationService service(DriftUserSettingsRepository s) {
    final db = f.host.current!.database;
    final svc = CaptureDeviceRegistrationService(
      settingsRepository: s,
      gate: gate,
      client: net,
      isIos: () => true,
      isBackendConfigured: () => true,
      readSession: () => f.host.activeUid == null
          ? null
          : (uid: f.host.activeUid!, jwt: 'jwt'),
      captureWorkAuthority: f.session.captureLocalWorkAuthority,
      isCurrentScope: () => identical(f.host.current?.database, db),
      readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
    );
    // The production owner-publication hook (explicit plan).
    f.session.configureCaptureOwnerPublish((u, a) =>
        svc.publishRestrictiveOwnerDetailed(
            admissionAuthority: a, plan: f.session.explicitPublishPlanFor(a)));
    return svc;
  }

  ConsentLocalWork work() {
    final capability = f.session.captureConsentCapability()!;
    return ConsentLocalWork(capability,
        <T>(action) => f.session.runConsentLocalOperation(capability, action));
  }

  /// Exactly what the Settings toggle / the banner's auto-resume run
  /// (saveConsentChoice minus the Riverpod plumbing).
  Future<Object?> choose(
          DriftUserSettingsRepository s, CaptureDeviceRegistrationService svc,
          {bool cloud = false, bool ai = false, bool declined = false}) =>
      applyConsentChoice(
              scope: work(),
              repository: s,
              writer: s,
              service: svc,
              cloud: cloud,
              ai: ai,
              declined: declined)
          .then<Object?>((v) => v, onError: (Object e) => e);

  /// F1 fixture: a lifetime fence (here: the plain-expiry fence) left
  /// OFF + retirement in native; the Dart layers still say ON.
  void nativeRetiredOffAfterExpiry() {
    sim
      ..hashKeyExists = true
      ..egressState = 'OFF'
      ..egressGeneration = 20
      ..egressVersion = 9
      ..retirement = {
        'operationId': 'c' * 32,
        'transitionGeneration': 18,
        'reservedVersion': 4,
        'ownerGeneration': 5,
        'ownerEpoch': sim.ownerEpoch,
      };
    final dartOn = rigEnvelope(rigRecord(EgressState.on, 19, 3));
    rig.secure.value = dartOn;
    rig.file.value = dartOn;
  }

  Future<void> saveOn(DriftUserSettingsRepository s, {bool ai = true}) async =>
      s.saveSettings((await s.getSettings()).copyWith(
        cloudConsentState: ConsentState.accepted,
        aiConsentState: ai ? ConsentState.accepted : ConsentState.declined,
      ));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    previousGate = CloudEgressGate.instance;
    rig = EgressRig();
    NativeCaptureBridge.debugTreatHostAsNative = true;
    // Production native slot: the gate reads the SAME (simulated) native store
    // the enable/withdraw channel calls write.
    gate = CloudEgressGate(
      store: CloudEgressStore(
          secure: rig.secure,
          file: rig.file,
          native: NativeEgressSlot.platformDefault(),
          pendingSecure: rig.pendingSecure,
          pendingFile: rig.pendingFile),
      activeOwner: () async => kRigOwner,
      resolved: true,
      nativeInflight: (_) async => (count: 0, latestDeadline: null),
    );
    CloudEgressGate.instance = gate;
    ConsentAuthority.egressFrozen = false;
    net = _NoNetwork();
    sim = NativeEnableSim();
    NativeCaptureBridge.debugTreatHostAsNative = true;
    // SharedCaptureStore.withdrawCloudEgress (restrictive, owner-scoped): the
    // scripted sim does not model it, so model its device contract here.
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'withdrawCloudEgress') {
        sim.calls.add(call);
        final wasOn = sim.egressState == 'ON';
        if (wasOn) sim.egressState = 'DISABLING';
        return {
          'mirror': 'restricted',
          'config': 'restricted',
          'egress': wasOn ? 'restricted' : 'already_denied',
          'inflightBefore': 0,
          'cancelled': 0,
        };
      }
      return sim.handle(call);
    });
    f = await F2Fixture.create();
    f.session.configureCaptureOwnerClear(() async {
      sim.ownerAlive = false;
      sim.ownerEpoch++;
      return true;
    });
    f.session.configureCaptureOwnerPublish(null);
    await signIn(kRigOwner);
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

  group('15: app-made pause (expiry fence) is resumed with AI', () {
    test(
        'expiry fence (native OFF+retired, Dart ON, settings ON+AI) -> '
        'reconcile saves declined + reminder(aiWasOn) -> the auto-resume '
        'route ends Cloud+AI ON; a later reconcile does not pause it again',
        () async {
      final s = repo();
      await saveOn(s, ai: true);
      nativeRetiredOffAfterExpiry();
      final svc = service(s);
      addTearDown(svc.dispose);

      // Relaunch / readmission reconciliation after the fence.
      await svc.resolvePendingDisable();
      final paused = await s.getSettings();
      expect(paused.cloudProcessingEnabled, isFalse,
          reason: 'the reconcile `rec off && on` branch paused Cloud');
      expect(await CloudResumeReminder().shouldShow(kRigOwner, paused), isTrue);
      expect(await CloudResumeReminder().aiWasOn(kRigOwner), isTrue);
      expect(await gate.permits(owner: kRigOwner), isFalse);
      expect(net.calls, 0);

      // The banner's auto-resume: saveConsentChoice(cloud: true, ai: aiWasOn).
      final ai = await CloudResumeReminder().aiWasOn(kRigOwner);
      final result = await choose(s, svc, cloud: true, ai: ai);
      expect(result, isA<UserSettingsEntity>(), reason: '$result');
      final resumed = await s.getSettings();
      expect(resumed.cloudProcessingEnabled, isTrue);
      expect(resumed.aiConsentGranted, isTrue);
      expect(sim.egressState, 'ON');
      expect(sim.retirement, isNull);
      expect(
          (await CloudEgressStore.forTesting(secure: rig.secure, file: rig.file)
                  .readOwnerLayers(kRigOwner))
              .records
              .every((r) => r.state == EgressState.on),
          isTrue);
      await CloudResumeReminder().dismiss(kRigOwner); // the banner does this

      // Loop check: the next launch's reconciliation keeps it ON.
      final svc2 = service(repo());
      addTearDown(svc2.dispose);
      await svc2.resolvePendingDisable();
      final after = await repo().getSettings();
      expect(after.cloudProcessingEnabled, isTrue, reason: 'no pause loop');
      expect(after.aiConsentGranted, isTrue);
      expect(await CloudResumeReminder().shouldShow(kRigOwner, after), isFalse);
      expect(sim.egressState, 'ON');
      expect(net.calls, 0,
          reason: 'nothing left the device in the local phase');
    });
  });

  group('16/20: the user\'s own OFF is never auto-resumed', () {
    test('explicit OFF -> relaunch reconcile: OFF, no reminder', () async {
      final s = repo();
      final svc = service(s);
      addTearDown(svc.dispose);
      expect(await choose(s, svc, cloud: true, ai: true),
          isA<UserSettingsEntity>());
      expect(sim.egressState, 'ON');
      expect(await choose(s, svc, declined: true), isA<UserSettingsEntity>());
      final off = await s.getSettings();
      expect(off.cloudProcessingEnabled, isFalse);
      final svc2 = service(repo());
      addTearDown(svc2.dispose);
      await svc2.resolvePendingDisable();
      final later = await repo().getSettings();
      expect(later.cloudProcessingEnabled, isFalse);
      expect(await CloudResumeReminder().shouldShow(kRigOwner, later), isFalse);
      expect(await CloudResumeReminder().aiWasOn(kRigOwner), isFalse);
      expect(await gate.permits(owner: kRigOwner), isFalse);
    });

    test(
        'killed right after the native withdrawal of a user OFF (native '
        'DISABLING, Dart ON, settings ON): relaunch completes OFF and records '
        'NO reminder', () async {
      final s = repo();
      await saveOn(s, ai: true);
      final dartOn = rigEnvelope(rigRecord(EgressState.on, 5, 2));
      rig.secure.value = dartOn;
      rig.file.value = dartOn;
      // withdrawCloudEgress: ON -> DISABLING at the SAME generation.
      sim
        ..hashKeyExists = true
        ..egressState = 'DISABLING'
        ..egressGeneration = 5
        ..egressVersion = 2;
      final svc = service(s);
      addTearDown(svc.dispose);
      await svc.resolvePendingDisable();
      final after = await s.getSettings();
      expect(after.cloudProcessingEnabled, isFalse);
      expect(await CloudResumeReminder().shouldShow(kRigOwner, after), isFalse,
          reason: 'a user OFF must never be recorded as an app-made pause');
      expect(await gate.permits(owner: kRigOwner), isFalse);
    });

    test(
        'killed mid-enable (durable Dart pending, native barrier): relaunch '
        'is never ON; the next explicit enable is not locked out', () async {
      final s = repo();
      final svc = service(s);
      addTearDown(svc.dispose);
      sim.fault('writeCloudEgressEnableOn', SimFault.platformError);
      final first = await choose(s, svc, cloud: true, ai: true);
      expect(first, isNot(isA<UserSettingsEntity>()));
      expect(await gate.permits(owner: kRigOwner), isFalse);
      // Relaunch.
      sim.faults.clear();
      final svc2 = service(repo());
      addTearDown(svc2.dispose);
      await svc2.resolvePendingDisable();
      expect((await repo().getSettings()).cloudProcessingEnabled, isFalse);
      expect(await gate.permits(owner: kRigOwner), isFalse);
      // Not stuck: the user's next explicit enable reaches ON.
      final retry = await choose(repo(), svc2, cloud: true, ai: true);
      expect(retry, isA<UserSettingsEntity>(), reason: '$retry');
      expect(sim.egressState, 'ON');
    });
  });

  group('19: quick toggles end at the last tap', () {
    // The UI serializes taps (the consent sheet's `_granting`, the Privacy
    // screen's confirmation), so each tap starts after the previous returned.
    for (final endOn in [false, true]) {
      test('ON/OFF/ON/OFF${endOn ? '/ON' : ''}, back to back', () async {
        final s = repo();
        final svc = service(s);
        addTearDown(svc.dispose);
        for (final on in [true, false, true, false, if (endOn) true]) {
          final r = on
              ? await choose(s, svc, cloud: true, ai: true)
              : await choose(s, svc, declined: true);
          expect(r, isA<UserSettingsEntity>(), reason: 'tap on=$on: $r');
          final now = await s.getSettings();
          expect(now.cloudProcessingEnabled, on);
          expect(sim.egressState == 'ON', on);
          expect(await gate.permits(owner: kRigOwner), on);
        }
        expect(
            await CloudResumeReminder()
                .shouldShow(kRigOwner, await s.getSettings()),
            isFalse,
            reason: 'user toggles never record an app-made pause');
      });
    }
  });

  group('15x/19: auto-resume racing the user\'s own OFF', () {
    test(
        'the dashboard auto-resume is in flight (owner publication) when the '
        'user withdraws on the Privacy screen: the user OFF must win',
        () async {
      final s = repo();
      await saveOn(s, ai: true);
      nativeRetiredOffAfterExpiry();
      final svc = service(s);
      addTearDown(svc.dispose);
      await svc.resolvePendingDisable();
      expect((await s.getSettings()).cloudProcessingEnabled, isFalse);
      expect(await CloudResumeReminder().aiWasOn(kRigOwner), isTrue);

      // CloudResumeBanner._autoResume -> saveConsentChoice(cloud, ai).
      final hold = sim.hold('publishRestrictiveCaptureOwner');
      final resume = choose(s, svc, cloud: true, ai: true);
      await sim.reached['publishRestrictiveCaptureOwner']!.future
          .timeout(const Duration(seconds: 5));

      // PrivacyScreen._withdrawConsent, verbatim decision order.
      final w = work();
      const choices = ConsentChoices(
          cloud: ConsentState.declined, ai: ConsentState.declined);
      final before = await w.run(s.getSettings);
      final updated = choices.applyTo(before);
      final pendingState =
          await svc.pendingEnableState(before, ownerUid: kRigOwner);
      if (pendingState != PendingEnableState.none) {
        await svc.withdrawPendingEnable(
            capability: w.capability,
            commitLocalOff: () =>
                w.run(() => s.saveConsentChoice(w.capability, choices)));
      } else if (svc.isDisablingCloud(before, updated)) {
        await svc.disableCloud(
            commitLocalOff: () =>
                w.run(() => s.saveConsentChoice(w.capability, choices)));
      } else {
        await w.run(() => s.saveConsentChoice(w.capability, choices));
      }
      final userOff = await s.getSettings();
      expect(userOff.cloudProcessingEnabled, isFalse);

      hold.complete();
      final r = await resume;
      final end = await s.getSettings();
      expect(end.cloudProcessingEnabled, isFalse,
          reason: 'resume=$r pending=$pendingState: the user tapped OFF last');
      expect(end.aiConsentGranted, isFalse);
      expect(sim.egressState, isNot('ON'));
      expect(await gate.permits(owner: kRigOwner), isFalse);
    });
  });

  group('extra: the reminder is per account', () {
    test("B never resumes from A's reminder", () async {
      final s = repo();
      await saveOn(s, ai: true);
      nativeRetiredOffAfterExpiry();
      final svc = service(s);
      addTearDown(svc.dispose);
      await svc.resolvePendingDisable();
      expect(
          await CloudResumeReminder()
              .shouldShow(kRigOwner, await s.getSettings()),
          isTrue);
      // A different account on this device, its own Cloud OFF row.
      final bOff = (await s.getSettings());
      expect(await CloudResumeReminder().shouldShow('uid-b', bOff), isFalse);
      expect(await CloudResumeReminder().aiWasOn('uid-b'), isFalse);
      expect(await CloudResumeReminder().shouldShow('', bOff), isFalse);
    });
  });

  // ── Gate-level attacks (no session) ──────────────────────────────────────
  group('17/22: Cloud OFF (offline or not) sends no SMS/transaction/AI', () {
    late TestEgress egress;
    late List<http.BaseRequest> seen;
    late http.Client spy;
    setUp(() {
      egress = TestEgress().install();
      seen = [];
      spy = MockClient((req) async {
        seen.add(req);
        throw const SocketExceptionLike();
      });
    });

    for (final path in [
      '/rest/v1/transactions',
      '/functions/v1/parse-sms',
      '/functions/v1/ai-insights',
      '/functions/v1/register-capture-device',
      '/rest/v1/rpc/sync_push',
    ]) {
      test('POST $path is denied before the transport', () async {
        final client = GatedHttpClient(spy);
        Object? err;
        try {
          await client.post(Uri.parse('${egress.supabaseUrl}$path'),
              body: jsonEncode({'sms': 'Bank: 50 SAR'}));
        } catch (e) {
          err = e;
        }
        expect(err, isA<EgressDeniedException>());
        expect(seen, isEmpty);
      });
    }
  });

  group('21: Dart layers disagree (secure ON, file OFF)', () {
    test('ordinary egress fails closed; sign-in still goes through', () async {
      final egress = TestEgress().install();
      String env(EgressState st, int g) => jsonEncode({
            'v': 1,
            'records': {
              'uid-a': CloudEgressRecord(
                      state: st,
                      ownerUid: 'uid-a',
                      transitionGeneration: g,
                      reservedVersion: g)
                  .toJson()
            }
          });
      egress.secure.value = env(EgressState.on, 2);
      egress.file.value = env(EgressState.off, 1);
      expect(await egress.gate.permits(owner: 'uid-a'), isFalse);
      final seen = <String>[];
      final spy = MockClient((req) async {
        seen.add('${req.method} ${req.url.path}');
        return http.Response('{}', 200);
      });
      final client = GatedHttpClient(spy);
      Object? err;
      try {
        await client.post(
            Uri.parse('${egress.supabaseUrl}/rest/v1/transactions'),
            body: '{}');
      } catch (e) {
        err = e;
      }
      expect(err, isA<EgressDeniedException>());
      await egress.gate.runAccountControl(AccountControlOp.signIn, () async {
        await client.post(
            Uri.parse(
                '${egress.supabaseUrl}/auth/v1/token?grant_type=id_token'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'provider': 'google', 'id_token': 'x'}));
      });
      expect(seen, ['POST /auth/v1/token']);
      expect(await egress.gate.permitsSessionRefresh(), isTrue);
    });
  });
}

class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}
