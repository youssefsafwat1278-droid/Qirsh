import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/gamification_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/domain/repositories/user_settings_repository.dart';
import 'package:money_companion/domain/usecases/correct_category_usecase.dart';
import 'package:money_companion/domain/usecases/engagement_usecase.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

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

class _RecordingRules extends PlanningOutboxQueue {
  _RecordingRules(AppDatabase db)
      : super(
            db: db,
            isSyncEnabled: (_) => true,
            getAuthUserId: () async => 'user-1');

  final rules = <(String, String)>[];

  @override
  Future<bool> enqueueMerchantRule(PlanningSyncOperation op,
      {required String merchantKey, required String categoryKey}) async {
    rules.add((merchantKey, categoryKey));
    return true;
  }
}

class _Unused implements GamificationRepository, UserSettingsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unused ${invocation.memberName}');
}

class _CountingEngagement extends RecordEngagementUseCase {
  _CountingEngagement(TransactionRepository txs)
      : super(
            gamificationRepository: _Unused(),
            transactionRepository: txs,
            userSettingsRepository: _Unused());

  int calls = 0;

  @override
  Future<EngagementUpdate> call({
    required EngagementAction action,
    DateTime? occurredAt,
    double? goalProgressAfter,
    double? savedThisMonth,
  }) async {
    calls++;
    throw const _Recorded();
  }
}

class _Recorded implements Exception {
  const _Recorded();
}

