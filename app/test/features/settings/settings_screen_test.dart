import 'package:money_companion/l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/qirsh_visuals.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/settings/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('the «المزيد» hub shows every group and links each settings topic',
      (tester) async {
    // Tall viewport so the whole hub builds. Calm Capital v2 split the old
    // single scroll into a hub plus one-topic sub-pages; no tabs either way.
    tester.view.physicalSize = const Size(390, 4200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const settings = UserSettingsEntity(
      id: 'settings',
      displayName: 'يوسف',
      country: 'EG',
      currency: 'EGP',
      language: 'ar',
      theme: 'light',
      inputMethod: 'manual',
      notificationsJson: '{}',
      dbEncryptionKeyRef: 'test',
      privacyModeEnabled: false,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userSettingsProvider.overrideWith((ref) async => settings),
          notificationPreferencesProvider.overrideWith(
            (ref) async => const NotificationPreferences(),
          ),
          captureHealthStatusProvider.overrideWith(
            (ref) async => CaptureHealthStatus(
              lastCaptureAt: null,
              now: DateTime.utc(2026, 7, 18),
            ),
          ),
          supportedCountriesProvider.overrideWith((ref) async => const []),
          activeCurrenciesProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp(
          // SettingsScreen reads context.l10n (the SMS-capture trust
          // notice), so this harness has to supply delegates.
          locale: const Locale('ar'),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: const [
            ...AppL10n.localizationsDelegates,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: AppTheme.light,
          home: const Directionality(
            textDirection: TextDirection.rtl,
            child: SettingsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No back button on the root tab, and no tab switcher any more.
    expect(find.byTooltip('رجوع'), findsNothing);
    expect(
      find.byKey(const ValueKey('settings-tab-notifications')),
      findsNothing,
    );

    // The hub keeps every group (UX-029: destinations split from
    // configuration) and links each settings topic by name; the topics'
    // controls now live on their own sub-pages.
    for (final label in const [
      'حساباتك والتزاماتك',
      'أدوات',
      'تأكيد عملة الميزانيات والأهداف',
      'الإعدادات',
      'بيانات حسابك',
      'المظهر',
      'رصد العمليات',
      'تنبيهاتك',
      'نقل البيانات',
      'الأمان والخصوصية',
      'المكافآت والدعم',
      'تسجيل الخروج',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // Release builds never show the Developer group; debug builds hide it
    // behind a long-press on the version string.
    expect(find.text('Developer'), findsNothing);
    final l10n = AppL10n.of(tester.element(find.byType(SettingsScreen)));
    await tester.ensureVisible(find.text(l10n.setContactUs));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.setContactUs));
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((widget) => widget is QirshIllustration &&
        widget.name == 'help'), findsOneWidget);
    expect(find.text(l10n.setSupportBody), findsOneWidget);
    String? copiedEmail;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedEmail = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.tap(find.text(l10n.setCopyEmail));
    await tester.pumpAndSettle();
    expect(copiedEmail, 'support@money-companion.app');
    expect(find.text(l10n.setSupportBody), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('each hub link opens its sub-page with the same controls',
      (tester) async {
    tester.view.physicalSize = const Size(390, 4200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_host(const SettingsScreen()));
    await tester.pumpAndSettle();
    final l10n = AppL10n.of(tester.element(find.byType(SettingsScreen)));

    Future<void> openAndBack(String key, List<String> expected) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      for (final text in expected) {
        expect(find.text(text), findsWidgets, reason: '$key → $text');
      }
      await tester.tap(find.byTooltip('رجوع').last);
      await tester.pumpAndSettle();
    }

    await openAndBack('settings-page-account', [l10n.setLanguage]);
    await openAndBack('settings-page-appearance',
        [l10n.setThemeAuto, l10n.setThemeLight, l10n.setThemeDark]);
    await openAndBack('settings-page-capture', [
      l10n.setConfirmCaptured,
      l10n.setNotifyOnCapture,
      l10n.setHideOnLockScreen,
    ]);
    await openAndBack('settings-page-alerts', [
      l10n.setQirshMessages,
      l10n.setBudgetAlerts,
      l10n.setQuietHours,
      l10n.setTestNotifications,
      l10n.setMessageCentre,
    ]);
    await openAndBack('settings-page-security', [
      l10n.setPrivacyAndData,
      l10n.setHideAmounts,
      l10n.setAppLock,
      l10n.setDeleteAccount,
    ]);
    // The Android-only paragraph never shows off Android.
    await tester.tap(find.byKey(const ValueKey('settings-page-capture')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.smsCaptureTrustNotice), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pushed settings route pops without removing the root page',
      (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () => context.push('/settings'),
              child: const Text('open settings'),
            ),
          ),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => SettingsScreen(
            showBackButton: context.canPop(),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userSettingsProvider.overrideWith((ref) async => _settings),
          notificationPreferencesProvider.overrideWith(
            (ref) async => const NotificationPreferences(),
          ),
          captureHealthStatusProvider.overrideWith(
            (ref) async => CaptureHealthStatus(
              lastCaptureAt: null,
              now: DateTime.utc(2026, 7, 18),
            ),
          ),
          supportedCountriesProvider.overrideWith((ref) async => const []),
          activeCurrenciesProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp.router(
          // SettingsScreen reads context.l10n (the SMS-capture trust
          // notice), so this harness has to supply delegates.
          locale: const Locale('ar'),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: const [
            ...AppL10n.localizationsDelegates,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: AppTheme.light,
          routerConfig: router,
        ),
      ),
    );

    await tester.tap(find.text('open settings'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('رجوع'), findsOneWidget);

    await tester.tap(find.byTooltip('رجوع'));
    await tester.pumpAndSettle();

    expect(find.text('open settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

const _settings = UserSettingsEntity(
  id: 'settings',
  displayName: 'يوسف',
  country: 'EG',
  currency: 'EGP',
  language: 'ar',
  theme: 'light',
  inputMethod: 'manual',
  notificationsJson: '{}',
  dbEncryptionKeyRef: 'test',
  privacyModeEnabled: false,
);

Widget _host(Widget home) => ProviderScope(
      overrides: [
        userSettingsProvider.overrideWith((ref) async => _settings),
        notificationPreferencesProvider.overrideWith(
          (ref) async => const NotificationPreferences(),
        ),
        captureHealthStatusProvider.overrideWith(
          (ref) async => CaptureHealthStatus(
            lastCaptureAt: null,
            now: DateTime.utc(2026, 7, 18),
          ),
        ),
        supportedCountriesProvider.overrideWith((ref) async => const []),
        activeCurrenciesProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: const [
          ...AppL10n.localizationsDelegates,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AppTheme.light,
        home: home,
      ),
    );
