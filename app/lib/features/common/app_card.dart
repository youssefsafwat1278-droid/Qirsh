import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/mali_tokens.dart';

enum AppCardVariant { base, elevated, gradient, danger }

/// بطاقة قياسية بتوكنات التصميم — سطح، زاوية، ظل، وحواف ناعمة.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding,
    this.border,
    this.color,
    this.gradient,
    this.variant = AppCardVariant.base,
    this.margin,
    this.radius,
    this.semanticsLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;
  final Border? border;
  final Color? color;
  final Gradient? gradient;
  final AppCardVariant variant;
  final EdgeInsetsGeometry? margin;
  final double? radius;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    // Calm Capital: match the flagship MaliCard so AppCard-based screens look
    // identical (28px radius + translucent floating fill). `radius:` overrides.
    final effectiveRadius = radius ?? AppRadius.card;
    final effectiveGradient = gradient ??
        switch (variant) {
          AppCardVariant.gradient => LinearGradient(
              colors: [c.surfaceElevated, c.surface],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          AppCardVariant.danger => LinearGradient(
              colors: [c.dangerBg, c.surface],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          _ => null,
        };
    final effectiveBorder = border ??
        Border.all(
          color: switch (variant) {
            AppCardVariant.danger => c.danger.withValues(alpha: 0.24),
            AppCardVariant.gradient => c.border.withValues(alpha: 0.8),
            _ => t.cardBorder,
          },
          width: 1.0,
        );
    final decoration = BoxDecoration(
      color: effectiveGradient == null ? (color ?? t.surfaceFloating) : null,
      gradient: effectiveGradient,
      borderRadius: BorderRadius.circular(effectiveRadius),
      border: effectiveBorder,
      // v2: Group = e1 (light) / none (dark); elevated = e2 / none.
      boxShadow: variant == AppCardVariant.elevated
          ? AppShadows.raised(Theme.of(context).brightness)
          : t.floatShadow,
    );

    final cardContent = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(effectiveRadius),
      clipBehavior: Clip.antiAlias,
      child: onTap != null
          ? InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(effectiveRadius),
              child: Padding(
                padding:
                    padding ?? const EdgeInsets.all(AppSpacing.cardPadding),
                child: child,
              ),
            )
          : Padding(
              padding: padding ?? const EdgeInsets.all(AppSpacing.cardPadding),
              child: child,
            ),
    );

    final content = Container(
      margin: margin,
      decoration: decoration,
      child: cardContent,
    );

    if (onTap == null) return content;

    return Semantics(
      label: semanticsLabel,
      button: true,
      child: content,
    );
  }
}
