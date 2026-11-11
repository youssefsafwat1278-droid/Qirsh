import '../help/coach_marks.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/widgets/merchant_bar.dart' show ChartBar;
import '../common/motion.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_format.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/utils/category_glyph.dart';
import '../../core/utils/category_tone.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../common/category_catalog.dart';
import '../common/planning_repair_gate.dart';
import '../common/premium_loading.dart';
import 'widgets/planning_hero_tabs.dart';
import '../common/app_card.dart';
import '../common/app_empty_state.dart';
import '../common/money_text.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/theme/widgets/ring_progress.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../common/app_sheet_scaffold.dart';
import '../dashboard/dashboard_providers.dart';
import '../goals/goal_details_screen.dart';
import '../goals/goal_form_screen.dart';
import '../transactions/transaction_details_screen.dart';
import 'allocate_income_sheet.dart';
import 'budget_form_screen.dart';
import 'budgets_providers.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/theme/widgets/directional_chevron.dart';
import '../common/repo_error_messages.dart';
import '../../core/theme/widgets/glass_dialog.dart';
import '../../core/theme/widgets/glass_actions.dart';
import '../common/app_error_state.dart';

class BudgetsScreen extends ConsumerWidget {
  const BudgetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => PlanningRepairGate(
      child: FirstUseGuide(
          id: CoachMarkIds.budgets,
          marks: budgetCoachMarks,
          child: _buildScreen(context, ref)));

