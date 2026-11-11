import 'package:flutter/material.dart';

/// AppShadows — Centralized, subtle, premium shadow system.
class AppShadows {
  AppShadows._();

  /// card - Subtle drop shadow for resting cards in light mode.
  static const List<BoxShadow> card = [
    BoxShadow(
      color: Color(0x0F101828),
      blurRadius: 14,
      offset: Offset(0, 2),
    ),
  ];

  /// elevatedCard - Premium card lift for summary panels and selected states.
  static const List<BoxShadow> elevatedCard = [
    BoxShadow(
      color: Color(0x14101828),
      blurRadius: 24,
      offset: Offset(0, 10),
    ),
  ];

  /// sheet - Controlled depth for modal and bottom-sheet surfaces.
  static const List<BoxShadow> sheet = [
    BoxShadow(
      color: Color(0x29101828),
      blurRadius: 34,
      offset: Offset(0, -10),
    ),
  ];

  /// floatingNav - Soft lift for persistent navigation surfaces.
  static const List<BoxShadow> floatingNav = [
    BoxShadow(
      color: Color(0x1A101828),
      blurRadius: 28,
      offset: Offset(0, 12),
    ),
  ];

  /// ctaGlow - Gold glow for primary actions.
  static const List<BoxShadow> ctaGlow = [
    BoxShadow(
      color: Color(0x44FBC926),
      blurRadius: 18,
      offset: Offset(0, 8),
    ),
  ];

  // Legacy aliases
  static const List<BoxShadow> float = elevatedCard;
  static const List<BoxShadow> nav = floatingNav;
  static const List<BoxShadow> cta = ctaGlow;

  // ===== Calm Capital v2 light elevation ladder (colour #0C1330) =====
  // Dark static cards carry NO shadow (invisible on true black); in light
  // the shadow is the separation. Use [group]/[raised]/[floating] which
  // resolve per brightness.

  /// e1 — Group cards.
  static const List<BoxShadow> e1 = [
    BoxShadow(color: Color(0x0A0C1330), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0D0C1330), blurRadius: 12, offset: Offset(0, 4)),
  ];

  /// e2 — raised cards, sticky dock.
  static const List<BoxShadow> e2 = [
    BoxShadow(color: Color(0x0A0C1330), blurRadius: 4, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x140C1330), blurRadius: 28, offset: Offset(0, 12)),
  ];

  /// e3 — menus, sheets, floating tab bar.
  static const List<BoxShadow> e3 = [
    BoxShadow(color: Color(0x0F0C1330), blurRadius: 16, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x1F0C1330), blurRadius: 48, offset: Offset(0, 24)),
  ];

  /// Primary button lift (light only): 0 6 16 #155DFC @28%.
  static const List<BoxShadow> actionLift = [
    BoxShadow(color: Color(0x47155DFC), blurRadius: 16, offset: Offset(0, 6)),
  ];

  static const List<BoxShadow> none = <BoxShadow>[];

  static List<BoxShadow> group(Brightness b) =>
      b == Brightness.dark ? none : e1;
  static List<BoxShadow> raised(Brightness b) =>
      b == Brightness.dark ? none : e2;
  static List<BoxShadow> floating(Brightness b) =>
      b == Brightness.dark ? floatSoft : e3;

  // ===== Mali flagship system (docs/MALI_DESIGN_SYSTEM.md) =====
  // Additive only — nothing above is modified or retired.

  /// floatSoft - Ambient grounding for a surface floating on a dark canvas.
  /// Two-layer: a soft key shadow plus a faint wide ambient falloff, so depth
  /// reads without a harsh edge.
  static const List<BoxShadow> floatSoft = [
    BoxShadow(
      color: Color(0x33000000),
      blurRadius: 28,
      offset: Offset(0, 8),
    ),
    BoxShadow(
      color: Color(0x14000000),
      blurRadius: 48,
      offset: Offset(0, 20),
    ),
  ];

  /// heroGlow - Restrained colored glow for the small set of flagship accent
  /// surfaces (AI insight, selected states). Never applied to the balance
  /// hero itself, which stays directly on canvas — see design doc §0.
  static const List<BoxShadow> heroGlow = [
    BoxShadow(
      color: Color(0x332E6BFF), // accent @ 20% — softened (calm, not neon)
      blurRadius: 32,
      offset: Offset(0, 10),
    ),
  ];
}
