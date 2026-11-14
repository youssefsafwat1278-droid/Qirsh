import '../../features/capture/ledger_admission_fixture.dart';
// WP-4: sequence pull across EVERY pull service (accounts, planning, children,
// smart inbox, sender mappings, gamification, ledger) behind one SeqPullGate.
// Covers SYNC T3 (bootstrap), T4 (incremental / idle = one head call), T22
// (large backlog), T23 (page boundaries), T24 (crash between apply and cursor)
// and the injected-skew suite.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_gamification_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/data/sync/sender_bank_mapping_sync_service.dart';
import 'package:money_companion/data/sync/seq_pull.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';
import 'package:money_companion/features/capture/services/smart_inbox_sync_service.dart';
import 'package:money_companion/features/gamification/services/gamification_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/accounts_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../harness/seed_test_account.dart';

const _uid = 'user-1';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Server model for the sequence protocol; counts every call.
class _FakeSeq implements SeqRemote {
  final tables = <String, List<Map<String, dynamic>>>{};
  String epoch = 'e1';
  int headCalls = 0;
  final fetchAfters = <String, List<int>>{};
  final fetchSizes = <String, List<int>>{};

  int get tableCalls => fetchAfters.values.fold(0, (a, b) => a + b.length);

  void put(String table, Map<String, dynamic> row) =>
      (tables[table] ??= []).add(row);

  int get head => tables.values
      .expand((r) => r)
      .fold(0, (m, r) => (r['sync_seq'] as int) > m ? r['sync_seq'] as int : m);

  @override
  Future<List<Map<String, dynamic>>> fetchRowsBySeq({
    required String table,
    required String userId,
    required int afterSeq,
    required int limit,
    String select = '*',
  }) async {
    (fetchAfters[table] ??= []).add(afterSeq);
    final rows = (tables[table] ?? [])
        .where((r) => (r['sync_seq'] as int) > afterSeq)
        .toList()
      ..sort((a, b) => (a['sync_seq'] as int).compareTo(b['sync_seq'] as int));
    final page = rows.take(limit).toList();
    (fetchSizes[table] ??= []).add(page.length);
    return page;
  }

  @override
  Future<SyncHead?> fetchHead(String userId) async {
    headCalls++;
    return SyncHead(lastSeq: head, epoch: epoch);
  }
}

Map<String, dynamic> _acct(String id, int seq,
        {String updatedAt = '2026-01-01T00:00:00.000Z'}) =>
    {
      'id': id,
      'sync_seq': seq,
      'local_id': null,
      'name': 'Acc $id',
      'currency': 'SAR',
      'type': 'bank',
      'initial_balance_text': '0',
      'current_balance_text': '0',
      'credit_limit_text': null,
      'available_credit_text': null,
      'updated_at': updatedAt,
      'deleted_at': null,
    };

Map<String, dynamic> _inbox(String id, int seq,
        {String updatedAt = '2026-07-03T00:00:00.000Z'}) =>
    {
      'id': id,
      'sync_seq': seq,
      'transaction_id': null,
      'payload_id': null,
      'type': 'needs_review',
      'title': 'Review',
      'body': null,
      'status': 'open',
      'confidence': null,
      'metadata': null,
      'created_at': '2026-07-03T00:00:00.000Z',
      'updated_at': updatedAt,
    };

Map<String, dynamic> _sender(String n, int seq,
        {String updatedAt = '2026-01-01T00:00:00.000Z'}) =>
    {
      'id': 'srv-$n',
      'sync_seq': seq,
      'user_id': _uid,
      'sender_id': n,
      'normalized_sender_id': n,
      'bank_key': 'alrajhi',
      'suggested_bank_name': 'Bank',
      'suggested_country': 'SA',
      'confidence': 0.9,
      'reason': null,
      'status': 'confirmed',
      'source': 'user_manual',
      'first_seen_at': '2026-01-01T00:00:00Z',
      'last_seen_at': '2026-01-01T00:00:00Z',
      'confirmed_at': '2026-01-01T00:00:00Z',
      'rejected_at': null,
      'rejection_expires_at': null,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': updatedAt,
      'deleted_at': null,
    };

Map<String, dynamic> _tomb(String id, int seq) => {
      'id': id,
      'sync_seq': seq,
      'updated_at': '2026-01-01T00:00:00.000Z',
      'deleted_at': '2026-02-01T00:00:00.000Z',
    };

