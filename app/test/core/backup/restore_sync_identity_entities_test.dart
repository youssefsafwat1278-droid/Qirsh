// V1-020 / decision 3.3 — per-entity proof that a restore keeps each synced
// row's server identity (the backup format carries none) and leaves the right
// intent for the normal sync machinery, plus the local-only (guest) guard.
// A device holding records MERGES (its copies are kept untouched unless the
// backup's copy is newer); a device with none takes the full-apply path, which
// rebinds the identity of the rows it replaces. Real restore use
// case, snapshot builder, PendingSyncReconciler and outbox queues on an
// in-memory database; no network. Synthetic data only.
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/core/sync/pending_sync_reconciler.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

const _t = '2026-01-01T00:00:00.000Z';
const _base = '2026-08-01T00:00:00.000Z';

/// table -> (sync key expression, live parent?).
const _keys = {
  'accounts': 'id',
  'categories': 'id',
  'cards': 'id',
  'transactions': 'id',
  'budgets': 'id',
  'goals': 'id',
  'goal_contributions': 'id',
  'subscriptions': 'id',
  'bill_payments': 'id',
  'plans': 'id',
  'plan_transaction_links': "plan_id || ':' || transaction_id",
  'user_settings': 'id',
};

Future<Set<String>> _cols(AppDatabase db, String table) async => {
      for (final r in await db.customSelect('PRAGMA table_info($table);').get())
        r.read<String>('name'),
    };

Future<List<Map<String, Object?>>> _q(AppDatabase db, String sql) async =>
    (await db.customSelect(sql).get()).map((r) => r.data).toList();

Future<void> _account(AppDatabase db, String id) => db.customStatement(
    'INSERT INTO accounts(id,name,currency,type,is_default,sort_order,'
    "created_at,updated_at) VALUES('$id','Synthetic','SAR','bank',1,1,"
    "'$_t','$_t');");

