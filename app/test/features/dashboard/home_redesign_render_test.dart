import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:money_companion/features/dashboard/home_hero_period_controller.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/cards/brand_mark.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/features/dashboard/dashboard_providers.dart';
import 'package:money_companion/features/dashboard/dashboard_screen.dart';
import 'package:money_companion/features/dashboard/home_sections_providers.dart';
import 'package:money_companion/features/goals/goals_providers.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// The redesigned Home (concept B) pumped for real in both of its states, at
/// a phone size, in both themes — so a layout error in the hero, the cards or
/// the first-run screen fails here rather than on a device.
Money sar(int minor) => Money(minor, 'SAR');

final _now = DateTime.now();
final _today = DateTime(_now.year, _now.month, _now.day);

final _catalog = CategoryCatalog(const [
  CategoryEntity(
    id: 'groceries',
    key: 'groceries',
    nameAr: 'بقالة',
    icon: 'shopping-cart',
    color: '#31D0AA',
    isIncome: false,
    sort: 1,
  ),
  CategoryEntity(
    id: 'food',
    key: 'restaurants',
    nameAr: 'مطاعم',
    icon: 'utensils',
    color: '#F59E0B',
    isIncome: false,
    sort: 2,
  ),
]);

TransactionEntity _tx(String id, int minor, String merchant, String cat,
        {TransactionStatus status = TransactionStatus.confirmed,
        int hoursAgo = 1}) =>
    TransactionEntity(
      id: id,
      amountMoney: sar(minor),
      currency: 'SAR',
      type: TransactionTypeEntity.payment,
      source: TransactionSourceEntity.bank,
      occurredAt: _now.subtract(Duration(hours: hoursAgo)),
      rawMessage: 'test',
      rawMerchant: merchant,
      categoryId: cat,
      parseConfidence: 1,
      status: status,
      createdAt: _now,
      updatedAt: _now,
    );

DashboardData _data(
    {required bool withData, int pending = 1, bool matchedHistory = true}) {
  final recent = withData
      ? [
          _tx('t1', 11200, 'Danube', 'groceries'),
          _tx('t2', 3850, 'Careem', 'food', hoursAgo: 3),
          _tx('t3', 3600, 'Barns', 'food', hoursAgo: 30),
        ]
      : <TransactionEntity>[];
  final zero = sar(0);
  return DashboardData(
    savedThisMonth: zero,
    spentThisMonth: withData ? sar(251240) : zero,
    incomeThisMonth: zero,
    todaySpend: withData ? sar(18650) : zero,
    todayIncome: zero,
    weekIncome: zero,
    balance: null,
    dailyBudgetLimit: zero,
    weeklyBudgetLimit: zero,
    monthlyBudgetLimit: withData ? sar(300000) : zero,
    monthlyBudgetRatio: withData ? 0.84 : 0,
    budgetPeriod: null,
    currency: 'SAR',
    streak: StreakEntity(
      id: 's',
      currentStreak: 0,
      longestStreak: 0,
      lastActiveDate: _now,
      freezesAvailable: 0,
    ),
    topCategories: withData
        ? [
            CategorySlice(
                category: _catalog.byId('groceries')!,
                total: sar(82000),
                percent: 0.6,
                previousTotal: matchedHistory ? sar(85000) : null),
            CategorySlice(
                category: _catalog.byId('food')!,
                total: sar(55000),
                percent: 0.4,
                previousTotal: matchedHistory ? sar(41000) : null),
          ]
        : const [],
    dailySpendTrend: const [],
    lastSevenDays: [
      for (var i = 6; i >= 0; i--)
        DailySpend(
            day: _today.subtract(Duration(days: i)),
            total: sar(withData ? 10000 + i * 900 : 0)),
    ],
    todayTransactions: withData ? recent.take(2).toList() : const [],
    availableToday: withData ? sar(3820) : null,
    monthElapsedRatio: _now.day / DateTime(_now.year, _now.month + 1, 0).day,
    categoryCount: withData ? 2 : 0,
    topMerchants: const [],
    recent: recent,
    catalog: _catalog,
    // The pending row is kept out of `recent` here: the test font draws every
    // glyph as a full square, so the shared row's «قيد المراجعة» badge
    // overflows a phone-width row in tests although it fits on a device. The
    // review card, which is new, is still pumped with it.
    pendingReview: withData
        ? [
            for (var i = 0; i < pending; i++)
              _tx('p$i', 6400, 'POS 773$i', 'food',
                  status: TransactionStatus.pending)
          ]
        : const [],
    pendingReviewTotal: zero,
    weekSpend: withData ? sar(104830) : zero,
    previousWeekSpend: withData ? sar(93600) : zero,
    projectedMonthSpend: withData ? 2700 : 0,
    subscriptions: const [],
    subscriptionsMonthlyTotal: zero,
    range: TransactionsDateRange(
      preset: TransactionsDatePreset.thisMonth,
      from: DateTime(_now.year, _now.month),
      to: _now,
    ),
    currencyTotals: const [],
    budgetProgress: const [],
    rangeExpense: zero,
    rangeIncome: zero,
    monthDailySpend: withData
        ? [
            for (var d = 1; d <= _now.day; d++)
              DailySpend(
                  day: DateTime(_now.year, _now.month, d), total: sar(8000)),
          ]
        : const [],
    hasAnyTransactions: withData,
  );
}

