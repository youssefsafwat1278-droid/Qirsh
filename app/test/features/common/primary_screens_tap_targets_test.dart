import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'primary_screen_harness.dart';

// UX-05 (round 2): every tappable control on the primary screens is at least
// 44x44 pt. The harness walks the semantics tree screenful by screenful (the
// node rules of Flutter's iOSTapTargetGuideline, scroll edges refined) and lists every target
// below 44 pt, so a failure names the control and its size.
void main() {
  for (final language in ['en', 'ar']) {
    for (final size in const [Size(390, 844), Size(320, 568)]) {
      for (final screen in primaryScreens) {
        testWidgets('${screen.name} tap targets >= 44pt, $language $size',
            (tester) async {
          final semantics = tester.ensureSemantics();
          final errors = await pumpPrimaryScreen(tester, screen,
              size: size, language: language);
          final small = <String>{};
          await eachScreenful(tester, () async {
            for (final target in tapTargets(tester)) {
              if (target.size.width < 44 - precisionErrorTolerance ||
                  target.size.height < 44 - precisionErrorTolerance) {
                small.add('$target');
              }
            }
          });
          stopCollectingErrors();
          expect(errors, isEmpty);
          expect(small, isEmpty,
              reason: 'tap targets below 44x44 pt on ${screen.name}');
          semantics.dispose();
        });
      }
    }
  }
}
