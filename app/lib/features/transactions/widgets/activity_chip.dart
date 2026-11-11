import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';

/// v2 `QChip`: 36pt pill. Unselected = card + hairline (light: white + 1px
/// stroke.soft); selected = action.soft fill + action.text label + 1px
/// action@40% stroke. Colour morphs over `dur.micro`; `selectionClick`.
///
/// Shared by the Activity filter row and the bills Subscriptions/Instalments
/// row, so both read as one chip family.
class ActivityChip extends StatelessWidget {
  const ActivityChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge = 0,
    this.count,
    this.leading,
    this.trailing,
    this.semanticLabel,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Warning count badge (e.g. items awaiting review); hidden at 0.
  final int badge;

  /// A quiet item count after the label (e.g. «اشتراكات 2»); hidden when null.
  final int? count;
  final Widget? leading;
  final Widget? trailing;

  /// Overrides the spoken label (an icon-only chip has an empty [label]).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = selected ? c.actionText : c.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: AnimatedContainer(
          duration: AppMotion.micro,
          curve: AppMotion.easeOut,
          constraints: const BoxConstraints(minHeight: 36),
          padding: EdgeInsets.symmetric(
              horizontal: label.isEmpty ? 10 : 14, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? c.ctaSoft : c.surface,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: selected
                  ? c.cta.withValues(alpha: 0.40)
                  : isDark
                      ? c.border
                      : c.strokeSoft,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[
                leading!,
                if (label.isNotEmpty) const SizedBox(width: 6),
              ],
              if (label.isNotEmpty)
                Text(
                  label,
                  style: AppTypography.subhead(fg)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              if (count != null) ...[
                const SizedBox(width: 5),
                Text(
                  '$count',
                  textDirection: TextDirection.ltr,
                  style: AppTypography.subhead(fg.withValues(alpha: .7))
                      .copyWith(fontWeight: FontWeight.w500),
                ),
              ],
              if (badge > 0) ...[
                const SizedBox(width: 6),
                Container(
                  constraints:
                      const BoxConstraints(minWidth: 20, minHeight: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.warning,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    '$badge',
                    textDirection: TextDirection.ltr,
                    style: AppTypography.overline(Colors.white),
                  ),
                ),
              ],
              if (trailing != null) ...[
                const SizedBox(width: 4),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
