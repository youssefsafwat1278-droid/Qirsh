import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/features/transactions/transaction_details_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../common/primary_screen_harness.dart';

// Owner brief 4.6: a saved (confirmed) transaction can be moved back into
// review from its details. It leaves the totals at once, the user gets
// feedback, and the details then offer Confirm again.
void main() {
  for (final language in ['en', 'ar']) {
    testWidgets(
        'a saved transaction moves into review and leaves the totals '
        '($language)', (tester) async {
      late AppDatabase db;
      final screen = largeTextScreens
          .firstWhere((s) => s.name == 'Transaction details (saved)');
      final errors = await pumpPrimaryScreen(tester, screen,
          size: const Size(390, 844),
          language: language,
          seed: (d) async => db = d);
      final l10n =
          AppL10n.of(tester.element(find.byType(TransactionDetailsScreen)));
      final repo = DriftTransactionRepository(db);
      final from = DateTime.now().subtract(const Duration(days: 2));
      final to = DateTime.now().add(const Duration(minutes: 1));
      final before = (await tester.runAsync(() =>
          repo.expenseTotalBetween(from: from, to: to, currency: 'SAR')))!;

      final move = find.byKey(const Key('txdMoveToReview'));
      final found = move.evaluate().length;
      if (found == 1) {
        await tester.scrollUntilVisible(move, 200,
            scrollable: find.byType(Scrollable).first);
        await tester.pump();
        expect(tester.getSize(move).height, greaterThanOrEqualTo(44));
        await tester.tap(move);
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
      final toastShown =
          find.text(l10n.txdMovedToReviewToast).evaluate().isNotEmpty;
      final after = (await tester.runAsync(() =>
          repo.expenseTotalBetween(from: from, to: to, currency: 'SAR')))!;
      final status =
          (await tester.runAsync(() => repo.getById('scan-1')))!.status;
      await tester.pump(const Duration(seconds: 5));
      stopCollectingErrors();

      expect(found, 1, reason: 'a confirmed transaction offers Move to review');
      expect(status, TransactionStatus.pending);
      expect(before.minorUnits - after.minorUnits, 8730,
          reason: 'the moved payment leaves the expense total');
      expect(toastShown, isTrue);
      expect(errors, isEmpty);
    });
  }
}
