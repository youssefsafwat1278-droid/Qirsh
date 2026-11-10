import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/utils/app_lucide_icons.dart';

/// AppCheckMark — the unified selection mark for pickable list rows: a small
/// rounded square that fills with blue + a check when selected, and shows a
/// quiet border when not. Presentation only — the enclosing row owns the
/// onTap and the interactive semantics; this widget just reports the checked
/// state to assistive tech.
class AppCheckMark extends StatelessWidget {
  const AppCheckMark({super.key, required this.selected, this.size = 22});

  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      checked: selected,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.standardCurve,
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: selected ? c.cta : Colors.transparent,
          borderRadius: BorderRadius.circular(size * 0.32),
          border: selected ? null : Border.all(color: c.border, width: 1.5),
        ),
        child: selected
            ? Icon(AppLucideIcons.check, size: size * 0.7, color: c.onCta)
            : null,
      ),
    );
  }
}
