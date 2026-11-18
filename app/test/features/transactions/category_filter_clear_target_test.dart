import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';
import 'package:money_companion/features/transactions/widgets/activity_chip.dart';

import '../common/primary_screen_harness.dart';

// UX-05: the active category chip's clear "x" is a 14 pt glyph. A tap 12 pt
// below its centre (inside a 44 pt target) must clear the filter rather than
// fall through to the chip, which opens the category picker.
void main() {
  for (final language in ['en', 'ar']) {
    testWidgets('category filter clear has a 44 pt hit area, $language',
        (tester) async {
      final screen = largeTextScreens
          .firstWhere((s) => s.name == 'Transactions (category filter)');
      final errors = await pumpPrimaryScreen(tester, screen,
          size: const Size(390, 844), language: language);
      final x = find.descendant(
          of: find.byType(ActivityChip),
          matching: find.byIcon(AppLucideIcons.x));
      final found = x.evaluate().length;
      if (found == 1) {
        // The chip row scrolls sideways; bring the chip on screen.
        final row = find.ancestor(
            of: x,
            matching: find.byWidgetPredicate((w) =>
                w is SingleChildScrollView &&
                w.scrollDirection == Axis.horizontal));
        await tester.drag(row, Offset(language == 'ar' ? 600 : -600, 0));
        await tester.pumpAndSettle();
        await tester.tapAt(tester.getCenter(x) + const Offset(0, 12));
        await tester.pump(const Duration(milliseconds: 500));
      }
      final container = ProviderScope.containerOf(
          tester.element(find.byType(TransactionsScreen)));
      final filter = container.read(transactionCategoryFilterProvider);
      stopCollectingErrors();
      expect(found, 1);
      expect(filter, isNull,
          reason: 'a tap 12 pt from the glyph centre must clear the filter');
      expect(errors, isEmpty);
    });
  }
}
