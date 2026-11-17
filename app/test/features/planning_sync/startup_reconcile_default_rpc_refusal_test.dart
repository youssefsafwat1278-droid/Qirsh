import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/account_fence_store.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/tracking/user_activity_service.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/features/planning_sync/services/accounts_backfill_service.dart';
import 'package:money_companion/features/planning_sync/services/startup_sync_reconcile_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/session/f2_fixture.dart';
import '../capture/ledger_admission_fixture.dart';

// Stage A (E4 default-account backfill): the REAL StartupSyncReconcileService
// over the REAL admitted host database and the REAL global Supabase client,
// with MockClient as the only HTTP. Both cases drive the same three routes:
//
//   1 GET  user_accounts            -> the server row already matches (no INSERT)
//   2 POST rpc/set_default_account  -> positive {id} | raw 400 QD001
//   3 GET  user_transactions        -> ordinary 503 (controlled stop sentinel;
//                                      the SDK retries a 503 GET, so 4 requests)
//
// Route 3 is answered identically in both cases and the handler never throws,
// so a stop can only come from the service itself. The refusal case states the
// TARGET invariant (a genuine default-RPC denial must stop later chain work);
// it is judged only after the service future has settled. A genuine default-RPC
// denial now ends the run with a TYPED stop (AccountsDeliveryStopped) that is
// captured here as outcome evidence; every external assertion still runs. The
// accepted denial retires and closes the original database, so its retained
// rows are read through LedgerAdmissionFixture.inspectClosed with a location
// recorded BEFORE retirement. This is SDK -> MockClient only (mayEgress=true is
// not a Cloud-OFF proof) and the UUID correlation is local-only, never a server
// idempotency or replay identity.

const _uid = 'default-backfill-owner';
const _accountId = 'account-h2';
const _txId = 'tx-sentinel';
const _serverAccountId = '00000000-0000-4000-8000-0000000000a1';

const _accountSelect = '*,initial_balance_text:initial_balance::text,'
    'current_balance_text:current_balance::text,'
    'credit_limit_text:credit_limit::text,'
    'available_credit_text:available_credit::text';
const _transactionSelect = '*,amount_text:amount::text,'
    'balance_after_text:balance_after::text,'
    'foreign_amount_text:foreign_amount::text';

const _refusalPayload = {
  'code': 'QD001',
  'message': 'synthetic account refusal',
  'details': null,
  'hint': null,
};

typedef _Handler = Future<http.Response> Function(http.Request request);

Object? _decode(String body) {
  if (body.isEmpty) return null;
  try {
    return jsonDecode(body);
  } catch (_) {
    return body;
  }
}

Map<String, Object?> _describe(http.Request r) => {
      'method': r.method,
      'path': r.url.path,
      'query': Map<String, String>.of(r.url.queryParameters),
      'body': _decode(r.body),
    };

const _onboardingRequest = {
  'method': 'POST',
  'path': '/rest/v1/rpc/mark_onboarding_completed',
  'query': <String, String>{},
  'body': null,
};

const _accountLookup = {
  'method': 'GET',
  'path': '/rest/v1/user_accounts',
  'query': {
    'select': _accountSelect,
    'user_id': 'eq.$_uid',
    'local_id': 'eq.$_accountId',
  },
  'body': null,
};

const _defaultRpc = {
  'method': 'POST',
  'path': '/rest/v1/rpc/set_default_account',
  'query': <String, String>{},
  'body': {'p_account_id': _serverAccountId},
};

const _transactionLookup = {
  'method': 'GET',
  'path': '/rest/v1/user_transactions',
  'query': {
    'select': _transactionSelect,
    'user_id': 'eq.$_uid',
    // The backfill first looks for a server row keyed by the local id (the
    // key the outbox push uses) before its own `backfill_…` key, so a restored
    // row is bound instead of duplicated. That first lookup is the sentinel.
    'client_request_id': 'eq.$_txId',
  },
  'body': null,
};

Map<String, dynamic> _matchingServerAccount() => {
      'id': _serverAccountId,
      'name': 'Exact account',
      'currency': 'KWD',
      'type': 'card',
      'initial_balance': '12.345',
      'initial_balance_text': '12.345',
      'current_balance': '20.000',
      'current_balance_text': '20.000',
      'credit_limit': '500.000',
      'credit_limit_text': '500.000',
      'available_credit': '400.000',
      'available_credit_text': '400.000',
      'is_default': true,
      'deleted_at': null,
    };

