import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/widgets/glass_sheet.dart';
import '../../../core/theme/widgets/mali_card.dart';
import '../../../core/theme/widgets/navy_sheet_theme.dart';
import '../../../core/theme/widgets/qirsh_visuals.dart';
import '../../../core/utils/app_lucide_icons.dart';
import '../../../core/utils/currency.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../domain/entities/bill_entity.dart';
import '../../../domain/finance/bill_metrics.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/finance/money_format.dart';
import '../../common/app_avatar.dart';
import '../../common/app_button.dart';
import '../../common/app_empty_state.dart';
import '../../common/motion.dart';
import '../../common/qirsh_summary_card.dart';
import '../../transactions/transactions_providers.dart' show BillSuggestion;
import '../../transactions/widgets/account_scope_sheet.dart';
import '../../transactions/widgets/activity_chip.dart';
import '../bill_details_sheet.dart';
import '../bill_form_sheet.dart';

/// The ONE bills body, shared by the Activity «الفواتير» tab and the pushed
/// «الفواتير والاشتراكات» page: summary card (currency as its scope chip),
/// Subscriptions / Instalments chips, «Needs attention» (overdue only) and
/// «Upcoming» (everything else, once each), then help and add.
///
/// Presentation only — callers pass the bills they already loaded and the
/// canonical subscription total they already computed.
class BillsOverview extends ConsumerStatefulWidget {
  const BillsOverview({
    super.key,
    required this.bills,
    required this.suggestions,
    required this.baseCurrency,
    required this.subscriptionsMonthly,
    required this.subscriptionsLabel,
    required this.instalmentsMonthly,
    this.subscriptionsExtraStat,
    this.afterSummary,
  });

  final List<BillEntity> bills;
  final List<BillSuggestion> suggestions;
  final String baseCurrency;

  /// MALI-064n — the canonical monthly subscription metric, exact Money.
  final Money subscriptionsMonthly;

  /// UX-023/024 — the subscriptions caption (names the scoped account).
  final String subscriptionsLabel;

  /// UX-023 — the instalment obligation per month (ACTIVE instalments only),
  /// exact Money; the summary amount in Instalments mode.
  final Money instalmentsMonthly;

  /// UX-023 — an extra stat on the Subscriptions summary (the monthly
  /// instalment commitment, when there is one).
  final QirshSummaryStat? subscriptionsExtraStat;

  /// Optional slot right under the summary (the pushed page's ad banner).
  final Widget? afterSummary;

  @override
  ConsumerState<BillsOverview> createState() => _BillsOverviewState();
}

class _BillsOverviewState extends ConsumerState<BillsOverview> {
  BillType _type = BillType.subscription;

