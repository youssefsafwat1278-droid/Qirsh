import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/common/qirsh_summary_card.dart';
import 'package:money_companion/features/dashboard/dashboard_providers.dart';
import 'package:money_companion/features/reports/reports_providers.dart';
import 'package:money_companion/features/reports/reports_screen.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

ReportSection _section() => ReportSection(
  total: Money(222210, 'KWD'),
  prevTotal: Money(0, 'KWD'),
  refunds: Money(345, 'KWD'),
  topCategories: [
    for (var i = 0; i < 18; i++)
      CategorySlice(
        category: CategoryView(CategoryEntity(
          id: 'category-$i', key: 'custom-$i', nameAr: 'Category $i',
          icon: 'shopping-cart', color: '#16A37F', isIncome: false, sort: i,
        )),
        total: Money(12345, 'KWD'), percent: 1 / 18, count: 2,
        refunds: i == 17 ? Money(345, 'KWD') : null,
      ),
  ],
  topMerchants: [MerchantSpend(name: 'Test merchant',
    total: Money(1234, 'KWD'), count: 1)],
  dailySpend: const [], anomaly: null,
);

Future<AppL10n> _openDetails(WidgetTester tester,
    {required String language, bool privacy = false,
    ReportSection? data, bool trends = false}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final section = data ?? _section();
  await tester.pumpWidget(ProviderScope(overrides: [
    reportsProvider.overrideWith((ref) async =>
      ReportsBundle(weekly: section, monthly: section)),
    baseCurrencyProvider.overrideWith((ref) async => 'KWD'),
    userSettingsProvider.overrideWith((ref) async => UserSettingsEntity(
      id: 'test', country: 'KW', currency: 'KWD', language: language,
      theme: 'system', inputMethod: 'manual', notificationsJson: '{}',
      privacyModeEnabled: privacy,
    )),
    for (final placement in AdPlacement.values)
      bannerEligibilityProvider(placement).overrideWith((ref) async => false),
  ], child: MaterialApp(
    theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
    locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates,
    home: const ReportsScreen(),
  )));
  await tester.pumpAndSettle();
  final l10n = AppL10n.of(tester.element(find.byType(ReportsScreen)));
  final hero = find.byKey(const ValueKey('section-hero-reports'));
  final targetTab = find.descendant(
    of: hero,
    matching: find.text(trends ? l10n.rptTabTrends : l10n.rptTabDetails),
  );
  expect(targetTab.hitTestable(), findsOneWidget);
  await tester.tap(targetTab);
  await tester.pumpAndSettle();
  return l10n;
}

