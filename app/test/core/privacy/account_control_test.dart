import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../harness/egress_test_support.dart';

/// Astra H2.1 / H2.6-B: the operation-scoped OFF allowlist, driven through the
/// REAL supabase / gotrue / postgrest clients (pinned versions) and a spy inner
/// client, so the endpoints asserted here are the ones the packages emit.
const _url = 'https://example.supabase.co';

class _MemStorage extends GotrueAsyncStorage {
  final _m = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => _m[key];
  @override
  Future<void> removeItem({required String key}) async => _m.remove(key);
  @override
  Future<void> setItem({required String key, required String value}) async =>
      _m[key] = value;
}

String _jwt(int exp) {
  String b(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${b({'alg': 'HS256'})}.${b({'sub': 'uid-a', 'exp': exp})}.sig';
}

Map<String, dynamic> _sessionJson({required bool expired}) {
  final exp = DateTime.now()
          .add(Duration(hours: expired ? -2 : 1))
          .millisecondsSinceEpoch ~/
      1000;
  return {
    'access_token': _jwt(exp),
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': exp,
    'refresh_token': 'refresh',
    'user': {
      'id': 'uid-a',
      'aud': 'authenticated',
      'created_at': '2026-01-01T00:00:00Z',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
      'email': 'a@b.c',
    },
  };
}

class _Spy {
  final seen = <http.BaseRequest>[];
  bool follow = true;
  late final http.Client client = MockClient.streaming((req, body) async {
    seen.add(req);
    follow = req.followRedirects;
    final path = req.url.path;
    Object json = <String, dynamic>{};
    if (path == '/auth/v1/token' || path == '/auth/v1/verify') {
      json = _sessionJson(expired: false);
    } else if (path.startsWith('/rest/v1/rpc/')) {
      json = '2026-02-01T00:00:00Z';
    } else if (path.startsWith('/rest/v1/')) {
      json = <Object>[];
    }
    return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(json))), 200,
        headers: const {'content-type': 'application/json'}, request: req);
  });
  List<String> get calls => [
        for (final r in seen)
          '${r.method} ${r.url.path}${r.url.query.isEmpty ? '' : '?${r.url.query}'}'
      ];
}

