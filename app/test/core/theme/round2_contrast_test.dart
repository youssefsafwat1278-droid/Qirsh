import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/common/app_status_pill.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../features/common/primary_screen_harness.dart';
import 'contrast_test.dart' show contrast;

/// The colour a text widget is painted in, and the nearest filled box behind
/// it (the surface the WCAG ratio is measured against).
(Color, Color) _pair(WidgetTester tester, Finder text) {
  final paragraph = tester.widget<RichText>(
      find.descendant(of: text, matching: find.byType(RichText)).first);
  final fg = paragraph.text.style!.color!;
  final element = tester.element(text);
  Color? bg;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    final decoration = switch (widget) {
      Container(:final decoration?) => decoration,
      AnimatedContainer(:final decoration?) => decoration,
      DecoratedBox(:final decoration) => decoration,
      _ => null,
    };
    if (decoration is BoxDecoration && decoration.color != null) {
      bg = decoration.color;
      return false;
    }
    return true;
  });
  return (fg, bg!);
}

Color _over(Color top, Color bottom) => Color.alphaBlend(top, bottom);

// UX-07 (round 2): text that rendered below 4.5:1 on the screens' own
// surfaces, measured on the rendered widgets.
void main() {
  for (final dark in [false, true]) {
    final theme = dark ? 'dark' : 'light';

    testWidgets('success status pill text is >= 4.5:1 ($theme)', (tester) async {
      await tester.pumpWidget(MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          home: const Scaffold(
              body: Center(
                  child: AppStatusPill(
                      label: 'Confirmed', tone: AppStatusTone.success)))));
      final (fg, bg) = _pair(tester, find.text('Confirmed'));
      expect(contrast(fg, bg), greaterThanOrEqualTo(4.5),
          reason: '${contrast(fg, bg).toStringAsFixed(2)}:1');
    });

    testWidgets('budgets "On track" chip text is >= 4.5:1 ($theme)',
        (tester) async {
      await pumpPrimaryScreen(
          tester, primaryScreens.firstWhere((s) => s.name == 'Budgets'),
          size: const Size(390, 844), language: 'en', dark: dark);
      stopCollectingErrors();
      final l10n = AppL10n.of(tester.element(find.byType(Scaffold).first));
      for (final label in [l10n.bdgStateSafeF, '1']) {
        final text = label == '1'
            // The count above the label shares its colour.
            ? find.descendant(
                of: find.ancestor(
                    of: find.text(l10n.bdgStateSafeF),
                    matching: find.byType(Column)).first,
                matching: find.text('1'))
            : find.text(label);
        final (fg, bg) = _pair(tester, text);
        expect(contrast(fg, bg), greaterThanOrEqualTo(4.5),
            reason: '"$label" ${contrast(fg, bg).toStringAsFixed(2)}:1');
      }
    });
  }

  // The shared input decoration: label and hint over the field fill, the fill
  // composited over the page surface it sits on.
  for (final (name, data, colors) in [
    ('light', AppTheme.light, AppColors.light),
    ('dark', AppTheme.dark, AppColors.dark),
    ('sheet', AppTheme.sheet, AppTheme.sheetColors),
  ]) {
    test('default text field label and hint are >= 4.5:1 ($name)', () {
      final input = data.inputDecorationTheme;
      for (final surface in [colors.surface, colors.bg]) {
        final fill = _over(input.fillColor!, surface);
        for (final style in [input.labelStyle!, input.hintStyle!]) {
          final fg = _over(style.color!, fill);
          expect(contrast(fg, fill), greaterThanOrEqualTo(4.5),
              reason: '${contrast(fg, fill).toStringAsFixed(2)}:1 on $fill');
        }
      }
    });
  }
}
