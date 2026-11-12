import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';

void main() {
  for (final showDetails in [true, false]) {
    test('replayed capture preserves notification details preference: $showDetails', () async {
      late Request sent;
      final client = CaptureBackendClient(
        supabaseUrl: 'https://example.supabase.co', anonKey: 'anon',
        notificationDetails: showDetails,
        httpClient: MockClient((request) async {
          sent = request;
          return Response('{}', 200);
        }),
      );
      await client.processIosSms(
        installId: 'i', deviceSecret: 's', payloadId: 'p', smsText: 'sanitized',
        receivedAt: DateTime.utc(2026), allowAi: true, ownerUid: 'u', ownerGeneration: 1,
      );
      expect((jsonDecode(sent.body) as Map)['notificationDetails'], showDetails);
    });
  }

  test('pending-send retry preserves payload id and AI consent', () async {
    late Request sent;
    final client = CaptureBackendClient(
      supabaseUrl: 'https://example.supabase.co',
      anonKey: 'anon-key',
      httpClient: MockClient((request) async {
        sent = request;
        return Response('{"status":"processed"}', 200);
      }),
    );

    await client.processIosSms(
      installId: 'install-a',
      deviceSecret: 'device-secret',
      payloadId: 'stable-payload',
      smsText: 'bank message',
      receivedAt: DateTime.utc(2026, 7, 14, 12),
      allowAi: false,
      ownerUid: 'uid-a',
      ownerGeneration: 3,
    );

    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['payloadId'], 'stable-payload');
    expect(body['allowAi'], isFalse);
    expect(sent.url.path, '/functions/v1/process-ios-sms');
    // Astra G C.1 (new assertions): the owner and its generation are ALWAYS sent,
    // also on the v1 body (no schema_version marker there).
    expect(body['owner_uid'], 'uid-a');
    expect(body['owner_generation'], 3);
    expect(body.containsKey('schema_version'), isFalse);
  });

  test('pending-send replay keeps a bounded configurable timeout', () async {
    final client = CaptureBackendClient(
      supabaseUrl: 'https://example.supabase.co',
      anonKey: 'anon-key',
      processIosSmsTimeout: const Duration(milliseconds: 1),
      httpClient: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return Response('{"status":"processed"}', 200);
      }),
    );

    await expectLater(
      client.processIosSms(
        installId: 'install-a',
        deviceSecret: 'device-secret',
        payloadId: 'stable-payload',
        smsText: 'bank message',
        receivedAt: DateTime.utc(2026, 7, 14, 12),
        allowAi: false,
        ownerUid: 'uid-a',
        ownerGeneration: 3,
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('unlink uses device credentials and never requires a user JWT',
      () async {
    late Request sent;
    final client = CaptureBackendClient(
      supabaseUrl: 'https://example.supabase.co',
      anonKey: 'anon-key',
      httpClient: MockClient((request) async {
        sent = request;
        return Response('{"ok":true}', 200);
      }),
    );

    await client.unlinkDevice(
      installId: 'install-a',
      deviceSecret: 'device-secret',
    );

    expect(sent.url.path, '/functions/v1/unlink-capture-device');
    expect(sent.headers['authorization'], 'Bearer anon-key');
    expect(jsonDecode(sent.body), {
      'installId': 'install-a',
      'deviceSecret': 'device-secret',
    });
  });

  test('unlink failure is reported without rotating the local secret',
      () async {
    final client = CaptureBackendClient(
      supabaseUrl: 'https://example.supabase.co',
      anonKey: 'anon-key',
      httpClient: MockClient((_) async => Response('{}', 401)),
    );

    await expectLater(
      client.unlinkDevice(installId: 'install-a', deviceSecret: 'bad'),
      throwsA(isA<CaptureBackendException>()),
    );
  });
  // F10 — "nothing is known" must not be read as "there are no results": the
  // drain would park a server-analysed capture and later discard its result.
  group('sync-captures: a malformed 200 is unknown, not empty', () {
    CaptureBackendClient client(String body) => CaptureBackendClient(
          supabaseUrl: 'https://example.supabase.co',
          anonKey: 'anon',
          httpClient: MockClient((_) async => Response(body, 200)),
        );

    test('a non-JSON body throws instead of returning no captures', () async {
      await expectLater(
        client('<html>ok</html>').syncCaptures(installId: 'i', deviceSecret: 's'),
        throwsA(isA<CaptureBackendException>()
            .having((e) => e.reason, 'reason', 'sync_failed_malformed')),
      );
    });

    test('a JSON body without a captures list throws', () async {
      await expectLater(
        client('{"ok":true}').syncCaptures(installId: 'i', deviceSecret: 's'),
        throwsA(isA<CaptureBackendException>()),
      );
    });

    test('a well-formed empty list is still "no results"', () async {
      expect(
        await client('{"captures":[]}')
            .syncCaptures(installId: 'i', deviceSecret: 's'),
        isEmpty,
      );
    });
  });
}
