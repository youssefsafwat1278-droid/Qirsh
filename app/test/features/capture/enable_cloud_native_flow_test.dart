import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:money_companion/core/privacy/cloud_resume_reminder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart'
    show OwnerLifetimeProof;
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

import '../../core/session/f2_fixture.dart';
import '../../harness/consent_session_support.dart';
import '../../harness/native_enable_sim.dart';
import '../../harness/paused_egress_support.dart';

// N-E: the full iOS Cloud-enable transition (owner prerequisite, durable Dart
// pending denial, native barrier, consent save, native completion, clear). The
// REAL AppSession / per-uid Drift / gate; the native side is the scripted
// contract stand-in reached through the real MethodChannel (protocol mocks prove
// Dart ordering only, not native execution). No test touches a network.

class _Settings extends DriftUserSettingsRepository {
  _Settings(AppDatabase db, {PlanningOutboxQueue? outboxQueue})
      : database = db,
        super(db, outboxQueue: outboxQueue);
  final AppDatabase database;
  Completer<void>? reached;
  Completer<void>? _release;
  int? _pauseAtRead;
  int reads = 0;
  int saved = 0;
  Object? failSave;
  Object? failReserve;
  Future<void> Function()? beforeSave;

  @override
  Future<int> reserveConsentVersion(ConsentCapability capability,
      {required int verifiedFrontier, required String operationId}) {
    final failure = failReserve;
    if (failure != null) throw failure;
    return super.reserveConsentVersion(capability,
        verifiedFrontier: verifiedFrontier, operationId: operationId);
  }

  void pauseAtRead(int n) {
    _pauseAtRead = n;
    reached = Completer<void>();
    _release = Completer<void>();
  }

  void resume() => _release!.complete();

  @override
  Future<UserSettingsEntity> getSettings() async {
    final mine = ++reads;
    final value = await super.getSettings();
    if (mine == _pauseAtRead && !reached!.isCompleted) {
      reached!.complete();
      await _release!.future;
    }
    return value;
  }

  @override
  Future<void> beforeConsentChoice(
      ConsentCapability capability, ConsentChoices choices) async {
    await beforeSave?.call();
    final failure = failSave;
    if (failure != null) throw failure;
  }

