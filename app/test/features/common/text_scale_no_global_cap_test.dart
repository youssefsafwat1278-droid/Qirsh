import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// UX-09 / owner brief §6: "Do not cap accessibility text scaling simply to make
// tests pass." The root builder in `app.dart` keeps the user's text scale with
// only a lower bound. Source contract (the root widget needs the full app
// bootstrap): a global `maxScaleFactor` there would bring the cap back. The
// layouts are held by `large_text_overflow_test.dart` up to 3.1x.
void main() {
  test('app.dart applies no global upper bound to the text scale', () {
    final source = File('lib/app.dart').readAsStringSync();
    expect(source, contains('textScaler: mediaQuery.textScaler.clamp('));
    expect(source, isNot(contains('maxScaleFactor')),
        reason: 'no app-wide text-scale cap (UX-09)');
  });
}