  Widget _buildScreen(BuildContext context, WidgetRef ref) {
    final async = ref.watch(budgetsViewProvider);
    final tab = ref.watch(budgetsPageTabProvider);
    final displayCurrency =
        ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR';
    final currencyLabel = Currency.label(context, displayCurrency);

    return Scaffold(
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => const SkeletonList(rows: 4),
        error: (error, _) => SafeArea(
            child: SingleChildScrollView(
                child: AppErrorState(
          title: context.l10n.bdgError,
          description: context.l10n.annTryAgainSoon,
          retryLabel: context.l10n.startRetry,
          onRetry: () => ref.invalidate(budgetsViewProvider),
        ))),
        data: (data) {
          final historyEntries = data.historyEntries;
          final rawBudgetEntries = tab == 1
              ? historyEntries.map((entry) => entry.progress).toList()
              : data.snapshot.entries;
          final budgetEntries = rawBudgetEntries
              .where((entry) =>
                  entry.budget.currency.toUpperCase() ==
                  displayCurrency.toUpperCase())
              .toList(growable: false);
          // An "all expenses" budget is the overall roll-up; category budgets
          // are its breakdown. Summing both double-counts, so the header total
          // uses the roll-up when present, otherwise the sum of categories.
          final categoryEntries =
              budgetEntries.where((e) => !e.budget.isAllExpenses).toList();
          final allExpensesEntries =
              budgetEntries.where((e) => e.budget.isAllExpenses);
          // §16/§6: only same-currency category budgets fold into the roll-up —
          // never Money(EGP)+Money(SAR).
          final sameCurrencyEntries = categoryEntries
              .where((e) =>
                  e.budget.currency.toUpperCase() ==
                  displayCurrency.toUpperCase())
              .toList(growable: false);
          final used = allExpensesEntries.isNotEmpty
              ? allExpensesEntries.first.spent
              : Money.sum(
                  sameCurrencyEntries.map((entry) => entry.spent),
                  displayCurrency,
                );
          final limit = allExpensesEntries.isNotEmpty
              ? allExpensesEntries.first.budget.amountMoney
              : Money.sum(
                  sameCurrencyEntries.map((entry) => entry.budget.amountMoney),
                  displayCurrency,
                );
          final usedRatio = limit.isZero
              ? 0
              : (used.toDouble() / limit.toDouble() * 100).round();
          final displayGoals = data.goals.where((goal) =>
              goal.currency.toUpperCase() == displayCurrency.toUpperCase());
          final saved = Money.sum(
              displayGoals.map((goal) => goal.savedMoney), displayCurrency);
          final target = Money.sum(
              displayGoals.map((goal) => goal.targetMoney), displayCurrency);
          final progress = target.isZero
              ? 0
              : (saved.toDouble() / target.toDouble() * 100).round();
          final safeCount = budgetEntries
              .where((entry) => entry.health == BudgetHealth.safe)
              .length;
          final warningCount = budgetEntries
              .where((entry) => entry.health == BudgetHealth.warning)
              .length;
          final overCount = budgetEntries
              .where((entry) => entry.health == BudgetHealth.over)
              .length;

          return RefreshIndicator(
            onRefresh: () async => refreshBudgets(ref),
            // This indicator wraps a NestedScrollView. Its default predicate
            // accepts notifications at depth 0, but under NestedScrollView the
            // ScrollUpdateNotifications that accumulate the pull distance are
            // emitted ONLY by the inner scrollable at depth 1 (measured: 20
            // updates at depth 1, none at depth 0). So it armed on the start
            // notification and never saw a single update — pull-to-refresh
            // could not fire from the body or the header, on iOS or Android.
            // Found by the exhaustive control sweep on a physical iPhone and
            // reproduced with the exact structure in
            // test/harness/nested_refresh_repro_test.dart. The other four
            // RefreshIndicators in the app do not wrap a NestedScrollView.
            notificationPredicate: (n) => n.depth == 1,
            child: QirshSectionBackdrop(
                child: SafeArea(
              // Immersive: the section photo runs under the status bar /
              // Dynamic Island; the hero pads its own content below it.
              top: false,
              bottom: false,
              child: NestedScrollView(
                headerSliverBuilder: (context, innerBoxIsScrolled) {
                  return [
                    SliverToBoxAdapter(
                        child: CalmPageHeader(
                      sectionPhoto: tab == 2
                          ? QirshSectionPhoto.goals
                          : QirshSectionPhoto.budgets,
                      sectionHeight: 190,
                      title: switch (tab) {
                        1 => context.l10n.bdgTabHistory,
                        2 => context.l10n.bdgTabGoals,
                        _ => context.l10n.bdgTabBudgets,
                      },
                      subtitle: context.l10n.bdgOverviewSubtitle,
                      coverBottom: PlanningHeroTabs(
                        tab: tab,
                        onSelected: (value) => ref
                            .read(budgetsPageTabProvider.notifier).state = value,
                      ),
                      leading: Navigator.of(context).canPop()
                          ? const BackButton()
                          : null,
                      trailing: CoachAnchor(target: 'budgetAdd',
                          child: _AddButton(
                              label: tab == 2
                                  ? context.l10n.bdgAddGoal
                                  : context.l10n.bdgAddBudget,
                              onTap: () => tab == 2
                                  ? GoalFormScreen.showSheet(context)
                                  : BudgetFormScreen.showSheet(context))),
                    )),
                    SliverToBoxAdapter(
                      child: Column(
                        children: [
                          _BudgetsHeader(
                            tab: tab,
                            usedRatio: usedRatio,
                            usedAmount: used,
                            limit: limit,
                            saved: saved,
                            target: target,
                            progress: progress,
                            goalsCount: displayGoals
                                .where((goal) => goal.status == 'active')
                                .length,
                            daysLeft: budgetEntries.isNotEmpty &&
                                    budgetEntries.every((entry) =>
                                        entry.periodEnd.isAtSameMomentAs(
                                            budgetEntries.first.periodEnd))
                                ? DateUtils.dateOnly(
                                        budgetEntries.first.periodEnd.toLocal())
                                    .difference(
                                        DateUtils.dateOnly(DateTime.now()))
                                    .inDays
                                    .clamp(0, 3660)
                                : null,
                            budgetsCount: budgetEntries.length,
                            safeCount: safeCount,
                            warningCount: warningCount,
                            overCount: overCount,
                            currencyLabel: currencyLabel,
                          ),
                        ],
                      ),
                    ),
                  ];
                },
                body: MeltTail(
                    startAt: 64,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.gutter,
                        AppSpacing.s3,
                        AppSpacing.gutter,
                        120,
                      ),
                      children: [
                        if (tab == 0) ...[
                          ..._budgetEntryChildren(
                            context,
                            ref,
                            data,
                            entries: data.snapshot.entries,
                            currencyLabel: currencyLabel,
                            showGlobalAccountLabel: false,
                            emptyTitle: context.l10n.bdgEmptyBudgetsTitle,
                            emptySubtitle: context.l10n.bdgEmptyBudgetsBody,
                          ),
                          const SizedBox(height: AppSpacing.s3),
                          _AllocateIncomeButton(
                              onTap: () => AllocateIncomeSheet.show(context)),
                        ] else if (tab == 1) ...[
                          _HistoryPeriodFilterRow(ref: ref),
                          const SizedBox(height: AppSpacing.s2),
                          ..._budgetHistoryChildren(
                            context,
                            data,
                            entries: _applyHistoryFilter(historyEntries,
                                ref.watch(budgetsHistoryPeriodFilterProvider)),
                            currencyLabel: currencyLabel,
                          ),
                        ] else ...[
                          if (data.goals.isEmpty)
                            AppEmptyState(
                              illustration: const QirshIllustration(
                                  name: 'savings', width: 210, height: 158),
                              icon: AppLucideIcons.target,
                              title: context.l10n.bdgEmptyGoalsTitle,
                              subtitle: context.l10n.bdgEmptyGoalsBody,
                              primaryLabel: context.l10n.bdgAddGoal,
                              onPrimary: () =>
                                  GoalFormScreen.showSheet(context),
                            )
                          else
                            for (final goal in data.goals) ...[
                              _GoalPlannerCard(
                                goal: goal,
                                currencyLabel: currencyLabel,
                              ),
                              const SizedBox(height: AppSpacing.s4),
                            ]
                        ],
                      ],
                    )),
              ),
            )),
          );
        },
      ),
    );
  }

  List<Widget> _budgetHistoryChildren(
    BuildContext context,
    BudgetsView data, {
    required List<BudgetHistoryEntry> entries,
    required String currencyLabel,
  }) {
    if (entries.isEmpty) {
      return [
        AppEmptyState(
          illustration:
              const QirshIllustration(name: 'budget', width: 210, height: 158),
          icon: AppLucideIcons.history,
          title: context.l10n.bdgEmptyHistoryTitle,
          subtitle: context.l10n.bdgEmptyHistoryBody,
          primaryLabel: context.l10n.bdgAddBudget,
          onPrimary: () => BudgetFormScreen.showSheet(context),
        ),
      ];
    }
    // Entries arrive sorted by periodStart desc. Group consecutive entries by
    // their month so the user reads the log as "how did each past period go".
    final widgets = <Widget>[];
    int? year;
    int? month;
    for (final history in entries) {
      final start = history.progress.periodStart;
      if (start.year != year || start.month != month) {
        year = start.year;
        month = start.month;
        if (widgets.isNotEmpty) {
          widgets.add(const SizedBox(height: AppSpacing.s4));
        }
        widgets.add(_MonthHeader(label: Formatters.monthYear(start, context)));
        widgets.add(const SizedBox(height: AppSpacing.s2));
      }
      final entryCurrency =
          _entryCurrencyLabel(context, data, history.progress, currencyLabel);
      widgets.add(
        _BudgetHistoryRow(
          history: history,
          category: data.catalog.byId(history.budget.categoryId),
          currencyLabel: entryCurrency,
          onTap: () => _BudgetPeriodDetailsSheet.show(
            context,
            history: history,
            category: data.catalog.byId(history.budget.categoryId),
            accountName: data.accountName(
              history.budget.accountId,
              showGlobalLabel: true,
              globalLabel: context.l10n.budgetsAllAccounts,
            ),
            currencyLabel: entryCurrency,
          ),
        ),
      );
      widgets.add(const SizedBox(height: AppSpacing.s2));
    }
    return widgets;
  }

  List<Widget> _budgetEntryChildren(
    BuildContext context,
    WidgetRef ref,
    BudgetsView data, {
    required List<BudgetProgressEntry> entries,
    required String currencyLabel,
    required bool showGlobalAccountLabel,
    required String emptyTitle,
    required String emptySubtitle,
  }) {
    if (entries.isEmpty) {
      return [
        AppEmptyState(
          illustration:
              const QirshIllustration(name: 'budget', width: 210, height: 158),
          icon: AppLucideIcons.pieChart,
          title: emptyTitle,
          subtitle: emptySubtitle,
          primaryLabel: context.l10n.bdgAddBudget,
          onPrimary: () => BudgetFormScreen.showSheet(context),
        ),
      ];
    }
    // v2: worst first, all rows inside ONE Group (never a card per row).
    final sorted = [...entries]..sort((a, b) => b.ratio.compareTo(a.ratio));
    final c = context.colors;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(0, AppSpacing.s3, 0, AppSpacing.s3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(context.l10n.bdgV2YourBudgets,
                  style: AppTypography.sectionTitle(c.textPrimary)),
            ),
            Text(context.l10n.bdgV2WorstFirst,
                style: AppTypography.caption(c.textMuted)),
          ],
        ),
      ),
      AppCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            for (var i = 0; i < sorted.length; i++) ...[
              if (i > 0)
                Divider(
                    height: 1,
                    thickness: 1,
                    indent: 16 + 56 + AppSpacing.s3,
                    color: c.border),
              _Enter(
                delay: AppMotion.stagger * math.min(i, 6),
                child: _BudgetCard(
                  entry: sorted[i],
                  category: data.catalog.byId(sorted[i].budget.categoryId),
                  accountName: data.accountName(
                    sorted[i].budget.accountId,
                    showGlobalLabel: showGlobalAccountLabel,
                    globalLabel: context.l10n.budgetsAllAccounts,
                  ),
                  currencyLabel:
                      _entryCurrencyLabel(context, data, sorted[i], currencyLabel),
                  onTap: () => BudgetFormScreen.showSheet(
                    context,
                    budgetId: sorted[i].budget.id,
                  ),
                  onDelete: () => _confirmDeleteBudget(context, ref, sorted[i]),
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.s4),
    ];
  }

  Future<void> _confirmDeleteBudget(
    BuildContext context,
    WidgetRef ref,
    BudgetProgressEntry entry,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text(context.l10n.bdgDeleteTitle),
        content: Text(context.l10n.bdgDeleteBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(context.l10n.commonCancel)),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(foregroundColor: ctx.colors.danger),
              child: Text(context.l10n.setDelete)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(budgetRepositoryProvider).delete(entry.budget.id);
      refreshBudgets(ref);
      ref.invalidate(dashboardDataProvider);
    } on RepoException catch (error) {
      if (!context.mounted) return;
      AppToast.showError(context, repoErrorMessage(context, error));
    } catch (_) {
      if (!context.mounted) return;
      AppToast.showError(context, context.l10n.bdgDeleteFailed);
    }
  }

  String _entryCurrencyLabel(
    BuildContext context,
    BudgetsView data,
    BudgetProgressEntry entry,
    String fallback,
  ) {
    final accountId = entry.budget.accountId;
    if (accountId == null) return fallback;
    for (final account in data.accounts) {
      if (account.id == accountId) {
        return Currency.label(context, account.currency);
      }
    }
    return fallback;
  }
}

