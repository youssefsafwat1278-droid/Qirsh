import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/reports/reports_providers.dart';
import 'package:money_companion/features/reports/reports_screen.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

ReportSection _empty() => ReportSection(
  total: Money.zero('SAR'), prevTotal: Money.zero('SAR'), refunds: Money.zero('SAR'),
  topCategories: const [], topMerchants: const [], dailySpend: const [], anomaly: null,
);

// UX-12: a new user's Reports overview shows guidance, not a blank page.
void main() {
  for (final language in ['ar', 'en']) {
    testWidgets('empty reports overview shows the add-transactions tip ($language)',
        (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final fonts = FontLoader('Vazirmatn');
        for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
          fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
        }
        await fonts.load();
      });
      await tester.pumpWidget(ProviderScope(overrides: [
        reportsProvider.overrideWith((ref) async =>
            ReportsBundle(weekly: _empty(), monthly: _empty())),
        baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
        userSettingsProvider.overrideWith((ref) => UserSettingsEntity(
          id: 'synthetic', country: 'SA', currency: 'SAR', language: language,
          theme: 'system', inputMethod: 'manual', notificationsJson: '{}',
          privacyModeEnabled: false,
        )),
        for (final placement in AdPlacement.values)
          bannerEligibilityProvider(placement).overrideWith((ref) async => false),
      ], child: MaterialApp(theme: AppTheme.light, locale: Locale(language),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: AppL10n.localizationsDelegates,
        home: const ReportsScreen(),
      )));
      await tester.pumpAndSettle();
      final l10n = AppL10n.of(tester.element(find.byType(ReportsScreen)));
      final tip = find.text(l10n.rptAddMoreTx);
      for (var i = 0; i < 6 && tip.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(NestedScrollView), const Offset(0, -300));
        await tester.pumpAndSettle();
      }
      expect(tip, findsOneWidget);
      expect(find.text(l10n.rptQuickTip), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
