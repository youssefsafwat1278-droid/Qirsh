import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/diagnostics_consent_gate.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/features/settings/consent_status.dart';
import 'package:money_companion/features/settings/privacy_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../consent/consent_test_harness.dart';

// Deliberate consent management on the Privacy screen: an honest status
// (active / partial / off / unknown / turning on / turning off) and explicit
// actions. Nothing is changed by rendering; cancelling or dismissing keeps the
// stored choices; only the disclosed Accept grants; withdrawal is confirmed and
// jointly stops cloud and AI.

final _en = lookupAppL10n(const Locale('en'));

class _DirectOpener extends ConsumerWidget {
  const _DirectOpener();
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () =>
                showSmartAnalysisConsentSheet(context, ref, management: true),
            child: const Text('open'),
          ),
        ),
      );
}

class _RevokeFailsService extends FakeRegistrationService {
  bool revokeFailed = false;

  @override
  Future<void> disableCloud({required Future<void> Function() commitLocalOff}) async {
    disableCalls++;
    revokeFailed = true;

    await commitLocalOff();
  }
}

class _StaleDuringDisable extends FakeRegistrationService {
  _StaleDuringDisable(this.expire);
  final void Function() expire;

  @override
  Future<void> disableCloud({required Future<void> Function() commitLocalOff}) async {
    disableCalls++;
    expire();
    await commitLocalOff();
  }
}

