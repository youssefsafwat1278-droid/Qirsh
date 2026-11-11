import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_typography.dart';
import '../../core/theme/app_motion.dart';
import '../../core/utils/formatters.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_format.dart';

bool shouldReduceMotion(BuildContext context) {
  final media = MediaQuery.maybeOf(context);
  return media?.disableAnimations ?? false;
}

class PremiumMotion extends StatefulWidget {
  const PremiumMotion({
    super.key,
    required this.child,
    this.delay = Duration.zero,
  });

  final Widget child;
  final Duration delay;

  @override
  State<PremiumMotion> createState() => _PremiumMotionState();
}

class _PremiumMotionState extends State<PremiumMotion>
    with SingleTickerProviderStateMixin {
  // v2 m.enter, played once per mount. The widget tree under this state
  // never changes shape (FadeTransition → AnimatedBuilder → child at every
  // frame, including after completion), so a provider-driven rebuild never
  // remounts the child — a remount restarted chart/ring draw-ins midway and
  // left a pending timer behind. The delay is folded into the controller
  // as a leading Interval, so no Timer is ever scheduled.
  late final AnimationController _c;
  late final Animation<double> _fade;
  late final Animation<double> _rise;

  @override
  void initState() {
    super.initState();
    final delayMs = widget.delay.inMilliseconds;
    final total = delayMs + AppMotion.moderate.inMilliseconds;
    _c = AnimationController(
        vsync: this, duration: Duration(milliseconds: total));
    final start = delayMs / total;
    final fadeEnd =
        (delayMs + AppMotion.base.inMilliseconds) / total;
    _fade = CurvedAnimation(
        parent: _c,
        curve: Interval(start, fadeEnd.clamp(start, 1.0),
            curve: AppMotion.easeOut));
    _rise = CurvedAnimation(
        parent: _c, curve: Interval(start, 1, curve: AppMotion.easeOut));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.isAnimating || _c.isCompleted) return;
    if (shouldReduceMotion(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: AnimatedBuilder(
        animation: _rise,
        child: widget.child,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, AppMotion.enterRise * (1 - _rise.value)),
          child: child,
        ),
      ),
    );
  }
}

class AnimatedAmountText extends StatelessWidget {
  const AnimatedAmountText({
    super.key,
    required this.amount,
    required this.color,
    this.suffix = '',
    this.textAlign = TextAlign.center,
    this.style,
  }) : money = null;

  const AnimatedAmountText.money({
    super.key,
    required Money value,
    required this.color,
    this.suffix = '',
    this.textAlign = TextAlign.center,
    this.style,
  }) : money = value, amount = 0;

  final double amount;
  final Money? money;
  final Color color;
  final String suffix;
  final TextAlign textAlign;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final exact = money;
    // v2 m.count: duration scales with magnitude (500–900ms), expo-out.
    final duration = shouldReduceMotion(context)
        ? Duration.zero
        : AppMotion.countFor(exact != null
            ? exact.minorUnits / 100
            : amount);
    if (exact != null) {
      return TweenAnimationBuilder<int>(
        tween: IntTween(begin: 0, end: 1000),
        duration: duration,
        curve: AppMotion.easeOut,
        builder: (context, progress, _) {
          final minor = (BigInt.from(exact.minorUnits) * BigInt.from(progress) ~/
              BigInt.from(1000)).toInt();
          return Text('${formatMoney(Money(minor, exact.currency))}$suffix',
            textDirection: TextDirection.ltr,
            textAlign: textAlign,
            style: (style ?? AppTypography.title2(color)).copyWith(color: color,
              fontFeatures: const [FontFeature.tabularFigures()]));
        },
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: amount),
      duration: duration,
      curve: AppMotion.easeOut,
      builder: (context, value, _) {
        final baseStyle = style ?? AppTypography.title2(color);
        return Text(
          '${Formatters.amount(value)}$suffix',
          textAlign: textAlign,
          style: baseStyle.copyWith(
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
      },
    );
  }
}
