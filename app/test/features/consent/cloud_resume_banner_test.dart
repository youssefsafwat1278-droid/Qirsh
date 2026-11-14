import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';
import 'package:money_companion/core/privacy/cloud_resume_reminder.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/consent/cloud_resume_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'consent_test_harness.dart';

void main() {
  late FakeSettingsRepository repo;
  late FakeRegistrationService service;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CloudResumeBannerDebug.reset();
    repo = FakeSettingsRepository();
    repo.settings = repo.settings.copyWith(
        cloudConsentState: ConsentState.declined, cloudConsentVersion: 2);
    service = FakeRegistrationService();
  });

  Future<void> pump(WidgetTester tester, {String language = 'en',
      bool dark = false, bool pending = true, double scale = 1}) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (pending) await CloudResumeReminder().rememberPaused('uid-fake', repo.settings);
    await tester.pumpWidget(consentApp(overrides: consentOverrides(repo, service),
      locale: language,
      home: Theme(data: dark ? AppTheme.dark : AppTheme.light,
        child: MediaQuery(data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: const Scaffold(body: SingleChildScrollView(child: CloudResumeBanner(autoResume: false)))))));
    await tester.pumpAndSettle();
  }

  for (final language in ['en', 'ar']) {
    for (final dark in [false, true]) {
      testWidgets('resume hint is legible at large text: $language dark=$dark', (tester) async {
        await pump(tester, language: language, dark: dark, scale: 1.8);
        expect(find.byKey(const Key('cloudResumeEnable')), findsOneWidget);
        expect(find.byKey(const Key('cloudResumeDismiss')), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(service.enableCalls, 0);
        expect(repo.saveCalls, 0);
      });
    }
  }

  test('a cached ON UI snapshot cannot discard a newly committed pause', () async {
    await CloudResumeReminder().rememberPaused('uid-fake', repo.settings);
    final container = ProviderContainer(overrides: [
      userSettingsRepositoryProvider.overrideWithValue(repo),
      userSettingsProvider.overrideWith((_) async => repo.settings.copyWith(
          cloudConsentState: ConsentState.accepted, cloudConsentVersion: 1)),
      consentLocalWorkProvider.overrideWithValue(() =>
          fakeConsentWork(isCurrent: () => true)),
    ]);
    addTearDown(container.dispose);
    await container.read(userSettingsProvider.future); // already cached ON
    expect(await container.read(cloudResumeReminderProvider.future), 'uid-fake');
    expect(await CloudResumeReminder().shouldShow('uid-fake', repo.settings), isTrue);
  });

  testWidgets('a hint read before admission appears once sign-in publishes', (tester) async {
    await CloudResumeReminder().rememberPaused('uid-fake', repo.settings);
    final session = AppSession.instance;
    final prior = session.status;
    addTearDown(() => session.value = prior);
    session.value = SessionStatus.needsOnboarding;
    var admitted = false;
    await tester.pumpWidget(consentApp(overrides: [
      userSettingsRepositoryProvider.overrideWithValue(repo),
      userSettingsProvider.overrideWith((_) => repo.getSettings()),
      consentLocalWorkProvider.overrideWithValue(() => admitted
          ? fakeConsentWork(isCurrent: () => true) : null),
    ], home: const Scaffold(body: CloudResumeBanner())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cloudResumeEnable')), findsNothing);
    admitted = true;
    session.value = SessionStatus.authenticated;
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cloudResumeEnable')), findsOneWidget);
    expect(repo.saveCalls, 0);
  });

  testWidgets('never-enabled user sees no banner', (tester) async {
    await pump(tester, pending: false);
    expect(find.byKey(const Key('cloudResumeEnable')), findsNothing);
    expect(repo.saveCalls, 0);
  });

  testWidgets('close dismisses only the hint, with no permission change', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('cloudResumeDismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cloudResumeEnable')), findsNothing);
    expect(await CloudResumeReminder().shouldShow('uid-fake', repo.settings), isFalse);
    expect(repo.saveCalls, 0);
    expect(service.enableCalls, 0);
  });

  testWidgets('review opens the existing disclosure; cancel grants nothing', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('cloudResumeEnable')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('initialConsentAccept')), findsOneWidget);
    expect(service.enableCalls, 0);
    await tester.tap(find.byKey(const Key('consentManageCancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cloudResumeEnable')), findsOneWidget);
    expect(repo.saveCalls, 0);
  });

  testWidgets('explicit approval uses the typed enable and removes the hint', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('cloudResumeEnable')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await tester.pumpAndSettle();
    expect(service.enableCalls, 1);
    expect(repo.settings.cloudConsentState, ConsentState.accepted);
    expect(find.byKey(const Key('cloudResumeEnable')), findsNothing);
    expect(await CloudResumeReminder().shouldShow('uid-fake', repo.settings), isFalse);
  });

  group('automatic resume of an app-made pause (owner decision 2026-11-14)', () {
    Future<void> pumpAuto(WidgetTester tester, {bool aiWasOn = false}) async {
      await CloudResumeReminder()
          .rememberPaused('uid-fake', repo.settings, aiWasOn: aiWasOn);
      await tester.pumpWidget(consentApp(
          overrides: consentOverrides(repo, service),
          home: const Scaffold(
              body: SingleChildScrollView(child: CloudResumeBanner()))));
      await tester.pumpAndSettle();
    }

    testWidgets('Cloud comes back ON through the typed enable, no tap',
        (tester) async {
      await pumpAuto(tester);
      expect(service.enableCalls, 1);
      expect(repo.settings.cloudConsentState, ConsentState.accepted);
      expect(find.byKey(const Key('cloudResumeEnable')), findsNothing);
      expect(await CloudResumeReminder().shouldShow('uid-fake', repo.settings),
          isFalse);
    });

    testWidgets('AI that was ON before the pause comes back ON too',
        (tester) async {
      repo.settings =
          repo.settings.copyWith(aiConsentState: ConsentState.declined);
      await pumpAuto(tester, aiWasOn: true);
      expect(repo.settings.cloudConsentState, ConsentState.accepted);
      expect(repo.settings.aiConsentState, ConsentState.accepted);
    });

    testWidgets('a failed resume keeps the one-tap banner and is not retried',
        (tester) async {
      service.enableError = StateError('native_unconfirmed');
      await pumpAuto(tester);
      expect(service.enableCalls, 1);
      expect(repo.settings.cloudConsentState, ConsentState.declined);
      expect(find.byKey(const Key('cloudResumeEnable')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(service.enableCalls, 1);
    });

    testWidgets("the user's own OFF (no reminder) is never turned back on",
        (tester) async {
      await tester.pumpWidget(consentApp(
          overrides: consentOverrides(repo, service),
          home: const Scaffold(body: CloudResumeBanner())));
      await tester.pumpAndSettle();
      expect(service.enableCalls, 0);
      expect(repo.saveCalls, 0);
    });
  });
}
