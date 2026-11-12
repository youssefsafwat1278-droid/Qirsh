import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/repositories/user_settings_repository.dart';
import 'package:money_companion/features/onboarding/restore_prompt_screen.dart';
import 'package:money_companion/features/onboarding/setup_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _SettingsRepository implements UserSettingsRepository {
  const _SettingsRepository();

  static const settings = UserSettingsEntity(
    id: 'settings',
    country: 'EG',
    currency: 'EGP',
    language: 'ar',
    theme: 'system',
    inputMethod: 'shortcut',
    notificationsJson: '',
    dbEncryptionKeyRef: '',
    privacyModeEnabled: false,
  );

  @override
  Future<UserSettingsEntity> getSettings() async => settings;

  @override
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity value) async =>
      value;
}

Widget _app(Widget home, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('ar'),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
    ),
  );
}

void main() {
  testWidgets('start fresh enters setup and starts at the first step',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(const RestorePromptScreen(onboardingFlow: true)),
    );
    await tester.ensureVisible(find.text('ابدأ جديد'));
    await tester.tap(find.text('ابدأ جديد'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(OnboardingSetupScreen), findsOneWidget);
    // The setup screen shows one step at a time now — a full entry starts
    // at step 0 (country/currency); the shortcut step isn't built yet.
    expect(find.text('دولتك وعملتك'), findsOneWidget);
    expect(find.text('ثبّت اختصار قِرش'), findsNothing);
  });

  testWidgets('restored entry starts at the device capture guide',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        const OnboardingSetupScreen(
          entry: OnboardingSetupEntry.captureGuide,
        ),
        overrides: [
          userSettingsRepositoryProvider.overrideWithValue(
            const _SettingsRepository(),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    // captureGuide pre-completes steps 0-1 and jumps straight to the
    // shortcut step, pre-filled with the restored currency. The currency
    // shows up inside the (horizontally scrolling) instructions carousel.
    expect(find.text('ثبّت اختصار قِرش'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('EGP'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    // Finish animations started when the carousel's cards enter the viewport.
    await tester.pumpAndSettle();
    expect(find.textContaining('EGP'), findsWidgets);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