Map<String, dynamic> _ledger(String id, int seq) => {
      'id': id,
      'sync_seq': seq,
      'client_request_id': null,
      'source_payload_id': null,
      'amount_text': '10.0',
      'balance_after_text': null,
      'foreign_amount_text': null,
      'foreign_currency': null,
      'currency': 'SAR',
      'transaction_type': 'expense',
      'source': 'ios_shortcut',
      'merchant': 'm',
      'occurred_at': '2026-01-01T10:00:00.000Z',
      'updated_at': '2026-01-01T10:00:00.000Z',
      'confidence': 0.9,
    };

/// A legacy source that fails the test if the timestamp path is used.
class _NoLegacyAccounts implements AccountsRemoteSource {
  @override
  Future<List<Map<String, dynamic>>> fetchRows(
          {required SyncCursor after, int limit = 200}) async =>
      throw StateError('legacy accounts pull used');
}

/// Real keyset semantics on (updated_at, id), like the legacy server query.
class _KeysetAccounts implements AccountsRemoteSource {
  final rows = <Map<String, dynamic>>[];
  int calls = 0;
  @override
  Future<List<Map<String, dynamic>>> fetchRows(
      {required SyncCursor after, int limit = 200}) async {
    calls++;
    final all = [...rows]..sort((a, b) {
        final t = (a['updated_at'] as String).compareTo(b['updated_at'] as String);
        return t != 0 ? t : (a['id'] as String).compareTo(b['id'] as String);
      });
    return all
        .where((r) {
          if (after.id.isEmpty) return true;
          final c = normalizeCursorTimestamp(r['updated_at'])
              .compareTo(after.updatedAt);
          return c > 0 ||
              (c == 0 && (r['id'] as String).compareTo(after.id) > 0);
        })
        .take(limit)
        .toList();
  }
}

class _NoLegacySmartInbox implements SmartInboxRemoteSource {
  @override
  Future<List<Map<String, dynamic>>> fetchRows(
          {required SyncCursor after, int limit = 200}) async =>
      throw StateError('legacy smart-inbox pull used');
  @override
  Future<int> pushStatus(String serverId, String status) async => 1;
}

class _NoLegacySender implements SenderMappingRemoteStore {
  @override
  Future<List<Map<String, dynamic>>> fetchRows(
          {required SyncCursor after, int limit = 200}) async =>
      throw StateError('legacy sender pull used');
  @override
  Future<List<Map<String, dynamic>>> upsert(
          List<Map<String, dynamic>> rows) async =>
      throw UnimplementedError();
}

class _NoLegacyPlanning implements PlanningRemoteSource {
  @override
  Future<List<Map<String, dynamic>>> fetchRows(String table,
          {required SyncCursor after, int limit = 200}) async =>
      throw StateError('legacy planning pull used');
}

class _NoLegacyLedger implements LedgerRemoteSource {
  @override
  Future<List<Map<String, dynamic>>> fetchRows(
          {required SyncCursor after, int limit = 200}) async =>
      throw StateError('legacy ledger pull used');
}

