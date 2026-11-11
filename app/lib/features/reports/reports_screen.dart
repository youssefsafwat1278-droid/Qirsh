import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../transactions/transactions_providers.dart';
import '../common/money_text.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/utils/async_reload_safe.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/widgets/merchant_bar.dart' show ChartBar;
import '../../core/theme/app_spacing.dart';
import '../ads/ad_placement.dart';
import '../ads/qirsh_ad_banner.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/glass_sheet.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../common/app_pill_tab_bar.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../domain/entities/report_models.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_format.dart';
import '../common/charts/spending_charts.dart';
import '../common/motion.dart';
import '../common/premium_loading.dart';
import '../common/qirsh_summary_card.dart';
import '../common/widgets.dart';
import '../dashboard/dashboard_providers.dart' show CategorySlice;
import '../settings/settings_providers.dart';
import '../report_ads/report_ad_notice.dart';
import '../reporting/ui/report_config_page.dart';
import '../report_ads/report_ads_providers.dart';
import 'reports_providers.dart';

Future<void> _openReport(BuildContext context, WidgetRef ref) async {
  final request = await showReportConfigPage(context);
  if (request == null || !context.mounted) return;
  await ref.read(reportExportCoordinatorProvider).run(() async {
    if (!context.mounted) return;
    await runReportGeneration(context, ref, request);
  }, confirmAdNotice: () async =>
      context.mounted && await showReportAdNotice(context));
}

/// The three periods the Insights summary chip offers.
const _reportPresets = [
  TransactionsDatePreset.thisMonth,
  TransactionsDatePreset.previousMonth,
  TransactionsDatePreset.last90Days,
];

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  /// The (period, account) scope whose figures this mount has already shown
  /// fresh. `reportsProvider` is kept alive and reloads with
  /// `skipLoadingOnReload`, so on a period switch — or on arriving while a
  /// recompute is pending — it still holds the PREVIOUS scope's bundle. Those
  /// figures are dimmed until the fresh bundle lands instead of being shown as
  /// if they belonged to the chip's new period. Presentation only.
  Object? _freshFor;

  Future<void> _pickPeriod(TransactionsDatePreset? current) async {
    final picked = await showGlassSheet<TransactionsDatePreset>(
      context: context,
      builder: (sheetContext) {
        final c = sheetContext.colors;
        final language = Localizations.localeOf(sheetContext).languageCode;
        return navySheetTheme(Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter, 0, AppSpacing.gutter, AppSpacing.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(sheetContext.l10n.rngPickPeriod,
                    style: AppTypography.title2(c.textPrimary)),
              ),
              const SizedBox(height: AppSpacing.s3),
              for (final preset in _reportPresets)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(AppLucideIcons.calendarDays,
                      color: preset == current ? c.cta : c.textMuted),
                  title: Text(transactionsRangeForPreset(preset)
                      .labelIn(language)),
                  trailing: preset == current
                      ? Icon(AppLucideIcons.checkCircle, color: c.cta)
                      : null,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    Navigator.of(sheetContext).pop(preset);
                  },
                ),
            ],
          ),
        ));
      },
    );
    if (picked == null || !mounted) return;
    ref.read(transactionsDateRangeProvider.notifier).state =
        transactionsRangeForPreset(picked);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(reportsProvider);
    final scope = (
      ref.watch(transactionsDateRangeProvider),
      ref.watch(activeAccountIdProvider),
    );
    if (async.hasValue && !async.isLoading) _freshFor = scope;
    final settling = async.isLoading && _freshFor != scope;
    final privacyMode = ref.watch(userSettingsProvider).dataOrWhen(
          data: (settings) => settings.privacyModeEnabled,
          orElse: () => false,
        );
    final currencyLabel = Currency.label(
        context, ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR');

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        body: async.when(
          skipLoadingOnReload: true,
          loading: () => const SkeletonList(rows: 4),
          error: (e, _) => SafeArea(
              child: SingleChildScrollView(
                  child: AppErrorState(
            title: context.l10n.txnError,
            description: context.l10n.annTryAgainSoon,
            retryLabel: context.l10n.startRetry,
            onRetry: () => ref.invalidate(reportsProvider),
          ))),
          data: (bundle) {
            final section = bundle.monthly;
            final range = effectiveTransactionsRange(
              ref.watch(transactionsDateRangeProvider),
            );
            final preset = range.preset;
            final periodLabel = range
                .labelIn(Localizations.localeOf(context).languageCode);
            return QirshSectionBackdrop(
                child: SafeArea(
                    // Immersive: the photo runs under the status bar.
                    top: false,
                    bottom: false,
                    child: NestedScrollView(
                      headerSliverBuilder: (context, innerBoxIsScrolled) {
                        return [
                          SliverToBoxAdapter(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                CalmPageHeader(
                                  sectionPhoto: QirshSectionPhoto.reports,
                                  // v3: title row + one segmented control.
                                  sectionHeight: 190,
                                  // v2: one title, matching the tab — «التحليلات».
                                  title: context.l10n.navAnalytics,
                                  subtitle: context.l10n.rptInsightsSub,
                                  leading: Navigator.of(context).canPop()
                                      ? const BackButton()
                                      : null,
                                  trailing: _ReportPill(
                                    onTap: () => _openReport(context, ref),
                                  ),
                                  coverBottom: Builder(builder: (context) {
                                    final controller =
                                        DefaultTabController.of(context);
                                    return AnimatedBuilder(
                                      animation: controller,
                                      builder: (context, _) => AppPillTabBar(
                                        onPhoto: true,
                                        tabs: [
                                          context.l10n.rptTabOverview,
                                          context.l10n.rptTabTrends,
                                          context.l10n.rptTabDetails,
                                        ],
                                        selectedIndex: controller.index,
                                        onSelected: controller.animateTo,
                                      ),
                                    );
                                  }),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    AppSpacing.gutter,
                                    AppSpacing.s2,
                                    AppSpacing.gutter,
                                    0,
                                  ),
                                  child: _Settling(
                                    settling: settling,
                                    child: _PeriodCard(
                                      section: section,
                                      currencyLabel: currencyLabel,
                                      privacyMode: privacyMode,
                                      periodLabel: periodLabel,
                                      onPeriodTap: () {
                                        HapticFeedback.selectionClick();
                                        _pickPeriod(preset);
                                      },
                                    ),
                                  ),
                                ),
                                const Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: AppSpacing.gutter),
                                  child: QirshAdBanner(
                                      placement: AdPlacement.reports),
                                ),
                              ],
                            ),
                          ),
                        ];
                      },
                      body: _Settling(
                        settling: settling,
                        child: TabBarView(
                        children: [
                          _OverviewTab(
                            section: section,
                            weekly: bundle.weekly,
                            currencyLabel: currencyLabel,
                            privacyMode: privacyMode,
                          ),
                          _TrendsTab(
                            section: section,
                            weekly: bundle.weekly,
                            currencyLabel: currencyLabel,
                            privacyMode: privacyMode,
                          ),
                          _DetailsTab(
                            section: section,
                            currencyLabel: currencyLabel,
                            privacyMode: privacyMode,
                          ),
                        ],
                      )),
                    )));
          },
        ),
      ),
    );
  }
}

