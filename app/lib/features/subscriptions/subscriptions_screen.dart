import '../help/coach_marks.dart';

import 'package:flutter/material.dart';
import '../../domain/finance/money_format.dart';
import 'package:flutter/services.dart';
import '../../core/utils/l10n_ext.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/di/app_providers.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../ads/ad_placement.dart';
import '../ads/qirsh_ad_banner.dart';
import '../common/app_pill_tab_bar.dart';
import '../common/app_header.dart';
import '../common/app_error_state.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/finance/money.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/finance/bill_metrics.dart';
import '../common/app_avatar.dart';
import '../common/premium_loading.dart';
import 'bill_details_sheet.dart';
import 'bill_form_sheet.dart';
import 'subscriptions_providers.dart';

String _dueInLabel(BuildContext context, DateTime due) {
  final days = due.difference(DateTime.now()).inDays;
  if (days < 0) return context.l10n.subsOverdue;
  if (days == 0) return context.l10n.subsToday;
  return context.l10n.txnInDays(days);
}

class SubscriptionsScreen extends ConsumerWidget {
  const SubscriptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final billsAsync = ref.watch(savedBillsProvider);
    final suggestionsAsync = ref.watch(subscriptionsProvider);
    final baseCur = ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR';
    // UX-024 — the same account the list was filtered by, not a second guess.
    final scopeAccount = ref.watch(billsScopeAccountProvider).valueOrNull;
    final header = AppHeader(
      title: context.l10n.subsTitle,
      sectionPhoto: QirshSectionPhoto.bills,
      action: CoachAnchor(
          target: 'billAdd',
          child: _AddButton(
              onTap: () => BillFormSheet.show(context,
                  initialType: BillType.subscription))),
    );

