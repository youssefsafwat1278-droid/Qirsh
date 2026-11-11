import 'package:flutter/material.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/mali_tokens.dart';
import '../../../core/theme/widgets/mali_card.dart';
import '../../../domain/entities/report_models.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/finance/daily_allowance.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/finance/money_format.dart';
import '../../cards/brand_mark.dart';
import '../../common/app_avatar.dart';
import '../../common/app_status_pill.dart';
import '../../common/category_catalog.dart';
import '../../common/transaction_direction.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/theme/widgets/ring_progress.dart';
import '../../../core/utils/app_lucide_icons.dart';
import 'home_v2_style.dart';

/// Home's «المصروفات اليومية» card.
///
/// Answers three questions in one surface: what did I spend today, how does
/// that sit against my own week, and **how much can I still spend today**.
/// The last one is the number the user acts on and did not exist anywhere in
/// the app before.
///
/// Presentation only — every figure arrives pre-computed from
/// `dashboardDataProvider`; nothing here aggregates transactions.
///
/// On the seven bars and the Home/Reports split: these are seven fixed slots
/// with no axis, legend, tooltip or gesture — context for one number, not
/// analytics. Reports keeps the chart library and every interactive chart; see
/// `test/features/dashboard/no_charts_on_home_test.dart`, which encodes exactly
/// that boundary.
class DailySpendCard extends StatelessWidget {
  const DailySpendCard({
    super.key,
    required this.todaySpend,
    required this.lastSevenDays,
    required this.averageSevenDays,
    required this.availableToday,
    this.dailyBudgetLimit,
    required this.todayVsYesterday,
    required this.todayTransactions,
    required this.todayIsTruncated,
    required this.catalog,
    required this.currencyLabel,
    required this.privacyMode,
    this.merchantLogos = const <String, String>{},
    this.onTransactionTap,
  });

  final Money todaySpend;

  /// Exactly seven slots, oldest → today (see [normalizeLastSevenDays]).
  final List<DailySpend> lastSevenDays;
  final Money averageSevenDays;

  /// Null when no monthly budget is set — rendered as «—» plus a prompt, never
  /// as a zero that would read as "nothing left".
  final Money? availableToday;
  final Money? dailyBudgetLimit;

  /// Null when yesterday had no spend: a percentage against zero is not a
  /// comparison, so the chip is omitted rather than showing «+100%».
  final double? todayVsYesterday;

  final List<TransactionEntity> todayTransactions;

  /// True when today's rows came off a truncated read — the count is then
  /// rendered as «+N», never as an exact number.
  final bool todayIsTruncated;

  final CategoryCatalog catalog;
  final String currencyLabel;
  final bool privacyMode;
  final Map<String, String> merchantLogos;
  final void Function(TransactionEntity tx)? onTransactionTap;

  static const int _topCount = 3;