List<BudgetHistoryEntry> _applyHistoryFilter(
  List<BudgetHistoryEntry> entries,
  BudgetPeriod? filter,
) {
  if (filter == null) return entries;
  return entries.where((e) => e.budget.period == filter).toList();
}

String _budgetPeriodDateLabel(BudgetProgressEntry entry, BuildContext context) {
  final s = entry.periodStart;
  final e = entry.periodEnd;
  switch (entry.budget.period) {
    case BudgetPeriod.daily:
      return Formatters.fullDate(s, context);
    case BudgetPeriod.weekly:
      return '${s.day}/${s.month} — ${e.day}/${e.month}';
    case BudgetPeriod.monthly:
      return Formatters.monthYear(s, context);
    case BudgetPeriod.yearly:
      return '${s.year}';
  }
}

class _HistoryPeriodFilterRow extends StatelessWidget {
  const _HistoryPeriodFilterRow({required this.ref});
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final selected = ref.watch(budgetsHistoryPeriodFilterProvider);
    final options = <(BudgetPeriod?, String)>[
      (null, context.l10n.bdgFilterAll),
      (BudgetPeriod.daily, context.l10n.bdgFilterDaily),
      (BudgetPeriod.weekly, context.l10n.bdgFilterWeekly),
      (BudgetPeriod.monthly, context.l10n.bdgFilterMonthly),
      (BudgetPeriod.yearly, context.l10n.bdgFilterYearly),
    ];
    return Wrap(
      spacing: AppSpacing.s2,
      runSpacing: AppSpacing.s2,
      children: [
        for (final (period, label) in options) ...[
          GestureDetector(
            onTap: () {
              if (selected != period) HapticFeedback.selectionClick();
              ref.read(budgetsHistoryPeriodFilterProvider.notifier).state =
                  period;
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s3, vertical: AppSpacing.s1 + 2),
              // v2 QChip: selected = action.soft + action.text + 1px
              // action@40%; idle = card + hairline (light: white + strokeSoft).
              decoration: BoxDecoration(
                color: selected == period ? c.ctaSoft : c.surfaceCard,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(
                  color: selected == period
                      ? c.cta.withValues(alpha: .40)
                      : Theme.of(context).brightness == Brightness.dark
                          ? c.border
                          : c.strokeSoft,
                ),
              ),
              child: Text(
                label,
                style: AppTypography.caption(
                  selected == period ? c.actionText : c.textSecondary,
                ).copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// v2: the «+» is a 44pt tinted icon button in the bar — not a FAB-like
/// filled circle competing with the page's one primary.
class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap, required this.label});
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: c.ctaSoft,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: SizedBox.square(
            dimension: 44,
            child: Icon(AppLucideIcons.plus, size: 22, color: c.actionText),
          ),
        ),
      ),
    );
  }
}

