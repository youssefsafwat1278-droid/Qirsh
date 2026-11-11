import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_motion.dart';
import '../app_typography.dart';
import '../mali_tokens.dart';

/// MerchantBar — one ranked merchant/place spend row: a brand mark, the name
/// over a proportional progress bar, and the amount + operation count. Pure
/// presentation; [fraction] is 0..1 relative to the top merchant.
class MerchantBar extends StatelessWidget {
  const MerchantBar({
    super.key,
    required this.name,
    required this.amount,
    required this.fraction,
    this.meta,
    this.markLabel,
    this.markColor,
  });

  final String name;
  final String amount;
  final double fraction;
  final String? meta;
  final String? markLabel;
  final Color? markColor;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final mark = markColor ?? MaliTokens.accentStart;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: mark,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              (markLabel ?? (name.isNotEmpty ? name.characters.first : '?')),
              style: AppTypography.subhead(Colors.white),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.subhead(t.textOnCanvasPrimary),
                ),
                const SizedBox(height: 7),
                ChartBar(value: fraction),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                amount,
                style: AppTypography.subhead(t.textOnCanvasPrimary),
              ),
              if (meta != null) ...[
                const SizedBox(height: 3),
                Text(meta!, style: AppTypography.caption(t.textOnCanvasMuted)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// ChartBar — the v2 ranked-spend bar (merchant bars, share bars).
///
/// Anchored at the leading edge (right in RTL) and growing toward the
/// trailing edge. Default fill per theme (spec §3.0): dark `action.text`
/// #8FB0FF@70% on the well #0C0D11; light action #155DFC on #E6EAF2 — never
/// the brand navy. Draws in once (`m.chart`: width 0→value, 600ms ease.out,
/// after [delay] for a leading→trailing stagger); Reduce Motion renders the
/// final width.
class ChartBar extends StatelessWidget {
  const ChartBar({
    super.key,
    required this.value,
    this.height = 6,
    this.color,
    this.trackColor,
    this.delay = Duration.zero,
    this.animate = true,
  });

  /// 0..1; clamped.
  final double value;
  final double height;
  final Color? color;
  final Color? trackColor;
  final Duration delay;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = color ??
        (isDark ? c.actionText.withValues(alpha: .70) : c.cta);
    final track = trackColor ?? c.surfaceMuted;
    final target = value.isNaN ? 0.0 : value.clamp(0.0, 1.0).toDouble();
    final radius = BorderRadius.circular(height);

    Widget bar(double v) => SizedBox(
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(color: track, borderRadius: radius),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FractionallySizedBox(
                widthFactor: v,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: fill, borderRadius: radius),
                ),
              ),
            ),
          ),
        );

    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (!animate || reduce || target == 0) return bar(target);
    const run = Duration(milliseconds: 600);
    final total = run + delay;
    final start = delay.inMicroseconds / total.inMicroseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target),
      duration: total,
      curve: Interval(start, 1, curve: AppMotion.easeOut),
      builder: (context, v, _) => bar(v),
    );
  }
}