String _money(
  Money amount, {
  required String currencyLabel,
  required bool privacyMode,
}) {
  // R-8 — `Formatters.amount` is a double at a hardcoded two decimals, which
  // mis-scales a 3-decimal currency and loses digits at large magnitudes.
  return privacyMode
      ? '•••• $currencyLabel'
      : '${formatMoney(amount)} $currencyLabel';
}

String _dateLabel(DateTime day) => '${day.day}/${day.month}';

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.section,
    required this.weekly,
    required this.currencyLabel,
    required this.privacyMode,
  });


  final ReportSection section;
  final ReportSection weekly;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    // v3: the daily-average / highest-day / count stats live in the summary
    // card above; the cards below keep its s4 rhythm.
    final cards = <Widget>[
      if (section.topCategories.isNotEmpty)
        _Enter(
          delay: const Duration(milliseconds: 120),
          child: _CategoryDistributionCard(
            section: section,
            currencyLabel: currencyLabel,
            privacyMode: privacyMode,
          ),
        ),
      if (section.anomaly case final SpendingAnomaly anomaly)
        _Enter(
          child: _AnomalyCard(
            anomaly: anomaly,
            currencyLabel: currencyLabel,
            privacyMode: privacyMode,
          ),
        ),
      if (!weekly.total.isZero && !weekly.total.isNegative)
        _Enter(
          child: _WeeklyInsightCard(
            weekly: weekly,
            currencyLabel: currencyLabel,
            privacyMode: privacyMode,
          ),
        ),
      if (section.topMerchants.isNotEmpty)
        _Enter(
          delay: const Duration(milliseconds: 160),
          child: _MerchantRankingCard(
            section: section,
            currencyLabel: currencyLabel,
            privacyMode: privacyMode,
          ),
        ),
    ];
    return MeltTail(
        startAt: 0,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.s4,
            AppSpacing.gutter,
            120,
          ),
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(height: AppSpacing.s4),
              cards[i],
            ],
          ],
        ));
  }
}

class _TrendsTab extends StatelessWidget {
  const _TrendsTab({
    required this.section,
    required this.weekly,
    required this.currencyLabel,
    required this.privacyMode,
  });


