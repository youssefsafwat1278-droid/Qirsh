import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/services/budget_alert_planner.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/engine/parser/parse_result.dart';
import 'package:money_companion/features/capture/services/budget_alert_commits.dart';
import 'package:money_companion/features/capture/services/captured_message_processor.dart';

class _KeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory';
  @override
  Future<String?> readStoredKey() async => 'memory';
}

void main() {
  final now = DateTime(2026, 10, 15, 12);
  late AppDatabase db;
  late DriftTransactionRepository transactions;
  var serial = 0;

  Future<TransactionEntity> put({
    String account = 'sofa',
    String currency = 'EGP',
    String category = 'groceries',
    TransactionStatus status = TransactionStatus.confirmed,
    TransactionTypeEntity type = TransactionTypeEntity.payment,
    DateTime? at,
    String amount = '85',
  }) =>
      transactions.saveTransaction(
        transaction: TransactionEntity(
          id: 'event-${serial++}',
          amountMoney: Money.parse(amount, currency),
          currency: currency,
          accountId: account,
          type: type,
          source: TransactionSourceEntity.bank,
          occurredAt: at ?? now,
          rawMessage: '',
          parseConfidence: 1,
          status: status,
          createdAt: now,
          updatedAt: now,
        ),
        categoryKey: category,
      );

  Future<void> budget(
      {String? account = 'sofa', String? category, bool active = true}) async {
    await DriftBudgetRepository(db).save(BudgetEntity(
      id: 'budget',
      accountId: account,
      categoryId: category ?? BudgetEntity.allExpensesCategoryId,
      currency: 'EGP',
      amountMoney: Money.parse('100', 'EGP'),
      period: BudgetPeriod.monthly,
      startDate: DateTime(2026, 10),
      isActive: active,
      alertThresholdPercent: 80,
      lastNotifiedSpentMoney: Money(0, 'EGP'),
      lastNotifiedPeriodStart: DateTime(2026, 10),
    ));
  }

  Future<List<BudgetAlertContent>> check(List<TransactionEntity> events) async {
    final alerts = <BudgetAlertContent>[];
    await CapturedMessageProcessor.checkBudgetAlert(
      db,
      const NotificationPreferences(),
      committedTransactions: events,
      now: now,
      lang: 'en',
      emit: (alert) async {
        alerts.add(alert);
      },
    );
    return alerts;
  }

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _KeyStore());
    transactions = DriftTransactionRepository(db);
    for (final id in ['sofa', 'mina', 'excluded']) {
      await DriftAccountRepository(db).create(AccountEntity(
        id: id,
        name: id,
        currency: 'EGP',
        type: AccountType.bank,
        isDefault: id == 'mina',
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
        excludeFromTotals: id == 'excluded',
      ));
    }
  });
  tearDown(() => db.close());

  test('same currency: default mina event cannot alert over-threshold sofa',
      () async {
    await budget();
    final sofa = await put();
    final mina = await put(account: 'mina');
    expect(await check([mina]), isEmpty);
    final alerts = await check([sofa]);
    expect(alerts, hasLength(1));
    expect(alerts.single.body, contains('sofa'));
    expect(alerts.single.body, contains('80%'));
    expect(await check([sofa]), isEmpty,
        reason: 'reopening/importing at the same budget tier must not repeat it');
  });

  test('global budget spans included accounts without default account label',
      () async {
    await budget(account: null);
    final alerts = await check([await put(account: 'mina')]);
    expect(alerts, hasLength(1));
    expect(alerts.single.body, isNot(contains('mina')));
    expect(await check([await put(currency: 'USD')]), isEmpty);
    expect(await check([await put(account: 'excluded')]), isEmpty);
  });

  test('only a new tier or another ten percent over budget alerts again', () async {
    await budget();
    expect(await check([await put()]), hasLength(1));
    expect(await check([await put(amount: '1')]), isEmpty);
    expect(await check([await put(amount: '5')]), hasLength(1));
    expect(await check([await put(amount: '10')]), hasLength(1));
    expect(await check([await put(amount: '5')]), isEmpty);
    expect(await check([await put(amount: '6')]), hasLength(1));
  });

  test('failed delivery leaves the budget eligible for a later alert', () async {
    await budget();
    final event = await put();
    await expectLater(CapturedMessageProcessor.checkBudgetAlert(db,
      const NotificationPreferences(), committedTransactions: [event], now: now,
      emit: (_) async => throw StateError('delivery failed')), throwsStateError);
    expect(await check([event]), hasLength(1));
    expect(await check([event]), isEmpty);
  });

  test('account-specific excluded account still consumes its budget', () async {
    await budget(account: 'excluded');
    expect(await check([await put(account: 'excluded')]), hasLength(1));
  });

  test('currency and category scope use the committed row', () async {
    final seed = await put();
    await budget(category: seed.categoryId);
    expect(await check([await put(currency: 'USD')]), isEmpty);
    expect(await check([await put(category: 'restaurants')]), isEmpty);
    expect(await check([await put()]), hasLength(1));
  });

  test('live period is half open; historical and future events cannot alert',
      () async {
    await budget();
    await put();
    expect(await check([await put(at: DateTime(2026, 9, 30))]), isEmpty);
    expect(await check([await put(at: DateTime(2026, 11))]), isEmpty);
    expect(await check([await put(at: DateTime(2026, 10))]), hasLength(1));
  });

  test('only confirmed expenses trigger, even when budget is already over',
      () async {
    await budget();
    await put();
    for (final status in [
      TransactionStatus.pending,
      TransactionStatus.ignored
    ]) {
      expect(await check([await put(status: status)]), isEmpty);
    }
    for (final type in [
      TransactionTypeEntity.income,
      TransactionTypeEntity.transfer,
      TransactionTypeEntity.refund,
      TransactionTypeEntity.unknown
    ]) {
      expect(await check([await put(type: type)]), isEmpty);
    }
    expect(await check([await put(type: TransactionTypeEntity.withdrawal)]),
        hasLength(1));
  });

  test('inactive budgets never alert', () async {
    await budget(active: false);
    expect(await check([await put()]), isEmpty);
  });

  test('mixed-account batch alerts once per affected budget', () async {
    await budget();
    final sofa = await put();
    final mina = await put(account: 'mina');
    expect(await check([mina, sofa, sofa]), hasLength(1));
  });

  test('empty, duplicate and nontransaction captures cannot alert', () async {
    await budget();
    final old = await put();
    expect(await check([]), isEmpty);
    expect(
        await check(
            newlyAddedTransactions(AddTransactionResult.duplicate(old))),
        isEmpty);
    expect(
        await check(newlyAddedTransactions(
            AddTransactionResult.notTransaction(ParseResult.notTransaction()))),
        isEmpty);
  });

  test('secondary expense alerts even when primary is an unrelated income',
      () async {
    await budget();
    final primary =
        await put(account: 'mina', type: TransactionTypeEntity.income);
    final fee = await put();
    final result = AddTransactionResult.added(
        primary, ParseResult.notTransaction(),
        secondary:
            AddTransactionResult.added(fee, ParseResult.notTransaction()));
    expect(await check(newlyAddedTransactions(result)), hasLength(1));
    final nextFee = await put(amount: '15');
    final duplicateWithNewFee =
        AddTransactionResult.duplicate(primary, secondary:
          AddTransactionResult.added(nextFee, ParseResult.notTransaction()));
    expect(
        await check(newlyAddedTransactions(duplicateWithNewFee)), hasLength(1));
  });
}
