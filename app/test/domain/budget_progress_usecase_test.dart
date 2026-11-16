import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/capture/proof_correction_log.dart'
    show ProofEditOrigin;
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/card_summary.dart';
import 'package:money_companion/domain/services/card_account_grouper.dart';
import 'package:money_companion/domain/entities/category_spend.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/budget_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/domain/usecases/budget_progress_usecase.dart';

class _FakeBudgetRepository implements BudgetRepository {
  _FakeBudgetRepository(this.budgets);

  final List<BudgetEntity> budgets;
  var getAllCalls = 0;

  @override
  Future<int> countActive() async => budgets.where((it) => it.isActive).length;

  @override
  Future<void> delete(String id) async {
    budgets.removeWhere((item) => item.id == id);
  }

  @override
  Future<List<BudgetEntity>> getAll() async {
    getAllCalls += 1;
    return budgets;
  }

  @override
  Future<BudgetEntity?> getById(String id) async {
    for (final budget in budgets) {
      if (budget.id == id) {
        return budget;
      }
    }
    return null;
  }

  @override
  Future<BudgetEntity> save(BudgetEntity budget) async {
    final index = budgets.indexWhere((item) => item.id == budget.id);
    if (index == -1) {
      budgets.add(budget);
    } else {
      budgets[index] = budget;
    }
    return budget;
  }
}

class _FakeTransactionRepository implements TransactionRepository {
  _FakeTransactionRepository({
    required this.currentSpend,
    required this.previousSpend,
  });

  final Money currentSpend;
  final Money previousSpend;

  @override
  Future<List<TransactionEntity>> largestExpenses({
    required DateTime from,
    required DateTime to,
    String? accountId,
    int limit = 10,
  }) async =>
      const [];

  @override
  Future<List<TransactionEntity>> confirmedInRangePage({
    required DateTime from,
    required DateTime to,
    String? accountId,
    DateTime? beforeOccurredAt,
    String? beforeId,
    int limit = 500,
  }) async =>
      const [];

  @override
  Future<Money> categoryExpenseTotalBetween({
    required String categoryId,
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  }) async {
    if (from.day == 12) {
      return previousSpend;
    }
    return currentSpend;
  }