void main() {
  _immediateDeletionTests();
  late TestEgress egress; // OFF: no record at all
  late _Spy spy;
  late SupabaseClient client;

  SupabaseClient build() => SupabaseClient(_url, 'anon',
      httpClient: GatedHttpClient(spy.client),
      authOptions: AuthClientOptions(
          autoRefreshToken: false, pkceAsyncStorage: _MemStorage()));

  void setUpGate(
      {Duration ttl = kAccountControlTtl, Duration Function()? mono}) {
    egress = TestEgress(accountControlTtl: ttl, monotonic: mono).install();
    spy = _Spy();
    client = build();
  }

  setUp(() => setUpGate());

  Future<Object?> expectDenied(Future<Object?> Function() f) async {
    try {
      await f();
    } catch (e) {
      return e;
    }
    return null;
  }

  group('allowed inside their own op, nothing else', () {
    test('identity linking while Cloud is off requires its current owner', () async {
      var current = true;
      await egress.gate.runAccountControl(AccountControlOp.linkIdentity, () async {
        await client.auth.signInWithOtp(email: 'a@b.c', shouldCreateUser: false);
        current = false;
        expect(await expectDenied(() => client.auth.signInWithOtp(email: 'a@b.c')),
            isNotNull);
      }, linking: (owner: 'uid-a', current: () => current));
      expect(spy.calls, ['POST /auth/v1/otp']);
    });

    test('signIn: Google/Apple id_token, email otp and verify', () async {
      await gateRun(
          AccountControlOp.signIn,
          () => client.auth
              .signInWithIdToken(provider: OAuthProvider.google, idToken: 'x'));
      await gateRun(AccountControlOp.signIn,
          () => client.auth.signInWithOtp(email: 'a@b.c'));
      await gateRun(
          AccountControlOp.signIn,
          () => client.auth
              .verifyOTP(email: 'a@b.c', token: '123456', type: OtpType.email));
      expect(spy.calls, [
        'POST /auth/v1/token?grant_type=id_token',
        'POST /auth/v1/otp',
        'POST /auth/v1/verify',
      ]);
    });

    test('reauthenticate keeps the standard sign-in endpoints', () async {
      await gateRun(
          AccountControlOp.reauthenticate,
          () => client.auth.signInWithIdToken(
              provider: OAuthProvider.apple, idToken: 'x', nonce: 'n'));
      expect(spy.calls, ['POST /auth/v1/token?grant_type=id_token']);
    });

    test('only the explicit sign-in grant can reach Google enrollment', () async {
      Future<FunctionResponse> enroll() => client.functions.invoke(
        'google-enrollment',
        body: {'id_token': 'synthetic', 'nonce': null},
      );
      await expectDenied(enroll);
      await gateRun(AccountControlOp.signIn, enroll);
      expect(spy.calls, ['POST /functions/v1/google-enrollment']);
      await gateRun(AccountControlOp.reauthenticate, () async {
        await expectDenied(enroll);
      });
      expect(spy.calls, ['POST /functions/v1/google-enrollment']);
    });

    test('onboarding checks only the exact signed-in UID and one field while OFF',
        () async {
      await client.auth.setInitialSession(jsonEncode(_sessionJson(expired: false)));
      var current = true;
      final token = client.auth.currentSession!.accessToken;
      await egress.gate.runAccountControl(
        AccountControlOp.onboardingStatus,
        () async {
          final allowed = client.from('profiles')
              .select('onboarding_completed_at').eq('id', 'uid-a').maybeSingle();
          expect(await allowed, isNull);
          expect(spy.follow, isFalse);
          expect(await expectDenied(() => client.from('profiles')
              .select().eq('id', 'uid-a')), isA<EgressDeniedException>());
          expect(await expectDenied(() => client.from('profiles')
              .select('onboarding_completed_at').eq('id', 'uid-b')),
              isA<EgressDeniedException>());
          expect(await expectDenied(() => client.rpc('mark_onboarding_completed')),
              isA<EgressDeniedException>());
          final exactUrl = Uri.parse(
              '$_url/rest/v1/profiles?select=onboarding_completed_at&id=eq.uid-a');
          final raw = GatedHttpClient(spy.client);
          expect(await expectDenied(() => raw.get(exactUrl,
              headers: {'Authorization': 'Bearer wrong-session'})),
              isA<EgressDeniedException>());
          expect(await expectDenied(() => raw.send(http.Request('GET', exactUrl)
              ..headers['Authorization'] = 'Bearer $token'
              ..body = 'financial-payload')),
              isA<EgressDeniedException>());
          current = false;
          expect(await expectDenied(() => client.from('profiles')
              .select('onboarding_completed_at').eq('id', 'uid-a')),
              isA<EgressDeniedException>());
        },
        onboarding: (
          authority: AdmissionAuthority('uid-a', () => current, canCreate: false),
          accessToken: token,
        ),
      );
      expect(spy.seen, hasLength(1));
      expect(await egress.gate.permits(), isFalse);
    });

    test('after sign-in, the setup lookup passes a leftover DISABLING; the '
        'rest of the account stays closed', () async {
      await client.auth.setInitialSession(jsonEncode(_sessionJson(expired: false)));
      await egress.gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      final token = client.auth.currentSession!.accessToken;
      await egress.gate.runAccountControl(
        AccountControlOp.onboardingStatus,
        () async {
          expect(await client.from('profiles')
              .select('onboarding_completed_at').eq('id', 'uid-a').maybeSingle(),
              isNull);
          expect(await expectDenied(() => client.from('profiles')
              .select().eq('id', 'uid-a')), isA<EgressDeniedException>());
        },
        onboarding: (
          authority: AdmissionAuthority('uid-a', () => true, canCreate: false),
          accessToken: token,
        ),
      );
      expect(spy.calls,
          ['GET /rest/v1/profiles?select=onboarding_completed_at&id=eq.uid-a']);
      await expectLater(client.from('transactions').select(),
          throwsA(isA<EgressDeniedException>()));
      expect(spy.seen, hasLength(1));
    });

    // Audit L1 (2026-11-14): a freeze, an uncertain view or a pending enable
    // denied the setup lookup, so the account-check screen retried forever.
    for (final state in ['frozen', 'state_uncertain', 'pending_enable']) {
      test('after sign-in, the setup lookup passes $state; the rest of the '
          'account stays closed', () async {
        await client.auth
            .setInitialSession(jsonEncode(_sessionJson(expired: false)));
        if (state == 'frozen') ConsentAuthority.egressFrozen = true;
        addTearDown(() => ConsentAuthority.egressFrozen = false);
        if (state == 'state_uncertain') egress.file.value = '{broken';
        if (state == 'pending_enable') egress.pendingSecure.value = '{broken';
        await expectLater(egress.gate.admit(),
            throwsA(isA<EgressDeniedException>()
                .having((e) => e.reason, 'reason', state)));
        final token = client.auth.currentSession!.accessToken;
        await egress.gate.runAccountControl(
          AccountControlOp.onboardingStatus,
          () async {
            expect(await client.from('profiles')
                .select('onboarding_completed_at').eq('id', 'uid-a')
                .maybeSingle(), isNull);
            expect(await expectDenied(() => client.from('profiles')
                .select().eq('id', 'uid-a')), isA<EgressDeniedException>());
          },
          onboarding: (
            authority: AdmissionAuthority('uid-a', () => true, canCreate: false),
            accessToken: token,
          ),
        );
        expect(spy.calls,
            ['GET /rest/v1/profiles?select=onboarding_completed_at&id=eq.uid-a']);
        await expectLater(egress.gate.admit(),
            throwsA(isA<EgressDeniedException>()
                .having((e) => e.reason, 'reason', state)));
      });
    }

    test('deleteAccount: the RPC', () async {
      await client.auth.setInitialSession(jsonEncode(_sessionJson(expired: false)));
      final r = await gateRun(AccountControlOp.deleteAccount,
          () => client.rpc('request_account_deletion'));
      expect(r, '2026-02-01T00:00:00Z');
      expect(spy.calls, ['POST /rest/v1/rpc/request_account_deletion']);
    });

    // P5 (2026-11-14): no Cloud consent state refuses account deletion; the
    // cancel stays gated and the rest of the account stays closed.
    for (final state in ['frozen', 'disabling', 'state_uncertain', 'pending_enable']) {
      test('deleteAccount: the RPC passes $state; cancelDelete and ordinary '
          'egress stay denied', () async {
        await client.auth
            .setInitialSession(jsonEncode(_sessionJson(expired: false)));
        if (state == 'frozen') ConsentAuthority.egressFrozen = true;
        addTearDown(() => ConsentAuthority.egressFrozen = false);
        if (state == 'disabling') {
          await egress.gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
        }
        if (state == 'state_uncertain') egress.file.value = '{broken';
        if (state == 'pending_enable') egress.pendingSecure.value = '{broken';
        await expectLater(egress.gate.admit(),
            throwsA(isA<EgressDeniedException>()
                .having((e) => e.reason, 'reason', state)));
        final r = await gateRun(AccountControlOp.deleteAccount,
            () => client.rpc('request_account_deletion'));
        expect(r, '2026-02-01T00:00:00Z');
        expect(spy.calls, ['POST /rest/v1/rpc/request_account_deletion']);
        // Only the deletion RPC: the grant's scope still applies.
        expect(await expectDenied(() => gateRun(AccountControlOp.deleteAccount,
            () => client.rpc('cancel_account_deletion'))), isNotNull);
        if (state != 'pending_enable') {
          // A pending enable never gated account control (N-E); the others do.
          expect(await expectDenied(() => gateRun(AccountControlOp.cancelDelete,
              () => client.rpc('cancel_account_deletion'))), isNotNull);
        }
        await expectLater(egress.gate.admit(),
            throwsA(isA<EgressDeniedException>()
                .having((e) => e.reason, 'reason', state)));
        expect(spy.seen, hasLength(1));
      });
    }

    test('cancelDelete: the RPC', () async {
      await client.auth.setInitialSession(jsonEncode(_sessionJson(expired: false)));
      await gateRun(AccountControlOp.cancelDelete,
          () => client.rpc('cancel_account_deletion'));
      expect(spy.calls, ['POST /rest/v1/rpc/cancel_account_deletion']);
    });

    // ASR I3: the expired-token refresh is the AuthCoordinator's own op (§3.5);
    // the SDK's refresh is denied before admission even inside the grant.
    for (final (op, rpc) in [
      (AccountControlOp.deleteAccount, 'request_account_deletion'),
      (AccountControlOp.cancelDelete, 'cancel_account_deletion'),
    ]) {
      test('${op.name}: the SDK refresh of an expired token is denied', () async {
        await client.auth
            .setInitialSession(jsonEncode(_sessionJson(expired: true)));
        expect(await expectDenied(() => gateRun(op, () => client.rpc(rpc))),
            isNotNull);
        expect(spy.seen, isEmpty);
      });
    }

    test('no grant, no OFF traffic: the same calls are denied unwrapped',
        () async {
      expect(
          await expectDenied(() => client.auth
              .signInWithIdToken(provider: OAuthProvider.google, idToken: 'x')),
          isNotNull);
      expect(await expectDenied(() => client.rpc('cancel_account_deletion')),
          isNotNull);
      expect(spy.seen, isEmpty);
    });
  });

  group('everything else is denied during an allowance', () {
    const ops = AccountControlOp.values;
    for (final op in ops) {
      test(
          '$op: PostgREST, other RPC, functions, storage, /user, refresh '
          '(unless delete/cancel) never reach the inner client', () async {
        await client.auth
            .setInitialSession(jsonEncode(_sessionJson(expired: false)));
        final attempts = <Future<Object?> Function()>[
          () => client.from('profiles').select(),
          () => client.rpc('get_referral_summary'),
          () => client.rpc('record_metric', params: {'p_metric_key': 'k'}),
          () => client.functions.invoke('catalog-versions'),
          () => client.storage.from('b').list(),
          () => client.auth.getUser(),
          () => client.auth.signOut(),
          if (op == AccountControlOp.signIn) () => client.auth.refreshSession(),
        ];
        await gateRun(op, () async {
          for (final a in attempts) {
            expect(await expectDenied(a), isNotNull);
          }
        });
        expect(spy.seen, isEmpty,
            reason: 'zero requests reached the inner client');
      });
    }

    test('a delete grant does not authorize the cancel RPC and vice versa',
        () async {
      await client.auth
          .setInitialSession(jsonEncode(_sessionJson(expired: false)));
      await gateRun(AccountControlOp.deleteAccount, () async {
        expect(await expectDenied(() => client.rpc('cancel_account_deletion')),
            isNotNull);
      });
      await gateRun(AccountControlOp.cancelDelete, () async {
        expect(await expectDenied(() => client.rpc('request_account_deletion')),
            isNotNull);
      });
      expect(spy.seen, isEmpty);
    });

    test('another host / scheme / user-info is denied', () async {
      await gateRun(AccountControlOp.signIn, () async {
        for (final u in [
          'https://evil.example.com/auth/v1/otp',
          'http://example.supabase.co/auth/v1/otp',
          'https://u@example.supabase.co/auth/v1/otp',
          'https://example.supabase.co/auth/v1/otp?redirect_to=x',
        ]) {
          expect(
              await expectDenied(() => egress.gate
                  .admit(request: AdmissionRequest('POST', Uri.parse(u)))),
              isA<EgressDeniedException>(),
              reason: u);
        }
        expect(
            await expectDenied(() => egress.gate.admit(
                request:
                    AdmissionRequest('GET', Uri.parse('$_url/auth/v1/otp')))),
            isA<EgressDeniedException>());
      });
    });
  });

  group('the allowance disappears', () {
    Future<String?> admitIn(Zone z) => z.run(() async {
          try {
            final t = await egress.gate.admit(
                request:
                    AdmissionRequest('POST', Uri.parse('$_url/auth/v1/otp')));
            egress.gate.release(t);
            return null;
          } on EgressDeniedException catch (e) {
            return e.reason;
          }
        });

    test('on success: a zone timer / retry that fires afterwards is denied',
        () async {
      final late = Completer<String?>();
      await gateRun(AccountControlOp.signIn, () async {
        // Active now:
        expect(await admitIn(Zone.current), isNull);
        Timer(const Duration(milliseconds: 60), () async {
          late.complete(await admitIn(Zone.current));
        });
      });
      expect(await late.future, 'grant_inactive');
    });

    test('on failure', () async {
      late Zone z;
      await expectLater(
          gateRun(AccountControlOp.signIn, () async {
            z = Zone.current;
            throw StateError('boom');
          }),
          throwsStateError);
      expect(await admitIn(z), 'grant_inactive');
    });

    test(
        'on timeout (monotonic TTL): body cancelled, grant ended, in-flight '
        'request aborted', () async {
      setUpGate(ttl: const Duration(milliseconds: 80));
      late Zone z;
      await expectLater(
          gateRun(AccountControlOp.signIn, () async {
            z = Zone.current;
            await Completer<void>().future; // never completes
          }),
          throwsA(isA<TimeoutException>()));
      expect(await admitIn(z), 'grant_inactive');
    });

    test('expiry is measured on the injected monotonic clock', () async {
      var now = Duration.zero;
      setUpGate(mono: () => now);
      await gateRun(AccountControlOp.signIn, () async {
        expect(await admitIn(Zone.current), isNull);
        now += kAccountControlTtl; // exactly the TTL: expired
        expect(await admitIn(Zone.current), 'grant_inactive');
      });
    });

    test('an unrelated concurrent call never inherits the grant', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final op = gateRun(AccountControlOp.signIn, () async {
        started.complete();
        await release.future;
      });
      await started.future;
      expect(
          await expectDenied(() => egress.gate.admit(
              request:
                  AdmissionRequest('POST', Uri.parse('$_url/auth/v1/otp')))),
          isA<EgressDeniedException>());
      release.complete();
      await op;
    });
  });

  group('no widening, no redirects', () {
    test('the store, the record and consent are untouched by every op',
        () async {
      final before = (egress.secure.value, egress.file.value);
      for (final op in AccountControlOp.values) {
        await client.auth.setInitialSession(jsonEncode(_sessionJson(expired: false)));
        if (op == AccountControlOp.linkIdentity) {
          await egress.gate.runAccountControl(op,
            () => client.auth.signInWithOtp(email: 'a@b.c'),
            linking: (owner: 'uid-a', current: () => true),
          );
          continue;
        }
        await gateRun(op, () async {
          if (op == AccountControlOp.deleteAccount) {
            await client.rpc('request_account_deletion');
          } else if (op == AccountControlOp.cancelDelete) {
            await client.rpc('cancel_account_deletion');
          } else if (op != AccountControlOp.onboardingStatus) {
            await client.auth.signInWithOtp(email: 'a@b.c');
          }
        });
      }
      expect((egress.secure.value, egress.file.value), before);
      expect(egress.secure.writes + egress.file.writes, 0);
      expect(await egress.gate.permits(), isFalse, reason: 'Cloud stays OFF');
      expect(egress.gate.permitNotifier.value, isFalse);
      expect(egress.gate.permitsNetworkSync, isFalse);
      expect((await egress.gate.view()).record, isNull);
      expect(ConsentAuthority.egressFrozen, isFalse);
    });

    test(
        'a granted request is sent with followRedirects=false; ordinary '
        'traffic is untouched', () async {
      await gateRun(AccountControlOp.signIn,
          () => client.auth.signInWithOtp(email: 'a@b.c'));
      expect(spy.follow, isFalse);
      await egress.gate.enable(owner: 'uid-a', reservedVersion: 1);
      await client.from('profiles').select();
      expect(spy.follow, isTrue);
    });

    test('a 3xx answer is returned as-is (never followed to another host)',
        () async {
      final inner = MockClient.streaming((req, _) async {
        spy.seen.add(req);
        return http.StreamedResponse(const Stream.empty(), 302,
            headers: const {'location': 'https://evil.example.com/'},
            request: req,
            isRedirect: true);
      });
      final c = SupabaseClient(_url, 'anon',
          httpClient: GatedHttpClient(inner),
          authOptions: AuthClientOptions(
              autoRefreshToken: false, pkceAsyncStorage: _MemStorage()));
      await expectLater(
          gateRun(AccountControlOp.signIn,
              () => c.auth.signInWithOtp(email: 'a@b.c')),
          throwsA(isA<AuthException>()));
      expect(spy.seen.length, 1);
      expect(spy.seen.single.followRedirects, isFalse);
    });
  });

  group('state still wins over a grant', () {
    test('unresolved, frozen and DISABLING deny a grant; uncertain too',
        () async {
      Future<String?> reason() => gateRun(AccountControlOp.signIn, () async {
            try {
              final t = await egress.gate.admit(
                  request:
                      AdmissionRequest('POST', Uri.parse('$_url/auth/v1/otp')));
              egress.gate.release(t);
              return null;
            } on EgressDeniedException catch (e) {
              return e.reason;
            }
          });
      expect(await reason(), isNull, reason: 'OFF/unset + grant = allowed');

      final unresolved = TestEgress(resolved: false).install();
      expect(
          await unresolved.gate.runAccountControl(AccountControlOp.signIn,
              () async {
            try {
              await unresolved.gate.admit(
                  request:
                      AdmissionRequest('POST', Uri.parse('$_url/auth/v1/otp')));
              return null;
            } on EgressDeniedException catch (e) {
              return e.reason;
            }
          }),
          'unresolved');

      egress = TestEgress().install();
      ConsentAuthority.egressFrozen = true;
      expect(await reason(), 'frozen');
      ConsentAuthority.egressFrozen = false;
      await egress.gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      expect(await reason(), 'disabling');
      egress = TestEgress().install();
      egress.file.value = '{broken';
      expect(await reason(), 'state_uncertain');
    });

    // Device report (TestFlight, 2026-11-14): "Couldn't sign in
    // (E: EgressDenied:disabling)". A disable left DISABLING behind; it is
    // completed only by the signed-in reconciliation (the account database must
    // be open), so a signed-out device could never sign in again.
    test('signed out: a leftover DISABLING never blocks sign-in itself',
        () async {
      Future<String?> reason(AccountControlOp op, String path) =>
          gateRun(op, () async {
            try {
              final t = await egress.gate.admit(
                  request: AdmissionRequest('POST', Uri.parse('$_url$path')));
              egress.gate.release(t);
              return null;
            } on EgressDeniedException catch (e) {
              return e.reason;
            }
          });
      await egress.gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      egress.gate.configureSessionUsable(() => false);
      addTearDown(() => egress.gate.configureSessionUsable(() => true));
      expect(await reason(AccountControlOp.signIn, '/auth/v1/otp'), isNull);
      // Only the sign-in endpoints: anything else in the grant stays denied.
      expect(await reason(AccountControlOp.signIn, '/rest/v1/profiles'),
          isNotNull);
      // Ordinary traffic and other control operations stay denied.
      await expectLater(egress.gate.admit(),
          throwsA(isA<EgressDeniedException>()
              .having((e) => e.reason, 'reason', 'disabling')));
      expect(await reason(AccountControlOp.cancelDelete, '/auth/v1/otp'),
          'disabling');
      // A usable session is not "signed out": DISABLING still wins.
      egress.gate.configureSessionUsable(() => true);
      expect(await reason(AccountControlOp.signIn, '/auth/v1/otp'),
          'disabling');
    });
  });

  group('sign-out while OFF is local and sends nothing', () {
    test(
        'the session is cleared, the persisted-session event fires, the '
        'inner client is never reached', () async {
      await client.auth
          .setInitialSession(jsonEncode(_sessionJson(expired: false)));
      final events = <AuthChangeEvent>[];
      final sub =
          client.auth.onAuthStateChange.listen((d) => events.add(d.event));
      Object? thrown;
      try {
        await client.auth.signOut();
      } catch (e) {
        thrown = e; // the denied server logout; callers already swallow it
      }
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(client.auth.currentSession, isNull);
      expect(client.auth.currentUser, isNull);
      expect(events, contains(AuthChangeEvent.signedOut));
      expect(thrown, isA<AuthRetryableFetchException>());
      expect(spy.seen, isEmpty);
    });
  });

  group('url_launcher', () {
    test(
        'denied unless permitted; an allowlisted host inside an active grant '
        'is the only exception', () async {
      final web = Uri.parse('https://example.com/privacy');
      final own = Uri.parse('$_url/anything');
      expect(await egress.gate.mayLaunchExternal(web), isFalse);
      expect(await egress.gate.mayLaunchExternal(own), isFalse);
      await gateRun(AccountControlOp.signIn, () async {
        expect(await egress.gate.mayLaunchExternal(web), isFalse);
        expect(await egress.gate.mayLaunchExternal(own), isTrue);
      });
      expect(await egress.gate.mayLaunchExternal(own), isFalse);
      await egress.gate.enable(owner: 'uid-a', reservedVersion: 1);
      expect(await egress.gate.mayLaunchExternal(web), isTrue);
    });
  });
}

