import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/merchant_category_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/domain/usecases/confirm_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/correct_category_usecase.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/features/transactions/widgets/confirm_transaction_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

final _now = DateTime.utc(2026, 11, 1);
final _tx = TransactionEntity(
    id: 'pending-1',
    amountMoney: Money(1500, 'EGP'),
    currency: 'EGP',
    type: TransactionTypeEntity.payment,
    source: TransactionSourceEntity.bank,
    occurredAt: _now,
    rawMessage: 'synthetic',
    rawMerchant: 'QA merchant',
    categoryId: 'food',
    parseConfidence: 1,
    status: TransactionStatus.pending,
    createdAt: _now,
    updatedAt: _now);

/// The sheet must not write a category to the repository itself.
class _Repo implements TransactionRepository {
  int directCategoryWrites = 0;
  int confirms = 0;

  @override
  Future<TransactionEntity> updateCategory(
      {required String transactionId,
      required String categoryKey,
      bool appliedByRule = false}) async {
    directCategoryWrites++;
    return _tx;
  }

  @override
  Future<TransactionEntity> confirm(String id) async {
    confirms++;
    return _tx;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected ${invocation.memberName}');
}

class _NoMerchants implements MerchantCategoryRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected ${invocation.memberName}');
}

class _RecordingCorrect extends CorrectCategoryUseCase {
  _RecordingCorrect(TransactionRepository repo)
      : super(
            transactionRepository: repo,
            merchantCategoryRepository: _NoMerchants());

  final calls = <(String, CategoryCorrectionScope)>[];

  @override
  Future<TransactionEntity> call({
    required String transactionId,
    required String categoryKey,
    required CategoryCorrectionScope scope,
    bool alsoUpdatePast = false,
    PastUpdateOverrides overrides = const PastUpdateOverrides(),
  }) async {
    calls.add((categoryKey, scope));
    return _tx;
  }
}

Future<AppL10n> _open(
    WidgetTester tester, _Repo repo, _RecordingCorrect correct) async {
  tester.view.physicalSize = const Size(400, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      transactionByIdProvider(_tx.id).overrideWith((ref) async => _tx),
      categoryCatalogProvider
          .overrideWith((ref) async => CategoryCatalog(const [
                CategoryEntity(
                    id: 'food',
                    key: 'food',
                    nameAr: 'Food',
                    icon: 'utensils',
                    color: '#22C55E',
                    isIncome: false,
                    sort: 1),
                CategoryEntity(
                    id: 'travel',
                    key: 'travel',
                    nameAr: 'Travel',
                    icon: 'plane',
                    color: '#1653F3',
                    isIncome: false,
                    sort: 2),
              ], languageCode: 'en')),
      accountsProvider.overrideWith((ref) async => const []),
      transactionRepositoryProvider.overrideWithValue(repo),
      confirmTransactionUseCaseProvider
          .overrideWithValue(ConfirmTransactionUseCase(repo)),
      correctCategoryUseCaseProvider.overrideWithValue(correct),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('en'),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => showConfirmTransactionSheet(context, _tx.id),
                  child: const Text('open')))),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return AppL10n.of(tester.element(find.text('open')));
}

Future<void> _confirm(WidgetTester tester, AppL10n l10n) async {
  final confirm = find.text(l10n.txdConfirmTx);
  await tester.ensureVisible(confirm);
  await tester.tap(confirm);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a chip pick goes through the use case and teaches no rule',
      (tester) async {
    final repo = _Repo();
    final correct = _RecordingCorrect(repo);
    final l10n = await _open(tester, repo, correct);

    expect(find.text(l10n.ccAllMerchant), findsNothing,
        reason: '"remember" appears only once a category is picked');
    await tester.tap(find.text('Travel'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.ccAllMerchant), findsOneWidget);
    await _confirm(tester, l10n);

    expect(correct.calls,
        [('travel', CategoryCorrectionScope.thisTransactionOnly)]);
    expect(repo.directCategoryWrites, 0);
    expect(repo.confirms, 1);
  });

  testWidgets('"remember" teaches the rule through the same use case',
      (tester) async {
    final repo = _Repo();
    final correct = _RecordingCorrect(repo);
    final l10n = await _open(tester, repo, correct);

    await tester.tap(find.text('Travel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.ccAllMerchant));
    await tester.pumpAndSettle();
    await _confirm(tester, l10n);

    expect(correct.calls, [
      ('travel', CategoryCorrectionScope.thisTransactionOnly),
      ('travel', CategoryCorrectionScope.allMerchantTransactions),
    ]);
    expect(repo.directCategoryWrites, 0);
    expect(repo.confirms, 1);
  });
}