class _BudgetsHeader extends StatelessWidget {
  const _BudgetsHeader({
    required this.tab,
    required this.usedRatio,
    required this.usedAmount,
    required this.limit,
    required this.saved,
    required this.target,
    required this.progress,
    required this.goalsCount,
    required this.budgetsCount,
    required this.safeCount,
    required this.warningCount,
    required this.overCount,
    required this.currencyLabel,
    this.daysLeft,
  });

  final int tab;
  final int usedRatio;
  // UX-001 / R-8 — Money, not double. `Formatters.amount` is hardcoded to two
  // decimals, so it silently mis-scales a 3-decimal currency (KWD) and a
  // 0-decimal one (JPY). `formatMoney` reads the canonical scale registry.
  final Money usedAmount;
  final Money limit;
  final Money saved;
  final Money target;
  final int progress;
  final int goalsCount;
  final int budgetsCount;
  final int safeCount;
  final int warningCount;
  final int overCount;
  final String currencyLabel;
  final int? daysLeft;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isGoals = tab == 2;
    final isAllLog = tab == 1;
    final totalLabel = switch (tab) {
      1 => context.l10n.bdgStatHistoryCount,
      2 => context.l10n.bdgStatTotalSaved,
      _ => context.l10n.bdgStatTotalBudgeted,
    };
    final unit = isAllLog ? context.l10n.bdgBudgetWord : currencyLabel;
    // v2: one row of EQUAL counters — never the old 3 + 2 orphan grid.
    final chips = isGoals
        ? [
            _SummaryChip(
                value: '$goalsCount',
                label: context.l10n.bdgStatActiveGoals,
                background: c.surfaceMuted,
                foreground: c.textSecondary),
            _SummaryChip(
                value: '$progress%',
                label: context.l10n.bdgStatProgress,
                background: c.surfaceMuted,
                foreground: c.textSecondary),
            _SummaryChip(
                value: formatMoney(target),
                label: context.l10n.bdgStatTargetSavings,
                background: c.surfaceMuted,
                foreground: c.textSecondary),
          ]
        : [
            _SummaryChip(
                value: '$safeCount',
                label: context.l10n.bdgStateSafeF,
                background: c.successBg,
                foreground: c.success),
            _SummaryChip(
                value: '$warningCount',
                label: context.l10n.bdgStateNear,
                background: c.warningBg,
                foreground: c.warningText),
            _SummaryChip(
                value: '$overCount',
                label: context.l10n.bdgStateOverF,
                background: c.dangerBg,
                foreground: c.danger),
            if (!isAllLog)
              _SummaryChip(
                  value: '$budgetsCount',
                  label: context.l10n.bdgBudgetsWord,
                  background: c.surfaceMuted,
                  foreground: c.textSecondary),
          ];
    final amountStyle = AppTypography.amountLarge(c.textMain);
    final remaining = limit - usedAmount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, AppSpacing.s2, AppSpacing.gutter, 0),
      child: _Enter(
        child: _SoftHeroCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Hero amounts carry the currency on the label line.
              Text('$totalLabel · $unit',
                  style: AppTypography.caption(c.textLight)),
              const SizedBox(height: 2),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: isAllLog
                      ? Text('$budgetsCount', style: amountStyle)
                      : AnimatedAmountText.money(
                          value: isGoals ? saved : limit,
                          color: c.textMain,
                          style: amountStyle,
                          textAlign: TextAlign.start,
                        ),
                ),
              ),
              if (!isGoals && !isAllLog) ...[
                const SizedBox(height: AppSpacing.s3),
                Semantics(
                  label: '${context.l10n.bdgUsageRate} $usedRatio%',
                  excludeSemantics: true,
                  child: Row(
                    children: [
                      Expanded(
                        child: ChartBar(
                          value: usedRatio / 100,
                          height: 10,
                          color: c.cta,
                          trackColor: isDark
                              ? Colors.white.withValues(alpha: .12)
                              : c.surfaceMuted,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s2),
                      Text('$usedRatio%',
                          textDirection: TextDirection.ltr,
                          style: AppTypography.caption(c.textSecondary)
                              .copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: AppSpacing.s3,
                  runSpacing: 2,
                  children: [
                    Text(
                        '${context.l10n.bdgActualSpend} ${formatMoney(usedAmount)}',
                        style: AppTypography.caption(c.textLight)),
                    Text(
                        '${context.l10n.bdgRemaining} ${formatMoney(remaining)}'
                        '${daysLeft == null ? '' : ' · ${context.l10n.goalDaysLeft(daysLeft!)}'}',
                        style: AppTypography.caption(c.textLight)),
                  ],
                ),
              ],
              const SizedBox(height: AppSpacing.s4),
              Row(
                children: [
                  for (var i = 0; i < chips.length; i++) ...[
                    if (i > 0) const SizedBox(width: AppSpacing.s2),
                    Expanded(
                      child: _Enter(
                        delay: AppMotion.stagger * (i + 1),
                        child: chips[i],
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// v2 Soft hero (summary cards on 08/13/15): dark #181A20 + 10% hairline +
/// a top-leading aurora; light white + e2 + a 3pt action top edge, no aurora.
class _SoftHeroCard extends StatelessWidget {
  const _SoftHeroCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(AppRadius.card);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isDark ? c.surfaceElevated : c.surface,
        borderRadius: radius,
        border: isDark ? Border.all(color: c.strokeSoft) : null,
        boxShadow: AppShadows.raised(Theme.of(context).brightness),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            if (isDark)
              const Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: AlignmentDirectional(-1, -1),
                        radius: 1.1,
                        colors: [Color(0x3D2E6BFF), Color(0x002E6BFF)],
                      ),
                    ),
                  ),
                ),
              )
            else
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 3,
                child: ColoredBox(color: c.cta),
              ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s5),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}

/// One equal-width status counter in the summary card.
class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.value,
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String value;
  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s1, vertical: AppSpacing.s2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value,
                maxLines: 1,
                textDirection: TextDirection.ltr,
                style: AppTypography.amountSmall(foreground)),
          ),
          Text(label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.caption(foreground)),
        ],
      ),
    );
  }
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard({
    required this.entry,
    required this.category,
    required this.accountName,
    required this.currencyLabel,
    required this.onTap,
    this.onDelete,
  });

  final BudgetProgressEntry entry;
  final CategoryView? category;
  final String accountName;
  final String currencyLabel;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  Future<void> _openMenu(BuildContext context) async {
    final value = await showGlassActions<String>(context: context, actions: [
      GlassAction(
          value: 'delete',
          label: context.l10n.setDelete,
          icon: AppLucideIcons.trash2,
          destructive: true)
    ]);
    if (value == 'delete') onDelete?.call();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final progressColor = c.budgetState(entry.ratio,
        warnAtPercent: entry.budget.alertThresholdPercent);
    final percent = (entry.ratio * 100).round();
    final isOver = entry.remaining.isNegative;
    final isGeneral = entry.budget.isAllExpenses;
    final periodLabel = switch (entry.budget.period) {
      BudgetPeriod.daily => context.l10n.bdgFilterDaily,
      BudgetPeriod.weekly => context.l10n.bdgFilterWeekly,
      BudgetPeriod.monthly => context.l10n.bdgFilterMonthly,
      BudgetPeriod.yearly => context.l10n.bdgFilterYearly,
    };
    final meta = [periodLabel, if (accountName.isNotEmpty) accountName]
        .join(' · ');
    // v2 budget row (one Group, 96pt): ring with % · name + one meta line ·
    // «باقي»/«تجاوز» amount over «spent / limit». Status is carried by the
    // ring and the amount colour — the separate pill is gone.
    return InkWell(
      onTap: onTap,
      onLongPress: onDelete == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              _openMenu(context);
            },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 96),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 4, 12),
          child: Row(
            children: [
              _BudgetHealthRing(
                ratio: entry.ratio,
                color: progressColor,
                over: isOver,
                warnKey: entry.budget.id,
                child: Text('$percent%',
                    textDirection: TextDirection.ltr,
                    style: AppTypography.custom(
                        size: 13,
                        weight: FontWeight.w700,
                        height: 1.2,
                        tabular: true,
                        color: c.textPrimary)),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        isGeneral
                            ? context.l10n.bdgAllExpenses
                            : category?.name ?? context.l10n.bdgCategory,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.cardTitle(c.textPrimary)),
                    const SizedBox(height: 2),
                    Text(meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption(c.textMuted)),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerEnd,
                      child: Text(
                          '${isOver ? context.l10n.bdgOver : context.l10n.bdgRemaining} '
                          '${formatMoney(isOver ? -entry.remaining : entry.remaining)}',
                          maxLines: 1,
                          style: AppTypography.amountSmall(
                              isOver ? c.danger : c.success)),
                    ),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerEnd,
                      child: Text(
                          '${formatMoney(entry.spent)} / ${formatMoney(entry.budget.amountMoney)} $currencyLabel',
                          maxLines: 1,
                          style: AppTypography.caption(c.textMuted)),
                    ),
                  ],
                ),
              ),
              if (onDelete != null)
                SizedBox(
                    height: 44,
                    width: 40,
                    child: IconButton(
                        padding: EdgeInsets.zero,
                        tooltip: context.l10n.setDelete,
                        icon: Icon(AppLucideIcons.moreVertical,
                            color: c.textMuted, size: 18),
                        onPressed: () => _openMenu(context)))
              else
                const SizedBox(width: AppSpacing.s3),
            ],
          ),
        ),
      ),
    );
  }
}

