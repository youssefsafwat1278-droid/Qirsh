// Owner brief 4.6: a confirmed transaction can be moved back into review, and
// confirming it again restores it. Plus the bank-reported balance with its
// time (latestReportedBalance). Synthetic data only.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/confirm_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/mark_for_review_usecase.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;
  late DriftTransactionRepository repo;
  late String categoryId;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    repo = DriftTransactionRepository(
      db,
      outboxQueue: LedgerOutboxQueue(
        db: db,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-1',
      ),
    );
    categoryId = (await db
            .customSelect('SELECT id FROM categories ORDER BY id LIMIT 1;')
            .getSingle())
        .read<String>('id');
  });
  tearDown(() async => db.close());

  Future<void> insert({
    required String id,
    String status = 'confirmed',
    String categorySource = 'user',
    double? balanceAfter,
    String occurredAt = '2026-07-20T10:00:00.000Z',
  }) async {
    await db.customStatement('''
      INSERT INTO transactions(
        id, amount, currency, type, source, category_id, category_source,
        balance_after, occurred_at, raw_message, parse_confidence, status,
        created_at, updated_at
      ) VALUES (
        '$id', 45.5, 'SAR', 'payment', 'bank', '$categoryId', '$categorySource',
        ${balanceAfter ?? 'NULL'}, '$occurredAt', 'm', 1.0, '$status',
        '$occurredAt', '$occurredAt'
      );
    ''');
    await backfillNonPlanningMoneyV30(db);
  }

  Future<List<Map<String, Object?>>> outbox(String id) async => (await db
          .customSelect(
              "SELECT operation, payload_json FROM ledger_sync_outbox "
              "WHERE transaction_id = '$id';")
          .get())
      .map((r) => {
            'operation': r.read<String>('operation'),
            'payload': jsonDecode(r.read<String>('payload_json')),
          })
      .toList();

  Future<List<String>> proofEvents(String id) async => (await db
          .customSelect(
              "SELECT event_type FROM proof_correction_events "
              "WHERE transaction_id = '$id' ORDER BY occurred_at, id;")
          .get())
      .map((r) => r.read<String>('event_type'))
      .toList();

  Future<Money> spend() => repo.expenseTotalBetween(
      from: DateTime.utc(2026, 7, 1),
      to: DateTime.utc(2026, 8, 1),
      currency: 'SAR');

  test('a confirmed transaction moves into review: pending, out of totals, '
      'amount and manual category kept, sync update queued, provenance logged',
      () async {
    await insert(id: 't1');
    expect(await spend(), Money(4550, 'SAR'));

    final moved = await MarkForReviewUseCase(repo)('t1');

    expect(moved.status, TransactionStatus.pending);
    expect(moved.amountMoney, Money(4550, 'SAR'));
    expect(moved.categoryId, categoryId);
    expect(moved.categoryProvenance, CategoryProvenance.user);
    expect(await spend(), Money(0, 'SAR'));
    final queued = await outbox('t1');
    expect(queued, hasLength(1));
    expect(queued.single['operation'], 'update');
    expect((queued.single['payload'] as Map)['status'], 'pending');
    expect(await proofEvents('t1'), ['rejected_or_deleted']);
  });

  test('moving into review is idempotent', () async {
    await insert(id: 't1');
    await repo.markForReview('t1');
    final before = await outbox('t1');
    final again = await repo.markForReview('t1');
    expect(again.status, TransactionStatus.pending);
    expect(await proofEvents('t1'), ['rejected_or_deleted']);
    expect(await outbox('t1'), before);
  });

  test('confirming again restores it in place, without a duplicate', () async {
    await insert(id: 't1', categorySource: 'rule');
    await repo.markForReview('t1');
    final restored = await ConfirmTransactionUseCase(repo)('t1');

    expect(restored.status, TransactionStatus.confirmed);
    expect(restored.amountMoney, Money(4550, 'SAR'));
    expect(restored.categoryId, categoryId);
    expect(restored.categoryProvenance, CategoryProvenance.rule);
    expect(await spend(), Money(4550, 'SAR'));
    final rows = await db.customSelect('SELECT COUNT(*) AS n FROM transactions;')
        .getSingle();
    expect(rows.read<int>('n'), 1);
    final queued = await outbox('t1');
    expect(queued, hasLength(1), reason: 'coalesced into one pending update');
    expect((queued.single['payload'] as Map)['status'], 'confirmed');
  });

  test('pending and ignored rows are left as they are; unknown ids throw',
      () async {
    await insert(id: 'p', status: 'pending');
    await insert(id: 'i', status: 'ignored');
    expect((await repo.markForReview('p')).status, TransactionStatus.pending);
    expect((await repo.markForReview('i')).status, TransactionStatus.ignored);
    expect(await outbox('p'), isEmpty);
    expect(await outbox('i'), isEmpty);
    expect(await proofEvents('p'), isEmpty);
    expect(() => repo.markForReview('missing'), throwsStateError);
  });

  test('latestReportedBalance returns the latest balance with its bank time; '
      'latestBalanceAfter is unchanged', () async {
    await insert(id: 'a', balanceAfter: 300, occurredAt: '2026-07-20T10:00:00.000Z');
    await insert(id: 'b', balanceAfter: 250, occurredAt: '2026-07-22T08:30:00.000Z');
    await insert(id: 'c', occurredAt: '2026-07-23T08:30:00.000Z');

    final reported = await repo.latestReportedBalance();
    expect(reported?.balance, Money(25000, 'SAR'));
    expect(reported?.occurredAt, DateTime.utc(2026, 7, 22, 8, 30));
    expect(await repo.latestBalanceAfter(), reported?.balance);

    // A row in review is not a confirmed balance on either query.
    await repo.markForReview('b');
    expect((await repo.latestReportedBalance())?.occurredAt,
        DateTime.utc(2026, 7, 20, 10));
    expect(await repo.latestBalanceAfter(), Money(30000, 'SAR'));
  });

  test('no balance: null', () async {
    await insert(id: 'a');
    expect(await repo.latestReportedBalance(), isNull);
  });
}