  final ReportSection section;
  final ReportSection weekly;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final delta = section.deltaPercent;
    final anomaly = section.anomaly;
    return MeltTail(
        startAt: 0,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.s4,
            AppSpacing.gutter,
            120,
          ),
          children: [
            Text(context.l10n.rptDailySpending,
              style: AppTypography.sectionTitle(c.textPrimary)),
            const SizedBox(height: 12),
            MaliCard(child: privacyMode
              ? const Center(child: Text('••••'))
              : DailySpendBarChart(
                  values: section.dailySpend.map((d) => d.total.toDouble()).toList(),
                  days: section.dailySpend.map((d) => d.day).toList(),
                  average: section.averageDaily,
                  averageLabel: context.l10n.rptDailyAverage,
                )),
            const SizedBox(height: 16),
            _Enter(
              delay: const Duration(milliseconds: 70),
              child: _WeeklySpendCard(
                section: weekly,
                currencyLabel: currencyLabel,
                privacyMode: privacyMode,
              ),
            ),
            if (section.topCategories.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.s4),
              _CategoryComparisonCard(
                section: section,
                currencyLabel: currencyLabel,
                privacyMode: privacyMode,
              ),
              const SizedBox(height: AppSpacing.s4),
            ],
            if (anomaly != null) ...[
              _AnomalyCard(
                anomaly: anomaly,
                currencyLabel: currencyLabel,
                privacyMode: privacyMode,
              ),
              const SizedBox(height: AppSpacing.s4),
            ],
            _InsightCard(
              icon: delta == null || delta <= 0
                  ? AppLucideIcons.trendingDown
                  : AppLucideIcons.trendingUp,
              title: context.l10n.rptVsPrevPeriod,
              body: delta == null
                  ? context.l10n.rptNeedPrevPeriod
                  : delta <= 0
                      ? context.l10n.rptSpendLower((delta.abs() * 100).round())
                      : context.l10n.rptSpendHigher((delta.abs() * 100).round()),
              // v2: red is reserved for over-budget/failed/destructive.
              color: delta == null || delta <= 0 ? c.success : c.warningText,
            ),
            const SizedBox(height: AppSpacing.s4),
            _InsightCard(
              icon: AppLucideIcons.shapes,
              title: context.l10n.rptHighestSpendDay,
              body:
                  context.l10n.rptHighestDayBody(_money(section.highestDaily,
                      currencyLabel: currencyLabel, privacyMode: privacyMode)),
              color: c.primary,
            ),
            const SizedBox(height: AppSpacing.s4),
            _InsightCard(
              icon: AppLucideIcons.sun,
              title: context.l10n.rptQuickTip,
              body: section.topCategories.isEmpty
                  ? context.l10n.rptAddMoreTx
                  : context.l10n.rptTopCategoryHint(
                      section.topCategories.first.category.name),
              color: c.actionText,
            ),
          ],
        ));
  }
}

class _CategoryComparisonCard extends StatelessWidget {
  const _CategoryComparisonCard({
    required this.section,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final ReportSection section;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MaliCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _VisualSectionTitle(icon: AppLucideIcons.barChart3,
              title: context.l10n.rptVsPrevPeriod,
              subtitle: context.l10n.rptNet),
          for (final slice in section.topCategories.take(5)) ...[
            const SizedBox(height: AppSpacing.s4),
            _CategoryComparisonRow(slice: slice,
                currencyLabel: currencyLabel, privacyMode: privacyMode),
          ],
          if (!privacyMode && section.topCategories
              .every((slice) => slice.previousTotal == null)) ...[
            const SizedBox(height: AppSpacing.s3),
            Text(context.l10n.rptNeedPrevPeriod,
                style: AppTypography.caption(c.textLight)),
          ],
        ],
      ),
    );
  }
}

class _CategoryComparisonRow extends StatelessWidget {
  const _CategoryComparisonRow({required this.slice,
      required this.currencyLabel, required this.privacyMode});

