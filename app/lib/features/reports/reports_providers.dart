import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/report_models.dart';
import '../../domain/finance/money.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../common/category_catalog.dart';
import '../dashboard/dashboard_providers.dart' show CategorySlice;
import '../transactions/transactions_providers.dart';

class ReportSection {
  const ReportSection({
    required this.total,
    required this.prevTotal,
    required this.refunds,
    required this.topCategories,
    required this.topMerchants,
    required this.dailySpend,
    required this.anomaly,
    this.transactionCount,
  });

  /// Net expense: `Σpayment + Σwithdrawal − Σrefund` (the documented contract).
  final Money total;
  final Money prevTotal;

  /// UX-022 — refunds included in [total], as a positive magnitude.
  ///
  /// Refunds were netted into the total silently, so a screen could show
  /// 2,120.00 for transactions of 420.00 + 1,899.00 with a 199.00 refund and
  /// offer no way to understand the difference. Carrying the component lets the
  /// UI state `gross − refunds = net` instead of asking the user to trust it.
  final Money refunds;

  /// Expenses BEFORE refunds are deducted. Derived, never queried separately,
  /// so it cannot drift from [total].
  Money get grossExpense => total + refunds;

  bool get hasRefunds => !refunds.isZero;
  final List<CategorySlice> topCategories;
  final List<MerchantSpend> topMerchants;
  final List<DailySpend> dailySpend;
  final SpendingAnomaly? anomaly;
  final int? transactionCount;

  /// نسبة التغيّر مقابل الفترة السابقة (null إذا لا توجد فترة سابقة).
  double? get deltaPercent => prevTotal.isZero
      ? null
      : (total - prevTotal).toDouble() / prevTotal.toDouble();

  Money get averageDaily {
    if (dailySpend.isEmpty) return Money.zero(total.currency);
    return Money.sum(dailySpend.map((day) => day.total), total.currency)
        .applyRate(
      rateNumerator: BigInt.one,
      rateDenominator: BigInt.from(dailySpend.length),
    );
  }

  Money get highestDaily {
    if (dailySpend.isEmpty) return Money.zero(total.currency);
    return dailySpend
        .map((day) => day.total)
        .reduce((a, b) => a.compareTo(b) > 0 ? a : b);
  }

  /// أفضل يوم توفيرًا = اليوم الوحيد بأقل إنفاق غير صفري.
  DailySpend? get bestSavingsDay {
    final zero = Money.zero(total.currency);
    final active =
        dailySpend.where((d) => d.total.compareTo(zero) > 0).toList();
    if (active.isEmpty) return null;
    return active.reduce((a, b) => a.total.compareTo(b.total) < 0 ? a : b);
  }

  /// أكبر فئة إنفاق.
  CategorySlice? get topCategory =>
      topCategories.isEmpty ? null : topCategories.first;

  /// أكبر متجر إنفاقًا.
  MerchantSpend? get topMerchant =>
      topMerchants.isEmpty ? null : topMerchants.first;
}

class SpendingAnomaly {
  const SpendingAnomaly({
    required this.day,
    required this.total,
    required this.baseline,
    required this.ratio,
  });

  final DateTime day;
  final Money total;
  final Money baseline;
  final double ratio;
}

class ReportsBundle {
  const ReportsBundle({required this.weekly, required this.monthly});

  final ReportSection weekly;
  final ReportSection monthly;
}

DateTime _weekStartSaturday(DateTime now) {
  final daysSinceSat = (now.weekday - DateTime.saturday) % 7;
  return DateTime(now.year, now.month, now.day)
      .subtract(Duration(days: daysSinceSat));
}

