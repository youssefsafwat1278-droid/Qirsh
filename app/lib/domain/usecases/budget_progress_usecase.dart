import '../entities/budget_entity.dart';
import '../entities/engagement_entities.dart';
import '../finance/budget_period.dart';
import '../finance/money.dart';
import '../reporting/date_range.dart';
import '../repositories/budget_repository.dart';
import '../repositories/transaction_repository.dart';
import 'engagement_usecase.dart';

typedef FetchBudgetBatchSpent = Future<Map<String, Money>> Function({
  required DateTime from,
  required DateTime to,
});

class BudgetProgressUseCase {
  BudgetProgressUseCase({
    required BudgetRepository budgetRepository,
    required TransactionRepository transactionRepository,
    RecordEngagementUseCase? recordEngagementUseCase,
    FetchBudgetBatchSpent? fetchBatchSpent,
    this.onMonthUnderBudget,
  })  : _budgetRepository = budgetRepository,
        _transactionRepository = transactionRepository,
        _recordEngagementUseCase = recordEngagementUseCase,
        _fetchBatchSpent = fetchBatchSpent;

  final BudgetRepository _budgetRepository;
  final TransactionRepository _transactionRepository;
  final RecordEngagementUseCase? _recordEngagementUseCase;
  final FetchBudgetBatchSpent? _fetchBatchSpent;
  final Future<void> Function(DateTime completedAt)? onMonthUnderBudget;
  Future<BudgetProgressSnapshot>? _inFlight;

  Future<BudgetProgressSnapshot> call({DateTime? now}) async {
    final inFlight = _inFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final future = _calculate(now: now);
    _inFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    }
  }

  Future<BudgetProgressSnapshot> _calculate({DateTime? now}) async {
    final current = now ?? DateTime.now().toUtc();
    final budgets = (await _budgetRepository.getAll())
        .where((budget) => budget.isActive)
        .toList();
    final entries = <BudgetProgressEntry>[];
    final currentPeriods = <BudgetPeriod, (DateTime, DateTime)>{
      for (final period in BudgetPeriod.values)
        period: _currentPeriodFor(period, current),
    };
    final batchSpent = await _fetchCurrentBatchSpent(budgets, currentPeriods);

    for (final budget in budgets) {
      final normalizedBudget = await _rollBudgetIfNeeded(budget, current);
      final period = currentPeriods[normalizedBudget.period]!;
      final spent = batchSpent?[normalizedBudget.id] ??
          await _spentForBudget(normalizedBudget, period);
      final ratio = normalizedBudget.amountMoney.isZero
          ? 0.0
          : spent.toDouble() / normalizedBudget.amountMoney.toDouble();
      final remaining = normalizedBudget.amountMoney - spent;
      // The budget's OWN threshold, not a constant. This was a hardcoded 0.8
      // and was the second place the number lived — the alert planner had its
      // own 0.75, so the bar could read "warning" while no alert had been sent,
      // or the reverse. Both now read the same persisted field.
      final warnAt = BudgetEntity.normalizeAlertThreshold(
            normalizedBudget.alertThresholdPercent,
          ) /
          100;
      final health = ratio >= 1
          ? BudgetHealth.over
          : ratio >= warnAt
              ? BudgetHealth.warning
              : BudgetHealth.safe;
      final entry = BudgetProgressEntry(
        budget: normalizedBudget,
        spent: spent,
        remaining: remaining,
        ratio: ratio,
        health: health,
        periodStart: period.$1,
        periodEnd: period.$2,
      );
      entries.add(entry);
    }

    entries.sort((a, b) => b.ratio.compareTo(a.ratio));
    return BudgetProgressSnapshot(entries: entries);
  }

  Future<Map<String, Money>?> _fetchCurrentBatchSpent(
    List<BudgetEntity> budgets,
    Map<BudgetPeriod, (DateTime, DateTime)> periods,
  ) async {
    final fetch = _fetchBatchSpent;
    if (fetch == null || budgets.isEmpty) return null;
    final result = <String, Money>{};
    for (final entry in periods.entries) {
      final ids = budgets
          .where((budget) => budget.period == entry.key)
          .map((budget) => budget.id)
          .toSet();
      if (ids.isEmpty) continue;
      final spent = await fetch(
        from: entry.value.$1,
        to: entry.value.$2.add(const Duration(milliseconds: 1)),
      );
      for (final id in ids) {
        final value = spent[id];
        if (value != null) result[id] = value;
      }
    }
    return result;
  }

  Future<BudgetEntity> _rollBudgetIfNeeded(
    BudgetEntity budget,
    DateTime now,
  ) async {
    final expectedStart = _currentPeriodFor(budget.period, now).$1;
    if (budget.startDate.isAtSameMomentAs(expectedStart)) {
      return budget;
    }

    final previousPeriod = _periodForStart(budget.period, budget.startDate);
    final previousSpent = await _spentForBudget(budget, previousPeriod);

    if (budget.period == BudgetPeriod.monthly &&
        !previousPeriod.$2.isAfter(now) &&
        !budget.startDate.isAfter(previousPeriod.$1) &&
        previousSpent.minorUnits > 0 &&
        previousSpent.compareTo(budget.amountMoney) <= 0) {
      await onMonthUnderBudget?.call(previousPeriod.$2);
    }

    if (budget.period == BudgetPeriod.daily &&
        previousSpent.compareTo(budget.amountMoney) <= 0 &&
        _recordEngagementUseCase != null) {
      await _recordEngagementUseCase(
        action: EngagementAction.dailyBudgetKept,
        occurredAt: previousPeriod.$2.subtract(const Duration(seconds: 1)),
      );
    }

    final updated = budget.copyWith(
      startDate: expectedStart,
      // Period roll resets the notified-spent to an EXACT zero in the budget's
      // own currency (canonical persistence, not a display double).
      lastNotifiedSpentMoney: Money(0, budget.currency),
      lastNotifiedPeriodStart: expectedStart,
    );
    return _budgetRepository.save(updated);
  }

  // MALI-049n/028 — the ONE canonical budget-period resolver (genuine half-open
  // `[from, to)`, Saturday-anchored week, no epsilon end). The current period
  // contains `now`; a rolled-over period contains its own `start`.
  (DateTime, DateTime) _currentPeriodFor(BudgetPeriod period, DateTime now) {
    final range = budgetPeriodContaining(period, now);
    return (range.from, range.to);
  }

  (DateTime, DateTime) _periodForStart(BudgetPeriod period, DateTime start) {
    final range = budgetPeriodContaining(period, start);
    return (range.from, range.to);
  }

  Future<Money> _spentForBudget(
    BudgetEntity budget,
    (DateTime, DateTime) period,
  ) =>
      budgetSpent(
        _transactionRepository,
        budget,
        DateRange(period.$1, period.$2),
      );
}
