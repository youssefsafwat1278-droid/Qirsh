import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/theme/mali_tokens.dart';
import '../../common/motion.dart';

/// Calm Capital v2 treatments that are specific to Home (spec §3 «05» and the
/// §3.0 Home rows). Kept local to the dashboard: the shared theme carries the
/// tokens, this file only resolves the few per-theme values the spec gives
/// for Home's own surfaces (hero gradient, chart bars, pace bar).
abstract final class HomeV2 {
  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  /// Hero gradient, top-leading → bottom-trailing. Light is one step brighter
  /// with no deep navy (spec §2.2 Hero).
  static List<Color> heroStops(bool dark) => dark
      ? const [AppBrandBlue.deep, AppBrandBlue.brand, AppBrandBlue.strong]
      : const [AppBrandBlue.brand, AppBrandBlue.strong, AppBrandBlue.mid];

  /// Hero lift: dark glow `#2E6BFF`@20% blur 32 y10; light `#155DFC`@28%
  /// blur 32 y12.
  static List<BoxShadow> heroShadow(bool dark) => dark
      ? AppShadows.heroGlow
      : const [
          BoxShadow(
              color: Color(0x47155DFC), blurRadius: 32, offset: Offset(0, 12)),
        ];

  /// The 1px inner top sheen of the hero.
  static Color heroSheen(bool dark) =>
      Colors.white.withValues(alpha: dark ? 0.14 : 0.28);

  /// Tracks and dividers inside the hero.
  static Color heroTrack(bool dark) =>
      Colors.white.withValues(alpha: dark ? 0.16 : 0.24);

  /// The over-pace span of the hero pace bar — a lighter amber in light for
  /// the brighter gradient.
  static Color heroOverPace(bool dark) =>
      dark ? AppColors.dark.warning : const Color(0xFFFFB454);

  /// Row dividers: `#FFFFFF`@6% in dark, `#E6EAF2` in light.
  static Color hairline(BuildContext context) => isDark(context)
      ? MaliTokens.dark.cardBorder
      : context.colors.border;

  /// Progress / ring track: `#FFFFFF`@12% dark, `#E6EAF2` light.
  static Color track(BuildContext context) => isDark(context)
      ? MaliTokens.dark.ringTrackNeutral
      : context.colors.surfaceMuted;

  /// Inactive chart bar: `#FFFFFF`@14% dark, `#D9E0EE` light.
  static Color chartOff(BuildContext context) =>
      isDark(context) ? const Color(0x24FFFFFF) : const Color(0xFFD9E0EE);

  /// Group card fill + edge, per theme: dark `#121317` + 1px hairline, light
  /// white + e1, no border.
  static BoxDecoration group(BuildContext context,
      {double radius = 20, Color? color}) {
    final dark = isDark(context);
    return BoxDecoration(
      color: color ?? context.colors.surface,
      borderRadius: BorderRadius.circular(radius),
      border: dark ? Border.all(color: MaliTokens.dark.cardBorder) : null,
      boxShadow: AppShadows.group(Theme.of(context).brightness),
    );
  }

  /// Draw-in duration, or zero under Reduce Motion.
  static Duration chart(BuildContext context) => shouldReduceMotion(context)
      ? Duration.zero
      : AppMotion.chartAnimation;
}

/// v2 `m.press`: scales its child down while pressed and releases on the
/// snappy spring curve. Purely visual; [onTap] keeps the caller's behaviour.
class HomePressScale extends StatefulWidget {
  const HomePressScale({
    super.key,
    required this.child,
    required this.onTap,
    this.scale = AppMotion.pressScaleButton,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  @override
  State<HomePressScale> createState() => _HomePressScaleState();
}

class _HomePressScaleState extends State<HomePressScale> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: widget.onTap == null ? null : (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: _down ? AppMotion.press : AppMotion.base,
        curve: _down ? Curves.easeOut : AppMotion.springSnappyCurve,
        child: widget.child,
      ),
    );
  }
}

/// A dashed horizontal rule (the 7-day average line). [progress] draws it
/// from the leading edge.
class HomeDashedLine extends StatelessWidget {
  const HomeDashedLine({super.key, required this.color, this.progress = 1});

  final Color color;
  final double progress;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: const Size(double.infinity, 1.5),
        painter: _DashPainter(
            color: color,
            progress: progress,
            rtl: Directionality.of(context) == TextDirection.rtl),
      );
}

class _DashPainter extends CustomPainter {
  _DashPainter(
      {required this.color, required this.progress, required this.rtl});

  final Color color;
  final double progress;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    final end = size.width * progress.clamp(0.0, 1.0);
    const dash = 5.0, gap = 4.0;
    for (var x = 0.0; x < end; x += dash + gap) {
      final a = x, b = (x + dash).clamp(0.0, end);
      final y = size.height / 2;
      if (rtl) {
        canvas.drawLine(
            Offset(size.width - a, y), Offset(size.width - b, y), paint);
      } else {
        canvas.drawLine(Offset(a, y), Offset(b, y), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) =>
      old.color != color || old.progress != progress || old.rtl != rtl;
}
