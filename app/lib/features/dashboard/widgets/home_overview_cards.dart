import 'package:flutter/material.dart';
import '../../../core/theme/widgets/qirsh_visuals.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/mali_tokens.dart';
import '../../../core/theme/widgets/mali_card.dart';
import '../../../core/utils/app_lucide_icons.dart';
import '../../../core/utils/currency.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../domain/entities/bill_entity.dart';
import '../../common/app_avatar.dart';
import '../../../domain/entities/goal_entity.dart';
import '../../../domain/finance/money_format.dart';
import '../../plans/plans_providers.dart';
import '../dashboard_providers.dart';

/// The cards of the redesigned Home (concept B). Presentation only: every
/// figure arrives computed from `dashboardDataProvider` or the Home section
/// providers, and every tap is delegated to the screen.

/// «أين ذهبت أموالك» — one segmented bar of the period's categories, then the
/// top four with their share and change against the previous window.
class CategorySpendCard extends StatelessWidget {
  const CategorySpendCard({
    super.key,
    required this.categories,
    required this.privacyMode,
  });

  final List<CategorySlice> categories;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    return MaliCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: SizedBox(
              height: 14,
              child: Row(
                children: [
                  for (var i = 0; i < categories.length; i++) ...[
                    if (i > 0) const SizedBox(width: 3),
                    Expanded(
                      flex:
                          (categories[i].percent * 1000).round().clamp(8, 1000),
                      child: Container(
                        decoration: BoxDecoration(
                          color: categories[i].category.color,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < categories.length && i < 4; i++)
            _row(context, c, t, categories[i], first: i == 0),
        ],
      ),
    );
  }

  Widget _row(
      BuildContext context, AppColors c, MaliTokens t, CategorySlice slice,
      {required bool first}) {
    final prev = slice.previousTotal;
    String? delta;
    Color? deltaColor;
    if (prev != null && !prev.isZero && !prev.isNegative) {
      final ratio = slice.total.toDouble() / prev.toDouble() - 1;
      final pct = (ratio * 100).round();
      if (pct != 0) {
        delta = '${pct > 0 ? '+' : '−'}${pct.abs() > 999 ? 999 : pct.abs()}%';
        deltaColor = pct > 0 ? c.warning : c.income;
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: first ? null : Border(top: BorderSide(color: t.cardBorder)),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: slice.category.color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(slice.category.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.body(t.textOnCanvasPrimary)),
          ),
          if (delta != null) ...[
            Text(delta,
                textDirection: TextDirection.ltr,
                style: AppTypography.micro(deltaColor!)),
            const SizedBox(width: 8),
          ],
          Text('${(slice.percent * 100).round()}%',
              style: AppTypography.caption(t.textOnCanvasMuted)),
          const SizedBox(width: 10),
          Text(privacyMode ? '••••' : formatMoney(slice.total),
              style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
        ],
      ),
    );
  }
}

/// «مدفوعات قادمة» — a 14-day strip with a dot on each charge date, then the
/// next three subscriptions or instalments.
class UpcomingPaymentsCard extends StatelessWidget {
  const UpcomingPaymentsCard({
    super.key,
    required this.bills,
    required this.privacyMode,
    required this.now,
    required this.onTap,
  });

  /// Subscriptions and instalments together. Never summed — each row keeps
  /// its own amount.
  final List<BillEntity> bills;
  final bool privacyMode;
  final DateTime now;
  final VoidCallback onTap;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    final today = _day(now);
    final dueDays = {for (final b in bills) _day(b.nextDueDate)};
    final next = [...bills]
      ..sort((a, b) => a.nextDueDate.compareTo(b.nextDueDate));

    // Preserve the compact strip at ordinary size; grow only when the actual
    // localized, platform-scaled labels need more room. Reserve the due dot's
    // space instead of shrinking or clipping the user's larger text.
    Size labelSize(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.localeOf(context),
      )..layout();
      final size = painter.size;
      painter.dispose();
      return size;
    }