    return FirstUseGuide(
        id: CoachMarkIds.bills,
        marks: billCoachMarks,
        child: billsAsync.when(
          skipLoadingOnReload: true,
          loading: () => Scaffold(
            appBar: header,
            body: const SkeletonList(rows: 4),
          ),
          error: (e, _) => Scaffold(
            appBar: header,
            body: SingleChildScrollView(
                child: AppErrorState(
              title: context.l10n.txnError,
              description: context.l10n.annTryAgainSoon,
              retryLabel: context.l10n.startRetry,
              onRetry: () => ref.invalidate(savedBillsProvider),
            )),
          ),
          data: (bills) {
            final subs =
                bills.where((b) => b.type == BillType.subscription).toList();
            final insts =
                bills.where((b) => b.type == BillType.installment).toList();
            final suggestions = suggestionsAsync.valueOrNull ?? [];
            // MALI-064n: projected monthly recurring obligation (frequency-
            // normalized, active subscriptions only) — the ONE canonical metric.
            // Summed EXACTLY as Money in the base display currency (currency-
            // isolated); converted to double only here at the display leaf.
            final monthlyTotal = subscriptionMonthlyTotalMoney(subs, baseCur);
            // UX-023 — the installment obligation as its OWN line, so the header's
            // metric and the counters beneath it describe the same world.
            //
            // `monthlyEquivalentsTotalMoney` is deliberately filter-free ("the
            // caller decides"), which is precisely the footgun that produced F-027
            // when a caller forgot. The active filter is therefore explicit here
            // rather than assumed.
            final installmentMonthly = monthlyEquivalentsTotalMoney(
              insts.where((b) => b.status == BillStatus.active),
              baseCur,
            );

            return DefaultTabController(
              length: 2,
              child: Scaffold(
                body: QirshSectionBackdrop(
                  child: SafeArea(
                    bottom: false,
                    child: NestedScrollView(
                      headerSliverBuilder: (context, innerBoxIsScrolled) {
                        return [
                          SliverToBoxAdapter(
                            child: Column(
                              children: [
                                CalmPageHeader(
                                  sectionPhoto: QirshSectionPhoto.bills,
                                  sectionHeight: 165,
                                  useSafeAreaTop: false,
                                  title: context.l10n.subsTitle,
                                  leading: Navigator.of(context).canPop()
                                      ? const BackButton()
                                      : null,
                                  trailing: CoachAnchor(
                                    target: 'billAdd',
                                    child: _AddButton(
                                      onTap: () => BillFormSheet.show(context,
                                          initialType: BillType.subscription),
                                    ),
                                  ),
                                  coverBottom: Builder(builder: (context) {
                                    final controller =
                                        DefaultTabController.of(context);
                                    return AnimatedBuilder(
                                      animation: controller,
                                      builder: (context, _) => AppPillTabBar(
                                        onPhoto: true,
                                        tabs: [
                                          context.l10n.subsTabSubs(subs.length),
                                          context.l10n
                                              .subsTabInst(insts.length),
                                        ],
                                        selectedIndex: controller.index,
                                        onSelected: controller.animateTo,
                                      ),
                                    );
                                  }),
                                ),
                                _BillsHeader(
                                  monthly: monthlyTotal,
                                  installmentMonthly: installmentMonthly,
                                  subsCount: subs.length,
                                  instsCount: insts.length,
                                  currency: Currency.label(context, baseCur),
                                  scopeAccountName: scopeAccount?.name,
                                ),
                                const Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: AppSpacing.gutter),
                                  child: QirshAdBanner(
                                      placement: AdPlacement.subscriptions),
                                ),
                              ],
                            ),
                          ),
                        ];
                      },
                      body: TabBarView(
                        children: [
                          _SubscriptionsTab(
                            meltStartAt: 0,
                            bills: subs,
                            suggestions: suggestions,
                            baseCurrency: baseCur,
                          ),
                          _InstallmentsTab(meltStartAt: 0, bills: insts),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ));
  }
}

class _BillsHeader extends StatelessWidget {
  const _BillsHeader({
    required this.monthly,
    required this.subsCount,
    required this.instsCount,
    required this.currency,
    required this.installmentMonthly,
    required this.scopeAccountName,
  });

  /// R-8 — exact Money. The yearly metric is `monthly × 12`, and multiplying a
  /// double by twelve compounds whatever the conversion already lost.
  final Money monthly;
  final int subsCount;
  final int instsCount;
  final String currency;
  final Money installmentMonthly;

  /// UX-024 — the account the list is filtered to, or null when nothing scopes
  /// it (no accounts yet), in which case there is nothing honest to claim.
  final String? scopeAccountName;

  @override
  Widget build(BuildContext context) {
    return CalmFinancialSummary(
      label: scopeAccountName == null
          ? context.l10n.subsMonthlyTotal
          : context.l10n.subsMonthlyScoped(scopeAccountName!),
      amount: formatMoney(monthly),
      currency: currency,
      metrics: [
        CalmMetric(label: context.l10n.subsActiveSubs, value: '$subsCount'),
        CalmMetric(label: context.l10n.subsRunningInst, value: '$instsCount'),
        // The figure the header used to omit: what the installments actually
        // commit per month. Shown only when there is one, so the strip does not
        // carry a permanent «0.00».
        if (installmentMonthly.minorUnits > 0)
          CalmMetric(
            label: context.l10n.subsMonthlyInstCommit,
            value: formatMoney(installmentMonthly),
          ),
        CalmMetric(
          label: context.l10n.txnYearlyTotal,
          value: formatMoney(
            Money(monthly.minorUnits * 12, monthly.currency),
          ),
        ),
      ],
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return CalmHeaderAction(
      icon: AppLucideIcons.plus,
      primary: true,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
    );
  }
}

// ─── Subscriptions Tab ───────────────────────────────────────────────────────

class _SubscriptionsTab extends StatelessWidget {
  const _SubscriptionsTab({
    required this.meltStartAt,
    required this.bills,
    required this.suggestions,
    required this.baseCurrency,
  });

  /// Melt already consumed by the header, the ad band and the tab row.
  final double meltStartAt;

  final List<BillEntity> bills;
  final List<dynamic> suggestions;
  final String baseCurrency;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (bills.isEmpty && suggestions.isEmpty) {
      // The melt wraps the EMPTY state too. It used to return the bare card,
      // which skipped `MeltTail` entirely — so the blue stopped dead at the tab
      // row and the page below it started as flat canvas, with no fade at all.
      // An empty tab is exactly where that seam is most visible, because there
      // is no content to distract from it.
      return MeltTail(
        startAt: meltStartAt,
        child: _EmptyState(
          icon: AppLucideIcons.repeat,
          title: context.l10n.subsEmptyTitle,
          body: context.l10n.txnSubsEmptyBody,
          actionLabel: context.l10n.txnAddSub,
          onAction: () =>
              BillFormSheet.show(context, initialType: BillType.subscription),
        ),
      );
    }
    return MeltTail(
        startAt: meltStartAt,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter, AppSpacing.s3, AppSpacing.gutter, 120),
          children: [
            for (final bill in bills)
              _SubscriptionCard(bill: bill, baseCurrency: baseCurrency),
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.s4),
              Text(
                context.l10n.subsAutoDetected,
                style: AppTypography.caption(c.textLight)
                    .copyWith(letterSpacing: 1.4, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.s3),
              for (final item in suggestions)
                _SuggestionCard(item: item, baseCurrency: baseCurrency),
            ],
            const SizedBox(height: AppSpacing.s4),
            OutlinedButton.icon(
              onPressed: () => BillFormSheet.show(context,
                  initialType: BillType.subscription),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                side: BorderSide(color: c.border),
              ),
              icon: Icon(AppLucideIcons.plus, color: c.cta),
              label: Text(
                context.l10n.subsAddNewSub,
                style: AppTypography.bodyStrong(c.cta),
              ),
            ),
          ],
        ));
  }
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({required this.bill, required this.baseCurrency});
  final BillEntity bill;
  final String baseCurrency;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final statusColor = switch (bill.status) {
      BillStatus.active => c.success,
      BillStatus.paused => c.accent,
      BillStatus.cancelled => c.textLight,
    };
    final statusLabel = switch (bill.status) {
      BillStatus.active => context.l10n.txnActive,
      BillStatus.paused => context.l10n.txnPaused,
      BillStatus.cancelled => context.l10n.txnCancelled,
    };
    final freqLabel = switch (bill.frequency) {
      BillFrequency.weekly => context.l10n.txnCycleWeekly,
      BillFrequency.monthly => context.l10n.txnCycleMonthly,
      BillFrequency.yearly => context.l10n.txnCycleYearly,
      BillFrequency.custom => context.l10n.txnRangeCustom,
    };
    final daysLeft = bill.nextDueDate.difference(DateTime.now()).inDays;

    final Color dueColor;
    final String dueLabel;
    final IconData dueIcon;

    if (daysLeft < 0) {
      dueColor = c.danger;
      dueLabel = context.l10n.txnOverdueDays(daysLeft.abs());
      dueIcon = AppLucideIcons.alertTriangle;
    } else if (daysLeft == 0) {
      dueColor = c.danger;
      dueLabel = context.l10n.txnDueToday;
      dueIcon = AppLucideIcons.alertCircle;
    } else if (daysLeft <= 3) {
      dueColor = c.accent;
      dueLabel = context.l10n.txnInDays(daysLeft);
      dueIcon = AppLucideIcons.calendarClock;
    } else {
      dueColor = c.textLight;
      dueLabel = context.l10n.txnInDays(daysLeft);
      dueIcon = AppLucideIcons.calendarDays;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: MaliCard(
        style: MaliSurfaceStyle.floating,
        padding: const EdgeInsets.all(AppSpacing.s4),
        onTap: () => BillDetailsSheet.show(context, bill),
        child: Column(
          children: [
            Row(
              children: [
                AppAvatar.brand(name: bill.name),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              bill.name,
                              style: AppTypography.bodyStrong(c.textMain),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.10),
                              borderRadius:
                                  BorderRadius.circular(AppRadius.pill),
                              border: Border.all(
                                  color: statusColor.withValues(alpha: 0.20)),
                            ),
                            child: Text(
                              statusLabel,
                              style: AppTypography.caption(statusColor)
                                  .copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      if (bill.mightBeUnused) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(AppLucideIcons.info,
                                size: 12, color: c.warning),
                            const SizedBox(width: 3),
                            Text(
                              context.l10n.subsMaybeUnused,
                              style: AppTypography.caption(c.warning),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(dueIcon, size: 13, color: dueColor),
                          const SizedBox(width: 4),
                          Flexible(
                              child: Text(
                            '$freqLabel · $dueLabel',
                            style: AppTypography.caption(dueColor),
                          )),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatMoney(bill.amountMoney),
                      style: AppTypography.bodyStrong(c.textMain),
                    ),
                    Text(
                      Currency.label(context, bill.currency),
                      style: AppTypography.caption(c.textLight),
                    ),
                    if (bill.type == BillType.subscription)
                      Text(
                        context.l10n.subsPerYearApprox(
                            Formatters.amount(annualEquivalent(bill))),
                        style: AppTypography.caption(c.textLight),
                      ),
                  ],
                ),
              ],
            ),
            if (bill.safeManualPaidAmount > 0) ...[
              const SizedBox(height: AppSpacing.s3),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: c.success.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(
                    color: c.success.withValues(alpha: 0.28),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(AppLucideIcons.banknote, size: 16, color: c.success),
                    const SizedBox(width: 6),
                    Text(
                      context.l10n.txnPaidManuallyLabel,
                      style: AppTypography.caption(c.textLight),
                    ),
                    Text(
                      '${formatMoney(bill.safeManualPaidMoney)} ${Currency.label(context, bill.currency)}',
                      style: AppTypography.caption(c.success).copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.item, required this.baseCurrency});
  final dynamic item;
  final String baseCurrency;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: MaliCard(
        style: MaliSurfaceStyle.floating,
        padding: const EdgeInsets.all(AppSpacing.s4),
        onTap: () => BillFormSheet.show(
          context,
          initialType: BillType.subscription,
          initialName: item.name as String,
        ),
        child: Row(
          children: [
            AppAvatar.brand(name: item.name as String),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name as String,
                    style: AppTypography.bodyStrong(c.textMain),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    context.l10n
                        .txnRecurredMonths((item.monthsSeen as num).toInt()),
                    style: AppTypography.caption(c.textLight),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s3),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  context.l10n.txnEstPerMonth(
                      formatMoney(item.estimatedAmountMoney as Money),
                      Currency.label(context, baseCurrency)),
                  style: AppTypography.caption(c.textMain).copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: c.cta.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(AppLucideIcons.plus, size: 12, color: c.cta),
                      const SizedBox(width: 2),
                      Text(
                        context.l10n.txnAdd,
                        style: AppTypography.caption(c.cta)
                            .copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Installments Tab ────────────────────────────────────────────────────────

class _InstallmentsTab extends StatelessWidget {
  const _InstallmentsTab({required this.meltStartAt, required this.bills});

  /// Melt already consumed by the header, the ad band and the tab row.
  final double meltStartAt;
  final List<BillEntity> bills;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (bills.isEmpty) {
      // Same as the subscriptions tab: the melt has to wrap the empty state, or
      // the blue ends in a hard line under the tab row.
      return MeltTail(
        startAt: meltStartAt,
        child: _EmptyState(
          icon: AppLucideIcons.repeat,
          title: context.l10n.subsInstEmptyTitle,
          body: context.l10n.subsInstEmptyBody,
          actionLabel: context.l10n.txnAddInstalment,
          onAction: () =>
              BillFormSheet.show(context, initialType: BillType.installment),
        ),
      );
    }
    // One cross-bill display total, computed EXACTLY as Money and currency-
    // isolated: an installment in another currency is NEVER folded into this
    // total (no implicit FX). The double conversion happens only at the leaf
    // Text below.
    final displayCode = bills.first.amountMoney.currency;
    final totalRemainingMoney =
        installmentsRemainingTotalMoney(bills, displayCode);
    final activeCount = bills.where((b) => b.remainingInstallments > 0).length;
    final dueSoon = bills.where((b) => b.remainingInstallments > 0).toList()
      ..sort((a, b) => a.nextDueDate.compareTo(b.nextDueDate));
    final nearest = dueSoon.isEmpty ? null : dueSoon.first;
    final currency =
        bills.isEmpty ? 'SAR' : Currency.label(context, bills.first.currency);

    return MeltTail(
        startAt: meltStartAt,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter, AppSpacing.s3, AppSpacing.gutter, 120),
          children: [
            if (!totalRemainingMoney.isZero) ...[
              // كارت معلومات هادي (كان تدرّج أزرق قديم) — الرقم بالخط الأسود
              // على سطح عائم، زي باقي كروت النظام.
              MaliCard(
                style: MaliSurfaceStyle.floating,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.l10n.subsTotalInstDebt,
                        style: AppTypography.caption(c.textLight)),
                    const SizedBox(height: 4),
                    Text(
                      '${formatMoney(totalRemainingMoney)} $currency',
                      style: AppTypography.amountMedium(c.textMain),
                    ),
                    const SizedBox(height: AppSpacing.s3),
                    Wrap(
                      spacing: AppSpacing.s4,
                      runSpacing: AppSpacing.s2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _DebtStat(
                            label: context.l10n.subsRunningInst,
                            value: '$activeCount'),
                        if (nearest != null) ...[
                          _DebtStat(
                            label: context.l10n.subsNearestInst,
                            value:
                                '${formatMoney(nearest.amountMoney)} · ${_dueInLabel(context, nearest.nextDueDate)}',
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
            ],
            for (final bill in bills) _InstallmentCard(bill: bill),
            const SizedBox(height: AppSpacing.s4),
            OutlinedButton.icon(
              onPressed: () => BillFormSheet.show(context,
                  initialType: BillType.installment),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                side: BorderSide(color: c.border),
              ),
              icon: Icon(AppLucideIcons.plus, color: c.cta),
              label: Text(
                context.l10n.subsAddNewInst,
                style: AppTypography.bodyStrong(c.cta),
              ),
            ),
          ],
        ));
  }
}

class _DebtStat extends StatelessWidget {
  const _DebtStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: AppTypography.bodyStrong(c.textMain)
              .copyWith(fontWeight: FontWeight.w700),
        ),
        Text(
          label,
          style: AppTypography.caption(c.textLight),
        ),
      ],
    );
  }
}

class _InstallmentCard extends StatelessWidget {
  const _InstallmentCard({required this.bill});
  final BillEntity bill;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasProg =
        bill.totalInstallments != null && bill.totalInstallments! > 0;
    final progress = bill.installmentProgress;
    final remaining = bill.remainingInstallments;
    final daysLeft = bill.nextDueDate.difference(DateTime.now()).inDays;
    final currLabel = Currency.label(context, bill.currency);

    final Color dueColor;
    final String dueLabel;
    if (daysLeft < 0) {
      dueColor = c.danger;
      dueLabel = context.l10n.txnOverdueDays(daysLeft.abs());
    } else if (daysLeft == 0) {
      dueColor = c.danger;
      dueLabel = context.l10n.txnDueToday;
    } else if (daysLeft <= 3) {
      dueColor = c.accent;
      dueLabel = context.l10n.txnInDays(daysLeft);
    } else {
      dueColor = c.textLight;
      dueLabel = context.l10n.txnInDays(daysLeft);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: MaliCard(
        style: MaliSurfaceStyle.floating,
        padding: const EdgeInsets.all(AppSpacing.s4),
        onTap: () => BillDetailsSheet.show(context, bill),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppAvatar.brand(name: bill.lenderName ?? bill.name),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bill.name,
                        style: AppTypography.bodyStrong(c.textMain),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (bill.lenderName != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          bill.lenderName!,
                          style: AppTypography.caption(c.textLight),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.s2),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatMoney(bill.amountMoney),
                      style: AppTypography.bodyStrong(c.primary),
                    ),
                    Text(
                      context.l10n.txnPerInstalment(currLabel),
                      style: AppTypography.caption(c.textLight),
                    ),
                  ],
                ),
              ],
            ),
            if (hasProg) ...[
              const SizedBox(height: AppSpacing.s4),
              Row(
                children: [
                  Text(
                    context.l10n.txnPaidOfTotal(
                        bill.paidCount ?? 0, bill.totalInstallments ?? 0),
                    style: AppTypography.caption(c.textLight),
                  ),
                  const Spacer(),
                  Text(
                    context.l10n.txnRemainingInstalments(remaining),
                    style: AppTypography.caption(c.primary)
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: SizedBox(
                  height: 6,
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor: c.surface2,
                    valueColor: AlwaysStoppedAnimation(
                      progress >= 1.0 ? c.success : c.primary,
                    ),
                  ),
                ),
              ),
            ],
            if (bill.totalPurchaseAmount != null) ...[
              const SizedBox(height: AppSpacing.s3),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: c.bg,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  children: [
                    Text(
                      context.l10n.txnTotalValueLabel,
                      style: AppTypography.caption(c.textLight),
                    ),
                    Text(
                      '${formatMoney(bill.totalPurchaseMoney!)} $currLabel',
                      style: AppTypography.caption(c.textMain).copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (bill.interestRate != null) ...[
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: c.accent.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Text(
                          context.l10n.txnInterestRate(
                              (bill.interestRate! * 100).toStringAsFixed(1)),
                          style: AppTypography.caption(c.accent)
                              .copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            if (bill.safeManualPaidAmount > 0) ...[
              const SizedBox(height: AppSpacing.s3),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: c.success.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(
                    color: c.success.withValues(alpha: 0.28),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(AppLucideIcons.banknote, size: 16, color: c.success),
                    const SizedBox(width: 6),
                    Text(
                      context.l10n.txnPaidManuallyLabel,
                      style: AppTypography.caption(c.textLight),
                    ),
                    Text(
                      '${formatMoney(bill.safeManualPaidMoney)} $currLabel',
                      style: AppTypography.caption(c.success).copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.s3),
            Row(
              children: [
                Icon(AppLucideIcons.calendarDays, size: 14, color: dueColor),
                const SizedBox(width: 4),
                Text(
                  context.l10n.txnNextInstalment(dueLabel),
                  style: AppTypography.caption(dueColor).copyWith(
                      fontWeight:
                          dueColor == c.danger ? FontWeight.bold : null),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Empty State ─────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.gutter,
            vertical: AppSpacing.s4,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const QirshIllustration(name: 'bills', width: 220, height: 165),
              const SizedBox(height: AppSpacing.s4),
              Text(title,
                  textAlign: TextAlign.center,
                  style: AppTypography.cardTitle(c.textMain)),
              const SizedBox(height: AppSpacing.s2),
              Text(body,
                  textAlign: TextAlign.center,
                  style: AppTypography.callout(c.textLight)),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: AppSpacing.s4),
                SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: onAction,
                    icon: const Icon(AppLucideIcons.plus),
                    label: Text(actionLabel!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
