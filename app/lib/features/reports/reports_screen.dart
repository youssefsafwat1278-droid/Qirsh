import 'package:flutter/material.dart';
import '../transactions/transactions_providers.dart';
import '../common/money_text.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/utils/async_reload_safe.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../ads/ad_placement.dart';
import '../ads/qirsh_ad_banner.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/calm_page_header.dart';
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

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(reportsProvider);
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
            const presets = [
              TransactionsDatePreset.thisMonth,
              TransactionsDatePreset.previousMonth,
              TransactionsDatePreset.last90Days,
            ];
            final preset = effectiveTransactionsRange(
              ref.watch(transactionsDateRangeProvider),
            ).preset;
            return QirshSectionBackdrop(
                child: SafeArea(
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
                                  sectionHeight: 225,
                                  useSafeAreaTop: false,
                                  title: context.l10n.rptInsightsTitle,
                                  subtitle: context.l10n.rptInsightsSub,
                                  leading: Navigator.of(context).canPop()
                                      ? const BackButton()
                                      : null,
                                  coverBottom: Builder(builder: (context) {
                                    final controller =
                                        DefaultTabController.of(context);
                                    final language =
                                        Localizations.localeOf(context)
                                            .languageCode;
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        FilledButton.icon(
                                          onPressed: () =>
                                              _openReport(context, ref),
                                          icon: const Icon(
                                              AppLucideIcons.fileText,
                                              size: 17),
                                          label:
                                              Text(context.l10n.rcCreateReport),
                                        ),
                                        const SizedBox(height: AppSpacing.s2),
                                        AppPillTabBar(
                                          onPhoto: true,
                                          tabs: [
                                            for (final datePreset in presets)
                                              transactionsRangeForPreset(
                                                      datePreset)
                                                  .labelIn(language),
                                          ],
                                          selectedIndex: presets.indexWhere(
                                              (value) => value == preset),
                                          onSelected: (index) => ref
                                                  .read(
                                                      transactionsDateRangeProvider
                                                          .notifier)
                                                  .state =
                                              transactionsRangeForPreset(
                                                  presets[index]),
                                        ),
                                        const SizedBox(height: AppSpacing.s2),
                                        AnimatedBuilder(
                                          animation: controller,
                                          builder: (context, _) =>
                                              AppPillTabBar(
                                            onPhoto: true,
                                            tabs: [
                                              context.l10n.rptTabOverview,
                                              context.l10n.rptTabTrends,
                                              context.l10n.rptTabDetails,
                                            ],
                                            selectedIndex: controller.index,
                                            onSelected: controller.animateTo,
                                          ),
                                        ),
                                      ],
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
                                  child: _PeriodCard(
                                    section: section,
                                    currencyLabel: currencyLabel,
                                    privacyMode: privacyMode,
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
                      body: TabBarView(
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
                      ),
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
            CalmKpiTiles(margin: EdgeInsets.zero, metrics: [
              CalmMetric(label: context.l10n.rptDailyAverage,
                value: _money(section.averageDaily, currencyLabel: currencyLabel, privacyMode: privacyMode)),
              CalmMetric(label: context.l10n.rptHighestDay,
                value: _money(section.highestDaily, currencyLabel: currencyLabel, privacyMode: privacyMode)),
              CalmMetric(label: context.l10n.rptExpenseCountLabel,
                value: privacyMode ? '••••' : section.transactionCount?.toString() ?? '—'),
            ]),
            const SizedBox(height: 16),
            if (section.topCategories.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.s4),
              PremiumMotion(
                delay: const Duration(milliseconds: 120),
                child: _CategoryDistributionCard(
                  section: section,
                  currencyLabel: currencyLabel,
                  privacyMode: privacyMode,
                ),
              ),
            ],
            if (section.anomaly case final SpendingAnomaly anomaly) ...[
              _InsightCard(
                icon: AppLucideIcons.alertTriangle,
                title: context.l10n.rptUnusualSpend,
                body: privacyMode ? context.l10n.rptAnomalyPrivate(_dateLabel(anomaly.day))
                  : context.l10n.rptAnomalyDetail(_dateLabel(anomaly.day),
                    _money(anomaly.total, currencyLabel: currencyLabel, privacyMode: false),
                    anomaly.ratio.toStringAsFixed(1)),
                color: context.colors.danger,
              ),
              const SizedBox(height: 16),
            ],
            if (!weekly.total.isZero && !weekly.total.isNegative) ...[
              PremiumMotion(
                child: _WeeklyInsightCard(
                  weekly: weekly,
                  currencyLabel: currencyLabel,
                  privacyMode: privacyMode,
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
            ],
            if (section.topMerchants.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.s4),
              PremiumMotion(
                delay: const Duration(milliseconds: 160),
                child: _MerchantRankingCard(
                  section: section,
                  currencyLabel: currencyLabel,
                  privacyMode: privacyMode,
                ),
              ),
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
            PremiumMotion(
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
              _InsightCard(
                icon: AppLucideIcons.alertTriangle,
                title: context.l10n.rptUnusualSpend,
                body: privacyMode
                    ? context.l10n.rptAnomalyPrivate(_dateLabel(anomaly.day))
                    : context.l10n.rptAnomalyDetail(
                        _dateLabel(anomaly.day),
                        _money(anomaly.total,
                            currencyLabel: currencyLabel, privacyMode: false),
                        anomaly.ratio.toStringAsFixed(1)),
                color: c.danger,
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
              color: delta == null || delta <= 0 ? c.success : c.danger,
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
              color: c.cta,
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
          (context.l10n.rptSelectedPeriod, slice.total, c.primary),
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

class _PeriodCard extends StatelessWidget {
  const _PeriodCard({
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.rptSelectedPeriod, style: AppTypography.subhead(c.textLight)),
          const SizedBox(height: AppSpacing.s2),
          Text(
              _money(section.total,
                  currencyLabel: currencyLabel, privacyMode: privacyMode),
              style: AppTypography.custom(size: 30, weight: FontWeight.w700,
                height: 1.2, color: c.textMain, tabular: true)),
          Text(
              section.hasRefunds ? context.l10n.rptNetPeriodSpend : context.l10n.rptSelectedPeriodSpend,
              style: AppTypography.caption(c.textLight)),
          // UX-022 — explain the netting instead of asking the user to trust it.
          //
          // Refunds subtract silently under the documented contract
          // (net = payments + withdrawals − refunds), so the QA's real case
          // showed 2,120.00 for transactions of 420.00 + 1,899.00 with a 199.00
          // refund, and nothing on screen accounted for the 199. The three
          // figures below are that same contract, written out.
          //
          // Shown ONLY when a refund exists, so a period without one keeps the
          // single clean headline it has today.
          if (section.hasRefunds) ...[
            const SizedBox(height: AppSpacing.s3),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s3, vertical: AppSpacing.s2),
              decoration: BoxDecoration(
                color: c.surfaceMuted,
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: Column(
                children: [
                  _RefundLine(
                    label: context.l10n.rptTotalExpenses,
                    amount: section.grossExpense,
                    currencyLabel: currencyLabel,
                    privacyMode: privacyMode,
                  ),
                  const SizedBox(height: 4),
                  _RefundLine(
                    label: context.l10n.rptRefunds,
                    amount: section.refunds,
                    currencyLabel: currencyLabel,
                    privacyMode: privacyMode,
                    negative: true,
                    color: c.success,
                  ),
                  const Divider(height: AppSpacing.s3),
                  _RefundLine(
                    label: context.l10n.rptNet,
                    amount: section.total,
                    currencyLabel: currencyLabel,
                    privacyMode: privacyMode,
                    strong: true,
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

class _CategoryDistributionCard extends StatelessWidget {
  const _CategoryDistributionCard({
    required this.section,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final ReportSection section;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final slices = [
      for (final slice in section.topCategories)
        SpendingChartSlice(
          category: slice.category,
          total: slice.total.toDouble(),
          percent: slice.percent,
          count: slice.count,
        ),
    ];
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _VisualSectionTitle(
            icon: AppLucideIcons.pieChart,
            title: context.l10n.rptByCategory,
            subtitle: _money(section.total,
                currencyLabel: currencyLabel, privacyMode: privacyMode),
          ),
          const SizedBox(height: AppSpacing.s3),
          CategoryDonutChart(
            slices: slices,
            currencyLabel: currencyLabel,
            centerLabel: privacyMode ? '••••' : formatMoney(section.total),
            centerCurrency: currencyLabel,
            compactCenter: true,
            framed: false,
            showLegend: false,
            height: 174,
          ),
          const SizedBox(height: AppSpacing.s3),
          LayoutBuilder(builder: (context, constraints) {
            final twoColumns = constraints.maxWidth >= 385 &&
                MediaQuery.textScalerOf(context).scale(14) <= 17;
            return Wrap(
              spacing: AppSpacing.s3,
              runSpacing: AppSpacing.s3,
              children: [
                for (final slice in section.topCategories)
                  SizedBox(
                    width: twoColumns
                        ? (constraints.maxWidth - AppSpacing.s3) / 2
                        : constraints.maxWidth,
                    child: _CategoryLegendTile(
                      slice: slice,
                      currencyLabel: currencyLabel,
                      privacyMode: privacyMode,
                    ),
                  ),
              ],
            );
          }),
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
            for (final merchant in section.topMerchants.take(8)) ...[
              _MerchantBarRow(
                merchant: merchant,
                maxTotal: maxTotal,
                currencyLabel: currencyLabel,
                privacyMode: privacyMode,
              ),
              if (merchant != section.topMerchants.take(8).last)
                const SizedBox(height: AppSpacing.s3),
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
        Icon(icon, color: c.success, size: 22),
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
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                Localizations.localeOf(context).languageCode == 'en'
                    ? '${(slice.percent * 100).round()}% ${slice.category.name}'
                    : '%${(slice.percent * 100).round()} ${slice.category.name}',
                style: AppTypography.subhead(c.textMain),
              ),
              // UX-022 item 2 — «تسوق 1,700.00» matched no transaction: an
              // expense of 1,899.00 with a 199.00 refund netted into it. The
              // row now carries the refund, so the figure is explainable
              // without changing the contract that produced it.
              Text(
                '${_money(slice.total, currencyLabel: currencyLabel, privacyMode: privacyMode)}'
                '${slice.count > 0 ? ' · ${context.l10n.rptMerchantTxCount(slice.count)}' : ''}'
                '${slice.hasRefunds && !privacyMode ? '${context.l10n.rptIncludesRefund}${formatMoney(slice.refunds!)}' : ''}',
                style: AppTypography.caption(c.textLight),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MerchantBarRow extends StatelessWidget {
  const _MerchantBarRow({
    required this.merchant,
    required this.maxTotal,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final MerchantSpend merchant;
  final double maxTotal;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ratio = maxTotal <= 0
        ? 0.0
        : (merchant.total.toDouble() / maxTotal).clamp(0.0, 1.0);
    return Row(
      children: [
        AppAvatar.brand(name: merchant.name),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      merchant.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.subhead(c.textMain),
                    ),
                  ),
                  Text(
                    _money(merchant.total,
                        currencyLabel: currencyLabel, privacyMode: privacyMode),
                    style: AppTypography.caption(c.textSecondary)
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 6,
                  backgroundColor: c.surface2,
                  valueColor: AlwaysStoppedAnimation(c.primary),
                ),
              ),
              // UX-022 item 4 — «نون · 1,700.00 · 2 عمليات» matched no
              // transaction, because one of the two rows was a 199.00 refund
              // netted into the total. The count was never wrong: the refund
              // genuinely is one of the transactions the total is built from.
              // What was missing was the refund, which is what made the pair
              // impossible to reconcile. Stating it makes the count coherent
              // rather than dropping it and hiding the netting further.
              if (merchant.count > 0) ...[
                const SizedBox(height: 3),
                Row(
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
            ],
          ),
        ),
      ],
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
    final deltaColor = (delta ?? 0) < 0 ? c.success : c.danger;
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
          c.cta,
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

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.rptWeekSummary, style: AppTypography.bodyStrong(c.textMain)),
          const SizedBox(height: AppSpacing.s3),
          ...insights.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s2),
              child: Row(
                children: [
                  Icon(item.$1, size: 15, color: item.$3),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Text(
                      item.$2,
                      style: AppTypography.caption(c.textMain),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One line of the UX-022 refund breakdown. Amounts render through [MoneyText]
/// so the three figures are exact and therefore always reconcile on screen.
class _RefundLine extends StatelessWidget {
  const _RefundLine({
    required this.label,
    required this.amount,
    required this.currencyLabel,
    required this.privacyMode,
    this.negative = false,
    this.strong = false,
    this.color,
  });

  final String label;
  final Money amount;
  final String currencyLabel;
  final bool privacyMode;
  final bool negative;
  final bool strong;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tone = color ?? (strong ? c.textMain : c.textSecondary);
    final style =
        strong ? AppTypography.bodyStrong(tone) : AppTypography.callout(tone);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(child: Text(label, style: AppTypography.callout(c.textLight))),
        const SizedBox(width: AppSpacing.s2),
        if (privacyMode)
          Text('••••', style: style)
        else
          Flexible(
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 3,
              children: [
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (negative) Text('−', style: style),
                        MoneyText(amount, style: style),
                      ],
                    ),
                  ),
                ),
                Text(currencyLabel, style: AppTypography.caption(c.textLight)),
              ],
            ),
          ),
      ],
    );
  }
}