/// Category provenance and the "also update past transactions" bulk update,
/// over a real in-memory database (one replica = one signed-in user).
void main() {
  late AppDatabase db;
  late _RecordingOutbox outbox;
  late _RecordingRules ruleQueue;
  late DriftTransactionRepository txs;
  late DriftMerchantCategoryRepository merchants;
  late CorrectCategoryUseCase correct;
  late List<String> offered;

  const merchant = 'ZARYAB DIMASHQI TRDG';
  final at = DateTime.utc(2026, 11, 1);

  Future<AppDatabase> openDb() => AppDatabase.open(
      executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

  Future<void> insertAccount(AppDatabase d, String id) => d.customStatement(
      "INSERT INTO accounts(id, name, type, currency, is_default, sort_order, "
      "created_at, updated_at) VALUES('$id', '$id', 'bank', 'SAR', 0, 0, "
      "'2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');");

  setUp(() async {
    db = await openDb();
    outbox = _RecordingOutbox(db);
    ruleQueue = _RecordingRules(db);
    txs = DriftTransactionRepository(db, outboxQueue: outbox);
    merchants = DriftMerchantCategoryRepository(db, outboxQueue: ruleQueue);
    offered = [];
    correct = CorrectCategoryUseCase(
      transactionRepository: txs,
      merchantCategoryRepository: merchants,
      offerSharedRule: (tx, key) async => offered.add(tx.id),
    );
    await insertAccount(db, 'acc-a');
    await insertAccount(db, 'acc-b');
  });

  tearDown(() => db.close());

  var seq = 0;
  Future<TransactionEntity> add({
    String m = merchant,
    String account = 'acc-a',
    TransactionSourceEntity source = TransactionSourceEntity.bank,
    CategoryProvenance? provenance = CategoryProvenance.auto,
    String category = 'groceries',
    bool imported = false,
    DrifTxRepo? repo,
  }) {
    seq++;
    return (repo ?? txs).saveTransaction(
      transaction: TransactionEntity(
        id: 'tx-$seq',
        amountMoney: Money(1000 + seq, 'SAR'),
        currency: 'SAR',
        type: TransactionTypeEntity.payment,
        source: source,
        occurredAt: at.add(Duration(minutes: seq)),
        rawMessage: 'synthetic $seq',
        rawMerchant: m,
        accountId: account,
        parseConfidence: 1,
        status: TransactionStatus.confirmed,
        createdAt: at,
        updatedAt: at,
        categoryProvenance: provenance,
        importedFromFile: imported,
      ),
      categoryKey: category,
    );
  }

  Future<String> sourceOf(String id, [AppDatabase? d]) async => (await (d ??
              db)
          .customSelect('SELECT category_source FROM transactions WHERE id = ?',
              variables: [Variable.withString(id)])
          .getSingle())
      .read<String>('category_source');

  Future<String?> keyOf(String id, [AppDatabase? d]) async => (await (d ?? db)
          .customSelect(
              'SELECT c.key AS k FROM transactions t LEFT JOIN categories c '
              'ON c.id = t.category_id WHERE t.id = ?',
              variables: [Variable.withString(id)])
          .getSingle())
      .read<String?>('k');

  Future<PastCategoryUpdatePlan> preview(TransactionEntity t,
          [PastUpdateOverrides o = const PastUpdateOverrides()]) =>
      correct.previewPastUpdate(
          transaction: t, categoryKey: 'restaurants', overrides: o);

  Future<void> rememberAndUpdatePast(TransactionEntity t,
          [PastUpdateOverrides o = const PastUpdateOverrides()]) =>
      correct(
        transactionId: t.id,
        categoryKey: 'restaurants',
        scope: CategoryCorrectionScope.allMerchantTransactions,
        alsoUpdatePast: true,
        overrides: o,
      );

  group('recorded provenance', () {
    test('new rows keep what the capture said; a hand edit is the user\'s',
        () async {
      final auto = await add();
      final rule = await add(provenance: CategoryProvenance.rule);
      final manual = await add(
          source: TransactionSourceEntity.unknown, provenance: null);
      final imported = await add(
          source: TransactionSourceEntity.imported, provenance: null);
      expect(await sourceOf(auto.id), 'auto');
      expect(await sourceOf(rule.id), 'rule');
      expect(await sourceOf(manual.id), 'user');
      expect(await sourceOf(imported.id), 'unknown');

      await correct(
          transactionId: auto.id,
          categoryKey: 'restaurants',
          scope: CategoryCorrectionScope.thisTransactionOnly);
      expect(await sourceOf(auto.id), 'user');
    });

    test('editing a note or amount never changes provenance', () async {
      final t = await add();
      await txs.updateTransaction(
        transactionId: t.id,
        amount: Money(4321, 'SAR'),
        currency: 'SAR',
        type: t.type,
        occurredAt: t.occurredAt,
        rawMerchant: t.rawMerchant,
        categoryId: t.categoryId,
        note: 'lunch with team',
      );
      expect(await sourceOf(t.id), 'auto');

      final edited = await add();
      final plan = await preview(edited);
      expect(plan.eligible.map((e) => e.id), contains(t.id),
          reason: 'an unrelated edit must not block future corrections');
    });

    test('changing the category in the full edit form is a user choice',
        () async {
      final t = await add();
      final other = await txs.categoryIdForKey('restaurants');
      await txs.updateTransaction(
        transactionId: t.id,
        amount: t.amountMoney,
        currency: 'SAR',
        type: t.type,
        occurredAt: t.occurredAt,
        rawMerchant: t.rawMerchant,
        categoryId: other,
        note: null,
      );
      expect(await sourceOf(t.id), 'user');
    });
  });

  group('preview and protection', () {
    test('every exclusion has a reason, and apply changes exactly the preview',
        () async {
      final eligibleAuto = await add();
      final eligibleRule = await add(provenance: CategoryProvenance.rule);
      final chosen = await add(provenance: CategoryProvenance.user);
      final unknown = await add(provenance: CategoryProvenance.unknown);
      final manual = await add(
          source: TransactionSourceEntity.unknown, provenance: null);
      final imported = await add(
          source: TransactionSourceEntity.imported, provenance: null);
      final ignored = await add();
      await txs.deleteTransaction(ignored.id);
      final already = await add(category: 'restaurants');
      final edited = await add();

      final plan = await preview(edited);
      expect(plan.eligible.map((e) => e.id).toSet(),
          {eligibleAuto.id, eligibleRule.id});
      Set<String> ids(PastUpdateExclusion r) =>
          (plan.excluded[r] ?? const []).map((e) => e.id).toSet();
      expect(ids(PastUpdateExclusion.chosenByYou), {chosen.id});
      expect(ids(PastUpdateExclusion.unknownOrigin), {unknown.id});
      expect(ids(PastUpdateExclusion.manual), {manual.id});
      expect(ids(PastUpdateExclusion.imported), {imported.id});
      expect(ids(PastUpdateExclusion.ignored), {ignored.id});
      expect(plan.alreadyInCategory, 1);
      expect(plan.totalExcluded, 5);

      await rememberAndUpdatePast(edited);
      for (final t in [eligibleAuto, eligibleRule]) {
        expect(await keyOf(t.id), 'restaurants');
        expect(await sourceOf(t.id), 'rule');
      }
      for (final t in [chosen, unknown, manual, imported, ignored]) {
        expect(await keyOf(t.id), 'groceries', reason: '${t.id} protected');
      }
      expect(await sourceOf(chosen.id), 'user');
      expect(await keyOf(already.id), 'restaurants');
    });

    test('hand-picked rows change only through the explicit override',
        () async {
      final chosen = await add(provenance: CategoryProvenance.user);
      final unknown = await add(provenance: CategoryProvenance.unknown);
      final edited = await add();

      await rememberAndUpdatePast(
          edited, const PastUpdateOverrides(includeUnknown: true));
      expect(await keyOf(unknown.id), 'restaurants');
      expect(await keyOf(chosen.id), 'groceries',
          reason: 'including unknown never includes hand-picked rows');

      await rememberAndUpdatePast(
          edited, const PastUpdateOverrides(includeChosenByYou: true));
      expect(await keyOf(chosen.id), 'restaurants');
    });
  });

  group('imported from a file', () {
    Future<int> markerOf(String id) async => (await db
            .customSelect(
                'SELECT imported_from_file FROM transactions WHERE id = ?',
                variables: [Variable.withString(id)])
            .getSingle())
        .read<int>('imported_from_file');

    test('keeps its original source and survives unrelated and category edits',
        () async {
      final t = await add(imported: true, provenance: CategoryProvenance.unknown);
      expect((await txs.getById(t.id))!.source, TransactionSourceEntity.bank);
      expect(await markerOf(t.id), 1);
      await txs.updateTransaction(
        transactionId: t.id,
        amount: Money(9, 'SAR'),
        currency: 'SAR',
        type: t.type,
        occurredAt: t.occurredAt,
        rawMerchant: t.rawMerchant,
        categoryId: await txs.categoryIdForKey('travel'),
        note: 'n',
      );
      await correct(
          transactionId: t.id,
          categoryKey: 'restaurants',
          scope: CategoryCorrectionScope.thisTransactionOnly);
      expect(await markerOf(t.id), 1, reason: 'the marker is never cleared');
      expect((await txs.getById(t.id))!.importedFromFile, isTrue);
    });

    test('stays excluded even with "include unknown origin"', () async {
      final imp = await add(imported: true, provenance: CategoryProvenance.unknown);
      final impAuto = await add(imported: true, provenance: CategoryProvenance.auto);
      final edited = await add();
      final plan = await preview(
          edited, const PastUpdateOverrides(includeUnknown: true));
      expect(plan.eligible.map((e) => e.id), isNot(contains(imp.id)));
      expect(plan.eligible.map((e) => e.id), isNot(contains(impAuto.id)));
      expect((plan.excluded[PastUpdateExclusion.imported] ?? [])
          .map((e) => e.id)
          .toSet(), {imp.id, impAuto.id});

      await rememberAndUpdatePast(
          edited, const PastUpdateOverrides(includeUnknown: true));
      expect(await keyOf(imp.id), 'groceries');
      expect(await keyOf(impAuto.id), 'groceries');
    });

    test('changes only through its own opt-in; hand-picked still needs that one',
        () async {
      final imp = await add(imported: true, provenance: CategoryProvenance.unknown);
      final impChosen =
          await add(imported: true, provenance: CategoryProvenance.user);
      final edited = await add();
      const opt = PastUpdateOverrides(includeImported: true);
      final plan = await preview(edited, opt);
      expect(plan.eligible.map((e) => e.id), contains(imp.id));
      expect((plan.excluded[PastUpdateExclusion.chosenByYou] ?? [])
          .map((e) => e.id), [impChosen.id]);

      await rememberAndUpdatePast(edited, opt);
      expect(await keyOf(imp.id), 'restaurants');
      expect(await keyOf(impChosen.id), 'groceries');
      expect(await markerOf(imp.id), 1);
    });
  });

  test('applies across every account and card of the same user only',
      () async {
    final a = await add(account: 'acc-a');
    final b = await add(account: 'acc-b');
    final edited = await add(account: 'acc-a');

    // Another signed-in user's replica is a different database file.
    final otherDb = await openDb();
    addTearDown(otherDb.close);
    await insertAccount(otherDb, 'acc-a');
    final otherRepo = DriftTransactionRepository(otherDb);
    final foreign = await add(repo: otherRepo);

    await rememberAndUpdatePast(edited);
    expect(await keyOf(a.id), 'restaurants');
    expect(await keyOf(b.id), 'restaurants');
    expect(await keyOf(foreign.id, otherDb), 'groceries');
  });

  group('verified aliases only', () {
    Future<String> merchantIdOf(String id) async => (await db
            .customSelect('SELECT merchant_id FROM transactions WHERE id = ?',
                variables: [Variable.withString(id)])
            .getSingle())
        .read<String>('merchant_id');

    test('a similar name never matches without a verified alias', () async {
      final similar = await add(m: 'ZARYAB DIMASHQI');
      final typo = await add(m: 'ZARYAB DIMASHKI TRDG');
      final digits = await add(m: 'ZARYAB  DIMASHQI TRDG 42');
      final edited = await add();
      final plan = await preview(edited);
      expect(plan.eligible.map((e) => e.id).toSet(), {digits.id},
          reason: 'only the deterministic key (digits/spacing) matches');
      expect(plan.eligible.map((e) => e.id), isNot(contains(similar.id)));
      expect(plan.eligible.map((e) => e.id), isNot(contains(typo.id)));
    });

    test('a confirmed alias matches, and revoking it restores the old matching',
        () async {
      final aliased = await add(m: 'ZARYAB DIMASHQI');
      final edited = await add();
      await db.customStatement(
          "INSERT INTO merchant_aliases(alias_normalized, merchant_id, origin, "
          "created_at) VALUES('ZARYAB DIMASHQI', "
          "'${await merchantIdOf(edited.id)}', 'user', '2026-11-01T00:00:00Z');");
      expect((await preview(edited)).eligible.map((e) => e.id),
          contains(aliased.id));
      // From the alias side too: same merchant either way.
      expect((await preview(aliased)).eligible.map((e) => e.id),
          contains(edited.id));

      await db.customStatement("UPDATE merchant_aliases SET revoked_at = "
          "'2026-11-02T00:00:00Z' WHERE alias_normalized = 'ZARYAB DIMASHQI';");
      expect((await preview(edited)).eligible.map((e) => e.id),
          isNot(contains(aliased.id)));
    });
  });

  test('repeating the same bulk update has no side effects', () async {
    await add();
    await add();
    final edited = await add();
    final engagement = _CountingEngagement(txs);
    final counted = CorrectCategoryUseCase(
      transactionRepository: txs,
      merchantCategoryRepository: merchants,
      recordEngagementUseCase: engagement,
      offerSharedRule: (tx, key) async => offered.add(tx.id),
    );
    Future<void> run() async {
      try {
        await counted(
          transactionId: edited.id,
          categoryKey: 'restaurants',
          scope: CategoryCorrectionScope.allMerchantTransactions,
          alsoUpdatePast: true,
        );
      } on _Recorded {
        // The counting fake throws after recording; the writes already ran.
      }
    }

    outbox.enqueued.clear(); // the three creates above
    await run();
    expect(outbox.enqueued.length, 3, reason: 'edited row + two past rows');
    expect(ruleQueue.rules, [(merchant, 'restaurants')]);
    expect(engagement.calls, 1);
    expect(offered, [edited.id]);

    outbox.enqueued.clear();
    await run();
    await run();
    expect(outbox.enqueued, isEmpty, reason: 'no duplicate sync events');
    expect(ruleQueue.rules.length, 1, reason: 'no duplicate rule sync');
    expect(engagement.calls, 1, reason: 'no duplicate correction feedback');
    expect(offered.length, 1, reason: 'no duplicate shared offer');
  });
}

typedef DrifTxRepo = DriftTransactionRepository;
