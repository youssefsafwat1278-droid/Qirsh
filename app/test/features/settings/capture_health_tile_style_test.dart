import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/settings/settings_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

const _settings = UserSettingsEntity(
  id: 'settings',
  displayName: 'Synthetic',
  country: 'SA',
  currency: 'SAR',
  language: 'en',
  theme: 'light',
  inputMethod: 'manual',
  notificationsJson: '{}',
  dbEncryptionKeyRef: 'test',
  privacyModeEnabled: false,
);

// UX-16: before any bank message is captured, the capture status must not
// wear the green "success" shield.
void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final captured in [false, true]) {
    testWidgets('capture status styling, captured=$captured', (tester) async {
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final now = DateTime.utc(2026, 7, 18);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          userSettingsProvider.overrideWith((ref) async => _settings),
          notificationPreferencesProvider
              .overrideWith((ref) async => const NotificationPreferences()),
          captureHealthStatusProvider.overrideWith((ref) async =>
              CaptureHealthStatus(
                  lastCaptureAt:
                      captured ? now.subtract(const Duration(hours: 2)) : null,
                  now: now)),
          supportedCountriesProvider.overrideWith((ref) async => const []),
          activeCurrenciesProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          theme: AppTheme.light,
          home: const SettingsScreen(page: SettingsPage.capture),
        ),
      ));
      await tester.pumpAndSettle();
      final l10n = AppL10n.of(tester.element(find.byType(SettingsScreen)));
      expect(find.text(l10n.setBankCaptureStatus), findsOneWidget);
      final shield = find.byIcon(AppLucideIcons.shieldCheck);
      final info = find.byIcon(AppLucideIcons.info);
      if (captured) {
        expect(shield, findsOneWidget);
      } else {
        expect(shield, findsNothing);
        expect(info, findsOneWidget);
        expect(tester.widget<Icon>(info).color, AppColors.light.actionText);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