class _NoLegacyChild implements PlanningChildRemote {
  @override
  Future<List<Map<String, dynamic>>> fetchRows(String table,
          {required SyncCursor after, int limit = 200}) async =>
      throw StateError('legacy child pull used');
  @override
  Future<Map<String, dynamic>> callRpc(String n, Map<String, dynamic> p) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> upsertPlanLink(Map<String, dynamic> r) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>?> findPlanLink({
    required String userId,
    required String planId,
    required String transactionId,
  }) async =>
      null;
  @override
  Future<void> tombstonePlanLink(String serverId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _FakeSeq seq;
  late DateTime now;
  var cap = ServerCapabilityState.verified;

  SeqPullGate gate() => SeqPullGate(
        db: db,
        capability: () async => cap,
        remote: seq,
        clock: () => now,
      );

  AccountsPullService accounts(SeqPullGate? g,
          {AccountsRemoteSource? remote, int pageSize = 200, int maxPages = 10}) =>
      AccountsPullService(
        db: db,
        isEnabled: () => true,
        getAuthUserId: () async => _uid,
        remoteSource: remote ?? _NoLegacyAccounts(),
        pageSize: pageSize,
        maxPagesPerRun: maxPages,
        mayEgress: () async => true,
        seqGate: g,
      );

  SmartInboxSyncService inbox(SeqPullGate? g, {int pageSize = 200}) =>
      SmartInboxSyncService(
        db: db,
        isPullEnabled: () => true,
        getAuthUserId: () async => _uid,
        remoteSource: _NoLegacySmartInbox(),
        pageSize: pageSize,
        mayEgress: () async => true,
        seqGate: g,
      );

  SenderBankMappingSyncService sender(SeqPullGate? g) =>
      SenderBankMappingSyncService(
        db: db,
        remoteStore: _NoLegacySender(),
        currentUserId: () => _uid,
        mayEgress: () async => true,
        seqGate: g,
      );

  PlanningPullService planning(SeqPullGate? g) => PlanningPullService(
        db: db,
        isEnabled: (_) => true,
        getAuthUserId: () async => _uid,
        remoteSource: _NoLegacyPlanning(),
        mayEgress: () async => true,
        seqGate: g,
      );

  PlanningChildSyncService children(SeqPullGate? g) => PlanningChildSyncService(
        db: db,
        queue: PlanningOutboxQueue(
          db: db,
          isSyncEnabled: (_) => true,
          getAuthUserId: () async => _uid,
        ),
        isEnabled: (_) => true,
        isPullEnabled: (_) => true,
        getAuthUserId: () async => _uid,
        remote: _NoLegacyChild(),
        pullCapability: () => ExactTransportCapability.verifiedExact,
        mayEgress: () async => true,
        seqGate: g,
      );

  LedgerSyncService ledger(SeqPullGate? g) => LedgerSyncService(
        db: db,
        transactionRepository: DriftTransactionRepository(db),
        dedupStore: DriftDedupStore(db),
        isPullEnabled: () => true,
        remoteSource: _NoLegacyLedger(),
        getAuthUserId: () async => _uid,
        mayEgress: () async => true,
        seqGate: g,
      );

  GamificationSyncService gamification(SeqPullGate? g) =>
      GamificationSyncService(
        db: db,
        supabase: SupabaseClient(
          'https://example.supabase.co',
          'public-anon-key',
          accessToken: () async => 'x',
          httpClient: MockClient((r) async =>
              throw StateError('legacy gamification pull used: ${r.url}')),
        ),
        gamificationRepo: DriftGamificationRepository(db),
        getAuthUserId: () async => _uid,
        mayEgress: () async => true,
        seqGate: g,
      );

  Future<int> count(String table) async => (await db
          .customSelect('SELECT COUNT(*) AS n FROM $table;')
          .getSingle())
      .read<int>('n');

  Future<int> cursor(String entity) => readSeqCursor(db, _uid, entity);

  setUp(() async {
    db = await seededDb(AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore()));
    await db.customStatement('DELETE FROM accounts;');
    seq = _FakeSeq();
    now = DateTime.utc(2026, 1, 1);
    cap = ServerCapabilityState.verified;
  });
  tearDown(() => db.close());