/// Owner brief 4.6: whether transactions in the report's account scope are
/// waiting for review. Totals only count confirmed transactions, so the report
/// says so when there are some. Re-runs with [reportsProvider].
final reportsHasPendingReviewProvider = FutureProvider<bool>((ref) async {
  await ref.watch(reportsProvider.future);
  final txRepo = ref.watch(transactionRepositoryProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final selectedAccountId = ref.watch(activeAccountIdProvider);
  final selected = selectedAccountId == null
      ? null
      : await accountRepo.getById(selectedAccountId);
  final accountId = (selected ?? await accountRepo.getDefault())?.id;
  final pending = await txRepo.getTransactionPage(
    limit: 1,
    filter: TransactionPageFilter(pendingOnly: true, accountId: accountId),
  );
  return pending.isNotEmpty;
});

final reportsProvider = FutureProvider<ReportsBundle>((ref) async {
  ref.watch(scopedRevisionProvider(kReportsRevisionTables));
  final txRepo = ref.watch(transactionRepositoryProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final catalog = await ref.watch(categoryCatalogProvider.future);
  final selectedAccountId = ref.watch(activeAccountIdProvider);
  final selectedAccount = selectedAccountId == null
      ? null
      : await accountRepo.getById(selectedAccountId);
  final defaultAccount = await accountRepo.getDefault();
  final activeAccount = selectedAccount ?? defaultAccount;
  final accountId = activeAccount?.id;
  final String currency =
      activeAccount?.currency ?? (await ref.watch(baseCurrencyProvider.future));
  final now = DateTime.now();
  final range =
      effectiveTransactionsRange(ref.watch(transactionsDateRangeProvider));
  final rangeEnd = range.to.isAfter(now) ? now : range.to;

  Future<ReportSection> section(
      DateTime from, DateTime to, DateTime prevFrom, DateTime prevTo) async {
    // MALI-063n: always the canonical Drift aggregates (the dormant Supabase
    // summary path is retired).
    final total = await txRepo.expenseTotalBetween(
        from: from, to: to, currency: currency, accountId: accountId);
    final prevTotal = await txRepo.expenseTotalBetween(
        from: prevFrom, to: prevTo, currency: currency, accountId: accountId);
    // UX-022 — one of `total`'s own inputs, so the screen can explain it.
    final refunds = await txRepo.refundTotalBetween(
        from: from, to: to, currency: currency, accountId: accountId);
    final breakdown = await txRepo.categoryBreakdown(
        from: from, to: to, currency: currency, accountId: accountId);
    final previousBreakdown = await txRepo.categoryBreakdown(
        from: prevFrom, to: prevTo, currency: currency, accountId: accountId);
    final previousByCategory = {
      for (final item in previousBreakdown) item.categoryId: item.total,
    };
    final sumAll = Money.sum(breakdown.map((item) => item.total), currency);
    final topCategories = <CategorySlice>[];
    for (final item in breakdown.take(18)) {
      final view =
          catalog.byId(item.categoryId) ?? catalog.byKey(item.categoryId);
      if (view == null) continue;
      topCategories.add(CategorySlice(
        category: view,
        total: item.total,
        percent: sumAll.isZero ? 0 : item.total.toDouble() / sumAll.toDouble(),
        count: item.count,
        refunds: item.refunds,
        previousTotal: previousByCategory[item.categoryId] ?? Money.zero(currency),
      ));
    }
    final topMerchants = await txRepo.merchantBreakdown(
        from: from, to: to, currency: currency, limit: 8, accountId: accountId);
    final dailySpend = await txRepo.dailyExpenseTotals(
        from: from, to: to, currency: currency, accountId: accountId);
    return ReportSection(
      total: total,
      prevTotal: prevTotal,
      refunds: refunds,
      topCategories: topCategories,
      topMerchants: topMerchants,
      dailySpend: dailySpend,
      anomaly: detectSpendingAnomaly(dailySpend),
      transactionCount: breakdown.fold<int>(0, (count, item) => count + item.count),
    );
  }

  // أسبوعي (يبدأ السبت) — مقارنة بنفس المدى من الأسبوع السابق.
  final weekStart = _weekStartSaturday(now);
  final weekElapsed = now.difference(weekStart);
  final prevWeekStart = weekStart.subtract(const Duration(days: 7));
  final weekly = await section(
      weekStart, now, prevWeekStart, prevWeekStart.add(weekElapsed));

  // الفترة المختارة — مقارنة بنفس طول الفترة السابقة.
  final rangeStart =
      DateTime(range.from.year, range.from.month, range.from.day);
  final daysInRange =
      rangeEnd.difference(rangeStart).inDays.abs().clamp(1, 3660) + 1;
  final prevRangeStart = rangeStart.subtract(Duration(days: daysInRange));
  // MALI-028: the previous period ends where the current one begins — a genuine
  // exclusive boundary, not an epsilon-adjusted last instant.
  final prevRangeEnd = rangeStart;
  final monthly =
      await section(rangeStart, rangeEnd, prevRangeStart, prevRangeEnd);

  return ReportsBundle(weekly: weekly, monthly: monthly);
});

SpendingAnomaly? detectSpendingAnomaly(List<DailySpend> dailySpend) {
  if (dailySpend.isEmpty) return null;
  final currency = dailySpend.first.total.currency;
  final zero = Money.zero(currency);
  final activeDays = dailySpend
      .where((day) => day.total.compareTo(zero) > 0)
      .toList(growable: false);
  if (activeDays.length < 4) return null;

  final candidate = activeDays.reduce(
    (a, b) => a.total.compareTo(b.total) >= 0 ? a : b,
  );
  final baselineDays =
      activeDays.where((day) => !_isSameDate(day.day, candidate.day));
  final baselineTotal =
      Money.sum(baselineDays.map((day) => day.total), currency);
  final baselineCount = activeDays.length - 1;
  if (baselineCount <= 0) return null;

  final baseline = baselineTotal.applyRate(
    rateNumerator: BigInt.one,
    rateDenominator: BigInt.from(baselineCount),
  );
  if (baseline.compareTo(zero) <= 0) return null;

  final ratio = candidate.total.toDouble() / baseline.toDouble();
  final difference = candidate.total - baseline;
  if (ratio < 1.8 || difference.compareTo(Money.parse('75', currency)) < 0) {
    return null;
  }

  return SpendingAnomaly(
    day: candidate.day,
    total: candidate.total,
    baseline: baseline,
    ratio: ratio,
  );
}

bool _isSameDate(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}
