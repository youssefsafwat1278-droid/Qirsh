// V1-020 — one simulated device for restore-then-sync tests without a live
// stack: the REAL restore use case, snapshot builder, ledger outbox, pending
// reconciler, transactions backfill, legacy ledger push and pull, over the
// in-memory cloud in fake_ledger_cloud.dart. The caller owns the admission
// fixture (LedgerAdmissionFixture) whose database is passed in.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/core/sync/pending_sync_reconciler.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';
import 'package:money_companion/features/capture/services/transactions_backfill_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/capture/ledger_admission_fixture.dart';
import 'fake_ledger_cloud.dart';

const uid = 'user-1';
Future<String?> _uid() async => uid;
Future<bool> _yes() async => true;

class Device {
  Device(this.db, this.cloud) {
    client = LedgerAdmissionFixture.trackClient(cloud.client());
    queue = LedgerOutboxQueue(
        db: db, isPushEnabled: () => true, getAuthUserId: _uid);
    repo = DriftTransactionRepository(db, outboxQueue: queue);
  }

  final AppDatabase db;
  final FakeLedgerCloud cloud;
  late final SupabaseClient client;
  late final LedgerOutboxQueue queue;
  late final DriftTransactionRepository repo;

  Future<void> seedAccount() async {
    // A cloud-bound account (accounts sync is not under test here).
    const now = '2026-07-04T12:00:00.000Z';
    await db.customStatement(
        'INSERT INTO accounts(id, name, currency, type, is_default, sort_order, '
        'created_at, updated_at, server_id, sync_status) VALUES '
        "('acc', 'Synthetic account', 'SAR', 'bank', 1, 1, '$now', '$now', "
        "'srv-acc', 'synced');");
  }

  Future<void> add(String id, String amount) async {
    final now = DateTime.utc(2026, 7, 5, 9);
    await repo.saveTransaction(
      transaction: TransactionEntity(
        id: id,
        amountMoney: Money.parse(amount, 'SAR'),
        currency: 'SAR',
        type: TransactionTypeEntity.payment,
        direction: TransactionDirectionEntity.debit,
        source: TransactionSourceEntity.unknown,
        occurredAt: now,
        rawMessage: 'manual',
        parseConfidence: 1,
        status: TransactionStatus.confirmed,
        createdAt: now,
        updatedAt: now,
        accountId: 'acc',
        rawMerchant: 'Synthetic shop $id',
      ),
      categoryKey: null,
    );
  }

  /// One cycle in the app shell's order: startup backfill, pending-intent
  /// reconcile, ledger push, ledger pull.
  Future<void> sync() async {
    await TransactionsBackfillService(
      db: db,
      getClient: () => client,
      getAuthUserId: _uid,
      getLocalDataOwnerUid: _uid,
    ).run();
    await PendingSyncReconciler(
      db: db,
      ledgerQueue: queue,
      planningQueue: PlanningOutboxQueue(
          db: db, isSyncEnabled: (_) => true, getAuthUserId: _uid),
      getOwnerUid: _uid,
      getAuthUserId: _uid,
      mayEgress: _yes,
    ).run();
    await LedgerPushService(
      db: db,
      queue: queue,
      isPushEnabled: () => true,
      getAuthUserId: _uid,
      getClient: () => client,
      mayEgress: _yes,
    ).push();
    await LedgerSyncService(
      db: db,
      transactionRepository: DriftTransactionRepository(db),
      dedupStore: DriftDedupStore(db),
      isPullEnabled: () => true,
      mayEgress: _yes,
      getAuthUserId: _uid,
      remoteSource: cloud,
    ).pull();
  }

  Future<Map<String, dynamic>> backup() async =>
      Map<String, dynamic>.from(await BackupSnapshotBuilder(db).build());

  Future<void> restore(Map<String, dynamic> snapshot) =>
      RestoreBackupUseCase(db)(snapshot);

  /// Live local rows: merchant -> amount.
  Future<Map<String, String>> live() async => {
        for (final r in await db
            .customSelect("SELECT raw_merchant m, amount_minor a FROM "
                "transactions WHERE status != 'ignored' ORDER BY raw_merchant")
            .get())
          r.read<String>('m'): Money(r.read<int>('a'), 'SAR').toDecimalString(),
      };

  Future<String?> syncStatus(String id) async => (await db
          .customSelect(
              "SELECT sync_status FROM transactions WHERE id = '$id';")
          .getSingle())
      .readNullable<String>('sync_status');
}

/// Device and cloud hold the same live rows, exactly one cloud copy each, and
/// every restored value survived.
Future<void> expectConverged(Device d, Map<String, String> restored) async {
  final local = await d.live();
  final cloud = d.cloud.live();
  for (final e in restored.entries) {
    expect(local[e.key], e.value, reason: 'restored ${e.key} was overwritten');
  }
  for (final e in cloud.entries) {
    expect(e.value, hasLength(1), reason: 'duplicate cloud copies of ${e.key}');
  }
  expect({for (final e in cloud.entries) e.key: e.value.single}, local,
      reason: 'device and cloud must agree');
  expect(
      d.cloud.rows.where(
          (r) => '${r['client_request_id']}'.startsWith('backfill_')),
      isEmpty,
      reason: 'no backfill copy of a row the cloud already has');
}