/// The budget's health ring (56pt, stroke 6): sweeps in as the row appears
/// (`m.chart` ring). Over budget it sweeps past full and pulses once — a soft
/// danger glow in dark, a 1.06 scale in light — with one warning haptic per
/// budget per session. Reduce Motion shows the final state.
class _BudgetHealthRing extends StatefulWidget {
  const _BudgetHealthRing({
    required this.ratio,
    required this.color,
    required this.over,
    required this.warnKey,
    required this.child,
  });

  final double ratio;
  final Color color;
  final bool over;
  final String warnKey;
  final Widget child;

  static final Set<String> _warned = <String>{};

  @override
  State<_BudgetHealthRing> createState() => _BudgetHealthRingState();
}

class _BudgetHealthRingState extends State<_BudgetHealthRing>
    with SingleTickerProviderStateMixin {
  // 0–0.5: wait out the 700ms sweep; 0.5–1: the single pulse.
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400));
  bool _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scheduled || !widget.over) return;
    _scheduled = true;
    if (shouldReduceMotion(context)) return;
    _pulse.addListener(_onPulse);
    _pulse.forward();
  }

  void _onPulse() {
    if (_pulse.value < .5) return;
    _pulse.removeListener(_onPulse);
    if (_BudgetHealthRing._warned.add(widget.warnKey)) {
      HapticFeedback.mediumImpact();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final t = ((_pulse.value - .5) * 2).clamp(0.0, 1.0);
        final wave = math.sin(t * math.pi);
        final ring = RingProgress(
          value: widget.ratio,
          size: 56,
          strokeWidth: 6,
          color: widget.color,
          allowOverflow: widget.over,
          glowColor: isDark && widget.over && wave > 0
              ? widget.color.withValues(alpha: .40 * wave)
              : null,
          child: child,
        );
        if (isDark || wave == 0) return ring;
        return Transform.scale(scale: 1 + .06 * wave, child: ring);
      },
      child: widget.child,
    );
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s2, bottom: AppSpacing.s1),
      child: Row(
        children: [
          Flexible(
            child: Text(
              label,
              style: AppTypography.footnote(c.textSecondary)
                  .copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: AppSpacing.s2),
          Expanded(child: Divider(color: c.border, height: 1)),
        ],
      ),
    );
  }
}

