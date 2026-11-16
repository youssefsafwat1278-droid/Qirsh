import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/segmented_control.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/merchant_category_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/domain/usecases/correct_category_usecase.dart';
import 'package:money_companion/features/common/app_button.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/transactions/widgets/change_category_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

// The real correction use case reaches its repository boundary and fails there.
// No financial write or learned merchant category is fabricated as successful.
class _FailingTransactions implements TransactionRepository {
  final requests = <({String transactionId, String categoryKey})>[];
  Completer<TransactionEntity>? pending;

  @override
  Future<TransactionEntity> updateCategory({required String transactionId,
      required String categoryKey, bool appliedByRule = false}) {
    requests.add((transactionId: transactionId, categoryKey: categoryKey));
    return (pending = Completer<TransactionEntity>()).future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected transaction operation ${invocation.memberName}');
}

class _NoMerchantWrites implements MerchantCategoryRepository {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('Unexpected merchant operation ${invocation.memberName}');
  }
}

Future<AppL10n> _open(WidgetTester tester, _FailingTransactions transactions,
    _NoMerchantWrites merchants, String language, bool dark) async {
  tester.view.physicalSize = const Size(375, 812);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final now = DateTime.utc(2026, 11, 1);
  final transaction = TransactionEntity(id: 'category-failure-tx',
    amountMoney: Money(12345, 'EGP'), currency: 'EGP',
    type: TransactionTypeEntity.payment, source: TransactionSourceEntity.bank,
    occurredAt: now, rawMessage: 'synthetic', rawMerchant: 'QA merchant',
    categoryId: 'food', parseConfidence: 1,
    status: TransactionStatus.confirmed, createdAt: now, updatedAt: now);
  final catalog = CategoryCatalog(const [
    CategoryEntity(id: 'food', key: 'food', nameAr: 'مطاعم', icon: 'utensils',
      color: '#22C55E', isIncome: false, sort: 1),
    CategoryEntity(id: 'travel', key: 'qa-travel', nameAr: 'QA travel', icon: 'plane',
      color: '#1653F3', isIncome: false, sort: 2),
  ], languageCode: language);
  await tester.pumpWidget(ProviderScope(overrides: [
    correctCategoryUseCaseProvider.overrideWithValue(CorrectCategoryUseCase(
      transactionRepository: transactions, merchantCategoryRepository: merchants)),
  ], child: MaterialApp(
    theme: dark ? AppTheme.dark : AppTheme.light,
    locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates,
    home: Builder(builder: (context) => Scaffold(body: TextButton(
      onPressed: () => showChangeCategorySheet(context, transaction, catalog),
      child: const Text('open')))),
  )));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return AppL10n.of(tester.element(find.byType(AppPrimaryButton)));
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('category correction failure keeps selection and permits retry $language dark$dark', (tester) async {
        final transactions = _FailingTransactions();
        final merchants = _NoMerchantWrites();
        final l10n = await _open(tester, transactions, merchants, language, dark);
        await tester.tap(find.text('QA travel'));
        await tester.tap(find.text(l10n.ccScopeMerchant));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.ccSave));
        await tester.pump();
        expect(transactions.requests, [(transactionId: 'category-failure-tx', categoryKey: 'qa-travel')]);
        expect(tester.widget<AppPrimaryButton>(find.byType(AppPrimaryButton)).onTap, isNull);
        transactions.pending!.completeError(StateError('private_repository_detail'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        expect(find.text(l10n.ccTitle), findsOneWidget);
        expect(find.text(l10n.ctsCategoryUpdateFailed), findsOneWidget);
        expect(find.textContaining('private_repository_detail'), findsNothing);
        expect(tester.widget<AppPrimaryButton>(find.byType(AppPrimaryButton)).onTap, isNotNull);
        final scope = tester.widget<SegmentedControl<CategoryCorrectionScope>>(
          find.byType(SegmentedControl<CategoryCorrectionScope>));
        expect(scope.value, CategoryCorrectionScope.allMerchantTransactions);
        expect(merchants.calls, 0);
        // The next real tap retries the same selected category; no failed
        // correction reaches the subsequent merchant-learning boundary.
        await tester.tap(find.text(l10n.ccSave));
        await tester.pump();
        expect(transactions.requests.length, 2);
        expect(transactions.requests.last.categoryKey, 'qa-travel');
        transactions.pending!.completeError(StateError('retry_failed'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        expect(merchants.calls, 0);
        await tester.pump(const Duration(seconds: 4));
      });
    }
  }

  testWidgets('dismissed category sheet ignores later correction failure', (tester) async {
    final transactions = _FailingTransactions();
    final merchants = _NoMerchantWrites();
    final l10n = await _open(tester, transactions, merchants, 'en', false);
    await tester.tap(find.text(l10n.ccSave));
    await tester.pump();
    Navigator.of(tester.element(find.byType(AppPrimaryButton))).pop();
    await tester.pumpAndSettle();
    transactions.pending!.completeError(StateError('late_failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text(l10n.ccTitle), findsNothing);
    expect(find.text(l10n.ctsCategoryUpdateFailed), findsNothing);
    expect(merchants.calls, 0);
  });
}
