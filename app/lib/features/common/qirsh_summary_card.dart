import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/utils/app_lucide_icons.dart';

/// One figure in a [QirshSummaryCard] stat strip.
class QirshSummaryStat {
  const QirshSummaryStat({required this.value, required this.label});

  /// Usually an exact-money text widget (keeps privacy masking intact).
  final Widget value;
  final String label;
}

/// v3 unified summary card — the one header card every list/section page
/// opens with (Transactions, Bills, Subscriptions, Insights):
///
///   label ··························· [scope chip ▾]
///   BIG AMOUNT
///   caption
///   ─────────────────────────────────────────────
///   stat │ stat │ stat
///
/// Presentation only: callers pass already-formatted (privacy-aware) widgets.
class QirshSummaryCard extends StatelessWidget {
  const QirshSummaryCard({
    super.key,
    required this.label,
    required this.amount,
    this.scopeLabel,
    this.onScopeTap,
    this.caption,
    this.stats = const <QirshSummaryStat>[],
  });

  final String label;
  final Widget amount;

  /// Small chip in the top corner naming the card's scope (period, currency).
  /// Hidden when null.
  final String? scopeLabel;
  final VoidCallback? onScopeTap;
  final Widget? caption;
  final List<QirshSummaryStat> stats;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.s4, AppSpacing.s3, AppSpacing.s4, AppSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: AppTypography.footnote(c.textSecondary)),
              ),
              if (scopeLabel != null)
                QirshScopeChip(label: scopeLabel!, onTap: onScopeTap),
            ],
          ),
          const SizedBox(height: AppSpacing.s1),
          DefaultTextStyle.merge(
            style: AppTypography.amountLarge(c.textPrimary),
            child: amount,
          ),
          if (caption != null) ...[
            const SizedBox(height: 2),
            DefaultTextStyle.merge(
              style: AppTypography.caption(c.textSecondary),
              child: caption!,
            ),
          ],
          if (stats.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s3),
            Divider(height: 1, thickness: .5, color: c.divider),
            const SizedBox(height: AppSpacing.s3),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < stats.length; i++) ...[
                    if (i > 0)
                      VerticalDivider(
                          width: AppSpacing.s4,
                          thickness: .5,
                          color: c.divider),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: AlignmentDirectional.centerStart,
                            child: DefaultTextStyle.merge(
                              style: AppTypography.custom(
                                size: 15,
                                weight: FontWeight.w600,
                                height: 1.25,
                                tabular: true,
                                color: c.textPrimary,
                              ),
                              child: stats[i].value,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(stats[i].label,
                              style: AppTypography.micro(c.textSecondary)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The small "scope ▾" chip used in a [QirshSummaryCard] corner (period,
/// currency). Tappable when [onTap] is set.
class QirshScopeChip extends StatelessWidget {
  const QirshScopeChip({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.surfaceMuted,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.border, width: .5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: AppTypography.caption(c.textPrimary)
                  .copyWith(fontWeight: FontWeight.w600)),
          if (onTap != null) ...[
            const SizedBox(width: 3),
            Icon(AppLucideIcons.chevronDown, size: 13, color: c.textSecondary),
          ],
        ],
      ),
    );
    if (onTap == null) return chip;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: chip,
      ),
    );
  }
}