Future<void> _seedLocal(AppDatabase db) async {
  const now = '2026-08-25T10:00:00.000Z';
  await db.customStatement('DELETE FROM transactions;');
  await db.customStatement('DELETE FROM accounts;');
  await db.customStatement('''
    INSERT INTO accounts(id,name,currency,type,initial_balance,initial_balance_minor,
      current_balance,current_balance_minor,credit_limit,credit_limit_minor,
      available_credit,available_credit_minor,is_default,sort_order,created_at,updated_at,
      sync_status,synced_at)
    VALUES('$_accountId','Exact account','KWD','card',12.345,12345,
      20.0,20000,500.0,500000,400.0,400000,1,0,'$now','$now',
      'pending','2026-08-24T00:00:00.000Z');
  ''');
  final occurred = dateTimeToSql(DateTime.utc(2026, 10, 1, 10));
  await db.customStatement('''
    INSERT INTO transactions(id, amount, amount_minor, currency, type, source,
      occurred_at, raw_message, parse_confidence, status, created_at, updated_at)
    VALUES ('$_txId', 100.0, 10000, 'SAR', 'payment', 'bank', '$occurred', '',
      0.9, 'confirmed', '$occurred', '$occurred');
  ''');
}

Future<Map<String, Object?>> _snapshot(AppDatabase db) async {
  Future<List<Map<String, Object?>>> rows(String sql) async =>
      [for (final r in await db.customSelect(sql).get()) r.data];
  return {
    'accounts': await rows('SELECT * FROM accounts ORDER BY id;'),
    'transactions': await rows('SELECT * FROM transactions ORDER BY id;'),
    'ledgerOutbox': (await rows('SELECT COUNT(*) AS n FROM ledger_sync_outbox;'))
        .single['n'],
    'planningOutbox':
        (await rows('SELECT COUNT(*) AS n FROM planning_sync_outbox;'))
            .single['n'],
  };
}

bool _isOnboarding(http.Request r) =>
    r.method == 'POST' && r.url.path == '/rest/v1/rpc/mark_onboarding_completed';

Matcher _stopped(AccountsDeliveryStopReason reason, {required bool accepted}) =>
    isA<AccountsDeliveryStopped>()
        .having((s) => s.reason, 'reason', reason)
        .having((s) => s.accepted, 'accepted', accepted);

/// Records every request; the handler never throws and never asserts. Only the
/// declared routes are answered, and `onRpc` controls the default RPC reply.
class _Net {
  final requests = <http.Request>[];
  final unknown = <String>[];
  int setupEnd = -1;
  int serviceEnd = -1;
  String? accountReadCode;
  Future<http.Response> Function(http.Request request, int attempt)? onRpc;
  int _rpcAttempts = 0;

  http.Response reply(http.Request r, int status, Object? body) =>
      http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'}, request: r);

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    final route = '${r.method} ${r.url.path}';
    if (_isOnboarding(r)) return reply(r, 200, null);
    if (route == 'GET /rest/v1/user_accounts') {
      final code = accountReadCode;
      return code == null
          ? reply(r, 200, _matchingServerAccount())
          : reply(r, 400, {
              'code': code,
              'message': 'synthetic read refusal',
              'details': null,
              'hint': null,
            });
    }
    final rpc = onRpc;
    if (route == 'POST /rest/v1/rpc/set_default_account' && rpc != null) {
      return rpc(r, ++_rpcAttempts);
    }
    unknown.add('${r.method} ${r.url} ${r.body}');
    return reply(r, 500, {
      'code': 'unexpected_fixture_request',
      'message': 'not allowlisted',
      'details': null,
      'hint': null,
    });
  }

  int get rpcRequests => requests
      .where((r) => r.url.path == '/rest/v1/rpc/set_default_account')
      .length;

  /// Service-window requests, onboarding lifecycle pings excluded.
  List<Map<String, Object?>> trace() => [
        for (var i = setupEnd; i < serviceEnd; i++)
          if (!_isOnboarding(requests[i])) _describe(requests[i]),
      ];

  Future<void> settle() async {
    await UserActivityService.waitPendingActivityWork();
    serviceEnd = requests.length;
  }

  /// Cumulative guard run after owned work and fixture cleanup, even when the
  /// body failed: nothing unknown, and outside the service window only the
  /// declared null onboarding RPC.
  void finalGuard() {
    expect(unknown, isEmpty, reason: 'cumulative unexpected HTTP');
    final start = setupEnd < 0 ? requests.length : setupEnd;
    for (var i = 0; i < requests.length; i++) {
      final inWindow = i >= start && (serviceEnd < 0 || i < serviceEnd);
      if (!inWindow) {
        expect(_describe(requests[i]), _onboardingRequest,
            reason: 'request $i outside the service window');
      }
    }
  }
}

