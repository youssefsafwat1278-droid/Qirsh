import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// شريط تبويب حبة الدواء — سيطرة قطعية قابلة لإعادة الاستخدام.
///
/// A quiet segmented track with a sliding blue selection.
/// آمن في وضع RTL، ودعم إمكانية الوصول.
/// لا يعتمد على [TabController] أو أي شاشة بعينها.
class AppPillTabBar extends StatelessWidget {
  const AppPillTabBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    this.height = 44,
    this.onPhoto = false,
  });

  final List<String> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final double height;
  final bool onPhoto;

  static const double _inset = 3;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final lensFill = c.cta;
    final selectedFg = c.onCta;
    final idleFg = onPhoto ? Colors.white : c.textSecondary;
    final scaledHeight = MediaQuery.textScalerOf(context).scale(12) * 2.4 + 8;
    final count = tabs.length;
    final x = count < 2 ? 0.0 : -1 + 2 * selectedIndex / (count - 1);

    return SizedBox(
      height: scaledHeight > height ? scaledHeight : height,
      child: Container(
        decoration: BoxDecoration(
          color: onPhoto ? const Color(0xB30B1526) : c.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border:
              Border.all(color: onPhoto ? const Color(0x55FFFFFF) : c.border),
        ),
        padding: const EdgeInsets.all(_inset),
        child: Stack(
          children: [
            if (selectedIndex >= 0 && selectedIndex < count)
              Positioned.fill(
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  alignment: AlignmentDirectional(x, 0),
                  child: FractionallySizedBox(
                    widthFactor: 1 / count,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: lensFill,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                    ),
                  ),
                ),
              ),
            Row(
              children: [
                for (var i = 0; i < count; i++)
                  Expanded(
                    child: Semantics(
                      label: tabs[i],
                      selected: selectedIndex == i,
                      button: true,
                      onTap: () => onSelected(i),
                      excludeSemantics: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onSelected(i),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 180),
                              style: AppTypography.caption(
                                selectedIndex == i ? selectedFg : idleFg,
                              ).copyWith(fontWeight: FontWeight.w700),
                              child: Text(
                                tabs[i],
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
