import 'package:flutter/material.dart';

/// MaliTokens — the flagship "Calm Capital" canvas + accent system
/// (docs/MALI_DESIGN_SYSTEM.md).
///
/// Mode-aware: [MaliTokens.of] resolves a [light] or [dark] instance from the
/// ambient [Theme.of] brightness, so the flagship primitives ([MaliScreen],
/// [MaliCard], rings, glass) render correctly under both wired themes
/// (`AppTheme.light` / `AppTheme.dark`). The dark set is the original true-black
/// identity; the light set is the calm off-white companion.
///
/// Depth on the dark canvas is expressed as surface *lightness* (white over
/// black); on the light canvas it is expressed as a soft shadow + hairline
/// [cardBorder]. The accent gradient is mode-invariant — see the `static const`
/// block below.
///
/// [AppColors] semantics (income/expense/warning/danger) are reused as-is for
/// semantic tints on the canvas — not duplicated here.
@immutable
class MaliTokens {
  const MaliTokens({
    required this.canvas,
    required this.canvasGlowTop,
    required this.canvasGlowSecondary,
    required this.surfaceRaised,
    required this.surfaceFloating,
    required this.surfaceGlassFill,
    required this.surfaceGlassStroke,
    required this.glassFillTop,
    required this.glassFillBottom,
    required this.glassStroke,
    required this.glassSheen,
    required this.glassSheetFill,
    required this.strokeSoft,
    required this.cardBorder,
    required this.textOnCanvasPrimary,
    required this.textOnCanvasSecondary,
    required this.textOnCanvasMuted,
    required this.ringTrackNeutral,
    required this.ringIndeterminate,
    required this.floatShadow,
    required this.auroraTop,
    required this.auroraA,
    required this.auroraB,
    required this.grainOpacity,
  });

  // ===== Canvas =====
  final Color canvas;
  final Color canvasGlowTop;
  final Color canvasGlowSecondary;

  // ===== Surface hierarchy =====
  final Color surfaceRaised;
  final Color surfaceFloating;
  final Color surfaceGlassFill;
  final Color surfaceGlassStroke;

  /// Liquid glass ([MaliGlass]) — the *real* backdrop-blurred material.
  /// Fill is a vertical [glassFillTop]→[glassFillBottom] gradient painted over
  /// the blurred backdrop; [glassStroke] is the 1px rim (white on dark, ink on
  /// light — light-mode definition comes from ink + shadow, not white glow);
  /// [glassSheen] is the top specular edge highlight.
  final Color glassFillTop;
  final Color glassFillBottom;
  final Color glassStroke;
  final Color glassSheen;

  /// Near-opaque body fill for the `sheet` glass variant. Sheets carry forms
  /// and financial input, so only a thin band at the top edge stays properly
  /// translucent; the body must read as solid.
  final Color glassSheetFill;

  final Color strokeSoft;

  /// Hairline edge for a floating card. Barely-there on dark (elevation via
  /// surface lightness carries depth there); a real hairline on light (where
  /// the soft shadow needs an edge to sit against).
  final Color cardBorder;

  // ===== Text on canvas =====
  final Color textOnCanvasPrimary;
  final Color textOnCanvasSecondary;
  final Color textOnCanvasMuted;

  // ===== Neutral ring track =====
  final Color ringTrackNeutral;
  final Color ringIndeterminate;

  /// Drop shadow for a floating card, matching the HTML mockup's `--float-shadow`.
  /// Dark = deep black key + wide ambient; light = soft navy-tinted. Mode-aware
  /// (unlike the `static const` [AppShadows]).
  final List<BoxShadow> floatShadow;

  /// Combined canvas background ("aurora"): a top accent glow ([auroraTop]) +
  /// two soft aurora blobs ([auroraA]/[auroraB]) + a faint [grainOpacity] grain.
  /// Painted by [CalmCanvas]; tune here to change the background app-wide.
  final Color auroraTop;
  final Color auroraA;
  final Color auroraB;
  final double grainOpacity;

