/// AppSpacing — the design system's spacing ladder.
///
/// Steps 1–7 are `--sp-1`..`--sp-7` from the prototype, verbatim:
/// **4 / 8 / 12 / 16 / 20 / 26 / 34**. The first five already agreed; s6 and s7
/// were 24 and 32 and are now the design's 26 and 34.
///
/// Steps 8–10 have no counterpart in the prototype, whose ladder stops at
/// seven. They are kept for the few page-level gaps that need more than 34 and
/// are left on the 8pt grid.
class AppSpacing {
  AppSpacing._();

  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20;
  // v2: back on the 4pt grid (were the prototype's 26 / 34).
  static const double s6 = 24;
  static const double s7 = 32;
  static const double s8 = 40;
  static const double s9 = 48;
  static const double s10 = 64;

  // Semantic spacing — Compact UI system (docs/MALI_COMPACT_UI_SYSTEM_PLAN.md).
  // Evolved toward ~25–35% less vertical whitespace; every screen inherits these.
  // v2: gutter 20 so section titles and card edges share one line.
  static const double pagePadding = s5; // 20
  static const double pagePaddingCompact = s4; // 16
  static const double sectionGap = s7; // v2: 32
  static const double sectionGapCompact = s4; // 16 (was 20)
  static const double listGap = s3; // 12
  static const double cardPadding = 16; // (was 20)
  static const double cardPaddingCompact = 14; // simple/short cards
  static const double cardPaddingLarge = s5; // 20 (was 24)
  static const double chipPadding = s3;
  static const double chipGap = s2;
  static const double fieldGap = s3; // 12 (was 16)
  static const double iconGap = s3;
  static const double buttonGap = s3;
  static const double buttonHeight = 52; // v2 QButton
  static const double buttonHeightCompact = 46; // (was 48) — ≥ 44 accessible
  static const double sheetPadding = s5; // 20 (was 24)
  static const double sheetTopGap = s3; // 12 (was 16)

  // Component density tokens (Compact UI system).
  static const double avatar =
      40; // standard avatar / leading tile (hero, rows)
  static const double avatarSm = 32; // compact avatar (dense chips, sub-rows)
  static const double avatarLg = 56; // hero / detail-screen tile
  static const double headerTopInset = 44; // CalmPageHeader top (was 64)
  static const double rowPaddingV =
      11; // list-row vertical padding (≈ 58–62px row)
  /// `.bnav { height:60px }`. Its buttons are 52 tall inside it, and it sits on
  /// a 16pt inset from the screen edges and the bottom — see [navBarInset].
  static const double navBarHeight = 64; // v2 QTabBar

  /// `.bnav { inset-inline:16px; bottom:16px }`.
  static const double navBarInset = s4;

  /// `.bnav button { height:52px }`.
  static const double navBarItemHeight = 52;

  /// `.fab { width:48px;height:48px }`.
  static const double fabSize = 48;

  // Legacy aliases
  static const double gutter = pagePadding;
  static const double screenPadding = pagePadding;
}

/// AppRadius — Standardized border radii.
class AppRadius {
  AppRadius._();

  // The prototype's radius ladder: `--r-xs`..`--r-2xl`.
  // 8 / 12 / 16 / 22 / 26 / 32. `xs` keeps 4 for hairline chips and
  // progress tracks, which the prototype rounds with `--r-pill` instead.
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 22;
  static const double xxl = 26;
  // Mali flagship system (docs/MALI_DESIGN_SYSTEM.md) — flagship surfaces
  // (hero, top-level MaliCard) that want a more generous, calmer curve.
  static const double xxxl = 32;
  static const double pill = 999;
  static const double full = 9999;

  // Explicit semantic tokens
  static const double extraSmall = xs;
  static const double small = sm;
  static const double medium = md;
  static const double large = lg;
  static const double xlarge = xl;

  // ── The refinement-pass ladder ────────────────────────────────────────
  // The prototype re-declares four semantic radii AFTER the base ladder,
  // deliberately: "a radius ladder instead of one 28-32px rounding
  // everywhere". These are the ones components actually use, so they are
  // pinned to the design's values rather than aliased onto the base scale.

  /// `--r-ctl: 9px` — small controls and `.btn.sm`.
  static const double control = 10;

  /// `--r-row: 13px` — `.btn` and standalone rows.
  static const double row = 14;

  /// `--r-card: 18px` — `.card`, `.grp`, `.lgrp`, `.strip`, `.ledger`, `.rank`.
  static const double card = 20;

  /// `--r-sheet: 28px` — the modal sheet's top corners.
  static const double sheet = 28;

  /// `.screen>.sheet { border-radius:34px 34px 0 0 }` — the white panel that
  /// rises over the hero. A different curve from the modal sheet, on purpose.
  static const double screenSheet = 28; // v2: hero/sheet radius 28

  /// `.screen>.hero:not(.tall) { border-end-*-radius:30px }`.
  static const double heroBottom = 28;

  static const double cardLg = xxl;
  static const double button = row;
  static const double chip = pill;

  /// `.bnav { border-radius:var(--r-pill) }` — the nav is a pill, not a
  /// rounded rectangle.
  static const double nav = pill;
}