  @override
  Widget build(BuildContext context) {
    final subs = widget.bills
        .where((b) => b.type == BillType.subscription)
        .toList(growable: false);
    final insts = widget.bills
        .where((b) => b.type == BillType.installment)
        .toList(growable: false);
    final isSubs = _type == BillType.subscription;
    final items = isSubs ? subs : insts;
    final suggestions = isSubs ? widget.suggestions : const <BillSuggestion>[];

    // Overdue items are listed ONCE, under «Needs attention»; everything else
    // once, under «Upcoming» (active first, then by due date).
    final overdue = items.where(_isOverdue).toList(growable: false)
      ..sort((a, b) => a.nextDueDate.compareTo(b.nextDueDate));
    final upcoming = items.where((b) => !_isOverdue(b)).toList(growable: false)
      ..sort((a, b) {
        final active = (a.status == BillStatus.active ? 0 : 1)
            .compareTo(b.status == BillStatus.active ? 0 : 1);
        if (active != 0) return active;
        final due = a.nextDueDate.compareTo(b.nextDueDate);
        return due != 0 ? due : a.id.compareTo(b.id);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _summary(context, items),
        if (widget.afterSummary != null) widget.afterSummary!,
        const SizedBox(height: AppSpacing.s3),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ActivityChip(
              label: context.l10n.txnBillsSubs,
              count: subs.length,
              selected: isSubs,
              onTap: () => setState(() => _type = BillType.subscription),
            ),
            ActivityChip(
              label: context.l10n.txnBillsInstalments,
              count: insts.length,
              selected: !isSubs,
              onTap: () => setState(() => _type = BillType.installment),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s2),
        if (items.isEmpty && suggestions.isEmpty)
          AppEmptyState(
            illustration:
                const QirshIllustration(name: 'bills', width: 210, height: 158),
            icon: isSubs ? AppLucideIcons.repeat : AppLucideIcons.receipt,
            title: isSubs
                ? context.l10n.txnSubsEmptyTitle
                : context.l10n.txnInstEmptyTitle,
            subtitle: isSubs
                ? context.l10n.txnSubsEmptyBody
                : context.l10n.txnInstEmptyBody,
            primaryLabel:
                isSubs ? context.l10n.txnAddSub : context.l10n.txnAddInstalment,
            onPrimary: () => BillFormSheet.show(context, initialType: _type),
          ),
        if (overdue.isNotEmpty) ...[
          _SectionLabel(context.l10n.syncSheetNeedsAttention),
          PremiumMotion(
            child: _BillGroup(alert: true, children: [
              for (final bill in overdue)
                _BillRow(bill: bill, baseCurrency: widget.baseCurrency),
            ]),
          ),
        ],
        if (upcoming.isNotEmpty) ...[
          _SectionLabel(context.l10n.subsV2Upcoming),
          PremiumMotion(
            delay: AppMotion.stagger,
            child: _BillGroup(children: [
              for (final bill in upcoming)
                _BillRow(bill: bill, baseCurrency: widget.baseCurrency),
            ]),
          ),
        ],
        if (suggestions.isNotEmpty) ...[
          _SectionLabel(context.l10n.txnSuggestionsTitle),
          _BillGroup(children: [
            for (final suggestion in suggestions)
              _SuggestionRow(
                suggestion: suggestion,
                currencyLabel: Currency.label(context, widget.baseCurrency),
              ),
          ]),
        ],
        const SizedBox(height: AppSpacing.s3),
        TextButton.icon(
          onPressed: () => _showBillsHelp(context, _type),
          icon: const Icon(AppLucideIcons.helpCircle, size: 18),
          label: Text(context.l10n.txnLearnBills),
        ),
        if (items.isNotEmpty || suggestions.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s2),
          AppSecondaryButton(
            onTap: () => BillFormSheet.show(context, initialType: _type),
            icon: AppLucideIcons.plus,
            label: isSubs
                ? context.l10n.subsAddNewSub
                : context.l10n.subsAddNewInst,
          ),
        ],
      ],
    );
  }

  Widget _summary(BuildContext context, List<BillEntity> items) {
    final base = widget.baseCurrency;
    final currencyLabel = Currency.label(context, base);
    final isSubs = _type == BillType.subscription;
    // F-027 — the base currency is explicit (never `bills.first`); both
    // totals are computed by the host from ACTIVE bills only.
    final monthly =
        isSubs ? widget.subscriptionsMonthly : widget.instalmentsMonthly;
    final activeCount =
        items.where((b) => b.status == BillStatus.active).length;
    final now = DateTime.now();
    final weekEnd = now.add(const Duration(days: 7));
    final nextThisWeek = items
        .where((b) =>
            !b.nextDueDate.isBefore(now) && b.nextDueDate.isBefore(weekEnd))
        .length;
    final debt = isSubs
        ? null
        : installmentsRemainingTotalMoney(
            items.where((b) => b.remainingInstallments > 0), base);

    // The currency is the card's scope: a chip, and only when there is more
    // than one account to switch between (it opens the same account picker).
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const [];
    final selectedId = ref.watch(activeAccountIdProvider);
    String? scopeLabel;
    VoidCallback? onScopeTap;
    if (accounts.length > 1) {
      final fallback =
          accounts.firstWhere((a) => a.isDefault, orElse: () => accounts.first);
      final account = accounts.firstWhere((a) => a.id == selectedId,
          orElse: () => fallback);
      final accountCurrency = Currency.label(context, account.currency);
      final currencies =
          accounts.map((a) => a.currency.toUpperCase()).toSet().length;
      scopeLabel = currencies == accounts.length
          ? accountCurrency
          : '${account.name} · $accountCurrency';
      onScopeTap = () => showAccountScopeSheet(context, ref, account.id);
    }

    return QirshSummaryCard(
      label:
          isSubs ? widget.subscriptionsLabel : context.l10n.txnTotalMonthlyInst,
      scopeLabel: scopeLabel,
      onScopeTap: onScopeTap,
      amount: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: Text(
          '${formatMoney(monthly)} $currencyLabel',
          maxLines: 1,
        ),
      ),
      stats: [
        QirshSummaryStat(
            value: Text('$activeCount'), label: context.l10n.txnActive),
        QirshSummaryStat(
          value:
              Text('${formatMoney(monthly * 12)} $currencyLabel', maxLines: 1),
          label: context.l10n.txnPerYear,
        ),
        if (isSubs) ...[
          QirshSummaryStat(
              value: Text('$nextThisWeek'),
              label: context.l10n.txnRangeThisWeek),
          if (widget.subscriptionsExtraStat != null)
            widget.subscriptionsExtraStat!,
        ] else if (debt != null && !debt.isZero)
          QirshSummaryStat(
            value: Text('${formatMoney(debt)} $currencyLabel', maxLines: 1),
            label: context.l10n.subsTotalInstDebt,
          ),
      ],
    );
  }

  void _showBillsHelp(BuildContext context, BillType type) {
    final c = context.colors;
    showGlassSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => navySheetTheme(Directionality(
        textDirection: Directionality.of(context),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                type == BillType.subscription
                    ? context.l10n.txnHowSubsTitle
                    : context.l10n.txnHowInstTitle,
                style: AppTypography.cardTitle(c.textMain),
              ),
              const SizedBox(height: AppSpacing.s3),
              Text(
                type == BillType.subscription
                    ? context.l10n.txnHowSubsBody
                    : context.l10n.txnHowInstBody,
                style: AppTypography.callout(c.textLight),
              ),
              const SizedBox(height: AppSpacing.s4),
            ],
          ),
        ),
      )),
    );
  }
}

