import 'package:flutter/widgets.dart';

/// The design system's category colour families, per theme.
///
/// The prototype defines five: `--c-food`, `--c-move`, `--c-bill`, `--c-shop`,
/// `--c-in`. Each carries a BACKGROUND and an INK, and — this is the part that
/// matters — the two are different colours in light and dark, not one colour at
/// two opacities:
///
/// ```
/// --c-food-bg:  #FDF0E7 (light)   #2C1E12 (dark)
/// --c-food-ink: #C9541A (light)   #F0A868 (dark)
/// ```
///
/// Dark mode LIGHTENS the ink and darkens the ground. A single colour at low
/// alpha cannot do that: `categoryTileColor` returns values like `#2C1E12`,
/// which is itself the design's dark background, and at 12% opacity on a black
/// canvas it is invisible. Measured on device — the ledger's fuel and shopping
/// glyphs were barely legible in dark mode, which is what this file fixes.
class CategoryTone {
  const CategoryTone(this.background, this.ink);

  /// The tile's fill — `--c-*-bg`.
  final Color background;

  /// The glyph's colour — `--c-*-ink`.
  final Color ink;
}

enum _Family { food, move, bill, shop, income, neutral }

/// Which design family an icon belongs to.
///
/// The prototype names five families and the app ships twenty-nine icons, so
/// the rest resolve to the nearest family by meaning rather than inventing new
/// colours: a gym and a clinic are things you pay for (bill), a plane and a
/// hotel are movement, a cigarette and a haircut are shopping.
_Family _familyFor(String icon) {
  switch (icon) {
    case 'utensils-crossed':
    case 'coffee':
    case 'cake':
      return _Family.food;
    case 'car-taxi-front':
    case 'fuel':
    case 'plane':
    case 'hotel':
      return _Family.move;
    case 'receipt-text':
    case 'repeat':
    case 'shield-check':
    case 'wrench':
    case 'house':
    case 'heart-pulse':
    case 'graduation-cap':
    case 'dumbbell':
      return _Family.bill;
    case 'shopping-bag':
    case 'shopping-basket':
    case 'gift':
    case 'scissors':
    case 'baby':
    case 'dog':
    case 'cigarette':
    case 'clapperboard':
      return _Family.shop;
    case 'banknote':
    case 'piggy-bank':
    case 'arrow-left-right':
    case 'heart-handshake':
      return _Family.income;
    default:
      return _Family.neutral;
  }
}

/// The background/ink pair for [icon] in the given [brightness], straight from
/// the prototype's `:root` and `:root[data-theme="dark"]` blocks.
CategoryTone categoryTone(String icon, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  // Calm Capital v2 (spec §2.1): the six headline categories use the v2
  // palette — ink at 100%, tile = the colour @16% (dark) / @12% (light) over
  // the card surface.
  final v2 = _v2Ink[icon];
  if (v2 != null) {
    final ink = Color(dark ? v2[0] : v2[1]);
    final ground = dark ? const Color(0xFF121317) : const Color(0xFFFFFFFF);
    return CategoryTone(
      Color.alphaBlend(ink.withValues(alpha: dark ? .16 : .12), ground),
      ink,
    );
  }
  switch (_familyFor(icon)) {
    case _Family.food:
      return dark
          ? const CategoryTone(Color(0xFF2C1E12), Color(0xFFF0A868))
          : const CategoryTone(Color(0xFFFDF0E7), Color(0xFFC9541A));
    case _Family.move:
      return dark
          ? const CategoryTone(Color(0xFF15263A), Color(0xFF7FBEF5))
          : const CategoryTone(Color(0xFFE6F1FC), Color(0xFF1568B6));
    case _Family.bill:
      return dark
          ? const CategoryTone(Color(0xFF2B1E45), Color(0xFFB49CFF))
          : const CategoryTone(Color(0xFFF0ECFF), Color(0xFF6641F0));
    case _Family.shop:
      return dark
          ? const CategoryTone(Color(0xFF33192A), Color(0xFFF591BC))
          : const CategoryTone(Color(0xFFFCE9F1), Color(0xFFB32456));
    case _Family.income:
      return dark
          ? const CategoryTone(Color(0xFF0E2A18), Color(0xFF22C55E))
          : const CategoryTone(Color(0xFFE1F3EC), Color(0xFF12855C));
    case _Family.neutral:
      // `--qirsh-blue-wash` / `--qirsh-blue`, which is what the prototype uses
      // for an icon box with no category of its own.
      return dark
          ? const CategoryTone(Color(0xFF0E1D33), Color(0xFF9DB9FF))
          : const CategoryTone(Color(0xFFEAF0FE), Color(0xFF0336BF));
  }
}

/// v2 category palette by icon key: [dark, light].
const Map<String, List<int>> _v2Ink = {
  'shopping-bag': [0xFFA78BFA, 0xFF7C4DDB],
  'shopping-basket': [0xFF5EC8E5, 0xFF0E94B8],
  'utensils-crossed': [0xFFFF8A5B, 0xFFE0622B],
  'coffee': [0xFFD4A373, 0xFF9C6B3F],
  'car-taxi-front': [0xFF6E9BFF, 0xFF2F6BE0],
  'repeat': [0xFFF472B6, 0xFFD0398A],
};
