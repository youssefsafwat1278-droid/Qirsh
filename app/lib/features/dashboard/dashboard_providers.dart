import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'home_hero_period_controller.dart';
export 'home_hero_period_controller.dart' show HeroPeriod;

import '../../core/di/app_providers.dart';
import '../../core/i18n/locale_provider.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/report_models.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/finance/account_scope.dart';
import '../../domain/finance/daily_allowance.dart';
import '../../domain/finance/period_comparison.dart';
import '../../domain/finance/budget_period.dart';
import '../../domain/finance/money.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../common/category_catalog.dart';
import '../transactions/transactions_providers.dart';

/// ملخص تقدّم ميزانية واحدة (كل الميزانيات الفعّالة)، تُعرض في قسم
/// "كل الميزانيات" على الداشبورد.
class DashboardBudgetEntry {
  const DashboardBudgetEntry({
    required this.budgetId,
    required this.label,
    required this.spent,
    required this.limit,
    required this.ratio,
    required this.period,
    this.accountId,
    this.accountName,
    this.alertThresholdPercent = BudgetEntity.defaultAlertThresholdPercent,
  });

  final String budgetId;
  final String label;
  final Money spent;
  final Money limit;
  final double ratio;
  final BudgetPeriod period;
  /// The budget's own warning threshold, carried so the dashboard bar turns
  /// amber at the same point the alert fires.
  final int alertThresholdPercent;
  final String? accountId;
  final String? accountName;
}

class CategorySlice {
  const CategorySlice({
    required this.category,
    required this.total,
    required this.percent,
    this.count = 0,
    this.refunds,
    this.previousTotal,
  });

  final CategoryView category;
  final Money total;
  final double percent; // 0..1
  final int count;

  /// The same category's total over the immediately preceding window of equal
  /// length. Null when that window was not measured. A measured zero still
  /// has no meaningful percentage baseline, so [changeRatio] is nullable.
  final Money? previousTotal;

  /// Change against [previousTotal], as a ratio. Null when there is nothing to
  /// compare against — a category that did not exist last period has no
  /// percentage change, and rendering "+100%" for it would be an invention.
  double? get changeRatio {
    final prev = previousTotal;
    if (prev == null || prev.isZero || prev.isNegative) return null;
    return (total - prev).toDouble() / prev.toDouble();
  }

  /// UX-022 — the refund magnitude netted into [total], when there is one.
  /// تسوق displayed 1,700.00, which matched no transaction on the screen.
  final Money? refunds;

  bool get hasRefunds => (refunds?.minorUnits ?? 0) > 0;
}

class DashboardData {
  const DashboardData({
    required this.savedThisMonth,
    required this.spentThisMonth,
    required this.incomeThisMonth,
    required this.todaySpend,
    required this.todayIncome,
    required this.weekIncome,
    required this.balance,
    required this.dailyBudgetLimit,
    required this.weeklyBudgetLimit,
    required this.monthlyBudgetLimit,
    required this.monthlyBudgetRatio,
    required this.budgetPeriod,
    required this.currency,
    required this.streak,
    required this.topCategories,
    required this.dailySpendTrend,
    required this.lastSevenDays,
    required this.todayTransactions,
    required this.availableToday,
    required this.monthElapsedRatio,
    required this.categoryCount,
    required this.topMerchants,
    required this.recent,
    required this.catalog,
    required this.pendingReview,
    required this.pendingReviewTotal,
    required this.weekSpend,
    required this.previousWeekSpend,
    required this.projectedMonthSpend,
    required this.subscriptions,
    required this.subscriptionsMonthlyTotal,
    required this.range,
    required this.currencyTotals,
    required this.budgetProgress,
    required this.rangeExpense,
    required this.rangeIncome,
    this.activeGoal,
    this.monthDailySpend = const <DailySpend>[],
    this.hasAnyTransactions = true,
  });

