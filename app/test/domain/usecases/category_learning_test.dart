import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/correct_category_usecase.dart';
import 'package:money_companion/domain/usecases/learned_rules_usecase.dart';
import 'package:money_companion/engine/intelligence/merchant_intelligence_store.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// Records what reaches the sync outbox instead of writing it.
class _RecordingOutbox extends LedgerOutboxQueue {
  _RecordingOutbox(AppDatabase db)
      : super(
            db: db,
            isPushEnabled: () => true,
            getAuthUserId: () async => 'user-1');

  final enqueued = <(OutboxOperation, String)>[];

  @override
  Future<void> enqueue(OutboxOperation op, TransactionEntity tx) async {
    enqueued.add((op, tx.id));
  }
}

/// Local category learning: "remember for this merchant", "also update past
/// transactions", and the Learned rules list — over a real in-memory database.
void main() {
  late AppDatabase db;
  late _RecordingOutbox outbox;
  late DriftTransactionRepository transactions;
  late DriftMerchantCategoryRepository merchants;
  late MerchantIntelligenceStore model;
  late AddTransactionUseCase addTransaction;
  late CorrectCategoryUseCase correctCategory;
  late LearnedRulesUseCase learnedRules;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    outbox = _RecordingOutbox(db);
    transactions = DriftTransactionRepository(db, outboxQueue: outbox);
    merchants = DriftMerchantCategoryRepository(db);
    model = MerchantIntelligenceStore();
    addTransaction = AddTransactionUseCase(
      transactionRepository: transactions,
      merchantCategoryRepository: merchants,
      merchantIntelligence: model,
    );
    correctCategory = CorrectCategoryUseCase(
      transactionRepository: transactions,
      merchantCategoryRepository: merchants,
      merchantIntelligence: model,
    );
    learnedRules = LearnedRulesUseCase(
      merchantCategoryRepository: merchants,
      merchantIntelligence: model,
    );
  });

  tearDown(() async => db.close());

  // Unknown to the shipped catalog and to the model.
  const merchant = 'ZARYAB DIMASHQI TRDG';
  String sms(int day, {String m = merchant}) =>
      'عملية شراء\nمبلغ:SAR 1$day.00\nلدى:$m\nفي:2026-04-${day.toString().padLeft(2, '0')} 18:30';

  Future<TransactionEntity> capture(int day, {String m = merchant}) async =>
      (await addTransaction(rawMessage: sms(day, m: m))).transaction!;

  Future<String?> categoryKeyOf(String id) async {
    final row = await db.customSelect(
      'SELECT c.key AS k FROM transactions t '
      'LEFT JOIN categories c ON c.id = t.category_id WHERE t.id = ?;',
      variables: [Variable.withString(id)],
    ).getSingle();
    return row.read<String?>('k');
  }

  test('the default edit changes only that transaction and teaches nothing',
      () async {
    final a = await capture(1);
    final b = await capture(2);
    final base = await categoryKeyOf(b.id);
    expect(base, isNot('restaurants'));

    await correctCategory(
      transactionId: a.id,
      categoryKey: 'restaurants',
      scope: CategoryCorrectionScope.thisTransactionOnly,
    );

    expect(await categoryKeyOf(a.id), 'restaurants');
    expect(await categoryKeyOf(b.id), base);
    expect(await merchants.getUserConfirmedRules(), isEmpty);
    expect(model.learnedCount, 0);
    final next = await capture(3);
    expect(await categoryKeyOf(next.id), base,
        reason: 'a one-off edit must not become a rule');
  });

  test('"remember" creates a rule the next capture of that merchant follows',
      () async {
    final a = await capture(1);

    await correctCategory(
      transactionId: a.id,
      categoryKey: 'restaurants',
      scope: CategoryCorrectionScope.allMerchantTransactions,
    );

    final rules = await merchants.getUserConfirmedRules();
    expect(rules.map((r) => (r.rawMerchant, r.categoryKey)),
        [(merchant, 'restaurants')]);
    // Same normalised merchant: digits and spacing differ.
    final next = await capture(4, m: 'ZARYAB  DIMASHQI TRDG 77');
    expect(await categoryKeyOf(next.id), 'restaurants');
  });

  test('"remember" alone leaves past transactions as they were', () async {
    final past = await capture(1);
    final base = await categoryKeyOf(past.id);
    final edited = await capture(2);

    await correctCategory(
      transactionId: edited.id,
      categoryKey: 'restaurants',
      scope: CategoryCorrectionScope.allMerchantTransactions,
    );

    expect(await categoryKeyOf(past.id), base);
  });

  test(
      'also updating past transactions: count matches, hand-set ones are '
      'untouched, and every change is enqueued for sync', () async {
    final auto1 = await capture(1);
    final auto2 = await capture(2);
    final handSet = await capture(3);
    final other = await capture(4, m: 'MAKANI ROASTERY');
    final edited = await capture(5);
    // The user set this one by hand earlier.
    await correctCategory(
      transactionId: handSet.id,
      categoryKey: 'shopping',
      scope: CategoryCorrectionScope.thisTransactionOnly,
    );
    final otherBefore = await categoryKeyOf(other.id);

    final count = await correctCategory.countPastToUpdate(
        transaction: edited, categoryKey: 'restaurants');
    expect(count, 2);

    outbox.enqueued.clear();
    await correctCategory(
      transactionId: edited.id,
      categoryKey: 'restaurants',
      scope: CategoryCorrectionScope.allMerchantTransactions,
      alsoUpdatePast: true,
    );

    expect(await categoryKeyOf(edited.id), 'restaurants');
    expect(await categoryKeyOf(auto1.id), 'restaurants');
    expect(await categoryKeyOf(auto2.id), 'restaurants');
    expect(await categoryKeyOf(handSet.id), 'shopping');
    expect(await categoryKeyOf(other.id), otherBefore);
    expect(
      outbox.enqueued.toSet(),
      {
        (OutboxOperation.update, edited.id),
        (OutboxOperation.update, auto1.id),
        (OutboxOperation.update, auto2.id),
      },
    );
    // Applied by the rule, not by hand: nothing left to update, and a later
    // re-teach can still move these rows.
    expect(
        await correctCategory.countPastToUpdate(
            transaction: edited, categoryKey: 'cafes'),
        2);
  });

  test('a rule-applied update does not confirm a pending transaction',
      () async {
    final auto = await capture(1);
    await db.customStatement(
        "UPDATE transactions SET status = 'pending' WHERE id = '${auto.id}';");
    final edited = await capture(2);

    await correctCategory(
      transactionId: edited.id,
      categoryKey: 'restaurants',
      scope: CategoryCorrectionScope.allMerchantTransactions,
      alsoUpdatePast: true,
    );

    final after = await transactions.getById(auto.id);
    expect(await categoryKeyOf(auto.id), 'restaurants');
    expect(after!.status, TransactionStatus.pending);
  });

  test('learned rules list only user-confirmed rules; delete and undo work',
      () async {
    final seededBefore = await merchants.getLearnedCategoryMap();
    expect(seededBefore, isNotEmpty, reason: 'catalog seed rows exist');
    expect(await learnedRules.list(), isEmpty,
        reason: 'seed mappings are not user rules');

    final a = await capture(1);
    final base = await categoryKeyOf(a.id);
    await correctCategory(
      transactionId: a.id,
      categoryKey: 'restaurants',
      scope: CategoryCorrectionScope.allMerchantTransactions,
    );
    final rules = await learnedRules.list();
    expect(rules, hasLength(1));
    expect(model.predict(merchant)?.categoryKey, 'restaurants');

    await learnedRules.delete(rules.single);
    expect(await learnedRules.list(), isEmpty);
    expect(model.predict(merchant), isNull,
        reason: 'the model must not keep suggesting a deleted rule');
    expect(await categoryKeyOf((await capture(6)).id), base);

    await learnedRules.restore(rules.single);
    expect((await learnedRules.list()).single.categoryKey, 'restaurants');
    expect(model.predict(merchant)?.categoryKey, 'restaurants');
    expect(await categoryKeyOf((await capture(7)).id), 'restaurants');
  });

  test('deleting a rule on a catalog merchant restores the catalog mapping',
      () async {
    final a = await capture(1, m: 'STARBUCKS');
    expect(await categoryKeyOf(a.id), 'cafes');
    await correctCategory(
      transactionId: a.id,
      categoryKey: 'restaurants',
      scope: CategoryCorrectionScope.allMerchantTransactions,
    );
    expect(await categoryKeyOf((await capture(2, m: 'STARBUCKS')).id),
        'restaurants');

    await learnedRules.delete((await learnedRules.list()).single);

    expect(await learnedRules.list(), isEmpty);
    expect(await categoryKeyOf((await capture(3, m: 'STARBUCKS')).id), 'cafes');
  });
}
