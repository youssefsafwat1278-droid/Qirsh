// One simulated DEVICE for the local end-to-end sync proof: a fresh in-memory
// AppDatabase wired with the REAL repositories, REAL outbox queues and REAL
// push/pull services, all talking to the real SupabaseClient that
// `Supabase.initialize` pointed at the local stack.
//
// Only three things are injected (all through constructor seams production
// already exposes): the consent callback, the transport capabilities (exact
// push/pull are `verifiedExact` build constants in production; planning
// currency is a runtime probe, exercised through the REAL providers in S14)
// and the owner accessor.
import 'package:drift/native.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/data/repositories/drift_sender_bank_mapping_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/data/sync/sender_bank_mapping_sync_service.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/accounts_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/accounts_push_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

const _canonical =
    FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical);

Future<String?> signedInUid() async =>
    Supabase.instance.client.auth.currentUser?.id;

class Device {
  Device._(this.db);

  /// A new device = a new empty local database (what "another phone, same
  /// account" or "fresh install" looks like).
  static Future<Device> open() async {
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    final d = Device._(db);
    d._wire();
    return d;
  }

  /// Wires the same real services over a database the caller already opened
  /// (e.g. one admitted by the account-fence host). The caller owns closing it.
  static Device wrap(AppDatabase db) => Device._(db).._wire();

  final AppDatabase db;

  // ---- injected, mutable per scenario ------------------------------------
  /// Consent callback (financial sync). Scenarios flip it true/false.
  bool consent = true;

  /// Transport capabilities. Production: exact push/pull are `verifiedExact`;
  /// planning currency starts `unknown` until probed. This harness runs with
  /// `verifiedExact` unless a scenario says otherwise (S14 uses the real probe).
  ExactTransportCapability pushCap = ExactTransportCapability.verifiedExact;
  ExactTransportCapability pullCap = ExactTransportCapability.verifiedExact;
  ExactTransportCapability planningCurrencyCap =
      ExactTransportCapability.verifiedExact;

  /// Owner accessor = the signed-in user's uid (AppSession analogue).
  Future<String?> Function() ownerUid = signedInUid;

  // ---- real production objects ------------------------------------------
  late final LedgerOutboxQueue ledgerQueue;
  late final PlanningOutboxQueue planningQueue;
  late final DriftAccountRepository accounts;
  late final DriftTransactionRepository transactions;
  late final DriftBudgetRepository budgets;
  late final DriftGoalRepository goals;
  late final DriftPlanRepository plans;
  late final DriftBillRepository bills;
  late final DriftSenderBankMappingRepository senderMappings;
  late final ServerCapabilitiesService capabilities;
  late final LedgerPushService ledgerPush;
  late final LedgerSyncService ledgerPull;
  late final AccountsPushService accountsPush;
  late final AccountsPullService accountsPull;
  late final PlanningPushService planningPush;
  late final PlanningPullService planningPull;
  late final PlanningChildSyncService childSync;
  late final SenderBankMappingSyncService senderSync;

  Future<bool> _consent() async => consent;

  void _wire() {
    ledgerQueue = LedgerOutboxQueue(
      db: db,
      isPushEnabled: () => true,
      getAuthUserId: signedInUid,
      getOwnerUid: () => ownerUid(),
      coordinator: _canonical,
    );
    planningQueue = PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: signedInUid,
      getOwnerUid: () => ownerUid(),
      coordinator: _canonical,
    );
    accounts = DriftAccountRepository(db,
        outboxQueue: planningQueue, ledgerOutboxQueue: ledgerQueue);
    transactions = DriftTransactionRepository(db, outboxQueue: ledgerQueue);
    budgets = DriftBudgetRepository(db, outboxQueue: planningQueue);
    goals = DriftGoalRepository(db, outboxQueue: planningQueue);
    plans = DriftPlanRepository(db, outboxQueue: planningQueue);
    bills = DriftBillRepository(db, outboxQueue: planningQueue);
    senderMappings = DriftSenderBankMappingRepository(db);