  final Money savedThisMonth;
  final Money spentThisMonth;
  final Money incomeThisMonth;
  final Money todaySpend;
  final Money todayIncome;
  final Money weekIncome;
  final Money? balance;
  final Money dailyBudgetLimit;
  final Money weeklyBudgetLimit;
  final Money monthlyBudgetLimit;
  final double monthlyBudgetRatio;
  final String currency;

  /// Legacy label kept for older widgets; monthly is the main dashboard ring.
  final BudgetPeriod? budgetPeriod;
  final StreakEntity streak;
  final List<CategorySlice> topCategories;
  final List<double> dailySpendTrend;

  /// Exactly seven ordered slots, oldest → today, gaps filled with zero.
  ///
  /// Was `weeklyDailySpend`, a Saturday→now window that had no consumer: on a
  /// Saturday it held ONE day, which would have rendered a "last 7 days" chart
  /// with a single bar. The window is now a rolling seven days, and the name
  /// says so.
  final List<DailySpend> lastSevenDays;

  /// Net spend per day of the CALENDAR month so far, whatever range is
  /// selected — the source of the hero's month pace line. Days without spend
  /// are absent, not zero.
  final List<DailySpend> monthDailySpend;

  /// False only when the selected account has never had a transaction. That
  /// is a first-run Home, which is a different screen from "this period is
  /// empty" — [isEmpty] answers the second question, not this one.
  final bool hasAnyTransactions;

  /// Today's rows, newest first — the source for «أعلى ٣ النهاردة».
  ///
  /// Sliced from the same bounded 50-row recency read the dashboard already
  /// performs, so it costs no extra query. See [todayIsTruncated] for the
  /// bound this places on the count.
  final List<TransactionEntity> todayTransactions;

  /// What is still available to spend today from the monthly budget.
  /// Null when no monthly budget is set — the card must say so rather than
  /// render a zero that looks like "you have nothing left".
  final Money? availableToday;

  /// How far through the calendar month we are, 0..1 — the "you should be
  /// here" mark on the budget meter. Being at 75% of the budget on day 20 of
  /// 31 is only meaningful next to the 65% the month itself has elapsed.
  final double monthElapsedRatio;

  /// Total categories with spend in the period. [topCategories] is a slice of
  /// it, so a header can honestly say «٣ من ١٢» instead of implying it is all.
  final int categoryCount;

  final List<MerchantSpend> topMerchants;
  final List<TransactionEntity> recent;
  final CategoryCatalog catalog;
  final List<TransactionEntity> pendingReview;
  final Money pendingReviewTotal;
  final Money weekSpend;
  final Money previousWeekSpend;
  final double projectedMonthSpend;
  final List<RecurringCandidate> subscriptions;
  final Money subscriptionsMonthlyTotal;
  final TransactionsDateRange range;
  final List<CurrencyTotal> currencyTotals;
  final List<DashboardBudgetEntry> budgetProgress;
  final GoalEntity? activeGoal;

  /// Expense/income totals for the currently selected filter [range] — not
  /// tied to the calendar month, unlike [spentThisMonth]/[incomeThisMonth].
  /// Feeds the dashboard's income-vs-expense summary card.
  final Money rangeExpense;
  final Money rangeIncome;

  /// عرض إجماليات منفصلة لكل عملة (عند تعدّد العملات في «كل الحسابات»).
  bool get hasMultipleCurrencies => currencyTotals.length > 1;

  bool get isEmpty => recent.isEmpty;

  /// CAPPED at 3 — the pending query is `limit: 3`, so this is "at least N",
  /// never the true pending total. Any label built from it must say so
  /// («٣+»), otherwise the screen states a count it did not measure.
  int get pendingReviewCount => pendingReview.length;
  bool get pendingReviewIsCapped => pendingReview.length >= 3;
  int get subscriptionsCount => subscriptions.length;

  /// Net spend for the day before today, from [lastSevenDays].
  Money get yesterdaySpend => lastSevenDays.length >= 2
      ? lastSevenDays[lastSevenDays.length - 2].total
      : Money.zero(currency);

