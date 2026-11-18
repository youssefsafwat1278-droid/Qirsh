import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/privacy/diagnostics_consent_gate.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/features/settings/privacy_screen.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../core/session/f2_fixture.dart';
import '../../harness/native_enable_sim.dart';
import '../../harness/paused_egress_support.dart';
import '../consent/consent_test_harness.dart';

// G1/G2 with the REAL service, gate, session and per-uid Drift replica behind
// the Privacy screen: what the status card says and which actions it offers for
// stored ON with native unset, OFF, corrupt and pending states, a successful
// recovery and a refusal. Only the platform edge (native channel stand-in,
// network client) is scripted. Real I/O is driven through runAsync.

final _en = lookupAppL10n(const Locale('en'));

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
  late CloudEgressGate gate;
  late _Spy settings;
  late CaptureDeviceRegistrationService service;

  Future<RestrictiveCaptureOwnerReceipt?> publish(
      String uid, AdmissionAuthority authority) async {
    final epoch = await NativeCaptureBridge.captureOwnerEpoch();
    return NativeCaptureBridge.publishRestrictiveCaptureOwner(
        uid: uid, version: 0, expectedEpoch: epoch);
  }

  Future<void> boot(WidgetTester tester, {bool nativeGate = false}) async {
    await tester.runAsync(() async {
      previousGate = CloudEgressGate.instance;
      NativeCaptureBridge.debugTreatHostAsNative = true;
      rig = EgressRig();
      // The rig's scripted native egress slot is not wired to the native enable
      // stand-in (the sim owns the native ON), so the gate here reads only the
      // Dart layers; the sim is the native side.
      gate = CloudEgressGate(
        store: CloudEgressStore(
            secure: rig.secure,
            file: rig.file,
            // R18: the production shape, the native egress layer reached through
            // the channel (the simulator is then the single native truth).
            native: nativeGate ? NativeEgressSlot.platformDefault() : null,
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
      messenger.setMockMethodCallHandler(channel, sim.handle);
      f = await F2Fixture.create();
      f.session.configureCaptureOwnerClear(() async {
        sim.ownerAlive = false;
        sim.ownerEpoch++;
        return true;
      });
      f.session.configureCaptureOwnerPublish(publish);
      final sdk = await F2Fixture.liveClient('uid-x');
      f.session.configureConsentSdkClient(() => sdk);
      await f.signIn('uid-x');
      settings = _Spy(f.host.current!.database);
      service = CaptureDeviceRegistrationService(
        settingsRepository: settings,
        gate: gate,
        client: net,
        isIos: () => true,
        isBackendConfigured: () => false,
        readSession: () => f.host.activeUid == null
            ? null
            : (uid: f.host.activeUid!, jwt: 'jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        isCurrentScope: () =>
            identical(f.host.current?.database, settings.database),
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
      );
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        for (final h in sim.holds.values) {
          if (!h.isCompleted) h.complete();
        }
        await pumpEventQueue(times: 30);
        f.session.configureCaptureOwnerPublish(null);
        f.session.debugResetAdmissionState();
        await f.dispose();
      });
      NativeCaptureBridge.debugTreatHostAsNative = false;
      messenger.setMockMethodCallHandler(channel, null);
      ConsentAuthority.egressFrozen = false;
      CloudEgressGate.instance = previousGate;
      DiagnosticsConsentGate.resetForTest();
    });
  }

  Future<T> io<T>(WidgetTester tester, Future<T> Function() body) async {
    T? result;
    await tester.runAsync(() async => result = await body());
    return result as T;
  }

  /// Lets real I/O and the frames it schedules run to quiescence.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// Like [settle], but stops as soon as [finder] matches (a toast only lives
  /// three seconds of frame time).
  Future<void> settleUntil(WidgetTester tester, Finder finder) async {
    final elapsed = Stopwatch()..start();
    while (finder.evaluate().isEmpty &&
        elapsed.elapsed < const Duration(seconds: 10)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      // Keep frame time close to real I/O time. Advancing seconds of fake
      // time while SQLite is still running can fire lifecycle timeouts early.
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(finder, findsWidgets,
        reason: 'the expected UI state must finish within 10s of real I/O');
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(consentApp(
      overrides: [
        appDatabaseProvider.overrideWithValue(f.host.current!.database),
        userSettingsRepositoryProvider.overrideWithValue(settings),
        consentSettingsWriterProvider.overrideWithValue(settings),
        userSettingsProvider.overrideWith((_) => settings.getSettings()),
        captureDeviceRegistrationServiceProvider.overrideWithValue(service),
        merchantOffersEnabledProvider.overrideWithValue(false),
      ],
      home: const PrivacyScreen(),
    ));
    await settle(tester);
  }

  Finder status(String text) => find.descendant(
      of: find.byKey(const Key('consentStatus')), matching: find.text(text));
  Finder turnOn() => find.byKey(const Key('consentTurnOn'));
  Finder turnOff() => find.byKey(const Key('consentTurnOff'));

  Future<void> seedStoredOn(WidgetTester tester) => io(
      tester,
      () => settings
          .saveConsentChoice(f.session.captureConsentCapability()!, _accept));

  void seedDartOn(int version) {
    final body = rigEnvelope(rigRecord(EgressState.on, 1, version));
    rig.secure.value = body;
    rig.file.value = body;
  }

  group('status and actions with the real service', () {
    testWidgets('stored ON, native unset: Can\'t confirm, never On, no Turn on',
        (tester) async {
      await boot(tester);
      final row = await seedStoredOn(tester).then((_) => io(tester, settings.getSettings));
      seedDartOn(row.consentVersion); // Dart says ON; native has nothing
      await pumpScreen(tester);
      expect(status(_en.consentStatusUnknown), findsOneWidget);
      expect(status(_en.consentStatusActive), findsNothing);
      expect(turnOn(), findsNothing);
      expect(turnOff(), findsOneWidget);
      expect(find.text(_en.consentStatusUnknownRecovery), findsOneWidget);
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(net.calls, 0);
    });

    testWidgets('stored ON, native OFF: Can\'t confirm', (tester) async {
      await boot(tester);
      final row = await seedStoredOn(tester).then((_) => io(tester, settings.getSettings));
      seedDartOn(row.consentVersion);
      sim.egressState = 'OFF';
      sim.egressGeneration = 1;
      sim.egressVersion = row.consentVersion;
      await pumpScreen(tester);
      expect(status(_en.consentStatusUnknown), findsOneWidget);
      expect(turnOn(), findsNothing);
    });

    testWidgets('stored ON, corrupt Dart store: Can\'t confirm', (tester) async {
      await boot(tester);
      await seedStoredOn(tester);
      rig.secure.value = 'not json';
      await pumpScreen(tester);
      expect(status(_en.consentStatusUnknown), findsOneWidget);
      expect(status(_en.consentStatusActive), findsNothing);
      expect(turnOn(), findsNothing);
    });

    testWidgets('stored OFF: Off with a Turn on that completes a fresh enable',
        (tester) async {
      await boot(tester);
      await pumpScreen(tester);
      expect(status(_en.consentStatusOff), findsOneWidget);
      expect(turnOn(), findsOneWidget);
      await tester.ensureVisible(turnOn());
      await tester.tap(turnOn());
      await settle(tester);
      // The full disclosure is long: scroll to the action first.
      await tester.ensureVisible(find.byKey(const Key('initialConsentAccept')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await settle(tester);
      await settle(tester); // the preflight/reservation adds local DB work
      expect(sim.of('finishCloudEgressEnable'), hasLength(1));
      expect(settings.saved, 1);
      expect(status(_en.consentStatusActive), findsOneWidget,
          reason: 'On only after the verified completion');
      expect(net.calls, 0);
    });

    testWidgets('pending after incomplete native work: Turning on, never On; '
        'Turn on resumes the exact operation', (tester) async {
      await boot(tester);
      sim.fault('finishCloudEgressEnable', SimFault.nullReply);
      final err = await io(
          tester,
          () => service
              .enableCloud(
                  write: ConsentWrite(
                      f.session.captureConsentCapability()!, _accept))
              .then<Object?>((_) => null, onError: (Object e) => e));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(settings.saved, 1);
      await pumpScreen(tester);
      expect(status(_en.consentStatusTurningOn), findsOneWidget);
      expect(status(_en.consentStatusActive), findsNothing);
      expect(turnOff(), findsOneWidget,
          reason: 'Turn off is the verified withdrawal route');
      expect(turnOn(), findsOneWidget);
      await tester.ensureVisible(turnOn());
      await tester.tap(turnOn());
      await settle(tester);
      // The full disclosure is long: scroll to the action first.
      await tester.ensureVisible(find.byKey(const Key('initialConsentAccept')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await settle(tester);
      expect(settings.saved, 1, reason: 'the committed choice is not re-saved');
      expect(sim.pending, isNull);
      expect(status(_en.consentStatusActive), findsOneWidget);
    });

    testWidgets('a verified partial permission completes with a plain save',
        (tester) async {
      await boot(tester);
      await io(
          tester,
          () => service.enableCloud(
              write: ConsentWrite(f.session.captureConsentCapability()!,
                  const ConsentChoices(
                      cloud: ConsentState.accepted,
                      ai: ConsentState.declined))));
      await pumpScreen(tester);
      expect(status(_en.consentStatusPartial), findsOneWidget);
      await tester.ensureVisible(turnOn());
      await tester.tap(turnOn());
      await settle(tester);
      // The full disclosure is long: scroll to the action first.
      await tester.ensureVisible(find.byKey(const Key('initialConsentAccept')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await settle(tester);
      expect(sim.of('beginCloudEgressEnable'), hasLength(1),
          reason: 'no second native enable over a verified live ON');
      expect(status(_en.consentStatusActive), findsOneWidget);
    });

    testWidgets('recovery from Can\'t confirm: withdraw, then enable fresh',
        (tester) async {
      await boot(tester);
      final row = await seedStoredOn(tester).then((_) => io(tester, settings.getSettings));
      seedDartOn(row.consentVersion);
      await pumpScreen(tester);
      expect(status(_en.consentStatusUnknown), findsOneWidget);
      await tester.ensureVisible(turnOff());
      await tester.tap(turnOff());
      await settle(tester);
      await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
      await settle(tester);
      expect((await io(tester, settings.getSettings)).cloudProcessingEnabled,
          isFalse);
      expect(status(_en.consentStatusOff), findsOneWidget);
      expect(turnOn(), findsOneWidget);
      await tester.ensureVisible(turnOn());
      await tester.tap(turnOn());
      await settle(tester);
      // The full disclosure is long: scroll to the action first.
      await tester.ensureVisible(find.byKey(const Key('initialConsentAccept')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await settle(tester);
      expect(sim.of('finishCloudEgressEnable'), hasLength(1));
      expect(status(_en.consentStatusActive), findsOneWidget);
    });
  });

  group('R17/R18 pending states on the screen', () {
    const cloudOnly = ConsentChoices(
        cloud: ConsentState.accepted, ai: ConsentState.declined);

    Future<void> leavePending(WidgetTester tester) async {
      sim.fault('finishCloudEgressEnable', SimFault.nullReply);
      final err = await io(
          tester,
          () => service
              .enableCloud(
                  write: ConsentWrite(
                      f.session.captureConsentCapability()!, cloudOnly))
              .then<Object?>((_) => null, onError: (Object e) => e));
      expect(err, isA<CloudEnableIncompleteException>());
    }

    Future<void> moveVersionOn(WidgetTester tester) => io(
        tester,
        () => settings.saveConsentChoice(
            f.session.captureConsentCapability()!, _accept));

    Future<void> withdraw(WidgetTester tester) async {
      await tester.ensureVisible(turnOff());
      await tester.tap(turnOff());
      await settle(tester);
      await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
      await settle(tester);
    }

    testWidgets('an unresolved pending offers no Turn on, only the withdrawal',
        (tester) async {
      await boot(tester, nativeGate: true);
      await leavePending(tester);
      await moveVersionOn(tester); // stored version no longer the reserved one
      await pumpScreen(tester);
      expect(status(_en.consentStatusTurningOn), findsOneWidget);
      expect(status(_en.consentStatusActive), findsNothing);
      expect(turnOn(), findsNothing);
      expect(turnOff(), findsOneWidget);
      expect(find.text(_en.consentStatusUnknownRecovery), findsOneWidget);
    });

    testWidgets('a resumable pending offers both Turn on and Turn off',
        (tester) async {
      await boot(tester, nativeGate: true);
      await leavePending(tester);
      await pumpScreen(tester);
      expect(status(_en.consentStatusTurningOn), findsOneWidget);
      expect(turnOn(), findsOneWidget);
      expect(turnOff(), findsOneWidget);
    });

    testWidgets('Cloud-only pending then both-permission Accept: the resume '
        'completes Cloud only and says the new choice was not saved',
        (tester) async {
      await boot(tester, nativeGate: true);
      await leavePending(tester);
      final saved = settings.saved;
      await pumpScreen(tester);
      await tester.ensureVisible(turnOn());
      await tester.tap(turnOn());
      await settle(tester);
      // The full disclosure is long: scroll to the action first.
      await tester.ensureVisible(find.byKey(const Key('initialConsentAccept')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await settleUntil(tester, find.text(_en.cloudEnableChoiceNotSaved));
      final row = await io(tester, settings.getSettings);
      expect(row.cloudProcessingEnabled, isTrue);
      expect(row.aiConsentGranted, isFalse, reason: 'AI was never saved');
      expect(settings.saved, saved);
      for (final t in [
        _en.cloudEnableIncomplete,
        _en.cloudEnableWithdrawFirst,
        _en.setupSaveFailed
      ]) {
        expect(find.text(t), findsNothing, reason: t);
      }
      expect(find.text(_en.cloudEnableChoiceNotSaved), findsOneWidget);
      expect(net.calls, 0, reason: 'no backend work on an unsaved choice');
      // The sheet did not report a grant: it is still open for another try.
      expect(find.byKey(const Key('initialConsentAccept')), findsOneWidget);
      await tester.pump(const Duration(seconds: 4)); // the toast timer
    });

    testWidgets('Turn off withdraws an unresolved pending: verified, then '
        'Off and a fresh Turn on', (tester) async {
      await boot(tester, nativeGate: true);
      await leavePending(tester);
      await moveVersionOn(tester);
      await pumpScreen(tester);
      await withdraw(tester);
      final row = await io(tester, settings.getSettings);
      expect(row.cloudProcessingEnabled, isFalse);
      expect(row.aiConsentGranted, isFalse);
      expect(sim.pending, isNull);
      expect(await io(tester, () => gate.readPending()).then((r) => r.blocks(kRigOwner)),
          isFalse);
      expect(status(_en.consentStatusOff), findsOneWidget);
      expect(turnOn(), findsOneWidget);
      await tester.ensureVisible(turnOn());
      await tester.tap(turnOn());
      await settle(tester);
      // Exercise real native completion later than the old 750ms I/O window.
      // The screen must wait for the verified receipt before reporting On.
      final nativeFinish = sim.hold('finishCloudEgressEnable');
      await tester.runAsync(() async {
        Timer(const Duration(seconds: 2), () {
          if (!nativeFinish.isCompleted) nativeFinish.complete();
        });
      });
      // The full disclosure is long: scroll to the action first.
      await tester.ensureVisible(find.byKey(const Key('initialConsentAccept')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await settleUntil(tester, status(_en.consentStatusActive));
      expect(status(_en.consentStatusActive), findsOneWidget);
      expect(nativeFinish.isCompleted, isTrue);
      expect(sim.pending, isNull);
      expect(await io(tester, () => gate.permits(owner: kRigOwner)), isTrue);
      expect(net.calls, 0);
    });

    testWidgets('a withdrawal that cannot be verified says so and stays '
        'denied; a retry completes it', (tester) async {
      await boot(tester, nativeGate: true);
      await leavePending(tester);
      sim.fault('finishCloudEgressEnable', SimFault.incomplete);
      await pumpScreen(tester);
      await tester.ensureVisible(turnOff());
      await tester.tap(turnOff());
      await settle(tester);
      await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
      await settleUntil(tester, find.text(_en.consentWithdrawFailed));
      expect(find.text(_en.consentWithdrawFailed), findsOneWidget);
      expect(status(_en.consentStatusTurningOn), findsOneWidget);
      expect(status(_en.consentStatusOff), findsNothing);
      expect(sim.pending, isNotNull);
      expect(turnOff(), findsOneWidget);
      await withdraw(tester);
      expect(status(_en.consentStatusOff), findsOneWidget);
      expect(sim.pending, isNull);
    });
  });
}
