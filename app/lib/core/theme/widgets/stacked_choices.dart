import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_spacing.dart';
import '../app_typography.dart';

/// UX-09 / SP-10: the large-text form of a horizontal pill selector
/// (segmented control, pill tabs). At large text the options are stacked one
/// per line at full width, so every label is read whole instead of being cut
/// to a few letters in a narrow segment. Each option is at least 44 pt tall.
class StackedChoices extends StatelessWidget {
  const StackedChoices({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    required this.trackColor,
    required this.selectedColor,
    required this.selectedForeground,
    required this.idleForeground,
    this.icons,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Color trackColor;
  final Color selectedColor;
  final Color selectedForeground;
  final Color idleForeground;
  final List<IconData?>? icons;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: trackColor,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < labels.length; i++)
            Semantics(
              button: true,
              selected: i == selectedIndex,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (i != selectedIndex) HapticFeedback.selectionClick();
                  onSelected(i);
                },
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.s3, vertical: AppSpacing.s2),
                  decoration: BoxDecoration(
                    color: i == selectedIndex ? selectedColor : null,
                    borderRadius: BorderRadius.circular(AppRadius.card - 4),
                  ),
                  alignment: AlignmentDirectional.centerStart,
                  child: Row(
                    children: [
                      if (icons?[i] != null) ...[
                        Icon(icons![i],
                            size: 16,
                            color: i == selectedIndex
                                ? selectedForeground
                                : idleForeground),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          labels[i],
                          style: AppTypography.subhead(i == selectedIndex
                                  ? selectedForeground
                                  : idleForeground)
                              .copyWith(
                                  fontWeight: i == selectedIndex
                                      ? FontWeight.w600
                                      : FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
