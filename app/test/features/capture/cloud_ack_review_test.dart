import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/features/capture/services/capture_consent_client.dart';

void main() {
  for (final route in ['link-capture-device', 'set-device-consent']) {
    test('$route must reject HTTP 200 when Supabase did not apply ON',
        () async {
      final client = CaptureConsentClient(
        supabaseUrl: 'https://example.supabase.co',
        anonKey: 'test',
        httpClient: MockClient((request) async {
          expect(request.url.pathSegments.last, route);
          return http.Response(
            '{"ok":true,"applied":false,"reason":"stale_generation",'
            '"cloud_processing_enabled":true,"ai_consent_granted":true}',
            200,
          );
        }),
      );

      final request = route == 'link-capture-device'
          ? client.link(
              installId: 'install',
              deviceSecret: 'secret',
              jwt: 'jwt',
              cloud: true,
              ai: true,
              version: 7,
              clientGeneration: 3)
          : client.setConsent(
              installId: 'install',
              deviceSecret: 'secret',
              jwt: 'jwt',
              cloud: true,
              ai: true,
              version: 7,
              clientGeneration: 3);

      await expectLater(request, throwsException);
    });
  }
}