/// Real client for reads/auth; the RPC factory fails SYNCHRONOUSLY. Nothing is
/// sent, so this can never be remote mutation proof.
class _FactoryFailureClient implements SupabaseClient {
  _FactoryFailureClient(this.inner, this.failure);
  final SupabaseClient inner;
  final Object Function() failure;
  int rpcAttempts = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #auth) return inner.auth;
    if (invocation.memberName == #from) {
      return inner.from(invocation.positionalArguments.single as String);
    }
    if (invocation.memberName == #rpc) {
      rpcAttempts++;
      throw failure();
    }
    return super.noSuchMethod(invocation);
  }
}

/// Real client over the real HTTP path; records whether the instance that built
/// the RPC had its signed-in user read first (the validated instance IS the
/// dispatch instance).
class _TrackedClient implements SupabaseClient {
  _TrackedClient(this.inner);
  final SupabaseClient inner;
  bool authRead = false;
  int rpcCalls = 0;
  bool authReadBeforeRpc = false;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #auth) {
      authRead = true;
      return inner.auth;
    }
    if (invocation.memberName == #from) {
      return inner.from(invocation.positionalArguments.single as String);
    }
    if (invocation.memberName == #rpc) {
      rpcCalls++;
      authReadBeforeRpc = authRead;
      return inner.rpc(invocation.positionalArguments.single as String,
          params: invocation.namedArguments[#params] as Map<String, dynamic>?);
    }
    return super.noSuchMethod(invocation);
  }
}

