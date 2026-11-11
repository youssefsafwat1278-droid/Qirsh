import 'package:flutter/material.dart';

import '../app_typography.dart';
import '../mali_tokens.dart';
import 'mali_card.dart';
import 'ring_progress.dart';

/// One category budget ring in a [BudgetRingRail].
class BudgetRing {
  const BudgetRing({
    required this.value,
    required this.name,
    required this.sub,
    this.color,
  });

  /// 0..1 spent-of-budget, or null for the no-data state.
  final double? value;
  final String name;
  final String sub;
  final Color? color;
}

/// BudgetRingRail — a raised strip of small category budget rings, each with a
/// percentage center, name, and "spent / limit" sub. Uses [Expanded] columns
/// so it never overflows on a narrow device. Pure presentation.
class BudgetRingRail extends StatelessWidget {
  const BudgetRingRail({super.key, required this.rings, this.ringSize = 72});

  final List<BudgetRing> rings;
  final double ringSize;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return MaliCard(
      style: MaliSurfaceStyle.raised,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in rings)
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RingProgress(
                    value: r.value,
                    size: ringSize,
                    strokeWidth: 7,
                    color: r.color ?? MaliTokens.accentStart,
                    child: Text(
                      r.value == null
                          ? '—'
                          : '${(r.value!.clamp(0.0, 1.0) * 100).round()}%',
                      style: AppTypography.subhead(t.textOnCanvasPrimary),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    r.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption(t.textOnCanvasPrimary),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    r.sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // v2: 13pt caption is the floor for Arabic.
                    style: AppTypography.caption(t.textOnCanvasMuted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
