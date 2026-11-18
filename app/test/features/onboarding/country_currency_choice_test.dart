import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/usecases/user_settings_usecases.dart';
import 'package:money_companion/features/onboarding/setup_screen.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/settings/settings_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../consent/consent_test_harness.dart';

// A country whose ISO currency the app cannot store asks for an explicit
// currency from the storable set, in onboarding and in Settings. Nothing is
// saved until the user chooses; a storable default is saved directly.
//
// Closure round, decision 3.7: stored money now holds every ISO-4217 currency
// (kCurrencyScale), so every country but Antarctica (no currency) has a
// storable default. Norway, which used to ask, now saves NOK directly.

class _RecordingSave implements SaveCountryCurrencyUseCase {
  final calls = <(String, String)>[];
  @override
  Future<UserSettingsEntity> call(String country, String currency) async {
    calls.add((country, currency));
    return FakeSettingsRepository().settings;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _RecordingSave save;

  Future<void> openOnboarding(WidgetTester tester, String locale) async {
    await tester.binding.setSurfaceSize(const Size(800, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repo = FakeSettingsRepository();
    await tester.pumpWidget(consentApp(
      locale: locale,
      overrides: [
        ...consentOverrides(repo, FakeRegistrationService()),
        saveCountryCurrencyUseCaseProvider.overrideWithValue(save),
      ],
      home: const OnboardingSetupScreen(),
    ));
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> pickCountry(WidgetTester tester, Finder field, String search,
      String code) async {
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('country-search')), search);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('country-$code')));
    await tester.pumpAndSettle();
  }

  setUp(() => save = _RecordingSave());

  for (final locale in ['en', 'ar']) {
    testWidgets('onboarding ($locale): Norway saves NOK without asking',
        (tester) async {
      await openOnboarding(tester, locale);
      await pickCountry(tester,
          find.byKey(const ValueKey('setup-country-field')), 'Norway', 'NO');
      expect(find.byKey(const ValueKey('currency-choice-sheet')), findsNothing);
      expect(save.calls, [('NO', 'NOK')]);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('onboarding: dismissing the currency choice saves nothing',
      (tester) async {
    await openOnboarding(tester, 'en');
    await pickCountry(tester,
        find.byKey(const ValueKey('setup-country-field')), 'Antarctica', 'AQ');
    expect(find.byKey(const ValueKey('currency-choice-sheet')), findsOneWidget);
    await tester.tapAt(const Offset(400, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('currency-choice-sheet')), findsNothing);
    expect(save.calls, isEmpty);
    expect(find.text('Step 1 of 6'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('onboarding: Antarctica (no currency) asks too', (tester) async {
    await openOnboarding(tester, 'en');
    final l = lookupAppL10n(const Locale('en'));
    await pickCountry(tester,
        find.byKey(const ValueKey('setup-country-field')), 'Antarctica', 'AQ');
    expect(find.text(l.currencyChoiceNoCurrencyBody), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('currency-AED')));
    await tester.pumpAndSettle();
    expect(save.calls, [('AQ', 'AED')]);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('onboarding: Egypt saves its storable default without asking',
      (tester) async {
    await openOnboarding(tester, 'en');
    await pickCountry(tester,
        find.byKey(const ValueKey('setup-country-field')), 'Egypt', 'EG');
    expect(find.byKey(const ValueKey('currency-choice-sheet')), findsNothing);
    expect(save.calls, [('EG', 'EGP')]);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  group('Settings', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    Future<void> openSettings(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repo = FakeSettingsRepository();
      await tester.pumpWidget(consentApp(
        overrides: [
          ...consentOverrides(repo, FakeRegistrationService()),
          saveCountryCurrencyUseCaseProvider.overrideWithValue(save),
          notificationPreferencesProvider
              .overrideWith((ref) async => const NotificationPreferences()),
          captureHealthStatusProvider.overrideWith((ref) async =>
              CaptureHealthStatus(lastCaptureAt: null, now: DateTime.utc(2026))),
          supportedCountriesProvider.overrideWith((ref) async => const []),
          activeCurrenciesProvider.overrideWith((ref) async => const []),
        ],
        home: const SettingsScreen(page: SettingsPage.account),
      ));
      await tester.pumpAndSettle();
    }

    Finder countryTile() =>
        find.text(lookupAppL10n(const Locale('en')).setCountry);

    testWidgets('changing to Norway saves NOK without asking', (tester) async {
      await openSettings(tester);
      await pickCountry(tester, countryTile(), 'Norway', 'NO');
      expect(find.byKey(const ValueKey('currency-choice-sheet')), findsNothing);
      expect(save.calls, [('NO', 'NOK')]);
    });

    testWidgets('changing to Antarctica asks for a storable currency',
        (tester) async {
      await openSettings(tester);
      await pickCountry(tester, countryTile(), 'Antarctica', 'AQ');
      expect(find.byKey(const ValueKey('currency-choice-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('currency-AED')));
      await tester.pumpAndSettle();
      expect(save.calls, [('AQ', 'AED')]);
    });

    testWidgets('dismissing the choice keeps the country unchanged',
        (tester) async {
      await openSettings(tester);
      await pickCountry(tester, countryTile(), 'Antarctica', 'AQ');
      expect(find.byKey(const ValueKey('currency-choice-sheet')), findsOneWidget);
      await tester.tapAt(const Offset(400, 10));
      await tester.pumpAndSettle();
      expect(save.calls, isEmpty);
    });

    testWidgets('changing to Kuwait saves its storable default',
        (tester) async {
      await openSettings(tester);
      await pickCountry(tester, countryTile(), 'Kuwait', 'KW');
      expect(find.byKey(const ValueKey('currency-choice-sheet')), findsNothing);
      expect(save.calls, [('KW', 'KWD')]);
    });
  });
}
