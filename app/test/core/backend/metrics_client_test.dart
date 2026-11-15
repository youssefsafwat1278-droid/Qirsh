import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/core/backend/metrics_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// [currentUser] can be non-null from a locally-cached session even when the
/// underlying token is no longer valid server-side (a failed silent refresh
/// on cold start, exactly as observed live: `Invalid Refresh Token: Refresh
/// Token Not Found` immediately after `Supabase init completed`). Builds a
/// JWT with a future `exp` claim only — gotrue derives `Session.expiresAt`
/// purely from the local claim (no signature check), so `recoverSession`
/// accepts it and sets `currentUser` without any network call.
String _fakeNotYetExpiredAccessToken() {
  String segment(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final header = segment({'alg': 'none', 'typ': 'JWT'});
  final payload = segment({
    'exp':
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
            1000,
    'sub': 'qa-user',
  });
  return '$header.$payload.';
}

void main() {
  test('app-open metric retries a rejected account-lock write', () async {
    final writes = <String>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/rest/v1/rpc/record_metric');
        writes.add(request.body);
        return Response(
          writes.length == 1 ? '{"code":"55P03","message":"account_busy"}' : 'null',
          writes.length == 1 ? 500 : 200,
          headers: const {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    addTearDown(client.dispose);
    await client.auth.recoverSession(jsonEncode({
      'access_token': _fakeNotYetExpiredAccessToken(),
      'token_type': 'bearer',
      'user': {'id': 'qa-user'},
    }));

    await MetricsClient(client: client).logEvent('app_open');

    expect(writes, hasLength(2));
    expect(writes.last, writes.first);
  });

  test(
      'logEvent never throws when the metrics insert is rejected '
      '(stale-session RLS failure) — must not be able to block app bootstrap',
      () async {
    final http = MockClient((request) async {
      return Response(
        jsonEncode({
          'message':
              'new row violates row-level security policy for table "metrics"',
          'code': '42501',
          'details': 'Unauthorized',
        }),
        403,
        headers: const {'content-type': 'application/json'},
        request: request,
      );
    });
    final client = SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      httpClient: http,
    );
    await client.auth.recoverSession(jsonEncode({
      'access_token': _fakeNotYetExpiredAccessToken(),
      'token_type': 'bearer',
      'user': {'id': 'qa-user'},
    }));
    expect(client.auth.currentUser, isNotNull,
        reason: 'test setup must reproduce a non-null-but-invalid session');

    await expectLater(
      MetricsClient(client: client).logEvent('app_open'),
      completes,
    );
  });

  test('logEvent is a no-op with no signed-in user', () async {
    var called = false;
    final http = MockClient((request) async {
      called = true;
      return Response('{}', 200);
    });
    final client = SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      httpClient: http,
    );

    await MetricsClient(client: client).logEvent('app_open');

    expect(called, isFalse);
  });

  test('MALI-075n: routes through the record_metric RPC, not a direct insert',
      () async {
    String? path;
    final http = MockClient((request) async {
      path = request.url.path;
      return Response('null', 200,
          headers: const {'content-type': 'application/json'});
    });
    final client = SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      httpClient: http,
    );
    await client.auth.recoverSession(jsonEncode({
      'access_token': _fakeNotYetExpiredAccessToken(),
      'token_type': 'bearer',
      'user': {'id': 'qa-user'},
    }));

    await MetricsClient(client: client).logEvent('app_open', dimension: 'ios');

    expect(path, contains('/rpc/record_metric'));
    expect(path, isNot(contains('/metrics'))); // never the raw table
  });
}