int _daysUntil(DateTime due) => due.difference(DateTime.now()).inDays;

bool _isOverdue(BillEntity bill) =>
    bill.status == BillStatus.active && _daysUntil(bill.nextDueDate) < 0;

/// Share of the current renewal cycle already elapsed (last renewal → next
/// due), from the dates the bill already carries. Null when there is no
/// meaningful cycle to show.
double? _cycleProgress(BillEntity bill) {
  if (bill.type != BillType.subscription || bill.status != BillStatus.active) {
    return null;
  }
  final next = bill.nextDueDate;
  final DateTime last = switch (bill.frequency) {
    BillFrequency.weekly => next.subtract(const Duration(days: 7)),
    BillFrequency.monthly =>
      DateTime(next.year, next.month - 1, next.day, next.hour, next.minute),
    BillFrequency.yearly =>
      DateTime(next.year - 1, next.month, next.day, next.hour, next.minute),
    BillFrequency.custom =>
      next.subtract(Duration(days: bill.customIntervalDays ?? 30)),
  };
  final span = next.difference(last).inMinutes;
  if (span <= 0) return null;
  final elapsed = DateTime.now().difference(last).inMinutes;
  return (elapsed / span).clamp(0.0, 1.0);
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.only(
            start: 4, top: AppSpacing.s3, bottom: AppSpacing.s2),
        child: Text(text,
            style: AppTypography.subhead(context.colors.textPrimary)
                .copyWith(fontWeight: FontWeight.w600)),
      );
}

/// One card holding rows separated by inset hairlines — never one card per
/// row. [alert] = the «Needs attention» card: a subtle danger tint + border.
class _BillGroup extends StatelessWidget {
  const _BillGroup({required this.children, this.alert = false});
  final List<Widget> children;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final rows = <Widget>[
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 66),
            child: Divider(height: 1, thickness: .5, color: c.divider),
          ),
        children[i],
      ],
    ];
    if (!alert) {
      return MaliCard(
        style: MaliSurfaceStyle.floating,
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Column(children: rows),
        ),
      );
    }
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color:
            Color.alphaBlend(c.danger.withValues(alpha: 0.07), c.surfaceCard),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.danger.withValues(alpha: 0.35)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(children: rows),
      ),
    );
  }
}

/// v3 bill row: logo tile · name · «status · cadence» coloured by state ·
/// thin cycle bar; amount and «≈ X/yr» on the trailing side. Normal (active)
/// bills carry no badge — only paused / ended say so, in text.
class _BillRow extends StatelessWidget {
  const _BillRow({required this.bill, required this.baseCurrency});
  final BillEntity bill;
  final String baseCurrency;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isSub = bill.type == BillType.subscription;
    final isActive = bill.status == BillStatus.active;
    final daysLeft = _daysUntil(bill.nextDueDate);
    final currLabel = Currency.label(context, bill.currency);

    final String stateLabel;
    final Color stateColor;
    if (!isActive) {
      stateLabel = bill.status == BillStatus.paused
          ? context.l10n.txnPaused
          : context.l10n.txnCancelled;
      stateColor = c.textSecondary;
    } else if (daysLeft < 0) {
      stateLabel = context.l10n.txnOverdueDays(daysLeft.abs());
      stateColor = c.danger;
    } else if (daysLeft <= 3) {
      stateLabel = daysLeft == 0
          ? context.l10n.txnDueToday
          : context.l10n.txnInDays(daysLeft);
      stateColor = c.warningText;
    } else {
      stateLabel = context.l10n.txnInDays(daysLeft);
      stateColor = c.textSecondary;
    }
    final freqLabel = switch (bill.frequency) {
      BillFrequency.weekly => context.l10n.txnCycleWeekly,
      BillFrequency.monthly => context.l10n.txnCycleMonthly,
      BillFrequency.yearly => context.l10n.txnCycleYearly,
      BillFrequency.custom => context.l10n.txnRangeCustom,
    };
    final hasProg =
        !isSub && bill.totalInstallments != null && bill.totalInstallments! > 0;
    final cadence = hasProg
        ? context.l10n
            .txnPaidOfTotal(bill.paidCount ?? 0, bill.totalInstallments ?? 0)
        : freqLabel;

