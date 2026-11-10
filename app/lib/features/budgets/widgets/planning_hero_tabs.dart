import 'package:flutter/material.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../common/app_pill_tab_bar.dart';

class PlanningHeroTabs extends StatelessWidget {
  const PlanningHeroTabs(
      {super.key, required this.tab, required this.onSelected});

  final int tab;
  final ValueChanged<int> onSelected;

  static const _order = [0, 2, 1];

  @override
  Widget build(BuildContext context) {
    return AppPillTabBar(
      onPhoto: true,
      tabs: [
        context.l10n.bdgTabBudgets,
        context.l10n.bdgTabGoals,
        context.l10n.bdgTabHistory,
      ],
      selectedIndex: _order.indexOf(tab),
      onSelected: (index) => onSelected(_order[index]),
    );
  }
}