  /// Change in today's spend against yesterday, as a ratio. Null when
  /// yesterday was zero — a percentage against nothing is not a comparison.
  double? get todayVsYesterday {
    final y = yesterdaySpend;
    if (y.isZero || y.isNegative) return null;
    return (todaySpend - y).toDouble() / y.toDouble();
  }

  /// True when today's rows may be incomplete: the dashboard reads the 50 most
  /// recent transactions, so a day with 50+ of them is truncated and the count
  /// must not be presented as exact.
  bool get todayIsTruncated => todayTransactions.length >= 50;

  double get weekChangeRatio {
    if (previousWeekSpend.isZero) return weekSpend.isZero ? 0 : 1;
    return (weekSpend - previousWeekSpend).toDouble() /
        previousWeekSpend.toDouble();
  }

  // ─── درجة قرش ───────────────────────────────────────────────────────────────

  /// التزام بالميزانية: 0-100. إذا لم تُحدَّد ميزانية → 75 (محايد).
  double get budgetScore {
    if (monthlyBudgetLimit.isZero || monthlyBudgetLimit.isNegative) return 75;
    return ((1 - monthlyBudgetRatio).clamp(0.0, 1.0) * 100);
  }

  /// معدل الادخار: 0-100. إذا لم يوجد دخل → 50 (محايد).
  double get savingsScore {
    if (incomeThisMonth.isZero || incomeThisMonth.isNegative) return 50;
    return (((incomeThisMonth - spentThisMonth).toDouble() /
                incomeThisMonth.toDouble())
            .clamp(0.0, 1.0) *
        100);
  }

  /// انتظام التسجيل (streak): 0-100. 30 أسبوعًا = 100%.
  double get streakScore => (streak.currentStreak / 30).clamp(0.0, 1.0) * 100;

  /// تنوع الإنفاق بناءً على عدد الفئات: 0-100. 5 فئات أو أكثر = 100%.
  double get diversityScore => (topCategories.length / 5).clamp(0.0, 1.0) * 100;

  /// درجة قرش الإجمالية (0-100) — وزن مرجّح من المكونات الأربعة.
  int get qirshScore => (budgetScore * 0.35 +
          savingsScore * 0.30 +
          streakScore * 0.20 +
          diversityScore * 0.15)
      .round()
      .clamp(0, 100);

  /// تسمية الفترة للعرض: «اليوم» / «الأسبوع» / «الشهر».
  String budgetPeriodLabelIn(String languageCode) {
    final en = languageCode == 'en';
    return switch (budgetPeriod) {
      BudgetPeriod.daily => en ? 'Today' : 'اليوم',
      BudgetPeriod.weekly => en ? 'This week' : 'الأسبوع',
      BudgetPeriod.monthly => en ? 'This month' : 'الشهر',
      BudgetPeriod.yearly => en ? 'This year' : 'السنة',
      null => en ? 'This month' : 'الشهر',
    };
  }
}

/// الحساب المختار في الـ dashboard (null = الحساب الافتراضي الحالي).
final dashboardAccountProvider = activeAccountIdProvider;

/// HOME-LOCAL on purpose — it must not be `transactionsDateRangeProvider`.
///
/// That provider is shared by Transactions (list + total), the bills view,
/// Reports and Budgets. Wiring the hero's اليوم/الأسبوع/الشهر switch to it
/// would mean tapping «اليوم» on Home silently resets the Transactions tab's
/// paging and search, and re-scopes Reports and Budgets — a control changing
/// four screens the user cannot see.
///
/// No new query is needed either way: `todaySpend`, `weekSpend` and
/// `spentThisMonth` are all already on [DashboardData].
final heroPeriodProvider =
    StateNotifierProvider<HomeHeroPeriodController, HeroPeriod>(
      (_) => HomeHeroPeriodController(),
    );