  final CategorySlice slice;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final previous = slice.previousTotal;
    // A refund-dominated or absent baseline has no useful spending percentage.
    // Percent labels use integer minor units; doubles are only bar coordinates.
    String? percent;
    if (!privacyMode && previous != null &&
        previous.minorUnits > 0 && !slice.total.isNegative) {
      final delta = BigInt.from(slice.total.minorUnits) -
          BigInt.from(previous.minorUnits);
      final baseline = BigInt.from(previous.minorUnits);
      final rounded = (delta.abs() * BigInt.from(100) + baseline ~/ BigInt.two)
          ~/ baseline;
      percent = '${delta.isNegative ? '−' : delta > BigInt.zero ? '+' : ''}$rounded%';
    }
    final maxMinor = [BigInt.from(slice.total.minorUnits).abs(),
      BigInt.from(previous?.minorUnits ?? 0).abs(), BigInt.one]
        .reduce((a, b) => a > b ? a : b);
    final tone = previous != null && slice.total.compareTo(previous) > 0
        ? c.warning : c.success;
    return Column(
      key: ValueKey('report-category-comparison-${slice.category.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          AppAvatar.category(category: slice.category, size: 28),
          const SizedBox(width: AppSpacing.s2),
          Expanded(child: Text(slice.category.name,
              style: AppTypography.subhead(c.textMain))),
          if (percent != null) Flexible(child: Text(percent,
              textAlign: TextAlign.end, textDirection: TextDirection.ltr,
              style: AppTypography.caption(tone))),
        ]),
        const SizedBox(height: AppSpacing.s2),
        for (final entry in [
          (context.l10n.rptSelectedPeriod, slice.total, c.cta),
          if (previous != null) (context.l10n.rptPreviousPeriod, previous, c.textLight),
        ]) ...[
          Row(children: [
            Expanded(child: Text(entry.$1,
                style: AppTypography.caption(c.textLight))),
            Flexible(child: Text(_money(entry.$2,
                currencyLabel: currencyLabel, privacyMode: privacyMode),
                textAlign: TextAlign.end,
                style: AppTypography.caption(c.textMain))),
          ]),
          if (!privacyMode) ...[
            const SizedBox(height: 4),
            ClipRRect(borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: BigInt.from(entry.$2.minorUnits).abs().toDouble() /
                    maxMinor.toDouble(),
                minHeight: 5, backgroundColor: c.surface2,
                valueColor: AlwaysStoppedAnimation(entry.$3),
              )),
          ],
          const SizedBox(height: AppSpacing.s2),
        ],
        if (!privacyMode && slice.hasRefunds)
          Text('${context.l10n.rptIncludesRefund}${formatMoney(slice.refunds!)}',
              style: AppTypography.caption(c.textLight)),
      ],
    );
  }
}

class _DetailsTab extends StatelessWidget {
  const _DetailsTab({
    required this.section,
    required this.currencyLabel,
    required this.privacyMode,
  });


  final ReportSection section;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    return MeltTail(
        startAt: 0,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.s4, AppSpacing.gutter, 120),
          children: [
            _CategoryRankingCard(
              section: section,
              currencyLabel: currencyLabel,
              privacyMode: privacyMode,
            ),
            const SizedBox(height: AppSpacing.s4),
            _MerchantRankingCard(
              section: section,
              currencyLabel: currencyLabel,
              privacyMode: privacyMode,
            ),
          ],
        ));
  }
}

/// v3 Insights summary: ONE [QirshSummaryCard] — the net once, its refund
/// breakdown as a caption, and the period's three stats in the strip. The
/// period is the card's scope chip (the hero no longer carries a selector).
class _PeriodCard extends StatelessWidget {
  const _PeriodCard({
    required this.section,
    required this.currencyLabel,
    required this.privacyMode,
    required this.periodLabel,
    required this.onPeriodTap,
  });

  final ReportSection section;
  final String currencyLabel;
  final bool privacyMode;
  final String periodLabel;
  final VoidCallback onPeriodTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final count = section.transactionCount;
    // Stats render their final, exact values at once. The old strip counted
    // up from zero on every mount, which read as the numbers changing right
    // after the tab appeared (4,939.33 → 5,210.27, 44 → 48 mid-animation).
    String figure(Money value) => privacyMode ? '••••' : formatMoney(value);
    return QirshSummaryCard(
      label: section.hasRefunds
          ? context.l10n.rptNetPeriodSpend
          : context.l10n.rptSelectedPeriodSpend,
      scopeLabel: periodLabel,
      onScopeTap: onPeriodTap,
      amount: Align(
        alignment: AlignmentDirectional.centerStart,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                if (privacyMode)
                  Text('••••', style: AppTypography.amountLarge(c.textPrimary))
                else
                  MoneyText(section.total,
                      style: AppTypography.amountLarge(c.textPrimary)),
                const SizedBox(width: AppSpacing.s1),
                Text(currencyLabel,
                    style: AppTypography.caption(c.textSecondary)),
              ],
            ),
          ),
        ),
      ),
      // UX-022 — explain the netting instead of asking the user to trust it.
      //
      // Refunds subtract silently under the documented contract
      // (net = payments + withdrawals − refunds), so the QA's real case
      // showed 2,120.00 for transactions of 420.00 + 1,899.00 with a 199.00
      // refund, and nothing on screen accounted for the 199. The caption is
      // that same contract written out: gross expenses · refunds → the net
      // headline above.
      //
      // Shown ONLY when a refund exists, so a period without one keeps the
      // single clean headline it has today.
      caption: section.hasRefunds
          ? Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(context.l10n.rptTotalExpenses),
                _RefundLine(
                  amount: section.grossExpense,
                  privacyMode: privacyMode,
                ),
                const Text('·'),
                Text(context.l10n.rptRefunds),
                _RefundLine(
                  amount: section.refunds,
                  privacyMode: privacyMode,
                  negative: true,
                  color: c.income,
                ),
              ],
            )
          : null,
      stats: [
        QirshSummaryStat(
          value: Text(figure(section.averageDaily), maxLines: 1),
          label: context.l10n.rptDailyAverage,
        ),
        QirshSummaryStat(
          value: Text(figure(section.highestDaily), maxLines: 1),
          label: context.l10n.rptHighestDay,
        ),
        QirshSummaryStat(
          value: Text(
              privacyMode ? '••••' : count == null ? '—' : '$count',
              maxLines: 1),
          label: context.l10n.rptExpenseCountLabel,
        ),
      ],
    );
  }
}