class _SdkMemoryStorage extends GotrueAsyncStorage {
  const _SdkMemoryStorage();
  @override
  Future<String?> getItem({required String key}) async => null;
  @override
  Future<void> setItem({required String key, required String value}) async {}
  @override
  Future<void> removeItem({required String key}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const configured = String.fromEnvironment('SUPABASE_ENV') == 'local' &&
      SupabaseConfig.url == 'https://example.supabase.co' &&
      SupabaseConfig.anonKey == 'anon';
  if (!configured) {
    test('default-RPC refusal qualification requires exact synthetic local defines',
        () {},
        skip: 'No qualification: requires SUPABASE_ENV=local, '
            'SUPABASE_URL=https://example.supabase.co, SUPABASE_ANON_KEY=anon');
    return;
  }

  late _Handler respond;
  setUpAll(() async {
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'anon',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
        pkceAsyncStorage: _SdkMemoryStorage(),
      ),
      httpClient: MockClient((request) => respond(request)),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());

  for (final refusal in [false, true]) {
    test(
        refusal
            ? 'default RPC QD001 refusal must stop later reconcile chain work'
            : 'matched positive: default RPC accepted reaches the transaction sentinel',
        () async {
      // Every request and reply is recorded BEFORE any judgement. The handler
      // never throws and never asserts: absence of later requests is therefore
      // observed, not manufactured.
      final requests = <http.Request>[];
      final replies = <({int status, Object? body})>[];
      final unknown = <String>[];
      http.Response reply(http.Request r, int status, String body,
          {String type = 'application/json'}) {
        replies.add((status: status, body: _decode(body)));
        return http.Response(body, status,
            headers: {'content-type': type}, request: r);
      }

      respond = (r) async {
        requests.add(r);
        final route = '${r.method} ${r.url.path}';
        switch (route) {
          case 'POST /rest/v1/rpc/mark_onboarding_completed':
            return reply(r, 200, 'null');
          case 'GET /rest/v1/user_accounts':
            return reply(r, 200, jsonEncode(_matchingServerAccount()));
          case 'POST /rest/v1/rpc/set_default_account':
            return refusal
                ? reply(r, 400, jsonEncode(_refusalPayload))
                : reply(r, 200, jsonEncode({'id': _serverAccountId}));
          case 'GET /rest/v1/user_transactions':
            return reply(r, 503, 'synthetic unavailable', type: 'text/plain');
        }
        unknown.add('${r.method} ${r.url} ${r.body}');
        return reply(
            r,
            500,
            jsonEncode({
              'code': 'unexpected_fixture_request',
              'message': 'not allowlisted',
              'details': null,
              'hint': null,
            }));
      };

      LedgerAdmissionFixture? opened;
      int? setupCount;
      int? serviceSettledCount;
      Object? primary;
      StackTrace? primaryStack;
      final secondary = <(String, Object, StackTrace)>[];

      // Cumulative external HTTP guard, run AFTER every owned producer and the
      // fixture cleanup have settled (and even if the body or cleanup failed).
      // Unknown routes are never handled by a wildcard; this only judges.
      void finalHttpGuard() {
        expect(unknown, isEmpty, reason: 'cumulative unexpected HTTP');
        final setupEnd = setupCount;
        final serviceEnd = serviceSettledCount;
        expect(
            (setupEnd == null ? requests : requests.take(setupEnd))
                .map(_describe),
            everyElement(_onboardingRequest),
            reason: 'setup HTTP must be only the declared null onboarding RPC');
        if (serviceEnd != null) {
          expect(requests.skip(serviceEnd).map(_describe),
              everyElement(_onboardingRequest),
              reason: 'any HTTP after the service settled (late service or '
                  'cleanup) must be only the declared null onboarding RPC');
        }
      }

      try {
        // Actual global SDK client with a recovered synthetic session, BEFORE
        // admission so the admission callbacks see the matching SDK uid.
        await F2Fixture.recoverSession_(Supabase.instance.client, _uid);
        final admission = await LedgerAdmissionFixture.open(_uid);
        opened = admission;
        // Setup producers (sign-in activity ping) settle before the service
        // window starts; setup requests stay in `requests`, never cleared.
        await UserActivityService.waitPendingActivityWork();
        final setupEnd = requests.length;
        setupCount = setupEnd;
        final db = admission.database;
        final session = admission.fixture.session;
        await _seedLocal(db);

        final capability = session.captureLocalWorkAuthority()!;
        Future<Map<String, Object?>> observe() async => {
              'capabilityCurrent': capability.isCurrent,
              'hold': AccountFenceAuthority.shared.store
                  .holdFor(AccountFenceStore.ownerDigest(_uid))
                  ?.state
                  .toString(),
              'egressEpoch': CloudEgressGate.instance.epoch,
              'ownerMarker': await session.readLocalDataOwnerUid(),
              'ownerGeneration':
                  admission.fixture.storage.data[kGenerationKey],
              'hostDatabaseIsServiceDatabase':
                  identical(admission.fixture.host.current?.database, db),
            };
        final before = await _snapshot(db);
        final observedBefore = await observe();

        // Recorded BEFORE any retirement: the host scope is gone afterwards.
        final originalLocation = admission.location;
        ReconcileOutcome? outcome;
        Object? stopped;
        try {
          outcome = await StartupSyncReconcileService(
            db: db,
            mayEgress: () async => true,
          ).run();
        } on AccountFenceDeliveryCancellation catch (error) {
          stopped = error;
        }
        final settledEnd = requests.length;
        serviceSettledCount = settledEnd;

        final after = stopped == null
            ? await _snapshot(db)
            : await LedgerAdmissionFixture.inspectClosed(
                db, originalLocation, _snapshot);
        final observedAfter = await observe();
        final setup = requests.take(setupEnd).map(_describe).toList();
        final trace =
            requests.sublist(setupEnd, settledEnd).map(_describe).toList();
        final serviceReplies = replies.sublist(setupEnd, settledEnd);

        // ignore: avoid_print
        print('STAGE-A ${refusal ? 'refusal' : 'positive'} '
            'outcome=$outcome stopped=$stopped setupRequests=${setup.length}\n'
            'trace=${trace.map((r) => '${r['method']} ${r['path']}').toList()}\n'
            'replyStatuses=${serviceReplies.map((r) => r.status).toList()}\n'
            'rpcReply=${serviceReplies.length > 1 ? serviceReplies[1].body : null}\n'
            'observedBefore=$observedBefore\nobservedAfter=$observedAfter');

        // ── Fixture / setup validity (a failure here is NOT a product RED) ──
        expect(unknown, isEmpty, reason: 'unexpected HTTP reached the mock');
        expect(setup, everyElement(_onboardingRequest),
            reason: 'only the strict onboarding RPC is allowed during setup');
        expect(before['ledgerOutbox'], 0);
        expect(before['planningOutbox'], 0);
        expect(observedBefore['capabilityCurrent'], isTrue);
        expect(observedBefore['ownerMarker'], _uid);
        expect(observedBefore['hostDatabaseIsServiceDatabase'], isTrue);
        expect(trace.length, greaterThanOrEqualTo(2),
            reason: 'account match and default RPC must both be reached');
        expect(trace[0], _accountLookup, reason: 'matching account GET');
        expect(trace[1], _defaultRpc, reason: 'default RPC mutation request');
        if (refusal) {
          expect(serviceReplies[1].status, 400);
          expect(serviceReplies[1].body, _refusalPayload,
              reason: 'raw structured QD001 must be what the SDK received');
        } else {
          expect(serviceReplies[1].status, 200);
          expect(serviceReplies[1].body, {'id': _serverAccountId});
        }
        // Everything after the first two requests must be the declared
        // transaction lookup answered 503, so a malformed or unexpected route
        // can never masquerade as the product RED asserted below.
        for (var i = 2; i < trace.length; i++) {
          expect(trace[i], _transactionLookup,
              reason: 'request $i after the default RPC');
          expect(serviceReplies[i].status, 503,
              reason: 'reply $i after the default RPC');
        }

        // Legitimate pre-RPC account stamp, sentinel untouched, no queue rows.
        final account = (after['accounts'] as List).single as Map;
        expect(account['server_id'], _serverAccountId);
        expect(account['sync_status'], 'synced');
        final txBefore = before['transactions'] as List;
        expect(after['transactions'], txBefore,
            reason: 'sentinel transaction stays unsynced and unchanged');
        expect((txBefore.single as Map)['server_id'], isNull);
        expect(after['ledgerOutbox'], 0);
        expect(after['planningOutbox'], 0);
        expect(observedAfter['ownerMarker'], _uid);
        expect(observedAfter['ownerGeneration'],
            observedBefore['ownerGeneration']);
        if (stopped == null) {
          expect(observedAfter['hostDatabaseIsServiceDatabase'], isTrue);
        } else {
          // An accepted denial retires the host scope and closes its database.
          expect(db.lifecycleState, DatabaseLifecycleState.closed);
        }

        if (!refusal) {
          expect(stopped, isNull);
          // Positive REACHABILITY control: the chain continued to the sentinel
          // and ended in the ordinary 503 stop. This is not a reconcile pass.
          // The pinned postgrest 2.7.1 builder retries a 503 GET three times,
          // so the single sentinel lookup is observed as four identical
          // requests, each answered 503 by the unchanged mock handler.
          expect(trace, [
            _accountLookup,
            _defaultRpc,
            ...List.filled(4, _transactionLookup),
          ]);
          expect(serviceReplies.map((r) => r.status).toList(),
              [200, 200, 503, 503, 503, 503]);
          expect(outcome, ReconcileOutcome.failed);
          expect(account['is_default'], 1);
        } else {
          // TARGET invariant: a genuine default-RPC QD001 denial must stop
          // later chain HTTP. Judged only after the service Future settled.
          expect(trace, [_accountLookup, _defaultRpc],
              reason: 'no transaction (or later) request may follow a '
                  'default-RPC QD001 refusal');
          expect(outcome?.isProvenComplete ?? false, isFalse);
          // A returned failed/partial is NOT stop evidence: the run must have
          // ended with the typed, accepted denial and no returned outcome.
          expect(outcome, isNull);
          expect(
              stopped,
              isA<AccountsDeliveryStopped>()
                  .having((s) => s.reason, 'reason',
                      AccountsDeliveryStopReason.denial)
                  .having((s) => s.accepted, 'accepted', isTrue)
                  .having((s) => s.complete, 'complete', isTrue));
          expect(observedAfter['hold'], AccountFenceState.pending.toString());
        }
      } catch (error, stack) {
        primary = error;
        primaryStack = stack;
      }

      // Cleanup and the final guard always run, whatever the body did; each
      // step is isolated so one failure cannot skip the others.
      Future<void> step(String label, Future<void> Function() action) async {
        try {
          await action();
        } catch (error, stack) {
          secondary.add((label, error, stack));
        }
      }

      await step('stopAutoRefresh', () async {
        Supabase.instance.client.auth.stopAutoRefresh();
      });
      final fixture = opened;
      if (fixture != null) await step('fixture.finish', fixture.finish);
      await step('activity drain', UserActivityService.waitPendingActivityWork);
      await step('final HTTP guard', () async => finalHttpGuard());

      final reported = primary == null ? secondary.skip(1) : secondary;
      for (final (label, error, stack) in reported) {
        printOnFailure('STAGE-A secondary failure ($label): $error\n$stack');
      }
      if (primary != null) Error.throwWithStackTrace(primary, primaryStack!);
      if (secondary.isNotEmpty) {
        Error.throwWithStackTrace(secondary.first.$2, secondary.first.$3);
      }
    });
  }

  // ── Dedicated default-command scenarios ────────────────────────────────────
  // Same real admitted host database and real global SDK client over the
  // MockClient, driving AccountsBackfillService directly (the coordinator is
  // covered by the original control above). SDK -> Mock only; not a deployed
  // or Cloud-OFF proof. Each scenario runs the owned cleanup and the cumulative
  // HTTP guard even when its body fails, and rethrows the primary failure.

  Future<void> scenario(
    _Net net,
    Future<void> Function(LedgerAdmissionFixture admission, AppDatabase db) body, {
    LedgerDatabaseProbe? probe,
  }) async {
    respond = net.handle;
    LedgerAdmissionFixture? opened;
    Object? primary;
    StackTrace? primaryStack;
    final secondary = <(String, Object, StackTrace)>[];
    try {
      await F2Fixture.recoverSession_(Supabase.instance.client, _uid);
      final admission = await LedgerAdmissionFixture.open(_uid, probe);
      opened = admission;
      await UserActivityService.waitPendingActivityWork();
      net.setupEnd = net.requests.length;
      await _seedLocal(admission.database);
      await body(admission, admission.database);
    } catch (error, stack) {
      primary = error;
      primaryStack = stack;
    }
    Future<void> step(String label, Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        secondary.add((label, error, stack));
      }
    }

    await step('stopAutoRefresh', () async {
      Supabase.instance.client.auth.stopAutoRefresh();
    });
    final fixture = opened;
    if (fixture != null) await step('fixture.finish', fixture.finish);
    await step('activity drain', UserActivityService.waitPendingActivityWork);
    await step('final HTTP guard', () async => net.finalGuard());
    final reported = primary == null ? secondary.skip(1) : secondary;
    for (final (label, error, stack) in reported) {
      printOnFailure('default scenario secondary failure ($label): $error\n$stack');
    }
    if (primary != null) Error.throwWithStackTrace(primary, primaryStack!);
    if (secondary.isNotEmpty) {
      Error.throwWithStackTrace(secondary.first.$2, secondary.first.$3);
    }
  }

