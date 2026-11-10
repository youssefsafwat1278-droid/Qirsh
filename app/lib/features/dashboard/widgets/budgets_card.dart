import 'package:flutter/material.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/mali_tokens.dart';
import '../../../core/theme/widgets/mali_card.dart';
import '../../../core/utils/app_lucide_icons.dart';
import '../../../domain/entities/budget_entity.dart';
import '../../../domain/finance/money_format.dart';
import '../dashboard_providers.dart';

/// Compact account-scoped budget overview on Home.
class BudgetsCard extends StatelessWidget {
  const BudgetsCard({
    super.key,
    required this.entries,
    required this.privacyMode,
    this.maxHeight = 204,
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

    return MaliCard(
      style: MaliSurfaceStyle.raised,
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 14, 8),
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
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
                child: Divider(height: 1, color: t.strokeSoft),
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

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    entry.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyStrong(t.textOnCanvasPrimary),
                  ),
                ),
                const SizedBox(width: AppSpacing.s2),
                Text(
                    privacyMode || ratio == null
                        ? periodLabel
                        : '$periodLabel · ${(ratio * 100).round()}%',
                    style: AppTypography.caption(t.textOnCanvasMuted)),
              ],
            ),
            const SizedBox(height: AppSpacing.s2),
            if (ratio != null && !privacyMode)
              LinearProgressIndicator(
                value: ratio.clamp(0, 1),
                minHeight: 5,
                borderRadius: BorderRadius.circular(4),
                backgroundColor: t.ringTrackNeutral,
                color: tone,
                semanticsLabel: entry.label,
              ),
            const SizedBox(height: AppSpacing.s1),
            Wrap(
              spacing: AppSpacing.s2,
              runSpacing: AppSpacing.s1,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Text(
                  privacyMode
                      ? '•••• / ••••'
                      : '${formatMoney(entry.spent)} / ${formatMoney(entry.limit)}',
                  style: AppTypography.caption(t.textOnCanvasMuted),
                ),
                if (hasLimit)
                  Text(
                    privacyMode
                        ? '••••'
                        : '${over ? context.l10n.bdgOver : context.l10n.bdgRemaining} ${formatMoney(left)}',
                    style: AppTypography.caption(over ? c.danger : c.income),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
