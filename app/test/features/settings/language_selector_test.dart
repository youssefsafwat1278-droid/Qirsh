import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/usecases/user_settings_usecases.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/settings/settings_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// REACHABILITY, which is the half the localization work was missing.
///
/// Qirsh ships Arabic and English, and the English ARB, widgets and captures
/// were all complete. But `SaveLanguageUseCase` — the only code in `lib/` that
/// writes `user_settings.language` — had zero callers, and the column is
/// created as `'ar'`. There was no control in Settings, no onboarding step, no
/// migration and nothing seeding from the device locale. Every user therefore
/// ran in Arabic permanently, and the English half of the product was
/// unreachable from inside the app: shipped, verified, and impossible to see.
///
/// These tests are about the path, not the strings. They fail if the control
/// disappears, stops offering a language, or stops going through the app's
/// real write path.
UserSettingsEntity _settings(String language) => UserSettingsEntity(
      id: 'settings',
      country: 'SA',
      currency: 'SAR',
      language: language,
      theme: 'light',
      inputMethod: 'manual',
      notificationsJson: '{}',
      privacyModeEnabled: false,
    );

class _RecordingSaveLanguage implements SaveLanguageUseCase {
  final List<String> saved = <String>[];

  @override
  Future<UserSettingsEntity> call(String language) async {
    saved.add(language);
    return _settings(language);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<_RecordingSaveLanguage> pumpSettings(
    WidgetTester tester, {
    required String language,
  }) async {
    // Tall viewport: the settings list is one scroll and the tile has to be
    // built to be tapped.
    tester.view.physicalSize = const Size(390, 4200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final recorder = _RecordingSaveLanguage();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userSettingsProvider.overrideWith((ref) async => _settings(language)),
          saveLanguageUseCaseProvider.overrideWithValue(recorder),
          notificationPreferencesProvider
              .overrideWith((ref) async => const NotificationPreferences()),
          captureHealthStatusProvider.overrideWith(
            (ref) async => CaptureHealthStatus(
              lastCaptureAt: null,
              now: DateTime.utc(2026, 9, 18),
            ),
          ),
          supportedCountriesProvider.overrideWith((ref) async => const []),
          activeCurrenciesProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp(
          locale: Locale(language),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: const [
            ...AppL10n.localizationsDelegates,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: AppTheme.light,
          // v2: Language lives on the «بيانات حسابك» sub-page.
          home: const SettingsScreen(page: SettingsPage.account),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return recorder;
  }

  testWidgets('Settings offers Language, showing the one in use',
      (tester) async {
    await pumpSettings(tester, language: 'ar');
    final ar = await AppL10n.delegate.load(const Locale('ar'));
    expect(find.text(ar.setLanguage), findsOneWidget);
    // The endonym, not a translation: a reader looking for their own language
    // looks for its own name.
    expect(find.text('العربية'), findsOneWidget);
  });

  testWidgets('choosing English goes through the app\'s real write path',
      (tester) async {
    final recorder = await pumpSettings(tester, language: 'ar');
    final ar = await AppL10n.delegate.load(const Locale('ar'));

    await tester.tap(find.text(ar.setLanguage));
    await tester.pumpAndSettle();

    // Both languages are offered, each in its own name.
    expect(find.text('English'), findsOneWidget);
    expect(find.text('العربية'), findsWidgets);

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    // `SaveLanguageUseCase`, not a bespoke write: it is what carries the value
    // to `user_settings.language` AND mirrors it for the unlock prompt.
    expect(recorder.saved, ['en']);
  });

  testWidgets('and back again, from an English app', (tester) async {
    final recorder = await pumpSettings(tester, language: 'en');
    final en = await AppL10n.delegate.load(const Locale('en'));

    expect(find.text('English'), findsOneWidget);
    await tester.tap(find.text(en.setLanguage));
    await tester.pumpAndSettle();
    await tester.tap(find.text('العربية').last);
    await tester.pumpAndSettle();

    expect(recorder.saved, ['ar']);
  });

  test('the saved value is what the app resolves its locale from', () {
    // The other end of the wire: what Settings writes is what `localeProvider`
    // reads, so the choice reaches the whole tree — copy, direction, pickers
    // and the material delegates alike — without a restart.
    for (final language in const ['ar', 'en']) {
      final container = ProviderContainer(overrides: [
        userSettingsProvider.overrideWith((ref) async => _settings(language)),
      ]);
      addTearDown(container.dispose);
      container.listen(userSettingsProvider, (_, __) {});
      expect(
        container.read(userSettingsProvider.future).then(
            (_) => container.read(localeProvider).languageCode),
        completion(language),
      );
    }
  });
}
