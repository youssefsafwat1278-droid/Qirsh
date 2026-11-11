import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/metrics_client.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/goals/goals_providers.dart';
import 'package:money_companion/features/goals/goals_screen.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/features/ads/report_banner_suppression.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/dashboard/dashboard_providers.dart'
    show CategorySlice, dashboardDataProvider;
import 'package:money_companion/features/dashboard/dashboard_screen.dart';
import 'package:money_companion/features/reports/reports_providers.dart';
import 'package:money_companion/features/reports/reports_screen.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/subscriptions/subscriptions_providers.dart';
import 'package:money_companion/features/subscriptions/subscriptions_screen.dart';
import 'package:money_companion/features/transactions/widgets/activity_chip.dart';
import 'package:money_companion/features/achievements/achievements_providers.dart';
import 'package:money_companion/features/achievements/achievements_screen.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ad_controller.dart';
import 'package:money_companion/features/ads/banner_ads_analytics.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/ads/qirsh_ad_banner.dart';
import 'package:money_companion/features/report_ads/report_entitlement.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// THE BANNER, ON EACH APPROVED SCREEN.
///
/// One group per placement. Every group answers the same four questions, and
/// they are the ones the ad-surface contract actually depends on:
///
///   * exactly ONE banner is mounted, never two;
///   * a rebuild or a tab switch does not buy a second ad;
///   * the EMPTY state still carries exactly ONE ad — content availability is
///     no longer an eligibility condition (see `_noContentGuards` below), while
///     the ERROR state still carries none;
///   * the banner is a DIRECT child of the scroll view, so sliver laziness
///     applies — verified in `banner_placement_mechanics_test.dart` and relied
///     on here.
///
/// The screens are driven through their own view providers, so no database is
/// opened and the assertions are about placement rather than data.

final _silentAnalytics = BannerAdsAnalytics(
  cloudProcessingEnabled: () async => false,
  metrics: MetricsClient(),
);

class _SpyLoader implements BannerAdLoader {
  static int loadCalls = 0;
  static void reset() => loadCalls = 0;

  @override
  Object? get loadedAd => null;

  @override
  Future<int?> resolveHeight(int widthPx) async => 60;

  @override
  Future<bool> load({
    required String adUnitId,
    required int widthPx,
    required int heightPx,
    VoidCallback? onImpression,
  }) async {
    loadCalls++;
    return false;
  }

  @override
  void dispose() {}
}

