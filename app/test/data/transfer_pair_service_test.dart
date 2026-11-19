// A transfer between two of the user's own accounts is two ordinary transfer
// rows sharing transfer_group_id: a debit leg on From, a credit leg on To.
// Totals already exclude transfers and every account view filters on
// account_id, so each leg is correct on its own. Synthetic data only.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/transfer_pair_service.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/bill_repository.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/common/transaction_direction.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// Records the bill-payment cleanup the manual delete path performs.
class _Bills implements BillRepository {
  final cleaned = <String>[];
  @override
  Future<List<String>> deletePaymentForTransaction(String transactionId) async {
    cleaned.add(transactionId);
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

const _a = 'acc-a';
const _b = 'acc-b';
const _usd = 'acc-usd';
final _at = DateTime.utc(2026, 7, 15, 10);
final _from = DateTime.utc(2026, 7, 1);
final _to = DateTime.utc(2026, 8, 1);

void main() {
  late AppDatabase db;
  late DriftTransactionRepository repo;
  late _Bills bills;
  late TransferPairService service;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    final outbox = LedgerOutboxQueue(
      db: db,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-1',
    );
    repo = DriftTransactionRepository(db, outboxQueue: outbox);
    bills = _Bills();
    service = TransferPairService(db: db, transactions: repo, bills: bills);
    for (final (id, currency, order) in [
      (_a, 'SAR', 0),
      (_b, 'SAR', 1),
      (_usd, 'USD', 2),
    ]) {
      await db.customStatement(
        "INSERT INTO accounts(id, name, currency, type, is_default, sort_order, "
        "created_at, updated_at) VALUES('$id', '$id', '$currency', 'bank', "
        "${order == 0 ? 1 : 0}, $order, '2026-01-01T00:00:00Z', "
        "'2026-01-01T00:00:00Z');",
      );
    }
    final food = (await db
            .customSelect("SELECT id FROM categories WHERE key = 'restaurants';")
            .getSingle())
        .read<String>('id');
    final income = (await db
            .customSelect("SELECT id FROM categories WHERE key = 'income';")
            .getSingle())
        .read<String>('id');
    // Ordinary spending and income on both accounts, so totals are non-zero.
    for (final (id, account, type, amount, category) in [
      ('pay-a', _a, 'payment', 40.0, food),
      ('pay-b', _b, 'payment', 25.5, food),
      ('inc-a', _a, 'income', 1000.0, income),
    ]) {
      await db.customStatement(
        "INSERT INTO transactions(id, amount, currency, type, source, "
        "occurred_at, raw_message, parse_confidence, status, created_at, "
        "updated_at, account_id, category_id) VALUES ('$id', $amount, 'SAR', "
        "'$type', 'bank', '2026-07-10T09:00:00.000Z', 'sms', 1.0, 'confirmed', "
        "'2026-07-10T09:00:00.000Z', '2026-07-10T09:00:00.000Z', '$account', "
        "'$category');",
      );
    }
    await backfillNonPlanningMoneyV30(db);
  });
  tearDown(() async => db.close());

  Money sar(String v) => Money.parse(v, 'SAR');

  Future<({TransactionEntity debit, TransactionEntity credit})> pay(
          {String amount = '300'}) =>
      service.savePair(
        fromAccountId: _a,
        toAccountId: _b,
        amountOut: sar(amount),
        amountIn: sar(amount),
        currencyOut: 'SAR',
        currencyIn: 'SAR',
        occurredAt: _at,
        note: 'to savings',
      );

  Future<List<Map<String, Object?>>> transfers() async => [
        for (final r in await db
            .customSelect("SELECT * FROM transactions WHERE type = 'transfer' "
                'ORDER BY direction, id;')
            .get())
          r.data,
      ];

  Future<List<String>> outboxOps(String id) async => [
        for (final r in await db
            .customSelect('SELECT operation FROM ledger_sync_outbox '
                "WHERE transaction_id = '$id';")
            .get())
          r.read<String>('operation'),
      ];

  test('savePair writes exactly two linked legs: debit on A, credit on B',
      () async {
    final pair = await pay();
    final rows = await transfers();
    expect(rows, hasLength(2));
    final credit = rows.firstWhere((r) => r['direction'] == 'credit');
    final debit = rows.firstWhere((r) => r['direction'] == 'debit');
    expect(debit['account_id'], _a);
    expect(credit['account_id'], _b);
    expect(debit['transfer_group_id'], isNotNull);
    expect(debit['transfer_group_id'], credit['transfer_group_id']);
    for (final r in rows) {
      expect(r['status'], 'confirmed');
      expect(r['amount_minor'], 30000);
      expect(r['note'], 'to savings');
    }
    expect(pair.debit.transferGroupId, debit['transfer_group_id']);
    expect(pair.credit.id, credit['id']);
    // Both legs are queued for sync like a manual transaction.
    expect(await outboxOps(pair.debit.id), ['create']);
    expect(await outboxOps(pair.credit.id), ['create']);
  });

