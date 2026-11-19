import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/errors/repo_exceptions.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';
import 'package:money_companion/features/capture/services/transactions_backfill_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Serves a fixed set of server rows once (one page).
class _Rows implements LedgerRemoteSource {
  _Rows(this.rows);
  final List<Map<String, dynamic>> rows;
  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async =>
      after.id.isEmpty ? rows : const [];
}

/// Builds a real (network-mocked) [SupabaseClient] so a valid session can be
/// recovered for it — used to exercise AppSession's actual session
/// reconciliation (and thus the real local-data-owner marker claim), not a
/// shortcut around it. Mirrors the helper in app_session_test.dart.
SupabaseClient _authClient() {
  final http = MockClient((request) async => Response('{}', 200));
  return SupabaseClient(
    'https://example.supabase.co',
    'public-anon-key',
    httpClient: http,
  );
}

Future<void> _recoverSession(SupabaseClient client, String userId) async {
  String segment(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final header = segment({'alg': 'none', 'typ': 'JWT'});
  final payload = segment({
    'exp':
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
            1000,
    'sub': userId,
  });
  await client.auth.recoverSession(jsonEncode({
    'access_token': '$header.$payload.',
    'token_type': 'bearer',
    'user': {'id': userId},
  }));
}

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _openDb() {
  return AppDatabase.open(
    executor: NativeDatabase.memory(),
    keyStore: _MemoryKeyStore(),
  );
}

Future<void> _seedOneTransaction(AppDatabase db, {String id = 't1'}) async {
  final now = DateTime.now().toUtc().toIso8601String();
  await db.customStatement(
    "INSERT INTO transactions(id, amount, currency, type, source, occurred_at, "
    "raw_message, parse_confidence, status, created_at, updated_at) "
    "VALUES ('$id', 10, 'SAR', 'expense', 'manual', '$now', 'raw', 1.0, 'active', '$now', '$now');",
  );
  await backfillNonPlanningMoneyV30(db);
}

SupabaseClient _refusingClient() {
  throw StateError(
    'must not contact Supabase — either the ownership guard should have '
    'refused first, or there were zero local rows to upload',
  );
}

SupabaseClient _existingTransactionClient(Map<String, dynamic> row) {
  final http = MockClient((request) async {
    expect(request.method, 'GET');
    expect(request.url.path, contains('user_transactions'));
    return Response(
      jsonEncode(row),
      200,
      headers: const {'content-type': 'application/json'},
      request: request,
    );
  });
  return SupabaseClient(
    'https://example.supabase.co',
    'public-anon-key',
    accessToken: () async => 'token',
    httpClient: http,
  );
}

Future<void> _seedSecondaryMoneyTransaction(AppDatabase db) async {
  const now = '2026-08-24T10:00:00.000Z';
  await db.customStatement('''
    INSERT INTO transactions(id,amount,currency,type,source,balance_after,
      foreign_amount,foreign_currency,direction,occurred_at,raw_message,
      parse_confidence,status,created_at,updated_at)
    VALUES('money-tx',10.25,'SAR','payment','manual',90.75,2.125,'KWD','debit',
      '$now','',1,'confirmed','$now','$now');
  ''');
  await backfillNonPlanningMoneyV30(db);
}

Map<String, dynamic> _matchingRemoteTransaction() => {
      'id': 'server-money-tx',
      'amount_text': '10.25',
      'currency': 'SAR',
      'balance_after_text': '90.75',
      'foreign_amount_text': '2.125',
      'foreign_currency': 'KWD',
      'direction': 'debit',
      'transaction_type': 'expense',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    AppSession.instance.configureCaptureDeviceUnlink(null);
    // MALI-054n: production always registers the residue purge hook; default it
    // to success so sign-out releases ownership exactly as it does in the app.
    AppSession.instance.configureCaptureOwnerClear(() async => true);
    await AppSession.instance.wipeAndReset();
  });

  // B1 defense-in-depth: TransactionsBackfillService must never trust "every
  // local row belongs to whoever is currently authenticated" — it must
  // refuse when AppSession's local-data-owner marker names a different uid.

  test(
      'skips rows already synced (server_id set) — re-pushing them minted a '
      'duplicate server copy per reconcile run', () async {
    final db = await _openDb();
    addTearDown(db.close);
    // Accounts gate satisfied.
    await db.customStatement("UPDATE accounts SET server_id = 'srv-acct';");
    // A pull-imported transaction: already on the server, server_id attached.
    await _seedOneTransaction(db);
    await db.customStatement(
      "UPDATE transactions SET server_id = 'srv-tx-1', sync_status = 'synced' "
      "WHERE id = 't1';",
    );

    final service = TransactionsBackfillService(
      db: db,
      getAuthUserId: () async => 'user-a',
      getLocalDataOwnerUid: () async => 'user-a',
      // Throws on any use — proves the synced row triggers ZERO upload calls.
      getClient: _refusingClient,
    );

    final report = await service.run();
    expect(report.total, 0,
        reason: 'synced rows must be invisible to the backfill');
  });

  test(
      'refuses to backfill when the owner marker conflicts with the '
      'currently authenticated uid — and never touches Supabase', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedOneTransaction(db);

    final service = TransactionsBackfillService(
      db: db,
      getAuthUserId: () async => 'user-b',
      getLocalDataOwnerUid: () async => 'user-a',
      getClient: _refusingClient,
    );

    await expectLater(
      service.run(),
      throwsA(isA<ValidationRepoException>()),
    );
  });

  test(
      'proceeds when the owner marker is null (no known conflict — '
      'forward-compatible with installs from before this fix)', () async {
    final db = await _openDb();
    addTearDown(db.close);
    // A fresh DB always seeds one not-yet-backfilled default account; clear
    // it so only the ownership guard (not the separate accounts-backfill
    // gate) is under test here. Empty transactions table: the per-row loop
    // (the only place Supabase is ever contacted) never executes, so a
    // throwing getClient proves zero upload calls happen.
    await db.customStatement('DELETE FROM accounts;');
    final service = TransactionsBackfillService(
      db: db,
      getAuthUserId: () async => 'user-b',
      getLocalDataOwnerUid: () async => null,
      getClient: _refusingClient,
    );

    final report = await service.run();

    expect(report.total, 0);
  });

  test(
      'proceeds when the owner marker matches the currently authenticated '
      'uid', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await db.customStatement('DELETE FROM accounts;');
    final service = TransactionsBackfillService(
      db: db,
      getAuthUserId: () async => 'user-b',
      getLocalDataOwnerUid: () async => 'user-b',
      getClient: _refusingClient,
    );

    final report = await service.run();

    expect(report.total, 0);
  });

  // MALI-040 / Batch-3 §3 — MID-RUN stale-owner safety. The backfill captures
  // the uid once and asserts local-data ownership at PREFLIGHT; it does not
  // re-check per row. The mid-run window (an account switch AFTER preflight, while
  // the loop is pushing) is closed by the SERVER: every target table's RLS is
  // `WITH CHECK (user_id = auth.uid())`, so a push whose owner no longer matches
  // the auth token is rejected — and the client fails CLOSED (throws, no local
  // server_id stamped), leaving the row a backfill candidate for the next cycle
  // under the then-current owner. This proves that fail-closed contract.
  test(
      'mid-run server rejection (RLS refusing a stale-owner write) fails closed '
      '— the local row stays unsynced, never half-committed', () async {
    final db = await _openDb();
    addTearDown(db.close);
    // Accounts gate satisfied so the transaction upload loop actually runs.
    await db.customStatement("UPDATE accounts SET server_id = 'srv-acct';");
    await _seedOneTransaction(db); // server_id NULL — a backfill candidate

    SupabaseClient rejectingClient() {
      final http = MockClient((request) async {
        if (request.method == 'GET') {
          // No existing server row for this client_request_id.
          return Response('null', 200,
              headers: const {'content-type': 'application/json'});
        }
        // The write is rejected exactly as RLS rejects a user_id != auth.uid()
        // insert (Postgres 42501 / insufficient_privilege).
        return Response(
          jsonEncode({
            'code': '42501',
            'message': 'new row violates row-level security policy',
          }),
          403,
          headers: const {'content-type': 'application/json'},
        );
      });
      return SupabaseClient('https://example.supabase.co', 'public-anon-key',
          httpClient: http);
    }

    final service = TransactionsBackfillService(
      db: db,
      getAuthUserId: () async => 'user-a',
      getLocalDataOwnerUid: () async => 'user-a',
      getClient: rejectingClient,
    );

    await expectLater(service.run(), throwsA(isA<RepoException>()));

    final row = await db
        .customSelect(
          "SELECT server_id, sync_status FROM transactions WHERE id = 't1';",
        )
        .getSingle();
    expect(row.readNullable<String>('server_id'), isNull,
        reason: 'a rejected write must not stamp a server_id (fail-closed)');
    expect(row.readNullable<String>('sync_status'), isNot('synced'));
  });

  test('backfill metadata carries transfer_group_id only when the row has one',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await db.customStatement("UPDATE accounts SET server_id = 'srv-acct';");
    await _seedOneTransaction(db, id: 'linked');
    await _seedOneTransaction(db, id: 'plain');
    await db.customStatement("UPDATE transactions SET type = 'transfer', "
        "direction = 'debit', transfer_group_id = 'grp-1' WHERE id = 'linked';");

    final inserted = <String, Map<String, dynamic>>{};
    SupabaseClient capturingClient() {
      final http = MockClient((request) async {
        if (request.method == 'GET') {
          return Response('null', 200,
              headers: const {'content-type': 'application/json'},
              request: request);
        }
        final body = jsonDecode(request.body);
        final row = ((body is List ? body.single : body) as Map)
            .cast<String, dynamic>();
        inserted[row['client_request_id'] as String] = row;
        return Response(jsonEncode({...row, 'id': 'srv-${inserted.length}'}),
            201,
            headers: const {'content-type': 'application/json'},
            request: request);
      });
      return SupabaseClient('https://example.supabase.co', 'public-anon-key',
          httpClient: http);
    }

    await TransactionsBackfillService(
      db: db,
      getAuthUserId: () async => 'user-a',
      getLocalDataOwnerUid: () async => 'user-a',
      getClient: capturingClient,
    ).run();

    expect(
        inserted['backfill_transaction_linked']!['metadata']
            ['transfer_group_id'],
        'grp-1');
    expect(
        (inserted['backfill_transaction_plain']!['metadata'] as Map)
            .containsKey('transfer_group_id'),
        isFalse);
  });

  test('a backfilled transfer pair pulls onto an empty device as debit on '
      'From, credit on To, linked', () async {
    Future<AppDatabase> withAccounts() async {
      final db = await _openDb();
      addTearDown(db.close);
      await db.customStatement('DELETE FROM accounts;');
      for (final id in ['acc-a', 'acc-b']) {
        await db.customStatement(
          "INSERT INTO accounts(id, name, currency, type, created_at, "
          "updated_at, server_id) VALUES ('$id', '$id', 'SAR', 'bank', "
          "'2026-01-01', '2026-01-01', 'srv-$id');",
        );
      }
      await backfillNonPlanningMoneyV30(db);
      return db;
    }

    // A manual pair: the text carries no direction signal, so only the
    // stored direction can tell the legs apart.
    final source = await withAccounts();
    for (final (id, account, direction) in [
      ('leg-out', 'acc-a', 'debit'),
      ('leg-in', 'acc-b', 'credit'),
    ]) {
      await source.customStatement(
        "INSERT INTO transactions(id, amount, currency, type, source, "
        "direction, account_id, transfer_group_id, occurred_at, raw_message, "
        "parse_confidence, status, created_at, updated_at) VALUES ('$id', "
        "300, 'SAR', 'transfer', 'unknown', '$direction', '$account', "
        "'grp-1', '2026-07-15T10:00:00.000Z', 'Manual transaction', 1.0, "
        "'confirmed', '2026-07-15T10:00:00.000Z', '2026-07-15T10:00:00.000Z');",
      );
    }
    await backfillNonPlanningMoneyV30(source);

    final uploaded = <Map<String, dynamic>>[];
    await TransactionsBackfillService(
      db: source,
      getAuthUserId: () async => 'user-a',
      getLocalDataOwnerUid: () async => 'user-a',
      getClient: () => SupabaseClient(
        'https://example.supabase.co',
        'public-anon-key',
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return Response('null', 200,
                headers: const {'content-type': 'application/json'},
                request: request);
          }
          final body = jsonDecode(request.body);
          final row = {
            ...((body is List ? body.single : body) as Map)
                .cast<String, dynamic>(),
            'id': 'srv-${uploaded.length}',
            'amount_text': '300.0',
            'balance_after_text': null,
            'foreign_amount_text': null,
            'updated_at': '2026-07-15T10:00:0${uploaded.length}.000Z',
          };
          uploaded.add(row);
          return Response(jsonEncode(row), 201,
              headers: const {'content-type': 'application/json'},
              request: request);
        }),
      ),
    ).run();
    expect(uploaded, hasLength(2));

    final device = await withAccounts();
    await LedgerSyncService(
      db: device,
      transactionRepository: DriftTransactionRepository(device),
      dedupStore: DriftDedupStore(device),
      isPullEnabled: () => true,
      remoteSource: _Rows(uploaded),
      getAuthUserId: () async => 'user-a',
      mayEgress: () async => true,
    ).pull();

    final legs = [
      for (final r in await device
          .customSelect('SELECT account_id, direction, transfer_group_id '
              'FROM transactions ORDER BY account_id;')
          .get())
        r.data,
    ];
    expect(legs, [
      {
        'account_id': 'acc-a',
        'direction': 'debit',
        'transfer_group_id': 'grp-1'
      },
      {
        'account_id': 'acc-b',
        'direction': 'credit',
        'transfer_group_id': 'grp-1'
      },
    ]);
  });

  group('H-2 exact monetary reconciliation', () {
    Future<({TransactionBackfillReport report, Map<String, Object?> local})>
        run(
      Map<String, dynamic> remote,
    ) async {
      final db = await _openDb();
      addTearDown(db.close);
      await db.customStatement("UPDATE accounts SET server_id = 'srv-acct';");
      await _seedSecondaryMoneyTransaction(db);
      final report = await TransactionsBackfillService(
        db: db,
        getAuthUserId: () async => 'user-a',
        getLocalDataOwnerUid: () async => 'user-a',
        getClient: () => _existingTransactionClient(remote),
        coordinator: const FixedPlanningCutoverCoordinator(
          PlanningCutoverState.canonical,
        ),
      ).run();
      final local = (await db
              .customSelect(
                "SELECT server_id,synced_at,sync_status FROM transactions WHERE id='money-tx';",
              )
              .getSingle())
          .data;
      return (report: report, local: local);
    }

    test('remote balance_after mismatch is conflict, never synced', () async {
      final remote = _matchingRemoteTransaction()
        ..['balance_after_text'] = '90.76';
      final result = await run(remote);

      expect(result.report.mismatchedLocalIds, ['money-tx']);
      expect(result.local['sync_status'], 'conflict');
      expect(result.local['synced_at'], isNull);
    });

    test('remote foreign amount mismatch is conflict, never synced', () async {
      final remote = _matchingRemoteTransaction()
        ..['foreign_amount_text'] = '2.126';
      final result = await run(remote);

      expect(result.report.mismatchedLocalIds, ['money-tx']);
      expect(result.local['sync_status'], 'conflict');
      expect(result.local['synced_at'], isNull);
    });

    test('remote foreign currency mismatch is conflict, never synced',
        () async {
      final remote = _matchingRemoteTransaction()..['foreign_currency'] = 'SAR';
      final result = await run(remote);

      expect(result.report.mismatchedLocalIds, ['money-tx']);
      expect(result.local['sync_status'], 'conflict');
      expect(result.local['synced_at'], isNull);
    });

    test('all monetary dimensions matching stamps the row synced', () async {
      final result = await run(_matchingRemoteTransaction());

      expect(result.report.mismatchedLocalIds, isEmpty);
      expect(result.local['sync_status'], 'synced');
      expect(result.local['synced_at'], isNotNull);
    });
  });

  // The exact scenario from the release-blocker report: User A creates local
  // data, signs out, User B signs in, and a backfill run triggered by User B
  // (e.g. restoring a backup) must upload zero of User A's rows. WP-3b: A's rows
  // are KEPT in A's own replica (sign-out locks, never wipes) and B works in a
  // different database — proven here by an empty table in B's replica AND a
  // getClient that fails the test outright if anything ever tries to call
  // Supabase.

  test('end-to-end: sign-out keeps A\'s data in A\'s replica, B\'s backfill '
      'uploads zero rows',
      () async {
    final db = await _openDb();
    addTearDown(db.close);

    // User A creates local data and is the recorded owner (via a real
    // session reconciliation, exactly as production does on every launch).
    await AppSession.instance.completeOnboarding(
      method: 'google',
      email: 'a@example.com',
      userId: 'user-a',
    );
    final clientA = _authClient();
    await _recoverSession(clientA, 'user-a');
    await AppSession.instance.bindSupabaseAuth(clientA);
    expect(await AppSession.instance.readLocalDataOwnerUid(), 'user-a');
    await _seedOneTransaction(db);
    final countBeforeSignOut = await db
        .customSelect('SELECT COUNT(*) AS n FROM transactions;')
        .getSingle();
    expect(countBeforeSignOut.read<int>('n'), 1);

    // User A signs out — A's replica is kept (locked), the ownership marker is
    // cleared.
    await AppSession.instance.signOut();

    final countAfterSignOut = await db
        .customSelect('SELECT COUNT(*) AS n FROM transactions;')
        .getSingle();
    expect(countAfterSignOut.read<int>('n'), 1,
        reason: 'sign-out never discards A\'s data');
    expect(await AppSession.instance.readLocalDataOwnerUid(), isNull);
    final dbB = await _openDb();
    addTearDown(dbB.close);

    // User B signs in on the same device and their session reconciles,
    // claiming the now-unclaimed marker.
    await AppSession.instance.completeOnboarding(
      method: 'google',
      email: 'b@example.com',
      userId: 'user-b',
    );
    final clientB = _authClient();
    await _recoverSession(clientB, 'user-b');
    await AppSession.instance.bindSupabaseAuth(clientB);
    expect(await AppSession.instance.readLocalDataOwnerUid(), 'user-b');

    // B's own replica is seeded with one fresh default account; mark it as
    // already backfilled so only the transactions ownership guard (this
    // test's actual subject) is exercised, not the separate, already
    // independently-testable accounts-backfill precondition.
    await dbB.customStatement("UPDATE accounts SET server_id = 'srv-acct-b';");

    // User B triggers a backfill (e.g. via restoring a backup). A throwing
    // getClient means this test fails loudly if any row were ever uploaded.
    final service = TransactionsBackfillService(
      db: dbB,
      getAuthUserId: () async => 'user-b',
      getClient: _refusingClient,
    );

    final report = await service.run();

    expect(report.total, 0,
        reason: 'zero of User A\'s rows may be uploaded to User B\'s account');
  });
}
