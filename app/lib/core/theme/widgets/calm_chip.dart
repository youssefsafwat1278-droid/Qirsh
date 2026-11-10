import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_typography.dart';
import '../mali_tokens.dart';

/// CalmChip — the shared filter/choice pill (Calm Capital). Selected → brand blue; unselected → raised surface +
/// secondary text. Used for filter rows across the app; edit here to change
/// every chip.
class CalmChip extends StatelessWidget {
  const CalmChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    final fg = selected ? c.onCta : c.textSecondary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? c.cta : t.surfaceRaised,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              // 13px per the mockup `.chip` (subhead is 14).
              style: AppTypography.subhead(fg).copyWith(fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
