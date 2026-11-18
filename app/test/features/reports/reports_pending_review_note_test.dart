import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/app/app_shell.dart'
    show shellIndexProvider;
import 'package:money_companion/features/reports/reports_screen.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../common/primary_screen_harness.dart';

// Owner brief 4.6: "Reports should explain that transactions awaiting review
// are not included in totals." The note shows only when there are such items
// and leads to them (Transactions filtered to pending review).
void main() {
  final reports = primaryScreens.firstWhere((s) => s.name == 'Reports');

  for (final language in ['en', 'ar']) {
    testWidgets('a pending transaction shows the note, which opens the review '
        'list ($language)', (tester) async {
      final errors = await pumpPrimaryScreen(tester, reports,
          size: const Size(390, 844), language: language);
      stopCollectingErrors();
      expect(errors, isEmpty);
      final l10n = AppL10n.of(tester.element(find.byType(ReportsScreen)));
      expect(find.byKey(const Key('reportsPendingReviewNote')), findsOneWidget);
      expect(find.text(l10n.rptPendingNotIncluded), findsOneWidget);

      await tester.tap(find.text(l10n.commonReview));
      await tester.pump();
      final container = ProviderScope.containerOf(
          tester.element(find.byType(ReportsScreen)));
      expect(container.read(transactionsPendingFilterProvider), isTrue);
      expect(container.read(shellIndexProvider), 1);
    });
  }

  testWidgets('no pending transaction: no note', (tester) async {
    final errors = await pumpPrimaryScreen(tester, reports,
        size: const Size(390, 844), language: 'en', seedPending: false);
    stopCollectingErrors();
    expect(errors, isEmpty);
    expect(find.byKey(const Key('reportsPendingReviewNote')), findsNothing);
  });
}
