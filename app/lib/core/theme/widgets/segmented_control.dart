import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../app_colors.dart';
import '../app_motion.dart';
import '../app_shadows.dart';
import '../app_spacing.dart';
import '../app_typography.dart';

/// One option in a [SegmentedControl].
class SegmentOption<T> {
  const SegmentOption({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// SegmentedControl — the v2 `QSegmented` pill selector (add-sheet type,
/// report tabs). The selected thumb is `surface.top` (or the action fill when
/// [accent] is set) and slides between segments. Pure presentation + a
/// callback.
class SegmentedControl<T> extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.accent = false,
  });

  final List<SegmentOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selected = options.indexWhere((o) => o.value == value);
    // v2 QSegmented: track = surface.well, pill, 44pt, 4pt inset; thumb =
    // action fill (primary, [accent]) or surface.top (secondary), sliding on
    // spring.smooth (m.select).
    Color fg(T v) {
      if (value == v) return accent ? c.onCta : c.textPrimary;
      return c.textSecondary;
    }

    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth / options.length;
          final rtl = Directionality.of(context) == TextDirection.rtl;
          return Stack(
            children: [
              if (selected >= 0)
                AnimatedPositioned(
                  duration: AppMotion.moderate,
                  curve: AppMotion.springSmoothCurve,
                  top: 0,
                  bottom: 0,
                  width: w,
                  left: rtl ? w * (options.length - 1 - selected) : w * selected,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: accent ? c.cta : c.surfaceTop,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      boxShadow:
                          accent || isDark ? null : AppShadows.e1,
                    ),
                  ),
                ),
              Row(
                children: [
                  for (final o in options)
                    Expanded(
                      child: Semantics(
                        button: true,
                        selected: value == o.value,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            if (value != o.value) {
                              HapticFeedback.selectionClick();
                            }
                            onChanged(o.value);
                          },
                          child: Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (o.icon != null) ...[
                                  Icon(o.icon, size: 16, color: fg(o.value)),
                                  const SizedBox(width: 6),
                                ],
                                Flexible(
                                  child: AnimatedDefaultTextStyle(
                                    duration: AppMotion.micro,
                                    style: AppTypography.subhead(fg(o.value))
                                        .copyWith(
                                      fontWeight: value == o.value
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                    ),
                                    child: Text(
                                      o.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