  test('expense, income and category totals are unchanged by a transfer',
      () async {
    Future<List<Object>> snapshot() async => [
          for (final account in [null, _a, _b]) ...[
            await repo.expenseTotalBetween(
                from: _from, to: _to, currency: 'SAR', accountId: account),
            await repo.incomeTotalBetween(
                from: _from, to: _to, currency: 'SAR', accountId: account),
            [
              for (final c in await repo.categoryBreakdown(
                  from: _from, to: _to, currency: 'SAR', accountId: account))
                (c.categoryId, c.total, c.count),
            ],
          ],
        ];
    final before = await snapshot();
    expect(before.first, sar('65.5'), reason: 'the fixture has spending');
    await pay();
    expect(await snapshot(), before);
  });

  test('each account sees only its own leg, in the right direction', () async {
    final pair = await pay();
    final recentA = await repo.getRecent(limit: 50, accountId: _a);
    final recentB = await repo.getRecent(limit: 50, accountId: _b);
    final transfersA =
        recentA.where((t) => t.type == TransactionTypeEntity.transfer);
    final transfersB =
        recentB.where((t) => t.type == TransactionTypeEntity.transfer);
    expect(transfersA.map((t) => t.id), [pair.debit.id]);
    expect(transfersB.map((t) => t.id), [pair.credit.id]);
    expect(transactionIsDebit(transfersA.single), isTrue);
    expect(transactionIsDebit(transfersB.single), isFalse);
  });

  test('two identical transfers at the same time are both kept', () async {
    await pay();
    await pay();
    expect(await transfers(), hasLength(4));
  });

  test('different currencies: each leg keeps its own amount and currency',
      () async {
    final pair = await service.savePair(
      fromAccountId: _a,
      toAccountId: _usd,
      amountOut: sar('375'),
      amountIn: Money.parse('100', 'USD'),
      currencyOut: 'SAR',
      currencyIn: 'USD',
      occurredAt: _at,
    );
    final debit = (await repo.getById(pair.debit.id))!;
    final credit = (await repo.getById(pair.credit.id))!;
    expect((debit.amountMoney, debit.currency), (sar('375'), 'SAR'));
    expect((credit.amountMoney, credit.currency),
        (Money.parse('100', 'USD'), 'USD'));
    expect(credit.accountId, _usd);
  });

  test('rejects the same account and non-positive amounts', () async {
    expect(
        () => service.savePair(
              fromAccountId: _a,
              toAccountId: _a,
              amountOut: sar('1'),
              amountIn: sar('1'),
              currencyOut: 'SAR',
              currencyIn: 'SAR',
              occurredAt: _at,
            ),
        throwsArgumentError);
    expect(() => pay(amount: '0'), throwsArgumentError);
    expect(
        () => service.saveOutside(
              accountId: _a,
              amount: sar('-5'),
              currency: 'SAR',
              direction: TransactionDirectionEntity.debit,
              occurredAt: _at,
            ),
        throwsArgumentError);
    expect(await transfers(), isEmpty);
  });

  test('saveOutside writes one unlinked leg with the given direction',
      () async {
    final leg = await service.saveOutside(
      accountId: _b,
      amount: sar('50'),
      currency: 'SAR',
      direction: TransactionDirectionEntity.credit,
      occurredAt: _at,
      note: 'from a friend',
    );
    final rows = await transfers();
    expect(rows, hasLength(1));
    expect(rows.single['direction'], 'credit');
    expect(rows.single['account_id'], _b);
    expect(rows.single['transfer_group_id'], isNull);
    expect(await service.sibling(leg), isNull);
    expect(await outboxOps(leg.id), ['create']);
  });

  test('sibling finds the other leg from either side', () async {
    final pair = await pay();
    expect((await service.sibling(pair.debit))!.id, pair.credit.id);
    expect((await service.sibling(pair.credit))!.id, pair.debit.id);
  });

