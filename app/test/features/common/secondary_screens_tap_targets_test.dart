import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'primary_screen_harness.dart';

// UX-05 (closure round): the same 44x44 pt scan as
// `primary_screens_tap_targets_test.dart`, extended to the sheets and secondary
// screens the round-2 scan did not cover — Smart Inbox, transaction details
// (page and sheet), add / edit transaction, paste, Accounts and the sign-out
// sheet.
void main() {
  final secondary = largeTextScreens.skip(primaryScreens.length);
  for (final language in ['en', 'ar']) {
    for (final size in const [Size(390, 844), Size(320, 568)]) {
      for (final screen in secondary) {
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