  group('every service pulls by sync_seq when the capability is verified', () {
    test('accounts: applied in seq order, per-table cursor, no legacy call',
        () async {
      seq.put('user_accounts', _acct('a2', 2));
      seq.put('user_accounts', _acct('a1', 1));
      final r = await accounts(gate(), pageSize: 1).pull();
      expect(r.status, SyncPullStatus.completed);
      expect(await count('accounts'), 2);
      expect(seq.fetchAfters['user_accounts'], [0, 1, 2]);
      expect(await cursor('accounts'), 2);
    });

    test('smart inbox', () async {
      seq.put('user_smart_inbox', _inbox('i1', 1));
      seq.put('user_smart_inbox', _inbox('i2', 2));
      final r = await inbox(gate()).pull();
      expect(r.imported, 2);
      expect(await cursor('smart_inbox'), 2);
    });

    test('sender mappings', () async {
      seq.put('sender_bank_mappings', _sender('s1', 1));
      final r = await sender(gate()).pull();
      expect(r.imported, 1);
      expect(await cursor('sender_bank_mappings'), 1);
    });

    test('planning: every entity has its own seq cursor', () async {
      seq.put('user_cards', _tomb('c1', 3));
      seq.put('user_budgets', _tomb('b1', 5));
      final r = await planning(gate()).pull();
      expect(r.completedEntities, isNotEmpty);
      expect(await cursor('planning_card'), 5, reason: 'caught up to head');
      expect(await cursor('planning_budget'), 5);
      expect(seq.fetchAfters.keys,
          containsAll(['user_cards', 'user_budgets', 'user_categories']));
    });

    test('children: parked-or-applied rows still advance their own cursor',
        () async {
      await db.close();
      final childAdmission=await LedgerAdmissionFixture.open(_uid);
      addTearDown(childAdmission.finish);
      db=childAdmission.database;
      await db.customStatement(
          "INSERT INTO goals(id,name,currency,target_amount,target_amount_minor,"
          "saved_amount,saved_amount_minor,last_notified_saved_amount_minor,"
          "vault_skin,status,created_at,server_id,sync_status) VALUES "
          "('local-g1','هدف','SAR',100,10000,0,0,0,'classic','active',"
          "'2026-07-23T09:00:00Z','g1','synced');");
      seq.put('user_goal_contributions', {
        'id': 'gc1',
        'sync_seq': 7,
        'local_id': 'gc1',
        'goal_id': 'g1',
        'amount': 5.0,
        'amount_text': '5.00',
        'created_at': '2026-07-23T10:00:00.000Z',
        'note': null,
        'updated_at': '2026-07-23T10:00:00.000Z',
        'deleted_at': null,
      });
      await children(gate()).sync();
      expect(await count('goal_contributions'), 1);
      expect(await cursor('planning_child_goal_contributions'), 7);
    });

    test('gamification: achievements/streak/xp each by their own cursor',
        () async {
      seq.put('user_achievements', {
        'id': 'x1',
        'sync_seq': 2,
        'achievement_key': 'k',
        'unlocked_at': '2026-01-01T00:00:00Z',
        'deleted_at': null,
      });
      seq.put('user_xp_levels',
          {'sync_seq': 4, 'xp': 20, 'level': 2, 'deleted_at': null});
      await gamification(gate()).performSync();
      expect(await cursor('gamification_user_achievements'), 4);
      expect(await cursor('gamification_user_xp_levels'), 4);
      final xp =
          await db.customSelect('SELECT total_xp FROM xp_levels LIMIT 1;').getSingle();
      expect(xp.read<int>('total_xp'), 20);
    });

    test('ledger via the same gate', () async {
      seq.put('user_transactions', _ledger('t1', 1));
      final r = await ledger(gate()).pull();
      expect(r.imported, 1);
      expect(await cursor('ledger_transactions'), 1);
    });
  });

  group('server-head short-circuit (T4)', () {
    test('settings repair replays a previously skipped sequence row', () async {
      seq.put('user_settings', {
        'id': 'server-settings',
        'local_id': 'user_settings',
        'sync_seq': 1,
        'currency': 'EGP',
        'updated_at': '2026-01-01T00:00:00.000Z',
      });
      await writeSeqCursor(db, _uid, 'planning_settings', 1);

      await planning(gate()).pull();

      final profile = await db
          .customSelect('SELECT currency, server_id FROM user_settings LIMIT 1;')
          .getSingle();
      expect(profile.read<String>('currency'), 'EGP');
      expect(profile.read<String>('server_id'), 'server-settings');
      expect(seq.fetchAfters['user_settings'], [0]);
      await planning(gate()).pull();
      expect(seq.fetchAfters['user_settings'], [0]);
    });

    test('an idle cycle costs exactly one head call and zero table calls',
        () async {
      seq.put('user_accounts', _acct('a1', 1));
      seq.put('user_smart_inbox', _inbox('i1', 2));
      seq.put('sender_bank_mappings', _sender('s1', 3));
      seq.put('user_transactions', _ledger('t1', 4));
      seq.put('user_cards', _tomb('c1', 5));

      Future<void> cycle() async {
        final g = gate(); // services share one gate within a cycle
        await ledger(g).pull();
        await accounts(g).pull();
        await planning(g).pull();
        await inbox(g).pull();
        await sender(g).pull();
        await gamification(g).performSync();
      }

      await cycle();
      expect(seq.headCalls, 1, reason: 'one head read serves the whole cycle');
      final tableCallsAfterBootstrap = seq.tableCalls;
      expect(tableCallsAfterBootstrap, greaterThan(0));

      now = now.add(const Duration(minutes: 1));
      await cycle();
      expect(seq.headCalls, 2, reason: 'one head call per idle cycle');
      expect(seq.tableCalls, tableCallsAfterBootstrap,
          reason: 'no table is queried when nothing changed');
    });

    test('T4: after a remote edit only the changed rows come back, from the caught-up cursor',
        () async {
      seq.put('user_accounts', _acct('a1', 1));
      seq.put('user_smart_inbox', _inbox('i1', 2));
      await accounts(gate()).pull();
      await inbox(gate()).pull();
      seq.fetchAfters.clear();
      seq.fetchSizes.clear();

      // a remote change: one new row with a newer sync_seq
      seq.put('user_smart_inbox', _inbox('i2', 3));
      now = now.add(const Duration(minutes: 1));
      final g = gate();
      await accounts(g).pull();
      final r = await inbox(g).pull();
      expect(seq.fetchSizes['user_accounts']!.every((n) => n == 0), isTrue,
          reason: 'accounts is asked once (the head moved) but returns nothing');
      expect(seq.fetchAfters['user_smart_inbox']!.first, 2,
          reason: 'caught-up cursor (head at last EOF), not 0');
      expect(r.imported, 1);
      expect(seq.fetchSizes['user_smart_inbox'], [1]);
    });
  });

