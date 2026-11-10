import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/formatters.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_format.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/dashboard/widgets/daily_spend_card.dart';
import 'package:money_companion/features/dashboard/widgets/home_overview_cards.dart';
import 'package:money_companion/features/plans/plans_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

GoalEntity _goal() => GoalEntity(id: 'synthetic-goal', name: 'Demo goal',
  currency: 'KWD', targetMoney: Money(98765, 'KWD'), savedMoney: Money(12345, 'KWD'),
  lastNotifiedSavedMoney: Money.zero('KWD'), vaultSkin: 'classic',
  status: 'active', createdAt: DateTime(2026, 1, 1));

PlanProgress _plan(bool expired) {
  final now = DateTime.now();
  final plan = PlanEntity(id: 'synthetic-plan', name: 'Demo plan',
    budgetAmountMoney: Money(100000, 'KWD'), currency: 'KWD',
    startDate: DateTime(2020),
    endDate: expired ? DateTime(2021) : now.add(const Duration(days: 7, hours: 12)),
    accountIds: const [], cardLast4s: const [], status: PlanStatus.active,
    createdAt: DateTime(2026, 1, 1));
  final spent = Money(46142, 'KWD');
  return PlanProgress(expired ? plan : plan.copyWith(
    budgetAmountMoney: Money(spent.minorUnits + 12345 * plan.daysLeft, 'KWD')), spent);
}

void main() {
  Future<AppL10n> pump(WidgetTester tester, Widget child,
      String language, ThemeData theme) async {
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
    await tester.pumpWidget(MaterialApp(theme: theme, locale: Locale(language),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: Scaffold(body: SingleChildScrollView(child: Padding(
        padding: const EdgeInsets.all(16), child: child))),
    ));
    await tester.pumpAndSettle();
    return AppL10n.of(tester.element(find.byType(Scaffold)));
  }

  for (final language in ['ar', 'en']) {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      for (final privacy in [true, false]) {
        for (final expired in [true, false]) {
          testWidgets('goals/plans $language ${theme.brightness.name} privacy$privacy expired$expired preserve amount privacy and KWD precision',
              (tester) async {
            final goal = _goal();
            final plan = _plan(expired);
            var goalTaps = 0;
            var planTaps = 0;
            var newTaps = 0;
            final l10n = await pump(tester, GoalsPlansRail(
              goals: [goal], plans: [plan], privacyMode: privacy,
              onGoalTap: () => goalTaps++, onPlanTap: () => planTaps++,
              onNewGoal: () => newTaps++,
            ), language, theme);
            final line = expired
                ? l10n.planSpent(privacy ? '••••' : '46.142')
                : l10n.planPerDayLeft(privacy ? '••••' : '12.345');
            final rendered = tester.widgetList<Text>(find.byType(Text))
                .map((t) => t.data).toList();
            expect(rendered, containsAll([
              privacy ? '•••• / ••••' : '12.345 / 98.765', line,
            ]));
            await tester.tap(find.text('Demo goal'));
            await tester.tap(find.text('Demo plan'));
            await tester.tap(find.text(l10n.homeNewGoal));
            expect([goalTaps, planTaps, newTaps], [1, 1, 1]);
            expect(goal.savedMoney, Money(12345, 'KWD'));
            expect(goal.targetMoney, Money(98765, 'KWD'));
            expect(plan.spent, Money(46142, 'KWD'));
            expect(plan.perDayLeft, expired ? Money.zero('KWD') : Money(12345, 'KWD'));
            expect(tester.takeException(), isNull);
          });
        }

        testWidgets('daily bars actual semantics $language ${theme.brightness.name} privacy$privacy hide or announce exact signed KWD amounts',
            (tester) async {
          final handle = tester.ensureSemantics();
          try {
          final values = [-2345, 5678, 9012, 3456, 7891, 2345, 12345];
          final days = [for (var i = 0; i < values.length; i++)
            DailySpend(day: DateTime(2026, 10, 26 + i), total: Money(values[i], 'KWD'))];
          final l10n = await pump(tester, DailySpendCard(
            todaySpend: days.last.total, lastSevenDays: days,
            averageSevenDays: Money(5469, 'KWD'), availableToday: null,
            todayVsYesterday: null, todayTransactions: const [],
            todayIsTruncated: false, catalog: CategoryCatalog(const []),
            currencyLabel: 'KWD', privacyMode: privacy,
          ), language, theme);
          final context = tester.element(find.byType(DailySpendCard));
          final labels = <String>[];
          void visit(SemanticsNode node) {
            labels.add(node.getSemanticsData().label);
            node.visitChildren((child) { visit(child); return true; });
          }
          visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
          final expected = [for (var i = 0; i < days.length; i++)
            l10n.homeDayAmountSemantics(i == days.length - 1
                ? l10n.txnRangeToday : Formatters.weekdayInitial(context, days[i].day),
              privacy ? '••••' : formatMoney(days[i].total))];
          expect(labels, containsAll(expected),
              reason: 'Actual semantics tree must use the same privacy setting as visible amounts.');
          if (privacy) {
            for (final day in days) {
              expect(labels.join('\n'), isNot(contains(formatMoney(day.total))));
            }
          }
          expect(days.map((d) => d.total.minorUnits), values);
          expect(tester.takeException(), isNull);
          } finally {
            handle.dispose();
          }
        });
      }
    }
  }
}
