@Tags(['deletion-replica-io'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/auth/apple_deletion_reauth.dart';
import 'package:money_companion/core/auth/immediate_deletion_flow.dart';
import 'package:money_companion/core/auth/immediate_deletion_receipt_store.dart';
import 'package:money_companion/core/auth/prepared_immediate_deletion_gateway.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../harness/egress_test_support.dart';
import '../session/f2_fixture.dart';

// The REAL prepared gateway, session, scope host and egress gate; only the
// network transport, receipt persistence and Apple platform sheet are faked.

const _bound = Duration(seconds: 8);
const _owner = 'flow-owner-a';
const _other = 'flow-owner-b';
final _url = Uri.parse(
    'https://example.supabase.co/functions/v1/delete-account-immediate');
Future<T> _bounded<T>(Future<T> work) => work.timeout(_bound);

http.Response _json(Map<String, Object?> body, [int code = 200]) =>
    http.Response(jsonEncode(body), code,
        headers: {'content-type': 'application/json'});
http.Response _status(String status, [int code = 200]) =>
    _json({'status': status}, code);
http.Response _challenge([String? method]) => _json({
      'status': 'challenge',
      'challenge_id': 'challenge-id-0123456789abcdef',
      'nonce': 'raw-nonce-0123456789abcdef',
      'expires_at_ms': 4102444800000,
      if (method != null) 'proof_method': method,
    });

class _FakeApple implements AppleDeletionReauth {
  _FakeApple(this.next);
  AppleReauthResult Function(String nonce) next;
  final nonces = <String>[];
  Future<void> Function()? during;
  @override
  Future<AppleReauthResult> reauthenticate({required String nonce}) async {
    nonces.add(nonce);
    await during?.call();
    return next(nonce);
  }
}

class _World {
  final session = AppSession.instance;
  final values = <String, String>{};
  final requests = <http.Request>[];
  final bodies = <Map<String, dynamic>>[];
  final unexpectedSdk = <http.Request>[];
  final gateways = <PreparedImmediateDeletionGateway>[];
  final databases = <Object>[];
  final oldGate = CloudEgressGate.instance;
  final egress = TestEgress();
  late F2Fixture fixture;
  late SupabaseClient sdk;
  late MockClient transport;
  late void Function() restoreFence;
  bool bound = false;

  Future<http.Response> Function(String action, http.Request) answer =
      (action, _) async => switch (action) {
            'challenge' => _challenge(),
            'status' => _status('in_progress'),
            _ => _status('accepted', 202),
          };

  late final store = ImmediateDeletionReceiptStore(
    authority: Object(),
    read: (key) async => values[key],
    write: (key, value) async => values[key] = value,
    delete: (key) async => values.remove(key),
  );

  static Future<_World> open() async {
    final h = _World();
    await h.session.debugResetAuthBinding();
    h.session.configureAccountScope(null);
    await h.session.drainAdmissions();
    h.restoreFence = AccountFenceAuthority.replacePersistenceForTest();
    h.fixture = await F2Fixture.create(afterWithdraw: () async {});
    h.session.configureAccountScope(h.fixture.host);
    h.sdk = SupabaseClient('https://example.supabase.co', 'synthetic-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        // Same gated transport as production: a local sign-out's logout request
        // is denied with Cloud OFF and never reaches the socket.
        httpClient: GatedHttpClient(MockClient((request) async {
      h.unexpectedSdk.add(request);
      throw StateError('unexpected SDK transport');
    })));
    await F2Fixture.recoverSession_(h.sdk, _owner);
    h.transport = MockClient((request) async {
      h.requests.add(request);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      h.bodies.add(body);
      final action = body['action'] as String? ?? 'request';
      return h.answer(action, request);
    });
    h.egress.owner = _owner;
    h.egress.install();
    await h.admit();
    return h;
  }

  Future<void> admit() async {
    final actual = sdk.auth.currentSession!;
    await session.setIdentity(
        method: 'apple',
        email: actual.user.email,
        userId: actual.user.id,
        sessionCurrent: () =>
            sdk.auth.currentSession?.accessToken == actual.accessToken &&
            sdk.auth.currentSession?.isExpired == false);
    await session.finishOnboarding(client: sdk);
    if (!bound) {
      final event = Completer<void>();
      session.debugAuthEventCompleted = (type) {
        if (type == AuthChangeEvent.tokenRefreshed && !event.isCompleted) {
          event.complete();
        }
      };
      try {
        await session.bindSupabaseAuth(sdk);
        await _bounded(event.future);
      } finally {
        session.debugAuthEventCompleted = null;
      }
      bound = true;
    } else {
      await session.bindSupabaseAuth(sdk);
    }
    expect(session.captureDatabaseHostAdmission()?.isCurrent, isTrue);
  }

  Future<void> switchTo(String next) async {
    final event = Completer<void>();
    session.debugAuthEventCompleted = (type) {
      if (type == AuthChangeEvent.tokenRefreshed && !event.isCompleted) {
        event.complete();
      }
    };
    try {
      await F2Fixture.recoverSession_(sdk, next);
      await _bounded(event.future);
    } finally {
      session.debugAuthEventCompleted = null;
    }
    egress.owner = next;
    await admit();
  }

  /// A fresh gateway/flow over the SAME persisted receipts = an app restart.
  GatewayDeletionFlow flow(
    _FakeApple apple, {
    bool retain = true,
    bool? emailOnly,
    Future<AppleReauthResult> Function(String)? googleProof,
  }) {
    final gateway = PreparedImmediateDeletionGateway(
        session: session,
        host: fixture.host,
        client: sdk,
        store: store,
        transport: transport,
        functionUrl: _url,
        gate: egress.gate,
        retainReceiptUntilLocalRemoval: retain,
        requestTimeout: const Duration(seconds: 2));
    gateways.add(gateway);
    return GatewayDeletionFlow(
        gateway: gateway,
        apple: apple,
        emailOnly: emailOnly,
        googleProof: googleProof);
  }

  List<String> get actions =>
      [for (final b in bodies) b['action'] as String? ?? 'request'];

  Future<void> finish() async {
    for (final gateway in gateways) {
      await _bounded(gateway.waitPendingWork());
    }
    session.debugAuthEventCompleted = null;
    await _bounded(session.debugResetAuthBinding());
    await _bounded(session.drainAdmissions());
    await _bounded(fixture.dispose());
    await _bounded(sdk.dispose());
    transport.close();
    CloudEgressGate.instance = oldGate;
    restoreFence();
    expect(unexpectedSdk, isEmpty);
  }
}

Future<void> _world(Future<void> Function(_World) test) async {
  final h = await _World.open();
  try {
    await test(h);
  } finally {
    await h.finish();
  }
}

_FakeApple _granted() => _FakeApple((_) => const AppleReauthGranted(
    '{"identity_token":"synthetic-id","authorization_code":"synthetic-code"}'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<DeletionFlowSession> begin(GatewayDeletionFlow flow) async {
    final DeletionFlowSession? session = await _bounded(flow.begin());
    return session!;
  }

  test(
      'challenge -> Apple (raw nonce) -> request; completion removes only the '
      'original local replica and only then is the flow Completed',
      () => _world((h) async {
            h.answer = (action, _) async =>
                action == 'challenge' ? _challenge() : _status('completed');
            final apple = _granted();
            final session = await begin(h.flow(apple));
            expect(h.requests, isEmpty, reason: 'prepare sends nothing');
            expect(await h.fixture.artifactsOf(_owner), isNotEmpty);

            // The SDK session is signed out locally once removal completes.
            final token = h.sdk.auth.currentSession?.accessToken;
            final result = await _bounded(session.confirm());

            expect(result, isA<DeletionFlowCompleted>());
            expect(h.actions, ['challenge', 'request']);
            expect(h.sdk.auth.currentSession, isNull);
            expect(h.requests.first.headers['Authorization'], 'Bearer $token');
            expect(h.bodies.first, {'action': 'challenge'});
            expect(apple.nonces, ['raw-nonce-0123456789abcdef']);
            final request = h.bodies.last;
            expect(request['challenge_id'], 'challenge-id-0123456789abcdef');
            expect(jsonDecode(request['challenge_response'] as String), {
              'identity_token': 'synthetic-id',
              'authorization_code': 'synthetic-code',
            });
            expect(await h.fixture.artifactsOf(_owner), isEmpty,
                reason: 'original local replica removed after remote proof');
          }));

  for (final method in ['google', 'email']) {
    test(
        '$method proves deletion inside the original account operation',
        () => _world((h) async {
              h.answer = (action, _) async => action == 'challenge'
                  ? _challenge(method)
                  : _status('completed');
              final apple = _granted();
              final session = await begin(h.flow(
                apple,
                emailOnly: method == 'email',
                googleProof: (nonce) async {
                  expect(method, 'google');
                  expect(nonce, 'raw-nonce-0123456789abcdef');
                  return const AppleReauthGranted(
                      '{"proof":"google","identity_token":"test"}');
                },
              ));
              final result = await (session as EmailProofDeletionSession)
                  .confirmWithEmailProof(() async {
                expect(method, 'email');
                return '00001234';
              });
              expect(result, isA<DeletionFlowCompleted>());
              expect(apple.nonces, isEmpty);
              expect(h.bodies.first, {
                'action': 'challenge',
                'proof_version': 2,
                'email_only': method == 'email',
              });
              final response =
                  jsonDecode(h.bodies.last['challenge_response'] as String);
              expect(response['proof'], method);
              if (method == 'email') expect(response['code'], '00001234');
              expect(await h.fixture.artifactsOf(_owner), isEmpty);
            }));
  }

  test(
      'Apple cancel sends no deletion request, writes no receipt, removes nothing',
      () => _world((h) async {
            final apple = _FakeApple((_) => const AppleReauthCancelled());
            final session = await begin(h.flow(apple));
            expect(await _bounded(session.confirm()),
                isA<DeletionFlowCancelled>());
            expect(h.actions, ['challenge']);
            expect(h.values, isEmpty);
            expect(await h.fixture.artifactsOf(_owner), isNotEmpty);
            // The screen returns to idle; a later attempt is a fresh capture.
            expect(await _bounded(h.flow(apple).begin()), isNotNull);
          }));

  test(
      'Apple failure is a retryable failure, not a cancel; nothing is sent',
      () => _world((h) async {
            final apple = _FakeApple((_) => const AppleReauthFailed());
            final session = await begin(h.flow(apple));
            final result = await _bounded(session.confirm());
            expect(result, isA<DeletionFlowFailed>());
            expect((result as DeletionFlowFailed).retryable, isTrue);
            expect(h.actions, ['challenge']);
            expect(h.values, isEmpty);
            // Retry on the same capture: a fresh challenge, then success path.
            apple.next = (_) => const AppleReauthCancelled();
            expect(await _bounded(session.confirm()),
                isA<DeletionFlowCancelled>());
            expect(h.actions, ['challenge', 'challenge']);
          }));

  group('challenge errors never reach Apple and never touch local data', () {
    Future<void> check(
      _World h,
      http.Response reply,
      Matcher expected,
    ) async {
      h.answer = (_, __) async => reply;
      final apple = _granted();
      final session = await begin(h.flow(apple));
      expect(await _bounded(session.confirm()), expected);
      expect(apple.nonces, isEmpty);
      expect(h.actions, ['challenge']);
      expect(h.values, isEmpty);
      expect(await h.fixture.artifactsOf(_owner), isNotEmpty);
    }

    test(
        'admin_self_delete_blocked',
        () => _world((h) => check(
            h,
            _json(
                {'status': 'error', 'code': 'admin_self_delete_blocked'}, 403),
            isA<DeletionFlowAdminBlocked>())));
    test(
        'challenge_rate_limited',
        () => _world((h) => check(
            h,
            _json({'status': 'error', 'code': 'challenge_rate_limited'}, 429),
            isA<DeletionFlowRateLimited>())));
    test(
        'already_pending is pending, never success',
        () => _world((h) => check(
            h,
            _json({'status': 'error', 'code': 'already_pending'}, 409),
            isA<DeletionFlowPending>())));
    test(
        'server failure is a retryable failure',
        () => _world((h) =>
            check(h, _status('unavailable', 503), isA<DeletionFlowFailed>())));
  });

  for (final c in [
    ('accepted', _status('accepted', 202), isA<DeletionFlowPending>()),
    ('in progress', _status('in_progress'), isA<DeletionFlowPending>()),
    (
      'unknown',
      _json({'status': 'unknown'}, 404),
      isA<DeletionFlowUnconfirmed>()
    ),
    (
      'server error',
      _json({'status': 'error', 'code': 'server_error'}, 500),
      isA<DeletionFlowUnconfirmed>()
    ),
  ]) {
    test(
        '${c.$1} request outcome keeps all local data and is not success',
        () => _world((h) async {
              h.answer = (action, _) async =>
                  action == 'challenge' ? _challenge() : c.$2;
              final session = await begin(h.flow(_granted()));
              expect(await _bounded(session.confirm()), c.$3);
              expect(h.actions, ['challenge', 'request']);
              expect(await h.fixture.artifactsOf(_owner), isNotEmpty);
              expect(
                  h.session.captureDatabaseHostAdmission()?.isCurrent, isTrue);
              expect(h.sdk.auth.currentSession?.user.id, _owner);
            }));
  }

  test(
      'remote completion but local removal failure: cleanup pending, not success',
      () => _world((h) async {
            h.answer = (action, _) async =>
                action == 'challenge' ? _challenge() : _status('completed');
            h.fixture.barrier.failFinish = true;
            final session = await begin(h.flow(_granted()));
            final result = await _bounded(session.confirm());
            expect(result, isA<DeletionFlowLocalCleanupPending>());
            expect(result, isNot(isA<DeletionFlowCompleted>()));
          }));

  test(
      'restart recovery resumes the stored operation by status only: no new '
      'challenge, request or operation',
      () => _world((h) async {
            final first = await begin(h.flow(_granted()));
            expect(await _bounded(first.confirm()), isA<DeletionFlowPending>());
            expect(h.actions, ['challenge', 'request']);

            // "Restart": a brand new gateway/flow over the persisted receipt.
            final apple = _granted();
            final restarted = h.flow(apple);
            expect(await _bounded(restarted.begin()), isNull,
                reason: 'an existing operation is never replaced by a new one');
            final resumed = (await _bounded(restarted.resume()))!;
            h.answer = (_, __) async => _status('in_progress');
            expect(await _bounded(resumed.checkStatus()),
                isA<DeletionFlowPending>());
            expect(await h.fixture.artifactsOf(_owner), isNotEmpty);

            h.answer = (_, __) async => _status('completed');
            expect(await _bounded(resumed.checkStatus()),
                isA<DeletionFlowCompleted>());
            expect(h.actions, ['challenge', 'request', 'status', 'status']);
            expect(apple.nonces, isEmpty);
            expect(await h.fixture.artifactsOf(_owner), isEmpty);
          }));

  // ---------------------------------------------------------------------
  // Definitive rejects abandon the receipt; everything else stays unconfirmed.
  // ---------------------------------------------------------------------
  group('request refused by the server', () {
    const safe = <(String, int)>[
      ('unauthenticated', 401),
      ('invalid_request', 400),
      ('challenge_invalid', 400),
      ('challenge_expired', 400),
      ('apple_subject_mismatch', 403),
      ('admin_self_delete_blocked', 403),
    ];
    for (final c in safe) {
      test(
          '${c.$1} (pre-commit): receipt abandoned, a fresh flow succeeds',
          () => _world((h) async {
                h.answer = (action, _) async => action == 'challenge'
                    ? _challenge()
                    : _json({'status': 'error', 'code': c.$1}, c.$2);
                final session = await begin(h.flow(_granted()));
                final result = await _bounded(session.confirm());
                expect(
                    result,
                    c.$1 == 'admin_self_delete_blocked'
                        ? isA<DeletionFlowAdminBlocked>()
                        : isA<DeletionFlowRejected>());
                expect(h.actions, ['challenge', 'request']);
                expect(h.values, isEmpty,
                    reason: 'this operation\'s receipt was abandoned');
                expect(await h.fixture.artifactsOf(_owner), isNotEmpty);

                // begin() works again and a brand-new operation succeeds.
                h.answer = (action, _) async =>
                    action == 'challenge' ? _challenge() : _status('completed');
                final fresh = await begin(h.flow(_granted()));
                expect(await _bounded(fresh.confirm()),
                    isA<DeletionFlowCompleted>());
                expect(h.actions,
                    ['challenge', 'request', 'challenge', 'request']);
                expect(await h.fixture.artifactsOf(_owner), isEmpty);
              }));
    }

    final unsafe = <(String, Future<http.Response> Function())>[
      (
        'challenge_replayed',
        () async =>
            _json({'status': 'error', 'code': 'challenge_replayed'}, 409)
      ),
      (
        'idempotency_conflict',
        () async =>
            _json({'status': 'error', 'code': 'idempotency_conflict'}, 409)
      ),
      (
        'acceptance_unknown',
        () async => _json({
              'status': 'error',
              'code': 'acceptance_unknown',
              'recovery': 'lookup_receipt'
            }, 503)
      ),
      (
        'store_unavailable',
        () async => _json({'status': 'error', 'code': 'store_unavailable'}, 503)
      ),
      (
        'authorization_unavailable',
        () async =>
            _json({'status': 'error', 'code': 'authorization_unavailable'}, 503)
      ),
      ('bare 500', () async => http.Response('', 500)),
      ('malformed 200 body', () async => http.Response('not json', 200)),
      ('network error', () async => throw StateError('socket closed')),
    ];
    for (final c in unsafe) {
      test(
          '${c.$1} may follow an accepted request: unconfirmed, receipt kept',
          () => _world((h) async {
                h.answer = (action, _) async =>
                    action == 'challenge' ? _challenge() : c.$2();
                final session = await begin(h.flow(_granted()));
                final result = await _bounded(session.confirm());
                expect(result, isA<DeletionFlowUnconfirmed>());
                expect(
                    (result as DeletionFlowUnconfirmed).canCheckStatus, isTrue);
                expect(h.values, hasLength(1));
                expect(jsonDecode(h.values.values.single)['phase'],
                    'mayHaveBeenSent');
                expect(await _bounded(h.flow(_granted()).begin()), isNull,
                    reason: 'no second operation while one may be in flight');
                expect(await h.fixture.artifactsOf(_owner), isNotEmpty);
              }));
    }

    test(
        'challenge_replayed after a lost-reply acceptance recovers by status '
        'to completed, then removes the original replica',
        () => _world((h) async {
              h.answer = (action, _) async => action == 'challenge'
                  ? _challenge()
                  : _json(
                      {'status': 'error', 'code': 'challenge_replayed'}, 409);
              final session = await begin(h.flow(_granted()));
              expect(await _bounded(session.confirm()),
                  isA<DeletionFlowUnconfirmed>());
              h.answer = (_, __) async => _status('completed');
              expect(await _bounded(session.checkStatus()),
                  isA<DeletionFlowCompleted>());
              expect(h.actions, ['challenge', 'request', 'status']);
              expect(await h.fixture.artifactsOf(_owner), isEmpty);
            }));
  });

  // ---------------------------------------------------------------------
  // Local cleanup after remote completion: retained receipt, fresh evidence.
  // ---------------------------------------------------------------------
  Future<void> remoteCompletedWithoutLocalRemoval(_World h) async {
    // The process dies after the server finished but before local removal.
    h.answer = (_, __) async => _status('completed');
    h.flow(_granted());
    final gateway = h.gateways.last;
    final op = (await _bounded(gateway.prepare()))!;
    final out = await _bounded(gateway.request(op,
        challengeId: 'challenge-id-0123456789abcdef',
        challengeResponse: 'synthetic'));
    expect(out, isA<PreparedDeletionRemoteCompletion>());
    expect(await h.fixture.artifactsOf(_owner), isNotEmpty);
    final stored = jsonDecode(h.values.values.single) as Map;
    expect(stored['phase'], 'completed');
    expect(stored['receipt_secret'], isNotNull,
        reason: 'kept until the original local removal is confirmed');
  }

  test(
      'restart with local cleanup pending: the startup hook gets fresh status '
      'evidence, removes the ORIGINAL replica and retires the receipt',
      () => _world((h) async {
            await remoteCompletedWithoutLocalRemoval(h);
            final apple = _granted();
            final restarted = h.flow(apple);

            final result =
                await _bounded(recoverImmediateDeletionAtStart(restarted));

            expect(result, isA<DeletionFlowCompleted>());
            expect(h.actions, ['request', 'status'],
                reason: 'status only: no challenge, no new request');
            expect(
                h.requests.last.headers.containsKey('Authorization'), isFalse);
            expect(apple.nonces, isEmpty);
            expect(await h.fixture.artifactsOf(_owner), isEmpty);
            final stored = jsonDecode(h.values.values.single) as Map;
            expect(stored['phase'], 'completed');
            expect(stored['receipt_secret'], isNull,
                reason: 'retired only after removal was confirmed');
          }));

  test(
      'cleanup Retry: not completed yet -> still pending, receipt kept; then '
      'completed -> removal confirmed',
      () => _world((h) async {
            await remoteCompletedWithoutLocalRemoval(h);
            final session =
                (await _bounded(h.flow(_granted()).resumeLocalCleanup()))!;
            h.answer = (_, __) async => _status('in_progress');
            expect(await _bounded(session.retryLocalCleanup()),
                isA<DeletionFlowLocalCleanupPending>());
            expect(await h.fixture.artifactsOf(_owner), isNotEmpty);
            expect(jsonDecode(h.values.values.single)['receipt_secret'],
                isNotNull);
            h.answer = (_, __) async => _status('completed');
            expect(await _bounded(session.retryLocalCleanup()),
                isA<DeletionFlowCompleted>());
            expect(await h.fixture.artifactsOf(_owner), isEmpty);
            expect(h.actions, ['request', 'status', 'status']);
          }));

  test(
      'startup hook is idle once removal is confirmed: no request at all',
      () => _world((h) async {
            await remoteCompletedWithoutLocalRemoval(h);
            expect(
                await _bounded(
                    recoverImmediateDeletionAtStart(h.flow(_granted()))),
                isA<DeletionFlowCompleted>());
            final before = h.requests.length;
            expect(
                await _bounded(
                    recoverImmediateDeletionAtStart(h.flow(_granted()))),
                isNull);
            expect(h.requests, hasLength(before));
          }));

  test(
      'startup hook for a different owner has no effect and sends nothing',
      () => _world((h) async {
            await remoteCompletedWithoutLocalRemoval(h);
            final before = h.requests.length;
            final receiptA = Map<String, String>.from(h.values);
            await h.switchTo(_other);
            expect(await h.fixture.artifactsOf(_other), isNotEmpty);

            expect(
                await _bounded(
                    recoverImmediateDeletionAtStart(h.flow(_granted()))),
                isNull);

            expect(h.requests, hasLength(before));
            expect(h.values, receiptA, reason: "A's receipt untouched");
            expect(await h.fixture.artifactsOf(_other), isNotEmpty);
          }));

  test(
      'account switched between remote completion and the retry: the new '
      "account's replica stays untouched and no status is sent",
      () => _world((h) async {
            await remoteCompletedWithoutLocalRemoval(h);
            // Captured while A is current ...
            final session =
                (await _bounded(h.flow(_granted()).resumeLocalCleanup()))!;
            final before = h.requests.length;
            // ... but B is current by the time the person presses Retry.
            await h.switchTo(_other);
            final result = await _bounded(session.retryLocalCleanup());
            expect(result, isA<DeletionFlowLocalCleanupPending>());
            expect(h.requests, hasLength(before));
            expect(await h.fixture.artifactsOf(_other), isNotEmpty);
            expect(h.session.captureDatabaseHostAdmission()?.isCurrent, isTrue);
            expect(
                jsonDecode(h.values.values.single)['receipt_secret'], isNotNull,
                reason: "A's receipt is kept; B can never consume it");
          }));

  test(
      'startup hook is denied by the egress gate: nothing happens',
      () => _world((h) async {
            await remoteCompletedWithoutLocalRemoval(h);
            final before = h.requests.length;
            final flow = h.flow(_granted());
            TestEgress().install(); // a different gate: the binding is gone
            expect(
                await _bounded(recoverImmediateDeletionAtStart(flow)), isNull);
            expect(h.requests, hasLength(before));
            expect(await h.fixture.artifactsOf(_owner), isNotEmpty);
          }));

  test(
      'destructive local failure keeps the completed receipt; retry without '
      "the session's admission sends nothing (the session's own barrier "
      'resumes at launch)',
      () => _world((h) async {
            h.answer = (action, _) async =>
                action == 'challenge' ? _challenge() : _status('completed');
            h.fixture.barrier.failFinish = true;
            final session = await begin(h.flow(_granted()));
            expect(await _bounded(session.confirm()),
                isA<DeletionFlowLocalCleanupPending>());
            expect(jsonDecode(h.values.values.single)['receipt_secret'],
                isNotNull);
            final before = h.requests.length;
            expect(await _bounded(session.retryLocalCleanup()),
                isA<DeletionFlowLocalCleanupPending>());
            expect(h.requests, hasLength(before));
          }));

  test(
      'resume with no stored operation yields nothing',
      () => _world((h) async {
            expect(await _bounded(h.flow(_granted()).resume()), isNull);
            expect(h.requests, isEmpty);
          }));

  test(
      'account switched while the Apple sheet is open: no request is sent and '
      'neither account loses local data',
      () => _world((h) async {
            final apple = _granted()
              ..during = () async {
                await h.switchTo(_other);
              };
            final session = await begin(h.flow(apple));
            final result = await _bounded(session.confirm());
            expect(result, isA<DeletionFlowUnconfirmed>());
            expect((result as DeletionFlowUnconfirmed).canCheckStatus, isFalse);
            expect(h.actions, ['challenge'], reason: 'no stale request');
            expect(await h.fixture.artifactsOf(_owner), isNotEmpty);
            expect(h.session.captureDatabaseHostAdmission()?.isCurrent, isTrue);
          }));

  test(
      'stale operation after remote completion cannot remove the new '
      "account's data",
      () => _world((h) async {
            h.answer = (action, _) async =>
                action == 'challenge' ? _challenge() : _status('accepted', 202);
            final session = await begin(h.flow(_granted()));
            expect(
                await _bounded(session.confirm()), isA<DeletionFlowPending>());
            await h.switchTo(_other);
            h.answer = (_, __) async => _status('completed');
            final result = await _bounded(session.checkStatus());
            expect(result, isNot(isA<DeletionFlowCompleted>()));
            expect(await h.fixture.artifactsOf(_other), isNotEmpty,
                reason: "the new account's replica is untouched");
            expect(h.session.captureDatabaseHostAdmission()?.isCurrent, isTrue);
          }));
}
