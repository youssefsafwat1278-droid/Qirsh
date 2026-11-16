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
import 'package:money_companion/domain/usecases/correct_category_usecase.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/transactions/widgets/change_category_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

final _now = DateTime.utc(2026, 11, 1);

TransactionEntity _tx(String id) => TransactionEntity(
    id: id,
    amountMoney: Money(1500, 'EGP'),
    currency: 'EGP',
    type: TransactionTypeEntity.payment,
    source: TransactionSourceEntity.bank,
    occurredAt: _now,
    rawMessage: 'synthetic',
    rawMerchant: 'QA merchant',
    categoryId: 'food',
    parseConfidence: 1,
    status: TransactionStatus.confirmed,
    createdAt: _now,
    updatedAt: _now);

class _Transactions implements TransactionRepository {
  final writes = <({String id, String key, bool byRule})>[];
  final past = [
    _tx('past-1').copyWith(categoryProvenance: CategoryProvenance.auto),
    _tx('past-2').copyWith(categoryProvenance: CategoryProvenance.rule),
  ];
  int countQueries = 0;

  @override
  Future<TransactionEntity> updateCategory(
      {required String transactionId,
      required String categoryKey,
      bool appliedByRule = false}) async {
    writes.add((id: transactionId, key: categoryKey, byRule: appliedByRule));
    return _tx(transactionId);
  }

  @override
  Future<List<TransactionEntity>> sameMerchantTransactions(
      {required String rawMerchant, String? excludeTransactionId}) async {
    countQueries++;
    return past;
  }

  @override
  Future<String?> categoryIdForKey(String categoryKey) async => categoryKey;

  @override
  Future<TransactionEntity?> getById(String id) async => _tx(id);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected ${invocation.memberName}');
}

class _Merchants implements MerchantCategoryRepository {
  final rules = <(String, String)>[];

  @override
  Future<Map<String, String>> getLearnedCategoryMap() async => {};

  @override
  Future<String?> userConfirmedCategoryFor(String rawMerchant) async => null;

  @override
  Future<void> confirmMerchantCategory(
      {required String rawMerchant,
      required String categoryKey,
      required bool isUserConfirmed,
      double confidence = 1}) async {
    rules.add((rawMerchant, categoryKey));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected ${invocation.memberName}');
}

Future<AppL10n> _open(
    WidgetTester tester, _Transactions txs, _Merchants merchants) async {
  tester.view.physicalSize = const Size(400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final catalog = CategoryCatalog(const [
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
  ], languageCode: 'en');
  await tester.pumpWidget(ProviderScope(
    overrides: [
      correctCategoryUseCaseProvider.overrideWithValue(CorrectCategoryUseCase(
          transactionRepository: txs, merchantCategoryRepository: merchants)),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('en'),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () =>
                      showChangeCategorySheet(context, _tx('tx-1'), catalog),
                  child: const Text('open')))),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return AppL10n.of(tester.element(find.text(_l10nTitleProbe)));
}

const _l10nTitleProbe = 'Change the category';

void main() {
  testWidgets('the default edit changes only this transaction, teaches nothing',
      (tester) async {
    final txs = _Transactions();
    final merchants = _Merchants();
    final l10n = await _open(tester, txs, merchants);

    // "Also update past" is not offered until "remember" is chosen.
    expect(find.text(l10n.ccAlsoUpdatePast), findsNothing);
    await tester.tap(find.text('Travel'));
    await tester.tap(find.text(l10n.ccSave));
    await tester.pumpAndSettle();

    expect(txs.writes, [(id: 'tx-1', key: 'travel', byRule: false)]);
    expect(merchants.rules, isEmpty);
    expect(txs.countQueries, 0);
  });

  testWidgets('"remember" alone teaches a rule and leaves the past alone',
      (tester) async {
    final txs = _Transactions();
    final merchants = _Merchants();
    final l10n = await _open(tester, txs, merchants);

    await tester.tap(find.text('Travel'));
    await tester.tap(find.text(l10n.ccScopeMerchant));
    await tester.pumpAndSettle();
    expect(find.text(l10n.ccAlsoUpdatePast), findsOneWidget);
    await tester.tap(find.text(l10n.ccSave));
    await tester.pumpAndSettle();

    expect(txs.writes, [(id: 'tx-1', key: 'travel', byRule: false)]);
    expect(merchants.rules, [('QA merchant', 'travel')]);
  });

  testWidgets(
      '"also update past" shows the count first, then updates exactly those',
      (tester) async {
    final txs = _Transactions();
    final merchants = _Merchants();
    final l10n = await _open(tester, txs, merchants);

    await tester.tap(find.text('Travel'));
    await tester.tap(find.text(l10n.ccScopeMerchant));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.ccAlsoUpdatePast));
    await tester.pumpAndSettle();

    expect(txs.writes, isEmpty, reason: 'nothing changes before saving');
    expect(find.text(l10n.ccPastCount(2)), findsOneWidget);
    expect(find.textContaining(l10n.ccPastExcludedTitle), findsNothing);
    expect(l10n.ccPastCount(2), '2 past transactions will change.');

    await tester.tap(find.text(l10n.ccSave));
    await tester.pumpAndSettle();

    expect(txs.writes, [
      (id: 'tx-1', key: 'travel', byRule: false),
      (id: 'past-1', key: 'travel', byRule: true),
      (id: 'past-2', key: 'travel', byRule: true),
    ]);
    expect(merchants.rules, [('QA merchant', 'travel')]);
  });

  testWidgets(
      'imported rows need their own switch, behind a confirmation that names them',
      (tester) async {
    final txs = _Transactions()
      ..past.add(_tx('imp-1').copyWith(
          categoryProvenance: CategoryProvenance.unknown,
          importedFromFile: true));
    final merchants = _Merchants();
    final l10n = await _open(tester, txs, merchants);

    await tester.tap(find.text('Travel'));
    await tester.tap(find.text(l10n.ccScopeMerchant));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.ccAlsoUpdatePast));
    await tester.pumpAndSettle();

    expect(find.text(l10n.ccPastCount(2)), findsOneWidget);
    expect(find.textContaining(l10n.ccPastExclImported(1)), findsOneWidget);
    final toggle = find.byKey(const ValueKey('cc-include-imported'));
    await tester.ensureVisible(toggle);

    // Cancelling the confirmation leaves the imported row out.
    await tester.tap(find.descendant(of: toggle, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(find.text(l10n.ccIncludeImportedConfirmBody(1)), findsOneWidget);
    await tester.tap(find.text(l10n.commonCancel));
    await tester.pumpAndSettle();
    expect(find.text(l10n.ccPastCount(2)), findsOneWidget);

    // Confirming includes it, and the preview count follows.
    await tester.tap(find.descendant(of: toggle, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cc-include-imported-confirm')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.ccPastCount(3)), findsOneWidget);

    await tester.ensureVisible(find.text(l10n.ccSave));
    await tester.tap(find.text(l10n.ccSave));
    await tester.pumpAndSettle();
    expect(txs.writes.map((w) => w.id),
        ['tx-1', 'past-1', 'past-2', 'imp-1']);
  });
}
