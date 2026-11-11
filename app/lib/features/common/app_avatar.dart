import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/category_glyph.dart';
import '../../core/utils/category_tone.dart';
import '../../core/utils/category_palette.dart';
import '../cards/brand_mark.dart';
import 'category_catalog.dart';

/// نبرة التايل لما يكون أيقونة: [solid] لون ممتلئ وأيقونة بيضا، [soft] نفس
/// اللون بشفافية وأيقونة بلونه.
enum AppAvatarTone { solid, soft }

/// التايل المربّع الوحيد في التطبيق — براند / تصنيف / أيقونة.
///
/// كل الشاشات بتستخدمه بدل ما كل شاشة ترسم `Container` بمقاسها ونصف قطرها
/// ولونها. الشكل واحد: سوبر-إليبس (شكل أيقونات iOS) بنصف قطر = المقاس × 0.3،
/// والمقاسات من [AppSpacing] (`avatarSm` 32 / `avatar` 40 / `avatarLg` 56).
class AppAvatar extends StatelessWidget {
  /// شعار علامة تجارية — بيرجع لحرف/تصنيف تلقائيًا لو مفيش شعار.
  const AppAvatar.brand({
    super.key,
    required String name,
    String? logoUrl,
    Widget? fallback,
    this.size = AppSpacing.avatar,
  })  : _brandName = name,
        _logoUrl = logoUrl,
        _fallback = fallback,
        _category = null,
        _iconName = null,
        _label = null,
        _icon = null,
        _color = null,
        _tone = AppAvatarTone.solid;

  /// تايل تصنيف — إيموجي التصنيف على خلفية لونه الهادئة، أو أول حرف من
  /// [merchantName].
  ///
  /// The tone is SOFT, per the design prototype: a category tile is
  /// `.icobox { background: var(--c-food-bg); color: var(--c-food-ink) }` — a
  /// pale tint of the category's own colour, not the colour itself. Solid
  /// tiles rendered as dark brown/olive blocks down the ledger and the budget
  /// list, which is heavier than the design and fights the category emoji
  /// sitting on top of them.
  ///
  /// [merchantName] initials keep the solid treatment, because a letter needs
  /// a filled tile to read as a tile at all — see [build].
  const AppAvatar.category({
    super.key,
    CategoryView? category,
    String? iconName,
    String? merchantName,
    Color? color,
    this.size = AppSpacing.avatar,
  })  : _brandName = null,
        _logoUrl = null,
        _fallback = null,
        _category = category,
        _iconName = iconName,
        _label = merchantName,
        _icon = null,
        _color = color,
        _tone = AppAvatarTone.soft;

  /// تايل أيقونة عام (إعدادات، حالات، إجراءات).
  const AppAvatar.icon({
    super.key,
    required IconData icon,
    Color? color,
    AppAvatarTone tone = AppAvatarTone.solid,
    this.size = AppSpacing.avatar,
  })  : _brandName = null,
        _logoUrl = null,
        _fallback = null,
        _category = null,
        _iconName = null,
        _label = null,
        _icon = icon,
        _color = color,
        _tone = tone;

  final String? _brandName;
  final String? _logoUrl;
  final Widget? _fallback;
  final CategoryView? _category;
  final String? _iconName;
  final String? _label;
  final IconData? _icon;
  final Color? _color;
  final AppAvatarTone _tone;

  final double size;

  /// شكل التايل الموحّد — يُستخدم كمان في [BrandMark] عشان الاتنين يقروا واحد.
  static ShapeBorder shapeFor(double size, {BorderSide side = BorderSide.none}) =>
      RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(size * 0.3),
        side: side,
      );

  /// v2 (light): every white logo tile carries a 1px stroke.soft edge so
  /// bare glyphs keep the same footprint on white cards.
  static BorderSide logoEdge(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light
          ? const BorderSide(color: Color(0xFFD5DBE8))
          : BorderSide.none;

  @override
  Widget build(BuildContext context) {
    if (_brandName != null) {
      return BrandMark(
          name: _brandName, logoUrl: _logoUrl, size: size, fallback: _fallback);
    }

    final c = context.colors;
    final resolvedIconName = _iconName ?? _category?.iconName;
    final initial = _initial(_label);
    final tileColor = _icon != null
        ? (_color ?? c.primary)
        : resolvedIconName != null
            ? categoryTileColor(resolvedIconName)
            : (_color ?? _category?.color ?? c.primary);
    // An initial is white-on-colour and needs the filled tile to stay legible;
    // a glyph sits on the tint. Without this the merchant initials in the
    // ledger dropped to white-on-pale.
    final isSoft = _tone == AppAvatarTone.soft && initial == null;

    // `.icobox` — the design's per-family background/ink pair for this theme.
    // A single colour at low alpha cannot express it: the dark pair LIGHTENS
    // the ink and darkens the ground, and `categoryTileColor` already returns
    // near-black values, so 12% of one on a black canvas was invisible.
    final tone = resolvedIconName == null
        ? null
        : categoryTone(resolvedIconName, Theme.of(context).brightness);

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: isSoft
            ? (tone?.background ??
                // The prototype's `iconTile`: 12% of the hue, 22% on dark.
                tileColor.withValues(
                    alpha: Theme.of(context).brightness == Brightness.dark
                        ? 0.22
                        : 0.12))
            : tileColor,
        shape: shapeFor(size),
      ),
      child: _icon != null
          ? Icon(
              _icon,
              color: isSoft ? tileColor : Colors.white,
              size: size * 0.46,
            )
          : initial != null
              ? Text(
                  initial,
                  textDirection: TextDirection.ltr,
                  style: AppTypography.title2(Colors.white).copyWith(
                    fontSize: size * 0.40,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : CategoryGlyph(
                  name: resolvedIconName ?? 'receipt-text',
                  size: size * 0.46,
                  color: isSoft
                      ? (tone?.ink ?? tileColor)
                      : Colors.white,
                ),
    );
  }

  static String? _initial(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return null;
    return text.characters.first.toUpperCase();
  }
}
