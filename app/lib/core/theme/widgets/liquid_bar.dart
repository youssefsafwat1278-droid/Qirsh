import 'package:flutter/material.dart';

import '../app_motion.dart';
import '../mali_tokens.dart';

/// LiquidBar — the horizontal counterpart of [RingProgress]: a fully-rounded
/// track with a "liquid" fill (directional gradient body, a specular meniscus
/// along the top, and a soft glow off the leading cap). Same contract as the
/// ring — a value and its render, no financial logic — so a progress that
/// reads better as a line (a goal filling up) doesn't have to be a circle.
///
/// [value] is nullable by design, matching [RingProgress]: `null` renders the
/// muted "no data yet" track instead of guessing a number.
class LiquidBar extends StatelessWidget {
  const LiquidBar({
    super.key,
    required this.value,
    this.height = 12,
    this.color,
    this.trackColor,
    this.animate = true,
  });

  /// 0..1, or null for the no-data state. Clamped defensively.
  final double? value;
  final double height;
  final Color? color;
  final Color? trackColor;
  final bool animate;

  bool _reduceMotion(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final isIndeterminate = value == null;
    final target = isIndeterminate ? 0.0 : value!.clamp(0.0, 1.0);
    final fill = color ?? MaliTokens.accentStart;
    // v2 progress track: #FFFFFF@12% (dark) / #E6EAF2-family (light).
    final track = trackColor ?? t.ringTrackNeutral;
    // v2: the glow is a dark-theme cue only; light bars sit flat.
    final glow = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(height);

    Widget bar(double v) {
      return SizedBox(
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(color: track, borderRadius: radius),
          child: v <= 0
              ? null
              : Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FractionallySizedBox(
                    widthFactor: v,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        gradient: LinearGradient(
                          begin: AlignmentDirectional.centerStart,
                          end: AlignmentDirectional.centerEnd,
                          colors: [fill.withValues(alpha: 0.62), fill],
                        ),
                        boxShadow: glow
                            ? [
                                BoxShadow(
                                  color: fill.withValues(alpha: 0.30),
                                  blurRadius: height,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : null,
                      ),
                      // The meniscus: a bright top edge that makes the fill
                      // read as a liquid surface rather than a flat block.
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: radius,
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(alpha: 0.30),
                              Colors.white.withValues(alpha: 0.0),
                            ],
                            stops: const [0.0, 0.55],
                          ),
                        ),
                        child: SizedBox(height: height),
                      ),
                    ),
                  ),
                ),
        ),
      );
    }

    if (!animate || _reduceMotion(context)) return bar(target);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target),
      // v2 linear progress: width 0→value over 600ms, ease.out.
      duration: const Duration(milliseconds: 600),
      curve: AppMotion.easeOut,
      builder: (context, v, _) => bar(v),
    );
  }
}