    final double? progress = isSub
        ? _cycleProgress(bill)
        : (hasProg ? bill.installmentProgress : null);
    final Color barColor = !isSub
        ? (progress != null && progress >= 1.0 ? c.success : c.cta)
        : stateColor == c.textSecondary
            ? c.cta
            : (stateColor == c.warningText ? c.warning : stateColor);

    return InkWell(
      onTap: () => BillDetailsSheet.show(context, bill),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AppAvatar.brand(
                    name: isSub ? bill.name : (bill.lenderName ?? bill.name),
                    size: 40),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bill.name,
                        style: AppTypography.bodyStrong(c.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$stateLabel · $cadence',
                        // Wraps rather than clipping when a long exact
                        // amount narrows the row.
                        style: AppTypography.caption(stateColor),
                      ),
                      if (bill.mightBeUnused) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(AppLucideIcons.info,
                                size: 13, color: c.warning),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                context.l10n.subsMaybeUnused,
                                style: AppTypography.caption(c.warningText),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (progress != null) ...[
                        const SizedBox(height: 6),
                        _ThinBar(value: progress, color: barColor),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatMoney(bill.amountMoney),
                      textDirection: TextDirection.ltr,
                      style: AppTypography.bodyStrong(c.textPrimary),
                    ),
                    if (!isSub)
                      Text(
                        context.l10n.txnPerInstalment(currLabel),
                        style: AppTypography.caption(c.textSecondary),
                      )
                    else ...[
                      // The currency only when it differs from the base one.
                      if (bill.currency.toUpperCase() !=
                          baseCurrency.toUpperCase())
                        Text(currLabel,
                            style: AppTypography.caption(c.textSecondary)),
                      Text(
                        context.l10n.subsPerYearApprox(
                            formatMoney(annualEquivalentMoney(bill))),
                        style: AppTypography.caption(c.textSecondary),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            if (!isSub && bill.totalPurchaseAmount != null)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 52, top: 8),
                // Wrap, not Row: a long exact amount moves whole to the next
                // line instead of overflowing.
                child: Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      context.l10n.txnTotalValueLabel,
                      style: AppTypography.caption(c.textSecondary),
                    ),
                    Text(
                      '${formatMoney(bill.totalPurchaseMoney!)} $currLabel',
                      style: AppTypography.caption(c.textPrimary)
                          .copyWith(fontWeight: FontWeight.bold),
                    ),
                    if (bill.interestRate != null) ...[
                      Text(
                        context.l10n.txnInterestRate(
                            (bill.interestRate! * 100).toStringAsFixed(1)),
                        style: AppTypography.caption(c.accent)
                            .copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ],
                ),
              ),
            if (bill.safeManualPaidAmount > 0)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 52, top: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Icon(AppLucideIcons.banknote, size: 15, color: c.success),
                    Text(
                      context.l10n.txnPaidManuallyLabel,
                      style: AppTypography.caption(c.textSecondary),
                    ),
                    Text(
                      '${formatMoney(bill.safeManualPaidMoney)} $currLabel',
                      style: AppTypography.caption(c.success)
                          .copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 3pt progress line (renewal cycle / instalments paid). Draws in once;
/// decorative, so excluded from semantics.
class _ThinBar extends StatelessWidget {
  const _ThinBar({required this.value, required this.color});
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final track =
        isDark ? Colors.white.withValues(alpha: 0.12) : c.surfaceMuted;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: SizedBox(
          height: 3,
          child: ColoredBox(
            color: track,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: value),
              duration: shouldReduceMotion(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 600),
              curve: AppMotion.easeOut,
              builder: (context, v, _) => FractionallySizedBox(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: v,
                child: ColoredBox(color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.suggestion, required this.currencyLabel});
  final BillSuggestion suggestion;
  final String currencyLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: () => BillFormSheet.show(
        context,
        initialType: BillType.subscription,
        initialName: suggestion.name,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            AppAvatar.brand(name: suggestion.name, size: 40),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    suggestion.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyStrong(c.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    context.l10n.txnRecurredMonths(suggestion.monthsSeen),
                    style: AppTypography.caption(c.textSecondary),
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
                      formatMoney(suggestion.estimatedAmountMoney),
                      currencyLabel),
                  style: AppTypography.caption(c.textPrimary)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: c.ctaSoft,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(AppLucideIcons.plus, size: 12, color: c.actionText),
                      const SizedBox(width: 2),
                      Text(
                        context.l10n.txnAdd,
                        style: AppTypography.overline(c.actionText),
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