    capabilities = ServerCapabilitiesService(
      getAuthUserId: signedInUid,
      getClient: () => Supabase.instance.client,
      mayEgress: _consent,
      // Re-probe on every call so S11 sees the server change without waiting
      // out the 2-minute unknown back-off (cache is still per-session).
      unknownRetryAfter: Duration.zero,
    );

    ledgerPush = LedgerPushService(
      db: db,
      queue: ledgerQueue,
      isPushEnabled: () => true,
      getAuthUserId: signedInUid,
      coordinator: _canonical,
      pushCapability: () => pushCap,
      capabilities: capabilities,
      mayEgress: _consent,
    );
    ledgerPull = LedgerSyncService(
      db: db,
      // Production pulls through a repo WITHOUT the outbox (pulled rows must
      // not be re-pushed); mirror app_providers.dart exactly.
      transactionRepository: DriftTransactionRepository(db),
      dedupStore: DriftDedupStore(db),
      isPullEnabled: () => exactPullAllowed(pullCap),
      mayEgress: _consent,
      getAuthUserId: signedInUid,
    );
    accountsPush = AccountsPushService(
      db: db,
      queue: planningQueue,
      isEnabled: () => true,
      getAuthUserId: signedInUid,
      coordinator: _canonical,
      pushCapability: () => pushCap,
      mayEgress: _consent,
    );
    accountsPull = AccountsPullService(
      db: db,
      isEnabled: () => exactPullAllowed(pullCap),
      mayEgress: _consent,
      getAuthUserId: signedInUid,
    );
    planningPush = PlanningPushService(
      db: db,
      queue: planningQueue,
      isEnabled: (_) => true,
      getAuthUserId: signedInUid,
      coordinator: _canonical,
      pushCapability: () => pushCap,
      planningCurrencyCapability: () => planningCurrencyCap,
      mayEgress: _consent,
      mayEgressProfile: _consent,
    );
    planningPull = PlanningPullService(
      db: db,
      isEnabled: (_) => exactPullAllowed(pullCap),
      getAuthUserId: signedInUid,
      outboxQueue: planningQueue,
      mayEgress: _consent,
      mayEgressProfile: _consent,
    );
    childSync = PlanningChildSyncService(
      db: db,
      queue: planningQueue,
      isEnabled: (_) => true,
      isPullEnabled: (_) => exactPullAllowed(pullCap),
      mayEgress: _consent,
      getAuthUserId: signedInUid,
      coordinator: _canonical,
      pushCapability: () => pushCap,
      pullCapability: () => pullCap,
    );
    senderSync = SenderBankMappingSyncService(
      db: db,
      remoteStore:
          SupabaseSenderBankMappingRemoteStore(Supabase.instance.client),
      currentUserId: () => Supabase.instance.client.auth.currentUser?.id,
      mayEgress: _consent,
    );
  }

  // ---- local-state probes -----------------------------------------------
  Future<List<Map<String, Object?>>> sql(String q) async =>
      (await db.customSelect(q).get()).map((r) => r.data).toList();

  Future<int> ledgerOutboxCount([String where = '1=1']) async =>
      (await sql('SELECT COUNT(*) n FROM ledger_sync_outbox WHERE $where'))
          .first['n'] as int;

  Future<int> planningOutboxCount([String where = '1=1']) async =>
      (await sql('SELECT COUNT(*) n FROM planning_sync_outbox WHERE $where'))
          .first['n'] as int;

  Future<Map<String, Object?>> ledgerOutboxRow(String txId) async =>
      (await sql("SELECT * FROM ledger_sync_outbox "
              "WHERE transaction_id = '$txId'"))
          .single;

  /// Fast-forwards the retry back-off (the only way to "wait 30s" in a test).
  Future<void> elapseBackoff() async {
    await db.customStatement(
        'UPDATE ledger_sync_outbox SET next_retry_at = NULL;');
    await db.customStatement(
        'UPDATE planning_sync_outbox SET next_retry_at = NULL;');
  }

  Future<void> close() => db.close();
}
