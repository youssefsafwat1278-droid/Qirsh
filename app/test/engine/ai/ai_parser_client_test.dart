// MALI-060n — client sends a server-verifiable device secret + a stable
// idempotency request id + schema version to parse-sms.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';

void main() {
  SupabaseAiParserClient clientWith(
    http.Client http, {
    Future<String?> Function()? loadDeviceSecret,
  }) {
    return SupabaseAiParserClient(
      edgeFunctionUrl: 'https://x.test/functions/v1/parse-sms',
      getAnonJwt: () async => 'anon-jwt',
      loadDeviceSecret: loadDeviceSecret,
      httpClient: http,
    );
  }

  test('decodes optional exact amount_text alongside legacy numeric amount', () {
    final response = AiParseResponse.fromJson({
      'amount': 19.99,
      'amount_text': '19.99',
      'currency': 'SAR',
    });
    expect(response.amountText, '19.99');
    expect(response.amount, 19.99);
  });

  test('is_transaction:false is filtered by the client (null response)',
      () async {
    final mock = MockClient((req) async =>
        http.Response(jsonEncode({'is_transaction': false}), 200));
    final response = await clientWith(mock).parse(
      sanitizedSms: 'Your OTP is 1234',
      senderId: 'ACME',
      installId: 'install-1',
    );
    expect(response, isNull);
  });

  test('a response without amount/currency throws instead of a candidate',
      () async {
    final mock = MockClient(
        (req) async => http.Response(jsonEncode({'type': 'payment'}), 200));
    await expectLater(
      clientWith(mock).parse(
        sanitizedSms: 'x',
        senderId: 'ACME',
        installId: 'install-1',
      ),
      throwsA(isA<AiParseException>()),
    );
  });

  test('sends device_secret, request_id and schema_version', () async {
    late Map<String, dynamic> sent;
    final mock = MockClient((req) async {
      sent = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'amount': 10.0, 'currency': 'SAR'}), 200);
    });
    await clientWith(mock, loadDeviceSecret: () async => 'the-secret').parse(
      sanitizedSms: 'ACME purchase',
      senderId: 'ACME',
      installId: 'install-1',
    );
    expect(sent['device_secret'], 'the-secret');
    expect(sent['schema_version'], 1);
    expect(sent['request_id'], isA<String>());
    expect((sent['request_id'] as String).isNotEmpty, isTrue);
  });

  test('never sends the sender id (parse-sms does not read it)', () async {
    late Map<String, dynamic> sent;
    final mock = MockClient((req) async {
      sent = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'amount': 10.0, 'currency': 'SAR'}), 200);
    });
    await clientWith(mock).parse(
      sanitizedSms: 'Transfer received from [NAME] SAR 10.00',
      senderId: '+966551234567',
      installId: 'install-1',
    );
    expect(sent.containsKey('sender_id'), isFalse);
    expect(sent.containsKey('senderId'), isFalse);
    expect(jsonEncode(sent), isNot(contains('551234567')));
    expect(sent['sanitized_sms'], 'Transfer received from [NAME] SAR 10.00');
  });

  test('reuses the same request_id across the internal retry (idempotent)',
      () async {
    final ids = <String>[];
    var attempt = 0;
    final mock = MockClient((req) async {
      ids.add((jsonDecode(req.body) as Map<String, dynamic>)['request_id'] as String);
      attempt++;
      // First attempt: transient 502; second: success.
      return attempt == 1
          ? http.Response(jsonEncode({'error': 'x'}), 502)
          : http.Response(jsonEncode({'amount': 10.0, 'currency': 'SAR'}), 200);
    });
    await clientWith(mock, loadDeviceSecret: () async => 's').parse(
      sanitizedSms: 'ACME',
      senderId: 'ACME',
      installId: 'i',
    );
    expect(ids.length, 2);
    expect(ids[0], ids[1]); // same id → server dedupes, no double charge
  });

  test('omits device_secret when none is available (degrades to unauth)',
      () async {
    late Map<String, dynamic> sent;
    final mock = MockClient((req) async {
      sent = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'amount': 10.0, 'currency': 'SAR'}), 200);
    });
    await clientWith(mock, loadDeviceSecret: () async => null).parse(
      sanitizedSms: 'ACME',
      senderId: 'ACME',
      installId: 'i',
    );
    expect(sent.containsKey('device_secret'), isFalse);
    expect(sent['schema_version'], 1);
  });
}