Future<void> _pump(WidgetTester tester,
    {required bool withData,
    required ThemeData theme,
    int pending = 1,
    bool matchedHistory = true,
    String language = 'ar',
    Size size = const Size(390, 844),
    double textScale = 1,
    bool realFonts = false,
    GoRouter? router,
    GlobalKey? repaintKey}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  if (realFonts) {
    await tester.runAsync(() async {
      final fonts = FontLoader('Vazirmatn');
      for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
      }
      await fonts.load();
    });
  }
  final bills = withData
      ? [
          BillEntity(
            id: 'b1',
            name: 'Netflix',
            amountMoney: sar(5600),
            currency: 'SAR',
            type: BillType.subscription,
            frequency: BillFrequency.monthly,
            nextDueDate: _today.add(const Duration(days: 3)),
            reminderOn: true,
            isConfirmed: true,
            createdAt: _now,
          ),
        ]
      : const <BillEntity>[];
  await tester.pumpWidget(ProviderScope(
    overrides: [
      dashboardDataProvider.overrideWith((ref) async => _data(
          withData: withData,
          pending: pending,
          matchedHistory: matchedHistory)),
      accountsProvider.overrideWith((ref) async => const []),
      if (realFonts)
        userSettingsProvider.overrideWith((ref) => UserSettingsEntity(
              id: 'synthetic-heading',
              country: 'SA',
              currency: 'SAR',
              language: language,
              theme: 'system',
              inputMethod: 'manual',
              notificationsJson: '{}',
              privacyModeEnabled: false,
            )),
      merchantLogosProvider.overrideWith((ref) async => const {}),
      homeSubscriptionsProvider.overrideWith((ref) async => bills),
      homeInstallmentsProvider.overrideWith((ref) async => const []),
      goalsListProvider.overrideWith((ref) async => const []),
      homePlansProvider.overrideWith((ref) async => const []),
      dashboardCouponsProvider.overrideWith((ref) => const AsyncValue.data([])),
      for (final p in AdPlacement.values)
        bannerEligibilityProvider(p).overrideWith((ref) async => false),
    ],
    child: router != null
        ? MaterialApp.router(
            routerConfig: router,
            locale: Locale(language),
            supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: AppL10n.localizationsDelegates,
            theme: theme,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!),
          )
        : MaterialApp(
            locale: Locale(language),
            supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: const [
              ...AppL10n.localizationsDelegates,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: theme,
            home: RepaintBoundary(
                key: repaintKey, child: const DashboardScreen()),
          ),
  ));
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _scrollThrough(WidgetTester tester) async {
  final list = find.byType(Scrollable).first;
  for (var i = 0; i < 5; i++) {
    await tester.drag(list, const Offset(0, -700));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HomeHeroPeriodController.preload();
  });

  testWidgets('Home blue fade reveals the grain canvas without a dark seam',
      (tester) async {
    final boundary = GlobalKey();
    await _pump(tester,
        withData: true,
        theme: AppTheme.dark,
        size: const Size(390, 1400),
        repaintKey: boundary);
    await tester.runAsync(() => precacheImage(
        const AssetImage('assets/textures/grain.png'),
        boundary.currentContext!));
    await tester.pumpAndSettle();
    final fade =
        tester.getRect(find.byKey(const ValueKey('home-blue-backdrop')));
    final origin = tester.getTopLeft(find.byKey(boundary));
    final lastRow = (fade.bottom - origin.dy).floor() - 1;
    final bytes = await tester.runAsync(() async {
      final image = await (boundary.currentContext!.findRenderObject()
              as RenderRepaintBoundary)
          .toImage(pixelRatio: 1);
      try {
        final data =
            (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        // Grain repeats every 128 pixels. At the fading edge, the canvas must
        // match the same texture phase below it, outside the inset cards.
        expect(lastRow + 128, lessThan(image.height));
        return [
          for (var x = 4; x < 16; x++)
            for (var c = 0; c < 3; c++)
              (data.getUint8((lastRow * image.width + x) * 4 + c) -
                      data.getUint8(
                          ((lastRow + 128) * image.width + x) * 4 + c))
                  .abs()
        ];
      } finally {
        image.dispose();
      }
    });
    expect(bytes, everyElement(lessThanOrEqualTo(2)),
        reason: 'an opaque fade hides grain until its edge and creates a seam');
    expect(tester.takeException(), isNull);
  });

  testWidgets('category insight uses matched history and opens Reports',
      (tester) async {
    await _pump(tester, withData: true, theme: AppTheme.light);
    final context = tester.element(find.byType(DashboardScreen));
    final l10n = AppL10n.of(context);
    await tester.scrollUntilVisible(find.text(l10n.rptSpendLower(4)), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text(l10n.rptSpendHigher(34)), findsNothing);
    final details = find.widgetWithText(TextButton, l10n.rptTabDetails);
    await tester.ensureVisible(details);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(details);
    expect(ProviderScope.containerOf(context).read(shellIndexProvider), 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('category insight abstains when matched history is absent',
      (tester) async {
    await _pump(tester,
        withData: true, theme: AppTheme.dark, matchedHistory: false);
    final context = tester.element(find.byType(DashboardScreen));
    final l10n = AppL10n.of(context);
    await _scrollThrough(tester);
    expect(find.text(l10n.rptNeedPrevPeriod), findsNothing);
    expect(find.text(l10n.rptSpendLower(4)), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // The cards stacked under the review card once peeked through the
  // translucent dark card as an 80% white bar: `withValues(alpha:)` replaced
  // the 7% token opacity instead of scaling it.
  testWidgets('review stack layers stay dark in dark mode', (tester) async {
    await _pump(tester, withData: true, theme: AppTheme.dark, pending: 3);
    for (final inset in [11.0, 22.0]) {
      final layer = tester
          .widget<Container>(find.byKey(ValueKey('home-review-layer-$inset')));
      final color = (layer.decoration! as BoxDecoration).color!;
      expect(color.a, 1);
      expect(color.computeLuminance(), lessThan(0.05));
    }
    expect(tester.takeException(), isNull);
  });

  for (final theme in [AppTheme.light, AppTheme.dark]) {
    final mode = theme.brightness.name;

    testWidgets('with data ($mode): hero, review, today and sections render',
        (tester) async {
      await _pump(tester, withData: true, theme: theme);

      expect(find.text('مصروف الشهر'), findsOneWidget);
      // Both the main total and the restored Spent KPI show the same canonical amount.
      expect(find.text('2,512.40'), findsNWidgets(2));
      expect(find.text('للمراجعة (1)'), findsOneWidget);
      expect(find.text('متاح لليوم'), findsOneWidget);
      // Quick actions.
      expect(find.text('لصق رسالة'), findsOneWidget);

      // Every period renders its own drawing without a layout error.
      await tester.tap(find.text('الأسبوع'));
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('مصروف الأسبوع'), findsOneWidget);
      await tester.tap(find.text('اليوم').first);
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('مصروف اليوم'), findsOneWidget);

      await _scrollThrough(tester);
      expect(find.text('أين ذهبت أموالك'), findsOneWidget);
      expect(find.text('مدفوعات قادمة'), findsOneWidget);
      // A known brand gets its logo tile, not a hand-drawn letter.
      expect(
          find.byWidgetPredicate((w) => w is BrandMark && w.name == 'Netflix'),
          findsOneWidget);
      expect(find.text('أهدافي وخططي'), findsNothing);
      expect(find.text('آخر العمليات'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('first run ($mode): welcome and start steps, no zero hero',
        (tester) async {
      await _pump(tester, withData: false, theme: theme);

      expect(find.text('أهلاً بك في قِرش'), findsOneWidget);
      expect(find.text('ابدأ في ٣ خطوات'), findsOneWidget);
      expect(find.text('0/3'), findsOneWidget);
      expect(find.text('مصروف الشهر'), findsNothing);
      expect(find.text('0.00'), findsNothing);

      await _scrollThrough(tester);
      expect(find.text('أو أنشئ بنفسك'), findsOneWidget);
      // Nothing the user owns, so no empty owned sections on first run.
      expect(find.text('مدفوعات قادمة'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  for (final language in ['ar', 'en']) {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      for (final width in [375.0, 402.0]) {
        testWidgets(
            'Home upcoming heading fully wraps and All retains route at $language ${theme.brightness.name} width$width accessibility1.941',
            (tester) async {
          final router = GoRouter(routes: [
            GoRoute(path: '/', builder: (_, __) => const DashboardScreen()),
            GoRoute(
                path: '/subscriptions',
                builder: (_, __) => const Scaffold(
                    body: Text('Synthetic subscriptions destination'))),
          ]);
          addTearDown(router.dispose);
          await _pump(tester,
              withData: true,
              pending: 0,
              theme: theme,
              language: language,
              size: Size(width, 874),
              textScale: 1.9411764705882353,
              realFonts: true,
              router: router);
          final context = tester.element(find.byType(DashboardScreen));
          final l10n = AppL10n.of(context);
          final heading = find.text(l10n.homeUpcoming);
          for (var i = 0; i < 12 && heading.evaluate().isEmpty; i++) {
            await tester.drag(
                find.byType(Scrollable).first, const Offset(0, -350));
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(heading, findsOneWidget);
          await tester.ensureVisible(heading);
          await tester.pumpAndSettle();
          final paragraph = tester.renderObject<RenderParagraph>(heading);
          expect(paragraph.didExceedMaxLines, isFalse,
              reason:
                  'The full localized standalone section heading must remain readable.');
          final text = tester.widget<Text>(heading);
          expect(text.maxLines, isNull);
          expect(text.overflow, isNot(TextOverflow.ellipsis));
          final boxes = paragraph.getBoxesForSelection(TextSelection(
              baseOffset: 0, extentOffset: l10n.homeUpcoming.length));
          final origin = paragraph.localToGlobal(Offset.zero);
          for (final box in boxes) {
            expect(origin.dx + box.left, greaterThanOrEqualTo(0));
            expect(origin.dx + box.right, lessThanOrEqualTo(width));
          }
          final row =
              find.ancestor(of: heading, matching: find.byType(Row)).first;
          final all =
              find.descendant(of: row, matching: find.text(l10n.bdgFilterAll));
          expect(all, findsOneWidget);
          await tester.ensureVisible(all);
          await tester.pumpAndSettle();
          await tester.tap(all);
          await tester.pumpAndSettle();
          expect(
              find.text('Synthetic subscriptions destination'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