Widget _host(Widget screen, List<Override> overrides) {
  return ProviderScope(
    overrides: [
      for (final p in AdPlacement.values)
        bannerEligibilityProvider(p).overrideWith((ref) async => true),
      bannerAdLoaderFactoryProvider.overrideWithValue(_SpyLoader.new),
      bannerAdsAnalyticsProvider.overrideWithValue(_silentAnalytics),
      ...overrides,
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
      theme: AppTheme.dark,
      home: screen,
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Scrolls the screen's primary list to the bottom, where the banner lives.
/// Sliver laziness means it is not mounted until something reaches it.
Future<void> _scrollToBottom(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 6; i++) {
    await tester.drag(scrollable, const Offset(0, -900));
    await _settle(tester);
  }
}

/// Goals' banner follows the first card. Stop at that placement instead of
/// scrolling to the list's foot, where a lazy list may have evicted it.
Future<void> _revealGoalsBanner(WidgetTester tester) async {
  final banner = find.byType(QirshAdBanner);
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 20 && banner.evaluate().isEmpty; i++) {
    await tester.drag(scrollable, const Offset(0, -150));
    await _settle(tester);
  }
  expect(banner, findsOneWidget);
  final firstGoal = find.text('هدف 0');
  if (firstGoal.evaluate().isNotEmpty) {
    expect(tester.getBottomLeft(firstGoal).dy, lessThan(tester.getTopLeft(banner).dy),
        reason: 'the banner must follow the first meaningful goal card');
  }
  await tester.ensureVisible(banner);
  await _settle(tester);
  final bounds = tester.getRect(banner);
  final viewport = Offset.zero &
      (tester.view.physicalSize / tester.view.devicePixelRatio);
  expect(bounds.top, greaterThanOrEqualTo(viewport.top));
  expect(bounds.bottom, lessThanOrEqualTo(viewport.bottom));
}

AchievementsView _achievementsView({int badges = 8}) => AchievementsView(
      achievements: [
        for (var i = 0; i < badges; i++)
          AchievementEntity(
            id: 'a$i',
            key: 'first_transaction',
            nameAr: 'إنجاز $i',
            progress: 1,
            unlockedAt: i.isEven ? DateTime.utc(2026, 1, 1) : null,
          ),
      ],
      xpLevel: const XpLevelEntity(
          id: 'x', totalXp: 120, level: 1, levelKey: 'beginner'),
      streak: StreakEntity(
        id: 's',
        currentStreak: 3,
        longestStreak: 9,
        lastActiveDate: DateTime.utc(2026, 9, 18),
        freezesAvailable: 1,
      ),
    );

List<GoalEntity> _goals(int count) => [
      for (var i = 0; i < count; i++)
        GoalEntity(
          id: 'g$i',
          name: 'هدف $i',
          currency: 'SAR',
          targetMoney: Money.parse('5000', 'SAR'),
          savedMoney: Money.parse('1200', 'SAR'),
          lastNotifiedSavedMoney: Money(0, 'SAR'),
          vaultSkin: 'summer_trip',
          status: 'active',
          createdAt: DateTime.utc(2026, 1, 1),
        ),
    ];

/// GoalsScreen sits behind `PlanningRepairGate`, which reads the cutover
/// coordinator and therefore the database. A canonical stub keeps the test
/// about placement.
class _CanonicalCutover implements PlanningCutoverCoordinator {
  @override
  PlanningCutoverState state() => PlanningCutoverState.canonical;
}

UserSettingsEntity _settings() => const UserSettingsEntity(
      id: 'u1',
      country: 'SA',
      currency: 'SAR',
      language: 'ar',
      theme: 'dark',
      inputMethod: 'manual',
      notificationsJson: '{}',
      privacyModeEnabled: false,
    );

void main() {
  setUp(() {
    _SpyLoader.reset();
    BannerAdController.resetThrottleForTest();
    ReportBannerSuppression.resetForTest();
  });

  group('achievements', () {
    testWidgets('mounts exactly one banner, below the badge grid',
        (tester) async {
      await tester.pumpWidget(_host(
        const AchievementsScreen(),
        [
          achievementsViewProvider
              .overrideWith((ref) async => _achievementsView())
        ],
      ));
      await _settle(tester);

      // Sliver laziness: nothing yet, because the slot is below the grid.
      expect(_SpyLoader.loadCalls, 0,
          reason:
              'the banner sits below the grid and must not load on arrival');

      await _scrollToBottom(tester);
      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('a rebuild does not buy a second ad', (tester) async {
      await tester.pumpWidget(_host(
        const AchievementsScreen(),
        [
          achievementsViewProvider
              .overrideWith((ref) async => _achievementsView())
        ],
      ));
      await _settle(tester);
      await _scrollToBottom(tester);
      expect(_SpyLoader.loadCalls, 1);

      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(_SpyLoader.loadCalls, 1);
      expect(find.byType(QirshAdBanner), findsOneWidget);
    });

    testWidgets('the ERROR state carries no ad', (tester) async {
      await tester.pumpWidget(_host(
        const AchievementsScreen(),
        [
          achievementsViewProvider
              .overrideWith((ref) async => throw StateError('boom')),
        ],
      ));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsNothing);
      expect(_SpyLoader.loadCalls, 0);
    });

    testWidgets('an EMPTY badge list carries no ad', (tester) async {
      await tester.pumpWidget(_host(
        const AchievementsScreen(),
        [
          achievementsViewProvider
              .overrideWith((ref) async => _achievementsView(badges: 0)),
        ],
      ));
      await _settle(tester);
      await _scrollToBottom(tester);

      expect(find.byType(QirshAdBanner), findsNothing,
          reason: 'an ad alone on an empty screen reads as the content');
      expect(_SpyLoader.loadCalls, 0);
    });
  });

  group('goals', () {
    List<Override> deps(int count) => [
          planningCutoverCoordinatorProvider
              .overrideWithValue(_CanonicalCutover()),
          baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
          goalsListProvider.overrideWith((ref) async => _goals(count)),
        ];

    testWidgets('mounts exactly one banner, after the FIRST goal card',
        (tester) async {
      // Was "below the goal cards". The banner now follows the first card so it
      // does not require scrolling to the foot of the page.
      await tester.pumpWidget(_host(const GoalsScreen(), deps(4)));
      await _settle(tester);
      await _revealGoalsBanner(tester);

      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('a SINGLE goal carries exactly one ad', (tester) async {
      // INVERTED. This asserted `findsNothing` under the old rule, which
      // required two goals before an ad was allowed. Availability no longer
      // depends on how many goals exist.
      await tester.pumpWidget(_host(const GoalsScreen(), deps(1)));
      await _settle(tester);
      await _scrollToBottom(tester);

      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('the EMPTY state carries exactly one ad', (tester) async {
      // INVERTED, and the heart of the new contract: the
      // create-your-first-goal branch is a DIFFERENT ListView, so it needs its
      // own banner — and exactly one, never a second from the populated branch.
      await tester.pumpWidget(_host(const GoalsScreen(), deps(0)));
      await _settle(tester);
      await _scrollToBottom(tester);

      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('EMPTY then POPULATED never yields two banners',
        (tester) async {
      // The regression this guards: two branches each carrying a placement.
      // Whichever renders, there must be one — and rebuilding across the
      // boundary must not leave the other behind.
      await tester.pumpWidget(_host(const GoalsScreen(), deps(0)));
      await _settle(tester);
      // The original illustration/header makes this list tall enough for the
      // direct sliver child to stay lazy until visible, just like the populated
      // branch. Reach the placement before asserting its unique mount.
      await _scrollToBottom(tester);
      expect(find.byType(QirshAdBanner), findsOneWidget);

      await tester.pumpWidget(_host(const GoalsScreen(), deps(3)));
      await _settle(tester);
      await _scrollToBottom(tester);
      expect(find.byType(QirshAdBanner), findsOneWidget);
    });

    testWidgets('the ERROR state carries no ad', (tester) async {
      await tester.pumpWidget(_host(const GoalsScreen(), [
        planningCutoverCoordinatorProvider
            .overrideWithValue(_CanonicalCutover()),
        baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
        goalsListProvider.overrideWith((ref) async => throw StateError('boom')),
      ]));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsNothing);
      expect(_SpyLoader.loadCalls, 0);
    });

    testWidgets('a rebuild does not buy a second ad', (tester) async {
      await tester.pumpWidget(_host(const GoalsScreen(), deps(4)));
      await _settle(tester);
      await _revealGoalsBanner(tester);
      expect(_SpyLoader.loadCalls, 1);

      ProviderScope.containerOf(tester.element(find.byType(GoalsScreen)))
          .invalidate(goalsListProvider);
      await _settle(tester);
      await _revealGoalsBanner(tester);
      expect(_SpyLoader.loadCalls, 1);
      expect(find.byType(QirshAdBanner), findsOneWidget);
    });
  });

  group('subscriptions', () {
    List<BillEntity> bills(int count) => [
          for (var i = 0; i < count; i++)
            BillEntity(
              id: 'b$i',
              name: 'اشتراك $i',
              amountMoney: Money.parse('49', 'SAR'),
              currency: 'SAR',
              type: BillType.subscription,
              frequency: BillFrequency.monthly,
              nextDueDate: DateTime.utc(2026, 10, 1),
              reminderOn: true,
              isConfirmed: true,
              createdAt: DateTime.utc(2026, 1, 1),
            ),
        ];

    List<Override> deps(int count) => [
          baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
          billsScopeAccountProvider.overrideWith((ref) async => null),
          savedBillsProvider.overrideWith((ref) async => bills(count)),
          subscriptionsProvider.overrideWith((ref) async => []),
        ];

    testWidgets('mounts ONE banner in the header, above the tab bar',
        (tester) async {
      // The header sliver is not lazy, so unlike the list placements this one
      // is expected to request on arrival — it is on screen on arrival.
      await tester.pumpWidget(_host(const SubscriptionsScreen(), deps(3)));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('switching tabs does not buy a second ad', (tester) async {
      await tester.pumpWidget(_host(const SubscriptionsScreen(), deps(3)));
      await _settle(tester);
      expect(_SpyLoader.loadCalls, 1);

      // Subscriptions / Instalments is a chips row now (was a TabBarView).
      await tester.tap(find.byType(ActivityChip).at(1));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(QirshAdBanner), findsOneWidget,
          reason: 'one shared instance, not one per tab');
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('an EMPTY bills screen carries exactly one ad',
        (tester) async {
      // INVERTED. The banner sits in the header, under the hero and above the
      // tab bar, so the empty-state CTA inside the tabs still comes after it
      // without the ad ever replacing the explanation.
      await tester.pumpWidget(_host(const SubscriptionsScreen(), deps(0)));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('EMPTY and POPULATED both yield exactly one', (tester) async {
      await tester.pumpWidget(_host(const SubscriptionsScreen(), deps(0)));
      await _settle(tester);
      expect(find.byType(QirshAdBanner), findsOneWidget);

      await tester.pumpWidget(_host(const SubscriptionsScreen(), deps(2)));
      await _settle(tester);
      expect(find.byType(QirshAdBanner), findsOneWidget);
    });

    testWidgets('the ERROR state carries no ad', (tester) async {
      await tester.pumpWidget(_host(const SubscriptionsScreen(), [
        baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
        billsScopeAccountProvider.overrideWith((ref) async => null),
        savedBillsProvider
            .overrideWith((ref) async => throw StateError('boom')),
        subscriptionsProvider.overrideWith((ref) async => []),
      ]));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsNothing);
      expect(_SpyLoader.loadCalls, 0);
    });
  });

  group('reports', () {
    ReportSection section({int categories = 3}) => ReportSection(
          total: Money.parse('2400', 'SAR'),
          prevTotal: Money.parse('2000', 'SAR'),
          refunds: Money(0, 'SAR'),
          topCategories: [
            for (var i = 0; i < categories; i++)
              CategorySlice(
                category: CategoryView(CategoryEntity(
                  id: 'c$i',
                  key: 'restaurants',
                  nameAr: 'مطاعم',
                  icon: 'utensils-crossed',
                  color: '#FF7043',
                  isIncome: false,
                  sort: i,
                )),
                total: Money.parse('800', 'SAR'),
                percent: 0.33,
              ),
          ],
          topMerchants: const [],
          dailySpend: const [],
          anomaly: null,
        );

    List<Override> deps({int categories = 3}) => [
          baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
          userSettingsProvider.overrideWith((ref) async => _settings()),
          reportsProvider.overrideWith((ref) async => ReportsBundle(
                weekly: section(categories: categories),
                monthly: section(categories: categories),
              )),
        ];

    testWidgets('mounts ONE banner in the header', (tester) async {
      await tester.pumpWidget(_host(const ReportsScreen(), deps()));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('switching tabs does not buy a second ad', (tester) async {
      await tester.pumpWidget(_host(const ReportsScreen(), deps()));
      await _settle(tester);
      expect(_SpyLoader.loadCalls, 1);

      final controller =
          DefaultTabController.of(tester.element(find.byType(TabBarView)));
      controller.animateTo(2);
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('an EMPTY report carries exactly one ad', (tester) async {
      // INVERTED. `ReportBannerSuppression` is a separate, still-active gate and
      // is exercised in the cooldown group below — it is about not stacking two
      // ad formats, not about how much data exists.
      await tester
          .pumpWidget(_host(const ReportsScreen(), deps(categories: 0)));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('EMPTY and POPULATED both yield exactly one', (tester) async {
      await tester
          .pumpWidget(_host(const ReportsScreen(), deps(categories: 0)));
      await _settle(tester);
      expect(find.byType(QirshAdBanner), findsOneWidget);

      await tester
          .pumpWidget(_host(const ReportsScreen(), deps(categories: 4)));
      await _settle(tester);
      expect(find.byType(QirshAdBanner), findsOneWidget);
    });

    testWidgets('the ERROR state carries no ad', (tester) async {
      await tester.pumpWidget(_host(const ReportsScreen(), [
        baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
        userSettingsProvider.overrideWith((ref) async => _settings()),
        reportsProvider.overrideWith((ref) async => throw StateError('boom')),
      ]));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsNothing);
      expect(_SpyLoader.loadCalls, 0);
    });
  });

  // The cooldown lives in `bannerEligibilityProvider`, which the screen tests
  // above override wholesale — so it has to be exercised where it actually is.
  // These drive the REAL provider and override only its inputs.
  group('reports interstitial cooldown', () {
    Future<bool?> resolve() async {
      final container = ProviderContainer(overrides: [
        bannerPlacementEnabledProvider(AdPlacement.reports)
            .overrideWithValue(true),
        bannerEntitlementProvider.overrideWith(
            (ref) async => ReportEntitlementState.verifiedInactive),
        bannerConsentProvider.overrideWith((ref) async => true),
      ]);
      addTearDown(container.dispose);
      return container
          .read(bannerEligibilityProvider(AdPlacement.reports).future);
    }

    test('blocks Reports right after an interstitial', () async {
      ReportBannerSuppression.markAdShown();
      expect(await resolve(), isFalse);
    });

    test('never blocks another placement', () async {
      // Reports is the only surface with two formats. A global cooldown would
      // silently cost every other placement an ad for two minutes.
      ReportBannerSuppression.markAdShown();
      final container = ProviderContainer(overrides: [
        bannerPlacementEnabledProvider(AdPlacement.goals)
            .overrideWithValue(true),
        bannerEntitlementProvider.overrideWith(
            (ref) async => ReportEntitlementState.verifiedInactive),
        bannerConsentProvider.overrideWith((ref) async => true),
      ]);
      addTearDown(container.dispose);
      expect(
        await container
            .read(bannerEligibilityProvider(AdPlacement.goals).future),
        isTrue,
      );
    });
  });

  group('dashboard', () {
    // NO full pump of this screen, deliberately.
    //
    // `no_charts_on_home_test.dart` already records why: DashboardScreen's
    // provider aggregates about a dozen repositories, and its sections each
    // watch their own. Building a DashboardData fixture plus stubs for
    // budgets, subscriptions, plans and coupons would be far more scaffolding
    // than a banner placement earns, and it would break on changes that have
    // nothing to do with ads.
    //
    // So: the error path is pumped for real, and the structural claims are
    // checked against the source.

    testWidgets('the ERROR state carries no ad', (tester) async {
      await tester.pumpWidget(_host(const DashboardScreen(), [
        dashboardDataProvider
            .overrideWith((ref) async => throw StateError('x')),
      ]));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsNothing);
      expect(_SpyLoader.loadCalls, 0);
    });

    test('the banner is INSIDE _Sheet now, and there is exactly one', () {
      // INVERTED from "sibling of _Sheet, not a descendant".
      //
      // The old position was a direct ListView sibling at the foot of the page,
      // chosen so `SliverList` would materialise it lazily and not request an ad
      // for a slot the user might never reach. The banner is now in the
      // upper-middle of the sheet, where it IS on screen on arrival, so building
      // it with the sheet is correct rather than wasteful. Laziness only ever
      // mattered because the slot was unreachable.
      final src = File('lib/features/dashboard/dashboard_screen.dart')
          .readAsStringSync();
      final lines = src.split('\n');

      int indentOf(bool Function(String) match) {
        final line = lines.firstWhere(match);
        return line.length - line.trimLeft().length;
      }

      final bannerIndent = indentOf(
          (l) => l.contains('QirshAdBanner(placement: AdPlacement.dashboard)'));
      final sheetIndent = indentOf((l) => l.trimLeft().startsWith('_Sheet('));

      expect(bannerIndent, greaterThan(sheetIndent),
          reason: 'the banner now lives inside the sheet, above the budgets '
              'section, so it is reachable without scrolling to the bottom');
      expect('AdPlacement.dashboard'.allMatches(src).length, 1,
          reason: 'exactly one dashboard placement, never two');
    });
  });

  /// THE NEW PRODUCT RULE, encoded once for every surface.
  ///
  /// Banner availability must not depend on the user having content. Each of
  /// these five conditions used to gate a placement and has been removed; a
  /// reintroduction is the regression this catches.
  ///
  /// Dashboard and Transactions are asserted at source level rather than by
  /// pumping. `DashboardScreen` is documented above as too heavy to pump for a
  /// placement claim, and `TransactionsScreen` is the same shape — its list is
  /// fed by an `AutoDisposeAsyncNotifierProvider` and the screen watches the
  /// search field, filter bar and period totals besides. The other three are
  /// pumped for real in their own groups above, with zero data.
  group('content availability is not an ad gate', () {
    String read(String p) => File(p).readAsStringSync();

    test('no surface guards its banner on a content count', () {
      final offenders = <String>[];

      void check(String path, String placement, List<String> forbidden) {
        final src = read(path);
        final marker = RegExp(
          r'QirshAdBanner\(\s*placement:\s*AdPlacement\.' +
              RegExp.escape(placement) +
              r'\b',
        );
        final at = src.indexOf(marker);
        expect(at, greaterThan(-1), reason: '$placement missing from $path');
        // Only the text between the enclosing build and the placement can gate
        // it; a mention further down the file is unrelated.
        final before = src.substring(0, at);
        for (final f in forbidden) {
          // The LAST occurrence before the placement is the one that could
          // still wrap it.
          if (before.contains(f)) offenders.add('$path :: $f');
        }
      }

      check('lib/features/dashboard/dashboard_screen.dart', 'dashboard', [
        'if (!data.isEmpty)\n          const Padding',
      ]);
      check('lib/features/reports/reports_screen.dart', 'reports',
          ['if (section.topCategories.isNotEmpty)']);
      check('lib/features/subscriptions/subscriptions_screen.dart',
          'subscriptions',
          ['if (subs.isNotEmpty || insts.isNotEmpty)']);

      expect(offenders, isEmpty,
          reason: 'a content count must not decide whether an ad may serve');
    });

    test('transactions no longer requires a second date section', () {
      final src = read('lib/features/transactions/transactions_screen.dart');
      expect(src.contains('sections.length > 1'), isFalse,
          reason: 'the two-section requirement was a content gate');
      // The workflow rule is NOT a content rule and must survive.
      expect(src, contains('if (itemIndex == 0 && !pendingOnly)'),
          reason: 'the pending-review filter still carries no ad');
    });

    test('transactions and goals carry a banner in their EMPTY branch', () {
      // Both screens return a different subtree when empty, so the placement
      // has to exist in that subtree too — and in exactly one other place.
      for (final e in {
        'lib/features/transactions/transactions_screen.dart':
            'AdPlacement.transactionsList',
        'lib/features/goals/goals_screen.dart': 'AdPlacement.goals',
      }.entries) {
        expect(e.value.allMatches(read(e.key)).length, 2,
            reason: '${e.key}: one for the empty branch, one for the populated '
                'branch — they are mutually exclusive, so at most one renders');
      }
    });

    test('the REAL gates are untouched', () {
      // The gates that must keep deciding: nothing here may be weakened by the
      // content-guard removal.
      final src = read('lib/features/ads/banner_ads_providers.dart');
      expect(src, contains('bannerPlacementEnabledProvider'));
      expect(src, contains("featureFlags.getBool('enable_banner_ads')"));
      expect(src, contains('ReportEntitlementState.verifiedInactive'));
      expect(src, contains('bannerConsentProvider'));
      expect(src, contains('AdMobBuildConfig.isBannerConfiguredFor'));
      expect(src, contains('reportBannerSuppressedProvider'),
          reason: 'report suppression stays, it is not a content rule');
    });
  });
}
