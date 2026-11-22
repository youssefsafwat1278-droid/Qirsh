import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/services/budget_alert_planner.dart';

BudgetEntity _budget({
  String id = 'b1',
  String categoryId = 'food',
  int amountMinor = 100000,
}) {
  return BudgetEntity(
    id: id,
    categoryId: categoryId,
    currency: 'SAR',
    amountMoney: Money(amountMinor, 'SAR'),
    period: BudgetPeriod.monthly,
    startDate: DateTime.utc(2026, 7),
    isActive: true,
    lastNotifiedSpentMoney: Money(0, 'SAR'),
    lastNotifiedPeriodStart: DateTime.utc(2026, 7),
  );
}

BudgetProgressEntry _entry({
  required int amountMinor,
  required int spentMinor,
  String id = 'b1',
  String categoryId = 'food',
}) {
  final budget =
      _budget(id: id, categoryId: categoryId, amountMinor: amountMinor);
  final spent = Money(spentMinor, 'SAR');
  final ratio = budget.amountMoney.isZero
      ? 0.0
      : spent.toDouble() / budget.amountMoney.toDouble();
  return BudgetProgressEntry(
    budget: budget,
    spent: spent,
    remaining: budget.amountMoney - spent,
    ratio: ratio,
    health: ratio >= 1
        ? BudgetHealth.over
        : (ratio >= 0.8 ? BudgetHealth.warning : BudgetHealth.safe),
    periodStart: DateTime.utc(2026, 7),
    periodEnd: DateTime.utc(2026, 7, 31),
  );
}

void main() {
  const planner = BudgetAlertPlanner();
  final now = DateTime.utc(2026, 7, 15);

  test('no alert below the budget\'s threshold (default 80)', () {
    final content = planner.plan(
      entry: _entry(amountMinor: 100000, spentMinor: 50000),
      now: now,
      currencyLabel: 'ريال',
      categoryLabel: 'الطعام',
      accountLabel: 'الراجحي',
    );
    expect(content, isNull);
  });

  test('at the threshold, a warning alert names the category', () {
    final content = planner.plan(
      entry: _entry(amountMinor: 100000, spentMinor: 80000),
      now: now,
      currencyLabel: 'ريال',
      categoryLabel: 'الطعام',
      accountLabel: 'الراجحي',
    );
    expect(content, isNotNull);
    expect(content!.type, NotificationType.budgetWarning);
    expect(content.title, contains('الطعام'));
  });

  test('90%-99% spent produces the "about to run out" escalation', () {
    final content = planner.plan(
      entry: _entry(amountMinor: 100000, spentMinor: 95000),
      now: now,
      currencyLabel: 'ريال',
      categoryLabel: 'الطعام',
      accountLabel: 'الراجحي',
    );
    expect(content, isNotNull);
    expect(content!.type, NotificationType.budgetWarning);
    expect(content.title, contains('على وشك الاكتمال'));
  });

  test('100%+ spent produces an over-budget alert', () {
    final content = planner.plan(
      entry: _entry(amountMinor: 100000, spentMinor: 120000),
      now: now,
      currencyLabel: 'ريال',
      categoryLabel: 'الطعام',
      accountLabel: 'الراجحي',
    );
    expect(content, isNotNull);
    expect(content!.type, NotificationType.budgetOver);
    expect(content.title, contains('تجاوزت'));
    expect(content.body, contains('200'));
  });

  test('deleted spend no longer silences the alert it was notified at', () {
    // Alerted "exceeded" at 7,522 earlier this period; those transactions
    // were deleted and the spend is now 245.50 of a 200 budget.
    final fresh = _entry(amountMinor: 20000, spentMinor: 24550);
    final entry = BudgetProgressEntry(
      budget: fresh.budget.copyWith(lastNotifiedSpentMoney: Money(752200, 'SAR')),
      spent: fresh.spent,
      remaining: fresh.remaining,
      ratio: fresh.ratio,
      health: fresh.health,
      periodStart: fresh.periodStart,
      periodEnd: fresh.periodEnd,
    );
    final content = planner.plan(
      entry: entry,
      now: now,
      currencyLabel: 'ريال',
      categoryLabel: 'الطعام',
      accountLabel: 'الراجحي',
    );
    expect(content?.type, NotificationType.budgetOver);
  });

  test('different budgets produce different notification ids', () {
    final a = planner.plan(
      entry: _entry(
          id: 'b1',
          categoryId: 'food',
          amountMinor: 100000,
          spentMinor: 120000),
      now: now,
      currencyLabel: 'ريال',
      categoryLabel: 'الطعام',
      accountLabel: 'الراجحي',
    )!;
    final b = planner.plan(
      entry: _entry(
          id: 'b2',
          categoryId: 'transport',
          amountMinor: 100000,
          spentMinor: 120000),
      now: now,
      currencyLabel: 'ريال',
      categoryLabel: 'المواصلات',
      accountLabel: 'الراجحي',
    )!;
    expect(a.notifId, isNot(b.notifId));
  });

  test('same budget/period/bucket produces a stable notification id', () {
    final a = planner.plan(
      entry: _entry(amountMinor: 100000, spentMinor: 120000),
      now: now,
      currencyLabel: 'ريال',
      categoryLabel: 'الطعام',
      accountLabel: 'الراجحي',
    )!;
    final b = planner.plan(
      entry: _entry(amountMinor: 100000, spentMinor: 130000),
      now: now.add(const Duration(hours: 2)),
      currencyLabel: 'ريال',
      categoryLabel: 'الطعام',
      accountLabel: 'الراجحي',
    )!;
    expect(a.notifId, b.notifId);
  });
}
