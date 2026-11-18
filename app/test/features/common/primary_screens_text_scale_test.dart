import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'primary_screen_harness.dart';

const _sizes = [Size(320, 568), Size(390, 844)];

/// Laid-out text that is cut off (ellipsis or max lines exceeded).
Set<String> _truncated(WidgetTester tester) => {
      for (final element in find.byType(RichText).evaluate())
        if (element.renderObject case final RenderParagraph p
            when p.attached && p.didExceedMaxLines)
          p.text.toPlainText().replaceAll('\n', ' '),
    };

Future<(List<String>, Set<String>)> _measure(
    WidgetTester tester, PrimaryScreen screen,
    {required Size size, required String language, required double scale}) async {
  final errors = await pumpPrimaryScreen(tester, screen,
      size: size, language: language, textScale: scale);
  final cut = <String>{};
  await eachScreenful(tester, () async {
    cut.addAll(_truncated(tester));
    final pending = tester.takeException();
    if (pending != null) errors.add('$pending'.split('\n').first);
  });
  stopCollectingErrors();
  return (errors, cut);
}

// UX-09 (round 2). These cases were written when the app clamped text to
// 1.25x. The closure round removed that cap (`app.dart`); the regression gate
// across 1.0x-3.1x is now `large_text_overflow_test.dart`. The 1.25x cases and
// the Settings-hub 2.0x case below are kept as they were.
void main() {
  for (final language in ['en', 'ar']) {
    for (final size in _sizes) {
      for (final screen in primaryScreens) {
        testWidgets('${screen.name} lays out at the 1.25x cap, $language $size',
            (tester) async {
          final (errors, _) = await _measure(tester, screen,
              size: size, language: language, scale: 1.25);
          expect(errors, isEmpty);
        });
      }
    }
  }

  // Fixed in round 2 (it overflowed by 8 pt at 2x): the Settings hub's
  // destination tiles grow with the text instead of a fixed 88 pt.
  for (final size in _sizes) {
    testWidgets('Settings hub tiles do not overflow at 2.0x $size',
        (tester) async {
      final (errors, _) = await _measure(
          tester, primaryScreens.firstWhere((s) => s.name == 'Settings'),
          size: size, language: 'en', scale: 2.0);
      expect(errors, isEmpty);
    });
  }
}