Future<void> _seedEveryFamily(AppDatabase db) async {
  const acc = 'e-acc';
  await _account(db, acc);
  final cat = (await _q(db, 'SELECT id FROM categories LIMIT 1;')).single['id'];
  for (final sql in [
    "INSERT INTO merchants(id,raw_name,normalized_name,first_seen_at,last_seen_at) "
        "VALUES('e-m','Shop','shop','$_t','$_t');",
    "INSERT INTO cards(id,account_id,last4,network,created_at,updated_at) "
        "VALUES('e-card','$acc','4242','visa','$_t','$_t');",
    "INSERT INTO transactions(id,account_id,amount,amount_minor,currency,type,source,"
        "status,raw_message,parse_confidence,occurred_at,created_at,updated_at) "
        "VALUES('e-tx','$acc',10.0,1000,'SAR','payment','bank','confirmed','',1.0,"
        "'$_t','$_t','$_t');",
    "INSERT INTO budgets(id,category_id,currency,amount,amount_minor,period,start_date,"
        "is_active,last_notified_spent_amount,last_notified_spent_amount_minor,"
        "last_notified_period_start,show_on_header) VALUES('e-bud','$cat','SAR',10.0,"
        "1000,'monthly','$_t',1,0,0,'$_t',0);",
    "INSERT INTO goals(id,name,currency,target_amount,target_amount_minor,saved_amount,"
        "saved_amount_minor,vault_skin,status,created_at,last_notified_saved_amount,"
        "last_notified_saved_amount_minor) VALUES('e-goal','G','SAR',100.0,10000,5.0,"
        "500,'default','active','$_t',0,0);",
    "INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at) "
        "VALUES('e-gc','e-goal',5.0,500,'$_t');",
    "INSERT INTO subscriptions(id,merchant_id,name,amount,amount_minor,currency,type,"
        "period,frequency,next_due_date,reminder_on,is_confirmed,status,created_at) "
        "VALUES('e-sub','e-m','S',9.0,900,'SAR','subscription','monthly','monthly',"
        "'2026-02-01T00:00:00.000Z',1,1,'active','$_t');",
    "INSERT INTO bill_payments(id,bill_id,amount,amount_minor,currency,period_start,"
        "period_end,paid_at) VALUES('e-bp','e-sub',9.0,900,'SAR','$_t',"
        "'2026-02-01T00:00:00.000Z','2026-01-05T00:00:00.000Z');",
    "INSERT INTO plans(id,name,budget_amount,budget_amount_minor,currency,start_date,"
        "end_date,status,created_at) VALUES('e-plan','P',50.0,5000,'SAR','$_t',"
        "'2026-02-01T00:00:00.000Z','active','$_t');",
    "INSERT INTO plan_transaction_links(plan_id,transaction_id,created_at) "
        "VALUES('e-plan','e-tx','$_t');",
  ]) {
    await db.customStatement(sql);
  }
  // Every row of every synced family is cloud-bound and synced.
  for (final e in _keys.entries) {
    final rev =
        (await _cols(db, e.key)).contains('server_revision') ? ', server_revision = 7' : '';
    await db.customStatement(
        "UPDATE ${e.key} SET server_id = 'srv:' || ${e.value}, "
        "server_updated_at = '$_base', sync_status = 'synced'$rev;");
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _Keys());
  });
  tearDown(() => db.close());

  Future<Map<String, dynamic>> backup() async =>
      Map<String, dynamic>.from(await BackupSnapshotBuilder(db).build());

  for (final e in _keys.entries) {
    test('${e.key}: restoring onto a device that holds the same rows keeps '
        'each row, its server identity, base tokens and synced state (merge)',
        () async {
      await _seedEveryFamily(db);
      await RestoreBackupUseCase(db)(await backup());
      final cols = await _cols(db, e.key);
      final rows = await _q(
          db,
          'SELECT ${e.value} AS k, server_id, server_updated_at, sync_status'
          '${cols.contains('server_revision') ? ', server_revision' : ''} '
          'FROM ${e.key};');
      expect(rows, isNotEmpty);
      for (final r in rows) {
        expect(r['server_id'], 'srv:${r['k']}', reason: 'identity lost');
        expect(r['server_updated_at'], _base);
        if (cols.contains('server_revision')) {
          expect(r['server_revision'], 7);
        }
        expect(r['sync_status'], 'synced',
            reason: 'an unchanged device copy needs no new intent');
      }
    });
  }

  test('new device (no records yet): the full apply rebinds the identity of '
      'every synced row it replaces and leaves an update intent', () async {
    await _account(db, 'n-acc');
    await db.customStatement(
        "INSERT INTO cards(id,account_id,last4,network,created_at,updated_at) "
        "VALUES('n-card','n-acc','4242','visa','$_t','$_t');");
    for (final t in ['accounts', 'cards', 'categories', 'user_settings']) {
      await db.customStatement(
          "UPDATE $t SET server_id = 'srv:' || id, "
          "server_updated_at = '$_base', sync_status = 'synced';");
    }
    await RestoreBackupUseCase(db)(await backup());
    for (final t in ['accounts', 'cards', 'categories', 'user_settings']) {
      final rows = await _q(
          db, 'SELECT id, server_id, server_updated_at, sync_status FROM $t;');
      expect(rows, isNotEmpty, reason: t);
      for (final r in rows) {
        expect(r['server_id'], 'srv:${r['id']}', reason: '$t identity lost');
        expect(r['server_updated_at'], _base);
        expect(r['sync_status'], 'pending', reason: t);
      }
    }
  });

  test('a merge keeps every pull cursor (nothing pulled was removed) and '
      'records no intent for unchanged rows', () async {
    await _seedEveryFamily(db);
    final snapshot = await backup();
    // Cursors of the restored domains are reset; unrelated keys are kept.
    for (final key in [
      'ledger_transactions',
      'accounts',
      'planning_budget',
      'planning_child_goal_contributions',
      'seq:user-1:ledger_transactions',
      'seq:user-1:planning_goal',
      'seq:user-1:accounts',
      'seq_epoch:user-1',
      'smart_inbox',
      'budget_warning_v1:user-1',
    ]) {
      await db.customStatement(
          "INSERT INTO sync_cursors(entity,last_updated_at,last_id) "
          "VALUES('$key','$_base','x');");
    }

    await RestoreBackupUseCase(db)(snapshot);

    expect(
        (await _q(db, 'SELECT entity FROM sync_cursors ORDER BY entity;'))
            .map((r) => r['entity']),
        hasLength(10));

    final ledger = LedgerOutboxQueue(
        db: db, isPushEnabled: () => true, getAuthUserId: () async => 'user-1');
    final planning = PlanningOutboxQueue(
        db: db,
        isSyncEnabled: (_) => true,
        getAuthUserId: () async => 'user-1');
    await PendingSyncReconciler(
      db: db,
      ledgerQueue: ledger,
      planningQueue: planning,
      getOwnerUid: () async => 'user-1',
      getAuthUserId: () async => 'user-1',
      mayEgress: () async => true,
    ).run();
    expect(await _q(db, 'SELECT 1 FROM ledger_sync_outbox;'), isEmpty);
    expect(await _q(db, 'SELECT 1 FROM planning_sync_outbox;'), isEmpty);
  });

  test('an edit made after the backup is newer: it and its queued intent are '
      'kept', () async {
    await _seedEveryFamily(db);
    final snapshot = await backup();
    final ledger = LedgerOutboxQueue(
        db: db, isPushEnabled: () => true, getAuthUserId: () async => 'user-1');
    final repo = DriftTransactionRepository(db, outboxQueue: ledger);
    await repo.updateAmount(
        transactionId: 'e-tx', amount: Money.parse('99', 'SAR'));
    expect(await _q(db, 'SELECT 1 FROM ledger_sync_outbox;'), hasLength(1));

    await RestoreBackupUseCase(db)(snapshot);
    expect(await _q(db, 'SELECT 1 FROM ledger_sync_outbox;'), hasLength(1));

    await PendingSyncReconciler(
      db: db,
      ledgerQueue: ledger,
      planningQueue: PlanningOutboxQueue(
          db: db,
          isSyncEnabled: (_) => true,
          getAuthUserId: () async => 'user-1'),
      getOwnerUid: () async => 'user-1',
      getAuthUserId: () async => 'user-1',
      mayEgress: () async => true,
    ).run();
    final row = (await _q(db,
            'SELECT operation, payload_json FROM ledger_sync_outbox;'))
        .single;
    expect(row['operation'], 'update');
    expect(row['payload_json'] as String, contains('"amount":99'));
    expect(
        (await _q(db, "SELECT amount_minor FROM transactions WHERE id = 'e-tx';"))
            .single['amount_minor'],
        9900);
  });

  test('local-only (guest) restore: nothing is queued, bound or lost',
      () async {
    Future<String?> none() async => null;
    final ledger =
        LedgerOutboxQueue(db: db, isPushEnabled: () => true, getAuthUserId: none);
    final repo = DriftTransactionRepository(db, outboxQueue: ledger);
    const acc = 'g-acc';
    await _account(db, acc);
    Future<void> add(String id, String amount) => repo.saveTransaction(
          transaction: TransactionEntity(
            id: id,
            amountMoney: Money.parse(amount, 'SAR'),
            currency: 'SAR',
            type: TransactionTypeEntity.payment,
            source: TransactionSourceEntity.unknown,
            occurredAt: DateTime.utc(2026, 7, 5),
            rawMessage: 'manual',
            parseConfidence: 1,
            status: TransactionStatus.confirmed,
            createdAt: DateTime.utc(2026, 7, 5),
            updatedAt: DateTime.utc(2026, 7, 5),
            accountId: acc,
            rawMerchant: 'Guest shop $id',
          ),
          categoryKey: null,
        );
    await add('g-A', '10');
    await add('g-B', '20');
    final snapshot = await backup();
    await repo.updateAmount(transactionId: 'g-B', amount: Money.parse('25', 'SAR'));
    await add('g-C', '30');

    await RestoreBackupUseCase(db)(snapshot);

    expect(
        await _q(db,
            'SELECT id, amount_minor, server_id, sync_status FROM transactions '
            'ORDER BY id;'),
        [
          {'id': 'g-A', 'amount_minor': 1000, 'server_id': null, 'sync_status': null},
          // Merge: the newer edit and the record added after the backup stay.
          {'id': 'g-B', 'amount_minor': 2500, 'server_id': null, 'sync_status': null},
          {'id': 'g-C', 'amount_minor': 3000, 'server_id': null, 'sync_status': null},
        ]);
    for (final table in _keys.keys) {
      expect(
          await _q(db,
              "SELECT 1 FROM $table WHERE server_id IS NOT NULL OR sync_status = 'pending';"),
          isEmpty,
          reason: table);
    }
    final recorded = await PendingSyncReconciler(
      db: db,
      ledgerQueue: ledger,
      planningQueue:
          PlanningOutboxQueue(db: db, isSyncEnabled: (_) => true, getAuthUserId: none),
      getOwnerUid: none,
      getAuthUserId: none,
      mayEgress: () async => true,
    ).run();
    expect(recorded, 0);
    expect(await _q(db, 'SELECT 1 FROM ledger_sync_outbox;'), isEmpty);
    expect(await _q(db, 'SELECT 1 FROM planning_sync_outbox;'), isEmpty);
  });
}