  test('updatePair changes both legs and queues an update for each',
      () async {
    final pair = await pay();
    await db.customStatement('DELETE FROM ledger_sync_outbox;'); // pushed
    final later = DateTime.utc(2026, 7, 20, 8);
    await service.updatePair(
      pair.credit,
      fromAccountId: _b,
      toAccountId: _usd,
      amountOut: sar('750'),
      amountIn: Money.parse('200', 'USD'),
      currencyOut: 'SAR',
      currencyIn: 'USD',
      occurredAt: later,
      note: 'reversed',
    );
    final debit = (await repo.getById(pair.debit.id))!;
    final credit = (await repo.getById(pair.credit.id))!;
    expect(debit.direction, TransactionDirectionEntity.debit);
    expect(debit.accountId, _b);
    expect(debit.amountMoney, sar('750'));
    expect(credit.direction, TransactionDirectionEntity.credit);
    expect(credit.accountId, _usd);
    expect((credit.amountMoney, credit.currency),
        (Money.parse('200', 'USD'), 'USD'));
    for (final leg in [debit, credit]) {
      expect(leg.occurredAt, later);
      expect(leg.note, 'reversed');
      expect(leg.transferGroupId, pair.debit.transferGroupId);
      expect(await outboxOps(leg.id), ['update']);
    }
    expect(await transfers(), hasLength(2));
  });

  test('updatePair on an old single-row transfer creates the sibling',
      () async {
    await db.customStatement(
      "INSERT INTO transactions(id, amount, currency, type, source, "
      "occurred_at, raw_message, parse_confidence, status, created_at, "
      "updated_at, account_id, direction) VALUES ('old', 120, 'SAR', "
      "'transfer', 'bank', '2026-07-05T09:00:00.000Z', 'sms', 1.0, "
      "'confirmed', '2026-07-05T09:00:00.000Z', '2026-07-05T09:00:00.000Z', "
      "'$_a', 'debit');",
    );
    await backfillNonPlanningMoneyV30(db);
    final old = (await repo.getById('old'))!;
    expect(await service.sibling(old), isNull);

    final pair = await service.updatePair(
      old,
      fromAccountId: _a,
      toAccountId: _b,
      amountOut: sar('120'),
      amountIn: sar('120'),
      currencyOut: 'SAR',
      currencyIn: 'SAR',
      occurredAt: old.occurredAt,
    );
    expect(pair.debit.id, 'old');
    final rows = await transfers();
    expect(rows, hasLength(2));
    expect(pair.debit.transferGroupId, isNotNull);
    expect(rows.map((r) => r['transfer_group_id']).toSet(),
        {pair.debit.transferGroupId});
    final credit = rows.firstWhere((r) => r['direction'] == 'credit');
    expect(credit['account_id'], _b);
    expect(credit['amount_minor'], 12000);
    expect(await outboxOps(credit['id']! as String), ['create']);
  });

  test('deletePair soft-deletes both legs with two outbox deletes', () async {
    final pair = await pay();
    await db.customStatement('DELETE FROM ledger_sync_outbox;'); // pushed
    await service.deletePair(pair.debit);
    for (final id in [pair.debit.id, pair.credit.id]) {
      expect((await repo.getById(id))!.status, TransactionStatus.ignored);
      expect(await outboxOps(id), ['delete']);
    }
    expect(bills.cleaned, unorderedEquals([pair.debit.id, pair.credit.id]));
    expect(await service.sibling(pair.debit), isNull);
  });

  test('deletePair with no live sibling deletes the single leg', () async {
    final pair = await pay();
    await repo.deleteTransaction(pair.credit.id); // other leg already gone
    await db.customStatement('DELETE FROM ledger_sync_outbox;');
    bills.cleaned.clear();
    await service.deletePair(pair.debit);
    expect((await repo.getById(pair.debit.id))!.status,
        TransactionStatus.ignored);
    expect(await outboxOps(pair.debit.id), ['delete']);
    expect(await outboxOps(pair.credit.id), isEmpty);
    expect(bills.cleaned, [pair.debit.id]);
  });

  test('deletePair after the other account was deleted works', () async {
    final pair = await pay();
    await DriftAccountRepository(db).delete(_b);
    // Deleting an account keeps its transactions, unassigned: the credit leg
    // is still a live, linked row.
    final orphan = (await repo.getById(pair.credit.id))!;
    expect(orphan.accountId, isNull);
    expect(orphan.status, TransactionStatus.confirmed);

    await service.deletePair(pair.debit);
    expect((await repo.getById(pair.debit.id))!.status,
        TransactionStatus.ignored);
    expect((await repo.getById(pair.credit.id))!.status,
        TransactionStatus.ignored);
  });
}
