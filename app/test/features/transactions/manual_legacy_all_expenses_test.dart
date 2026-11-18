import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/widgets/glass_dropdown_field.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/transactions/manual_transaction_sheet.dart';

import '../common/primary_screen_harness.dart';

// FR-12: a legacy row stored under the `all_expenses` sentinel showed an empty
// category field when edited. It now shows the stored category; a new entry
// still cannot pick the sentinel.
final _when = DateTime(2026, 11, 1, 9);

TransactionEntity _legacy() => TransactionEntity(
      id: 'legacy-all',
      amountMoney: Money(4000, 'SAR'),
      currency: 'SAR',
      type: TransactionTypeEntity.payment,
      source: TransactionSourceEntity.unknown,
      rawMessage: 'synthetic',
      occurredAt: _when,
      rawMerchant: 'Synthetic Shop',
      parseConfidence: 1,
      status: TransactionStatus.confirmed,
      categoryId: BudgetEntity.allExpensesCategoryId,
      createdAt: _when,
      updatedAt: _when,
    );

Finder get _categoryField => find.byWidgetPredicate(
    (w) => w is GlassDropdownField<String> && w.items.length > 1);

void main() {
  for (final language in ['en', 'ar']) {
    for (final (name, tx) in [('edit legacy', _legacy()), ('new', null)]) {
      testWidgets('category field, $name ($language)', (tester) async {
        final errors = await pumpPrimaryScreen(
            tester,
            PrimaryScreen(name,
                () => Scaffold(body: ManualTransactionSheet(transaction: tx))),
            size: const Size(390, 844),
            language: language);
        final catalog = await ProviderScope.containerOf(
                tester.element(find.byType(ManualTransactionSheet)))
            .read(categoryCatalogProvider.future);
        final sentinel = catalog.byKey(BudgetEntity.allExpensesCategoryKey)!;
        final shown = find
            .descendant(of: _categoryField, matching: find.text(sentinel.name))
            .evaluate()
            .length;
        stopCollectingErrors();
        expect(errors, isEmpty);
        expect(shown, tx == null ? 0 : 1);
      });
    }
  }
}
