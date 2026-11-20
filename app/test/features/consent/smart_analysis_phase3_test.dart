import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/privacy/smart_analysis_consent.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/features/settings/privacy_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../harness/egress_test_support.dart';
import 'consent_test_harness.dart';

/// Gemini-first phase 3 (owner decision 2026-11-20): "Gemini is always
/// available in the app, separated from Cloud." The Smart Analysis consent on
/// its own, its switch in Privacy, and the wording version.
void main() {
  late FakeSettingsRepository repo;
  late FakeRegistrationService service;
  late Map<String, String> records;
  late SmartAnalysisConsentRecord record;

  setUp(() {
    repo = FakeSettingsRepository();
    service = FakeRegistrationService();
    records = {};
    record = SmartAnalysisConsentRecord.memory(records);
    TestEgress().install(); // Cloud never enabled: the Cloud gate denies
  });

  List<Override> overrides({bool ownLane = true}) => [
        ...consentOverrides(repo, service),
        smartAnalysisConsentRecordProvider.overrideWithValue(record),
        smartAnalysisOwnLaneProvider.overrideWithValue(ownLane),
        merchantOffersEnabledProvider.overrideWithValue(false),
      ];

  group('the Smart Analysis consent on its own', () {
    bool? done;

    Future<void> pumpPanel(WidgetTester tester, {String locale = 'en'}) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      done = null;
      await tester.pumpWidget(consentApp(
        overrides: overrides(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: SmartAnalysisConsentPanel(
                    smartAnalysisOnly: true, onDone: (v) => done = v))),
        locale: locale,
      ));
      await tester.pumpAndSettle();
    }

    for (final locale in ['en', 'ar']) {
      testWidgets('$locale: what, to whom, why, optional, how to turn off; '
          'Allow and Not now equal; nothing on yet', (tester) async {
        await pumpPanel(tester, locale: locale);
        final l = AppL10n.of(
            tester.element(find.byType(SmartAnalysisConsentPanel)));
        for (final text in [
          l.smartOnlyTitle,
          l.smartOnlyIntro,
          l.smartConsentHeadSent,
          l.smartOnlySent,
          l.smartConsentHeadWho,
          l.smartOnlyWho,
          l.smartConsentHeadWhy,
          l.smartOnlyWhy,
          l.smartOnlyHeadOptional,
          l.smartOnlyOptional,
          l.smartConsentHeadOff,
          l.smartOnlyOff,
          l.smartOnlyAllow,
          l.smartConsentNotNow,
        ]) {
          expect(find.text(text), findsOneWidget, reason: text);
        }
        expect(l.smartOnlyWho, contains('Gemini'));
        // The combined Cloud disclosure is not what is shown here.
        expect(find.text(l.smartConsentWho), findsNothing);
        expect(tester.getSize(find.byKey(const Key('smartOnlyNotNow'))),
            tester.getSize(find.byKey(const Key('smartOnlyAllow'))));
        expect(repo.saveCalls, 0);
        expect(repo.settings.aiConsentState, ConsentState.unset);
      });
    }

    testWidgets('Allow turns on Smart Analysis only, records the wording, '
        'connects the device; Cloud untouched', (tester) async {
      await pumpPanel(tester);
      await tester.ensureVisible(find.byKey(const Key('smartOnlyAllow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('smartOnlyAllow')));
      await tester.pumpAndSettle();
      expect(repo.settings.aiConsentState, ConsentState.accepted);
      expect(repo.settings.cloudConsentState, ConsentState.unset);
      expect(repo.lastChoices?.cloud, isNull, reason: 'Cloud is not written');
      expect(service.enableCalls, 0, reason: 'no Cloud enable');
      expect(await record.acceptedVersion('uid-fake'),
          kSmartAnalysisConsentVersion);
      expect(service.retryCalls, 1);
      expect(done, isTrue);
      expect(
          ConsentAuthority.decide(EgressClass.smartAnalysis, repo.settings),
          isTrue);
      expect(ConsentAuthority.decide(EgressClass.financialSync, repo.settings),
          isFalse);
    });

    testWidgets('Not now writes nothing and sends nothing', (tester) async {
      await pumpPanel(tester);
      await tester.ensureVisible(find.byKey(const Key('smartOnlyNotNow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('smartOnlyNotNow')));
      await tester.pumpAndSettle();
      expect(repo.saveCalls, 0);
      expect(service.retryCalls, 0);
      expect(records, isEmpty);
      expect(done, isFalse);
      expect(
          ConsentAuthority.decide(EgressClass.smartAnalysis, repo.settings),
          isFalse);
    });

    testWidgets('a failed save grants nothing', (tester) async {
      await pumpPanel(tester);
      repo.failSave = true;
      await tester.ensureVisible(find.byKey(const Key('smartOnlyAllow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('smartOnlyAllow')));
      await tester.pumpAndSettle();
      expect(repo.settings.aiConsentState, ConsentState.unset);
      expect(done, isNull);
      await tester.pump(const Duration(seconds: 4)); // the error toast leaves
    });
  });

  group('the Smart Analysis switch in Privacy', () {
    Future<void> pumpPrivacy(WidgetTester tester, {bool ownLane = true}) async {
      await tester.binding.setSurfaceSize(const Size(800, 3200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(consentApp(
        overrides: overrides(ownLane: ownLane),
        home: const PrivacyScreen(),
      ));
      await tester.pumpAndSettle();
    }

    Switch switchOf(WidgetTester tester) => tester.widget<Switch>(find.descendant(
        of: find.byKey(const Key('smartAnalysisSwitch')),
        matching: find.byType(Switch)));

    testWidgets('Cloud OFF: shows OFF; turning it on asks first, Allow turns '
        'it on (Cloud stays off)', (tester) async {
      await pumpPrivacy(tester);
      expect(switchOf(tester).value, isFalse);
      await tester.ensureVisible(find.byKey(const Key('smartAnalysisSwitch')));
      await tester.tap(find.byKey(const Key('smartAnalysisSwitch')));
      await tester.pumpAndSettle();
      expect(repo.saveCalls, 0, reason: 'nothing on before Allow');
      expect(find.byKey(const Key('smartOnlyAllow')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('smartOnlyAllow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('smartOnlyAllow')));
      await tester.pumpAndSettle();
      expect(repo.settings.aiConsentGranted, isTrue);
      expect(repo.settings.cloudProcessingEnabled, isFalse);
      expect(switchOf(tester).value, isTrue);
    });

    testWidgets('dismissing the consent leaves it off', (tester) async {
      await pumpPrivacy(tester);
      await tester.ensureVisible(find.byKey(const Key('smartAnalysisSwitch')));
      await tester.tap(find.byKey(const Key('smartAnalysisSwitch')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('smartOnlyNotNow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('smartOnlyNotNow')));
      await tester.pumpAndSettle();
      expect(repo.saveCalls, 0);
      expect(switchOf(tester).value, isFalse);
    });

    testWidgets('turning it off stops native sending BEFORE the choice is '
        'committed, keeps Cloud as it is and deletes nothing', (tester) async {
      repo.settings = repo.settings.copyWith(
          cloudConsentState: ConsentState.accepted,
          aiConsentState: ConsentState.accepted);
      await pumpPrivacy(tester);
      expect(switchOf(tester).value, isTrue);
      await tester.ensureVisible(find.byKey(const Key('smartAnalysisSwitch')));
      await tester.tap(find.byKey(const Key('smartAnalysisSwitch')));
      await tester.pumpAndSettle();
      expect(service.restrictSeen, [true],
          reason: 'the App Intent is stopped while consent still reads on');
      expect(repo.settings.aiConsentState, ConsentState.declined);
      expect(repo.settings.cloudConsentState, ConsentState.accepted);
      expect(service.disableCalls, 0, reason: 'Cloud is not turned off');
      expect(service.syncCalls, greaterThan(0),
          reason: 'the server copy is narrowed by the sync');
      expect(switchOf(tester).value, isFalse);
    });

    testWidgets('Cloud OFF with Smart Analysis on: the Cloud card no longer '
        'claims nothing is analysed', (tester) async {
      repo.settings = repo.settings.copyWith(
          cloudConsentState: ConsentState.declined,
          aiConsentState: ConsentState.accepted);
      await record.recordAccepted('uid-fake');
      await pumpPrivacy(tester);
      final l = AppL10n.of(tester.element(find.byType(PrivacyScreen)));
      expect(find.text(l.consentStatusOffSmartOnBody), findsOneWidget);
      expect(find.text(l.consentStatusOffBody), findsNothing);
      expect(switchOf(tester).value, isTrue);
    });

    testWidgets('a dormant pre-phase-3 AI choice (Cloud OFF, no wording) '
        'reads OFF: nothing is analysed for it until Allow', (tester) async {
      repo.settings = repo.settings.copyWith(
          cloudConsentState: ConsentState.declined,
          aiConsentState: ConsentState.accepted);
      await pumpPrivacy(tester);
      final l = AppL10n.of(tester.element(find.byType(PrivacyScreen)));
      expect(switchOf(tester).value, isFalse);
      expect(find.text(l.consentStatusOffBody), findsOneWidget);
    });

    testWidgets('without the lane (Android) it needs Cloud and cannot be '
        'turned on alone', (tester) async {
      await pumpPrivacy(tester, ownLane: false);
      final l = AppL10n.of(tester.element(find.byType(PrivacyScreen)));
      expect(find.text(l.smartConsentAiNeedsCloud), findsOneWidget);
      expect(switchOf(tester).onChanged, isNull);
    });
  });

  group('the wording version', () {
    final accepted = FakeSettingsRepository().settings.copyWith(
        cloudConsentState: ConsentState.declined,
        aiConsentState: ConsentState.accepted);

    test('a recorded older version needs consent again; the current does not',
        () async {
      await record.recordAccepted('uid-a', version: 1);
      expect(await record.needsReconsent('uid-a', accepted, current: 1),
          isFalse);
      expect(await record.needsReconsent('uid-a', accepted, current: 2),
          isTrue);
      await record.recordAccepted('uid-a', version: 2);
      expect(await record.needsReconsent('uid-a', accepted, current: 2),
          isFalse);
    });

    test('no consent, no question; an unreadable store never re-asks',
        () async {
      final off = accepted.copyWith(aiConsentState: ConsentState.declined);
      expect(await record.needsReconsent('uid-a', off, current: 2), isFalse);
      final broken = SmartAnalysisConsentRecord(
          read: (_) async => throw StateError('keychain'),
          write: (_, __) async {});
      expect(await broken.needsReconsent('uid-a', accepted, current: 2),
          isFalse);
    });

    testWidgets('a version bump turns Smart Analysis off first, then asks once',
        (tester) async {
      repo.settings = accepted;
      await record.recordAccepted('uid-fake', version: 1);
      late WidgetRef widgetRef;
      await tester.pumpWidget(consentApp(
        overrides: overrides(),
        home: Consumer(builder: (context, ref, _) {
          widgetRef = ref;
          return const Scaffold(body: SizedBox());
        }),
      ));
      final context = tester.element(find.byType(Scaffold));
      final outcome = maybeReaskConsent(context, widgetRef,
          smartAnalysisVersion: 2,
          seen: () async => false,
          markSeen: () async {});
      await tester.pumpAndSettle();
      expect(service.restrictSeen, [true]);
      expect(repo.settings.aiConsentState, ConsentState.declined,
          reason: 'the old consent no longer counts: sending stops');
      expect(find.byKey(const Key('smartOnlyAllow')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('smartOnlyAllow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('smartOnlyAllow')));
      await tester.pumpAndSettle();
      expect(await outcome, ReaskOutcome.shown);
      expect(repo.settings.aiConsentState, ConsentState.accepted);
      expect(await record.acceptedVersion('uid-fake'),
          kSmartAnalysisConsentVersion);
    });
  });
}
