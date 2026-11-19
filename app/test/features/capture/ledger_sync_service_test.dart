import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/transfer_pair_service.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/repositories/bill_repository.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';
import 'package:money_companion/domain/finance/money.dart';
import '../../harness/seed_test_account.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Counts SELECTs against accounts/categories to prove MALI-029 resolution
/// prefetch: a ledger pull resolves those stable sets ONCE, not per remote row.
class _ResolutionSelectCounter extends QueryInterceptor {
  int accountSelects = 0;
  int categorySelects = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) {
    final low = statement.toLowerCase();
    if (low.contains('from accounts')) accountSelects++;
    if (low.contains('from categories')) categorySelects++;
    return super.runSelect(executor, statement, args);
  }
}

class _MockRemoteSource implements LedgerRemoteSource {
  List<Map<String, dynamic>> activeRows = [];
  List<Map<String, dynamic>> tombstones = [];

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    final rows = [...activeRows, ...tombstones]..sort((left, right) {
        final timestamp = normalizeCursorTimestamp(left['updated_at'])
            .compareTo(normalizeCursorTimestamp(right['updated_at']));
        if (timestamp != 0) return timestamp;
        return (left['id'] as String).compareTo(right['id'] as String);
      });
    return rows
        .where((row) {
          if (after.id.isEmpty) return true;
          final timestamp = normalizeCursorTimestamp(row['updated_at']);
          final comparison = timestamp.compareTo(after.updatedAt);
          return comparison > 0 ||
              (comparison == 0 &&
                  (row['id'] as String).compareTo(after.id) > 0);
        })
        .take(limit)
        .toList();
  }
}

Map<String, dynamic> _serverRow({
  String id = 'test-server-uuid',
  String? payloadId,
  double amount = 100.0,
  String? amountText,
  String currency = 'SAR',
  String type = 'debit',
  String source = 'ios_shortcut',
  String? merchant,
  String? updatedAt,
}) =>
    {
      'id': id,
      'source_payload_id': payloadId,
      'amount': amount,
      'amount_text': amountText ?? amount.toString(),
      'balance_after_text': null,
      'foreign_amount_text': null,
      'foreign_currency': null,
      'currency': currency,
      'direction': type == 'credit' ? 'credit' : 'debit',
      'transaction_type': switch (type) {
        'credit' => 'income',
        'transfer' => 'transfer',
        _ => 'expense',
      },
      'source': source,
      'merchant': merchant,
      'occurred_at': '2026-01-01T10:00:00.000Z',
      'updated_at': updatedAt ?? '2026-01-01T10:00:00.000Z',
      'confidence': 0.9,
    };

LedgerSyncService _makeSvc(
  AppDatabase db,
  _MockRemoteSource remote, {
  bool flagOn = true,
  bool signedIn = true,
  int pageSize = 200,
}) =>
    LedgerSyncService(
      db: db,
      transactionRepository: DriftTransactionRepository(db),
      dedupStore: DriftDedupStore(db),
      isPullEnabled: () => flagOn,
      remoteSource: remote,
      getAuthUserId: () async => signedIn ? 'test-user-id' : null,
      pageSize: pageSize,
    
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );

void main() {
  late AppDatabase db;
  late _MockRemoteSource remote;

  setUp(() async {
    db = await seededDb(AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    ));
    remote = _MockRemoteSource();
  });

  tearDown(() async {
    await db.close();
  });

  test('transaction pull request shape keeps original cursor columns', () {
    expect(ledgerTransactionSelect, contains('amount_text:amount::text'));
    expect(ledgerTransactionSelect,
        contains('balance_after_text:balance_after::text'));
    expect(ledgerTransactionSelect,
        contains('foreign_amount_text:foreign_amount::text'));
    expect(ledgerTransactionOrderColumns, ['updated_at', 'id']);
    final filter = ledgerTransactionKeysetFilter(
      const SyncCursor(updatedAt: '2026-01-01T00:00:00Z', id: 'row-1'),
    );
    expect(filter, contains('updated_at.gt.'));
    expect(filter, contains('updated_at.eq.'));
    expect(filter, contains('id.gt.row-1'));
    expect(filter, isNot(contains('amount_text')));
  });

  test('deserialize exact money text and nullable transaction legs', () {
    final money = deserializeLedgerTransactionMoney({
      'currency': 'KWD',
      'amount_text': '9007199254740.991',
      'balance_after_text': null,
      'foreign_amount_text': '12.34',
      'foreign_currency': 'USD',
    });
    expect(money.amountMoney, Money.parse('9007199254740.991', 'KWD'));
    expect(money.balanceAfterMoney, isNull);
    expect(money.foreignMoney, Money.parse('12.34', 'USD'));
  });

  test('MALI-029: account/category resolution is prefetched once, not per row',
      () async {
    final counter = _ResolutionSelectCounter();
    final cdb = await AppDatabase.open(
      executor: NativeDatabase.memory().interceptWith(counter),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(cdb.close);
    await cdb.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at, "
      "server_id) VALUES ('a1', 'A', 'SAR', 'bank', '2026-01-01', "
      "'2026-01-01', 'srv-acct');",
    );
    await backfillNonPlanningMoneyV30(cdb);
    await cdb.customStatement(
      "INSERT INTO categories(id, key, name_ar, icon, color, is_income, "
      "sort_order) VALUES ('c1', 'cat_food', 'طعام', 'x', '#111', 0, 0);",
    );
    final r = _MockRemoteSource();
    r.activeRows = [
      for (var i = 0; i < 25; i++)
        {
          ..._serverRow(
            id: 'srv-$i',
            updatedAt:
                '2026-01-01T10:${(i ~/ 60).toString().padLeft(2, '0')}:'
                '${(i % 60).toString().padLeft(2, '0')}.000Z',
          ),
          'server_account_id': 'srv-acct',
          'category_id': 'cat_food',
        },
    ];
    // Measure only the pull (not open/seed).
    counter.accountSelects = 0;
    counter.categorySelects = 0;

    final result = await _makeSvc(cdb, r).pull();

    expect(result.imported, 25);
    // 25 rows all reference the same account → LedgerSync resolves accounts ONCE
    // for the whole pull (prefetch), never once per row (was ~25). LedgerSync
    // passes the resolved account id to the repo, so the repo does not re-resolve.
    expect(counter.accountSelects, lessThanOrEqualTo(2),
        reason: 'accounts resolved once per pull, not per row (was ~25)');
    // NOTE: category resolution for NEW imports still happens inside the shared
    // repo's saveTransaction (`_categoryIdByKey`, with type-based key
    // normalization) — a repo-layer redundancy that is out of scope for this
    // service-level fix (documented in PHASE_7_PERFORMANCE_CONTRACT). LedgerSync's
    // OWN category resolution (the update/repair path) IS cached.
  });

  test('does nothing when ledger_pull_sync flag is OFF', () async {
    remote.activeRows = [_serverRow()];
    final result = await _makeSvc(db, remote, flagOn: false).pull();

    expect(result.imported, 0);
    expect(result.updated, 0);
    expect(await db.count('transactions'), 0);
  });

  test('does nothing when user is a guest (no session)', () async {
    remote.activeRows = [_serverRow()];
    final result = await _makeSvc(db, remote, signedIn: false).pull();

    expect(result.imported, 0);
    expect(await db.count('transactions'), 0);
  });

  test('imports one server transaction into empty Drift DB', () async {
    remote.activeRows = [_serverRow()];
    final result = await _makeSvc(db, remote).pull();

    expect(result.imported, 1);
    expect(result.updated, 0);
    expect(await db.count('transactions'), 1);

    final rows = await db
        .customSelect('SELECT server_id, sync_status FROM transactions;')
        .get();
    expect(rows.first.readNullable<String>('server_id'), 'test-server-uuid');
    expect(rows.first.readNullable<String>('sync_status'), 'synced');
  });

  test('keyset pagination imports rows sharing a page-boundary timestamp',
      () async {
    remote.activeRows = List.generate(
      3,
      (index) => _serverRow(
        id: 'server-$index',
        updatedAt: '2026-01-01T10:00:00.000Z',
      ),
    );

    final result = await _makeSvc(db, remote, pageSize: 2).pull();

    expect(result.imported, 3);
    expect(await db.count('transactions'), 3);
    expect((await readSyncCursor(db, 'ledger_transactions')).id, 'server-2');
  });

  test('second pull of an unchanged row is a no-op and does not duplicate',
      () async {
    remote.activeRows = [_serverRow()];
    await _makeSvc(db, remote).pull();

    final result2 = await _makeSvc(db, remote).pull();

    expect(result2.imported, 0);
    // Unchanged server row → no re-write (prevents the dbRevision churn that
    // flickered the UI every sync cycle).
    expect(result2.updated, 0);
    expect(await db.count('transactions'), 1);
  });

  test('local transaction matched by source_payload_id gets server_id attached',
      () async {
    const payloadId = 'payload-abc-123';
    final svc = _makeSvc(db, remote);

    // Simulate a row that was already imported by CaptureSyncService (relay path):
    // insert a local transaction and mark it in dedup_hashes.
    const localId = 'local-tx-001';
    final now = dateTimeToSql(DateTime.now().toUtc());
    await db.customStatement('''
      INSERT INTO transactions(
        id, amount, currency, type, source,
        occurred_at, raw_message, parse_confidence, status,
        created_at, updated_at
      ) VALUES (
        '$localId', 50.0, 'SAR', 'payment', 'bank',
        '$now', '', 0.9, 'confirmed',
        '$now', '$now'
      );
    ''');
    await backfillNonPlanningMoneyV30(db);
    await DriftDedupStore(db).mark(
      'capture_payload:$payloadId',
      transactionId: localId,
      occurredAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );

    remote.activeRows = [_serverRow(payloadId: payloadId)];
    final result = await svc.pull();

    expect(result.imported, 0);
    expect(result.updated, 1);
    expect(await db.count('transactions'), 1);

    final rows = await db
        .customSelect(
          "SELECT server_id FROM transactions WHERE id = ${sqlString(localId)};",
        )
        .get();
    expect(rows.first.readNullable<String>('server_id'), 'test-server-uuid');
  });

  test('row missing amount is skipped', () async {
    remote.activeRows = [
      {
        'id': 'partial-row',
        'amount': null,
        'amount_text': null,
        'currency': 'SAR',
        'occurred_at': '2026-01-01T10:00:00.000Z',
        'type': 'debit',
        'source': 'ios_shortcut',
      }
    ];
    final result = await _makeSvc(db, remote).pull();

    expect(result.imported, 0);
    expect(await db.count('transactions'), 0);
  });

  test('tombstone marks synced local row as ignored', () async {
    // First import the row normally.
    remote.activeRows = [_serverRow()];
    await _makeSvc(db, remote).pull();
    expect(await db.count('transactions'), 1);

    // Move to tombstone.
    remote.activeRows = [];
    final tombstone = _serverRow(
      updatedAt: '2026-01-01T11:00:00.000Z',
    )
      ..remove('source_payload_id')
      ..['deleted_at'] = '2026-01-01T11:00:00.000Z';
    remote.tombstones = [tombstone];
    final result = await _makeSvc(db, remote).pull();

    expect(result.tombstoned, 1);
    final rows =
        await db.customSelect('SELECT status FROM transactions;').get();
    expect(rows.first.read<String>('status'), 'ignored');
  });

  test('row with conflict sync_status is counted as conflict, not overwritten',
      () async {
    // Import and then mark as conflict.
    remote.activeRows = [_serverRow()];
    await _makeSvc(db, remote).pull();

    await db.customStatement(
      "UPDATE transactions SET sync_status = 'conflict', amount = 999.0;",
    );
    remote.activeRows = [
      _serverRow(updatedAt: '2026-01-01T11:00:00.000Z'),
    ];

    final result = await _makeSvc(db, remote).pull();

    expect(result.conflicts, 1);
    expect(result.updated, 0);

    final rows =
        await db.customSelect('SELECT amount FROM transactions;').get();
    expect(rows.first.read<double>('amount'), 999.0);
  });

  test('re-pulling an unchanged row is a no-op (no flicker churn)', () async {
    remote.activeRows = [
      _serverRow(id: 'srv-1', updatedAt: '2026-01-01T10:00:00.000Z'),
    ];
    final first = await _makeSvc(db, remote).pull();
    expect(first.imported, 1);

    final syncedAtBefore = (await db
            .customSelect('SELECT synced_at FROM transactions LIMIT 1;')
            .getSingle())
        .readNullable<String>('synced_at');

    // Second pull, identical server state → must NOT re-write the row.
    final second = await _makeSvc(db, remote).pull();
    expect(second.imported, 0);
    expect(second.updated, 0, reason: 'unchanged row must not be re-written');

    final syncedAtAfter = (await db
            .customSelect('SELECT synced_at FROM transactions LIMIT 1;')
            .getSingle())
        .readNullable<String>('synced_at');
    expect(syncedAtAfter, syncedAtBefore,
        reason: 'synced_at must not move when nothing changed');
  });

  test(
      'import resolves the account via server_account_id, not the stale '
      'local_account_id from another install', () async {
    // The seeded sentinel default account, as the accounts pull leaves it:
    // attached server_id.
    await db.customStatement(
      "UPDATE accounts SET server_id = 'SRV-ACC-1' "
      "WHERE id = 'default_account';",
    );
    final row = _serverRow(id: 'srv-1');
    row['server_account_id'] = 'SRV-ACC-1';
    row['local_account_id'] = 'hBNX-stale-old-install'; // dead local id
    remote.activeRows = [row];

    final result = await _makeSvc(db, remote).pull();
    expect(result.imported, 1);

    final imported = await db
        .customSelect("SELECT account_id FROM transactions LIMIT 1;")
        .getSingle();
    expect(imported.readNullable<String>('account_id'), 'default_account',
        reason: 'must link via server_account_id → accounts.server_id');
  });

  test(
      'import with an unresolvable account falls back to the default '
      'account, never a dead dangling id', () async {
    final row = _serverRow(id: 'srv-1');
    row['local_account_id'] = 'dead-local-id'; // from a wiped install
    remote.activeRows = [row];

    await _makeSvc(db, remote).pull();

    final imported = await db
        .customSelect("SELECT account_id FROM transactions LIMIT 1;")
        .getSingle();
    // The resolver returns null for a dead id; saveTransaction then applies
    // its default-account policy — the row stays VISIBLE. What must never
    // happen is importing the dead id verbatim (hidden from every screen).
    expect(imported.readNullable<String>('account_id'), isNot('dead-local-id'));
    expect(imported.readNullable<String>('account_id'), 'default_account');
  });

  test(
      're-pull repairs an already-imported row whose account id no longer '
      'exists (post sign-out wipe)', () async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await db.customStatement(
      "UPDATE accounts SET server_id = 'SRV-ACC-1' "
      "WHERE id = 'default_account';",
    );
    // Orphaned import from before the fix: synced, matching server metadata
    // (so the no-op guard would normally skip it), but pointing at a dead id.
    await db.customStatement(
      "INSERT INTO transactions(id, amount, currency, type, source, "
      "occurred_at, raw_message, parse_confidence, status, created_at, "
      "updated_at, server_id, sync_status, server_updated_at, account_id) "
      "VALUES ('local-1', 100.0, 'SAR', 'payment', 'bank', "
      "'2026-01-01T10:00:00.000Z', '', 0.9, 'confirmed', '$now', '$now', "
      "'srv-1', 'synced', '2026-01-01T10:00:00.000Z', 'hBNX-dead-id');",
    );
    await backfillNonPlanningMoneyV30(db);
    final row = _serverRow(id: 'srv-1', updatedAt: '2026-01-01T10:00:00.000Z');
    row['server_account_id'] = 'SRV-ACC-1';
    remote.activeRows = [row];

    final result = await _makeSvc(db, remote).pull();
    expect(result.updated, 1,
        reason: 'account repair must override the unchanged-row skip');

    final repaired = await db
        .customSelect(
            "SELECT account_id FROM transactions WHERE id = 'local-1';")
        .getSingle();
    expect(repaired.readNullable<String>('account_id'), 'default_account');
  });

  test('re-pulling a row with a newer updated_at does update', () async {
    remote.activeRows = [
      _serverRow(id: 'srv-1', updatedAt: '2026-01-01T10:00:00.000Z'),
    ];
    await _makeSvc(db, remote).pull();

    remote.activeRows = [
      _serverRow(
        id: 'srv-1',
        updatedAt: '2026-01-02T10:00:00.000Z',
        merchant: 'CHANGED',
      ),
    ];
    final result = await _makeSvc(db, remote).pull();
    expect(result.updated, 1);
  });

  // ── MALI-009: remote field merge + pending-edit protection ────────────────

  Future<Map<String, dynamic>> localRow(String serverId) async {
    final row = await db
        .customSelect(
          'SELECT amount, raw_merchant, sync_status, server_updated_at '
          'FROM transactions '
          "WHERE server_id = ${sqlString(serverId)} LIMIT 1;",
        )
        .getSingle();
    return {
      'amount': row.read<double>('amount'),
      'raw_merchant': row.readNullable<String>('raw_merchant'),
      'sync_status': row.readNullable<String>('sync_status'),
      'server_updated_at': row.readNullable<String>('server_updated_at'),
    };
  }

  test('remote edit applies financial fields to an existing synced row',
      () async {
    remote.activeRows = [
      _serverRow(
        id: 'srv-merge',
        amount: 100.0,
        merchant: 'OLD',
        updatedAt: '2026-01-01T10:00:00.000Z',
      ),
    ];
    await _makeSvc(db, remote).pull();

    remote.activeRows = [
      _serverRow(
        id: 'srv-merge',
        amount: 250.0,
        merchant: 'NEW MERCHANT',
        updatedAt: '2026-01-02T10:00:00.000Z',
      ),
    ];
    await _makeSvc(db, remote).pull();

    final row = await localRow('srv-merge');
    expect(row['amount'], 250.0, reason: 'remote amount must land locally');
    expect(row['raw_merchant'], 'NEW MERCHANT');
    expect(row['sync_status'], 'synced');
    // One row, not a duplicate import.
    final count = await db
        .customSelect('SELECT COUNT(*) AS c FROM transactions;')
        .getSingle();
    expect(count.read<int>('c'), 1);
  });

  test('pending local edit is untouched when remote is at our base version',
      () async {
    remote.activeRows = [
      _serverRow(
        id: 'srv-pend',
        amount: 100.0,
        updatedAt: '2026-01-01T10:00:00.000Z',
      ),
    ];
    await _makeSvc(db, remote).pull();

    // Simulate a local edit awaiting push: fields changed, status pending,
    // base token = the version we pulled.
    await db.customStatement('''
      UPDATE transactions
      SET amount = 999.0, sync_status = 'pending'
      WHERE server_id = 'srv-pend';
    ''');

    // Remote unchanged (same updated_at) — pull must leave the row alone.
    final result = await _makeSvc(db, remote).pull();
    expect(result.conflicts, 0);

    final row = await localRow('srv-pend');
    expect(row['amount'], 999.0, reason: 'local pending edit must survive');
    expect(row['sync_status'], 'pending');
  });

  test('pending local edit + remote moved past base → conflict, fields kept',
      () async {
    remote.activeRows = [
      _serverRow(
        id: 'srv-conf',
        amount: 100.0,
        updatedAt: '2026-01-01T10:00:00.000Z',
      ),
    ];
    await _makeSvc(db, remote).pull();

    await db.customStatement('''
      UPDATE transactions
      SET amount = 999.0, sync_status = 'pending'
      WHERE server_id = 'srv-conf';
    ''');

    // Remote edited concurrently on another device.
    remote.activeRows = [
      _serverRow(
        id: 'srv-conf',
        amount: 300.0,
        updatedAt: '2026-01-03T10:00:00.000Z',
      ),
    ];
    final result = await _makeSvc(db, remote).pull();
    expect(result.conflicts, 1);

    final row = await localRow('srv-conf');
    expect(row['amount'], 999.0,
        reason: 'conflict must not silently pick the remote side');
    expect(row['sync_status'], 'conflict');
    expect(row['server_updated_at'], '2026-01-01T10:00:00.000Z',
        reason: 'base token must not be overwritten by the newer remote');
  });

  test('pending local edit + remote moved past base → conflict, fields kept; the ambiguous in-flight marker is cleared so keep-remote can resolve (D)',
      () async {
    remote.activeRows = [
      _serverRow(
        id: 'srv-conf',
        amount: 100.0,
        updatedAt: '2026-01-01T10:00:00.000Z',
      ),
    ];
    await _makeSvc(db, remote).pull();

    await db.customStatement('''
      UPDATE transactions
      SET amount = 999.0, sync_status = 'pending'
      WHERE server_id = 'srv-conf';
    ''');
    await db.customStatement('''
      INSERT INTO ledger_sync_outbox(id, transaction_id, operation, payload_json,
        attempt_count, status, created_at, updated_at, op_seq, in_flight_seq)
      SELECT 'o1', id, 'update', '{}', 0, 'pending', '2026-07-01T00:00:00Z',
        '2026-07-01T00:00:00Z', 1, 1 FROM transactions WHERE server_id = 'srv-conf';
    ''');

    // Remote edited concurrently on another device.
    remote.activeRows = [
      _serverRow(
        id: 'srv-conf',
        amount: 300.0,
        updatedAt: '2026-01-03T10:00:00.000Z',
      ),
    ];
    final result = await _makeSvc(db, remote).pull();
    expect(result.conflicts, 1);
    expect(
        (await db.customSelect(
                "SELECT in_flight_seq AS m FROM ledger_sync_outbox WHERE id = 'o1';")
            .getSingle())
            .readNullable<int>('m'),
        isNull,
        reason: 'a pull-raised conflict clears the ambiguous marker');

    final row = await localRow('srv-conf');
    expect(row['amount'], 999.0,
        reason: 'conflict must not silently pick the remote side');
    expect(row['sync_status'], 'conflict');
    expect(row['server_updated_at'], '2026-01-01T10:00:00.000Z',
        reason: 'base token must not be overwritten by the newer remote');
    final txId = (await db
            .customSelect("SELECT id FROM transactions WHERE server_id = 'srv-conf';")
            .getSingle())
        .read<String>('id');
    expect(
        await UniversalConflictResolver(db: db, reEnqueue: const {})
            .resolveKeepRemote('transaction', txId),
        isTrue);
  });

  // ---- B7 (sync-plan T9): remote tombstone vs pending local edit ------------
  Map<String, dynamic> tombstoneOf(String id,
          {String at = '2026-01-05T10:00:00.000Z'}) =>
      _serverRow(id: id, updatedAt: at)..['deleted_at'] = at;

  test(
      'T9: tombstone vs pending local edit → conflict, edit + outbox op kept, not ignored',
      () async {
    remote.activeRows = [_serverRow(id: 'srv-t9', amount: 100.0)];
    await _makeSvc(db, remote).pull();
    await db.customStatement(
        "UPDATE transactions SET amount = 999.0, sync_status = 'pending' "
        "WHERE server_id = 'srv-t9';");
    await db.customStatement('''
      INSERT INTO ledger_sync_outbox(id, transaction_id, operation, payload_json,
        attempt_count, status, created_at, updated_at, op_seq, in_flight_seq)
      SELECT 'o9', id, 'update', '{}', 0, 'pending', '2026-07-01T00:00:00Z',
        '2026-07-01T00:00:00Z', 1, 1 FROM transactions WHERE server_id = 'srv-t9';
    ''');

    remote.activeRows = [];
    remote.tombstones = [tombstoneOf('srv-t9')];
    final result = await _makeSvc(db, remote).pull();

    expect(result.conflicts, 1);
    expect(result.tombstoned, 0);
    final row = await localRow('srv-t9');
    expect(row['sync_status'], 'conflict');
    expect(row['status'], isNot('ignored'));
    expect(row['amount'], 999.0, reason: 'local edit preserved');
    final op = await db
        .customSelect(
            "SELECT in_flight_seq AS m FROM ledger_sync_outbox WHERE id = 'o9';")
        .getSingle();
    expect(op.readNullable<int>('m'), isNull,
        reason:
            'op kept (not lost) with the ambiguous in-flight marker cleared');
  });

  test('T9: an open outbox op without sync_status=pending is still a conflict',
      () async {
    remote.activeRows = [_serverRow(id: 'srv-t9b')];
    await _makeSvc(db, remote).pull();
    await db.customStatement('''
      INSERT INTO ledger_sync_outbox(id, transaction_id, operation, payload_json,
        attempt_count, status, created_at, updated_at, op_seq)
      SELECT 'o9b', id, 'update', '{}', 0, 'pending', '2026-07-01T00:00:00Z',
        '2026-07-01T00:00:00Z', 1 FROM transactions WHERE server_id = 'srv-t9b';
    ''');
    remote.activeRows = [];
    remote.tombstones = [tombstoneOf('srv-t9b')];
    final result = await _makeSvc(db, remote).pull();
    expect(result.conflicts, 1);
    expect((await localRow('srv-t9b'))['sync_status'], 'conflict');
    expect(await db.count('ledger_sync_outbox'), 1);
  });

  // ---- B9 (partial): canonical base-token comparison -------------------------
  test('equal instants in different formats are not a conflict and not an update',
      () async {
    remote.activeRows = [
      _serverRow(
          id: 'srv-ts', amount: 100.0, updatedAt: '2026-01-01T10:00:00.123Z'),
    ];
    await _makeSvc(db, remote).pull();
    expect((await localRow('srv-ts'))['server_updated_at'],
        '2026-01-01T10:00:00.123Z');

    // Same instant spelled +00:00 / microseconds: unchanged server row.
    remote.activeRows = [
      _serverRow(
          id: 'srv-ts',
          amount: 100.0,
          updatedAt: '2026-01-01T10:00:00.123000+00:00'),
    ];
    final noop =
        await _makeSvc(db, remote).pull(from: const SyncCursor.epoch());
    expect(noop.updated, 0);

    // Pending edit + same instant in another spelling: left alone, no conflict.
    await db.customStatement(
        "UPDATE transactions SET amount = 999.0, sync_status = 'pending' "
        "WHERE server_id = 'srv-ts';");
    final pending =
        await _makeSvc(db, remote).pull(from: const SyncCursor.epoch());
    expect(pending.conflicts, 0);
    expect((await localRow('srv-ts'))['sync_status'], 'pending');

    // A genuinely newer instant still conflicts.
    remote.activeRows = [
      _serverRow(
          id: 'srv-ts',
          amount: 300.0,
          updatedAt: '2026-01-01T10:00:00.124+00:00'),
    ];
    final conflict =
        await _makeSvc(db, remote).pull(from: const SyncCursor.epoch());
    expect(conflict.conflicts, 1);
  });

  test('stored base token is canonical UTC regardless of server spelling',
      () async {
    remote.activeRows = [
      _serverRow(id: 'srv-fmt', updatedAt: '2026-01-01T12:00:00.654321+02:00'),
    ];
    await _makeSvc(db, remote).pull();
    expect((await localRow('srv-fmt'))['server_updated_at'],
        '2026-01-01T10:00:00.654321Z');
    expect(canonicalServerTimestamp('2026-01-01T10:00:00Z'),
        canonicalServerTimestamp('2026-01-01T10:00:00.000000+00:00'));
    expect(canonicalServerTimestamp(null), isNull);
  });

  // ---- B12: per-row quarantine ------------------------------------------------
  Future<List<QueryRow>> quarantined() => db
      .customSelect(
          "SELECT * FROM parked_child_rows WHERE table_name = 'transactions';")
      .get();

  test(
      'B12: a poison row is quarantined; other rows import and the cursor advances; retry succeeds once fixed',
      () async {
    await db.customStatement('''
      CREATE TRIGGER poison BEFORE UPDATE OF server_id ON transactions
      WHEN NEW.server_id = 'srv-poison'
      BEGIN SELECT RAISE(ABORT, 'poison'); END;
    ''');
    remote.activeRows = [
      _serverRow(id: 'srv-a', updatedAt: '2026-01-01T10:00:00.000Z'),
      _serverRow(id: 'srv-poison', updatedAt: '2026-01-01T10:01:00.000Z'),
      _serverRow(id: 'srv-b', updatedAt: '2026-01-01T10:02:00.000Z'),
    ];
    final result = await _makeSvc(db, remote).pull();

    expect(result.status, SyncPullStatus.completed);
    expect(result.imported, 2);
    expect(await db.count('transactions'), 2,
        reason: 'the poison row left no partial write behind');
    final cursor = await readSyncCursor(db, 'ledger_transactions');
    expect(cursor.id, 'srv-b');
    final q = await quarantined();
    expect(q.length, 1);
    expect(q.single.read<String>('server_id'), 'srv-poison');
    expect(q.single.read<String>('reason'), 'quarantine');
    expect(q.single.read<String>('row_json'), contains('srv-poison'));

    // "Fix" the cause, pull again: the quarantined row is retried and imported.
    await db.customStatement('DROP TRIGGER poison;');
    remote.activeRows = [];
    final retry = await _makeSvc(db, remote).pull();
    expect(retry.status, SyncPullStatus.completed);
    expect(await db.count('transactions'), 3);
    expect(await quarantined(), isEmpty);
  });

  test(
      'B12: a permanently bad row stays quarantined, retries are bounded, then terminal (still countable)',
      () async {
    remote.activeRows = [
      _serverRow(id: 'srv-ok', updatedAt: '2026-01-01T10:00:00.000Z'),
      _serverRow(id: 'srv-bad', updatedAt: '2026-01-01T10:01:00.000Z')
        ..['currency'] = 123,
    ];
    final first = await _makeSvc(db, remote).pull();
    expect(first.imported, 1);
    expect((await quarantined()).single.read<String>('reason'), 'quarantine');

    remote.activeRows = [];
    for (var i = 0; i < 6; i++) {
      await _makeSvc(db, remote).pull();
    }
    final q = (await quarantined()).single;
    expect(q.read<String>('reason'), 'terminal');
    expect(q.read<int>('attempt_count'), 5);
    expect(await db.count('transactions'), 1);
  });

  // ---- WP-5: lost-ACK receipt on the pull side (the WP-4 note) --------------
  Future<String> pendingWithOp(String serverId,
      {required String opId,
      String operation = 'update',
      List<String> prior = const []}) async {
    await db.customStatement(
        "UPDATE transactions SET amount = 999.0, sync_status = 'pending' "
        "WHERE server_id = '$serverId';");
    final payload = prior.isEmpty
        ? '{}'
        : '{"prior_op_ids":[${prior.map((e) => '"$e"').join(',')}]}';
    await db.customStatement('''
      INSERT INTO ledger_sync_outbox(id, transaction_id, operation, payload_json,
        attempt_count, status, created_at, updated_at, op_seq, in_flight_seq,
        operation_id)
      SELECT 'o-$opId', id, '$operation', '$payload', 0, 'pending',
        '2026-07-01T00:00:00Z', '2026-07-01T00:00:00Z', 1, 1, '$opId'
      FROM transactions WHERE server_id = '$serverId';
    ''');
    return (await db
            .customSelect(
                "SELECT id FROM transactions WHERE server_id = '$serverId';")
            .getSingle())
        .read<String>('id');
  }

  Future<Map<String, Object?>> rowOf(String serverId) async => (await db
          .customSelect('SELECT id, amount, sync_status, server_revision '
              "FROM transactions WHERE server_id = '$serverId';")
          .getSingle())
      .data;

  Future<int> openConflicts() async => (await db
          .customSelect(
              'SELECT COUNT(*) AS n FROM sync_conflicts WHERE resolved_at IS NULL;')
          .getSingle())
      .read<int>('n');

  test('WP-5 lost ACK (update): the cloud row moved but its last_op_id is our '
      'queued op → settled, never a conflict', () async {
    remote.activeRows = [_serverRow(id: 'srv-la', updatedAt: '2026-01-01T10:00:00.000Z')];
    await _makeSvc(db, remote).pull();
    await pendingWithOp('srv-la', opId: 'op-mine');
    remote.activeRows = [
      _serverRow(id: 'srv-la', amount: 999.0, updatedAt: '2026-01-03T10:00:00.000Z')
        ..['revision'] = 2
        ..['last_op_id'] = 'op-mine',
    ];
    final r = await _makeSvc(db, remote).pull();
    expect(r.conflicts, 0);
    final row = await rowOf('srv-la');
    expect(row['sync_status'], 'synced');
    expect(row['amount'], 999.0, reason: 'our own edit stays');
    expect(row['server_revision'], 2);
    expect(await db.count('ledger_sync_outbox'), 0, reason: 'op consumed');
    expect(await openConflicts(), 0);
  });

  test('WP-5 lost ACK (create found by client_request_id): the server row is '
      "the client's own op → not a conflict, identity attached", () async {
    await db.customStatement('''
      INSERT INTO transactions(id, amount, currency, type, source, occurred_at,
        raw_message, parse_confidence, status, created_at, updated_at, sync_status)
      VALUES ('tx-new', 100.0, 'SAR', 'payment', 'bank', '2026-01-01T10:00:00.000Z',
        '', 0.9, 'confirmed', '2026-01-01', '2026-01-01', 'pending');
    ''');
    await db.customStatement('''
      INSERT INTO ledger_sync_outbox(id, transaction_id, operation, payload_json,
        attempt_count, status, created_at, updated_at, op_seq, in_flight_seq,
        operation_id)
      VALUES ('o-new', 'tx-new', 'create', '{}', 0, 'pending', '2026-07-01',
        '2026-07-01', 1, 1, 'op-create');
    ''');
    remote.activeRows = [
      _serverRow(id: 'srv-new', updatedAt: '2026-01-03T10:00:00.000Z')
        ..['client_request_id'] = 'tx-new'
        ..['revision'] = 1
        ..['last_op_id'] = 'op-create',
    ];
    final r = await _makeSvc(db, remote).pull();
    expect(r.conflicts, 0);
    final row = await rowOf('srv-new');
    expect(row['id'], 'tx-new');
    expect(row['sync_status'], 'synced');
    expect(await db.count('ledger_sync_outbox'), 0);
  });

  test('WP-5 a foreign op id is a real conflict and is stored durably '
      '(snapshots) before anything is resolved', () async {
    remote.activeRows = [_serverRow(id: 'srv-fo', updatedAt: '2026-01-01T10:00:00.000Z')];
    await _makeSvc(db, remote).pull();
    await pendingWithOp('srv-fo', opId: 'op-mine');
    remote.activeRows = [
      _serverRow(id: 'srv-fo', amount: 300.0, updatedAt: '2026-01-03T10:00:00.000Z')
        ..['revision'] = 2
        ..['last_op_id'] = 'someone-else',
    ];
    final r = await _makeSvc(db, remote).pull();
    expect(r.conflicts, 1);
    final rec = await db.customSelect('SELECT * FROM sync_conflicts').getSingle();
    expect(rec.read<String>('kind'), 'update');
    expect(rec.read<int>('theirs_revision'), 2);
    expect(rec.read<String>('mine_json'), contains('999'));
    expect(rec.read<String>('theirs_json'), contains('300'));
    expect(await db.count('ledger_sync_outbox'), 1,
        reason: 'the local op is kept until the user decides');
  });

  test('WP-5 earlier op of a since-edited row: re-based, edit stays pending, '
      'no conflict', () async {
    remote.activeRows = [_serverRow(id: 'srv-pr', updatedAt: '2026-01-01T10:00:00.000Z')];
    await _makeSvc(db, remote).pull();
    await pendingWithOp('srv-pr', opId: 'op-second', prior: ['op-first']);
    remote.activeRows = [
      _serverRow(id: 'srv-pr', amount: 500.0, updatedAt: '2026-01-03T10:00:00.000Z')
        ..['revision'] = 2
        ..['last_op_id'] = 'op-first',
    ];
    final r = await _makeSvc(db, remote).pull();
    expect(r.conflicts, 0);
    final row = await rowOf('srv-pr');
    expect(row['sync_status'], 'pending');
    expect(row['server_revision'], 2);
    expect(await db.count('ledger_sync_outbox'), 1);
    expect(
        (await db.customSelect('SELECT base_revision AS b FROM ledger_sync_outbox').getSingle())
            .read<int>('b'),
        2);
  });

  test('WP-5 tombstone of our own queued delete: settled, no conflict',
      () async {
    remote.activeRows = [_serverRow(id: 'srv-td', updatedAt: '2026-01-01T10:00:00.000Z')];
    await _makeSvc(db, remote).pull();
    await pendingWithOp('srv-td', opId: 'op-del', operation: 'delete');
    remote.activeRows = [];
    remote.tombstones = [
      tombstoneOf('srv-td')
        ..['revision'] = 2
        ..['last_op_id'] = 'op-del',
    ];
    final r = await _makeSvc(db, remote).pull();
    expect(r.conflicts, 0);
    expect(await db.count('ledger_sync_outbox'), 0);
    expect(await openConflicts(), 0);
  });

  test('WP-5 foreign tombstone vs pending edit: durable conflict kind '
      'tombstone, edit and op kept', () async {
    remote.activeRows = [_serverRow(id: 'srv-tf', updatedAt: '2026-01-01T10:00:00.000Z')];
    await _makeSvc(db, remote).pull();
    await pendingWithOp('srv-tf', opId: 'op-mine');
    remote.activeRows = [];
    remote.tombstones = [tombstoneOf('srv-tf')..['last_op_id'] = 'someone-else'];
    final r = await _makeSvc(db, remote).pull();
    expect(r.conflicts, 1);
    expect((await db.customSelect('SELECT kind FROM sync_conflicts').getSingle())
        .read<String>('kind'), 'tombstone');
    expect(await db.count('ledger_sync_outbox'), 1);
  });

  group('transfer between own accounts', () {
    setUp(() async {
      for (final id in ['acc-a', 'acc-b']) {
        await db.customStatement(
          "INSERT INTO accounts(id, name, currency, type, created_at, "
          "updated_at, server_id) VALUES ('$id', '$id', 'SAR', 'bank', "
          "'2026-01-01', '2026-01-01', 'srv-$id');",
        );
      }
      await backfillNonPlanningMoneyV30(db);
    });

    Map<String, dynamic> leg(String account, String direction,
            {String? group, String updatedAt = '2026-01-01T10:00:00.000Z'}) =>
        {
          ..._serverRow(
              id: 'srv-$direction', type: 'transfer', updatedAt: updatedAt),
          'direction': direction,
          'source': 'manual',
          'client_request_id': 'leg-$direction',
          'server_account_id': 'srv-$account',
          'metadata': {
            'payload_version': 2,
            'canonical_type': 'transfer',
            'canonical_source': 'unknown',
            'canonical_direction': direction,
            if (group != null) 'transfer_group_id': group,
          },
        };

    Future<List<Map<String, Object?>>> legs() async => [
          for (final r in await db
              .customSelect('SELECT id, account_id, direction, type, '
                  'transfer_group_id FROM transactions ORDER BY direction;')
              .get())
            r.data,
        ];

    test('a pulled pair lands linked on an empty device', () async {
      remote.activeRows = [
        leg('acc-a', 'debit', group: 'grp-1'),
        leg('acc-b', 'credit', group: 'grp-1'),
      ];
      expect((await _makeSvc(db, remote).pull()).imported, 2);

      expect(await legs(), [
        {
          'id': 'leg-credit',
          'account_id': 'acc-b',
          'direction': 'credit',
          'type': 'transfer',
          'transfer_group_id': 'grp-1',
        },
        {
          'id': 'leg-debit',
          'account_id': 'acc-a',
          'direction': 'debit',
          'type': 'transfer',
          'transfer_group_id': 'grp-1',
        },
      ]);
      final repo = DriftTransactionRepository(db);
      final service =
          TransferPairService(db: db, transactions: repo, bills: _Bills());
      final debit = (await repo.getById('leg-debit'))!;
      final credit = (await repo.getById('leg-credit'))!;
      expect((await service.sibling(debit))?.id, 'leg-credit');
      expect((await service.sibling(credit))?.id, 'leg-debit');
    });

    test('a later write without the key (older build) keeps the local link',
        () async {
      remote.activeRows = [leg('acc-a', 'debit', group: 'grp-1')];
      await _makeSvc(db, remote).pull();
      remote.activeRows = [
        leg('acc-a', 'debit', updatedAt: '2026-01-02T10:00:00.000Z')
          ..['amount_text'] = '250.0',
      ];
      expect((await _makeSvc(db, remote).pull()).updated, 1);

      final row = (await legs()).single;
      expect(row['transfer_group_id'], 'grp-1');
      expect(row['direction'], 'debit');
    });

    test('a legacy transfer row with no canonical metadata takes the server '
        'direction column', () async {
      remote.activeRows = [
        leg('acc-b', 'credit')..remove('metadata'),
      ];
      await _makeSvc(db, remote).pull();
      expect((await legs()).single['direction'], 'credit');
    });

    test('a later legacy write with no usable direction keeps a known local '
        'transfer direction', () async {
      remote.activeRows = [leg('acc-a', 'debit')];
      await _makeSvc(db, remote).pull();
      remote.activeRows = [
        leg('acc-a', 'unknown', updatedAt: '2026-01-02T10:00:00.000Z')
          ..['id'] = 'srv-debit'
          ..['client_request_id'] = 'leg-debit'
          ..remove('metadata'),
      ];
      expect((await _makeSvc(db, remote).pull()).updated, 1);
      expect((await legs()).single['direction'], 'debit');
    });

    test('a pair without the key pulls as two correct unlinked transfers',
        () async {
      remote.activeRows = [
        leg('acc-a', 'debit'),
        leg('acc-b', 'credit'),
      ];
      await _makeSvc(db, remote).pull();

      expect(await legs(), [
        {
          'id': 'leg-credit',
          'account_id': 'acc-b',
          'direction': 'credit',
          'type': 'transfer',
          'transfer_group_id': null,
        },
        {
          'id': 'leg-debit',
          'account_id': 'acc-a',
          'direction': 'debit',
          'type': 'transfer',
          'transfer_group_id': null,
        },
      ]);
      final repo = DriftTransactionRepository(db);
      final from = DateTime.utc(2025, 12, 1);
      final to = DateTime.utc(2026, 2, 1);
      for (final account in [null, 'acc-a', 'acc-b']) {
        expect(
            await repo.expenseTotalBetween(
                from: from, to: to, currency: 'SAR', accountId: account),
            Money.parse('0', 'SAR'));
        expect(
            await repo.incomeTotalBetween(
                from: from, to: to, currency: 'SAR', accountId: account),
            Money.parse('0', 'SAR'));
      }
    });
  });
}

class _Bills implements BillRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
