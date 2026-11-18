import 'package:flutter/material.dart';

import '../app_typography.dart';
import '../large_text.dart';
import '../mali_tokens.dart';

/// SectionHeader — consistent title (+ optional trailing action) for every
/// section archetype. Defaults to on-canvas colors; override [titleColor] /
/// [trailingColor] when used on a light surface elsewhere in the app.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.onTrailingTap,
    this.titleColor,
    this.trailingColor,
  });

  final String title;
  final String? trailing;
  final VoidCallback? onTrailingTap;

  /// Defaults to the on-canvas primary/secondary for the ambient mode; override
  /// when used on a differently-colored surface.
  final Color? titleColor;
  final Color? trailingColor;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: linesUnlessLargeText(context, 1),
            overflow: TextOverflow.ellipsis,
            // Compact UI system: section titles use the 19px role token.
            style:
                AppTypography.sectionTitle(titleColor ?? t.textOnCanvasPrimary),
          ),
        ),
        if (trailing != null)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTrailingTap,
            // UX-05: a 44x44 pt tap target around the unchanged link text.
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: Text(
                  trailing!,
                  style: AppTypography.subhead(
                      trailingColor ?? t.textOnCanvasSecondary),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