    var stripHeight = 64.0;
    var dayWidth = 46.0;
    for (var i = 0; i < 14; i++) {
      final date = DateTime(today.year, today.month, today.day + i);
      final weekday = labelSize(
          MaterialLocalizations.of(context).narrowWeekdays[date.weekday % 7],
          AppTypography.micro(t.textOnCanvasMuted));
      final day = labelSize(
          '${date.day}', AppTypography.subhead(t.textOnCanvasPrimary));
      final neededHeight = (weekday.height + day.height + 26).ceilToDouble();
      final neededWidth =
          (weekday.width > day.width ? weekday.width : day.width)
                  .ceilToDouble() +
              12;
      if (neededHeight > stripHeight) stripHeight = neededHeight;
      if (neededWidth > dayWidth) dayWidth = neededWidth;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: stripHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: 14,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (context, i) {
              // Calendar days, not 24h steps: a DST change (Egypt's ends on
              // the last Thursday of October) would repeat or skip a day.
              final d = DateTime(today.year, today.month, today.day + i);
              final isToday = i == 0;
              final weekday = MaterialLocalizations.of(context)
                  .narrowWeekdays[d.weekday % 7];
              return Container(
                width: dayWidth,
                decoration: BoxDecoration(
                  color: isToday ? c.cta : t.surfaceFloating,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(
                      color: isToday ? Colors.transparent : t.cardBorder),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(weekday,
                            style: AppTypography.micro(isToday
                                ? Colors.white.withValues(alpha: 0.8)
                                : t.textOnCanvasMuted)),
                        Text('${d.day}',
                            style: AppTypography.subhead(isToday
                                ? Colors.white
                                : t.textOnCanvasPrimary)),
                      ],
                    ),
                    if (dueDays.contains(d))
                      Positioned(
                        bottom: 6,
                        child: Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: isToday ? Colors.white : c.danger,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        MaliCard(
          onTap: onTap,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Column(
            children: [
              for (var i = 0; i < next.length && i < 3; i++)
                _row(context, c, t, next[i], today, first: i == 0),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, AppColors c, MaliTokens t, BillEntity b,
      DateTime today,
      {required bool first}) {
    final due = b.nextDueDate;
    // Counted in UTC so a DST hour in between cannot drop a day.
    final days = DateTime.utc(due.year, due.month, due.day)
        .difference(DateTime.utc(today.year, today.month, today.day))
        .inDays;
    final when = days < 0
        ? context.l10n.txnOverdueDays(days.abs())
        : days == 0
            ? context.l10n.txnDueToday
            : context.l10n.txnInDays(days);
    final soon = days <= 3;
    final total = b.totalInstallments;
    final subtitle = total != null && total > 0
        ? context.l10n.homeInstalmentProgress(
            ((b.paidCount ?? 0) + 1).clamp(1, total), total)
        : Formatters.dateGroupLabel(b.nextDueDate, context);
    if (MediaQuery.textScalerOf(context).scale(16) > 24) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          border: first ? null : Border(top: BorderSide(color: t.cardBorder)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppAvatar.brand(name: b.lenderName ?? b.name),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(b.name,
                        style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                    Text(subtitle,
                        style: AppTypography.caption(t.textOnCanvasMuted)),
                  ],
                )),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                Text(
                    privacyMode
                        ? '••••'
                        : '\u2066−${formatMoney(b.amountMoney)}\u2069 ${Currency.label(context, b.currency.toUpperCase())}',
                    style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: (soon ? c.warning : c.cta).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(when,
                      style: AppTypography.micro(soon ? c.warning : c.cta)),
                ),
              ],
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: first ? null : Border(top: BorderSide(color: t.cardBorder)),
      ),
      child: Row(
        children: [
          // Same tile as the Subscriptions screen: bundled brand SVG first,
          // then the consent-gated remote logo, then the letter.
          AppAvatar.brand(name: b.lenderName ?? b.name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(b.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                Text(subtitle,
                    maxLines: 1,
                    style: AppTypography.caption(t.textOnCanvasMuted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                privacyMode
                    ? '••••'
                    // LRI…PDI isolates the signed number so RTL keeps the
                    // minus in front of it («−56.00 ريال»).
                    : '\u2066−${formatMoney(b.amountMoney)}\u2069 ${Currency.label(context, b.currency.toUpperCase())}',
                style: AppTypography.bodyStrong(t.textOnCanvasPrimary),
              ),
              const SizedBox(height: 3),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: (soon ? c.warning : c.cta).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(when,
                    style: AppTypography.micro(soon ? c.warning : c.cta)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compact goal and plan cards with a separate action to create a goal.
class GoalsPlansRail extends StatelessWidget {
  const GoalsPlansRail({
    super.key,
    required this.goals,
    required this.plans,
    required this.privacyMode,
    required this.onGoalTap,
    required this.onPlanTap,
    required this.onNewGoal,
  });

  final List<GoalEntity> goals;
  final List<PlanProgress> plans;
  final bool privacyMode;
  final VoidCallback onGoalTap;
  final VoidCallback onPlanTap;
  final VoidCallback onNewGoal;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) =>
            _buildRail(context, constraints.maxWidth),
      );

  Widget _buildRail(BuildContext context, double availableWidth) {
    final c = context.colors;
    final count = goals.length + plans.length;
    final width = count == 1
        ? availableWidth
        : ((availableWidth - AppSpacing.s2) / 2).clamp(148.0, 220.0);
    final cards = <Widget>[
      for (final g in goals)
        _card(
          context,
          width: width,
          name: g.name,
          label: context.l10n.homeTileGoal,
          photo: qirshGoalPhoto(g.vaultSkin),
          ratio: g.targetAmount > 0 ? g.savedAmount / g.targetAmount : 0,
          color: c.income,
          line: privacyMode
              ? '•••• / ••••'
              : '${formatMoney(g.savedMoney)} / ${formatMoney(g.targetMoney)}',
          onTap: onGoalTap,
        ),
      for (final p in plans)
        _card(
          context,
          width: width,
          name: p.plan.name,
          label: context.l10n.homeTilePlan,
          ratio: p.ratio,
          color: p.isOver ? c.danger : c.cta,
          line: p.perDayLeft.isZero
              ? context.l10n
                  .planSpent(privacyMode ? '••••' : formatMoney(p.spent))
              : context.l10n.planPerDayLeft(
                  privacyMode ? '••••' : formatMoney(p.perDayLeft)),
          onTap: onPlanTap,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: 6),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpacing.s2),
                  cards[i],
                ],
              ],
            ),
          ),
        ),
        TextButton.icon(
          onPressed: onNewGoal,
          icon: const Icon(AppLucideIcons.plus, size: 16),
          label: Text(context.l10n.homeNewGoal),
        ),
      ],
    );
  }

  Widget _card(
    BuildContext context, {
    required double width,
    required String name,
    required String label,
    QirshPhoto? photo,
    required double ratio,
    required Color color,
    required String line,
    required VoidCallback onTap,
  }) {
    final t = MaliTokens.of(context);
    return SizedBox(
      width: width,
      child: MaliCard(
        style: MaliSurfaceStyle.raised,
        onTap: onTap,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: photo == null
                      ? Container(
                          width: 38,
                          height: 38,
                          color: color.withValues(alpha: 0.12),
                          child: Icon(AppLucideIcons.calendar,
                              color: color, size: 18),
                        )
                      : QirshPhotoFrame(photo: photo, height: 38, width: 38),
                ),
                const SizedBox(width: AppSpacing.s2),
                Expanded(
                  child: Text(label,
                      style: AppTypography.caption(t.textOnCanvasMuted)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s2),
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
            const SizedBox(height: 3),
            Text(line,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.caption(t.textOnCanvasSecondary)),
            if (!privacyMode) ...[
              const Spacer(),
              const SizedBox(height: AppSpacing.s2),
              LinearProgressIndicator(
                value: ratio.clamp(0, 1),
                minHeight: 5,
                borderRadius: BorderRadius.circular(4),
                backgroundColor: t.ringTrackNeutral,
                color: color,
                semanticsLabel: name,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