void main() {
  late FakeSettingsRepository repo;
  late FakeRegistrationService service;
  var facts = ConsentLiveFacts.confirmedOn;
  var current = true;
  // G5: which admitted lifecycle a freshly captured capability belongs to. A
  // readmission or account switch moves it; every capability captured earlier
  // stops being current, while a NEW valid one becomes available.
  var generation = 0;
  var uid = 'uid-fake';

  setUp(() {
    repo = FakeSettingsRepository();
    service = FakeRegistrationService();
    facts = ConsentLiveFacts.confirmedOn;
    current = true;
    generation = 0;
    uid = 'uid-fake';
    DiagnosticsConsentGate.resetForTest();
  });
  tearDown(DiagnosticsConsentGate.resetForTest);

  Future<void> pump(WidgetTester tester, {String locale = 'en'}) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(consentApp(
      overrides: [
        ...consentOverrides(repo, service,
            workSource: () {
              final mine = generation;
              return fakeConsentWork(
                  isCurrent: () => current && generation == mine, uid: uid);
            }),
        consentLiveFactsProvider.overrideWith((_) async => facts),
        merchantOffersEnabledProvider.overrideWithValue(false),
      ],
      home: const PrivacyScreen(),
      locale: locale,
    ));
    await tester.pumpAndSettle();
  }

  void set(ConsentState cloud, ConsentState ai) => repo.settings =
      repo.settings.copyWith(cloudConsentState: cloud, aiConsentState: ai);

  Finder status(String text) =>
      find.descendant(of: find.byKey(const Key('consentStatus')), matching: find.text(text));

  group('honest status', () {
    testWidgets('active', (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      await pump(tester);
      expect(status(_en.consentStatusActive), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNothing,
          reason: 'no daily cloud/AI switches');
    });

    testWidgets('partial', (tester) async {
      set(ConsentState.accepted, ConsentState.declined);
      await pump(tester);
      expect(status(_en.consentStatusPartial), findsOneWidget);
    });

    testWidgets('off', (tester) async {
      await pump(tester);
      expect(status(_en.consentStatusOff), findsOneWidget);
    });

    testWidgets('unknown when the live state cannot be confirmed', (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      facts = const ConsentLiveFacts(egressState: EgressState.on, uncertain: true);
      await pump(tester);
      expect(status(_en.consentStatusUnknown), findsOneWidget);
      expect(status(_en.consentStatusActive), findsNothing);
    });

    testWidgets('a resumable pending enable shows turning on, never active',
        (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      facts = const ConsentLiveFacts(
          egressState: EgressState.on,
          enablePending: true,
          pendingResumable: true);
      await pump(tester);
      expect(status(_en.consentStatusTurningOn), findsOneWidget);
      expect(status(_en.consentStatusActive), findsNothing);
      expect(find.byKey(const Key('consentTurnOn')), findsOneWidget,
          reason: 'G1/R17: the exact resume of a resumable pending');
      expect(find.byKey(const Key('consentTurnOff')), findsOneWidget,
          reason: 'R18: the verified withdrawal route');
      expect(find.byKey(const Key('consentRefresh')), findsOneWidget);
    });

    testWidgets('an unresolved pending enable offers only the withdrawal',
        (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      facts = const ConsentLiveFacts(
          egressState: EgressState.on, enablePending: true);
      await pump(tester);
      expect(status(_en.consentStatusTurningOn), findsOneWidget);
      expect(find.byKey(const Key('consentTurnOn')), findsNothing,
          reason: 'R17: no Turn on over an unresolved pending');
      expect(find.byKey(const Key('consentTurnOff')), findsOneWidget);
      expect(find.text(_en.consentStatusUnknownRecovery), findsOneWidget);
    });

    testWidgets('Turn off from a pending enable is the verified withdrawal, '
        'not a plain disable', (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      facts = const ConsentLiveFacts(
          egressState: EgressState.on, enablePending: true);
      service.pendingStateOverride = PendingEnableState.unresolved;
      await pump(tester);
      await tester.ensureVisible(find.byKey(const Key('consentTurnOff')));
      await tester.tap(find.byKey(const Key('consentTurnOff')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
      await tester.pumpAndSettle();
      expect(service.withdrawCalls, 1);
      expect(service.disableCalls, 0);
      expect(repo.settings.cloudConsentState, ConsentState.declined);
      expect(repo.settings.aiConsentState, ConsentState.declined);
    });

    testWidgets('a withdrawal that is not verified is reported and changes '
        'nothing else', (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      facts = const ConsentLiveFacts(
          egressState: EgressState.on, enablePending: true);
      service.pendingStateOverride = PendingEnableState.unresolved;
      service.withdrawError = const CloudWithdrawIncompleteException('x');
      await pump(tester);
      await tester.ensureVisible(find.byKey(const Key('consentTurnOff')));
      await tester.tap(find.byKey(const Key('consentTurnOff')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
      await tester.pumpAndSettle();
      expect(find.text(_en.consentWithdrawFailed), findsOneWidget);
      expect(repo.settings.cloudConsentState, ConsentState.accepted);
      expect(service.syncCalls, 0);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a disabling gate shows turning off', (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      facts = const ConsentLiveFacts(egressState: EgressState.disabling);
      await pump(tester);
      expect(status(_en.consentStatusTurningOff), findsOneWidget);
    });

    testWidgets('a frozen gate shows the non-sensitive freeze tag', (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      facts = const ConsentLiveFacts(frozen: true, uncertain: true);
      ConsentAuthority.egressFreezeTag = 'reconcile_uncertain:native:epoch_missing';
      addTearDown(() => ConsentAuthority.egressFreezeTag = '');
      await pump(tester);
      expect(find.text('freeze: reconcile_uncertain:native:epoch_missing'),
          findsOneWidget);
      facts = ConsentLiveFacts.confirmedOn;
    });

    testWidgets('Arabic status renders', (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      await pump(tester, locale: 'ar');
      final ar = lookupAppL10n(const Locale('ar'));
      expect(status(ar.consentStatusActive), findsOneWidget);
    });
  });

  group('rendering and navigation grant nothing', () {
    testWidgets('opening the screen writes nothing and syncs nothing',
        (tester) async {
      await pump(tester);
      expect(repo.saveCalls, 0);
      expect(service.enableCalls, 0);
      expect(service.disableCalls, 0);
      expect(service.syncCalls, 0);
      expect(repo.settings.cloudConsentState, ConsentState.unset);
      expect(repo.settings.aiConsentState, ConsentState.unset);
    });
  });

  group('turning on goes through the existing disclosure', () {
    for (final start in <(ConsentState, ConsentState)>[
      (ConsentState.unset, ConsentState.unset),
      (ConsentState.declined, ConsentState.declined),
      (ConsentState.accepted, ConsentState.declined),
    ]) {
      testWidgets('cancel keeps ${start.$1.name}/${start.$2.name} untouched',
          (tester) async {
        set(start.$1, start.$2);
        await pump(tester);
        await tester.ensureVisible(find.byKey(const Key('consentTurnOn')));
        await tester.tap(find.byKey(const Key('consentTurnOn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('initialConsentAccept')), findsOneWidget,
            reason: 'the existing disclosure');
        expect(find.byKey(const Key('initialConsentDecline')), findsNothing,
            reason: 'first-use denial is not a management cancel');
        await tester.tap(find.byKey(const Key('consentManageCancel')));
        await tester.pumpAndSettle();
        expect(repo.saveCalls, 0);
        expect(repo.settings.cloudConsentState, start.$1);
        expect(repo.settings.aiConsentState, start.$2);
        expect(service.enableCalls, 0);
        expect(service.disableCalls, 0);
      });

      testWidgets('dismissing keeps ${start.$1.name}/${start.$2.name} untouched',
          (tester) async {
        set(start.$1, start.$2);
        await pump(tester);
        await tester.ensureVisible(find.byKey(const Key('consentTurnOn')));
        await tester.tap(find.byKey(const Key('consentTurnOn')));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(400, 20));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('initialConsentAccept')), findsNothing);
        expect(repo.saveCalls, 0);
        expect(repo.settings.cloudConsentState, start.$1);
        expect(repo.settings.aiConsentState, start.$2);
      });
    }

    testWidgets('only the explicit Accept grants both', (tester) async {
      await pump(tester);
      await tester.ensureVisible(find.byKey(const Key('consentTurnOn')));
      await tester.tap(find.byKey(const Key('consentTurnOn')));
      await tester.pumpAndSettle();
      expect(repo.saveCalls, 0, reason: 'opening the disclosure grants nothing');
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await tester.pumpAndSettle(const Duration(seconds: 6));
      expect(service.enableCalls, 1, reason: 'the durable enable flow');
      expect(repo.settings.cloudConsentState, ConsentState.accepted);
      expect(repo.settings.aiConsentState, ConsentState.accepted);
    });

    testWidgets('an incomplete enable says so, grants nothing and is not shown '
        'as active', (tester) async {
      service.enableError = const CloudEnableIncompleteException('native');
      await pump(tester);
      await tester.ensureVisible(find.byKey(const Key('consentTurnOn')));
      await tester.tap(find.byKey(const Key('consentTurnOn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
          find.text('${_en.cloudEnableIncomplete} '
              '(E: CloudEnableIncomplete:native)'),
          findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 6));
      expect(repo.settings.cloudConsentState, ConsentState.unset);
      expect(service.syncCalls, 0);
      await tester.tap(find.byKey(const Key('consentManageCancel')));
      await tester.pumpAndSettle();
      expect(status(_en.consentStatusActive), findsNothing);
    });

    testWidgets('closing the sheet after an enable that is still pending shows '
        'turning on, not active', (tester) async {
      service.enableError = const CloudEnableIncompleteException('native');
      await pump(tester);
      await tester.ensureVisible(find.byKey(const Key('consentTurnOn')));
      await tester.tap(find.byKey(const Key('consentTurnOn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await tester.pumpAndSettle(const Duration(seconds: 6));
      // The durable pending denial is still held after the failed enable.
      facts = const ConsentLiveFacts(enablePending: true);
      await tester.tap(find.byKey(const Key('consentManageCancel')));
      await tester.pumpAndSettle();
      expect(status(_en.consentStatusTurningOn), findsOneWidget);
      expect(status(_en.consentStatusActive), findsNothing);
    });

    testWidgets('a lifecycle that ended while the disclosure was open grants '
        'nothing', (tester) async {
      await pump(tester);
      await tester.ensureVisible(find.byKey(const Key('consentTurnOn')));
      await tester.tap(find.byKey(const Key('consentTurnOn')));
      await tester.pumpAndSettle();
      current = false; // logout / account switch while the sheet is open
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await tester.pumpAndSettle(const Duration(seconds: 6));
      expect(repo.settings.cloudConsentState, ConsentState.unset);
      expect(repo.settings.aiConsentState, ConsentState.unset);
      expect(find.text(_en.cloudEnableIncomplete), findsNothing);
    });
  });

  group('G1: actions follow verified transition semantics', () {
    Finder turnOn() => find.byKey(const Key('consentTurnOn'));
    Finder turnOff() => find.byKey(const Key('consentTurnOff'));

    testWidgets('stored ON that cannot be confirmed (native unset or '
        'unverified): Can\'t confirm, no Turn on, withdrawal and a hint',
        (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      facts = const ConsentLiveFacts(
          egressState: EgressState.on, nativeVerified: false);
      await pump(tester);
      expect(status(_en.consentStatusUnknown), findsOneWidget);
      expect(status(_en.consentStatusActive), findsNothing,
          reason: 'never On falsely');
      expect(turnOn(), findsNothing);
      expect(turnOff(), findsOneWidget);
      expect(find.byKey(const Key('consentRefresh')), findsOneWidget);
      expect(find.text(_en.consentStatusUnknownRecovery), findsOneWidget);
    });

    for (final unreadable in [true, false]) {
      testWidgets(
          unreadable
              ? 'corrupt/unreadable stores with stored ON: no Turn on'
              : 'no durable ON record with stored ON: no Turn on',
          (tester) async {
        set(ConsentState.accepted, ConsentState.accepted);
        facts = unreadable
            ? ConsentLiveFacts.unreadable
            : const ConsentLiveFacts();
        await pump(tester);
        expect(status(_en.consentStatusUnknown), findsOneWidget);
        expect(turnOn(), findsNothing);
        expect(turnOff(), findsOneWidget);
      });
    }

    testWidgets('stored OFF stays Off (with a Turn on) even when the stores '
        'are corrupt: nothing is claimed on', (tester) async {
      facts = ConsentLiveFacts.unreadable;
      await pump(tester);
      expect(status(_en.consentStatusOff), findsOneWidget);
      expect(turnOn(), findsOneWidget);
      expect(turnOff(), findsNothing);
    });

    testWidgets('partly on with a verified live ON keeps Turn on and Turn off',
        (tester) async {
      set(ConsentState.accepted, ConsentState.declined);
      await pump(tester);
      expect(status(_en.consentStatusPartial), findsOneWidget);
      expect(turnOn(), findsOneWidget);
      expect(turnOff(), findsOneWidget);
    });

    testWidgets('recovery: withdraw from Can\'t confirm, then a fresh enable '
        'is offered and succeeds', (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      facts = const ConsentLiveFacts(
          egressState: EgressState.on, nativeVerified: false);
      await pump(tester);
      await tester.ensureVisible(turnOff());
      await tester.tap(turnOff());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
      await tester.pumpAndSettle();
      expect(service.disableCalls, 1);
      expect(repo.settings.cloudConsentState, ConsentState.declined);
      facts = const ConsentLiveFacts(egressState: EgressState.off);
      // The status re-reads after the withdrawal.
      await tester.pumpAndSettle();
      expect(status(_en.consentStatusOff), findsOneWidget);
      await tester.ensureVisible(turnOn());
      await tester.tap(turnOn());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await tester.pumpAndSettle(const Duration(seconds: 6));
      expect(service.enableCalls, 1);
      expect(repo.settings.cloudConsentState, ConsentState.accepted);
    });

    testWidgets('refusal over a stored ON: honest message, nothing written, '
        'no retry / link / sync', (tester) async {
      set(ConsentState.accepted, ConsentState.declined);
      service.routeOverride = ExplicitEnableRoute.withdrawFirst;
      await pump(tester);
      await tester.ensureVisible(turnOn());
      await tester.tap(turnOn());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(_en.cloudEnableWithdrawFirst), findsOneWidget);
      expect(find.text(_en.setupSaveFailed), findsNothing);
      await tester.pumpAndSettle(const Duration(seconds: 6));
      expect(repo.saveCalls, 0);
      expect(service.enableCalls, 0);
      expect(service.retryCalls, 0);
      expect(service.syncCalls, 0);
      expect(repo.settings.aiConsentState, ConsentState.declined);
      expect(status(_en.consentStatusActive), findsNothing);
    });

    testWidgets('exact pending resume from Turning on: enable once, sync only '
        'after it', (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      facts = const ConsentLiveFacts(
          egressState: EgressState.on,
          enablePending: true,
          pendingResumable: true);
      service.routeOverride = ExplicitEnableRoute.resumePending;
      await pump(tester);
      await tester.ensureVisible(turnOn());
      await tester.tap(turnOn());
      await tester.pumpAndSettle();
      expect(service.syncCalls, 0);
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await tester.pumpAndSettle(const Duration(seconds: 6));
      expect(service.enableCalls, 1);
      expect(service.syncCalls + service.retryCalls, greaterThan(0),
          reason: 'registration follows a completed enable only');
    });
  });

  group('cancel and dismiss write nothing in every initial state', () {
    const states = <(String, ConsentState, ConsentState, ConsentLiveFacts)>[
      ('unset', ConsentState.unset, ConsentState.unset,
          ConsentLiveFacts(resolved: true)),
      ('declined', ConsentState.declined, ConsentState.declined,
          ConsentLiveFacts(egressState: EgressState.off)),
      ('verified partial', ConsentState.accepted, ConsentState.declined,
          ConsentLiveFacts(egressState: EgressState.on)),
      ('stored ON, native unverified', ConsentState.accepted,
          ConsentState.accepted,
          ConsentLiveFacts(egressState: EgressState.on, nativeVerified: false)),
      ('stored ON, unreadable', ConsentState.accepted, ConsentState.accepted,
          ConsentLiveFacts(uncertain: true)),
      ('pending enable', ConsentState.accepted, ConsentState.accepted,
          ConsentLiveFacts(
              egressState: EgressState.on,
              enablePending: true,
              pendingResumable: true)),
    ];
    for (final st in states) {
      for (final cancel in [true, false]) {
        testWidgets(
            '${cancel ? 'cancel' : 'dismiss'} the disclosure from ${st.$1}',
            (tester) async {
          set(st.$2, st.$3);
          facts = st.$4;
          await pump(tester);
          final opener = find.byKey(const Key('consentTurnOn'));
          if (opener.evaluate().isEmpty) {
            // Not offered here (nothing safe to turn on): nothing to cancel.
            expect(repo.saveCalls, 0);
            return;
          }
          await tester.ensureVisible(opener);
          await tester.tap(opener);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('initialConsentAccept')), findsOneWidget);
          if (cancel) {
            await tester.tap(find.byKey(const Key('consentManageCancel')));
          } else {
            await tester.tapAt(const Offset(400, 20));
          }
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('initialConsentAccept')), findsNothing);
          expect(repo.saveCalls, 0);
          expect(repo.settings.cloudConsentState, st.$2);
          expect(repo.settings.aiConsentState, st.$3);
          expect(service.enableCalls + service.disableCalls, 0);
          expect(service.routeCalls, 0, reason: 'no protocol was even chosen');
          expect(service.syncCalls + service.retryCalls, 0);
        });
      }
    }

    for (final st in states) {
      for (final cancel in [true, false]) {
        testWidgets(
            'the disclosure opened directly: ${cancel ? 'cancel' : 'dismiss'} '
            'from ${st.$1} writes nothing', (tester) async {
          await tester.binding.setSurfaceSize(const Size(800, 2000));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          set(st.$2, st.$3);
          await tester.pumpWidget(consentApp(
            overrides: consentOverrides(repo, service,
                workSource: () => fakeConsentWork(isCurrent: () => current)),
            home: const _DirectOpener(),
          ));
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('initialConsentAccept')), findsOneWidget);
          if (cancel) {
            await tester.tap(find.byKey(const Key('consentManageCancel')));
          } else {
            await tester.tapAt(const Offset(400, 20));
          }
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('initialConsentAccept')), findsNothing);
          expect(repo.saveCalls, 0);
          expect(repo.settings.cloudConsentState, st.$2);
          expect(repo.settings.aiConsentState, st.$3);
          expect(service.enableCalls + service.disableCalls, 0);
          expect(service.routeCalls, 0);
          expect(service.syncCalls + service.retryCalls, 0);
        });
      }
    }
  });

  group('stale capability around each await of Accept', () {
    Future<void> openAndAccept(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(const Key('consentTurnOn')));
      await tester.tap(find.byKey(const Key('consentTurnOn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await tester.pumpAndSettle(const Duration(seconds: 6));
    }

    testWidgets('ending while the route is chosen: nothing runs, nothing is '
        'shown', (tester) async {
      set(ConsentState.accepted, ConsentState.declined);
      service.duringRoute = () => current = false;
      await pump(tester);
      await openAndAccept(tester);
      expect(service.routeCalls, 1);
      expect(service.enableCalls, 0);
      expect(repo.saveCalls, 0);
      expect(service.syncCalls + service.retryCalls, 0);
      expect(find.text(_en.setupSaveFailed), findsNothing);
      expect(find.text(_en.cloudEnableIncomplete), findsNothing);
      expect(find.text(_en.cloudEnableWithdrawFirst), findsNothing);
    });

    testWidgets('ending during the durable enable: no sync, no toast',
        (tester) async {
      service.enableError = const StaleAdmissionException();
      await pump(tester);
      await openAndAccept(tester);
      expect(service.enableCalls, 1);
      expect(service.syncCalls + service.retryCalls, 0);
      expect(find.text(_en.cloudEnableIncomplete), findsNothing);
      expect(repo.settings.cloudConsentState, ConsentState.unset);
    });

    testWidgets('ending before the first await: the Accept does nothing',
        (tester) async {
      set(ConsentState.accepted, ConsentState.declined);
      await pump(tester);
      await tester.ensureVisible(find.byKey(const Key('consentTurnOn')));
      await tester.tap(find.byKey(const Key('consentTurnOn')));
      await tester.pumpAndSettle();
      current = false;
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await tester.pumpAndSettle(const Duration(seconds: 6));
      expect(service.routeCalls, 0);
      expect(repo.saveCalls, 0);
      expect(service.syncCalls + service.retryCalls, 0);
    });
  });

  group('G5: the withdrawal scope is bound before the dialog', () {
    for (final switchUid in [false, true]) {
      testWidgets(
          switchUid
              ? 'a different-uid switch with a NEW valid capability: the old '
                  'confirmation changes nothing'
              : 'same-uid readmission with a NEW valid capability: the old '
                  'confirmation changes nothing', (tester) async {
        set(ConsentState.accepted, ConsentState.accepted);
        await pump(tester);
        await tester.ensureVisible(find.byKey(const Key('consentTurnOff')));
        await tester.tap(find.byKey(const Key('consentTurnOff')));
        await tester.pumpAndSettle();
        expect(find.text(_en.consentWithdrawBody), findsOneWidget);
        // The lifecycle the dialog was opened for ends; a successor is admitted
        // and its capability is valid RIGHT NOW.
        generation++;
        if (switchUid) uid = 'uid-other';
        await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
        await tester.pumpAndSettle();
        expect(service.disableCalls, 0);
        expect(service.enableCalls, 0);
        expect(service.syncCalls, 0);
        expect(repo.saveCalls, 0);
        expect(repo.settings.cloudConsentState, ConsentState.accepted);
        expect(repo.settings.aiConsentState, ConsentState.accepted);
        expect(find.text(_en.consentWithdrawFailed), findsNothing,
            reason: 'no stale toast into the successor');
      });
    }

    testWidgets('a confirmation inside the same lifecycle still withdraws',
        (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      await pump(tester);
      await tester.ensureVisible(find.byKey(const Key('consentTurnOff')));
      await tester.tap(find.byKey(const Key('consentTurnOff')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
      await tester.pumpAndSettle();
      expect(service.disableCalls, 1);
      expect(repo.settings.cloudConsentState, ConsentState.declined);
    });
  });

  group('confirmed withdrawal', () {
    Future<void> openWithdraw(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(const Key('consentTurnOff')));
      await tester.tap(find.byKey(const Key('consentTurnOff')));
      await tester.pumpAndSettle();
    }

    for (final start in <(ConsentState, ConsentState)>[
      (ConsentState.accepted, ConsentState.accepted),
      (ConsentState.accepted, ConsentState.declined),
      (ConsentState.declined, ConsentState.accepted),
    ]) {
      testWidgets('cancelling the confirmation keeps '
          '${start.$1.name}/${start.$2.name}', (tester) async {
        set(start.$1, start.$2);
        await pump(tester);
        await openWithdraw(tester);
        expect(find.text(_en.consentWithdrawBody), findsOneWidget);
        await tester.tap(find.text(_en.commonCancel));
        await tester.pumpAndSettle();
        expect(repo.saveCalls, 0);
        expect(service.disableCalls, 0);
        expect(repo.settings.cloudConsentState, start.$1);
        expect(repo.settings.aiConsentState, start.$2);
      });

      testWidgets('confirming turns BOTH off from ${start.$1.name}/${start.$2.name}',
          (tester) async {
        set(start.$1, start.$2);
        await pump(tester);
        await openWithdraw(tester);
        await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
        await tester.pumpAndSettle();
        expect(repo.settings.cloudConsentState, ConsentState.declined);
        expect(repo.settings.aiConsentState, ConsentState.declined);
        expect(repo.lastChoices!.cloud, ConsentState.declined);
        expect(repo.lastChoices!.ai, ConsentState.declined);
        expect(service.disableCalls, start.$1 == ConsentState.accepted ? 1 : 0,
            reason: 'the restrictive disable protocol for a Cloud ON -> OFF');
        expect(service.enableCalls, 0);
        expect(DiagnosticsConsentGate.allowed, isFalse);
      });
    }

    testWidgets('a failed server revoke still leaves everything OFF',
        (tester) async {
      final failing = _RevokeFailsService();
      service = failing;
      set(ConsentState.accepted, ConsentState.accepted);
      await pump(tester);
      await openWithdraw(tester);
      await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
      await tester.pumpAndSettle();
      expect(failing.revokeFailed, isTrue);
      expect(repo.settings.cloudConsentState, ConsentState.declined);
      expect(repo.settings.aiConsentState, ConsentState.declined);
    });

    testWidgets('local OFF after a failed revoke must stay unconfirmed',
        (tester) async {
      final failing = _RevokeFailsService();
      service = failing;
      set(ConsentState.accepted, ConsentState.accepted);
      await pump(tester);
      await openWithdraw(tester);
      facts = const ConsentLiveFacts(
          egressState: EgressState.off, serverOffPending: true);
      await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
      await tester.pumpAndSettle();
      expect(failing.revokeFailed, isTrue);
      expect(repo.settings.cloudProcessingEnabled, isFalse);
      expect(status(_en.consentStatusOff), findsNothing,
          reason: 'Supabase has not confirmed OFF');
    });

    testWidgets('a failed local OFF write is reported and never claimed as '
        'success', (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      await pump(tester);
      await openWithdraw(tester);
      repo.failSave = true;
      await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(_en.consentWithdrawFailed), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a lifecycle that ended before confirming changes nothing',
        (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      await pump(tester);
      await openWithdraw(tester);
      current = false;
      await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
      await tester.pumpAndSettle();
      expect(service.disableCalls, 0);
      expect(repo.saveCalls, 0);
      expect(repo.settings.cloudConsentState, ConsentState.accepted);
      expect(find.text(_en.consentWithdrawFailed), findsNothing);
    });

    testWidgets('a lifecycle that ends during the withdrawal reports nothing '
        'into the live scope', (tester) async {
      service = _StaleDuringDisable(() => current = false);
      set(ConsentState.accepted, ConsentState.accepted);
      await pump(tester);
      await openWithdraw(tester);
      await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
      await tester.pumpAndSettle();
      expect(find.text(_en.consentWithdrawFailed), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a stale view withdraws from the CURRENT stored row',
        (tester) async {
      set(ConsentState.accepted, ConsentState.accepted);
      await pump(tester);
      // Meanwhile cloud was already withdrawn elsewhere; AI is legacy-accepted.
      set(ConsentState.declined, ConsentState.accepted);
      await openWithdraw(tester);
      await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
      await tester.pumpAndSettle();
      expect(service.disableCalls, 0, reason: 'cloud was already off');
      expect(repo.settings.cloudConsentState, ConsentState.declined);
      expect(repo.settings.aiConsentState, ConsentState.declined);
    });
  });
}
