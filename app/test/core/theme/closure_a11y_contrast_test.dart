import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_theme.dart';

import 'contrast_test.dart' show contrast;

// UX-05 / UX-07 (closure round): WCAG contrast of the text added or changed in
// this round, with the existing colour tokens, on the surfaces it is drawn on.
// Small text, so the bar is 4.5:1.
void main() {
  for (final dark in [false, true]) {
    final theme = dark ? 'dark' : 'light';
    final c = (dark ? AppTheme.dark : AppTheme.light).extension<AppColors>()!;

    final pairs = <String, (Color, List<Color>)>{
      // Account detail hero: "Manually entered balance", white over every
      // stop of the hero gradient (account_hero_surface.dart). White at 80%
      // measured 3.91:1 on the light theme's lightest stop.
      'hero balance-source label': (
        Colors.white,
        dark
            ? const [AppBrandBlue.deep, AppBrandBlue.brand, AppBrandBlue.strong]
            : const [AppBrandBlue.brand, AppBrandBlue.strong, AppBrandBlue.mid],
      ),
      // Accounts list row: "Entered manually" on the row card.
      'accounts row source label': (c.textLight, [c.surface, c.bg]),
      // Account detail: the bank-reported balance caption and time.
      'bank-reported caption': (c.textSecondary, [c.bg, c.surface]),
      // Reports note and Home review card: warning text on the warning fill.
      'pending-review note': (c.warningText, [c.warningBg]),
      // Transaction details: "Move to review" / "Change".
      'details action text': (c.actionText, [c.bg, c.surface]),
    };

    for (final MapEntry(key: name, value: (fg, backgrounds)) in pairs.entries) {
      test('$name is >= 4.5:1 ($theme)', () {
        for (final bg in backgrounds) {
          final ratio = contrast(Color.alphaBlend(fg, bg), bg);
          // ignore: avoid_print
          print('[contrast $theme] $name on $bg: ${ratio.toStringAsFixed(2)}:1');
          expect(ratio, greaterThanOrEqualTo(4.5),
              reason: '$name on $bg: ${ratio.toStringAsFixed(2)}:1');
        }
      });
    }
  }
}
