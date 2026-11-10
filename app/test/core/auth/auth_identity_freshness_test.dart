import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/auth/supabase_auth_service.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../harness/egress_test_support.dart';
import '../session/session_freshness_test.dart' show jwt;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('iOS Google exchange proves the nonce for each native attempt', () async {
    TestEgress().install();
    const channel = MethodChannel('mali/google_authorization');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final challenges = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'authorize');
      expect(call.arguments['clientId'], app.kGoogleIosClientId);
      challenges.add(call.arguments['nonce'] as String);
      return {'idToken': 'synthetic-google-id', 'accessToken': 'synthetic-google-access'};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    var exchanges = 0;
    final client = SupabaseClient('https://example.supabase.co', 'synthetic-anon',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(request.url.queryParameters['grant_type'], 'id_token');
        expect(body['provider'], 'google');
        expect(app.appleHashedNonce(body['nonce'] as String), challenges.last);
        expect(body['access_token'], 'synthetic-google-access');
        exchanges++;
        return http.Response(jsonEncode({
          'access_token': jwt('uid-a', DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600),
          'token_type': 'bearer',
          'user': {'id': 'uid-a'},
        }), 200);
      }));
    addTearDown(client.dispose);
    final service = app.SupabaseAuthService(client: client, platform: TargetPlatform.iOS);
    await service.signInWithGoogle();
    await service.signInWithGoogle();
    expect(exchanges, 2);
    expect(challenges.toSet(), hasLength(2));
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    await expectLater(service.signInWithGoogle(), throwsA(isA<app.AuthCancelledException>()));
    expect(exchanges, 2);
  });

  for (final expired in [true, false]) {
    test(
        'OTP provider ${expired ? 'rejects expired' : 'binds fresh'} response capability',
        () async {
      TestEgress().install();
      var uid = 'uid-a';
      final client =
          SupabaseClient('https://example.supabase.co', 'synthetic-anon',
              authOptions: const AuthClientOptions(autoRefreshToken: false),
              httpClient: MockClient((_) async => http.Response(
                  jsonEncode({
                    'access_token': jwt(
                        uid,
                        expired
                            ? 1
                            : DateTime.now().millisecondsSinceEpoch ~/ 1000 +
                                3600),
                    'token_type': 'bearer',
                    'user': {'id': uid},
                  }),
                  200)));
      final service = app.SupabaseAuthService(client: client);
      if (expired) {
        await expectLater(
            service.verifyEmailCode(email: 'a@example.test', code: '123456'),
            throwsA(isA<app.AuthException>()));
      } else {
        final identity = (await service.verifyEmailCode(
            email: 'a@example.test', code: '123456'))!;
        expect(identity.isCurrent!(), isTrue);
        uid = 'uid-b';
        await client.auth
            .signInWithPassword(email: 'b@example.test', password: 'synthetic');
        expect(identity.isCurrent!(), isFalse);
      }
      await client.dispose();
    });
  }
}