void main() {
  for (final language in ['en', 'ar']) {
    testWidgets('Details keeps all categories before merchants in $language',
        (tester) async {
      final l10n = await _openDetails(tester, language: language);
      for (var i = 0; i < 6 && find.text(l10n.rptByMerchant).evaluate().isEmpty; i++) {
        await tester.drag(find.byType(NestedScrollView), const Offset(0, -600));
        await tester.pumpAndSettle();
      }
      expect(find.text('Category 17'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Category 17')).dy,
          lessThan(tester.getTopLeft(find.text(l10n.rptByMerchant)).dy));
      expect(find.textContaining('12.345'), findsWidgets,
          reason: 'a three-decimal currency must retain its exact minor units');
      expect(find.textContaining('0.345'), findsOneWidget,
          reason: 'net category spending still explains its refund input');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('report summary period chip drives the shared period', (tester) async {
    await _openDetails(tester, language: 'en');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReportsScreen)),
    );
    // v3: the period selector left the hero; it is the summary card's chip.
    final hero = find.byKey(const ValueKey('section-hero-reports'));
    final card = find.byType(QirshSummaryCard);
    var current = TransactionsDatePreset.thisMonth;
    for (final preset in [
      TransactionsDatePreset.previousMonth,
      TransactionsDatePreset.last90Days,
      TransactionsDatePreset.thisMonth,
    ]) {
      final currentLabel = transactionsRangeForPreset(current).labelIn('en');
      expect(find.descendant(of: hero, matching: find.text(currentLabel)),
          findsNothing);
      final chip = find.descendant(
          of: card, matching: find.bySemanticsLabel(currentLabel));
      expect(chip.hitTestable(), findsOneWidget);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      for (final option in [
        TransactionsDatePreset.thisMonth,
        TransactionsDatePreset.previousMonth,
        TransactionsDatePreset.last90Days,
      ]) {
        expect(find.descendant(of: sheet,
            matching: find.text(transactionsRangeForPreset(option).labelIn('en'))),
            findsOneWidget);
      }
      final label = transactionsRangeForPreset(preset).labelIn('en');
      await tester.tap(find.descendant(of: sheet, matching: find.text(label)));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(container.read(transactionsDateRangeProvider).preset, preset);
      expect(find.descendant(of: card, matching: find.bySemanticsLabel(label)),
          findsOneWidget);
      current = preset;
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('hero Report pill opens the report flow', (tester) async {
    await _openDetails(tester, language: 'ar');
    final hero = find.byKey(const ValueKey('section-hero-reports'));
    final l10n = AppL10n.of(tester.element(find.byType(ReportsScreen)));
    expect(find.descendant(of: hero, matching: find.byType(FilledButton)),
        findsNothing);
    final pill = find.descendant(
        of: hero, matching: find.bySemanticsLabel(l10n.rcCreateReport));
    expect(pill.hitTestable(), findsOneWidget);
    await tester.tap(pill);
    await tester.pumpAndSettle();
    expect(find.text(l10n.rcTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Details privacy hides totals and refund amounts', (tester) async {
    await _openDetails(tester, language: 'en', privacy: true);
    await tester.drag(find.byType(NestedScrollView), const Offset(0, -1100));
    await tester.pumpAndSettle();
    expect(find.text('Category 17'), findsOneWidget);
    expect(find.textContaining('••••'), findsWidgets);
    expect(find.textContaining('12.345'), findsNothing);
    expect(find.textContaining('0.345'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  ReportSection comparison() => ReportSection(
    total: Money(13645, 'KWD'), prevTotal: Money(19700, 'KWD'),
    refunds: Money(545, 'KWD'), topMerchants: const [], dailySpend: const [],
    anomaly: null,
    topCategories: [
      for (var i = 0; i < 3; i++) CategorySlice(
        category: _section().topCategories[i].category,
        total: Money([12345, 1500, -200][i], 'KWD'),
        previousTotal: Money([20000, 0, -300][i], 'KWD'),
        percent: 0, refunds: i == 0 ? Money(345, 'KWD') : null,
      ),
    ],
  );

  Future<Finder> comparisonRow(WidgetTester tester, int i) async {
    final row = find.byKey(ValueKey('report-category-comparison-category-$i'));
    for (var attempt = 0; attempt < 8 && row.evaluate().isEmpty; attempt++) {
      await tester.drag(find.byType(NestedScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    expect(row, findsOneWidget);
    return row;
  }

  for (final language in ['en', 'ar']) {
    testWidgets('Trends shows exact paired totals without invented baselines in $language',
        (tester) async {
      await _openDetails(tester, language: language, data: comparison(), trends: true);
      final row = await comparisonRow(tester, 0);
      expect(find.descendant(of: row, matching: find.textContaining('12.345')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.textContaining('20.000')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('−38%')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.textContaining('0.345')), findsOneWidget);
      for (final i in [1, 2]) {
        final guardedRow = await comparisonRow(tester, i);
        expect(find.descendant(of: guardedRow,
            matching: find.textContaining('%')), findsNothing);
      }
      final refundRow = await comparisonRow(tester, 2);
      expect(find.descendant(of: refundRow,
          matching: find.textContaining('-0.200')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Trends privacy hides amounts percentages and relative bars', (tester) async {
    await _openDetails(tester, language: 'en', data: comparison(), trends: true, privacy: true);
    final row = await comparisonRow(tester, 0);
    expect(find.descendant(of: row, matching: find.textContaining('••••')), findsNWidgets(2));
    expect(find.descendant(of: row, matching: find.textContaining('12.345')), findsNothing);
    expect(find.descendant(of: row, matching: find.textContaining('%')), findsNothing);
    expect(find.descendant(of: row, matching: find.byType(LinearProgressIndicator)), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
