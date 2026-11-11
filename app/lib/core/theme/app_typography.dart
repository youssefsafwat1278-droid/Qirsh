import 'dart:ui';

import 'package:flutter/material.dart';

/// الطباعة — Arabic-first premium typography for Qirsh.
class AppTypography {
  AppTypography._();

  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  /// The BUNDLED primary family (pubspec `fonts:`) — no runtime GoogleFonts
  /// fetch, so the intended typography renders on the first offline launch.
  ///
  /// **Vazirmatn (OFL)**, because the design prototype asks for it first:
  /// `--f: "Vazirmatn Local","Vazirmatn","SF Arabic",…`. It was previously the
  /// FALLBACK behind IBM Plex Sans Arabic — bundled, licensed and weight-mapped,
  /// but never actually the face anyone saw. All four weights
  /// (400/500/600/700) are already in `assets/fonts/`, so this is a family
  /// swap and not a new asset.
  static const String fontFamily = 'Vazirmatn';

  /// Bundled fallbacks for whatever Vazirmatn lacks.
  static const List<String> _fontFallback = ['IBMPlexSansArabic', 'Alexandria'];

  /// Canonical app text style. **Vazirmatn** (bundled) supplies both the Arabic
  /// and Latin glyphs — it is [fontFamily], the family the design prototype
  /// names first. IBM Plex Sans Arabic + Alexandria are the bundled fallbacks
  /// ([_fontFallback]).
  ///
  /// NOTE — the PDF report renderer still draws with IBM Plex Sans Arabic
  /// (`features/reporting/pdf/report_fonts.dart`), so the exported report and
  /// the screen no longer share a face. That is recorded as an open delta in
  /// `V1_UI_REDESIGN_MAPPING_2026-09-18.md` rather than changed here: the PDF
  /// is a separate rendering pipeline with its own layout metrics, and
  /// swapping its face is a change to exported documents, not to the app's
  /// screens.
  ///
  /// This comment previously said the reverse — that Vazirmatn was primary and
  /// IBM Plex a fallback — which contradicted the two constants directly above
  /// it and misled a reader into reporting the wrong family. Kept accurate
  /// deliberately: a comment that disagrees with its own file is worse than no
  /// comment.
  /// This is a plain [TextStyle] over the bundled family — identical size /
  /// weight / height / letter-spacing / colour / shadows / tabular figures as
  /// before, only the font source changed (runtime fetch → bundled).
  static TextStyle custom({
    required double size,
    required FontWeight weight,
    required double height,
    double letterSpacing = 0,
    bool tabular = false,
    Color? color,
    List<Shadow>? shadows,
  }) {
    return TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: _fontFallback,
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
      shadows: shadows,
      fontFeatures: tabular ? _tabular : null,
    );
  }

  // ===== Premium Named Styles =====

  /// v2 display family — Alexandria 600/700, for `title.large` and
  /// `amount.hero` ONLY.
  static const String displayFamily = 'Alexandria';

  static TextStyle _displayFace({
    required double size,
    required FontWeight weight,
    required double height,
    double letterSpacing = 0,
    bool tabular = false,
    Color? color,
  }) =>
      custom(
        size: size,
        weight: weight,
        height: height,
        letterSpacing: letterSpacing,
        tabular: tabular,
        color: color,
      ).copyWith(
        fontFamily: displayFamily,
        fontFamilyFallback: const ['Vazirmatn', 'IBMPlexSansArabic'],
      );

  /// v2 `amount.hero` — Alexandria 600, 48/52, −1.2.
  static TextStyle amountHero(Color c) => _displayFace(
      size: 48,
      weight: FontWeight.w600,
      height: 52 / 48,
      letterSpacing: -1.2,
      tabular: true,
      color: c);

  /// v2 `amount.large` — 32/38, −0.4.
  static TextStyle amountLarge(Color c) => custom(
      size: 32,
      weight: FontWeight.w700,
      height: 38 / 32,
      letterSpacing: -0.4,
      tabular: true,
      color: c);

  /// v2 `amount.medium` — 22/28.
  static TextStyle amountMedium(Color c) => custom(
      size: 22, weight: FontWeight.w700, height: 28 / 22, tabular: true, color: c);

  /// v2 `amount.row` — 17/22.
  static TextStyle amountSmall(Color c) => custom(
      size: 17, weight: FontWeight.w600, height: 22 / 17, tabular: true, color: c);

  /// v2 `title.large` — Alexandria 700, 30/38, −0.3.
  static TextStyle titleLarge(Color c) => _displayFace(
      size: 30,
      weight: FontWeight.w700,
      height: 38 / 30,
      letterSpacing: -0.3,
      color: c);

  /// v2 `title.nav` — collapsed nav-bar title, 17/22.
  static TextStyle titleNav(Color c) =>
      custom(size: 17, weight: FontWeight.w600, height: 22 / 17, color: c);

  /// v2 `overline` — group labels and chart axes only, 12/16 +0.2.
  static TextStyle overline(Color c) => custom(
      size: 12,
      weight: FontWeight.w600,
      height: 16 / 12,
      letterSpacing: 0.2,
      color: c);

  // UX-002 — the scale below follows `docs/design/BRAND_AND_DESIGN_SYSTEM.md` §7 with ONE
  // deliberate deviation: sizes for Display / Title-1 / Title-2 are one step
  // SMALLER than the spec (32/24/20 rather than 34/28/22).
  //
  // That deviation predates Phase J and is kept, because the owner's density
  // brief asks for a more compact, professional feel and these are the styles
  // that dominate perceived bulk. Weights, however, had drifted HEAVIER than
  // the spec (w700 where it says SemiBold 600, w600 where it says Medium 500);
  // those are corrected here, which serves the spec and the density goal at the
  // same time — heavy type reads as large type.
  static TextStyle display(Color c) =>
      custom(size: 32, weight: FontWeight.w700, height: 1.06, color: c);

  static TextStyle title1(Color c) =>
      custom(size: 24, weight: FontWeight.w600, height: 1.18, color: c);

  static TextStyle title2(Color c) =>
      custom(size: 20, weight: FontWeight.w600, height: 1.24, color: c);

  static TextStyle headline(Color c) =>
      custom(size: 18, weight: FontWeight.w600, height: 1.30, color: c);

  static TextStyle title(Color c) =>
      custom(size: 16, weight: FontWeight.w600, height: 1.40, color: c);

  // v2: Arabic body needs ≥1.6 line height (16/26).
  static TextStyle body(Color c) =>
      custom(size: 16, weight: FontWeight.w400, height: 26 / 16, color: c);

  static TextStyle bodyStrong(Color c) =>
      custom(size: 16, weight: FontWeight.w500, height: 1.50, color: c);

  static TextStyle callout(Color c) =>
      custom(size: 15, weight: FontWeight.w400, height: 24 / 15, color: c);

  static TextStyle subhead(Color c) =>
      custom(size: 14, weight: FontWeight.w500, height: 1.43, color: c);

  static TextStyle footnote(Color c) =>
      custom(size: 13, weight: FontWeight.w400, height: 1.38, color: c);

  // v2: 13 is the floor for Arabic UI text.
  static TextStyle caption(Color c) =>
      custom(size: 13, weight: FontWeight.w500, height: 18 / 13, color: c);

  static TextStyle label(Color c) =>
      custom(size: 12, weight: FontWeight.w600, height: 1.25, color: c);

  static TextStyle micro(Color c) =>
      custom(size: 12, weight: FontWeight.w500, height: 16 / 12, color: c);

  /// The MONOSPACED family, `--f-mono` in the design prototype.
  ///
  /// IBM Plex Mono (bundled, OFL). Used ONLY where the design calls for
  /// technical/monospaced copy — card-network badges, build and version lines,
  /// report page numbers and rank positions. It is not a body face and must not
  /// become one: it has no Arabic.
  static const String monoFontFamily = 'IBMPlexMono';

  /// Arabic falls through to the UI family.
  ///
  /// IBM Plex Mono is Latin-only. The design's own card-network badge renders
  /// «مدى» in it, so without this fallback an Arabic network name would render
  /// as tofu — the exact failure the mono face invites. Vazirmatn first so
  /// Arabic mono copy matches the rest of the interface.
  static const List<String> _monoFallback = <String>[
    'Vazirmatn',
    'IBMPlexSansArabic',
    'Alexandria',
  ];

  /// Technical/monospaced copy. [tabular] defaults ON — a monospaced string in
  /// this app is nearly always a number, an id or a code, and proportional
  /// figures in a mono face defeat the point of choosing one.
  static TextStyle mono({
    required double size,
    FontWeight weight = FontWeight.w400,
    double height = 1.30,
    double letterSpacing = 0,
    bool tabular = true,
    Color? color,
  }) {
    return TextStyle(
      fontFamily: monoFontFamily,
      fontFamilyFallback: _monoFallback,
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
      fontFeatures:
          tabular ? const [FontFeature.tabularFigures()] : const <FontFeature>[],
    );
  }

  // ===== Mali flagship "calm" scale (docs/MALI_DESIGN_SYSTEM.md) =====
  // Additive only. The existing amountHero/display/w800 styles above are
  // untouched and remain in active use across the app — do not remove them.
  // These calm tokens cap weight at w600/w700 and tighten tracking on large
  // numbers, per the flagship spec. Adopted intentionally, screen by screen.

  /// The Home balance statement — large, calm, tight tracking, tabular.
  static TextStyle balanceHero(Color c) => amountHero(c);

  /// Calmer alternative to [display] — same role, capped at w600.
  static TextStyle calmDisplay(Color c) => titleLarge(c);

  /// Calmer alternative to [title1]/section titles — capped at w600.
  static TextStyle calmTitle(Color c) =>
      custom(size: 22, weight: FontWeight.w600, height: 1.20, color: c);

  /// Compact section heading (docs/MALI_COMPACT_UI_SYSTEM_PLAN.md) — replaces
  /// oversized `headline`(18)/`title2`(20) misuse on section titles.
  static TextStyle sectionTitle(Color c) =>
      custom(size: 20, weight: FontWeight.w700, height: 26 / 20, color: c);

  /// Compact card / list-group title (also empty/error headings and default
  /// amount text). One step below a section title.
  static TextStyle cardTitle(Color c) =>
      custom(size: 16, weight: FontWeight.w600, height: 22 / 16, color: c);

  /// Plain-language verdict line for a RingProgress (e.g. "وضعك مستقر").
  /// Deliberately body-weight, not a headline — the ring carries the visual
  /// weight, the sentence explains it.
  static TextStyle verdict(Color c) =>
      custom(size: 17, weight: FontWeight.w500, height: 1.40, color: c);

  /// يبني [TextTheme] كامل بلون النص الأساسي.
  static TextTheme textTheme(Color main) => TextTheme(
        displayLarge: display(main),
        displayMedium: custom(
          size: 28,
          weight: FontWeight.w700,
          height: 1.08,
          color: main,
        ),
        displaySmall: custom(
          size: 24,
          weight: FontWeight.w700,
          height: 1.08,
          color: main,
        ),
        headlineLarge: title1(main),
        headlineMedium: title2(main),
        headlineSmall: headline(main),
        titleLarge: headline(main),
        titleMedium: title(main),
        titleSmall: subhead(main),
        bodyLarge: body(main),
        bodyMedium: callout(main),
        bodySmall: footnote(main),
        labelLarge: subhead(main),
        labelMedium: label(main),
        labelSmall: micro(main),
      );
}