  @override
  Future<List<CategorySpend>> categoryBreakdown({
    required DateTime from,
    required DateTime to,
    String? accountId,
    required String currency,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionEntity> confirm(String id) {
    throw UnimplementedError();
  }

  @override
  @override
  Future<Money> refundTotalBetween({
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  }) async =>
      // UX-022 — this fake exercises budget progress, which consumes the NET
      // total. No refunds are modelled here, so the netted and gross figures
      // coincide and the assertions are unaffected.
      Money.zero(currency);

  @override
  Future<Money> expenseTotalBetween({
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  }) async {
    if (from.day == 12) {
      return previousSpend;
    }
    return currentSpend;
  }

  @override
  Future<Money> incomeTotalBetween({
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Money?> latestBalanceAfter({String? accountId}) {
    throw UnimplementedError();
  }

  @override
  Future<List<CurrencyTotal>> currencyTotalsBetween({
    required DateTime from,
    required DateTime to,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> updateAccount({
    required String transactionId,
    required String accountId,
    ProofEditOrigin origin = ProofEditOrigin.user,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> updateCard({
    required String transactionId,
    required String? cardLast4,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> updateAmount({
    required String transactionId,
    required Money amount,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<DailySpend>> dailyExpenseTotals({
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionEntity?> findDuplicate({
    required Money amount,
    required String rawMerchant,
    required DateTime occurredAt,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionEntity?> findSuspiciousDuplicate({
    required Money amount,
    required String currency,
    required String merchantOrDescription,
    String? cardLast4,
    required DateTime comparisonTimestamp,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<TransactionEntity>> getAll() {
    throw UnimplementedError();
  }

  @override
  Future<List<TransactionEntity>> getPage(
      {required int offset, int limit = 500}) {
    throw UnimplementedError();
  }

  @override
  Future<List<TransactionEntity>> getTransactionPage({
    required int limit,
    TransactionPageCursor? after,
    TransactionPageFilter filter = const TransactionPageFilter(),
  }) {
    throw UnimplementedError();
  }

  @override
  Future<DateTime?> latestBankCaptureAt() {
    throw UnimplementedError();
  }

  @override
  Future<List<String>> distinctCurrencies() {
    throw UnimplementedError();
  }

  @override
  Future<List<TransactionEntity>> transactionsWithoutAccount({
    DateTime? beforeOccurredAt,
    String? beforeId,
    int limit = 500,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionEntity?> getById(String id) {
    throw UnimplementedError();
  }

  @override
  Future<List<TransactionEntity>> getRecent(
      {int limit = 5, String? accountId}) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    required String? categoryKey,
    String? resolvedCategoryId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionEntity> updateCategory({
    required String transactionId,
    required String categoryKey,
    bool appliedByRule = false,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<TransactionEntity>> sameMerchantTransactions({
    required String rawMerchant,
    String? excludeTransactionId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<String?> categoryIdForKey(String categoryKey) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionEntity> updateTransaction({
    required String transactionId,
    required Money amount,
    required String currency,
    required TransactionTypeEntity type,
    required DateTime occurredAt,
    required String? rawMerchant,
    required String? categoryId,
    required String? note,
    String? accountId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteTransaction(String id) {
    throw UnimplementedError();
  }

  @override
  Future<List<MerchantSpend>> merchantBreakdown({
    required DateTime from,
    required DateTime to,
    required String currency,
    int limit = 3,
    String? accountId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<RecurringCandidate>> recurringCandidates({String? accountId}) {
    throw UnimplementedError();
  }

  @override
  Future<List<CardSummary>> getCardSummaries() {
    throw UnimplementedError();
  }

  @override
  Future<List<CardAccountBreakdownRow>> getCardAccountBreakdown() {
    throw UnimplementedError();
  }

  @override
  Future<List<TransactionEntity>> getByCard(String last4) {
    throw UnimplementedError();
  }
}

void main() {
  test('uses injected batch spent summary for current budget periods',
      () async {
    final repo = _FakeBudgetRepository([
      BudgetEntity(
        id: 'budget-1',
        categoryId: 'restaurants',
        currency: 'SAR',
        amountMoney: Money.parse('100', 'SAR'),
        period: BudgetPeriod.monthly,
        startDate: DateTime(2026, 7),
        isActive: true,
        lastNotifiedSpentMoney: Money(0, 'SAR'),
        lastNotifiedPeriodStart: DateTime.utc(2000, 1, 1),
      ),
    ]);
    var calls = 0;
    final useCase = BudgetProgressUseCase(
      budgetRepository: repo,
      transactionRepository: _FakeTransactionRepository(
        currentSpend: Money(99900, 'SAR'),
        previousSpend: Money(0, 'SAR'),
      ),
      fetchBatchSpent: ({required from, required to}) async {
        calls++;
        return {'budget-1': Money(2500, 'SAR')};
      },
    );

    final snapshot = await useCase(now: DateTime(2026, 7, 14, 12));

    expect(calls, 1);
    expect(snapshot.entries.single.spent, Money(2500, 'SAR'));
    expect(snapshot.entries.single.ratio, 0.25);
  });

  test('BudgetProgress يحسب الميزانية العامة من كل المصروفات', () async {
    final repo = _FakeBudgetRepository([
      BudgetEntity(
        id: 'budget-all',
        categoryId: BudgetEntity.allExpensesCategoryId,
        currency: 'SAR',
        amountMoney: Money.parse('300', 'SAR'),
        period: BudgetPeriod.daily,
        startDate: DateTime.utc(2026, 6, 14, 0),
        isActive: true,
        lastNotifiedSpentMoney: Money(0, 'SAR'),
        lastNotifiedPeriodStart: DateTime.utc(2000, 1, 1),
      ),
    ]);
    final useCase = BudgetProgressUseCase(
      budgetRepository: repo,
      transactionRepository: _FakeTransactionRepository(
        currentSpend: Money(15000, 'SAR'),
        previousSpend: Money(2000, 'SAR'),
      ),
    );

    final snapshot = await useCase.call(now: DateTime.utc(2026, 6, 14, 10));

    expect(snapshot.entries.single.spent, Money(15000, 'SAR'));
    expect(snapshot.entries.single.ratio, 0.5);
    expect(snapshot.entries.single.budget.isAllExpenses, isTrue);
  });
}