/// Compact, result-focused row for the budgets log. Answers one question per
/// past period: did the user stay within the limit (وفّرت) or go over (تجاوزت)?
class _BudgetHistoryRow extends StatelessWidget {
  const _BudgetHistoryRow({
    required this.history,
    required this.category,
    required this.currencyLabel,
    required this.onTap,
  });

  final BudgetHistoryEntry history;
  final CategoryView? category;
  final String currencyLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final entry = history.progress;
    final isGeneral = entry.budget.isAllExpenses;
    final isOver = entry.remaining.isNegative;
    final periodLabel = switch (entry.budget.period) {
      BudgetPeriod.daily => context.l10n.bdgFilterDaily,
      BudgetPeriod.weekly => context.l10n.bdgFilterWeekly,
      BudgetPeriod.monthly => context.l10n.bdgFilterMonthly,
      BudgetPeriod.yearly => context.l10n.bdgFilterYearly,
    };
    final title = isGeneral
        ? context.l10n.bdgAllExpenses
        : category?.name ?? context.l10n.bdgCategory;
    final dateLabel = _budgetPeriodDateLabel(entry, context);
    final subtitle = history.isCurrent
        ? context.l10n.bdgPeriodSubtitleLive(periodLabel, dateLabel)
        : context.l10n.bdgPeriodSubtitle(periodLabel, dateLabel);