  // ===== Accent (mode-invariant — see design doc §0.2) =====
  // Reserved for AI insight, selected states, subtle glows, and a small number
  // of flagship moments. The hero balance stays directly on canvas — never
  // wrapped in this gradient. Same blue ramp in light and dark, so these stay
  // `static const` (usable as const default parameter values).
  static const Color accentStart = Color(0xFF2E6BFF);
  static const Color accentEnd = Color(0xFF1C4FD0);

  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accentStart, accentEnd],
  );

  /// The true-black flagship identity.
  static const MaliTokens dark = MaliTokens(
    canvas: Color(0xFF000000),
    canvasGlowTop: Color(0x1A2E6BFF),
    canvasGlowSecondary: Color(0x0FFFFFFF),
    surfaceRaised: Color(0x0AFFFFFF), // white @ ~4%
    surfaceFloating: Color(0x12FFFFFF), // white @ ~7%
    surfaceGlassFill: Color(0x14FFFFFF), // white @ ~8%
    surfaceGlassStroke: Color(0x24FFFFFF), // white @ ~14%
    glassFillTop: Color(0x14FFFFFF), // white @ ~8% (matches nav fallback)
    glassFillBottom: Color(0x80121317), // surface @ 50% (matches nav fallback)
    glassStroke: Color(0x24FFFFFF), // white @ ~14%
    glassSheen: Color(0x73FFFFFF), // white @ ~45% — top specular edge
    glassSheetFill: Color(0xB8121317), // surface @ 72% — liquid, forms legible
    strokeSoft: Color(0x1AFFFFFF), // white @ ~10%
    cardBorder: Color(0x0FFFFFFF), // white @ ~6%
    textOnCanvasPrimary: Color(0xFFFFFFFF),
    textOnCanvasSecondary: Color(0xFFC3C8D2), // ~64%
    textOnCanvasMuted: Color(0xFF8D94A2), // ~42%
    ringTrackNeutral: Color(0x1FFFFFFF),
    ringIndeterminate: Color(0x40FFFFFF),
    // --float-shadow (dark): 0 8/28 @ .45 + 0 20/48 @ .30
    floatShadow: [
      BoxShadow(color: Color(0x73000000), blurRadius: 28, offset: Offset(0, 8)),
      BoxShadow(
          color: Color(0x4D000000), blurRadius: 48, offset: Offset(0, 20)),
    ],
    auroraTop: Color(0x3D2E6BFF), // accent @ ~24% — top glow
    auroraA: Color(0x2E2E6BFF), // accent @ ~18%
    auroraB: Color(0x291C4FD0), // brand blue @ ~16%
    grainOpacity: 0.05,
  );

  /// The calm off-white companion. Matches `AppColors.light.bg` so the canvas
  /// is seamless with the ambient scaffold.
  static const MaliTokens light = MaliTokens(
    canvas: Color(0xFFF3F5FA),
    canvasGlowTop: Color(0x122E6BFF), // blue @ ~7%
    canvasGlowSecondary: Color(0x0D1C4FD0), // brand blue @ ~5%
    surfaceRaised: Color(0xFFEEF1F7),
    surfaceFloating: Color(0xFFFFFFFF),
    surfaceGlassFill: Color(0xB8FFFFFF), // white @ ~72%
    surfaceGlassStroke: Color(0x0F0F172A), // ink @ ~6%
    // v2: 78% → 88% (was 52/62% — content ghosted through the tab bar).
    glassFillTop: Color(0xC7FFFFFF), // white @ 78%
    glassFillBottom: Color(0xE0FFFFFF), // white @ 88%
    glassStroke: Color(0x1A0F172A), // ink @ ~10% — definition, not white glow
    glassSheen: Color(0xE6FFFFFF), // white @ ~90% — top specular edge
    glassSheetFill: Color(0xC7FFFFFF), // white @ 78% — liquid, forms legible
    strokeSoft: Color(0xFFD5DBE8),
    // v2: light Group cards carry no border — the e1 shadow is the edge.
    cardBorder: Color(0x00EDF1F7),
    textOnCanvasPrimary: Color(0xFF0C1330),
    textOnCanvasSecondary: Color(0xFF3D4660),
    textOnCanvasMuted: Color(0xFF67708A),
    ringTrackNeutral: Color(0xFFE7ECF5),
    ringIndeterminate: Color(0x330F172A), // ink @ ~20%
    // v2 e1 (#0C1330): 0 1 2 @4% + 0 4 12 @5% — the light Group card edge.
    floatShadow: [
      BoxShadow(color: Color(0x0A0C1330), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x0D0C1330), blurRadius: 12, offset: Offset(0, 4)),
    ],
    auroraTop: Color(0x1A2E6BFF), // accent @ ~10% (subtler in light)
    auroraA: Color(0x142E6BFF), // accent @ ~8%
    auroraB: Color(0x121C4FD0), // brand blue @ ~7%
    grainOpacity: 0.035,
  );

  /// Resolve the set for the ambient theme brightness.
  static MaliTokens of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}