  /// The [_topCount] largest **debits** today, biggest first.
  ///
  /// Direction comes from [transactionIsDebit], not from the sign of `amount`:
  /// `amount` is a magnitude and is positive for income too, so filtering on it
  /// would list the salary as one of the day's biggest expenses.
  List<TransactionEntity> get _top {
    final debits = todayTransactions.where(transactionIsDebit).toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
    return debits.take(_topCount).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final top = _top;

    return MaliCard(
      style: MaliSurfaceStyle.floating,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _headline(context, t),
          const SizedBox(height: AppSpacing.s5),
          RepaintBoundary(
            child: _SevenDayBars(
                days: lastSevenDays,
                average: averageSevenDays,
                privacyMode: privacyMode),
          ),
          const SizedBox(height: AppSpacing.s4),
          _metrics(context, t),
          if (top.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s3),
            Divider(height: 1, color: HomeV2.hairline(context)),
            const SizedBox(height: AppSpacing.s3),
            _topHeader(context, t),
            for (final tx in top) _topRow(context, t, tx),
          ],
        ],
      ),
    );
  }

  /// Spent ÷ today's allowance. The daily budget when one is set; with none
  /// (null or zero), what was spent against spent + still available (spec
  /// «05» item 6 — the ring used to sit empty without a daily budget). Null
  /// — a muted ring, never a guessed arc — when neither is in today's
  /// currency, and always under privacy.
  double? get _ringValue {
    if (privacyMode) return null;
    final limit = dailyBudgetLimit;
    if (limit != null &&
        limit.currency == todaySpend.currency &&
        limit.minorUnits > 0) {
      return todaySpend.minorUnits / limit.minorUnits;
    }
    // A positive daily budget in another currency is incompatible: no arc.
    if (limit != null && limit.minorUnits > 0) return null;
    final available = availableToday;
    if (available != null &&
        available.currency == todaySpend.currency &&
        !todaySpend.isNegative &&
        !available.isNegative) {
      final whole = todaySpend.minorUnits + available.minorUnits;
      if (whole > 0) return todaySpend.minorUnits / whole;
    }
    return null;
  }

  // ── «صرفت اليوم» + مقارنة بأمس ──────────────────────────────────────────

  Widget _headline(BuildContext context, MaliTokens t) {
    final c = context.colors;
    final dark = HomeV2.isDark(context);
    final ratio = todayVsYesterday;
    final ring = _ringValue;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(context.l10n.homeSpentToday,
                  style: AppTypography.caption(t.textOnCanvasMuted)),
              const SizedBox(height: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        privacyMode ? '••••' : formatMoney(todaySpend),
                        maxLines: 1,
                        style: AppTypography.amountLarge(t.textOnCanvasPrimary),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(currencyLabel,
                      style: AppTypography.caption(t.textOnCanvasMuted)),
                ],
              ),
              if (ratio != null) ...[
                const SizedBox(height: 8),
                _DeltaChip(ratio: ratio),
              ],
            ],
          ),
        ),
        if (availableToday != null) ...[
          const SizedBox(width: AppSpacing.s3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 136),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RingProgress(
                  key: const ValueKey('today-budget-ring'),
                  size: 72,
                  strokeWidth: 8,
                  // v2: arc = action text (dark) / action fill (light).
                  color: dark ? c.actionText : c.cta,
                  trackColor: HomeV2.track(context),
                  value: ring,
                  child: ring == null
                      ? null
                      : Text('${(ring * 100).round().clamp(0, 999)}%',
                          maxLines: 1,
                          style: AppTypography.label(t.textOnCanvasPrimary)),
                ),
                const SizedBox(height: 6),
                Text(context.l10n.homeAvailableToday,
                    textAlign: TextAlign.center,
                    style: AppTypography.caption(t.textOnCanvasMuted)),
                FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                        privacyMode ? '••••' : formatMoney(availableToday!),
                        maxLines: 1,
                        style:
                            AppTypography.amountSmall(t.textOnCanvasPrimary))),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // ── المقاييس ──────────────────────────────────────────────────────────────

  /// v2 `QStat`s: no box, separated by one vertical hairline.
  Widget _metrics(BuildContext context, MaliTokens t) {
    // The count is exact only when the read was not truncated.
    final countLabel = todayIsTruncated
        ? '+${todayTransactions.length}'
        : '${todayTransactions.length}';
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _metric(
            context,
            t,
            value: privacyMode ? '••••' : formatMoney(averageSevenDays),
            label: context.l10n.homeSevenDayAverage,
          ),
          Container(width: 1, color: HomeV2.hairline(context)),
          _metric(context, t,
              value: countLabel, label: context.l10n.homeTodayTransactions),
        ],
      ),
    );
  }

  Widget _metric(
    BuildContext context,
    MaliTokens t, {
    required String value,
    required String label,
  }) =>
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  maxLines: 1,
                  style: AppTypography.amountMedium(t.textOnCanvasPrimary),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: AppTypography.caption(t.textOnCanvasMuted),
              ),
            ),
          ],
        ),
      );

  // ── أعلى ٣ اليوم ─────────────────────────────────────────────────────────

  Widget _topHeader(BuildContext context, MaliTokens t) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.s1),
        child: Row(
          children: [
            Expanded(
              child: Text(context.l10n.homeTopThreeToday,
                  style: AppTypography.caption(t.textOnCanvasMuted)),
            ),
            Text(
              privacyMode
                  ? '•••• $currencyLabel'
                  : '${formatMoney(todaySpend)} $currencyLabel',
              style: AppTypography.caption(t.textOnCanvasMuted),
            ),
          ],
        ),
      );

  Widget _topRow(BuildContext context, MaliTokens t, TransactionEntity tx) {
    final category = catalog.byId(tx.categoryId);
    final title =
        tx.rawMerchant ?? category?.name ?? context.l10n.txnTransactionWord;
    final logo = BrandMark.logoFor(title, merchantLogos);
    final categoryTile = AppAvatar.category(
        iconName: category?.iconName,
        merchantName: title,
        color: category?.color,
        size: AppSpacing.avatarSm);
    return Semantics(
      button: onTransactionTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTransactionTap == null ? null : () => onTransactionTap!(tx),
        child: ConstrainedBox(
          // v2 compact row: 52pt.
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                (logo != null || BrandMark.hasBrand(title))
                    ? AppAvatar.brand(
                        name: title,
                        logoUrl: logo,
                        size: AppSpacing.avatarSm,
                        fallback: categoryTile)
                    : categoryTile,
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.subhead(t.textOnCanvasPrimary),
                      ),
                      Text(
                        category?.name ?? context.l10n.homeUncategorised,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption(t.textOnCanvasMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                Text(
                  // v2 money rule: an expense is neutral with a leading "−".
                  privacyMode
                      ? '••••'
                      : '−${formatMoney(Money(tx.amountMoney.minorUnits.abs(), tx.amountMoney.currency))}',
                  textDirection: TextDirection.ltr,
                  style: AppTypography.amountSmall(t.textOnCanvasPrimary)
                      .copyWith(fontSize: 15),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Seven fixed slots. One de-emphasised colour for the week, the action blue
/// for today — the days are ONE series, so colouring each of them separately
/// would burn the only free channel on information the bar heights already
/// carry. A dashed line marks the seven-day average.
///
/// v2 `m.chart`: bars rise from the baseline with a 30ms leading→trailing
/// stagger, then the average line draws in. Reduce Motion renders the chart
/// complete.
class _SevenDayBars extends StatelessWidget {
  const _SevenDayBars({
    required this.days,
    required this.average,
    required this.privacyMode,
  });

  final List<DailySpend> days;
  final Money average;
  final bool privacyMode;

  static const double _plotHeight = 76;
  static const double _minHeight = 3;
  static const int _barMs = 800;
  static const int _staggerMs = 30;
  static const int _lineMs = 400;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final c = context.colors;
    // Scale on the largest MAGNITUDE so a refund day (negative) still renders
    // a proportional bar instead of collapsing the whole chart.
    var peak = 0;
    for (final d in days) {
      final v = d.total.minorUnits.abs();
      if (v > peak) peak = v;
    }
    final avg = average.minorUnits.abs();
    final avgRatio =
        peak <= 0 || avg <= 0 ? null : (avg / peak).clamp(0.0, 1.0);
    final barsMs = _barMs + _staggerMs * (days.length - 1);
    final totalMs = barsMs + (avgRatio == null ? 0 : _lineMs);
    final animate = HomeV2.chart(context) != Duration.zero;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: animate ? 0 : 1, end: 1),
      duration: Duration(milliseconds: animate ? totalMs : 0),
      builder: (context, p, _) {
        double barProgress(int i) {
          final start = i * _staggerMs / totalMs;
          final end = (i * _staggerMs + _barMs) / totalMs;
          return AppMotion.springSmoothCurve
              .transform(((p - start) / (end - start)).clamp(0.0, 1.0));
        }

        final lineProgress = avgRatio == null
            ? 0.0
            : AppMotion.easeOut.transform(
                ((p * totalMs - barsMs) / _lineMs).clamp(0.0, 1.0));
        final lineY = avgRatio == null
            ? 0.0
            : _minHeight + (_plotHeight - _minHeight) * avgRatio;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: _plotHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (var i = 0; i < days.length; i++) ...[
                          if (i > 0) const SizedBox(width: 8),
                          Expanded(
                            child: _bar(
                              context,
                              day: days[i],
                              isToday: i == days.length - 1,
                              peak: peak,
                              progress: barProgress(i),
                              accent: c.cta,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (avgRatio != null && lineProgress > 0) ...[
                    PositionedDirectional(
                      start: 0,
                      end: 0,
                      bottom: lineY - 0.75,
                      child: Opacity(
                        opacity: 0.8,
                        child: HomeDashedLine(
                            color: t.textOnCanvasMuted,
                            progress: lineProgress),
                      ),
                    ),
                    PositionedDirectional(
                      end: 0,
                      bottom: avgRatio > 0.72 ? lineY - 20 : lineY + 4,
                      child: ExcludeSemantics(
                        child: Opacity(
                          opacity: lineProgress,
                          child: Container(
                            color: c.surface,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              '${context.l10n.homeSevenDayAverage} ${privacyMode ? '••••' : formatMoney(average)}',
                              maxLines: 1,
                              style: AppTypography.overline(
                                  t.textOnCanvasMuted),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 6),
            // The weekday letters; each bar already announces its day.
            ExcludeSemantics(
              child: Row(
                children: [
                  for (var i = 0; i < days.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        i == days.length - 1
                            ? context.l10n.txnRangeToday
                            : Formatters.weekdayInitial(context, days[i].day),
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.visible,
                        softWrap: false,
                        style: AppTypography.overline(i == days.length - 1
                            ? t.textOnCanvasPrimary
                            : t.textOnCanvasMuted),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _bar(
    BuildContext context, {
    required DailySpend day,
    required bool isToday,
    required int peak,
    required double progress,
    required Color accent,
  }) {
    final magnitude = day.total.minorUnits.abs();
    final height = peak <= 0
        ? _minHeight
        : (_minHeight + (_plotHeight - _minHeight) * (magnitude / peak))
            .clamp(_minHeight, _plotHeight)
            .toDouble();
    final label = isToday
        ? context.l10n.txnRangeToday
        : Formatters.weekdayInitial(context, day.day);
    return Semantics(
      label: context.l10n.homeDayAmountSemantics(
          label, privacyMode ? '••••' : formatMoney(day.total)),
      excludeSemantics: true,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          height: (height * progress).clamp(0.0, _plotHeight),
          constraints: const BoxConstraints(maxWidth: 28),
          decoration: BoxDecoration(
            color: isToday ? accent : HomeV2.chartOff(context),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }
}

class _DeltaChip extends StatelessWidget {
  const _DeltaChip({required this.ratio});

  final double ratio;

  @override
  Widget build(BuildContext context) {
    final pct = (ratio.abs() * 100).round();
    // Cap the label so an unusual spike cannot break the row's layout.
    final text = pct > 999 ? '+999%' : '${ratio > 0 ? '+' : '−'}$pct%';
    // v2 QStatusChip: spending less is success; more is a warning, never red
    // (red is reserved for over budget).
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: AppStatusPill(
          label: context.l10n.homeVsYesterdayValue(text),
          tone: ratio > 0 ? AppStatusTone.warning : AppStatusTone.success,
          icon: ratio > 0
              ? AppLucideIcons.trendingUp
              : AppLucideIcons.trendingDown,
          compact: true,
        ),
      ),
    );
  }
}
