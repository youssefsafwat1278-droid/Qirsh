import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/transactions/manual_transaction_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _NoAccounts implements AccountRepository {
  @override
  Future<AccountEntity?> getDefault() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// UX-01: the seeded budget-scope category «كل المصروفات / All expenses»
// (sort -1, so it sorts first) must not be pre-selected or offered as the
// category of a manual transaction.
void main() {
  for (final lang in ['ar', 'en']) {
    testWidgets('manual add does not default to or offer All expenses ($lang)',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final catalog = CategoryCatalog(const [
        CategoryEntity(
            id: BudgetEntity.allExpensesCategoryId,
            key: BudgetEntity.allExpensesCategoryKey,
            nameAr: 'كل المصروفات',
            icon: 'wallet-cards',
            color: '#AB47BC',
            isIncome: false,
            sort: -1),
        CategoryEntity(
            id: 'category',
            key: 'groceries',
            nameAr: 'بقالة',
            icon: 'shopping-cart',
            color: '#16A37F',
            isIncome: false,
            sort: 0),
      ], languageCode: lang);
      final allExpensesName =
          catalog.byKey(BudgetEntity.allExpensesCategoryKey)!.name;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          categoryCatalogProvider.overrideWith((ref) async => catalog),
          accountsProvider.overrideWith((ref) async => const []),
          accountRepositoryProvider.overrideWithValue(_NoAccounts()),
        ],
        child: MaterialApp(
          locale: Locale(lang),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          theme: AppTheme.light,
          home: Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                        onPressed: () => ManualTransactionSheet.show(context),
                        child: const Text('open'),
                      ))),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final l10n =
          AppL10n.of(tester.element(find.byType(ManualTransactionSheet)));

      // Not pre-selected: the field does not show the sentinel's name.
      expect(find.text(allExpensesName), findsNothing);

      // Not offered: the picker lists the real category only.
      await tester.tap(find.text(l10n.txnCategory));
      await tester.pumpAndSettle();
      expect(find.text(catalog.byKey('groceries')!.name), findsOneWidget);
      expect(find.text(allExpensesName), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // Saving with an amount but no category hits the existing validation.
      await tester.enterText(find.byType(TextField).first, '12.50');
      final save = find.widgetWithText(FilledButton, l10n.mtAddTransaction);
      await tester.scrollUntilVisible(save, 160,
          scrollable: find
              .descendant(
                  of: find.byType(ManualTransactionSheet),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pump();
      expect(find.text(l10n.mtPickCategory), findsOneWidget);
      expect(find.byType(ManualTransactionSheet), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