final dashboardDataProvider = FutureProvider<DashboardData>((ref) async {
  ref.watch(financialRevisionProvider);
  // This provider composes a few display labels itself. It has no element
  // tree, but it does have `ref`, so it reads the same locale the UI does.
  final lang = ref.watch(localeProvider).languageCode;
  final txRepo = ref.watch(transactionRepositoryProvider);
  final goalRepo = ref.watch(goalRepositoryProvider);
  final budgetRepo = ref.watch(budgetRepositoryProvider);
  final gamificationRepo = ref.watch(gamificationRepositoryProvider);
  final userSettingsRepo = ref.watch(userSettingsRepositoryProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final catalog = await ref.watch(categoryCatalogProvider.future);
  final range =
      effectiveTransactionsRange(ref.watch(transactionsDateRangeProvider));
  // These reads are independent. Starting them together keeps a dashboard
  // refresh to one network round-trip instead of three when Supabase-primary
  // repositories are active.
  final settingsFuture = userSettingsRepo.getSettings();
  final accountsFuture = accountRepo.getAll();
  // C-9 — this provider is a READ. It must not create accounts or reassign
  // transactions: both repositories enqueue sync intent, so a mutating read
  // turned merely opening Home into durable financial state and cloud writes
  // (the same fault as F-020, where browsing rewrote the default account).
  //
  // The legacy per-currency repair now runs once at startup as an explicit
  // command — see AccountCurrencyRepairService, invoked by BootstrapRunner
  // before the financial UI is marked usable. A currency first seen AFTER
  // startup still gets its account at WRITE time, in the capture path
  // (`add_transaction_usecase.dart`, `_accountForCurrency`), so nothing here
  // depends on the read repairing anything.
  final (settings, accounts) = await (settingsFuture, accountsFuture).wait;
  final selectedAccountId = ref.watch(dashboardAccountProvider);
  AccountEntity? selectedAccount;
  AccountEntity? defaultAccount;
  for (final account in accounts) {
    if (account.id == selectedAccountId) selectedAccount = account;
    if (account.isDefault) defaultAccount = account;
  }
  // الحساب المختار غير موجود (حُذف) → ارجع للحساب الافتراضي، وليس كل الحسابات.
  final activeAccount = selectedAccount ??
      defaultAccount ??
      (accounts.isEmpty ? null : accounts.first);
  final accountId = activeAccount?.id;
  // The dashboard is a single-currency surface: a selected/default account is
  // authoritative; without an account, fall back to the base display currency.
  final displayCurrency = accountId != null
      ? activeAccount!.currency
      : await ref.watch(baseCurrencyProvider.future);

  final now = DateTime.now();
  final rangeStart =
      DateTime(range.from.year, range.from.month, range.from.day);
  final rangeEnd = range.to.isAfter(now) ? now : range.to;
  final daysInRange =
      rangeEnd.difference(rangeStart).inDays.abs().clamp(1, 3660) + 1;
  final previousStart = rangeStart.subtract(Duration(days: daysInRange));
  // MALI-028: the previous period ends where the current one begins — a genuine
  // exclusive boundary, not an epsilon-adjusted last instant.
  final previousEnd = rangeStart;
  final today = DateTime(now.year, now.month, now.day);
  final weekStart =
      today.subtract(Duration(days: (now.weekday - DateTime.saturday) % 7));
  // F-028 — compare like with like. This used to measure the PARTIAL current
  // week (weekStart → now) against the FULL previous week
  // (prevWeekStart → weekStart), which is not merely a different choice from
  // Reports — it is biased: on a Saturday morning it weighs a few hours against
  // a complete week and reports a near-total collapse in spending. Reports
  // already used an elapsed-matched window; both now share one definition.
  final previousWeek = elapsedMatchedPreviousWindow(
    currentStart: weekStart,
    now: now,
    periodLength: const Duration(days: 7),
  );

  // سارف/دخل الشهر ثابتان على الشهر الحالي بغض النظر عن الفلتر المختار.
  final calendarMonthStart = DateTime(now.year, now.month, 1);
  // MALI-063n: every total comes from the canonical Drift aggregates (the
  // dormant Supabase summary path is retired). Independent reads start together
  // so a refresh reflects a newly-saved transaction as soon as the slowest read
  // completes.
  final balanceFuture = txRepo.latestBalanceAfter(accountId: accountId);
  final thisMonthExpensesFuture = txRepo.expenseTotalBetween(
      from: calendarMonthStart,
      to: now,
      currency: displayCurrency,
      accountId: accountId);
  final thisMonthIncomeFuture = txRepo.incomeTotalBetween(
      from: calendarMonthStart,
      to: now,
      currency: displayCurrency,
      accountId: accountId);
  final prevMonthExpensesFuture = txRepo.expenseTotalBetween(
      from: previousStart,
      to: previousEnd,
      currency: displayCurrency,
      accountId: accountId);
  final weekSpendFuture = txRepo.expenseTotalBetween(
      from: weekStart,
      to: now,
      currency: displayCurrency,
      accountId: accountId);
  final todaySpendFuture = txRepo.expenseTotalBetween(
      from: today, to: now, currency: displayCurrency, accountId: accountId);
  final todayIncomeFuture = txRepo.incomeTotalBetween(
      from: today, to: now, currency: displayCurrency, accountId: accountId);
  final weekIncomeFuture = txRepo.incomeTotalBetween(
      from: weekStart,
      to: now,
      currency: displayCurrency,
      accountId: accountId);
  final previousWeekSpendFuture = txRepo.expenseTotalBetween(
      from: previousWeek.from,
      to: previousWeek.to,
      currency: displayCurrency,
      accountId: accountId);
  final rangeExpenseFuture = txRepo.expenseTotalBetween(
      from: rangeStart,
      to: rangeEnd,
      currency: displayCurrency,
      accountId: accountId);
  final rangeIncomeFuture = txRepo.incomeTotalBetween(
      from: rangeStart,
      to: rangeEnd,
      currency: displayCurrency,
      accountId: accountId);
  final (
    (
      thisMonthExpenses,
      thisMonthIncome,
      prevMonthExpenses,
      weekSpend,
      todaySpend,
      todayIncome,
      weekIncome,
      previousWeekSpend,
    ),
    (rangeExpense, rangeIncome, rawBalance),
  ) = await (
    (
      thisMonthExpensesFuture,
      thisMonthIncomeFuture,
      prevMonthExpensesFuture,
      weekSpendFuture,
      todaySpendFuture,
      todayIncomeFuture,
      weekIncomeFuture,
      previousWeekSpendFuture,
    ).wait,
    (rangeExpenseFuture, rangeIncomeFuture, balanceFuture).wait,
  ).wait;
  // Both groups have error consumers before either can fail. Waiting for the
  // groups together also drains every started read when this provider fails or
  // its scope is disposed.
  final balance =
      rawBalance?.currency == displayCurrency.toUpperCase() ? rawBalance : null;
  // B2-C — the 3 most-recent pending rows via a bounded SQL query (was a
  // .where(...).take(3) over the whole ledger). Same scope: pending status,
  // active-account (or all when none).
  final pendingReview = await txRepo.getTransactionPage(
    limit: 3,
    filter: TransactionPageFilter(pendingOnly: true, accountId: accountId),
  );
  final pendingReviewTotal = Money.sum(
    pendingReview
        .where(
            (tx) => tx.currency.toUpperCase() == displayCurrency.toUpperCase())
        .map((tx) => tx.amountMoney),
    displayCurrency,
  );
  final saved = prevMonthExpenses - thisMonthExpenses;
  // Start the remaining independent sections before awaiting any one of them.
  // This is especially important with direct Supabase repositories, where
  // every aggregate is otherwise a separate network wait.
  final allBudgetsFuture = budgetRepo.getAll();
  final breakdownFuture = txRepo.categoryBreakdown(
      from: rangeStart,
      to: rangeEnd,
      currency: displayCurrency,
      accountId: accountId);
  // The SAME breakdown over the immediately preceding window of equal length,
  // so «مطاعم +18%» is a measured comparison rather than a guess. Both bounds
  // were already computed for the period aggregates above.
  final previousBreakdownFuture = txRepo.categoryBreakdown(
      from: previousStart,
      to: previousEnd,
      currency: displayCurrency,
      accountId: accountId);
  final dailySpendTrendFuture = txRepo.dailyExpenseTotals(
      from: rangeStart,
      to: rangeEnd,
      currency: displayCurrency,
      accountId: accountId);
  // Rolling seven days (today included), NOT the calendar week: the Home card
  // renders seven fixed slots, and a Saturday-anchored window would hand it a
  // single bar every Saturday.
  final lastSevenDaysFuture = txRepo.dailyExpenseTotals(
    from: today.subtract(const Duration(days: 6)),
    to: now,
    currency: displayCurrency,
    accountId: accountId,
  );
  final topMerchantsFuture = txRepo.merchantBreakdown(
    from: rangeStart,
    to: rangeEnd,
    currency: displayCurrency,
    limit: 5,
    accountId: accountId,
  );
  final recentFuture = txRepo.getRecent(limit: 50, accountId: accountId);
  final monthDailyFuture = txRepo.dailyExpenseTotals(
    from: DateTime(now.year, now.month),
    to: now,
    currency: displayCurrency,
    accountId: accountId,
  );
  final streakFuture = gamificationRepo.getStreak();
  final subscriptionsFuture = txRepo.recurringCandidates(accountId: accountId);
  final goalsFuture = goalRepo.getAll();

  final (
    (
      allBudgets,
      breakdown,
      dailySpendRows,
      lastSevenDayRows,
      topMerchants,
      recentRows,
      streak,
      subscriptionRows,
      goals,
    ),
    previousBreakdown,
    monthDailyRows,
  ) = await (
    (
      allBudgetsFuture,
      breakdownFuture,
      dailySpendTrendFuture,
      lastSevenDaysFuture,
      topMerchantsFuture,
      recentFuture,
      streakFuture,
      subscriptionsFuture,
      goalsFuture,
    ).wait,
    previousBreakdownFuture,
    monthDailyFuture,
  ).wait;
  final activeBudgets = allBudgets.where((budget) {
    if (!budget.isActive) return false;
    if (budget.currency.toUpperCase() != displayCurrency.toUpperCase()) {
      return false;
    }
    // F-026 / OD-08 — one canonical scope. This used to be
    // `budget.accountId == accountId`, which EXCLUDED global budgets whenever an
    // account was selected — and `accountId` is virtually never null here, since
    // it falls back to the default account and then the first account. The Home
    // ring therefore computed over a different budget set than the Budgets
    // screen and the two disagreed, even though both call the same canonical
    // `budgetSpent`. The shared helper was never the problem; the input scope was.
    return AccountScope.resolve(accountId).includesBudget(budget.accountId);
  }).toList(growable: false);
  BudgetEntity? allExpensesFor(BudgetPeriod period) => activeBudgets
      .where((budget) => budget.isAllExpenses && budget.period == period)
      .fold<BudgetEntity?>(null, (prev, budget) => budget);

  final dailyBudget = allExpensesFor(BudgetPeriod.daily);
  final weeklyBudget = allExpensesFor(BudgetPeriod.weekly);
  final monthlyBudget = allExpensesFor(BudgetPeriod.monthly);
  final dailyBudgetLimit =
      dailyBudget?.amountMoney ?? Money.zero(displayCurrency);
  final weeklyBudgetLimit =
      weeklyBudget?.amountMoney ?? Money.zero(displayCurrency);
  var monthlyBudgetLimit =
      monthlyBudget?.amountMoney ?? Money.zero(displayCurrency);

  // لو المستخدم وزّع دخله على مظاريف شهرية ومفيش ميزانية شهرية عامة،
  // اعرض مجموع المظاريف كحد صرف شهري في الداشبورد بدون double count.
  if (monthlyBudgetLimit.isZero || monthlyBudgetLimit.isNegative) {
    monthlyBudgetLimit = Money.sum(
      activeBudgets
          .where((b) =>
              !b.isAllExpenses &&
              b.period == BudgetPeriod.monthly &&
              // §16/§6: only same-currency budgets fold into the display total —
              // never Money(EGP)+Money(SAR).
              b.currency.toUpperCase() == displayCurrency.toUpperCase())
          .map((b) => b.amountMoney),
      displayCurrency,
    );
  }
  final monthlyBudgetRatio = monthlyBudgetLimit.isZero
      ? 0.0
      : thisMonthExpenses.toDouble() / monthlyBudgetLimit.toDouble();

  final accountMap = {for (final a in accounts) a.id: a.name};
  final budgetProgress = await Future.wait(activeBudgets.map((budget) async {
    // MALI-049n: consumption comes from the budget's OWN stored period (via the
    // canonical resolver), NEVER the dashboard filter range — so a monthly
    // budget stays monthly when the filter is "last 90 days", a weekly budget
    // uses the canonical Saturday-start week, and the ring matches budget
    // detail / the repository aggregate for the same scope.
    final period = resolveBudgetPeriod(budget, now);
    final bSpent = await budgetSpent(
      txRepo,
      budget,
      period,
      fallbackAccountId: accountId,
    );
    final bRatio = budget.amountMoney.isZero
        ? 0.0
        : bSpent.toDouble() / budget.amountMoney.toDouble();
    final catView = catalog.byId(budget.categoryId);
    return DashboardBudgetEntry(
      budgetId: budget.id,
      label: budget.isAllExpenses
          ? (lang == 'en'
              ? BudgetEntity.allExpensesNameEn
              : BudgetEntity.allExpensesNameAr)
          : (catView?.name ?? (lang == 'en' ? 'Budget' : 'ميزانية')),
      spent: bSpent,
      limit: budget.amountMoney,
      ratio: bRatio,
      period: budget.period,
      alertThresholdPercent: budget.alertThresholdPercent,
      accountId: budget.accountId,
      accountName:
          budget.accountId != null ? accountMap[budget.accountId] : null,
    );
  }));

  final totalSpend =
      Money.sum(breakdown.map((item) => item.total), displayCurrency);
  // Previous-window totals, keyed by category, so each slice can carry its own
  // change. Keyed by the SAME id the current breakdown uses; a category absent
  // last period simply has no entry, which yields a null delta rather than a
  // fabricated «+100%».
  final previousByCategory = <String, Money>{
    for (final item in previousBreakdown) item.categoryId: item.total,
  };
  final topCategories = <CategorySlice>[];
  for (final item in breakdown.take(5)) {
    final view =
        catalog.byId(item.categoryId) ?? catalog.byKey(item.categoryId);
    if (view == null) continue;
    topCategories.add(
      CategorySlice(
        category: view,
        total: item.total,
        percent: totalSpend.isZero
            ? 0
            : item.total.toDouble() / totalSpend.toDouble(),
        count: item.count,
        previousTotal: previousByCategory[item.categoryId],
      ),
    );
  }
  final dailySpendTrend =
      dailySpendRows.map((day) => day.total.toDouble()).toList(growable: false);

  final recent = recentRows
      .where((tx) =>
          // Half-open [rangeStart, rangeEnd) — consistent with the aggregates.
          !tx.occurredAt.isBefore(rangeStart) &&
          tx.occurredAt.isBefore(rangeEnd))
      .take(10)
      .toList(growable: false);
  // Today's rows come off the SAME bounded read — deliberately NOT filtered by
  // the selected range, because «صرفت النهاردة» means today whatever period the
  // user is browsing. `todaySpend` above is the exact aggregate; this slice
  // only supplies the top-3 list (and is flagged truncated past 50 rows).
  final todayTransactions = recentRows
      .where((tx) =>
          !tx.occurredAt.isBefore(today) &&
          tx.currency.toUpperCase() == displayCurrency.toUpperCase())
      .toList(growable: false);
  final lastSevenDays = normalizeLastSevenDays(
    rows: lastSevenDayRows,
    today: today,
    currency: displayCurrency,
  );
  // الداشبورد يعرض عملة الحساب النشط فقط لتجنب جمع عملات مختلفة في رقم واحد.
  const currencyTotals = <CurrencyTotal>[];
  final subscriptions = subscriptionRows
      .where((item) =>
          item.currency.toUpperCase() == displayCurrency.toUpperCase())
      .take(3)
      .toList(growable: false);
  // §16 correction: subscriptions are already filtered to the display currency
  // above, so the monthly estimate total is an EXACT same-currency Money.sum —
  // never a double fold, never cross-currency.
  final subscriptionsMonthlyTotal = Money.sum(
    subscriptions.map((item) => item.estimatedAmountMoney),
    displayCurrency,
  );
  final projectedMonthSpend = daysInRange == 0
      ? thisMonthExpenses.toDouble()
      : (thisMonthExpenses.toDouble() / daysInRange) * 30;

  final activeGoal = goals
      .where((g) =>
          g.status == 'active' &&
          g.currency.toUpperCase() == displayCurrency.toUpperCase() &&
          (accountId == null || g.accountId == accountId))
      .fold<GoalEntity?>(null, (best, g) {
    if (best == null) return g;
    final progress = g.targetMoney.isZero
        ? 0.0
        : g.savedMoney.toDouble() / g.targetMoney.toDouble();
    final bestProgress = best.targetMoney.isZero
        ? 0.0
        : best.savedMoney.toDouble() / best.targetMoney.toDouble();
    return progress > bestProgress ? g : best;
  });

  return DashboardData(
    savedThisMonth: saved,
    spentThisMonth: thisMonthExpenses,
    incomeThisMonth: thisMonthIncome,
    todaySpend: todaySpend,
    todayIncome: todayIncome,
    weekIncome: weekIncome,
    balance: balance,
    dailyBudgetLimit: dailyBudgetLimit,
    weeklyBudgetLimit: weeklyBudgetLimit,
    monthlyBudgetLimit: monthlyBudgetLimit,
    monthlyBudgetRatio: monthlyBudgetRatio,
    budgetPeriod: monthlyBudgetLimit.isNegative || monthlyBudgetLimit.isZero
        ? null
        : BudgetPeriod.monthly,
    currency: displayCurrency,
    streak: streak,
    topCategories: topCategories,
    dailySpendTrend: dailySpendTrend,
    lastSevenDays: lastSevenDays,
    todayTransactions: todayTransactions,
    availableToday: dailyAllowance(
      monthlyLimit: monthlyBudgetLimit,
      spentThisMonth: thisMonthExpenses,
      now: now,
    ),
    monthElapsedRatio: now.day / DateTime(now.year, now.month + 1, 0).day,
    categoryCount: breakdown.length,
    topMerchants: topMerchants,
    recent: recent,
    catalog: catalog,
    pendingReview: pendingReview,
    pendingReviewTotal: pendingReviewTotal,
    weekSpend: weekSpend,
    previousWeekSpend: previousWeekSpend,
    projectedMonthSpend: projectedMonthSpend,
    subscriptions: subscriptions,
    subscriptionsMonthlyTotal: subscriptionsMonthlyTotal,
    range: range,
    currencyTotals: currencyTotals,
    budgetProgress: budgetProgress,
    activeGoal: activeGoal,
    rangeExpense: rangeExpense,
    rangeIncome: rangeIncome,
    monthDailySpend: monthDailyRows,
    hasAnyTransactions: recentRows.isNotEmpty,
  );
});
