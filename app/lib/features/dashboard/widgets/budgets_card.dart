import 'package:flutter/material.dart';

import '../../../core/theme/app_motion.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/mali_tokens.dart';
import '../../../core/theme/widgets/mali_card.dart';
import '../../../core/utils/app_lucide_icons.dart';
import '../../../domain/entities/budget_entity.dart';
import '../../../domain/finance/money_format.dart';
import '../../common/app_status_pill.dart';
import '../dashboard_providers.dart';
import 'home_v2_style.dart';

/// Compact account-scoped budget overview on Home.
class BudgetsCard extends StatelessWidget {
  const BudgetsCard({
    super.key,
    required this.entries,
    required this.privacyMode,
    this.maxHeight = 260,
    this.onTap,
  });

  final List<DashboardBudgetEntry> entries;
  final bool privacyMode;
  final double maxHeight;
  final VoidCallback? onTap;

  int get _overCount =>
      entries.where((e) => e.spent.compareTo(e.limit) > 0).length;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, AppSpacing.s2),
        child: Text(context.l10n.homeNoBudgetsOnAccount,
            style: AppTypography.caption(t.textOnCanvasSecondary)),
      );
    }

    // v2: a Group card in BOTH themes (light white + e1 — it used to sit
    // bare on the canvas in light).
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 4),
            child: Wrap(
              spacing: AppSpacing.s3,
              runSpacing: AppSpacing.s1,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _summary(
                  icon: AppLucideIcons.wallet,
                  count: entries.length,
                  label: context.l10n.helpBudgetsTitle,
                  color: t.textOnCanvasSecondary,
                ),
                _summary(
                  icon: AppLucideIcons.flag,
                  count: _overCount,
                  label: context.l10n.bdgStateOverF,
                  color: _overCount > 0
                      ? context.colors.danger
                      : t.textOnCanvasMuted,
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: entries.length,
              separatorBuilder: (context, index) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
                child: Divider(height: 1, color: HomeV2.hairline(context)),
              ),
              itemBuilder: (context, i) => _row(context, t, entries[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summary({
    required IconData icon,
    required int count,
    required String label,
    required Color color,
  }) =>
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: AppSpacing.s1),
          Text('$count · $label', style: AppTypography.caption(color)),
        ],
      );

  Widget _row(BuildContext context, MaliTokens t, DashboardBudgetEntry entry) {
    final c = context.colors;
    final hasLimit = !entry.limit.isZero && !entry.limit.isNegative;
    final ratio = hasLimit ? entry.ratio : null;
    final tone = hasLimit
        ? c.budgetState(entry.ratio, warnAtPercent: entry.alertThresholdPercent)
        : t.textOnCanvasMuted;
    final over = entry.spent.minorUnits > entry.limit.minorUnits;
    final left = over ? entry.spent - entry.limit : entry.limit - entry.spent;
    final periodLabel = switch (entry.period) {
      BudgetPeriod.daily => context.l10n.bdgFilterDaily,
      BudgetPeriod.weekly => context.l10n.txnCycleWeekly,
      BudgetPeriod.monthly => context.l10n.txnCycleMonthly,
      BudgetPeriod.yearly => context.l10n.txnCycleYearly,
    };

    final amountStyle = AppTypography.subhead(over ? c.danger : c.income)
        .copyWith(fontWeight: FontWeight.w600, fontFeatures: const [
      FontFeature.tabularFigures(),
    ]);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    entry.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyStrong(t.textOnCanvasPrimary)
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: AppSpacing.s2),
                AppStatusPill(label: periodLabel, compact: true),
                const Spacer(),
                if (hasLimit) ...[
                  const SizedBox(width: AppSpacing.s2),
                  Flexible(
                    flex: 2,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerEnd,
                      child: Text(
                        privacyMode
                            ? '••••'
                            : '${over ? context.l10n.bdgOver : context.l10n.bdgRemaining} ${formatMoney(left)}',
                        maxLines: 1,
                        style: amountStyle,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.s2),
            if (ratio != null && !privacyMode)
              _BudgetBar(
                value: ratio.clamp(0.0, 1.0).toDouble(),
                color: tone,
                semanticsLabel: entry.label,
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    privacyMode
                        ? '•••• / ••••'
                        : '${formatMoney(entry.spent)} / ${formatMoney(entry.limit)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textDirection: TextDirection.ltr,
                    textAlign: Directionality.of(context) == TextDirection.rtl
                        ? TextAlign.end
                        : TextAlign.start,
                    style: AppTypography.caption(t.textOnCanvasMuted),
                  ),
                ),
                if (ratio != null && !privacyMode)
                  Text('${(ratio * 100).round()}%',
                      style: AppTypography.caption(t.textOnCanvasMuted)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// v2 budget bar: 8pt, pill radius, health-coded fill on the neutral track.
/// `m.chart` — fills from the leading edge over 600ms (expo-out); Reduce
/// Motion renders it complete.
class _BudgetBar extends StatelessWidget {
  const _BudgetBar({
    required this.value,
    required this.color,
    required this.semanticsLabel,
  });

  final double value;
  final Color color;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final reduce = HomeV2.chart(context) == Duration.zero;
    return Semantics(
      label: semanticsLabel,
      value: '${(value * 100).round()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: SizedBox(
          height: 8,
          child: ColoredBox(
            color: HomeV2.track(context),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: reduce ? value : 0, end: value),
              duration: reduce ? Duration.zero : const Duration(milliseconds: 600),
              curve: AppMotion.easeOut,
              builder: (context, v, _) => FractionallySizedBox(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: v,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
