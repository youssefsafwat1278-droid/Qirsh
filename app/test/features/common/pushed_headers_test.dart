import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/calm_page_header.dart';
import 'package:money_companion/core/theme/widgets/section_photo_header.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/accounts/accounts_screen.dart';
import 'package:money_companion/features/achievements/achievements_providers.dart';
import 'package:money_companion/features/achievements/achievements_screen.dart';
import 'package:money_companion/features/budgets/widgets/planning_hero_tabs.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/common/app_header.dart';
import 'package:money_companion/features/goals/goals_providers.dart';
import 'package:money_companion/features/goals/goals_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory';
  @override
  Future<String?> readStoredKey() async => 'memory';
}

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
  });
  tearDown(() async => db.close());

  for (final language in ['ar', 'en']) {
    for (final surface in ['accounts', 'goals', 'achievements']) {
      for (final state in ['loading', 'error', 'data']) {
        testWidgets('$surface keeps its pushed header and back in $state $language', (tester) async {
          await tester.runAsync(() async {
            final loader = FontLoader('Vazirmatn');
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              loader.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
            }
            await loader.load();
          });
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          Future<T> result<T>(T data) {
            if (state == 'loading') return Completer<T>().future;
            if (state == 'error') return Future<T>.error(StateError('synthetic read'));
            return Future.value(data);
          }
          final now = DateTime.now();
          final goal = GoalEntity(id: 'synthetic-header-goal', name: 'Family trip',
            currency: 'EGP', targetMoney: Money.parse('1000', 'EGP'),
            savedMoney: Money.parse('250', 'EGP'),
            lastNotifiedSavedMoney: Money.zero('EGP'), vaultSkin: 'summer_trip',
            status: 'active', createdAt: now, deadline: now.add(const Duration(days: 30)));
          final screen = switch (surface) {
            'accounts' => const AccountsScreen(),
            'goals' => const GoalsScreen(),
            _ => const AchievementsScreen(),
          };
          await tester.pumpWidget(ProviderScope(overrides: [
            appDatabaseProvider.overrideWithValue(db),
            baseCurrencyProvider.overrideWith((ref) async => 'EGP'),
            for (final placement in AdPlacement.values)
              bannerEligibilityProvider(placement).overrideWith((ref) async => false),
            if (surface == 'accounts') accountsProvider.overrideWith((ref) =>
                result(const <AccountEntity>[])),
            if (surface == 'goals') goalsListProvider.overrideWith((ref) =>
                result([goal])),
            if (surface == 'achievements') achievementsViewProvider.overrideWith((ref) =>
                result(AchievementsView(achievements: const [],
                  xpLevel: const XpLevelEntity(id: 'xp', totalXp: 10, level: 1, levelKey: 'beginner'),
                  streak: StreakEntity(id: 'streak', currentStreak: 1, longestStreak: 1,
                    lastActiveDate: now, freezesAvailable: 0)))),
          ], child: MaterialApp(
            theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
            locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: AppL10n.localizationsDelegates,
            home: Builder(builder: (context) => Scaffold(body: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => screen)), child: const Text('Open surface')))),
          )));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Open surface'));
          await tester.pump();
          // Loading placeholders animate indefinitely; bounded frames still
          // complete actual route transitions without faking an async result.
          for (var frame = 0; frame < 10; frame++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          // Goals' pushed header is the v2 in-body photo hero (CalmPageHeader
          // over QirshSectionHero), not an AppBar-slot AppHeader.
          final header = surface == 'goals'
              ? find.byType(CalmPageHeader)
              : find.byType(AppHeader);
          expect(header, findsOneWidget);
          final l10n = AppL10n.of(tester.element(header));
          final title = switch (surface) {
            'accounts' => l10n.accTitle,
            'goals' => l10n.bdgTabGoals,
            _ => l10n.achTitle,
          };
          // The goals hero also carries the planning segmented control, whose
          // middle segment is the same «Goals» label; the title is the other.
          final titleFinder = surface == 'goals'
              ? find.byElementPredicate((element) =>
                  element.widget is Text &&
                  (element.widget as Text).data == title &&
                  element.findAncestorWidgetOfExactType<PlanningHeroTabs>() ==
                      null)
              : find.text(title);
          expect(titleFinder, findsOneWidget);
          final titleText = tester.widget<Text>(titleFinder);
          if (surface == 'achievements') {
            final bar = tester.widget<AppBar>(find.byType(AppBar));
            expect(bar.centerTitle, isTrue);
            expect(titleText.style?.fontSize, 17);
            expect(tester.getCenter(titleFinder).dx, closeTo(187.5, 1));
          } else {
            final photo = surface == 'accounts'
                ? QirshSectionPhoto.accounts : QirshSectionPhoto.goals;
            final hero = tester.widget<QirshSectionHero>(find.byType(QirshSectionHero));
            expect(hero.photo, photo);
            // v2 title.large (Alexandria 700 30/38).
            expect(titleText.style?.fontSize, 30);
            expect(titleText.style?.color, Colors.white);
            expect(find.byWidgetPredicate((widget) => widget is Image &&
                widget.image is AssetImage &&
                (widget.image as AssetImage).assetName == photo.asset), findsOneWidget);
            expect(find.byType(AppBar), findsNothing);
          }
          expect(find.byType(BackButton).hitTestable(), findsOneWidget);
          if (surface == 'accounts') {
            expect(find.text(l10n.accSubtitle), findsOneWidget);
          }
          if (surface == 'achievements') {
            expect(find.text(l10n.achSubtitle), findsOneWidget);
          }
          if (surface == 'goals') {
            expect(find.byTooltip(l10n.bdgAddGoal).hitTestable(), findsOneWidget);
            expect(tester.widget<PlanningHeroTabs>(find.descendant(
                of: header, matching: find.byType(PlanningHeroTabs))).tab, 2);
            if (state == 'data') {
              // v2: the total-saved summary is a soft CalmFinancialSummary
              // card under the photo hero (it was a QirshPhotoCard).
              final summary = tester.widget<CalmFinancialSummary>(
                  find.byType(CalmFinancialSummary));
              expect(summary.label, l10n.goalTotalSavedAll);
              expect(find.text(l10n.goalTotalSavedAll), findsOneWidget);
            }
          }
          expect(tester.takeException(), isNull);
          await tester.tap(find.byType(BackButton));
          for (var frame = 0; frame < 20 && header.evaluate().isNotEmpty; frame++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(header, findsNothing);
          expect(find.text('Open surface'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        });
      }
    }
  }
}
