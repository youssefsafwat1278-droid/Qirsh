import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'primary_screen_harness.dart';

// UX-09 (closure round): the app no longer caps text scaling (`app.dart`).
// This is the regression gate: every screen in [largeTextScreens] must lay out
// with NO Flutter error (RenderFlex overflow included) at 1.0x, 1.3x, 2.0x and
// 3.1x (about the largest iOS accessibility size, AX5 body 53 pt / 17 pt), in
// English and Arabic, on an iPhone SE-size (320x568) and a regular (390x844)
// screen. Each screen is scrolled through so off-screen content is laid out too.
//
// Text cut off with an ellipsis is not an error; it is printed (not asserted)
// so the remaining truncations stay visible in the run log.

const _sizes = [Size(320, 568), Size(390, 844)];
const _scales = [1.0, 1.3, 2.0, 3.1];

Set<String> _truncated(WidgetTester tester) => {
      for (final element in find.byType(RichText).evaluate())
        if (element.renderObject case final RenderParagraph p
            when p.attached && p.didExceedMaxLines)
          p.text.toPlainText().replaceAll('\n', ' '),
    };

/// Only the screens named in QIRSH_LARGE_TEXT_SCREENS (comma-separated) when
/// set — a convenience for local iteration; the gate runs all of them.
final _only = Platform.environment['QIRSH_LARGE_TEXT_SCREENS']
    ?.split(',')
    .map((s) => s.trim())
    .toSet();

void main() {
  final only = _only;
  for (final screen in largeTextScreens) {
    if (only != null && !only.contains(screen.name)) continue;
    for (final scale in _scales) {
      testWidgets('${screen.name} has no layout error at ${scale}x '
          '(en/ar, 320x568 and 390x844)', (tester) async {
        final failures = <String>[];
        final cutOff = StringBuffer();
        for (final language in ['en', 'ar']) {
          for (final size in _sizes) {
            final errors = await pumpPrimaryScreen(tester, screen,
                size: size, language: language, textScale: scale);
            final cut = <String>{};
            await eachScreenful(tester, () async {
              cut.addAll(_truncated(tester));
              final pending = tester.takeException();
              if (pending != null) errors.add('$pending'.split('\n').first);
            });
            stopCollectingErrors();
            if (errors.isNotEmpty) {
              failures.add('$language $size: ${errors.toSet().join(' | ')}');
            }
            if (cut.isNotEmpty) {
              cutOff.writeln('[UX-09 ${scale}x $size $language] '
                  '${screen.name} cut off: ${cut.join(' ; ')}');
            }
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
        // ignore: avoid_print
        if (cutOff.isNotEmpty) print(cutOff.toString().trimRight());
        expect(failures, isEmpty,
            reason: '${screen.name} at ${scale}x must lay out without error');
      });
    }
  }
}