Future<T> gateRun<T>(AccountControlOp op, Future<T> Function() body) =>
    CloudEgressGate.instance.runAccountControl(op, body);

class _DeferredAdmissionSlot implements DurableSlot {
  final arrived = Completer<void>();
  final release = Completer<void>();
  @override
  Future<SlotRead> read() async {
    if (!arrived.isCompleted) arrived.complete();
    await release.future;
    return const SlotRead(SlotStatus.absent);
  }
  @override
  Future<void> write(String value) async {}
  @override
  Future<void> delete() async {}
}

class _SynchronousThrowClient extends http.BaseClient {
  int calls = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls++;
    throw StateError('synchronous transport failure');
  }
  @override
  void close() {}
}

class _ControlledTimer implements Timer {
  _ControlledTimer(this.callback);
  final void Function() callback;
  bool _active = true;
  @override
  bool get isActive => _active;
  @override
  int get tick => _active ? 0 : 1;
  @override
  void cancel() => _active = false;
  void fire() { if (_active) { _active = false; callback(); } }
}

void _immediateDeletionTests() {
  group('E6 exact immediate-deletion exchange grants', () {
    const secret = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    final endpoint = Uri.parse('$_url/functions/v1/delete-account-immediate');
    final statusBody = jsonEncode({'action': 'status', 'receipt_secret': secret});
    late TestEgress egress;
    late List<http.Request> sent;
    late GatedHttpClient transport;
    setUp(() {
      egress = TestEgress().install();
      sent = [];
      transport = GatedHttpClient(MockClient((r) async { sent.add(r); return http.Response('{}', 200); }));
    });
    Future<T> grant<T>(Future<T> Function() exchange, {
      String? expectedBody, Uri? url, ImmediateDeletionAction action = ImmediateDeletionAction.status,
      String? token, int? epoch, bool Function()? current,
    }) => egress.gate.runImmediateDeletion(action: action, owner: 'uid-a', activeOwner: 'uid-a',
        epoch: epoch ?? egress.gate.epoch, isCurrent: current ?? () => true,
        functionUrl: url ?? endpoint, serializedBody: expectedBody ?? statusBody,
        bearerToken: token, exchange: exchange);
    Future<http.Response> send({String? body, Uri? url, String method = 'POST', Map<String, String>? headers}) async {
      final request = http.Request(method, url ?? endpoint)
        ..headers.addAll(headers ?? {'content-type': 'application/json'})
        ..body = body ?? statusBody;
      return http.Response.fromStream(await transport.send(request));
    }

    test('Cloud OFF exact status passes once; no consent/store widening or redirects', () async {
      await grant(() => send());
      expect(sent.length, 1);
      expect(sent.single.followRedirects, isFalse);
      expect(egress.secure.writes + egress.file.writes, 0);
      expect(await egress.gate.permits(), isFalse);
      expect(egress.gate.permitsNetworkSync, isFalse);
    });

    for (final changed in ['action', 'receipt', 'body', 'whitespace', 'path', 'query', 'host', 'method', 'refresh', 'authorization', 'content-type']) {
      test('$changed cannot borrow a status grant and is denied before transport', () async {
        var body = statusBody;
        var url = endpoint;
        var method = 'POST';
        var headers = <String, String>{'content-type': 'application/json'};
        switch (changed) {
          case 'action': body = jsonEncode({'action': 'request', 'receipt_secret': secret});
          case 'receipt': body = jsonEncode({'action': 'status', 'receipt_secret': 'B' * 43});
          case 'body': body = jsonEncode({'action': 'status', 'receipt_secret': secret, 'extra': true});
          case 'whitespace': body = '$statusBody ';
          case 'path': url = endpoint.replace(path: '/functions/v1/other');
          case 'query': url = endpoint.replace(query: 'x=1');
          case 'host': url = endpoint.replace(host: 'other.invalid');
          case 'method': method = 'GET';
          case 'refresh': url = Uri.parse('$_url/auth/v1/token?grant_type=refresh_token');
          case 'authorization': headers = {...headers, 'authorization': 'Bearer forbidden'};
          case 'content-type': headers = {'content-type': 'text/plain'};
        }
        await expectLater(grant(() => send(body: body, url: url, method: method, headers: headers)),
            throwsA(isA<EgressDeniedException>()));
        expect(sent, isEmpty);
      });
    }

    test('submission binds coherent bearer and cannot be replaced with status or another token', () async {
      final body = jsonEncode({'challenge_id': 'challenge', 'challenge_response': 'proof', 'receipt_secret': secret});
      await grant(() => send(body: body, headers: {'content-type': 'application/json', 'authorization': 'Bearer captured'}),
          action: ImmediateDeletionAction.request, expectedBody: body, token: 'captured');
      expect(sent.length, 1);
      await expectLater(grant(() => send(body: body, headers: {'content-type': 'application/json', 'authorization': 'Bearer replaced'}),
          action: ImmediateDeletionAction.request, expectedBody: body, token: 'captured'), throwsA(isA<EgressDeniedException>()));
      expect(sent.length, 1);
    });

    group('challenge issuance grant', () {
      final challengeBody = jsonEncode({'action': 'challenge'});
      final headers = {'content-type': 'application/json', 'authorization': 'Bearer captured'};
      test('exact {action:challenge} with the captured bearer passes once', () async {
        await grant(() => send(body: challengeBody, headers: headers),
            action: ImmediateDeletionAction.challenge, expectedBody: challengeBody, token: 'captured');
        expect(sent.length, 1);
        expect(sent.single.followRedirects, isFalse);
      });
      for (final bad in ['extra-key', 'receipt', 'wrong-action', 'no-token', 'replaced-token']) {
        test('$bad is denied before transport', () async {
          var body = challengeBody;
          String? token = 'captured';
          var sendHeaders = headers;
          switch (bad) {
            case 'extra-key': body = jsonEncode({'action': 'challenge', 'x': 1});
            case 'receipt': body = jsonEncode({'action': 'challenge', 'receipt_secret': secret});
            case 'wrong-action': body = jsonEncode({'action': 'status'});
            case 'no-token': token = null;
            case 'replaced-token': sendHeaders = {...headers, 'authorization': 'Bearer other'};
          }
          await expectLater(
              grant(() => send(body: body, headers: sendHeaders),
                  action: ImmediateDeletionAction.challenge, expectedBody: body, token: token),
              throwsA(isA<EgressDeniedException>()));
          expect(sent, isEmpty);
        });
      }
      test('a challenge grant cannot be used to send a deletion request', () async {
        final request = jsonEncode({'challenge_id': 'c', 'challenge_response': 'p', 'receipt_secret': secret});
        await expectLater(
            grant(() => send(body: request, headers: headers),
                action: ImmediateDeletionAction.challenge, expectedBody: request, token: 'captured'),
            throwsA(isA<EgressDeniedException>()));
        expect(sent, isEmpty);
      });
    });

    test('concurrent same-grant dispatches admit only one; grant ends after completion', () async {
      late Zone zone;
      final results = await grant(() async {
        zone = Zone.current;
        Future<String> attempt() async {
          try { await send(); return 'sent'; } on EgressDeniedException { return 'denied'; }
        }
        return Future.wait([attempt(), attempt()]);
      });
      expect(results.where((r) => r == 'sent').length, 1);
      expect(results.where((r) => r == 'denied').length, 1);
      expect(sent.length, 1);
      await expectLater(zone.run(() => send()), throwsA(isA<EgressDeniedException>()));
      expect(sent.length, 1);
    });

    test('unsupported streamed/multipart payloads never reach transport', () async {
      for (final request in <http.BaseRequest>[
        http.StreamedRequest('POST', endpoint), http.MultipartRequest('POST', endpoint),
      ]) {
        await expectLater(grant(() => transport.send(request)), throwsA(isA<EgressDeniedException>()));
      }
      expect(sent, isEmpty);
    });

    test('controlled monotonic expiry and lifecycle epoch deny before transport', () async {
      var now = Duration.zero;
      egress = TestEgress(monotonic: () => now).install();
      await expectLater(grant(() { now += kAccountControlTtl; return send(); }), throwsA(isA<EgressDeniedException>()));
      await expectLater(grant(() { egress.gate.advanceEpoch(); return send(); }), throwsA(isA<EgressDeniedException>()));
      expect(sent, isEmpty);
    });

    test('mutable request body/header during admission cannot change fingerprinted outgoing snapshot', () async {
      final blocked = _DeferredAdmissionSlot();
      final gate = CloudEgressGate(store: CloudEgressStore(secure: blocked, file: MemorySlot(),
          pendingSecure: MemorySlot(), pendingFile: MemorySlot()),
          activeOwner: () async => 'uid-a', resolved: true, supabaseUrl: () => _url);
      CloudEgressGate.instance = gate;
      final request = http.Request('POST', endpoint)
        ..headers['content-type'] = 'application/json'
        ..body = statusBody;
      final future = gate.runImmediateDeletion(action: ImmediateDeletionAction.status,
          owner: 'uid-a', activeOwner: 'uid-a', epoch: gate.epoch, isCurrent: () => true,
          functionUrl: endpoint, serializedBody: statusBody,
          exchange: () async => http.Response.fromStream(await transport.send(request)));
      await blocked.arrived.future;
      request.body = jsonEncode({'action': 'status', 'receipt_secret': 'B' * 43});
      request.headers['authorization'] = 'Bearer injected';
      blocked.release.complete();
      await future;
      expect(sent.single.body, statusBody);
      expect(sent.single.headers.containsKey('authorization'), isFalse);
    });

    test('finalizing original during admission preserves private snapshot and releases ticket', () async {
      final blocked = _DeferredAdmissionSlot();
      final gate = CloudEgressGate(store: CloudEgressStore(secure: blocked, file: MemorySlot(),
          pendingSecure: MemorySlot(), pendingFile: MemorySlot()),
          activeOwner: () async => 'uid-a', resolved: true, supabaseUrl: () => _url);
      CloudEgressGate.instance = gate;
      final original = http.Request('POST', endpoint)
        ..headers['content-type'] = 'application/json'
        ..body = statusBody;
      final future = gate.runImmediateDeletion(action: ImmediateDeletionAction.status,
          owner: 'uid-a', activeOwner: 'uid-a', epoch: gate.epoch, isCurrent: () => true,
          functionUrl: endpoint, serializedBody: statusBody,
          exchange: () async => http.Response.fromStream(await transport.send(original)));
      await blocked.arrived.future;
      original.finalize();
      blocked.release.complete();
      await future;
      expect(sent.single.body, statusBody);
      expect(sent.single.followRedirects, isFalse);
      expect(gate.inFlightCount, 0);
    });

    test('epoch change while durable admission read is paused sends zero HTTP', () async {
      final blocked = _DeferredAdmissionSlot();
      final gate = CloudEgressGate(store: CloudEgressStore(secure: blocked, file: MemorySlot(),
          pendingSecure: MemorySlot(), pendingFile: MemorySlot()),
          activeOwner: () async => 'uid-a', resolved: true, supabaseUrl: () => _url);
      CloudEgressGate.instance = gate;
      final future = gate.runImmediateDeletion(action: ImmediateDeletionAction.status,
          owner: 'uid-a', activeOwner: 'uid-a', epoch: gate.epoch, isCurrent: () => true,
          functionUrl: endpoint, serializedBody: statusBody, exchange: () => send());
      final caught = expectLater(future, throwsA(isA<EgressDeniedException>()));
      await blocked.arrived.future;
      gate.advanceEpoch();
      blocked.release.complete();
      await caught;
      expect(sent, isEmpty);
    });

    test('controlled expiry during response cancels publication and closes late zone authority', () async {
      var now = Duration.zero;
      egress = TestEgress(monotonic: () => now).install();
      final arrived = Completer<void>(); final release = Completer<http.Response>();
      transport = GatedHttpClient(MockClient((r) { sent.add(r); arrived.complete(); return release.future; }));
      late Zone zone;
      final future = grant(() { zone = Zone.current; return send(); });
      final caught = expectLater(future, throwsA(isA<EgressDeniedException>()));
      await arrived.future;
      now += kAccountControlTtl;
      release.complete(http.Response('{}', 200));
      await caught;
      expect(egress.gate.inFlightCount, 0);
      await expectLater(zone.run(() => send()), throwsA(isA<EgressDeniedException>()));
      expect(sent.length, 1);
    });

    test('ended-on-throw grant cannot authorize a captured zone', () async {
      late Zone zone;
      await expectLater(grant(() async { zone = Zone.current; throw StateError('failed'); }), throwsStateError);
      await expectLater(zone.run(() => send()), throwsA(isA<EgressDeniedException>()));
      expect(sent, isEmpty);
    });

    for (final invalid in ['status-with-challenge', 'status-token', 'request-no-token', 'request-with-status', 'configured-query', 'fragment']) {
      test('invalid grant configuration $invalid refuses before transport', () async {
        var body = statusBody;
        var url = endpoint;
        var action = ImmediateDeletionAction.status;
        String? token;
        if (invalid == 'status-with-challenge') body = jsonEncode({'action': 'status', 'receipt_secret': secret, 'challenge_id': 'x'});
        if (invalid == 'status-token') token = 'forbidden';
        if (invalid == 'request-no-token' || invalid == 'request-with-status') action = ImmediateDeletionAction.request;
        if (invalid == 'request-no-token') body = jsonEncode({'challenge_id': 'x', 'challenge_response': 'y', 'receipt_secret': secret});
        if (invalid == 'request-with-status') token = 'captured';
        if (invalid == 'configured-query') url = endpoint.replace(query: 'x=1');
        if (invalid == 'fragment') url = endpoint.replace(fragment: 'extra');
        await expectLater(grant(() => send(body: body, url: url), expectedBody: body, url: url,
            action: action, token: token), throwsA(isA<EgressDeniedException>()));
        expect(sent, isEmpty);
      });
    }

    test('a freeze still denies ordinary egress and a non-deletion control '
        'before transport', () async {
      ConsentAuthority.egressFrozen = true;
      addTearDown(() => ConsentAuthority.egressFrozen = false);
      await expectLater(send(), throwsA(isA<EgressDeniedException>()
          .having((e) => e.reason, 'reason', 'frozen')));
      await expectLater(
          egress.gate.runAccountControl(AccountControlOp.cancelDelete,
              () => send(url: Uri.parse('$_url/rest/v1/rpc/cancel_account_deletion'))),
          throwsA(isA<EgressDeniedException>()
              .having((e) => e.reason, 'reason', 'frozen')));
      expect(sent, isEmpty);
      expect(egress.gate.inFlightCount, 0);
    });

    // P5 (2026-11-14): no Cloud consent state refuses the immediate deletion
    // exchange, including a freeze that becomes restrictive mid-admission.
    for (final state in ['frozen', 'disabling', 'state_uncertain', 'pending_enable']) {
      test('immediate deletion status passes $state; ordinary egress stays denied',
          () async {
        if (state == 'frozen') ConsentAuthority.egressFrozen = true;
        addTearDown(() => ConsentAuthority.egressFrozen = false);
        if (state == 'disabling') {
          await egress.gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
        }
        if (state == 'state_uncertain') egress.file.value = '{broken';
        if (state == 'pending_enable') egress.pendingSecure.value = '{broken';
        await grant(() => send());
        expect(sent.length, 1);
        await expectLater(egress.gate.admit(),
            throwsA(isA<EgressDeniedException>()
                .having((e) => e.reason, 'reason', state)));
        expect(egress.gate.inFlightCount, 0);
      });
    }

    test('a freeze becoming restrictive during durable admission does not refuse '
        'the deletion exchange', () async {
      final blocked = _DeferredAdmissionSlot();
      final gate = CloudEgressGate(store: CloudEgressStore(secure: blocked, file: MemorySlot(),
          pendingSecure: MemorySlot(), pendingFile: MemorySlot()),
          activeOwner: () async => 'uid-a', resolved: true, supabaseUrl: () => _url);
      CloudEgressGate.instance = gate;
      addTearDown(() => ConsentAuthority.egressFrozen = false);
      final future = gate.runImmediateDeletion(action: ImmediateDeletionAction.status,
          owner: 'uid-a', activeOwner: 'uid-a', epoch: gate.epoch, isCurrent: () => true,
          functionUrl: endpoint, serializedBody: statusBody, exchange: () => send());
      await blocked.arrived.future;
      ConsentAuthority.egressFrozen = true;
      blocked.release.complete();
      await future;
      expect(sent.length, 1);
      expect(gate.inFlightCount, 0);
    });

    test('timeout ends captured grant and cancels in-flight ticket at controlled deadline', () async {
      final arrived = Completer<void>(); final response = Completer<http.Response>();
      transport = GatedHttpClient(MockClient((r) { sent.add(r); arrived.complete(); return response.future; }));
      late Zone zone;
      late _ControlledTimer deadline;
      final future = runZoned(() => grant(() { zone = Zone.current; return send(); }),
          zoneSpecification: ZoneSpecification(createTimer: (self, parent, z, duration, callback) {
        if (duration == kAccountControlTtl) return deadline = _ControlledTimer(callback);
        return parent.createTimer(z, duration, callback);
      }));
      final caught = expectLater(future, throwsA(isA<TimeoutException>()));
      await arrived.future;
      expect(sent.length, 1);
      deadline.fire();
      await caught;
      expect(egress.gate.inFlightCount, 0);
      await expectLater(zone.run(() => send()), throwsA(isA<EgressDeniedException>()));
      expect(sent.length, 1);
      response.complete(http.Response('{}', 200));
    });

    test('controlled drain cancellation ends exchange authority and denies captured zone', () async {
      const duration = Duration(seconds: 1);
      egress = TestEgress(drain: duration).install();
      final arrived = Completer<void>(); final response = Completer<http.Response>();
      transport = GatedHttpClient(MockClient((r) { sent.add(r); arrived.complete(); return response.future; }));
      late Zone zone;
      final future = grant(() { zone = Zone.current; return send(); });
      final caught = expectLater(future, throwsA(isA<EgressDeniedException>()));
      await arrived.future;
      late _ControlledTimer deadline;
      final draining = runZoned(() => egress.gate.drain(),
          zoneSpecification: ZoneSpecification(createTimer: (self, parent, z, timeout, callback) {
        if (timeout == duration) return deadline = _ControlledTimer(callback);
        return parent.createTimer(z, timeout, callback);
      }));
      deadline.fire();
      await draining;
      await caught;
      expect(egress.gate.inFlightCount, 0);
      await expectLater(zone.run(() => send()), throwsA(isA<EgressDeniedException>()));
      expect(sent.length, 1);
      response.complete(http.Response('{}', 200));
    });

    for (final resolution in ['throws', 'signed-out', 'foreign']) {
      test('new receipt grant owner resolver $resolution is distinguished before dispatch', () async {
        final gate = CloudEgressGate(store: CloudEgressStore(secure: MemorySlot(), file: MemorySlot(),
            pendingSecure: MemorySlot(), pendingFile: MemorySlot()),
            activeOwner: () async {
              if (resolution == 'throws') throw StateError('owner unavailable');
              return resolution == 'signed-out' ? null : 'uid-b';
            }, resolved: true, supabaseUrl: () => _url);
        CloudEgressGate.instance = gate;
        final future = gate.runImmediateDeletion(action: ImmediateDeletionAction.status,
            owner: 'uid-a', activeOwner: null, epoch: gate.epoch, isCurrent: () => true,
            functionUrl: endpoint, serializedBody: statusBody, exchange: () => send());
        if (resolution == 'signed-out') {
          await future;
          expect(sent.length, 1);
          expect(sent.single.headers.containsKey('Authorization'), isFalse);
        } else {
          await expectLater(future, throwsA(isA<EgressDeniedException>()));
          expect(sent, isEmpty);
        }
        expect(gate.inFlightCount, 0);
      });
    }

    test('new grant synchronous inner send failure settles once without ticket leak or uncaught asynchronous error', () async {
      final inner = _SynchronousThrowClient();
      transport = GatedHttpClient(inner);
      final parentZone = Zone.current;
      final recorder = <Object>[];
      var recorderOpen = true;
      var settlements = 0;
      Object? observed;
      late Zone captured;
      final producerDone = Completer<void>();
      runZonedGuarded(() async {
        try {
          await grant(() { captured = Zone.current; return send(); });
        } catch (error) {
          observed = error;
        } finally {
          settlements++;
          producerDone.complete();
        }
      }, (error, stack) {
        if (recorderOpen) {
          recorder.add(error);
        } else {
          // The recorder is closed at known producer completion. Any later
          // error is forwarded to the test zone, never silently swallowed.
          parentZone.handleUncaughtError(error, stack);
        }
      });
      await producerDone.future;
      recorderOpen = false;
      expect(observed, isA<StateError>());
      expect(settlements, 1);
      expect(inner.calls, 1);
      expect(egress.gate.inFlightCount, 0);
      expect(recorder, isEmpty);
      final lateProducerDone = Completer<Object?>();
      captured.run(() async {
        try {
          await send();
          lateProducerDone.complete(null);
        } catch (error) {
          lateProducerDone.complete(error);
        }
      });
      expect(await lateProducerDone.future, isA<EgressDeniedException>());
      expect(inner.calls, 1);
    });

    test('a legacy delete-account grant cannot authorize immediate receipt status', () async {
      await expectLater(egress.gate.runAccountControl(AccountControlOp.deleteAccount, () => send()),
          throwsA(isA<EgressDeniedException>()));
      expect(sent, isEmpty);
    });
  });
}