  group('bootstrap (T3), page boundaries (T23), crash safety (T24)', () {
    test('T3: first sync pages from 0, survives a crash, resumes from the last committed page, records the epoch',
        () async {
      for (var i = 1; i <= 5; i++) {
        seq.put('user_accounts', _acct('a$i', i));
      }
      var admitted = true;
      var checks = 0;
      // Admission is lost during the second page's fetch.
      final r1 = await accounts(gate(), pageSize: 2).pull(isAdmitted: () {
        if (++checks >= 5) admitted = false;
        return admitted;
      });
      expect(r1.status, SyncPullStatus.failed);
      expect(await count('accounts'), 2, reason: 'page 1 committed');
      expect(await cursor('accounts'), 2);

      seq.fetchAfters.clear();
      now = now.add(const Duration(minutes: 1));
      final r2 = await accounts(gate(), pageSize: 2).pull();
      expect(r2.status, SyncPullStatus.completed);
      expect(seq.fetchAfters['user_accounts'], [2, 4],
          reason: 'resumed from the committed cursor (no re-fetch from 0)');
      expect(await count('accounts'), 5);
      expect((await readRecordedSyncEpoch(db, _uid))!.epoch, 'e1');
    });

    test('T23: exact page multiple and remainder — no skip, no duplicate',
        () async {
      for (var i = 1; i <= 4; i++) {
        seq.put('user_accounts', _acct('a$i', i));
      }
      await accounts(gate(), pageSize: 2).pull();
      expect(seq.fetchAfters['user_accounts'], [0, 2, 4]);
      expect(await count('accounts'), 4);

      seq.put('user_accounts', _acct('a5', 5));
      now = now.add(const Duration(minutes: 1));
      await accounts(gate(), pageSize: 2).pull();
      expect(await count('accounts'), 5);
      now = now.add(const Duration(minutes: 1));
      await accounts(gate(), pageSize: 2).pull();
      expect(await count('accounts'), 5, reason: 'idempotent');
    });

    test('T24: crash after apply but before the cursor write rolls back both',
        () async {
      seq.put('user_accounts', _acct('a1', 1));
      seq.put('user_accounts', _acct('a2', 2));
      var checks = 0;
      final r = await accounts(gate()).pull(isAdmitted: () => ++checks < 3);
      expect(r.status, SyncPullStatus.failed);
      expect(await count('accounts'), 0);
      expect(await cursor('accounts'), 0);

      final again = await accounts(gate()).pull();
      expect(again.status, SyncPullStatus.completed);
      expect(await count('accounts'), 2);
    });

    test('T22: large backlog pages in bounded chunks and resumes across runs',
        () async {
      for (var i = 1; i <= 600; i++) {
        seq.put('user_smart_inbox', _inbox('i$i', i));
      }
      var runs = 0;
      while (true) {
        runs++;
        final svc = SmartInboxSyncService(
          db: db,
          isPullEnabled: () => true,
          getAuthUserId: () async => _uid,
          remoteSource: _NoLegacySmartInbox(),
          pageSize: 100,
          mayEgress: () async => true,
          seqGate: gate(),
        );
        var pages = 0;
        // Each run is cut after 2 pages (as if the app was killed).
        final r = await svc.pull(isAdmitted: () => pages++ < 6);
        if (r.status == SyncPullStatus.completed) break;
        expect(runs, lessThan(10));
      }
      expect(runs, greaterThan(1));
      expect(await count('smart_inbox_items'), 600);
      expect(seq.fetchSizes['user_smart_inbox']!.every((n) => n <= 100), isTrue);
    });
  });