    // UX-001 — the label and the amount are kept apart so the amount can go
    // through MoneyText. Interpolating it into the sentence is what forced the
    // rounding in the first place.
    final String resultLabel;
    final Money resultAmount;
    final Color resultColor;
    final IconData? resultIcon;
    if (history.isCurrent) {
      resultLabel =
          isOver ? context.l10n.bdgStateOverF : context.l10n.bdgRemaining;
      resultAmount = isOver ? -entry.remaining : entry.remaining;
      resultColor = isOver ? c.danger : c.textSecondary;
      resultIcon = null;
    } else if (isOver) {
      resultLabel = context.l10n.bdgStateOverF;
      resultAmount = -entry.remaining;
      resultColor = c.danger;
      resultIcon = AppLucideIcons.alertTriangle;
    } else {
      resultLabel = context.l10n.bdgSaved;
      resultAmount = entry.remaining;
      resultColor = c.success;
      resultIcon = AppLucideIcons.checkCircle;
    }

    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: categoryTone(
                isGeneral ? 'wallet-cards' : (category?.iconName ?? 'shapes'),
                Theme.of(context).brightness,
              ).background,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: CategoryGlyph(
              name:
                  isGeneral ? 'wallet-cards' : (category?.iconName ?? 'shapes'),
              size: 20,
              color: categoryTone(
                isGeneral ? 'wallet-cards' : (category?.iconName ?? 'shapes'),
                Theme.of(context).brightness,
              ).ink,
            ),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTypography.subhead(c.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: AppTypography.caption(c.textSecondary),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: AppSpacing.s1,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (resultIcon != null)
                      Icon(resultIcon, size: 14, color: resultColor),
                    Text(resultLabel,
                        style: AppTypography.caption(resultColor)
                            .copyWith(fontWeight: FontWeight.w700)),
                    MoneyText(resultAmount,
                        style: AppTypography.caption(resultColor)
                            .copyWith(fontWeight: FontWeight.w700)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.s2),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${formatMoney(entry.spent)} / ${formatMoney(entry.budget.amountMoney)}',
                  textAlign: TextAlign.end,
                  style: AppTypography.subhead(c.textPrimary),
                ),
                Text(currencyLabel,
                    style: AppTypography.caption(c.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// How many of a period's transactions the detail sheet renders.
///
/// The cap itself is fine — a sheet is not a ledger. What was not fine was that
/// it was invisible: the sheet listed 20 rows and said nothing about the rest,
/// so a 60-transaction period looked like a 20-transaction one.
const int _kPeriodTransactionLimit = 20;

class _BudgetPeriodDetailsSheet extends StatelessWidget {
  const _BudgetPeriodDetailsSheet({
    required this.history,
    required this.category,
    required this.accountName,
    required this.currencyLabel,
  });

  final BudgetHistoryEntry history;
  final CategoryView? category;
  final String accountName;
  final String currencyLabel;

  static Future<void> show(
    BuildContext context, {
    required BudgetHistoryEntry history,
    required CategoryView? category,
    required String accountName,
    required String currencyLabel,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => navySheetTheme(_BudgetPeriodDetailsSheet(
        history: history,
        category: category,
        accountName: accountName,
        currencyLabel: currencyLabel,
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final entry = history.progress;
    final progressColor = c.budgetState(entry.ratio,
        warnAtPercent: entry.budget.alertThresholdPercent);
    final progress = entry.ratio.clamp(0, 1).toDouble();
    final percent = (entry.ratio * 100).round();
    final isOver = entry.remaining.isNegative;
    final title = entry.budget.isAllExpenses
        ? context.l10n.bdgAllExpenses
        : category?.name ?? context.l10n.bdgBudgetWord;
    final periodLabel = _periodLabel(context, entry.budget.period.name);
    final statusLabel = history.isCurrent
        ? context.l10n.bdgPeriodCurrent
        : isOver
            ? context.l10n.bdgPeriodOver
            : context.l10n.bdgPeriodEnded;

    return AppSheetScaffold(
      title: title,
      subtitle:
          '$periodLabel · ${_dateRangeLabel(context, entry.periodStart, entry.periodEnd)}',
      scrollable: true,
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: categoryTone(
                      entry.budget.isAllExpenses
                          ? 'wallet-cards'
                          : (category?.iconName ?? 'shapes'),
                      Theme.of(context).brightness,
                    ).background,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                  child: CategoryGlyph(
                    name: entry.budget.isAllExpenses
                        ? 'wallet-cards'
                        : (category?.iconName ?? 'shapes'),
                    size: 24,
                    color: categoryTone(
                      entry.budget.isAllExpenses
                          ? 'wallet-cards'
                          : (category?.iconName ?? 'shapes'),
                      Theme.of(context).brightness,
                    ).ink,
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(statusLabel,
                          style: AppTypography.bodyStrong(progressColor)),
                      if (accountName.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(accountName,
                            style: AppTypography.caption(c.textSecondary)),
                      ],
                    ],
                  ),
                ),
                Text('$percent%',
                    style: AppTypography.bodyStrong(progressColor)),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 10,
                backgroundColor: c.surface2,
                valueColor: AlwaysStoppedAnimation(progressColor),
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            AppCard(
              padding: const EdgeInsets.all(AppSpacing.s3),
              child: Row(
                children: [
                  Expanded(
                    child: _BudgetAmountTile(
                      label: context.l10n.bdgLimit,
                      amount: entry.budget.amountMoney,
                      currencyLabel: currencyLabel,
                      color: c.textPrimary,
                    ),
                  ),
                  Container(width: 1, height: 40, color: c.border),
                  Expanded(
                    child: _BudgetAmountTile(
                      label: context.l10n.bdgSpent,
                      amount: entry.spent,
                      currencyLabel: currencyLabel,
                      color: c.textPrimary,
                    ),
                  ),
                  Container(width: 1, height: 40, color: c.border),
                  Expanded(
                    child: _BudgetAmountTile(
                      label: isOver
                          ? context.l10n.bdgOver
                          : context.l10n.bdgRemaining,
                      amount: isOver ? -entry.remaining : entry.remaining,
                      currencyLabel: currencyLabel,
                      color: isOver ? c.danger : c.success,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            Text(
              history.isCurrent
                  ? context.l10n.bdgRecordLive
                  : context.l10n.bdgRecordFinal,
              style: AppTypography.caption(c.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.s4),
            // UX-003 — the sheet was entirely read-only: you could open a
            // budget's period, see that it had been exceeded, and have no way
            // to act on it from here. "Actions" is one of the finding's own
            // listed gaps.
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  BudgetFormScreen.showSheet(
                    context,
                    budgetId: entry.budget.id,
                  );
                },
                icon: Icon(AppLucideIcons.pencil, size: 16, color: c.textMain),
                label: Text(context.l10n.bdgEditBudget,
                    style: AppTypography.subhead(c.textMain)),
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Row(
              children: [
                Expanded(
                  child: Text(context.l10n.bdgPeriodTransactions,
                      style: AppTypography.bodyStrong(c.textPrimary)),
                ),
                // UX-003 / F-009 class — the list was capped at 20 rows with no
                // indicator, so a period with 60 transactions silently claimed
                // to have 20. The backlog names this exact class: "a silent cap
                // is the same class as F-009 (account detail capped at 20 rows
                // with no indicator)". The count is always stated, so the list
                // is honest whether or not it is truncated.
                if (history.transactions.isNotEmpty)
                  Text(
                    history.transactions.length > _kPeriodTransactionLimit
                        ? context.l10n.bdgLatestOfTotal(
                            _kPeriodTransactionLimit,
                            history.transactions.length)
                        : '${history.transactions.length}',
                    style: AppTypography.caption(c.textSecondary),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.s2),
            if (history.transactions.isEmpty)
              Container(
                padding: const EdgeInsets.all(AppSpacing.s3),
                decoration: BoxDecoration(
                  color: c.surfaceCard,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: c.border),
                ),
                child: Text(
                  context.l10n.bdgNoConfirmedTx,
                  style: AppTypography.caption(c.textSecondary),
                  textAlign: TextAlign.center,
                ),
              )
            else ...[
              for (final tx
                  in history.transactions.take(_kPeriodTransactionLimit))
                _BudgetTransactionRow(
                  tx: tx,
                  currencyLabel: Currency.label(context, tx.currency),
                ),
              if (history.transactions.length > _kPeriodTransactionLimit)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s2),
                  child: Text(
                    context.l10n.bdgMoreTxCounted(
                        history.transactions.length - _kPeriodTransactionLimit),
                    style: AppTypography.caption(c.textSecondary),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _periodLabel(BuildContext context, String period) => switch (period) {
        'daily' => context.l10n.bdgDailyBudget,
        'weekly' => context.l10n.bdgWeeklyBudget,
        'yearly' => context.l10n.bdgYearlyBudget,
        _ => context.l10n.bdgMonthlyBudget,
      };

  String _dateRangeLabel(BuildContext context, DateTime start, DateTime end) {
    final sameDay = start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    if (sameDay) return Formatters.fullDate(start, context);
    return '${Formatters.fullDate(start, context)} - ${Formatters.fullDate(end, context)}';
  }
}

class _BudgetTransactionRow extends StatelessWidget {
  const _BudgetTransactionRow({
    required this.tx,
    required this.currencyLabel,
  });

  final TransactionEntity tx;
  final String currencyLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final title = tx.rawMerchant?.trim().isNotEmpty == true
        ? tx.rawMerchant!.trim()
        : tx.note?.trim().isNotEmpty == true
            ? tx.note!.trim()
            : context.l10n.bdgTransactionWord;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () => TransactionDetailsScreen.showSheet(context, tx.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    c.expense,
                    Color.lerp(c.expense, Colors.black, 0.24)!,
                  ],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(AppLucideIcons.receipt,
                  size: 17, color: Colors.white),
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption(c.textPrimary)
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    Formatters.fullDate(tx.occurredAt, context),
                    style: AppTypography.caption(c.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            MoneyText(
              tx.amountMoney,
              style: AppTypography.caption(c.expense)
                  .copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 2),
            Text(currencyLabel, style: AppTypography.caption(c.textSecondary)),
          ],
        ),
      ),
    );
  }
}

class _GoalPlannerCard extends StatelessWidget {
  const _GoalPlannerCard({
    required this.goal,
    required this.currencyLabel,
  });

  final GoalEntity goal;
  final String currencyLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // UX-001 — «باقي 845» on a card printing «الحد 1,200» was the report; the
    // same integer rounding was applied to goals, where a goal one riyal short
    // of its target read as complete.
    final target = goal.targetMoney;
    final savedMinor = goal.savedMoney.minorUnits;
    final progress = target.isZero ? 0.0 : savedMinor / target.minorUnits;
    final percent = (progress * 100).round();
    final remainingMinor = target.minorUnits - savedMinor;
    final remaining =
        Money(remainingMinor > 0 ? remainingMinor : 0, target.currency);

    return AppCard(
      onTap: () => GoalDetailsScreen.showSheet(context, goal.id),
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppLucideIcons.piggyBank, color: c.primary),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(goal.name,
                    style: AppTypography.cardTitle(c.textPrimary)),
              ),
              Text('$percent%', style: AppTypography.bodyStrong(c.primary)),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: progress.clamp(0, 1).toDouble(),
              minHeight: 10,
              backgroundColor: c.surface2,
              valueColor: AlwaysStoppedAnimation(
                remaining.isZero ? c.success : c.cta,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          Text(
            '${formatMoney(goal.savedMoney)} / ${formatMoney(target)} $currencyLabel',
            style: AppTypography.bodyStrong(c.textPrimary),
          ),
          const SizedBox(height: AppSpacing.s2),
          if (remaining.isZero)
            Text(context.l10n.bdgGoalDone,
                style: AppTypography.caption(c.success))
          else
            Wrap(
              spacing: AppSpacing.s1,
              children: [
                Text(context.l10n.bdgRemainingPrefix,
                    style: AppTypography.caption(c.textSecondary)),
                MoneyText(
                  remaining,
                  style: AppTypography.caption(c.textSecondary),
                ),
                Text(context.l10n.bdgToReachSuffix(currencyLabel),
                    style: AppTypography.caption(c.textSecondary)),
              ],
            ),
        ],
      ),
    );
  }
}

/// UX-001 — the tile that made a budget card contradict itself.
///
/// It used to take a pre-formatted `String` built with
/// `Formatters.integer(money.toDouble())`. Three tiles sitting in one row each
/// rounded independently, so مطاعم printed «مصروف 356» and «باقي 845» against
/// «الحد 1,200» — 356 + 845 = 1,201, wrong by a riyal, in one glance. بقالة
/// reconciled only by luck, because its fractional part happened to round the
/// other way.
///
/// Taking a [Money] instead of a `String` is the fix and the guard: a caller
/// cannot round on the way in, because there is no longer anywhere to do it.
class _BudgetAmountTile extends StatelessWidget {
  const _BudgetAmountTile({
    required this.label,
    required this.amount,
    required this.currencyLabel,
    required this.color,
  });

  final String label;
  final Money amount;
  final String currencyLabel;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label, style: AppTypography.caption(c.textSecondary)),
        const SizedBox(height: 2),
        // The amount owns its own line. Three exact figures with fils no longer
        // fit beside a currency word at this width, and UX-035 is precisely the
        // failure mode of squeezing a large value into a narrow box.
        MoneyText(
          amount,
          style: AppTypography.subhead(color),
          textAlign: TextAlign.center,
        ),
        Text(currencyLabel, style: AppTypography.caption(c.textSecondary)),
      ],
    );
  }
}

/// Entry point for the «وزّع دخلك» flow at the top of the budgets tab.
class _AllocateIncomeButton extends StatelessWidget {
  const _AllocateIncomeButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // v2: demoted to a Tinted card (action.soft, + a 30% action hairline in
    // dark) so it is no longer the loudest thing on the page; the action
    // colour lives only in the icon tile.
    return Material(
      color: c.ctaSoft,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: isDark
            ? BorderSide(color: c.cta.withValues(alpha: .30))
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s4, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.ink,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(AppLucideIcons.pieChart, color: c.onInk, size: 22),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.l10n.bdgEnvelopeTitle,
                        style: AppTypography.cardTitle(c.textPrimary)),
                    const SizedBox(height: 2),
                    Text(
                      context.l10n.bdgEnvelopeBody,
                      style: AppTypography.caption(c.textSecondary),
                    ),
                  ],
                ),
              ),
              DirectionalChevron(color: c.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// v2 `m.enter` (fade + 12pt rise on ease.out, after [delay]) without timers
/// and without swapping the subtree when it finishes. `PremiumMotion` replaces
/// its child once played, which remounts it — that restarted the chart
/// draw-ins (donut, bars, rings) mid-sweep. Reduce Motion renders it in place.
class _Enter extends StatelessWidget {
  const _Enter({required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    final reduce = shouldReduceMotion(context);
    final total = AppMotion.moderate + delay;
    final start = delay.inMicroseconds / total.inMicroseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduce ? 1 : 0, end: 1),
      duration: reduce ? Duration.zero : total,
      curve: Interval(start, 1, curve: AppMotion.easeOut),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, AppMotion.enterRise * (1 - t)),
          child: child,
        ),
      ),
    );
  }
}
