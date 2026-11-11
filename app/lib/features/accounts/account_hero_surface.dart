import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../domain/finance/money.dart';
import '../common/money_text.dart';
import '../common/motion.dart';

/// Calm Capital v2 **Hero** role (spec §2.2) for the accounts surfaces: the
/// per-theme brand gradient as a self-contained card with a hard edge — dark
/// `#011341 → #022686 → #0336BF` + heroGlow, light `#022686 → #0336BF →
/// #155DFC` + a blue drop shadow — and a 1px inner top sheen.
///
/// Decoration only; callers own the content and its data.
class AccountHeroSurface extends StatelessWidget {
  const AccountHeroSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.s5),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  static const double radius = 28;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderRadius = BorderRadius.circular(radius);
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          gradient: LinearGradient(
            begin: AlignmentDirectional.topStart,
            end: AlignmentDirectional.bottomEnd,
            colors: isDark
                ? const [
                    AppBrandBlue.deep,
                    AppBrandBlue.brand,
                    AppBrandBlue.strong,
                  ]
                : const [
                    AppBrandBlue.brand,
                    AppBrandBlue.strong,
                    AppBrandBlue.mid,
                  ],
          ),
          boxShadow: isDark
              ? AppShadows.heroGlow
              : const [
                  BoxShadow(
                    color: Color(0x47155DFC),
                    blurRadius: 32,
                    offset: Offset(0, 12),
                  ),
                ],
        ),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: Stack(
            children: [
              // Inner top sheen: 1px white @14% (dark) / @28% (light).
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 1,
                child: ColoredBox(
                  color: Colors.white.withValues(alpha: isDark ? 0.14 : 0.28),
                ),
              ),
              Padding(
                padding: padding,
                child: DefaultTextStyle.merge(
                  style: const TextStyle(color: Colors.white),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// v2 `m.count` for an exact [Money] rendered through [MoneyText] (sign leads,
/// decimals dimmed): counts from zero on first paint, expo-out, duration by
/// magnitude. Reduce Motion renders the final value.
class CountUpMoneyText extends StatelessWidget {
  const CountUpMoneyText(this.money, {super.key, required this.style});

  final Money money;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    if (shouldReduceMotion(context)) return MoneyText(money, style: style);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.countFor(money.minorUnits / 100),
      curve: AppMotion.easeOut,
      builder: (context, t, _) {
        final minor = t >= 1
            ? money.minorUnits
            : (money.minorUnits * t).truncate();
        return MoneyText(Money(minor, money.currency), style: style);
      },
    );
  }
}

/// Alpha of the n-th share in a composition bar / its matching row key
/// (spec 11: @100 / 70 / 45 / 25%).
double accountShareAlpha(int index) => switch (index) {
      0 => 1.0,
      1 => 0.70,
      2 => 0.45,
      _ => 0.25,
    };