  AccountsBackfillService accounts(
    AppDatabase db, {
    Future<bool> Function()? mayEgress,
    SupabaseClient Function()? client,
  }) =>
      AccountsBackfillService(
        db: db,
        mayEgress: mayEgress ?? () async => true,
        getClient: client,
      );

  Future<({Object? value, Object? error})> outcomeOf(Future<Object?> run) async {
    try {
      return (value: await run, error: null);
    } catch (error) {
      return (value: null, error: error);
    }
  }

  Map<String, Object?> refusalBody(String code) =>
      {'code': code, 'message': 'synthetic', 'details': null, 'hint': null};

  AccountFenceRecord? holdOf() =>
      AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid));

  void expectSuccessorUntouched(LedgerAdmissionFixture admission, AppDatabase db) {
    expect(holdOf(), isNull, reason: 'no account restriction may be recorded');
    expect(db.lifecycleState, isNot(DatabaseLifecycleState.closed));
    expect(admission.fixture.session.captureLocalWorkAuthority()?.isCurrent, isTrue);
  }

  for (final (code, state) in [
    ('QD001', AccountFenceState.pending),
    ('QD002', AccountFenceState.gone),
  ]) {
    test('default RPC $code is accepted as ${state.name}: typed stop, stamp and '
        'sentinel retained', () async {
      final net = _Net();
      net.onRpc = (r, n) async => net.reply(r, 400, refusalBody(code));
      await scenario(net, (admission, db) async {
        final location = admission.location; // before retirement
        final before = await _snapshot(db);
        final run = await outcomeOf(accounts(db).run());
        await net.settle();
        expect(run.error, _stopped(AccountsDeliveryStopReason.denial, accepted: true));
        expect((run.error as AccountsDeliveryStopped).complete, isTrue);
        expect(net.trace(), [_accountLookup, _defaultRpc]);
        expect(db.lifecycleState, DatabaseLifecycleState.closed);
        expect(holdOf()?.state, state);
        final after =
            await LedgerAdmissionFixture.inspectClosed(db, location, _snapshot);
        final account = (after['accounts'] as List).single as Map;
        expect(account['server_id'], _serverAccountId);
        expect(account['sync_status'], 'synced');
        expect(account['is_default'], 1);
        expect(after['transactions'], before['transactions']);
        expect(after['ledgerOutbox'], 0);
        expect(after['planningOutbox'], 0);
      });
    });
  }

  for (final denial in [false, true]) {
    test('late default RPC ${denial ? 'denial' : 'success'} after the original '
        'lifetime ended cannot affect the successor', () async {
      final net = _Net();
      final reached = Completer<void>();
      final release = Completer<void>();
      net.onRpc = (r, n) async {
        reached.complete();
        await release.future;
        return denial
            ? net.reply(r, 400, refusalBody('QD001'))
            : net.reply(r, 200, {'id': _serverAccountId});
      };
      await scenario(net, (admission, db) async {
        Object? error;
        final done = accounts(db).run().then<void>((_) {}, onError: (Object e) {
          error = e;
        });
        try {
          await reached.future;
          final successor = await admission.restart();
          await successor.customStatement('UPDATE accounts SET is_default = 0;');
          final successorBefore = await _snapshot(successor);
          release.complete();
          await done;
          await net.settle();
          expect(
              error,
              _stopped(
                  denial
                      ? AccountsDeliveryStopReason.denial
                      : AccountsDeliveryStopReason.stale,
                  accepted: false));
          expect(await _snapshot(successor), successorBefore,
              reason: 'the stale result must not change the successor');
          expectSuccessorUntouched(admission, successor);
          expect(net.trace(), [_accountLookup, _defaultRpc]);
        } finally {
          if (!release.isCompleted) release.complete();
          await done;
        }
      });
    });
  }

  for (final denial in [false, true]) {
    test('default command edited in flight is '
        '${denial ? 'kept while the denial is still accepted' : 'never retargeted or retried'}',
        () async {
      final net = _Net();
      late AppDatabase original;
      net.onRpc = (r, n) async {
        await original.customStatement(
            "UPDATE accounts SET name = 'Edited locally' WHERE id = ?;",
            [_accountId]);
        return net.reply(r, 400, refusalBody(denial ? 'QD001' : '55P03'));
      };
      await scenario(net, (admission, db) async {
        original = db;
        final location = admission.location;
        final run = await outcomeOf(accounts(db).run());
        await net.settle();
        expect(net.trace(), [_accountLookup, _defaultRpc],
            reason: 'one immutable request; no retry and no new target');
        if (denial) {
          expect(run.error, _stopped(AccountsDeliveryStopReason.denial, accepted: true));
          final after =
              await LedgerAdmissionFixture.inspectClosed(db, location, _snapshot);
          final account = (after['accounts'] as List).single as Map;
          expect(account['name'], 'Edited locally');
          expect(account['server_id'], _serverAccountId);
          expect(account['sync_status'], 'synced');
        } else {
          expect(run.error, _stopped(AccountsDeliveryStopReason.stale, accepted: false));
          expectSuccessorUntouched(admission, db);
          final account = ((await _snapshot(db))['accounts'] as List).single as Map;
          expect(account['name'], 'Edited locally');
          expect(account['is_default'], 1);
        }
      });
    });
  }

  test('raw QD on the account READ is never accepted as a default mutation',
      () async {
    final net = _Net()..accountReadCode = 'QD001';
    net.onRpc = (r, n) async => net.reply(r, 400, refusalBody('QD001'));
    await scenario(net, (admission, db) async {
      final run = await outcomeOf(accounts(db).run());
      await net.settle();
      expect(run.error, isNot(isA<AccountFenceDeliveryCancellation>()));
      expect(net.rpcRequests, 0);
      expectSuccessorUntouched(admission, db);
    });
  });

  test('raw QD thrown by the synchronous RPC factory is unaccepted and sends '
      'nothing', () async {
    final net = _Net();
    await scenario(net, (admission, db) async {
      final client = _FactoryFailureClient(Supabase.instance.client,
          () => const PostgrestException(message: 'synthetic factory', code: 'QD001'));
      final run = await outcomeOf(accounts(db, client: () => client).run());
      await net.settle();
      expect(run.error, _stopped(AccountsDeliveryStopReason.provenance, accepted: false));
      expect(client.rpcAttempts, 1);
      expect(net.rpcRequests, 0);
      expectSuccessorUntouched(admission, db);
    });
  });

  test('55P03 thrown by the factory is not retried; 55P03 from the awaited RPC '
      'is retried exactly three times then ends as exhaustion', () async {
    final factoryNet = _Net();
    await scenario(factoryNet, (admission, db) async {
      final client = _FactoryFailureClient(Supabase.instance.client,
          () => const PostgrestException(message: 'synthetic factory', code: '55P03'));
      final run = await outcomeOf(accounts(db, client: () => client).run());
      await factoryNet.settle();
      expect(run.error, isNull, reason: 'ordinary warning contract, no stop');
      final report = run.value as AccountBackfillReport;
      expect(report.defaultResolved, isFalse);
      expect(report.defaultWarning, contains('set_default_account failed'));
      expect(client.rpcAttempts, 1, reason: 'unproven 55P03 must not be retried');
      expect(factoryNet.rpcRequests, 0);
      expectSuccessorUntouched(admission, db);
    });

    final rpcNet = _Net();
    rpcNet.onRpc = (r, n) async => rpcNet.reply(r, 400, refusalBody('55P03'));
    await scenario(rpcNet, (admission, db) async {
      final run = await outcomeOf(accounts(db).run());
      await rpcNet.settle();
      expect(run.error, isA<DefaultAccountBackfillContentionExhausted>());
      expect(rpcNet.trace(), [_accountLookup, ...List.filled(3, _defaultRpc)]);
      expectSuccessorUntouched(admission, db);
      final account = ((await _snapshot(db))['accounts'] as List).single as Map;
      expect(account['is_default'], 1);
    });
  });

  test('consent loss and lifetime loss before dispatch stop without any RPC',
      () async {
    final consentNet = _Net();
    await scenario(consentNet, (admission, db) async {
      final run = await outcomeOf(accounts(db, mayEgress: () async => false).run());
      await consentNet.settle();
      expect(run.error, _stopped(AccountsDeliveryStopReason.stale, accepted: false));
      expect(consentNet.trace(), [_accountLookup]);
      expectSuccessorUntouched(admission, db);
    });

    final lifetimeNet = _Net();
    await scenario(lifetimeNet, (admission, db) async {
      final run = await outcomeOf(accounts(db, mayEgress: () async {
        await admission.restart(); // the original lifetime ends during the wait
        return true;
      }).run());
      await lifetimeNet.settle();
      expect(run.error, _stopped(AccountsDeliveryStopReason.stale, accepted: false));
      expect(lifetimeNet.trace(), [_accountLookup]);
      expectSuccessorUntouched(admission, admission.database);
    });
  });
  test('the default RPC is built on the one client instance whose user was '
      'validated', () async {
    final net = _Net();
    net.onRpc = (r, n) async => net.reply(r, 200, {'id': _serverAccountId});
    await scenario(net, (admission, db) async {
      final clients = <_TrackedClient>[];
      SupabaseClient factory() {
        final client = _TrackedClient(Supabase.instance.client);
        clients.add(client);
        return client;
      }

      final run = await outcomeOf(accounts(db, client: factory).run());
      await net.settle();
      expect(run.error, isNull);
      expect((run.value as AccountBackfillReport).defaultResolved, isTrue);
      expect(net.trace(), [_accountLookup, _defaultRpc]);
      final sent = clients.where((c) => c.rpcCalls > 0).toList();
      expect(sent, hasLength(1));
      expect(sent.single.rpcCalls, 1);
      expect(sent.single.authReadBeforeRpc, isTrue,
          reason: 'the RPC was built on a client whose user was never checked');
    });
  });

  test('consent lost while a successful default RPC is in flight stops without '
      'any local default update', () async {
    final net = _Net();
    var allow = true;
    final reached = Completer<void>();
    final release = Completer<void>();
    net.onRpc = (r, n) async {
      reached.complete();
      await release.future;
      return net.reply(r, 200, {'id': _serverAccountId});
    };
    final sql = <String>[];
    final probe = LedgerDatabaseProbe()..before = (statement) async => sql.add(statement);
    await scenario(net, (admission, db) async {
      Object? error;
      Object? value;
      final done = accounts(db, mayEgress: () async => allow).run().then<void>(
          (v) => value = v, onError: (Object e) => error = e);
      try {
        await reached.future;
        final mark = sql.length;
        final before = await _snapshot(db);
        allow = false; // consent turns off; the original cap and command are unchanged
        release.complete();
        await done;
        await net.settle();
        expect(value, isNull);
        expect(error, _stopped(AccountsDeliveryStopReason.stale, accepted: false));
        expect(sql.skip(mark).where((s) => s.contains('UPDATE accounts SET is_default')),
            isEmpty,
            reason: 'no default finalization may even be attempted');
        expect(await _snapshot(db), before);
        final account = ((await _snapshot(db))['accounts'] as List).single as Map;
        expect(account['server_id'], _serverAccountId, reason: 'legitimate match stamp kept');
        expect(account['sync_status'], 'synced');
        expect(net.trace(), [_accountLookup, _defaultRpc]);
        expectSuccessorUntouched(admission, db);
      } finally {
        if (!release.isCompleted) release.complete();
        await done;
      }
    }, probe: probe);
  });

  test('raw QD from default preflight stops without mutation authority', () async {
    final net = _Net();
    final sql = <String>[];
    final probe = LedgerDatabaseProbe()..before = (statement) async => sql.add(statement);
    await scenario(net, (admission, db) async {
      final run = await outcomeOf(accounts(db,
          mayEgress: () async => throw const PostgrestException(
              message: 'synthetic preflight', code: 'QD001')).run());
      await net.settle();
      expect(net.rpcRequests, 0);
      expect(net.trace(), [_accountLookup]);
      expect(sql.where((s) => s.contains('UPDATE accounts SET is_default')), isEmpty,
          reason: 'no local default update may be attempted');
      final account = ((await _snapshot(db))['accounts'] as List).single as Map;
      expect(account['server_id'], _serverAccountId, reason: 'legitimate match stamp kept');
      expect(account['sync_status'], 'synced');
      expect(account['is_default'], 1);
      expectSuccessorUntouched(admission, db);
      expect(run.error, _stopped(AccountsDeliveryStopReason.provenance, accepted: false));
    }, probe: probe);
  });
}
