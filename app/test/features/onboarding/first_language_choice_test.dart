import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/core/security/lock_prompt_language.dart';
import 'package:money_companion/core/startup/install_presentation_store.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/repositories/user_settings_repository.dart';
import 'package:money_companion/domain/usecases/user_settings_usecases.dart';
import 'package:money_companion/features/onboarding/language_screen.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Settings implements UserSettingsRepository {
  _Settings(String language)
      : value = UserSettingsEntity(
          id: 'settings',
          country: 'EG',
          currency: 'EGP',
          language: language,
          theme: 'system',
          inputMethod: 'manual',
          notificationsJson: '{}',
          privacyModeEnabled: false,
        );
  UserSettingsEntity value;
  @override
  Future<UserSettingsEntity> getSettings() async => value;
  @override
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity settings) async =>
      value = settings;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(WidgetTester tester, _Settings settings) async {
  final router = GoRouter(routes: [
    GoRoute(
        path: '/', builder: (_, __) => const OnboardingLanguageScreen()),
    GoRoute(
        path: '/welcome', builder: (_, __) => const Text('welcome-reached')),
  ]);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      userSettingsProvider.overrideWith((ref) => settings.getSettings()),
      saveLanguageUseCaseProvider
          .overrideWithValue(SaveLanguageUseCase(settings)),
    ],
    child: Consumer(
        builder: (context, ref, _) => MaterialApp.router(
              routerConfig: router,
              locale: ref.watch(localeProvider),
              supportedLocales: AppL10n.supportedLocales,
              localizationsDelegates: AppL10n.localizationsDelegates,
            )),
  ));
  await tester.pumpAndSettle();
}

FilledButton _continue(WidgetTester tester) => tester.widget<FilledButton>(
    find.byKey(const ValueKey('language-first-continue')));

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('first launch: nothing preselected and Continue is disabled',
      (tester) async {
    await _pump(tester, _Settings('en'));
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing,
        reason: 'no language may be preselected');
    expect(find.byIcon(Icons.circle_outlined), findsNWidgets(2));
    expect(_continue(tester).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('language-first-continue')));
    await tester.pumpAndSettle();
    expect(find.text('welcome-reached'), findsNothing);
  });

  for (final code in ['ar', 'en']) {
    testWidgets('choosing $code enables Continue and persists the choice',
        (tester) async {
      final settings = _Settings(code == 'ar' ? 'en' : 'ar');
      await _pump(tester, settings);
      await tester.tap(find.byKey(ValueKey('language-first-$code')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(_continue(tester).onPressed, isNotNull);
      final context =
          tester.element(find.byKey(const ValueKey('language-first-continue')));
      expect(Directionality.of(context),
          code == 'ar' ? TextDirection.rtl : TextDirection.ltr);
      await tester.tap(find.byKey(const ValueKey('language-first-continue')));
      await tester.pumpAndSettle();
      expect(settings.value.language, code);
      expect(await LockPromptLanguage.read(), code);
      expect(find.text('welcome-reached'), findsOneWidget);
    });
  }

  testWidgets(
      'an existing user who reaches the screen keeps the language they were '
      'seeing until they choose', (tester) async {
    final settings = _Settings('ar');
    await _pump(tester, settings);
    final context =
        tester.element(find.byKey(const ValueKey('language-first-continue')));
    expect(Directionality.of(context), TextDirection.rtl);
    expect(settings.value.language, 'ar');
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
  });

  group('upgrade: install marker written before languageChosen existed', () {
    late Directory root;
    setUp(() async =>
        root = await Directory.systemTemp.createTemp('qirsh-lang-upgrade-'));
    tearDown(() => root.delete(recursive: true));

    Future<InstallPresentationStore> open(bool requiresSetup) async {
      final file = File('${root.path}/presentation.json');
      await file.writeAsString(jsonEncode({
        'version': 1,
        'requiresSetup': requiresSetup,
        'resetPending': false,
      }));
      final store = InstallPresentationStore(file);
      await store.prepare(
          hasExistingData: () async => fail('marker exists'),
          resetPresentation: () async => fail('no reset on upgrade'));
      return store;
    }

    test('a completed install is never sent back to the language screen',
        () async {
      expect((await open(false)).languageChosen, isTrue);
    });

    test('an install still in setup is asked, with nothing preselected',
        () async {
      expect((await open(true)).languageChosen, isFalse);
    });

    test('an install with data but no marker keeps its language', () async {
      final store = InstallPresentationStore(File('${root.path}/none.json'));
      await store.prepare(
          hasExistingData: () async => true,
          resetPresentation: () async => fail('no reset on upgrade'));
      expect(store.languageChosen, isTrue);
    });
  });
}
