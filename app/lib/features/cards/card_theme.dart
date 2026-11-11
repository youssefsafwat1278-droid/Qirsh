import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shadows.dart';

/// خيار ثيم تصميم البطاقة: مفتاح ثابت (يُخزَّن على البطاقة) + تسمية + تدرّج.
/// الألوان مُنتقاة لتُقرأ جيدًا مع نص أبيض (النهاية أغمق دائمًا).
class CardThemeOption {
  const CardThemeOption(this.key, this.label, this.colors);

  final String key;

  /// The Arabic name, kept so the catalog stays `const` and so anything
  /// without a BuildContext still has something to show. The UI renders
  /// `cardThemeLabel(context, key)` instead.
  final String label;
  final List<Color> colors; // [البداية، النهاية]
}

/// كتالوج ثيمات البطاقة المنسّق — نظام تصميم واحد، لا فوضى ألوان.
const List<CardThemeOption> kCardThemes = <CardThemeOption>[
  CardThemeOption('navy', 'كحلي', [Color(0xFF3A7BD5), Color(0xFF00185E)]),
  CardThemeOption('emerald', 'زمرّدي', [Color(0xFF34D399), Color(0xFF065F46)]),
  CardThemeOption('plum', 'برقوقي', [Color(0xFFB06AB3), Color(0xFF3B1C5A)]),
  CardThemeOption('sunset', 'غروب', [Color(0xFFFF8A5B), Color(0xFFB0273A)]),
  CardThemeOption('graphite', 'جرافيت', [Color(0xFF4B5563), Color(0xFF111827)]),
  CardThemeOption('ocean', 'محيط', [Color(0xFF2BC0E4), Color(0xFF12507B)]),
];

/// لوحة ألوان مميّزة منسّقة (اختيارية) — hex فقط، بلا اعتماد على أي مكتبة.
const List<String> kCardAccentSwatches = <String>[
  '#F59E0B',
  '#EF4444',
  '#EC4899',
  '#8B5CF6',
  '#3B82F6',
  '#06B6D4',
  '#10B981',
  '#84CC16',
  '#F97316',
  '#14B8A6',
];

/// يعيد خيار الثيم بمفتاحه، أو null (الثيم الافتراضي) إن لم يُطابق.
CardThemeOption? cardThemeByKey(String? key) {
  if (key == null) return null;
  for (final theme in kCardThemes) {
    if (theme.key == key) return theme;
  }
  return null;
}

/// يحوّل نص hex (‎#RRGGBB أو RRGGBB أو AARRGGBB) إلى Color، أو null.
Color? parseAccent(String? hex) {
  if (hex == null) return null;
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return null;
  final value = int.tryParse(h, radix: 16);
  return value == null ? null : Color(value);
}

/// تدرّج البطاقة النهائي: الثيم الافتراضي (بلا مفتاح) = `primaryGradient`؛ ثيم
/// منسّق = تدرّجه؛ ولون مميّز اختياري يطغى على لون النهاية فيظهر تخصيص المستخدم.
Gradient cardGradient(
  BuildContext context, {
  String? themeKey,
  String? accentHex,
}) {
  final accent = parseAccent(accentHex);
  final preset = cardThemeByKey(themeKey);
  if (preset == null) {
    // v2 bank card (spec §3.0 19): brand → action → sky at 135°, identical in
    // both themes (the card is always-dark imagery).
    const base = LinearGradient(
      begin: AlignmentDirectional.topStart,
      end: AlignmentDirectional.bottomEnd,
      colors: [AppBrandBlue.brand, AppBrandBlue.mid, AppBrandBlue.light],
    );
    if (accent == null) return base;
    return LinearGradient(
      begin: base.begin,
      end: base.end,
      colors: [base.colors.first, accent],
    );
  }
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: accent == null ? preset.colors : [preset.colors.first, accent],
  );
}

/// v2 bank-card lift (spec §3.0 19): `heroGlow` on the dark canvas, a navy
/// drop shadow `0 16 32 #022686@28%` on the light one.
List<BoxShadow> bankCardShadow(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? AppShadows.heroGlow
        : const [
            BoxShadow(
                color: Color(0x47022686), blurRadius: 32, offset: Offset(0, 16)),
          ];

/// The EMV chip's gold gradient (`gold.lit → gold → gold.deep`).
const LinearGradient bankCardChipGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [AppBrandAccent.goldLit, AppBrandAccent.gold, AppBrandAccent.goldDeep],
);
