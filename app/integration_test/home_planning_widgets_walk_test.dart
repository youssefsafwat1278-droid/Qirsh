import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/l10n_ext.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/dashboard/dashboard_providers.dart';
import 'package:money_companion/features/dashboard/widgets/budgets_card.dart';
import 'package:money_companion/features/dashboard/widgets/home_overview_cards.dart';
import 'package:money_companion/features/plans/plans_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Home planning cards fit, preserve taps and hide private values',
      (tester) async {
    final now = DateTime.now();
    Money egp(String value) => Money.parse(value, 'EGP');
    for (final (locale, dark, privacy) in [
      ('en', false, false),
      ('ar', true, false),
      ('en', false, true),
    ]) {
      final taps = <String>[];
      await tester.pumpWidget(MaterialApp(
        locale: Locale(locale),
        theme: dark ? AppTheme.dark : AppTheme.light,
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: AppL10n.localizationsDelegates,
        debugShowCheckedModeBanner: false,
        home: Builder(builder: (context) {
          return Scaffold(
            appBar: AppBar(title: Text(context.l10n.homeGoalsAndPlans)),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                BudgetsCard(
                  entries: [
                    DashboardBudgetEntry(
                      budgetId: 'b',
                      label: locale == 'ar' ? 'كل المصروفات' : 'All expenses',
                      spent: egp('760'),
                      limit: egp('1000'),
                      ratio: 0.76,
                      period: BudgetPeriod.monthly,
                      alertThresholdPercent: 75,
                    ),
                    DashboardBudgetEntry(
                      budgetId: 'b2',
                      label: locale == 'ar' ? 'المطاعم' : 'Restaurants',
                      spent: egp('450'),
                      limit: egp('400'),
                      ratio: 1.125,
                      period: BudgetPeriod.weekly,
                    ),
                  ],
                  privacyMode: privacy,
                  onTap: () => taps.add('budget'),
                ),
                const SizedBox(height: 22),
                GoalsPlansRail(
                  goals: [
                    GoalEntity(
                      id: 'g',
                      name: locale == 'ar' ? 'رحلة الصيف' : 'Summer trip',
                      currency: 'EGP',
                      targetMoney: egp('3000'),
                      savedMoney: egp('1250'),
                      lastNotifiedSavedMoney: egp('0'),
                      vaultSkin: 'summer_trip',
                      status: 'active',
                      createdAt: now,
                    ),
                  ],
                  plans: [
                    PlanProgress(
                      PlanEntity(
                        id: 'p',
                        name: locale == 'ar' ? 'عطلة الأسبوع' : 'Weekend plan',
                        budgetAmountMoney: egp('1000'),
                        currency: 'EGP',
                        startDate: now,
                        endDate: now.add(const Duration(days: 5)),
                        accountIds: const [],
                        cardLast4s: const [],
                        status: PlanStatus.active,
                        createdAt: now,
                      ),
                      egp('350'),
                    ),
                  ],
                  privacyMode: privacy,
                  onGoalTap: () => taps.add('goal'),
                  onPlanTap: () => taps.add('plan'),
                  onNewGoal: () => taps.add('add'),
                ),
              ],
            ),
          );
        }),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(LinearProgressIndicator),
          privacy ? findsNothing : findsNWidgets(4));
      await tester
          .tap(find.text(locale == 'ar' ? 'كل المصروفات' : 'All expenses'));
      await tester
          .tap(find.text(locale == 'ar' ? 'رحلة الصيف' : 'Summer trip'));
      await tester.tap(find.byType(TextButton));
      expect(taps, ['budget', 'goal', 'add']);
      final name =
          'home-planning-$locale-${dark ? 'dark' : privacy ? 'private' : 'light'}';
      final png = await binding.takeScreenshot(name);
      const directory = String.fromEnvironment('QIRSH_PLANNING_PREVIEW_DIR');
      if (directory.isNotEmpty) {
        await File('$directory/$name.png').writeAsBytes(png);
      }
    }
  });
}