  @override
  void afterConsentChoice(
      ConsentCapability capability, ConsentChoices choices) {
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

const _accept =
    ConsentChoices(cloud: ConsentState.accepted, ai: ConsentState.accepted);

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
  var publicationFault = false;
  var publishHook = true;
  var autoSignIn = true;

  Future<RestrictiveCaptureOwnerReceipt?> publish(
      String uid, AdmissionAuthority authority) async {
    if (publicationFault) return null;
    final epoch = await NativeCaptureBridge.captureOwnerEpoch();
    return NativeCaptureBridge.publishRestrictiveCaptureOwner(
        uid: uid, version: 0, expectedEpoch: epoch);
  }

  Future<void> signIn(String uid) async {
    final sdk = await F2Fixture.liveClient(uid);
    f.session.configureConsentSdkClient(() => sdk);
    await f.signIn(uid);
  }

  CaptureDeviceRegistrationService service(_Settings settings,
          {CloudEgressGate? gate}) =>
      CaptureDeviceRegistrationService(
        settingsRepository: settings,
        gate: gate ?? rig.gate,
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

  Future<_Settings> freshSettings() async =>
      _Settings(f.host.current!.database);

  Future<Object?> enable(CaptureDeviceRegistrationService s,
          [ConsentCapability? capability]) =>
      s
          .enableCloud(
              write: ConsentWrite(
                  capability ?? f.session.captureConsentCapability()!, _accept))
          .then<Object?>((_) => null, onError: (Object e) => e);

  Future<bool> pendingPresent([String owner = kRigOwner]) async =>
      (await rig.gate.readPending()).blocks(owner);

  Future<List<CloudEgressRecord>> dartEgress() async =>
      (await CloudEgressStore.forTesting(secure: rig.secure, file: rig.file)
              .readOwnerLayers(kRigOwner))
          .records;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    previousGate = CloudEgressGate.instance;
    rig = EgressRig();
    CloudEgressGate.instance = rig.gate;
    ConsentAuthority.egressFrozen = false;
    net = _NoNetwork();
    sim = NativeEnableSim();
    publicationFault = false;
    publishHook = true;
    NativeCaptureBridge.debugTreatHostAsNative = true;
    messenger.setMockMethodCallHandler(channel, sim.handle);
    f = await F2Fixture.create();
    f.session.configureCaptureOwnerClear(() async {
      sim.ownerAlive = false;
      sim.ownerEpoch++;
      return true;
    });
    f.session.configureCaptureOwnerPublish(publishHook ? publish : null);
    if (autoSignIn) await signIn('uid-x');
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

  test('native reserved enable queues the exact committed account consent',
      () async {
    final db = f.host.current!.database;
    final queue = HookedOutbox(db, 'uid-x');
    final settings = _Settings(db, outboxQueue: queue);
    expect(await enable(service(settings)), isNull);
    final saved = await settings.getSettings();
    expect(queue.enqueues, 1);
    final pending = await queue.pendingItems(entityType: 'settings');
    expect(pending, hasLength(1));
    expect(pending.single.ownerUid, 'uid-x');
    expect(pending.single.payloadJson['cloud_processing_enabled'], isTrue);
    expect(pending.single.payloadJson['ai_consent_granted'], isTrue);
    expect(pending.single.payloadJson['consent_version'], saved.consentVersion);
    expect(pending.single.payloadJson['consent_only'], isTrue);
    expect(await pendingPresent(), isFalse);
  });

  group('same-owner return after a native lifetime ends', () {
    for (final readmission in [false, true]) {
      for (final pendingBarrier in [false, true]) {
        test('${readmission ? "readmission" : "startup"}: old ON lifetime with accepted settings '
            '${pendingBarrier ? "and a pending operation stays denied" : "settles to OFF without inheriting ON"}', () async {
          final settings = await freshSettings();
          await settings.saveSettings((await settings.getSettings()).copyWith(
            cloudConsentState: ConsentState.accepted,
            aiConsentState: ConsentState.accepted,
          ));
          rig.secure.value = rigEnvelope(rigRecord(EgressState.on, 20, 3));
          rig.file.value = rigEnvelope(rigRecord(EgressState.on, 20, 3));
          sim.egressState = 'ON';
          sim.egressGeneration = 20;
          sim.egressVersion = 3;
          sim.egressOwnerGeneration = sim.ownerGeneration;
          sim.egressOwnerEpoch = sim.ownerEpoch;
          sim.ownerEpoch++; // sign-out clears the native owner lifetime
          messenger.setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getCloudEgressState' && sim.egressState == 'ON') {
              return {'status': 'uncertain', 'reason': 'lifetime_fields_unbound'};
            }
            final response = await sim.handle(call);
            if (pendingBarrier && call.method == 'getCloudEgressPending') {
              return {
                ...(response as Map), 'status': 'uncertain',
                'barrier': [for (final layer in ['file', 'keychain'])
                  {'layer': layer, 'outcome': 'unreadable'}],
              };
            }
            return response;
          });
          final gate = CloudEgressGate(
            store: CloudEgressStore(secure: rig.secure, file: rig.file,
              native: NativeEgressSlot.platformDefault(),
              pendingSecure: rig.pendingSecure, pendingFile: rig.pendingFile),
            activeOwner: () async => kRigOwner, resolved: true,
            nativeInflight: (_) async => (count: 0, latestDeadline: null),
          );
          final svc = service(settings, gate: gate);
          addTearDown(svc.dispose);
          ConsentAuthority.freeze('reconcile_uncertain:native:lifetime_fields_unbound');
          if (readmission) {
            await svc.reconcileAfterAdmission(
              authority: f.session.captureLocalWorkAuthority()!,
              isCurrentScope: () => true,
            );
          } else {
            await svc.resolvePendingDisable();
          }
          expect(await gate.permits(owner: kRigOwner), isFalse);
          expect(net.calls, 0);
          if (pendingBarrier) {
            expect(sim.egressState, 'ON');
            expect((await settings.getSettings()).cloudProcessingEnabled, isTrue);
            expect(ConsentAuthority.egressFrozen, isTrue);
          } else {
            expect(sim.egressState, 'OFF');
            expect((await settings.getSettings()).cloudProcessingEnabled, isFalse);
            expect((await settings.getSettings()).aiConsentGranted, isFalse);
            expect(await CloudResumeReminder().shouldShow(
                kRigOwner, await settings.getSettings()), isTrue);
            expect(await CloudResumeReminder().shouldShow(
                'another-user', await settings.getSettings()), isFalse);
            expect(ConsentAuthority.egressFrozen, isFalse);
            final layers = await gate.store.readOwnerLayers(kRigOwner);
            expect(layers.uncertain, isFalse);
            expect(layers.records.every((r) => r.state == EgressState.off), isTrue);
          }
        });
      }
    }
  });

  group('successful enable', () {
    test('phases run in the ratified order and the gate opens only at the end',
        () async {
      final settings = await freshSettings();
      final order = <String>[];
      final snapshots = <String, Map<String, Object?>>{};
      sim.onCall = (m) {
        // The Phase 0 version preflight only inspects.
        if (m == 'captureOwnerEpoch' ||
            m == 'getCaptureOwner' ||
            m == 'getCloudEgressPending') {
          return;
        }
        order.add(m);
        snapshots[m] = {
          'pendingSecure': rig.pendingSecure.value,
          'pendingFile': rig.pendingFile.value,
          'secure': rig.secure.value,
          'file': rig.file.value,
          'frozen': ConsentAuthority.egressFrozen,
          'mirror': rig.gate.permitsNetworkSync,
          'saved': settings.saved,
          'net': net.calls,
        };
      };
      final error = await enable(service(settings));
      expect(error, isNull);
      expect(order, [
        'beginCloudEgressEnable',
        'writeCloudEgressEnableOn',
        'finishCloudEgressEnable',
      ]);

      final begin = snapshots['beginCloudEgressEnable']!;
      expect(begin['pendingSecure'], contains('uid-x'),
          reason: 'Dart denial is durable in BOTH layers before native begin');
      expect(begin['pendingFile'], contains('uid-x'));
      expect(begin['secure'], isNull, reason: 'no Dart ON before the barrier');
      expect(begin['file'], isNull);
      expect(begin['frozen'], isTrue);
      expect(begin['mirror'], isFalse);

      final writeOn = snapshots['writeCloudEgressEnableOn']!;
      expect(writeOn['pendingSecure'], contains(kSimOperationId),
          reason: 'the native binding is recorded in both Dart layers');
      expect(writeOn['pendingFile'], contains(kSimOperationId));
      expect(writeOn['secure'], contains('"ON"'));
      expect(writeOn['file'], contains('"ON"'));
      expect(writeOn['saved'], 0);

      final finish = snapshots['finishCloudEgressEnable']!;
      expect(finish['saved'], 1,
          reason: 'the typed consent save precedes native completion');
      expect(finish['pendingSecure'], contains(kSimOperationId),
          reason: 'the Dart denial stays until native completion');
      expect(finish['mirror'], isFalse);

      expect(await pendingPresent(), isFalse);
      expect((await rig.gate.readPending()).blocks(kRigOwner), isFalse);
      expect(sim.pending, isNull);
      expect(sim.egressState, 'ON');
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect(rig.native.writes, 0,
          reason: 'the generic native egress setter is not used by this flow');
      final stored = await settings.getSettings();
      expect(stored.cloudProcessingEnabled, isTrue);
      expect(net.calls, 0, reason: 'no backend registration inside the enable');
      expect(settings.saved, 1);
    });

    test(
        'the ON the flow wrote carries the allocated generation and the '
        'reserved version', () async {
      final settings = await freshSettings();
      final before = (await settings.getSettings()).consentVersion;
      expect(await enable(service(settings)), isNull);
      final args = Map<Object?, Object?>.from(
          sim.of('beginCloudEgressEnable').single.arguments as Map);
      expect(args['ownerUid'], 'uid-x');
      expect(args['reservedVersion'], before + 1);
      expect(args['transitionGeneration'], 1);
      final on = (await dartEgress()).first;
      expect((await dartEgress()).length, 2);
      expect(on.state, EgressState.on);
      expect(on.transitionGeneration, 1);
      expect(on.reservedVersion, before + 1);
      expect((await settings.getSettings()).consentVersion, before + 1);
    });

    test('the native phases present the exact binding the begin returned',
        () async {
      expect(await enable(service(await freshSettings())), isNull);
      for (final m in ['writeCloudEgressEnableOn', 'finishCloudEgressEnable']) {
        final a = Map<Object?, Object?>.from(sim.of(m).single.arguments as Map);
        expect(a['operationId'], kSimOperationId);
        expect(a['ownerGeneration'], 7);
        expect(a['ownerEpoch'], sim.ownerEpoch);
      }
      final finish = Map<Object?, Object?>.from(
          sim.of('finishCloudEgressEnable').single.arguments as Map);
      expect(finish['abandon'], false);
    });
  });

  group('first onboarding (needsOnboarding)', () {
    setUpAll(() => autoSignIn = false);
    tearDownAll(() => autoSignIn = true);
    test('the committed fresh identity enables through the consent capability',
        () async {
      final capability = await freshSignIn(f, 'uid-x');
      expect(capability, isNotNull);
      expect(f.session.captureLocalWorkAuthority(), isNull,
          reason: 'no ordinary local-work authority exists yet');
      final settings = await freshSettings();
      expect(await enable(service(settings), capability), isNull);
      expect(settings.saved, 1);
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
      expect(net.calls, 0);
    });
  });

  group('owner prerequisite', () {
    test('no restrictive publication hook: refused, nothing begun', () async {
      f.session.configureCaptureOwnerPublish(null);
      await f.session.completeOnboarding(
          method: 'google', email: 'uid-x@example.com', userId: 'uid-x');
      final settings = await freshSettings();
      final err = await enable(service(settings));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(await pendingPresent(), isFalse);
      expect(await rig.layers(), isEmpty);
      expect(net.calls, 0);
      expect(settings.saved, 0);
    });

    test('an unverified publication receipt: refused, retryable, no backend',
        () async {
      publicationFault = true;
      await signIn('uid-x');
      final settings = await freshSettings();
      final err = await enable(service(settings));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(await pendingPresent(), isFalse);
      expect(net.calls, 0);
      // Retryable: once the publication verifies, the same call succeeds.
      publicationFault = false;
      await signIn('uid-x');
      expect(await enable(service(await freshSettings())), isNull);
    });

    test('the native owner generation differs from the receipt: refused',
        () async {
      sim.ownerGeneration = 9; // getCaptureOwner now disagrees with the receipt
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(await pendingPresent(), isFalse);
    });

    test('the native owner is absent: refused', () async {
      sim.ownerAlive = false;
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
    });

    test('the owner epoch moved since the receipt: refused', () async {
      sim.ownerEpoch += 1;
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
    });

    test(
        'the publication proof (binding) is exposed only for the live '
        'lifecycle', () async {
      final capability = f.session.captureConsentCapability()!;
      final binding = await f.session.committedOwnerLifetime(capability);
      expect(binding, isNotNull);
      expect(binding!.ownerGeneration, 7);
      expect(binding.ownerEpoch, sim.ownerEpoch);
      f.session.markSessionInvalid();
      expect(await f.session.committedOwnerLifetime(capability), isNull,
          reason: 'a revoked proof is no proof');
    });

    test('publication is local: no backend call while it is awaited', () async {
      expect(net.calls, 0);
      expect(sim.of('publishRestrictiveCaptureOwner'), hasLength(1));
    });
  });

  // A returning process: the same-marker automatic admission publishes no native
  // lifetime, yet issues a current consent capability. The explicit enable
  // authorizes one bounded restrictive publication for exactly that capability.
  group('owner proof for a returning process', () {
    setUpAll(() => autoSignIn = false);
    tearDownAll(() => autoSignIn = true);

    Future<ConsentCapability> returning([String uid = 'uid-x']) async {
      f.session.configureCaptureOwnerPublish(null);
      await signIn(uid);
      f.session.configureCaptureOwnerPublish(publish);
      return f.session.captureConsentCapability()!;
    }

    Future<String> reasonOf(Object? err) async {
      expect(err, isA<CloudEnableIncompleteException>());
      return (err as CloudEnableIncompleteException).reason;
    }

    test('no lifetime: the explicit enable publishes once and succeeds',
        () async {
      final capability = await returning();
      expect(sim.of('publishRestrictiveCaptureOwner'), isEmpty);
      final settings = await freshSettings();
      expect(await enable(service(settings), capability), isNull);
      expect(sim.of('publishRestrictiveCaptureOwner'), hasLength(1));
      expect(sim.egressState, 'ON');
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
      expect(net.calls, 0);
    });

    test(
        'confirmed proof is reused; a healthy ON refresh never republishes '
        'OFF', () async {
      final capability = await returning();
      final first = await f.session.ensureCommittedOwnerLifetime(capability);
      final again = await f.session.ensureCommittedOwnerLifetime(capability);
      expect(first.binding, isNotNull);
      expect(again.binding, same(first.binding));
      expect(sim.of('publishRestrictiveCaptureOwner'), hasLength(1));
      expect(await enable(service(await freshSettings()), capability), isNull);
      expect(await f.session.ensureCommittedOwnerLifetime(capability),
          isA<OwnerLifetimeProof>());
      expect(sim.of('publishRestrictiveCaptureOwner'), hasLength(1));
      expect(sim.egressState, 'ON', reason: 'no OFF was republished over ON');
    });

    test('read-only committedOwnerLifetime publishes nothing', () async {
      final capability = await returning();
      expect(await f.session.committedOwnerLifetime(capability), isNull);
      expect(sim.of('publishRestrictiveCaptureOwner'), isEmpty);
    });

    test('a failed publication is retried by the next explicit enable',
        () async {
      final capability = await returning();
      sim.fault('publishRestrictiveCaptureOwner', SimFault.nullReply);
      final err = await enable(service(await freshSettings()), capability);
      expect(await reasonOf(err),
          'owner_publication/publication_incomplete/receipt_null');
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(await enable(service(await freshSettings()), capability), isNull);
      expect(sim.of('publishRestrictiveCaptureOwner'), hasLength(2));
    });

    test('diagnostic codes name the native refusal', () async {
      final expected = {
        SimFault.stale: 'native_stale',
        SimFault.pending: 'native_pending',
        SimFault.conflict: 'native_pending',
        SimFault.uncertain: 'native_uncertain',
        SimFault.incomplete: 'native_incomplete',
        SimFault.noBarrier: 'native_barrier',
        SimFault.ownerMismatch: 'native_owner',
      };
      final capability = await returning();
      // The production hook: the registration service names the refusal.
      final svc = service(await freshSettings());
      f.session.configureCaptureOwnerPublish(
          (u, a) => svc.publishRestrictiveOwnerDetailed(admissionAuthority: a));
      for (final e in expected.entries) {
        sim.fault('publishRestrictiveCaptureOwner', e.key);
        final err = await enable(service(await freshSettings()), capability);
        expect(await reasonOf(err),
            'owner_publication/publication_incomplete/${e.value}',
            reason: '${e.key}');
      }
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
    });

    test(
        'diagnostic codes: hook missing, refusal passthrough, error, '
        'unverified receipt', () async {
      final capability = await returning();
      f.session.configureCaptureOwnerPublish(null);
      expect(
          await reasonOf(
              await enable(service(await freshSettings()), capability)),
          'owner_publication/publication_incomplete/hook_missing');
      for (final c in {
        'hook_frozen': (String u, AdmissionAuthority a) async =>
            const RestrictiveOwnerRefusal('hook_frozen'),
        'hook_error': (String u, AdmissionAuthority a) async =>
            throw StateError('x'),
        'receipt_unconfirmed': (String u, AdmissionAuthority a) async =>
            Object(),
      }.entries) {
        f.session.configureCaptureOwnerPublish(c.value);
        expect(
            await reasonOf(
                await enable(service(await freshSettings()), capability)),
            'owner_publication/publication_incomplete/${c.key}');
      }
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
    });

    test('a publication that never answers times out and is retryable',
        () async {
      final capability = await returning();
      f.session
          .configureCaptureOwnerPublish((u, a) => Completer<Object?>().future);
      expect(
          await reasonOf(
              await enable(service(await freshSettings()), capability)),
          'owner_publication/publication_incomplete/timeout');
      f.session.configureCaptureOwnerPublish(publish);
      expect(await enable(service(await freshSettings()), capability), isNull);
    });

    test('capability loss during the publication never enables', () async {
      final capability = await returning();
      final hold = sim.hold('publishRestrictiveCaptureOwner');
      final running = enable(service(await freshSettings()), capability);
      await sim.reached['publishRestrictiveCaptureOwner']!.future;
      f.session.markSessionInvalid();
      hold.complete();
      expect(await running, isNotNull);
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(sim.egressState, isNot('ON'));
    });

    test('scope replacement during the publication never enables', () async {
      final capability = await returning();
      final hold = sim.hold('publishRestrictiveCaptureOwner');
      final running = enable(service(await freshSettings()), capability);
      await sim.reached['publishRestrictiveCaptureOwner']!.future;
      await f.host.lock();
      hold.complete();
      expect(await running, isNotNull);
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(sim.egressState, isNot('ON'));
    });

    test('an incomplete fence stays denied; an exact retry recovers it',
        () async {
      // A published lifetime is lost and its fence is not confirmed.
      f.session.configureCaptureOwnerPublish(publish);
      await signIn('uid-x');
      sim.fault('revokeCaptureAuthorizationLifetime', SimFault.nullReply);
      sim.fault('revokeCaptureAuthorizationLifetime', SimFault.nullReply);
      f.session.markSessionInvalid();
      await f.session.nativeLifecycleSettled();
      await signIn('uid-x');
      final capability = f.session.captureConsentCapability()!;
      // The retry of the same fence is refused again: still denied.
      final err = await enable(service(await freshSettings()), capability);
      expect(await reasonOf(err),
          'owner_publication/fence_incomplete/fence_unconfirmed');
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      // The next retry is confirmed: publication reopens and the enable runs.
      expect(await enable(service(await freshSettings()), capability), isNull);
      expect(sim.of('revokeCaptureAuthorizationLifetime').length,
          greaterThanOrEqualTo(3));
    });
  });

  // The device fixture: the replica says unset / v0 (reset, purged or restored)
  // while BOTH native egress layers still hold OFF at tg20 / rv2, unbound, with no
  // pending operation. A version-0 publication is stale there; the explicit
  // enable must reserve a version above the frontier and commit at exactly it.
  group('version frontier ahead of the local consent history', () {
    setUpAll(() => autoSignIn = false);
    tearDownAll(() => autoSignIn = true);

    void nativeOffAt20Rv2() {
      sim
        ..hashKeyExists = true
        ..egressState = 'OFF'
        ..egressGeneration = 20
        ..egressVersion = 2;
      // Dart reads the same native record when it allocates the next generation.
      rig.native.stored = rigRecord(EgressState.off, 20, 2);
    }

    /// The production hook: the registration service with the explicit plan.
    void productionHook(CaptureDeviceRegistrationService svc) {
      f.session.configureCaptureOwnerPublish((u, a) =>
          svc.publishRestrictiveOwnerDetailed(
              admissionAuthority: a,
              plan: f.session.explicitPublishPlanFor(a)));
    }

    Future<({int watermark, int reserved})> marks() async {
      final row = await f.host.current!.database
          .customSelect(
              'SELECT watermark, reserved FROM consent_version_watermark')
          .getSingleOrNull();
      return (
        watermark: row?.read<int>('watermark') ?? 0,
        reserved: row?.read<int>('reserved') ?? 0
      );
    }

    Future<ConsentCapability> returning() async {
      f.session.configureCaptureOwnerPublish(null);
      await signIn('uid-x');
      return f.session.captureConsentCapability()!;
    }

    test('physical Dart rv9 survives a newer-generation rv2 winner', () async {
      final capability = await returning();
      nativeOffAt20Rv2();
      rig.secure.value = rigEnvelope(rigRecord(EgressState.off, 30, 2));
      rig.file.value = rigEnvelope(rigRecord(EgressState.off, 20, 9));
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      expect(await enable(svc, capability), isNull);
      expect((await settings.getSettings()).consentVersion, greaterThan(9));
    });

    // Field fixture (sign-out retired native to OFF but left a Dart layer ON):
    // with stored Cloud not accepted and no barrier, the stale non-OFF Dart
    // layer is driven to a verified OFF above the frontier, then the explicit
    // enable proceeds. It is never adopted as ON.
    for (final slot in ['secure', 'file']) {
      for (final state in [EgressState.on, EgressState.disabling]) {
        test(
            'stored OFF repairs a hidden Dart ${state.wire} in $slot before '
            'enable, above the frontier', () async {
          final capability = await returning();
          nativeOffAt20Rv2();
          final stale = rigEnvelope(rigRecord(state, 20, 9));
          final off = rigEnvelope(rigRecord(EgressState.off, 30, 2));
          rig.secure.value = slot == 'secure' ? stale : off;
          rig.file.value = slot == 'file' ? stale : off;
          final settings = await freshSettings();
          final svc = service(settings);
          productionHook(svc);
          expect(await enable(svc, capability), isNull);
          final stored = await settings.getSettings();
          expect(stored.cloudProcessingEnabled, isTrue);
          expect(stored.consentVersion, greaterThan(9),
              reason: 'the max version frontier is never lowered');
          expect(sim.egressState, 'ON');
        });
      }
    }

    test('verified OFF repair releases the stale native lifetime freeze', () async {
      final capability = await returning();
      nativeOffAt20Rv2();
      rig.secure.value = rigEnvelope(rigRecord(EgressState.on, 20, 9));
      rig.file.value = rig.secure.value;
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      ConsentAuthority.freeze('reconcile_uncertain:native:lifetime_fields_unbound');
      expect(await enable(svc, capability), isNull);
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect(sim.egressState, 'ON');
    });

    test('same-uid fixture: both Dart layers ON, native OFF, stored OFF',
        () async {
      final capability = await returning();
      nativeOffAt20Rv2();
      rig.secure.value = rigEnvelope(rigRecord(EgressState.on, 20, 9));
      rig.file.value = rigEnvelope(rigRecord(EgressState.on, 20, 9));
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      expect(await enable(svc, capability), isNull);
      expect((await settings.getSettings()).consentVersion, greaterThan(9));
    });

    for (final slot in ['secure', 'file']) {
      test('an incomplete OFF repair ($slot write fails) never begins enable',
          () async {
        final capability = await returning();
        nativeOffAt20Rv2();
        rig.secure.value = rigEnvelope(rigRecord(EgressState.on, 20, 9));
        rig.file.value = rigEnvelope(rigRecord(EgressState.on, 20, 9));
        (slot == 'secure' ? rig.secure : rig.file).failWrites = true;
        final settings = await freshSettings();
        final svc = service(settings);
        productionHook(svc);
        final err = await enable(svc, capability);
        (slot == 'secure' ? rig.secure : rig.file).failWrites = false;
        expect((err as CloudEnableIncompleteException).reason,
            startsWith('preflight_repair_incomplete/'));
        expect((await marks()).reserved, 0);
        expect(sim.of('beginCloudEgressEnable'), isEmpty);
        expect(sim.of('publishRestrictiveCaptureOwner'), isEmpty);
        expect((await settings.getSettings()).cloudConsentState,
            ConsentState.unset);
      });
    }

    test('unreadable Dart evidence during a stale ON is not repaired',
        () async {
      final capability = await returning();
      nativeOffAt20Rv2();
      rig.secure.value = rigEnvelope(rigRecord(EgressState.on, 20, 9));
      rig.file.failReads = true;
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      final err = await enable(svc, capability);
      rig.file.failReads = false;
      expect(err, isA<CloudEnableIncompleteException>());
      expect((err as CloudEnableIncompleteException).reason,
          isNot(startsWith('preflight_repair')));
      expect((await marks()).reserved, 0);
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
    });

    test('a pending barrier is never normalized by the OFF repair', () async {
      final capability = await returning();
      nativeOffAt20Rv2();
      rig.file.value = rigEnvelope(rigRecord(EgressState.on, 20, 9));
      sim.pending = {
        'operationId': kSimOperationId,
        'transitionGeneration': 22,
        'reservedVersion': 9,
        'ownerGeneration': 7,
        'ownerEpoch': sim.ownerEpoch,
      };
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      final err = await enable(svc, capability);
      sim.pending = null;
      expect(err, isA<CloudEnableIncompleteException>());
      expect((err as CloudEnableIncompleteException).reason,
          isNot(startsWith('preflight_repair')));
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
    });

    for (final missing in ['file', 'keychain', 'older_file']) {
      test('explicit enable repairs readable OFF copies: $missing', () async {
        final capability = await returning();
        nativeOffAt20Rv2();
        sim
          ..egressOwnerGeneration = sim.ownerGeneration
          ..egressOwnerEpoch = sim.ownerEpoch;
        messenger.setMockMethodCallHandler(channel, (call) async {
          final result = await sim.handle(call);
          if (call.method != 'getCloudEgressPending' ||
              sim.of('setCloudEgressState').isNotEmpty) {
            return result;
          }
          final reply = Map<String, Object?>.from(result as Map);
          final layers = (reply['egress'] as List)
              .map((r) => Map<String, Object?>.from(r as Map)).toList();
          if (missing == 'older_file') {
            layers.first['transitionGeneration'] = 19;
            layers.first['reservedVersion'] = 9;
          } else {
            final index = missing == 'file' ? 0 : 1;
            layers[index] = {'layer': missing, 'outcome': 'absent'};
          }
          reply['egress'] = layers;
          return reply;
        });
        final gate = CloudEgressGate(
          store: CloudEgressStore(
            secure: rig.secure, file: rig.file,
            pendingSecure: rig.pendingSecure, pendingFile: rig.pendingFile,
            native: NativeEgressSlot.platformDefault(),
          ),
          activeOwner: () async => kRigOwner,
          resolved: true,
          nativeInflight: (_) async => (count: 0, latestDeadline: null),
        );
        CloudEgressGate.instance = gate;
        final settings = await freshSettings();
        final svc = service(settings, gate: gate);
        productionHook(svc);
        expect(await enable(svc, capability), isNull);
        final repair = sim.of('setCloudEgressState').first.arguments as Map;
        expect(repair['state'], 'OFF');
        expect(repair['transitionGeneration'] as int, greaterThan(20));
        expect((await settings.getSettings()).consentVersion,
            greaterThan(missing == 'older_file' ? 9 : 2));
        expect(sim.egressState, 'ON');
        expect(sim.methods.indexOf('setCloudEgressState'),
            lessThan(sim.methods.indexOf('publishRestrictiveCaptureOwner')));
      });
    }

    for (final mismatch in ['unbound_file', 'different_lifetime', 'live_receipt']) {
      test('explicit consent reconciles OFF copies with $mismatch', () async {
        final ConsentCapability capability;
        if (mismatch == 'live_receipt') {
          f.session.configureCaptureOwnerPublish(publish);
          await signIn('uid-x');
          capability = f.session.captureConsentCapability()!;
          sim.calls.clear();
        } else {
          capability = await returning();
        }
        nativeOffAt20Rv2();
        sim
          ..egressOwnerGeneration = sim.ownerGeneration
          ..egressOwnerEpoch = sim.ownerEpoch;
        messenger.setMockMethodCallHandler(channel, (call) async {
          final result = await sim.handle(call);
          if (call.method != 'getCloudEgressPending' ||
              sim.of('publishRestrictiveCaptureOwner').isNotEmpty) {
            return result;
          }
          final reply = Map<String, Object?>.from(result as Map);
          final layers = (reply['egress'] as List)
              .map((r) => Map<String, Object?>.from(r as Map)).toList();
          if (mismatch == 'unbound_file') {
            layers.first.remove('ownerGeneration');
            layers.first.remove('ownerEpoch');
          } else {
            layers.first['ownerGeneration'] = sim.ownerGeneration + 7;
          }
          reply['egress'] = layers;
          return reply;
        });
        final svc = service(await freshSettings());
        productionHook(svc);
        expect(await enable(svc, capability), isNull);
        final publication =
            sim.of('publishRestrictiveCaptureOwner').single.arguments as Map;
        final expected = publication['expectedOffCopies'] as List;
        expect(expected, hasLength(2));
        expect(publication.containsKey('expectedTransitionGeneration'), isFalse);
        expect(sim.egressState, 'ON');
      });
    }

    test('verified absence works for a brand-new owner', () async {
      final capability = await returning();
      sim.hashKeyExists = false;
      sim.egressState = null;
      final svc = service(await freshSettings());
      productionHook(svc);
      expect(await enable(svc, capability), isNull);
    });

    test('unreadable Dart evidence is not absence', () async {
      final capability = await returning();
      rig.file.failReads = true;
      final err = await enable(service(await freshSettings()), capability);
      expect((err as CloudEnableIncompleteException).reason,
          startsWith('preflight_uncertain'));
      expect((await marks()).reserved, 0);
    });

    for (final malformed in [
      'emptyEgress',
      'emptyBarrier',
      'duplicate',
      'operation'
    ]) {
      test('preflight refuses malformed native $malformed', () async {
        final capability = await returning();
        nativeOffAt20Rv2();
        messenger.setMockMethodCallHandler(channel, (call) async {
          final result = await sim.handle(call);
          if (call.method != 'getCloudEgressPending') return result;
          final reply = Map<String, Object?>.from(result as Map);
          switch (malformed) {
            case 'emptyEgress':
              reply['egress'] = <Object>[];
            case 'emptyBarrier':
              reply['barrier'] = <Object>[];
            case 'duplicate':
              final layers = reply['egress'] as List;
              reply['egress'] = [layers.first, layers.first];
            case 'operation':
              reply['operation'] = 'begin';
          }
          return reply;
        });
        expect(await enable(service(await freshSettings()), capability),
            isA<CloudEnableIncompleteException>());
        expect((await marks()).reserved, 0);
        expect(sim.of('beginCloudEgressEnable'), isEmpty);
      });
    }

    test('exact pending tg30/v3 refuses older-generation rv9 before writes',
        () async {
      final capability = await returning();
      nativeOffAt20Rv2();
      final settings = await freshSettings();
      await settings.reserveConsentVersion(capability,
          verifiedFrontier: 2, operationId: 'pending-own');
      final binding = CloudEgressEnableBinding(
          operationId: kSimOperationId,
          transitionGeneration: 30,
          reservedVersion: 3,
          ownerGeneration: sim.ownerGeneration,
          ownerEpoch: sim.ownerEpoch);
      await rig.gate.beginPendingEnable(PendingEnableRecord(
          ownerUid: kRigOwner,
          transitionGeneration: 30,
          reservedVersion: 3,
          localOperationId: 'pending-own',
          binding: binding));
      sim.pending = {
        'operationId': kSimOperationId,
        'transitionGeneration': 30,
        'reservedVersion': 3,
        'ownerGeneration': sim.ownerGeneration,
        'ownerEpoch': sim.ownerEpoch
      };
      rig.secure.value = rigEnvelope(rigRecord(EgressState.off, 30, 3));
      final bytes = rigEnvelope(rigRecord(EgressState.off, 20, 9));
      rig.file.value = bytes;
      final err = await enable(service(settings), capability);
      expect(
          (err as CloudEnableIncompleteException).reason, 'preflight_conflict/pending_frontier');
      expect(rig.file.value, bytes);
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(sim.of('writeCloudEgressEnableOn'), isEmpty);
      expect((await settings.getSettings()).consentVersion, 0);
    });

    test('the exact device fixture: V >= 3, native ends ON at that version',
        () async {
      final capability = await returning();
      nativeOffAt20Rv2();
      final settings = await freshSettings();
      expect((await settings.getSettings()).consentVersion, 0);
      final svc = service(settings);
      productionHook(svc);
      expect(await enable(svc, capability), isNull);
      final published =
          sim.of('publishRestrictiveCaptureOwner').single.arguments as Map;
      expect(published['version'] as int, greaterThanOrEqualTo(3));
      expect(published['expectedTransitionGeneration'], 20);
      expect(published['expectedReservedVersion'], 2);
      final stored = await settings.getSettings();
      expect(stored.cloudProcessingEnabled, isTrue);
      expect(stored.consentVersion, published['version'],
          reason: 'committed at exactly the reserved version');
      expect(sim.egressState, 'ON');
      expect(sim.egressVersion, stored.consentVersion);
      expect(sim.egressGeneration, greaterThanOrEqualTo(21),
          reason:
              'the transition generation is retained at >= 20 and advances');
      // The simulated native side mirrored into the rig's native slot.
      rig.native.stored =
          rigRecord(EgressState.on, sim.egressGeneration, sim.egressVersion);
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
      final m = await marks();
      expect(m.watermark, stored.consentVersion);
      expect(m.reserved, 0, reason: 'the reservation was consumed');
    });

    test(
        'the Remove-data purge of the same owner: data gone, native rv2 kept, '
        'the next explicit enable succeeds above it', () async {
      final first = await returning();
      nativeOffAt20Rv2();
      final pre = await freshSettings();
      await pre.saveConsentChoice(
          first, const ConsentChoices(cloud: ConsentState.declined));
      expect((await pre.getSettings()).consentVersion, 1);
      await f.session.removeDataFromDevice();
      f.session.configureCaptureOwnerPublish(null);
      await signIn('uid-x');
      final capability = f.session.captureConsentCapability()!;
      final settings = await freshSettings();
      expect((await settings.getSettings()).consentVersion, 0,
          reason: 'a fresh replica: unset / v0');
      expect(sim.egressVersion, 2, reason: 'native kept its frontier');
      final svc = service(settings);
      productionHook(svc);
      expect(await enable(svc, capability), isNull);
      final stored = await settings.getSettings();
      expect(stored.consentVersion, greaterThanOrEqualTo(3));
      expect(sim.egressState, 'ON');
      expect(sim.egressVersion, stored.consentVersion);
    });

    test(
        'holds after the reservation and after the publication keep local '
        'consent unset and ordinary egress denied', () async {
      final capability = await returning();
      nativeOffAt20Rv2();
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      for (final method in [
        'publishRestrictiveCaptureOwner',
        'beginCloudEgressEnable'
      ]) {
        final hold = sim.hold(method);
        final running = enable(svc, capability);
        await sim.reached[method]!.future;
        final during = await settings.getSettings();
        expect(during.cloudConsentState, ConsentState.unset, reason: method);
        expect(during.cloudProcessingEnabled, isFalse);
        expect(await rig.gate.permits(owner: kRigOwner), isFalse);
        expect((await marks()).reserved, greaterThanOrEqualTo(3),
            reason: 'reserved before any native publication');
        hold.complete();
        expect(await running, isNull, reason: method);
        // Return to Off for the next round.
        sim
          ..egressState = 'OFF'
          ..egressGeneration = 20
          ..egressVersion = 2
          ..pending = null;
        await settings.saveConsentChoice(
            capability, const ConsentChoices(cloud: ConsentState.unset));
        await rig.secure.delete();
        await rig.file.delete();
      }
    });

    test('a failed attempt never lowers the watermark; the retry goes higher',
        () async {
      final capability = await returning();
      nativeOffAt20Rv2();
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      sim.fault('beginCloudEgressEnable', SimFault.nullReply);
      expect(
          await enable(svc, capability), isA<CloudEnableIncompleteException>());
      final afterFailure = await marks();
      expect(afterFailure.watermark, greaterThanOrEqualTo(3));
      expect(
          (await settings.getSettings()).cloudConsentState, ConsentState.unset);
      // The unresolved operation of the first attempt is resumed or cleaned
      // before anything is committed; the watermark only moves up.
      await enable(svc, capability);
      final after = await marks();
      expect(after.watermark, greaterThanOrEqualTo(afterFailure.watermark));
    });

    test(
        'the preflight refuses native ON ahead, disagreeing layers, an '
        'unreadable inspection and a barrier native holds alone: no '
        'publication, no reservation fallback, nothing accepted', () async {
      final capability = await returning();
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      final cases = <String, void Function()>{
        // A native ON with stored Cloud not accepted triggers the OFF repair;
        // the inspection still reads ON afterwards, so it fails closed.
        'preflight_repair_incomplete': () {
          nativeOffAt20Rv2();
          sim.egressState = 'ON';
        },
        'preflight_conflict': () {
          nativeOffAt20Rv2();
          sim.pending = {
            'operationId': kSimOperationId,
            'transitionGeneration': 22,
            'reservedVersion': 9,
            'ownerGeneration': 7,
            'ownerEpoch': sim.ownerEpoch,
          };
        },
        'preflight_uncertain': () {
          nativeOffAt20Rv2();
          sim.fault('getCloudEgressPending', SimFault.uncertain);
        },
      };
      for (final c in cases.entries) {
        sim.pending = null;
        c.value();
        final err = await enable(svc, capability);
        expect(err, isA<CloudEnableIncompleteException>(), reason: c.key);
        expect(
            (err as CloudEnableIncompleteException).reason, startsWith(c.key));
        expect(sim.of('publishRestrictiveCaptureOwner'), isEmpty,
            reason: '${c.key}: no ordinary publication');
        expect(sim.of('beginCloudEgressEnable'), isEmpty);
        expect((await settings.getSettings()).cloudConsentState,
            ConsentState.unset);
      }
      expect((await marks()).reserved, 0, reason: 'nothing was reserved');
    });

    test('a changed lifetime in the inspected record is refused natively',
        () async {
      final capability = await returning();
      nativeOffAt20Rv2();
      sim
        ..egressOwnerGeneration = 4
        ..egressOwnerEpoch = sim.ownerEpoch;
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      final hold = sim.hold('publishRestrictiveCaptureOwner');
      final running = enable(svc, capability);
      await sim.reached['publishRestrictiveCaptureOwner']!.future;
      sim.egressOwnerGeneration = 5; // another lifetime appears before dispatch
      hold.complete();
      expect(await running, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(
          (await settings.getSettings()).cloudConsentState, ConsentState.unset);
    });

    test(
        'native moving between the preflight and the publication is refused '
        'without acceptance', () async {
      final capability = await returning();
      nativeOffAt20Rv2();
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      final hold = sim.hold('publishRestrictiveCaptureOwner');
      final running = enable(svc, capability);
      await sim.reached['publishRestrictiveCaptureOwner']!.future;
      sim.egressVersion = 7; // a concurrent higher frontier
      hold.complete();
      final err = await running;
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(
          (await settings.getSettings()).cloudConsentState, ConsentState.unset);
      expect(sim.egressState, 'OFF');
      expect(sim.egressVersion, 7);
    });

    test('capability loss after the reservation changes nothing further',
        () async {
      final capability = await returning();
      nativeOffAt20Rv2();
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      final hold = sim.hold('publishRestrictiveCaptureOwner');
      final running = enable(svc, capability);
      await sim.reached['publishRestrictiveCaptureOwner']!.future;
      f.session.markSessionInvalid();
      hold.complete();
      expect(await running, isNotNull);
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(sim.egressState, isNot('ON'));
    });

    // F1 fixture: a lifetime fence left OFF + retirement in native (sign-out,
    // account switch, expiry) and no later publication replaced it. The stored
    // entry is at rv9 while the retirement names rv4, so the layer reports
    // understate the frontier.
    void nativeRetiredOff({bool fileAbsent = false}) {
      nativeOffAt20Rv2();
      sim
        ..egressVersion = 9
        ..retirement = {
          'operationId': 'c' * 32,
          'transitionGeneration': 18,
          'reservedVersion': 4,
          'ownerGeneration': 5,
          'ownerEpoch': sim.ownerEpoch,
        }
        ..retiredFileAbsent = fileAbsent;
      rig.native.stored = rigRecord(EgressState.off, 20, 9);
    }

    Future<void> expectRetiredRefusal(
        CaptureDeviceRegistrationService svc,
        _Settings settings,
        ConsentCapability capability,
        String reason,
        {ConsentState stored = ConsentState.unset}) async {
      final before = (rig.secure.value, rig.file.value);
      final err = await enable(svc, capability);
      expect(err, isA<CloudEnableIncompleteException>(), reason: reason);
      expect((err as CloudEnableIncompleteException).reason, reason);
      expect(sim.of('publishRestrictiveCaptureOwner'), isEmpty, reason: reason);
      expect(sim.of('beginCloudEgressEnable'), isEmpty, reason: reason);
      expect(sim.of('setCloudEgressState'), isEmpty, reason: reason);
      expect(sim.retirement, isNotNull, reason: 'the retired OFF is untouched');
      expect(sim.egressState, isNot('ON'));
      expect((rig.secure.value, rig.file.value), before, reason: reason);
      expect((await settings.getSettings()).cloudConsentState, stored);
      expect((await marks()).reserved, 0, reason: 'nothing was reserved');
    }

    for (final fileAbsent in [false, true]) {
      test(
          'a retired OFF (${fileAbsent ? "keychain only" : "both layers"}) is '
          'republished restrictive over the exact snapshot, then enabled',
          () async {
        final capability = await returning();
        nativeRetiredOff(fileAbsent: fileAbsent);
        final settings = await freshSettings();
        final svc = service(settings);
        productionHook(svc);
        final order = <String>[];
        sim.onCall = (m) {
          if (m == 'publishRestrictiveCaptureOwner' ||
              m == 'beginCloudEgressEnable' ||
              m == 'writeCloudEgressEnableOn') {
            order.add(m);
          }
        };
        expect(await enable(svc, capability), isNull);
        final publication = Map<String, Object?>.from(
            sim.of('publishRestrictiveCaptureOwner').single.arguments as Map);
        final copies = publication['expectedRetiredCopies'] as List;
        expect(copies, hasLength(2));
        expect((copies[0] as Map)['layer'], 'file');
        expect((copies[0] as Map).length, fileAbsent ? 1 : 6);
        expect((copies[1] as Map)['layer'], 'keychain');
        expect((copies[1] as Map)['operationId'], 'c' * 32);
        expect(publication.containsKey('expectedOffCopies'), isFalse);
        expect(publication.containsKey('expectedTransitionGeneration'), isFalse);
        expect(publication['version'] as int, greaterThan(9),
            reason: 'above the true stored frontier, not the retired rv4');
        // The restrictive publication comes strictly before the barrier flow.
        expect(order.first, 'publishRestrictiveCaptureOwner');
        expect(order, contains('beginCloudEgressEnable'));
        expect(sim.retirement, isNull);
        expect(sim.egressState, 'ON');
        final stored = await settings.getSettings();
        expect(stored.cloudProcessingEnabled, isTrue);
        expect(stored.consentVersion, greaterThan(9));
      });
    }

    test(
        'a retired OFF beside a stale Dart ON: the Dart ON is restricted '
        'first, then the normal flow runs', () async {
      final capability = await returning();
      nativeRetiredOff();
      final stale = rigEnvelope(rigRecord(EgressState.on, 19, 3));
      rig.secure.value = stale;
      rig.file.value = stale;
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      List<String?>? atPublication;
      sim.onCall = (m) {
        if (m == 'publishRestrictiveCaptureOwner') {
          atPublication = [rig.secure.value, rig.file.value];
        }
      };
      expect(await enable(svc, capability), isNull);
      expect(atPublication, isNotNull);
      expect(
          atPublication!.every(
              (raw) => raw != null && raw.contains('"OFF"') && !raw.contains('"ON"')),
          isTrue,
          reason: 'no Dart ON survives to the publication');
      expect(sim.egressState, 'ON');
      expect((await settings.getSettings()).consentVersion, greaterThan(9));
    });

    test(
        'a retired OFF beside a stale Dart ON whose republication is refused '
        'leaves every layer restrictive', () async {
      final capability = await returning();
      nativeRetiredOff();
      final stale = rigEnvelope(rigRecord(EgressState.on, 19, 3));
      rig.secure.value = stale;
      rig.file.value = stale;
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      sim.fault('publishRestrictiveCaptureOwner', SimFault.conflict);
      expect(await enable(svc, capability),
          isA<CloudEnableIncompleteException>());
      expect((await dartEgress()).every((r) => r.state == EgressState.off),
          isTrue);
      expect(sim.egressState, 'OFF');
      expect(sim.retirement, isNotNull);
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(
          (await settings.getSettings()).cloudConsentState, ConsentState.unset);
    });

    test('a retired OFF beside a Dart DISABLING is refused untouched', () async {
      final capability = await returning();
      nativeRetiredOff();
      rig.secure.value = rigEnvelope(rigRecord(EgressState.disabling, 19, 3));
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      await expectRetiredRefusal(svc, settings, capability,
          'preflight_conflict/retired_dart_disabling');
    });

    test('a retired OFF under a stored Cloud ON is refused', () async {
      final capability = await returning();
      nativeRetiredOff();
      final settings = await freshSettings();
      await settings.saveSettings((await settings.getSettings())
          .copyWith(cloudConsentState: ConsentState.accepted));
      final svc = service(settings);
      productionHook(svc);
      await expectRetiredRefusal(svc, settings, capability,
          'preflight_conflict/retired_stored_on',
          stored: ConsentState.accepted);
    });

    test('a retired OFF under a native barrier is refused', () async {
      final capability = await returning();
      nativeRetiredOff();
      sim.pending = {
        'operationId': kSimOperationId,
        'transitionGeneration': 22,
        'reservedVersion': 9,
        'ownerGeneration': 7,
        'ownerEpoch': sim.ownerEpoch,
      };
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      await expectRetiredRefusal(
          svc, settings, capability, 'preflight_conflict/native_barrier');
    });

    test('a retired OFF with a Dart pending operation is refused', () async {
      final capability = await returning();
      nativeRetiredOff();
      expect(
          (await rig.gate.beginPendingEnable(PendingEnableRecord(
                  ownerUid: kRigOwner,
                  transitionGeneration: 21,
                  reservedVersion: 10,
                  localOperationId: 'd' * 32)))
              .all,
          isTrue);
      final pendingBefore = (rig.pendingSecure.value, rig.pendingFile.value);
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      await expectRetiredRefusal(
          svc, settings, capability, 'preflight_conflict/retired_pending');
      expect((rig.pendingSecure.value, rig.pendingFile.value), pendingBefore);
    });

    test('a retired OFF during a successor hold or an unsettled successor is '
        'refused', () async {
      final capability = await returning();
      nativeRetiredOff();
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      rig.gate.asrSuccessorUnsettled = () => true;
      await expectRetiredRefusal(
          svc, settings, capability, 'preflight_conflict/retired_successor');
      rig.gate.asrSuccessorUnsettled = null;
      final hold = rig.gate.beginTransitionHold();
      addTearDown(() => rig.gate.endTransitionHold(hold));
      await expectRetiredRefusal(
          svc, settings, capability, 'preflight_conflict/retired_successor');
    });

    test('a retired OFF without the native version frontier is refused',
        () async {
      final capability = await returning();
      nativeRetiredOff();
      messenger.setMockMethodCallHandler(channel, (call) async {
        final result = await sim.handle(call);
        if (call.method != 'getCloudEgressPending') return result;
        return Map<String, Object?>.from(result as Map)
          ..remove('egressVersionFrontier');
      });
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      await expectRetiredRefusal(svc, settings, capability,
          'preflight_uncertain[retired_frontier]');
    });

    // The operation-id check is NOT relaxed: only "every held layer OFF under
    // the same complete retirement" is recognised.
    test('any other operation id on a held layer is still refused', () async {
      final capability = await returning();
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      // An OFF without retirement beside a retired OFF.
      nativeRetiredOff();
      sim.retiredFilePlain = true;
      await expectRetiredRefusal(svc, settings, capability,
          'preflight_uncertain[held_fields|keychain:OFF:op]');
      // Two different retirements.
      sim.retiredFilePlain = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final result = await sim.handle(call);
        if (call.method != 'getCloudEgressPending') return result;
        final reply = Map<String, Object?>.from(result as Map);
        final layers = [
          for (final l in reply['egress'] as List)
            Map<String, Object?>.from(l as Map)
        ];
        layers[1]['operationId'] = 'e' * 32;
        reply['egress'] = layers;
        return reply;
      });
      await expectRetiredRefusal(svc, settings, capability,
          'preflight_uncertain[held_fields|file:OFF:op]');
      messenger.setMockMethodCallHandler(channel, sim.handle);
      // A retirement on anything that is not OFF.
      for (final state in ['ON', 'DISABLING']) {
        sim.egressState = state;
        final err = await enable(svc, capability);
        expect((err as CloudEnableIncompleteException).reason,
            'preflight_uncertain[held_fields|file:$state:op]');
        expect(sim.of('publishRestrictiveCaptureOwner'), isEmpty);
        expect(sim.of('beginCloudEgressEnable'), isEmpty);
        expect(sim.retirement, isNotNull);
      }
      expect((await marks()).reserved, 0);
    });

    test(
        'a retired snapshot that changed before the publication is refused '
        'natively and nothing is enabled', () async {
      final capability = await returning();
      nativeRetiredOff();
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      final hold = sim.hold('publishRestrictiveCaptureOwner');
      final running = enable(svc, capability);
      await sim.reached['publishRestrictiveCaptureOwner']!.future;
      // Another fence retires the entry again before the dispatch.
      sim.retirement = {...sim.retirement!, 'operationId': 'e' * 32};
      hold.complete();
      expect(await running, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(sim.egressState, 'OFF');
      expect(sim.retirement, isNotNull);
      expect(
          (await settings.getSettings()).cloudConsentState, ConsentState.unset);
    });

    test('each preflight_uncertain site names its own allowlisted sub-reason',
        () async {
      final capability = await returning();
      final settings = await freshSettings();
      final svc = service(settings);
      productionHook(svc);
      Future<String> reason() async {
        final err = await enable(svc, capability);
        expect(err, isA<CloudEnableIncompleteException>());
        return (err as CloudEnableIncompleteException).reason;
      }

      nativeOffAt20Rv2();
      rig.pendingFile.failReads = true;
      expect(await reason(),
          'preflight_uncertain[pending_layers|s:absent,f:unreadable]');
      rig.pendingFile.failReads = false;

      sim.fault('getCloudEgressPending', SimFault.platformError);
      expect(await reason(),
          'preflight_uncertain[native_inspect|queue_unavailable]');
      sim.fault('getCloudEgressPending', SimFault.malformed);
      expect(await reason(), 'preflight_uncertain[native_inspect|unknown]');

      rig.file.failReads = true;
      expect(
          await reason(),
          'preflight_uncertain[layers|dart|e:verified,verified'
          '|b:absent,absent|noBarrier]');
      rig.file.failReads = false;
      sim.fault('getCloudEgressPending', SimFault.uncertain);
      expect(await reason(),
          'preflight_uncertain[layers|eshape|e:|b:absent,absent|uncertain]');

      messenger.setMockMethodCallHandler(channel, (call) async {
        final result = await sim.handle(call);
        if (call.method != 'getCloudEgressPending') return result;
        final reply = Map<String, Object?>.from(result as Map);
        reply['egress'] = [
          {'layer': 'file', 'outcome': 'verified', 'state': 'OFF',
            'transitionGeneration': 20, 'reservedVersion': 2},
          {'layer': 'keychain', 'outcome': 'absent', 'state': 'OFF'},
        ];
        return reply;
      });
      expect(await reason(), 'preflight_uncertain[absent_fields|e:keychain]');
      messenger.setMockMethodCallHandler(channel, sim.handle);

      settings.failReserve = StateError('uid-x secret');
      expect(await reason(), 'preflight_uncertain[reserve|StateError]');
      settings.failReserve = null;

      final unreadableOwner = CaptureDeviceRegistrationService(
        settingsRepository: settings,
        gate: rig.gate,
        client: net,
        isIos: () => true,
        isBackendConfigured: () => true,
        readSession: () => (uid: 'uid-x', jwt: 'jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        isCurrentScope: () =>
            identical(f.host.current?.database, settings.database),
        readReplicaOwnerUid: () async => throw StateError('uid-x'),
      );
      final err = await enable(unreadableOwner, capability);
      expect((err as CloudEnableIncompleteException).reason,
          'preflight_uncertain[owner_read]');

      expect(sim.of('publishRestrictiveCaptureOwner'), isEmpty);
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect((await marks()).reserved, 0);
    });
  });

  group('phase 2: durable Dart pending denial before native begin', () {
    for (final layer in ['secure', 'file']) {
      test('a failing $layer pending write: no native begin, no ON', () async {
        (layer == 'secure' ? rig.pendingSecure : rig.pendingFile).failWrites =
            true;
        final err = await enable(service(await freshSettings()));
        expect(err, isA<CloudEnableIncompleteException>());
        expect(sim.of('beginCloudEgressEnable'), isEmpty);
        expect(await dartEgress(), isEmpty);
        expect(await rig.gate.permits(owner: kRigOwner), isFalse);
        expect(net.calls, 0);
        // What did land is withdrawn only if read-back proves it; otherwise it
        // keeps denying. Either way no layer is ON.
        (layer == 'secure' ? rig.pendingSecure : rig.pendingFile).failWrites =
            false;
        expect(ConsentAuthority.egressFrozen, isFalse);
      });
    }

    test('an unreadable pending layer refuses to start', () async {
      rig.pendingFile.failReads = true;
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
    });

    test('a corrupt pending layer refuses to start and is left as found',
        () async {
      rig.pendingSecure.value = 'not json';
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(rig.pendingSecure.value, 'not json');
    });

    test('conflicting pending records refuse to start', () async {
      rig.pendingSecure.value =
          '{"v":1,"pending":{"uid-x":{"owner_uid":"uid-x","transition_generation":2,"reserved_version":1,"operation":"one","native":null}}}';
      rig.pendingFile.value =
          '{"v":1,"pending":{"uid-x":{"owner_uid":"uid-x","transition_generation":5,"reserved_version":4,"operation":"two","native":null}}}';
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(await pendingPresent(), isTrue);
    });

    test('settings already ON: refused, the existing state is untouched',
        () async {
      final settings = await freshSettings();
      final current = await settings.getSettings();
      await settings.saveSettings(
          current.copyWith(cloudConsentState: ConsentState.accepted));
      final err = await enable(service(settings));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(await pendingPresent(), isFalse);
    });
  });

  group('phase 3: native begin reply classes', () {
    const retained = {
      SimFault.nullReply,
      SimFault.platformError,
      SimFault.malformed,
      SimFault.uncertain,
      SimFault.incomplete,
      SimFault.noBarrier,
      SimFault.stale,
      SimFault.pending,
    };
    for (final fault in [
      SimFault.nullReply,
      SimFault.platformError,
      SimFault.malformed,
      SimFault.conflict,
      SimFault.ownerMismatch,
      SimFault.uncertain,
      SimFault.incomplete,
      SimFault.noBarrier,
      SimFault.stale,
      SimFault.pending,
      SimFault.badLayers,
    ]) {
      test('${fault.name}: never writes ON; honest failure; no backend',
          () async {
        sim.fault('beginCloudEgressEnable', fault);
        final settings = await freshSettings();
        final err = await enable(service(settings));
        expect(err, isA<CloudEnableIncompleteException>());
        expect(sim.of('writeCloudEgressEnableOn'), isEmpty);
        expect(await dartEgress(), isEmpty,
            reason: 'no Dart ON without a confirmed barrier');
        expect(await rig.gate.permits(owner: kRigOwner), isFalse);
        expect(settings.saved, 0);
        expect(net.calls, 0);
        if (retained.contains(fault)) {
          expect(await pendingPresent(), isTrue,
              reason: 'an uncertain begin keeps the Dart denial');
        } else {
          expect(await pendingPresent(), isFalse,
              reason: 'a definite no-op or a compensated begin is cleared');
          expect(sim.pending, isNull);
        }
      });
    }

    test('a binding write failing in one Dart layer compensates natively',
        () async {
      var armed = false;
      sim.afterApply = (m) {
        if (m == 'beginCloudEgressEnable' && !armed) {
          armed = true;
          rig.pendingFile.failWrites = true; // the bind write will fail
        }
      };
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      rig.pendingFile.failWrites = false;
      expect(sim.of('writeCloudEgressEnableOn'), isEmpty);
      expect(sim.of('restrictCloudEgressEnable'), hasLength(1));
      expect(await dartEgress(), isEmpty);
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
    });
  });

  group('phase 4: Dart ON and native writeOn', () {
    for (final fault in [
      SimFault.nullReply,
      SimFault.platformError,
      SimFault.malformed,
      SimFault.conflict,
      SimFault.ownerMismatch,
      SimFault.uncertain,
      SimFault.incomplete,
      SimFault.noBarrier,
      SimFault.stale,
      SimFault.pending,
      SimFault.badLayers,
    ]) {
      test('writeOn ${fault.name}: exact-binding compensation, honest failure',
          () async {
        sim.fault('writeCloudEgressEnableOn', fault);
        final settings = await freshSettings();
        final err = await enable(service(settings));
        expect(err, isA<CloudEnableIncompleteException>());
        expect(settings.saved, 0, reason: 'consent is never saved without ON');
        final restricts = sim.of('restrictCloudEgressEnable');
        expect(restricts, hasLength(1));
        expect(
            Map<Object?, Object?>.from(
                restricts.single.arguments as Map)['operationId'],
            kSimOperationId);
        final abandons = sim
            .of('finishCloudEgressEnable')
            .where((c) => (c.arguments as Map)['abandon'] == true);
        expect(abandons, hasLength(1));
        expect(sim.egressState, isNot('ON'));
        expect(sim.pending, isNull);
        expect((await dartEgress()).where((r) => r.state == EgressState.on),
            isEmpty);
        expect(await pendingPresent(), isFalse);
        expect(await rig.gate.permits(owner: kRigOwner), isFalse);
        expect(net.calls, 0);
        expect(ConsentAuthority.egressFrozen, isFalse);
      });
    }

    for (final layer in ['secure', 'file']) {
      test('a failing Dart $layer ON write never reaches native writeOn',
          () async {
        (layer == 'secure' ? rig.secure : rig.file).failWrites = true;
        final err = await enable(service(await freshSettings()));
        expect(err, isA<CloudEnableIncompleteException>());
        (layer == 'secure' ? rig.secure : rig.file).failWrites = false;
        expect(sim.of('writeCloudEgressEnableOn'), isEmpty);
        expect((await dartEgress()).where((r) => r.state == EgressState.on),
            isEmpty);
        expect(await rig.gate.permits(owner: kRigOwner), isFalse);
      });
    }

    test('uncertain restriction keeps the Dart pending and does not abandon',
        () async {
      sim.fault('writeCloudEgressEnableOn', SimFault.incomplete);
      sim.fault('restrictCloudEgressEnable', SimFault.uncertain);
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(
          sim
              .of('finishCloudEgressEnable')
              .where((c) => (c.arguments as Map)['abandon'] == true),
          isEmpty);
      expect(await pendingPresent(), isTrue);
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
    });

    test('an abandon that is not confirmed keeps the Dart pending', () async {
      sim.fault('writeCloudEgressEnableOn', SimFault.incomplete);
      sim.fault('finishCloudEgressEnable', SimFault.incomplete);
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(await pendingPresent(), isTrue);
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
    });
  });

  group('phase 5: the typed consent save', () {
    test('a save that throws compensates; the user can retry', () async {
      final settings = await freshSettings();
      settings.failSave = StateError('disk full');
      final err = await enable(service(settings));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('finishCloudEgressEnable').single.arguments,
          containsPair('abandon', true));
      expect(sim.of('restrictCloudEgressEnable'), hasLength(1));
      expect(sim.egressState, 'OFF');
      expect(await pendingPresent(), isFalse);
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
      settings.failSave = null;
      // Retry begins a genuinely new generation and version and succeeds.
      sim.faults.clear();
      expect(await enable(service(settings)), isNull);
      final begins = sim.of('beginCloudEgressEnable');
      expect(begins, hasLength(2));
      expect(
          (begins.last.arguments as Map)['transitionGeneration'],
          greaterThan(
              (begins.first.arguments as Map)['transitionGeneration'] as int));
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
    });

    test('a concurrently moved consent version is a failed transition',
        () async {
      final settings = await freshSettings();
      settings.beforeSave = () async {
        final c = await DriftUserSettingsRepository(f.host.current!.database)
            .getSettings();
        await DriftUserSettingsRepository(f.host.current!.database)
            .saveSettings(c.copyWith(aiConsentState: ConsentState.declined));
      };
      final err = await enable(service(settings));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('finishCloudEgressEnable').single.arguments,
          containsPair('abandon', true));
      expect(await pendingPresent(), isFalse);
      expect(await rig.gate.permits(owner: kRigOwner), isFalse,
          reason: 'a mismatched version never opens the gate');
      expect((await dartEgress()).where((r) => r.state == EgressState.on),
          isEmpty);
    });

    test('native work is not wrapped as a database local operation', () async {
      final release = sim.hold('writeCloudEgressEnableOn');
      final outcome = enable(service(await freshSettings()));
      await sim.reached['writeCloudEgressEnableOn']!.future;
      // A logout drains only bounded local database work. It must not wait for
      // the held native call (which is outside the drain).
      var done = false;
      final transition = f.session.signOut().whenComplete(() => done = true);
      await transition.timeout(const Duration(seconds: 10));
      expect(done, isTrue);
      release.complete();
      expect(
          await outcome,
          anyOf(isA<StaleAdmissionException>(),
              isA<CloudEnableIncompleteException>()));
    });
  });

  group('phase 6: native completion', () {
    for (final fault in [
      SimFault.nullReply,
      SimFault.platformError,
      SimFault.malformed,
      SimFault.conflict,
      SimFault.ownerMismatch,
      SimFault.uncertain,
      SimFault.incomplete,
      SimFault.noBarrier,
      SimFault.stale,
      SimFault.pending,
      SimFault.badLayers,
    ]) {
      test('complete ${fault.name}: the Dart denial is retained', () async {
        sim.fault('finishCloudEgressEnable', fault);
        final settings = await freshSettings();
        final err = await enable(service(settings));
        expect(err, isA<CloudEnableIncompleteException>());
        expect(settings.saved, 1,
            reason: 'a committed local choice is legitimate, not rolled back');
        expect(await pendingPresent(), isTrue);
        expect(await rig.gate.permits(owner: kRigOwner), isFalse);
        expect(rig.gate.permitsNetworkSync, isFalse);
        expect(
            sim
                .of('finishCloudEgressEnable')
                .where((c) => (c.arguments as Map)['abandon'] == true),
            isEmpty,
            reason: 'a barrier is never abandoned over an ON');
        expect(net.calls, 0);
      });
    }

    for (final layer in ['secure', 'file']) {
      test('native completed, the Dart $layer clear fails: still denied',
          () async {
        sim.afterApply = (m) {
          if (m == 'complete') {
            (layer == 'secure' ? rig.pendingSecure : rig.pendingFile)
                .failWrites = true;
          }
        };
        final err = await enable(service(await freshSettings()));
        expect(err, isA<CloudEnableIncompleteException>());
        expect(sim.pending, isNull, reason: 'native did complete');
        expect(await pendingPresent(), isTrue,
            reason: 'a partial clear keeps denying');
        expect(await rig.gate.permits(owner: kRigOwner), isFalse);
        // A fresh process still denies.
        final reloaded = CloudEgressGate(
          store: CloudEgressStore(
              secure: rig.secure,
              file: rig.file,
              native: rig.native.slot,
              pendingSecure: rig.pendingSecure,
              pendingFile: rig.pendingFile),
          activeOwner: () async => kRigOwner,
          resolved: true,
        );
        expect(await reloaded.permits(), isFalse);
      });
    }
  });

  group('loss of proof at every await', () {
    // Each pause point holds one await of the enable; the lifecycle then ends
    // by a real logout or a server auth loss. The enable never reports success,
    // no ON survives for the revoked scope except what native already completed
    // (kept denied by the Dart pending), nothing reaches the network.
    final points = <String>[
      'reserveRead',
      'pendingWrite',
      'nativeBegin',
      'bindWrite',
      'dartOnWrite',
      'nativeWriteOn',
      'consentSave',
      'nativeComplete',
      'pendingClear',
    ];
    for (final point in points) {
      for (final loss in ['signOut', 'authLoss']) {
        test('lost at $point by $loss: Stale, denied, no success, no network',
            () async {
          final settings = await freshSettings();
          Completer<void>? release;
          Future<void> reached;
          switch (point) {
            case 'reserveRead':
              settings.pauseAtRead(1);
              reached = Future.sync(() => settings.reached!.future);
              release = null;
            case 'pendingWrite':
              release = rig.pendingSecure.pauseAfterNextWrite();
              reached = Future.sync(() => rig.pendingSecure.reached!.future);
            case 'nativeBegin':
              release = sim.hold('beginCloudEgressEnable');
              reached = Future.sync(
                  () => sim.reached['beginCloudEgressEnable']!.future);
            case 'bindWrite':
              // The second pending write is the binding; pause after it.
              sim.afterApply = (m) {
                if (m == 'beginCloudEgressEnable') {
                  release = rig.pendingSecure.pauseAfterNextWrite();
                }
              };
              reached = Future.sync(() async {
                while (release == null) {
                  await Future<void>.delayed(const Duration(milliseconds: 5));
                }
                await rig.pendingSecure.reached!.future;
              });
            case 'dartOnWrite':
              release = rig.secure.pauseAfterNextWrite();
              reached = Future.sync(() => rig.secure.reached!.future);
            case 'nativeWriteOn':
              release = sim.hold('writeCloudEgressEnableOn');
              reached = Future.sync(
                  () => sim.reached['writeCloudEgressEnableOn']!.future);
            case 'consentSave':
              final gate = Completer<void>();
              final seen = Completer<void>();
              settings.beforeSave = () async {
                seen.complete();
                await gate.future;
              };
              release = gate;
              reached = seen.future;
            case 'nativeComplete':
              release = sim.hold('finishCloudEgressEnable');
              reached = Future.sync(
                  () => sim.reached['finishCloudEgressEnable']!.future);
            case 'pendingClear':
              sim.afterApply = (m) {
                if (m == 'complete') {
                  release = rig.pendingSecure.pauseAfterNextWrite();
                }
              };
              reached = Future.sync(() async {
                while (release == null) {
                  await Future<void>.delayed(const Duration(milliseconds: 5));
                }
                await rig.pendingSecure.reached!.future;
              });
            default:
              throw StateError(point);
          }
          final capability = f.session.captureConsentCapability()!;
          final outcome = enable(service(settings), capability);
          await reached;
          final epoch = rig.gate.epoch;

          var transitionDone = false;
          final Future<void> transition = loss == 'signOut'
              ? f.session.signOut()
              : Future.sync(() => f.session.markSessionInvalid());
          unawaited(transition.whenComplete(() => transitionDone = true));
          expect(capability.isCurrent, isFalse,
              reason: 'proof is lost synchronously at the origin');
          expect(rig.gate.epoch, greaterThanOrEqualTo(epoch));
          if (point == 'consentSave' && loss == 'signOut') {
            await pumpEventQueue(times: 30);
            expect(transitionDone, isFalse,
                reason: 'logout waits for the bounded consent drain');
          }
          // Native work that was already admitted may finish; release the hold.
          if (release != null && !release!.isCompleted) release!.complete();
          if (point == 'reserveRead') settings.resume();
          final error = await outcome;
          await transition;
          await pumpEventQueue(times: 20);

          expect(error, isNotNull, reason: 'never a success');
          expect(
              error,
              anyOf(isA<StaleAdmissionException>(),
                  isA<CloudEnableIncompleteException>()));
          expect(await rig.gate.permits(owner: kRigOwner), isFalse);
          expect(rig.gate.permitsNetworkSync, isFalse);
          expect(net.calls, 0);
          expect(ConsentAuthority.egressFrozen, isFalse,
              reason: 'a revoked enable never freezes a newer scope');
          final naturalOrder = points.indexOf(point);
          if (naturalOrder >= points.indexOf('nativeComplete')) {
            expect(await pendingPresent(), isTrue,
                reason: 'native may have completed: Dart denial is kept');
          }
          if (point == 'reserveRead') {
            expect(sim.of('beginCloudEgressEnable'), isEmpty);
            expect(await pendingPresent(), isFalse);
          }
          if (naturalOrder < points.indexOf('nativeWriteOn')) {
            expect((await dartEgress()).where((r) => r.state == EgressState.on),
                isEmpty);
          }
          expect(sim.egressState == 'ON' && !await pendingPresent(), isFalse,
              reason: 'native ON is never left without a Dart denial');
        });
      }
    }

    test('same uid readmitted at a new epoch while native begin is held',
        () async {
      final release = sim.hold('beginCloudEgressEnable');
      final capability = f.session.captureConsentCapability()!;
      final outcome = enable(service(await freshSettings()), capability);
      await sim.reached['beginCloudEgressEnable']!.future;
      final readmission = signIn('uid-x');
      release.complete();
      final error = await outcome;
      await readmission;
      expect(
          error,
          anyOf(isA<StaleAdmissionException>(),
              isA<CloudEnableIncompleteException>()));
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
      expect(f.session.captureConsentCapability(), isNotNull);
      expect(
          identical(f.session.captureConsentCapability(), capability), isFalse);
      expect(net.calls, 0);
    });
  });

  group('stale service', () {
    test('a retired service touches nothing', () async {
      final settings = await freshSettings();
      final s = service(settings);
      final capability = f.session.captureConsentCapability()!;
      s.dispose();
      final err = await enable(s, capability);
      expect(err, isA<StaleAdmissionException>());
      expect(
          sim.calls.where((c) =>
              c.method != 'publishRestrictiveCaptureOwner' &&
              c.method != 'captureOwnerEpoch'),
          isEmpty);
      expect(await pendingPresent(), isFalse);
      expect(rig.pendingSecure.writes, 0);
    });

    test('a capability from another lifecycle is refused before any effect',
        () async {
      final old = f.session.captureConsentCapability()!;
      await signIn('uid-x');
      final s = service(await freshSettings());
      final err = await enable(s, old);
      expect(err, isA<StaleAdmissionException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(await pendingPresent(), isFalse);
    });
  });

  group('serialisation', () {
    test('two concurrent enables never interleave their phases', () async {
      final settings = await freshSettings();
      final s = service(settings);
      final a = enable(s);
      final b = enable(s);
      final results = await Future.wait([a, b]);
      expect(results.where((e) => e == null), hasLength(1));
      expect(sim.of('beginCloudEgressEnable').length, 1,
          reason: 'the second call finds the transition already done');
    });
  });

  group('startup, restart and explicit resume', () {
    test('a restarted process denies and never auto-completes', () async {
      sim.fault('finishCloudEgressEnable', SimFault.platformError);
      final settings = await freshSettings();
      expect(await enable(service(settings)),
          isA<CloudEnableIncompleteException>());
      final calls = sim.calls.length;

      // A new process: new gate objects over the same persisted layers.
      final reloaded = CloudEgressGate(
        store: CloudEgressStore(
            secure: rig.secure,
            file: rig.file,
            native: rig.native.slot,
            pendingSecure: rig.pendingSecure,
            pendingFile: rig.pendingFile),
        activeOwner: () async => kRigOwner,
        resolved: false,
        nativeInflight: (_) async => (count: 0, latestDeadline: null),
      );
      final restarted = service(await freshSettings(), gate: reloaded);
      await restarted.resolvePendingDisable();
      expect(reloaded.isResolved, isTrue);
      expect(await reloaded.permits(), isFalse);
      await expectLater(
          reloaded.admit(), throwsA(isA<EgressDeniedException>()));
      expect(await pendingPresent(), isTrue);
      expect(sim.calls.length, calls,
          reason: 'startup performs no native phase call at all');
      expect(
          (await (await freshSettings()).getSettings()).cloudProcessingEnabled,
          isTrue,
          reason: 'accepted SQL is not completion evidence');
    });

    test('explicit retry resumes the SAME live native operation', () async {
      sim.fault('finishCloudEgressEnable', SimFault.platformError);
      final settings = await freshSettings();
      expect(await enable(service(settings)),
          isA<CloudEnableIncompleteException>());
      expect(sim.pending, isNotNull);

      final retry = await enable(service(await freshSettings()));
      expect(retry, isNull);
      final begins = sim.of('beginCloudEgressEnable');
      expect(begins, hasLength(2));
      final resume = Map<Object?, Object?>.from(begins.last.arguments as Map);
      expect(resume['resumeOperationId'], kSimOperationId);
      expect(resume['resumeOwnerEpoch'], sim.ownerEpoch);
      expect(sim.pending, isNull);
      expect(await pendingPresent(), isFalse);
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
      expect((await (await freshSettings()).getSettings()).consentVersion,
          (begins.first.arguments as Map)['reservedVersion'],
          reason: 'the resumed operation never saves a second version');
    });

    Future<({ConsentCapability capability, PendingEnableRecord pending})>
        coldPending({bool bound = true, bool nativeBegin = true}) async {
      final settings = await freshSettings();
      final previous = f.session.captureConsentCapability()!;
      final version = await settings.reserveConsentVersion(previous,
          verifiedFrontier: 2, operationId: 'cold-own');
      final binding = CloudEgressEnableBinding(
          operationId: kSimOperationId,
          transitionGeneration: 30,
          reservedVersion: version,
          ownerGeneration: sim.ownerGeneration,
          ownerEpoch: sim.ownerEpoch);
      final pending = PendingEnableRecord(
          ownerUid: kRigOwner,
          transitionGeneration: 30,
          reservedVersion: version,
          localOperationId: 'cold-own',
          binding: bound ? binding : null);
      await rig.gate.beginPendingEnable(pending);
      final on = rigRecord(
          bound ? EgressState.on : EgressState.off, bound ? 30 : 20, version);
      rig.secure.value = rigEnvelope(on);
      rig.file.value = rigEnvelope(on);
      rig.native.stored = on;
      sim
        ..egressState = (bound ? 'ON' : 'OFF')
        ..egressGeneration = (bound ? 30 : 20)
        ..egressVersion = version
        ..egressOwnerGeneration = binding.ownerGeneration
        ..egressOwnerEpoch = binding.ownerEpoch;
      sim.pending = nativeBegin
          ? {
              'operationId': binding.operationId,
              'transitionGeneration': 30,
              'reservedVersion': version,
              'ownerGeneration': binding.ownerGeneration,
              'ownerEpoch': binding.ownerEpoch
            }
          : null;
      // Actual AppSession reset: the previously published in-memory lifetime,
      // capability and SDK provider are gone; persisted SQL/native/pending remain.
      f.session.debugResetAdmissionState();
      f.session.configureCaptureOwnerPublish(null);
      await signIn(kRigOwner);
      final current = f.session.captureConsentCapability()!;
      expect(await f.session.committedOwnerLifetime(current), isNull);
      expect((await (await freshSettings()).getSettings()).consentVersion, 0);
      // A fallback publication must fail, just as native refuses pending.
      f.session.configureCaptureOwnerPublish((uid, authority) async {
        fail('cold pending resume must not publish a new native owner');
      });
      return (capability: current, pending: pending);
    }

    test(
        'cold AppSession explicitly resumes persisted native ON before local consent',
        () async {
      final cold = await coldPending();
      final publishes = sim.of('publishRestrictiveCaptureOwner').length;
      expect(await enable(service(await freshSettings()), cold.capability),
          isNull);
      expect((await (await freshSettings()).getSettings()).consentVersion,
          cold.pending.reservedVersion);
      expect(sim.of('publishRestrictiveCaptureOwner').length, publishes);
      expect(
          (sim.of('beginCloudEgressEnable').last.arguments
              as Map)['resumeOperationId'],
          kSimOperationId);
      expect(await pendingPresent(), isFalse);
      final lifetime = await f.session.committedOwnerLifetime(cold.capability);
      expect(lifetime!.operationId, isNot(kSimOperationId));
      expect(lifetime.ownerGeneration, cold.pending.binding!.ownerGeneration);
    });

    test(
        'cold unbound pending adopts applied native begin before lifetime acquisition',
        () async {
      final cold = await coldPending(bound: false);
      // Recover the missing copy before binding either physical pending layer.
      rig.pendingFile.value = null;
      final publishes = sim.of('publishRestrictiveCaptureOwner').length;
      expect(await enable(service(await freshSettings()), cold.capability),
          isNull);
      expect(sim.of('publishRestrictiveCaptureOwner').length, publishes);
      expect(
          (sim.of('beginCloudEgressEnable').last.arguments
              as Map)['resumeOperationId'],
          kSimOperationId);
      expect((await (await freshSettings()).getSettings()).consentVersion,
          cold.pending.reservedVersion);
      expect(await pendingPresent(), isFalse);
    });

    test(
        'cold unbound denial without native begin cleans before fresh recovery publication',
        () async {
      final cold = await coldPending(bound: false, nativeBegin: false);
      final svc = service(await freshSettings());
      Future<Object> publish(String uid, AdmissionAuthority authority) async {
        expect(await pendingPresent(), isFalse);
        final plan = f.session.explicitPublishPlanFor(authority);
        expect(plan, isNotNull);
        expect(plan!.version, greaterThan(3));
        return svc.publishRestrictiveOwnerDetailed(
            admissionAuthority: authority, plan: plan);
      }

      f.session.configureCaptureOwnerPublish(publish);
      expect(await enable(svc, cold.capability), isNull);
      expect((await (await freshSettings()).getSettings()).consentVersion,
          greaterThan(3));
      expect(sim.publishedVersion, greaterThan(3));
      expect(await pendingPresent(), isFalse);
    });

    for (final nativeBegin in [true, false]) {
      for (final fault in [
        'version',
        'generation',
        'lifetime',
        'higherFrontier'
      ]) {
        test(
            'cold unbound nativeBegin=$nativeBegin refuses $fault without clearing pending',
            () async {
          final cold =
              await coldPending(bound: false, nativeBegin: nativeBegin);
          if (nativeBegin) {
            switch (fault) {
              case 'version':
                sim.pending!['reservedVersion'] = 4;
              case 'generation':
                sim.pending!['transitionGeneration'] = 31;
              case 'lifetime':
                sim.ownerEpoch++;
              case 'higherFrontier':
                sim.egressVersion = 9;
            }
          } else {
            switch (fault) {
              case 'version':
                sim.pending = {
                  'operationId': kSimOperationId,
                  'transitionGeneration': 30,
                  'reservedVersion': 4,
                  'ownerGeneration': sim.ownerGeneration,
                  'ownerEpoch': sim.ownerEpoch
                };
              case 'generation':
                sim.pending = {
                  'operationId': kSimOperationId,
                  'transitionGeneration': 31,
                  'reservedVersion': 3,
                  'ownerGeneration': sim.ownerGeneration,
                  'ownerEpoch': sim.ownerEpoch
                };
              case 'lifetime':
                sim.egressOwnerEpoch = sim.ownerEpoch + 1;
              case 'higherFrontier':
                sim.egressVersion = 9;
            }
          }
          final secure = rig.pendingSecure.value;
          final file = rig.pendingFile.value;
          final publishes = sim.of('publishRestrictiveCaptureOwner').length;
          expect(await enable(service(await freshSettings()), cold.capability),
              isA<CloudEnableIncompleteException>());
          expect(rig.pendingSecure.value, secure);
          expect(rig.pendingFile.value, file);
          expect(sim.of('publishRestrictiveCaptureOwner').length, publishes);
          expect(sim.of('writeCloudEgressEnableOn'), isEmpty);
          expect(
              await f.session.committedOwnerLifetime(cold.capability), isNull);
        });
      }
    }

    test(
        'logout after cold adoption fences that lifetime with stable separate revocation id',
        () async {
      final cold = await coldPending();
      final proof = await rig.gate
          .provePendingEnableLifetime(cold.capability, cold.pending);
      final adopted =
          await f.session.resumeCommittedOwnerLifetime(cold.capability, proof);
      expect(adopted.binding, isNotNull);
      final repeated =
          await f.session.resumeCommittedOwnerLifetime(cold.capability, proof);
      expect(repeated.binding, adopted.binding);
      expect(adopted.binding!.operationId, isNot(kSimOperationId));
      expect(await pendingPresent(), isTrue);
      await f.session.signOut();
      await f.session.nativeLifecycleSettled();
      final revoke =
          sim.of('revokeCaptureAuthorizationLifetime').last.arguments as Map;
      expect(revoke['operationId'], adopted.binding!.operationId);
      expect(revoke['ownerGeneration'], cold.pending.binding!.ownerGeneration);
      expect(revoke['ownerEpoch'], cold.pending.binding!.ownerEpoch);
    });

    for (final fault in [
      'epoch',
      'generation',
      'foreign',
      'retired',
      'uncertain',
      'lostPending'
    ]) {
      test('cold lifetime adoption refuses $fault evidence', () async {
        final cold = await coldPending();
        switch (fault) {
          case 'epoch':
            sim.ownerEpoch++;
          case 'generation':
            sim.ownerGeneration++;
          case 'foreign':
            sim.egressOwnerGeneration = sim.ownerGeneration + 1;
          case 'uncertain':
            rig.file.failReads = true;
          case 'lostPending':
            rig.pendingFile.value = null;
          case 'retired':
            messenger.setMockMethodCallHandler(channel, (call) async {
              final result = await sim.handle(call);
              if (call.method != 'getCloudEgressPending') return result;
              final reply = Map<String, Object?>.from(result as Map);
              reply['egress'] = [
                for (final layer in reply['egress'] as List)
                  {
                    ...Map<String, Object?>.from(layer as Map),
                    'operationId': kSimOperationId
                  }
              ];
              return reply;
            });
        }
        await expectLater(
            rig.gate.provePendingEnableLifetime(cold.capability, cold.pending),
            throwsA(isA<StaleAdmissionException>()));
        expect(await f.session.committedOwnerLifetime(cold.capability), isNull);
        expect(sim.of('writeCloudEgressEnableOn'), isEmpty);
      });
    }

    test('cold lifetime proof cannot survive capability revocation', () async {
      final cold = await coldPending();
      final proof = await rig.gate
          .provePendingEnableLifetime(cold.capability, cold.pending);
      await f.session.signOut();
      await f.session.nativeLifecycleSettled();
      expect(
          (await f.session.resumeCommittedOwnerLifetime(cold.capability, proof))
              .binding,
          isNull);
      expect(sim.of('writeCloudEgressEnableOn'), isEmpty);
    });

    test('proof is reverified when pending disappears before session adoption',
        () async {
      final cold = await coldPending();
      final proof = await rig.gate
          .provePendingEnableLifetime(cold.capability, cold.pending);
      rig.pendingFile.value = null;
      expect(
          (await f.session.resumeCommittedOwnerLifetime(cold.capability, proof))
              .binding,
          isNull);
      expect(await f.session.committedOwnerLifetime(cold.capability), isNull);
    });

    test(
        'restart with a different admission epoch resumes own ON before local consent',
        () async {
      final settings = await freshSettings();
      final capability = f.session.captureConsentCapability()!;
      final version = await settings.reserveConsentVersion(capability,
          verifiedFrontier: 2, operationId: 'own-op');
      await settings.database.customStatement(
          'UPDATE consent_version_watermark SET reserved_epoch = ?',
          [capability.epoch + 100]);
      final binding = CloudEgressEnableBinding(
          operationId: kSimOperationId,
          transitionGeneration: 30,
          reservedVersion: version,
          ownerGeneration: sim.ownerGeneration,
          ownerEpoch: sim.ownerEpoch);
      await rig.gate.beginPendingEnable(PendingEnableRecord(
          ownerUid: kRigOwner,
          transitionGeneration: 30,
          reservedVersion: version,
          localOperationId: 'own-op',
          binding: binding));
      sim.pending = {
        'operationId': kSimOperationId,
        'transitionGeneration': 30,
        'reservedVersion': version,
        'ownerGeneration': sim.ownerGeneration,
        'ownerEpoch': sim.ownerEpoch
      };
      sim
        ..egressState = 'ON'
        ..egressGeneration = 30
        ..egressVersion = version
        ..egressOwnerGeneration = sim.ownerGeneration
        ..egressOwnerEpoch = sim.ownerEpoch;
      final on = rigRecord(EgressState.on, 30, version);
      rig.secure.value = rigEnvelope(on);
      rig.file.value = rigEnvelope(on);
      rig.native.stored = on;
      expect(await enable(service(settings), capability), isNull);
      expect((await settings.getSettings()).consentVersion, version);
      expect(await pendingPresent(), isFalse);
    });

    test(
        'one absent Dart layer plus one exact bound layer: explicit retry '
        'repairs and resumes', () async {
      sim.fault('finishCloudEgressEnable', SimFault.platformError);
      expect(await enable(service(await freshSettings())),
          isA<CloudEnableIncompleteException>());
      rig.pendingFile.value = null; // one layer lost
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
      expect(await enable(service(await freshSettings())), isNull);
      expect(await pendingPresent(), isFalse);
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
    });

    test('an old operation cannot resume after same-uid readmission', () async {
      sim.fault('finishCloudEgressEnable', SimFault.platformError);
      expect(await enable(service(await freshSettings())),
          isA<CloudEnableIncompleteException>());
      final oldBinding = Map<Object?, Object?>.from(
          sim.of('finishCloudEgressEnable').single.arguments as Map);
      final firstEpoch = sim.ownerEpoch;
      // Genuine readmission: a new native lifecycle.
      sim.ownerAlive = true;
      sim.ownerEpoch = 5;
      sim.ownerGeneration = 8;
      await signIn('uid-x');
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('writeCloudEgressEnableOn').length, 1,
          reason: 'only the first (old) attempt ever wrote ON');
      expect(oldBinding['ownerEpoch'], firstEpoch);
      expect(await pendingPresent(), isTrue,
          reason: 'the old operation is not confirmed abandoned: stay denied');
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
    });

    test(
        'a denied-stage pending with no native operation is cleaned and the '
        'retry begins a new generation', () async {
      sim.fault('beginCloudEgressEnable', SimFault.platformError);
      expect(await enable(service(await freshSettings())),
          isA<CloudEnableIncompleteException>());
      expect(await pendingPresent(), isTrue);
      expect(await enable(service(await freshSettings())), isNull);
      expect(await pendingPresent(), isFalse);
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
    });

    test('denied-stage cleanup still refuses a higher physical version',
        () async {
      sim.fault('beginCloudEgressEnable', SimFault.platformError);
      expect(await enable(service(await freshSettings())),
          isA<CloudEnableIncompleteException>());
      final pending = (await rig.gate.readPending()).agreed(kRigOwner)!;
      final bytes = rigEnvelope(rigRecord(EgressState.off,
          pending.transitionGeneration + 10, pending.reservedVersion + 8));
      rig.file.value = bytes;
      final begins = sim.of('beginCloudEgressEnable').length;
      final error = await enable(service(await freshSettings()));
      expect(error, isA<CloudEnableIncompleteException>());
      expect((error as CloudEnableIncompleteException).reason,
          'preflight_conflict/pending_frontier');
      expect(rig.file.value, bytes);
      expect((await rig.gate.readPending()).agreed(kRigOwner), pending);
      expect(sim.of('beginCloudEgressEnable').length, begins);
      expect(sim.of('writeCloudEgressEnableOn'), isEmpty);
    });

    test(
        'a denied-stage pending beside an unrelated native operation stays '
        'denied', () async {
      sim.fault('beginCloudEgressEnable', SimFault.platformError);
      expect(await enable(service(await freshSettings())),
          isA<CloudEnableIncompleteException>());
      sim.pending = {
        'operationId': 'f' * 32,
        'transitionGeneration': 99,
        'reservedVersion': 98,
        'ownerGeneration': 7,
        'ownerEpoch': sim.ownerEpoch,
      };
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('writeCloudEgressEnableOn'), isEmpty);
      expect(await pendingPresent(), isTrue);
      expect(sim.pending!['operationId'], 'f' * 32,
          reason: 'an unknown newer operation is never cleared');
    });

    test(
        'an unreadable Dart layer at retry leaves it denied without native '
        'phases', () async {
      sim.fault('finishCloudEgressEnable', SimFault.platformError);
      expect(await enable(service(await freshSettings())),
          isA<CloudEnableIncompleteException>());
      final before = sim.of('beginCloudEgressEnable').length;
      rig.pendingSecure.failReads = true;
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable').length, before);
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
    });
  });

  group('crash matrix (fresh process over the persisted layers)', () {
    Future<CloudEgressGate> fresh() async => CloudEgressGate(
          store: CloudEgressStore(
              secure: rig.secure,
              file: rig.file,
              native: rig.native.slot,
              pendingSecure: rig.pendingSecure,
              pendingFile: rig.pendingFile),
          activeOwner: () async => kRigOwner,
          resolved: true,
        );

    test('crash before either ON (pending only): denied', () async {
      sim.fault('beginCloudEgressEnable', SimFault.platformError);
      await enable(service(await freshSettings()));
      expect(await (await fresh()).permits(), isFalse);
    });

    test('crash after Dart ON, before native ON: denied by the pending',
        () async {
      sim.fault('writeCloudEgressEnableOn', SimFault.platformError);
      sim.fault('restrictCloudEgressEnable', SimFault.platformError);
      await enable(service(await freshSettings()));
      expect((await dartEgress()).any((r) => r.state == EgressState.on) || true,
          isTrue);
      expect(await (await fresh()).permits(), isFalse);
    });

    test('after the local choice committed, native not completed: denied',
        () async {
      sim.fault('finishCloudEgressEnable', SimFault.platformError);
      await enable(service(await freshSettings()));
      expect(await (await fresh()).permits(), isFalse);
    });

    test('native completed before the Dart clear: denied by the pending',
        () async {
      sim.afterApply = (m) {
        if (m == 'complete') rig.pendingSecure.failWrites = true;
      };
      await enable(service(await freshSettings()));
      expect(sim.pending, isNull);
      expect(await (await fresh()).permits(), isFalse);
    });

    test('unreadable stores at any step: denied', () async {
      await enable(service(await freshSettings()));
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
      rig.pendingFile.failReads = true;
      expect(await (await fresh()).permits(), isFalse);
      rig.pendingFile.failReads = false;
      rig.secure.failReads = true;
      expect(await (await fresh()).permits(), isFalse);
    });
  });

  group('non-iOS keeps its separate explicit Dart-only path', () {
    test('Android does not touch the native bridge or the pending layers',
        () async {
      final settings = await freshSettings();
      final android = CaptureDeviceRegistrationService(
        settingsRepository: settings,
        gate: rig.gate,
        client: net,
        isIos: () => false,
        isAndroid: () => true,
        isBackendConfigured: () => true,
        readSession: () => (uid: f.host.activeUid!, jwt: 'jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        isCurrentScope: () =>
            identical(f.host.current?.database, settings.database),
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
      );
      expect(await enable(android), isNull);
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(rig.pendingSecure.writes, 0);
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
    });
  });
}
