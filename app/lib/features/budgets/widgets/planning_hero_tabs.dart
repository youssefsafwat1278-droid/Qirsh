import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/l10n_ext.dart';

/// «الميزانيات | الأهداف | سجل الميزانيات» — the v2 `QSegmented` in its
/// on-photo style (spec §2.6): track #FFFFFF@12%, white thumb, selected label
/// brand navy, the others #FFFFFF@80%. Identical in both themes because it
/// always sits on the dark photo. The thumb slides on `spring.smooth`
/// (`m.select`) with a `selectionClick`.
class PlanningHeroTabs extends StatelessWidget {
  const PlanningHeroTabs(
      {super.key, required this.tab, required this.onSelected});

  final int tab;
  final ValueChanged<int> onSelected;

  static const _order = [0, 2, 1];

  @override
  Widget build(BuildContext context) {
    final tabs = [
      context.l10n.bdgTabBudgets,
      context.l10n.bdgTabGoals,
      context.l10n.bdgTabHistory,
    ];
    final selectedIndex = _order.indexOf(tab);
    final count = tabs.length;
    final x = count < 2 ? 0.0 : -1 + 2 * selectedIndex / (count - 1);
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final scaledHeight = MediaQuery.textScalerOf(context).scale(13) * 2 + 12;
    return Container(
      height: scaledHeight > 44 ? scaledHeight : 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Stack(
        children: [
          if (selectedIndex >= 0)
            Positioned.fill(
              child: AnimatedAlign(
                duration: reduce ? AppMotion.micro : AppMotion.moderate,
                curve: reduce ? Curves.linear : AppMotion.springSmoothCurve,
                alignment: AlignmentDirectional(x, 0),
                child: FractionallySizedBox(
                  widthFactor: 1 / count,
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
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
                    onTap: () => _select(i),
                    excludeSemantics: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _select(i),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: AnimatedDefaultTextStyle(
                            duration: AppMotion.micro,
                            style: AppTypography.caption(selectedIndex == i
                                    ? AppBrandBlue.brand
                                    : Colors.white.withValues(alpha: .80))
                                .copyWith(fontWeight: FontWeight.w600),
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
    );
  }

  void _select(int index) {
    if (_order[index] == tab) return;
    HapticFeedback.selectionClick();
    onSelected(_order[index]);
  }
}