class _WeeklySpendCard extends StatelessWidget {
  const _WeeklySpendCard({
    required this.section,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final ReportSection section;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _VisualSectionTitle(
            icon: AppLucideIcons.barChart3,
            title: context.l10n.rptThisWeekUsage,
            subtitle: context.l10n.txnRange7,
          ),
          const SizedBox(height: AppSpacing.s4),
          WeeklyCapsuleBarChart(
            days: section.dailySpend,
            currencyLabel: currencyLabel,
            privacyMode: privacyMode,
            height: 186,
            barWidth: 24,
            maxBarHeight: 78,
          ),
          const Divider(height: AppSpacing.s5),
          Row(
            children: [
              Expanded(
                child: _MiniMetric(
                  label: context.l10n.rptAverage,
                  value: _money(section.averageDaily,
                      currencyLabel: currencyLabel, privacyMode: privacyMode),
                ),
              ),
              Expanded(
                child: _MiniMetric(
                  label: context.l10n.rptHighest,
                  value: _money(section.highestDaily,
                      currencyLabel: currencyLabel, privacyMode: privacyMode),
                ),
              ),
              Expanded(
                child: _MiniMetric(
                  label: context.l10n.rptTotal,
                  value: _money(section.total,
                      currencyLabel: currencyLabel, privacyMode: privacyMode),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CategoryDistributionCard extends StatefulWidget {
  const _CategoryDistributionCard({
    required this.section,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final ReportSection section;
  final String currencyLabel;
  final bool privacyMode;

  @override
  State<_CategoryDistributionCard> createState() =>
      _CategoryDistributionCardState();
}

class _CategoryDistributionCardState extends State<_CategoryDistributionCard> {
  int? _selected;

  void _select(int? index) => setState(() => _selected = index);

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    final currencyLabel = widget.currencyLabel;
    final privacyMode = widget.privacyMode;
    final slices = [
      for (final slice in section.topCategories)
        SpendingChartSlice(
          category: slice.category,
          total: slice.total.toDouble(),
          percent: slice.percent,
          count: slice.count,
          amount: slice.total,
        ),
    ];
    final top = section.topCategories.fold<double>(
        0, (max, slice) => math.max(max, slice.total.toDouble()));
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.s4, AppSpacing.s4, AppSpacing.s4, AppSpacing.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _VisualSectionTitle(
            icon: AppLucideIcons.pieChart,
            title: context.l10n.rptByCategory,
            subtitle: _money(section.total,
                currencyLabel: currencyLabel, privacyMode: privacyMode),
          ),
          const SizedBox(height: AppSpacing.s5),
          // v2 donut: 200pt, v2 category palette, clockwise draw-in from 12
          // o'clock with the centre total counting up (m.chart). Tapping an arc
          // or a legend row lifts it and swaps the centre to its amount.
          CategoryDonutChart(
            slices: slices,
            currencyLabel: currencyLabel,
            centerLabel: privacyMode ? '••••' : formatMoney(section.total),
            centerCurrency: currencyLabel,
            centerAmount: section.total,
            compactCenter: true,
            framed: false,
            showLegend: false,
            height: 200,
            privacyMode: privacyMode,
            selectedIndex: _selected,
            onSelectionChanged: _select,
          ),
          const SizedBox(height: AppSpacing.s4),
          for (var i = 0; i < section.topCategories.length; i++)
            _Enter(
              delay: AppMotion.rowStagger * math.min(i, 8),
              child: _CategoryLegendTile(
                slice: section.topCategories[i],
                share: top <= 0
                    ? 0
                    : section.topCategories[i].total.toDouble() / top,
                currencyLabel: currencyLabel,
                privacyMode: privacyMode,
                dimmed: _selected != null && _selected != i,
                onTap: () {
                  HapticFeedback.selectionClick();
                  _select(_selected == i ? null : i);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _CategoryRankingCard extends StatelessWidget {
  const _CategoryRankingCard({
    required this.section,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final ReportSection section;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _VisualSectionTitle(
            icon: AppLucideIcons.layers,
            title: context.l10n.rptByCategory,
            subtitle: _money(section.total,
                currencyLabel: currencyLabel, privacyMode: privacyMode),
          ),
          const SizedBox(height: AppSpacing.s3),
          if (section.topCategories.isEmpty)
            Text(context.l10n.rptAddMoreTx,
                style: AppTypography.caption(c.textLight))
          else
            for (var i = 0; i < section.topCategories.length; i++) ...[
              if (i > 0) const Divider(height: AppSpacing.s4),
              _CategoryRankingRow(
                slice: section.topCategories[i],
                currencyLabel: currencyLabel,
                privacyMode: privacyMode,
              ),
            ],
        ],
      ),
    );
  }
}

class _CategoryRankingRow extends StatelessWidget {
  const _CategoryRankingRow({
    required this.slice,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final CategorySlice slice;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        AppAvatar.category(category: slice.category, size: AppSpacing.avatarSm),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(slice.category.name,
                  style: AppTypography.subhead(c.textMain)),
              Text(
                '${(slice.percent * 100).round()}%'
                '${slice.count > 0 ? ' · ${context.l10n.rptMerchantTxCount(slice.count)}' : ''}',
                style: AppTypography.caption(c.textLight),
              ),
              if (slice.hasRefunds && !privacyMode)
                Text(
                  '${context.l10n.rptIncludesRefund}${formatMoney(slice.refunds!)}',
                  style: AppTypography.caption(c.textLight),
                ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.s2),
        Flexible(
          child: Text(
            _money(slice.total,
                currencyLabel: currencyLabel, privacyMode: privacyMode),
            textAlign: TextAlign.end,
            style: AppTypography.subhead(c.textMain),
          ),
        ),
      ],
    );
  }
}

class _MerchantRankingCard extends StatelessWidget {
  const _MerchantRankingCard({
    required this.section,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final ReportSection section;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final maxTotal = section.topMerchants.fold<double>(
      1,
      (max, merchant) {
        final chartValue = merchant.total.toDouble();
        return chartValue > max ? chartValue : max;
      },
    );
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _VisualSectionTitle(
            icon: AppLucideIcons.store,
            title: context.l10n.rptByMerchant,
            subtitle: context.l10n.rptTopMerchantsSub,
          ),
          const SizedBox(height: AppSpacing.s3),
          if (section.topMerchants.isEmpty)
            Text(context.l10n.rptMerchantsEmpty,
                style: AppTypography.caption(c.textLight))
          else
            for (final (i, merchant) in section.topMerchants.take(8).indexed) ...[
              _MerchantBarRow(
                merchant: merchant,
                maxTotal: maxTotal,
                currencyLabel: currencyLabel,
                privacyMode: privacyMode,
                index: i,
              ),
              if (merchant != section.topMerchants.take(8).last)
                const SizedBox(height: AppSpacing.s4),
            ],
        ],
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Text(label, style: AppTypography.caption(c.textLight)),
        const SizedBox(height: 4),
        Text(value,
            textAlign: TextAlign.center,
            style: AppTypography.caption(c.textMain)
                .copyWith(fontWeight: FontWeight.bold)),
      ],
    );
  }
}

class _VisualSectionTitle extends StatelessWidget {
  const _VisualSectionTitle({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        // v2: blue = "you are here"; green stays reserved for money/health.
        Icon(icon, color: c.actionText, size: 22),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTypography.cardTitle(c.textMain)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: AppTypography.caption(c.textLight),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CategoryLegendTile extends StatelessWidget {
  const _CategoryLegendTile({
    required this.slice,
    required this.share,
    required this.currencyLabel,
    required this.privacyMode,
    required this.dimmed,
    required this.onTap,
  });

  final CategorySlice slice;
  final double share;
  final String currencyLabel;
  final bool privacyMode;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final accent = slice.category.accent(Theme.of(context).brightness);
    // v2 legend row: name first, then amount, then share — never «32% تسوق».
    // UX-022 item 2 — «تسوق 1,700.00» matched no transaction: an
    // expense of 1,899.00 with a 199.00 refund netted into it. The
    // row now carries the refund, so the figure is explainable
    // without changing the contract that produced it. (The refund
    // string carries its own « · » separator.)
    final meta = [
      if (slice.count > 0) context.l10n.rptMerchantTxCount(slice.count),
      if (slice.hasRefunds && !privacyMode)
        '${context.l10n.rptIncludesRefund}${formatMoney(slice.refunds!)}',
    ].join().trim();
    return AnimatedOpacity(
      duration: AppMotion.micro,
      opacity: dimmed ? .35 : 1,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.button),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  AppAvatar.category(category: slice.category, size: 40),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(slice.category.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.bodyStrong(c.textMain)),
                        if (meta.isNotEmpty)
                          Text(meta,
                              style: AppTypography.caption(c.textLight)),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _AmountText(
                        amount: slice.total,
                        currencyLabel: currencyLabel,
                        privacyMode: privacyMode,
                      ),
                      Text('${(slice.percent * 100).round()}%',
                          textDirection: TextDirection.ltr,
                          style: AppTypography.caption(c.textLight)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s1),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 52),
                child: ChartBar(value: share, height: 3, color: accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MerchantBarRow extends StatelessWidget {
  const _MerchantBarRow({
    required this.merchant,
    required this.maxTotal,
    required this.currencyLabel,
    required this.privacyMode,
    this.index = 0,
  });

  final MerchantSpend merchant;
  final double maxTotal;
  final String currencyLabel;
  final bool privacyMode;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ratio = maxTotal <= 0
        ? 0.0
        : (merchant.total.toDouble() / maxTotal).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            AppAvatar.brand(name: merchant.name),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // v2: the merchant's natural case («Carrefour», not
                    // «CARREFOUR»).
                    _naturalCase(merchant.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyStrong(c.textMain),
                  ),
                  // UX-022 item 4 — «نون · 1,700.00 · 2 عمليات» matched no
                  // transaction, because one of the two rows was a 199.00 refund
                  // netted into the total. The count was never wrong: the refund
                  // genuinely is one of the transactions the total is built from.
                  // What was missing was the refund, which is what made the pair
                  // impossible to reconcile. Stating it makes the count coherent
                  // rather than dropping it and hiding the netting further.
                  if (merchant.count > 0)
                    Wrap(
                      children: [
                        Text(context.l10n.rptMerchantTxCount(merchant.count),
                            style: AppTypography.caption(c.textLight)),
                        if (merchant.hasRefunds && !privacyMode) ...[
                          Text(context.l10n.rptIncludesRefund,
                              style: AppTypography.caption(c.textLight)),
                          MoneyText(
                            merchant.refunds!,
                            style: AppTypography.caption(c.textLight),
                          ),
                        ],
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            _AmountText(
              amount: merchant.total,
              currencyLabel: currencyLabel,
              privacyMode: privacyMode,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s2),
        // v2 merchant bar: 6pt, spans the row under the text, anchored at the
        // leading edge; draws in with a 30ms stagger (m.chart).
        Padding(
          padding: const EdgeInsetsDirectional.only(
              start: AppSpacing.avatar + AppSpacing.s3),
          child: ChartBar(
            value: ratio.toDouble(),
            delay: Duration(milliseconds: 30 * math.min(index, 8)),
          ),
        ),
      ],
    );
  }
}

/// «CARREFOUR» → «Carrefour»; short acronyms («KFC») and mixed-case names are
/// left exactly as they are.
String _naturalCase(String name) {
  final letters = name.replaceAll(RegExp(r'[^A-Za-z]'), '');
  if (letters.length <= 3 || letters != letters.toUpperCase()) return name;
  return name.splitMapJoin(RegExp(r'[A-Za-z]+'),
      onMatch: (m) {
        final word = m[0]!;
        return word[0] + word.substring(1).toLowerCase();
      },
      onNonMatch: (n) => n);
}

/// A row amount: `amount.row` figure + the currency as a muted caption run.
class _AmountText extends StatelessWidget {
  const _AmountText({
    required this.amount,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final Money amount;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: privacyMode ? '••••' : formatMoney(amount),
          style: AppTypography.amountSmall(c.textMain),
        ),
        TextSpan(
          text: ' $currencyLabel',
          style: AppTypography.caption(c.textLight),
        ),
      ]),
      textAlign: TextAlign.end,
      maxLines: 1,
    );
  }
}

/// v2 unusual-spend card — Tinted role: `warningBg` (+1px warning@24% in
/// dark), warning glyph tile that wiggles once, «3.4×» in warning text.
class _AnomalyCard extends StatelessWidget {
  const _AnomalyCard({
    required this.anomaly,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final SpendingAnomaly anomaly;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ratio = anomaly.ratio.toStringAsFixed(1);
    final body = privacyMode
        ? context.l10n.rptAnomalyPrivate(_dateLabel(anomaly.day))
        : context.l10n.rptAnomalyDetail(
            _dateLabel(anomaly.day),
            _money(anomaly.total,
                currencyLabel: currencyLabel, privacyMode: false),
            ratio);
    final bodyStyle = AppTypography.callout(c.textSecondary);
    final highlight = '$ratio×';
    final at = privacyMode ? -1 : body.indexOf(highlight);
    Widget tile = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: c.warning.withValues(alpha: .20),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Icon(AppLucideIcons.alertTriangle, color: c.warningText, size: 22),
    );
    if (!shouldReduceMotion(context)) {
      // One 6° wiggle on enter (spring.lively), no loop.
      final glyph = tile;
      tile = TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 600),
        curve: Curves.linear,
        builder: (context, v, child) => Transform.rotate(
          angle: math.sin(v * math.pi * 3) * (1 - v) * 6 * math.pi / 180,
          child: child,
        ),
        child: glyph,
      );
    }
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.warningBg,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: isDark
            ? Border.all(color: c.warning.withValues(alpha: .24))
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          tile,
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l10n.rptUnusualSpend,
                    style: AppTypography.cardTitle(c.textMain)),
                const SizedBox(height: 4),
                if (at < 0)
                  Text(body, style: bodyStyle)
                else
                  Text.rich(TextSpan(style: bodyStyle, children: [
                    TextSpan(text: body.substring(0, at)),
                    TextSpan(
                        text: highlight,
                        style: bodyStyle.copyWith(
                            color: c.warningText,
                            fontWeight: FontWeight.w600)),
                    TextSpan(text: body.substring(at + highlight.length)),
                  ])),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InsightCard extends StatelessWidget {
  const _InsightCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.bodyStrong(c.textMain)),
                const SizedBox(height: 4),
                Text(body, style: AppTypography.caption(c.textLight)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WeeklyInsightCard extends StatelessWidget {
  const _WeeklyInsightCard({
    required this.weekly,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final ReportSection weekly;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final delta = weekly.deltaPercent;
    final deltaSign = (delta ?? 0) < 0 ? '↓' : '↑';
    // v2: red is reserved for over-budget/failed — a rise reads in warning.
    final deltaColor = (delta ?? 0) < 0 ? c.success : c.warningText;
    final deltaText = delta == null
        ? null
        : context.l10n.rptVsLastWeek(
            deltaSign, (delta.abs() * 100).toStringAsFixed(0));

    final bestDay = weekly.bestSavingsDay;
    final topCat = weekly.topCategory;
    final topMerchant = weekly.topMerchant;

    final insights = <(IconData, String, Color)>[
      if (deltaText != null)
        (
          (delta ?? 0) < 0
              ? AppLucideIcons.trendingDown
              : AppLucideIcons.trendingUp,
          deltaText,
          deltaColor,
        ),
      if (topCat != null)
        (
          AppLucideIcons.shapes,
          context.l10n.rptTopCategoryWeek(topCat.category.name),
          c.actionText,
        ),
      if (bestDay != null)
        (
          AppLucideIcons.star,
          context.l10n.rptBestSavingDay(
              '${bestDay.day.day}/${bestDay.day.month}',
              _money(bestDay.total, currencyLabel: currencyLabel, privacyMode: privacyMode)),
          c.success,
        ),
      if (topMerchant != null)
        (
          AppLucideIcons.store,
          context.l10n.rptTopMerchantWeek(topMerchant.name,
              _money(topMerchant.total, currencyLabel: currencyLabel, privacyMode: privacyMode)),
          c.textMuted,
        ),
    ];

    if (insights.isEmpty) return const SizedBox.shrink();

    // v2: a Group holding a 2×2 grid of Inset mini-tiles instead of a wall
    // of text lines.
    final inset = Theme.of(context).brightness == Brightness.dark
        ? c.surfaceMuted
        : c.surfaceElevated;
    Widget tile((IconData, String, Color) item) => Container(
          padding: const EdgeInsets.all(AppSpacing.s3),
          decoration: BoxDecoration(
            color: inset,
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(item.$1, size: 20, color: item.$3),
              const SizedBox(height: AppSpacing.s2),
              Text(item.$2, style: AppTypography.subhead(c.textMain)),
            ],
          ),
        );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.l10n.rptWeekSummary,
              style: AppTypography.cardTitle(c.textMain)),
          const SizedBox(height: AppSpacing.s3),
          for (var i = 0; i < insights.length; i += 2) ...[
            if (i > 0) const SizedBox(height: AppSpacing.s2),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: tile(insights[i])),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: i + 1 < insights.length
                        ? tile(insights[i + 1])
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One figure of the UX-022 refund caption. Amounts render through [MoneyText]
/// so gross, refunds and net are exact and therefore always reconcile on
/// screen. Inherits the caption style of the summary card.
class _RefundLine extends StatelessWidget {
  const _RefundLine({
    required this.amount,
    required this.privacyMode,
    this.negative = false,
    this.color,
  });

  final Money amount;
  final bool privacyMode;
  final bool negative;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    final style = color == null ? base : base.copyWith(color: color);
    if (privacyMode) return Text('••••', style: style);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (negative) Text('−', style: style),
          MoneyText(amount,
              style: style, fractionScale: 1, fractionOpacity: 1),
        ],
      ),
    );
  }
}

/// v3 hero action: a small glass pill on the section photo. Runs the same
/// report flow the old full-width «Create report» button did.
class _ReportPill extends StatelessWidget {
  const _ReportPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      side: BorderSide(color: Colors.white.withValues(alpha: .18)),
    );
    return Semantics(
      button: true,
      label: context.l10n.rcCreateReport,
      excludeSemantics: true,
      child: Material(
        color: Colors.white.withValues(alpha: .14),
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(AppLucideIcons.fileText,
                      size: 17, color: Colors.white),
                  const SizedBox(width: AppSpacing.s1),
                  Text(context.l10n.insV3Report,
                      style: AppTypography.caption(Colors.white)
                          .copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dims figures that belong to the previous (period, account) scope while the
/// fresh bundle loads — see [_ReportsScreenState._freshFor].
class _Settling extends StatelessWidget {
  const _Settling({required this.settling, required this.child});

  final bool settling;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: AppMotion.micro,
      opacity: settling ? .45 : 1,
      child: child,
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
