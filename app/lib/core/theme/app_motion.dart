import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'dart:math' as math;

/// AppMotion — Centralized motion durations and curves for Qirsh.
class AppMotion {
  AppMotion._();

  // Durations
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 360);
  static const Duration emphasized = Duration(milliseconds: 480);
  static const Duration buttonPress = Duration(milliseconds: 90);
  static const Duration cardReveal = Duration(milliseconds: 280);
  static const Duration sheetEnter = Duration(milliseconds: 320);
  static const Duration sheetExit = Duration(milliseconds: 220);

  // Curves
  static const Curve standardCurve = Curves.easeOutCubic;
  static const Curve emphasizedCurve = Curves.easeInOutCubic;
  static const Curve sheetCurve = Curves.easeOutQuart;
  static const Curve buttonCurve = Curves.easeOut;
  static const Curve cardRevealCurve = Curves.easeOutCubic;

  // Specific timings
  static const Duration numberCountUp = Duration(milliseconds: 650);
  static const Duration chartAnimation = Duration(milliseconds: 800);

  // ===== Calm Capital v2 motion language (spec §2.5) =====
  static const Duration press = buttonPress; // 90
  static const Duration micro = Duration(milliseconds: 140);
  static const Duration base = normal; // 220
  static const Duration moderate = Duration(milliseconds: 320);
  static const Duration slowV2 = emphasized; // 480
  static const Duration shimmer = Duration(milliseconds: 1200);

  /// Enter rise distance (pt) and sibling stagger.
  static const double enterRise = 12;
  static const Duration stagger = Duration(milliseconds: 40);
  static const Duration rowStagger = Duration(milliseconds: 24);

  /// Count-up duration scaled by magnitude: clamp(500 + 100·log10|v|, 500, 900).
  static Duration countFor(num value) {
    final v = value.abs();
    final ms = v < 1 ? 500 : (500 + 100 * (math.log(v) / math.ln10));
    return Duration(milliseconds: ms.clamp(500, 900).round());
  }

  /// expo-out — all entrances, count-up, chart draw.
  static const Curve easeOut = Cubic(0.16, 1, 0.3, 1);

  /// On-screen moves A→B.
  static const Curve easeInOut = Cubic(0.65, 0, 0.35, 1);

  /// Exits (always 0.7× the enter duration).
  static const Curve easeExit = Cubic(0.4, 0, 1, 1);

  /// Press scales.
  static const double pressScaleButton = 0.97;
  static const double pressScaleRow = 0.985;
  static const double pressScaleIcon = 0.90;

  // Springs (mass / stiffness / damping).
  static const SpringDescription springSnappy =
      SpringDescription(mass: 1, stiffness: 520, damping: 36);
  static const SpringDescription springSmooth =
      SpringDescription(mass: 1, stiffness: 300, damping: 30);
  static const SpringDescription springLively =
      SpringDescription(mass: 1, stiffness: 380, damping: 22);
  static const SpringDescription springGentle =
      SpringDescription(mass: 1, stiffness: 170, damping: 26);

  /// Curve approximations of the springs, for implicit animations
  /// (AnimatedContainer, AnimatedAlign…) that take a [Curve].
  static const Curve springSnappyCurve = Cubic(0.2, 0.9, 0.3, 1);
  static const Curve springSmoothCurve = Cubic(0.25, 1, 0.4, 1);
  static const Curve springLivelyCurve = Cubic(0.34, 1.36, 0.64, 1);
  static const Curve springGentleCurve = Cubic(0.22, 1, 0.36, 1);
}