  group('injected skew: an old updated_at written late is still pulled', () {
    test('legacy timestamp pull MISSES it (the B6 defect), seq pull does not',
        () async {
      // Legacy path (capability unsupported).
      cap = ServerCapabilityState.unsupported;
      final legacy = _KeysetAccounts()
        ..rows.add(_acct('a1', 1, updatedAt: '2026-01-01T10:00:05.000Z'));
      await accounts(gate(), remote: legacy).pull();
      expect(await count('accounts'), 1);
      legacy.rows.add(_acct('a2', 2, updatedAt: '2026-01-01T10:00:01.000Z'));
      await accounts(gate(), remote: legacy).pull();
      expect(await count('accounts'), 1, reason: 'legacy: skewed row is lost');

      // Sequence path.
      await db.customStatement('DELETE FROM accounts;');
      await db.customStatement('DELETE FROM sync_cursors;');
      cap = ServerCapabilityState.verified;
      seq.put('user_accounts', _acct('a1', 1, updatedAt: '2026-01-01T10:00:05.000Z'));
      await accounts(gate()).pull();
      seq.put('user_accounts', _acct('a2', 2, updatedAt: '2026-01-01T10:00:01.000Z'));
      now = now.add(const Duration(minutes: 1));
      await accounts(gate()).pull();
      expect(await count('accounts'), 2, reason: 'seq: nothing missed');
    });

    test('smart inbox, sender mappings and ledger', () async {
      seq.put('user_smart_inbox', _inbox('i1', 1, updatedAt: '2026-07-03T10:00:09.000Z'));
      seq.put('sender_bank_mappings', _sender('s1', 2, updatedAt: '2026-01-01T10:00:09.000Z'));
      seq.put('user_transactions', _ledger('t1', 3));
      await inbox(gate()).pull();
      await sender(gate()).pull();
      await ledger(gate()).pull();

      seq.put('user_smart_inbox', _inbox('i2', 4, updatedAt: '2020-01-01T00:00:00.000Z'));
      seq.put('sender_bank_mappings', _sender('s2', 5, updatedAt: '2020-01-01T00:00:00.000Z'));
      seq.put('user_transactions',
          {..._ledger('t2', 6), 'updated_at': '2020-01-01T00:00:00.000Z'});
      now = now.add(const Duration(minutes: 1));
      final g = gate();
      await inbox(g).pull();
      await sender(g).pull();
      await ledger(g).pull();
      expect(await count('smart_inbox_items'), 2);
      expect(await count('sender_bank_mappings'), 2);
      expect(await count('transactions'), 2);
    });
  });

  group('gating', () {
    test('capability unsupported: legacy path, seq remote untouched', () async {
      cap = ServerCapabilityState.unsupported;
      final legacy = _KeysetAccounts()..rows.add(_acct('a1', 1));
      final r = await accounts(gate(), remote: legacy).pull();
      expect(r.status, SyncPullStatus.completed);
      expect(legacy.calls, greaterThan(0));
      expect(seq.headCalls + seq.tableCalls, 0);
      expect(await cursor('accounts'), 0);
    });

    test('capability unknown: nothing is pulled and the stop is typed',
        () async {
      cap = ServerCapabilityState.unknown;
      seq.put('user_accounts', _acct('a1', 1));
      final g = gate();
      final r = await accounts(g).pull();
      expect(r.status, SyncPullStatus.failed);
      expect(g.lastStop, SyncPullStop.capabilityUnknown);
      expect(await count('accounts'), 0);
    });

    test('epoch mismatch stops every service (no rebootstrap here)', () async {
      seq.put('user_accounts', _acct('a1', 1));
      await accounts(gate()).pull();
      seq.epoch = 'e2';
      seq.put('user_accounts', _acct('a2', 2));
      seq.put('user_smart_inbox', _inbox('i1', 3));
      now = now.add(const Duration(minutes: 1));
      final g = gate();
      final r = await accounts(g).pull();
      final r2 = await inbox(g).pull();
      expect(g.lastStop, SyncPullStop.epochMismatch);
      expect(r.status, SyncPullStatus.failed);
      expect(r2.status, SyncPullStatus.failed);
      expect(await count('accounts'), 1);
      expect(await count('smart_inbox_items'), 0);
    });
  });
}
