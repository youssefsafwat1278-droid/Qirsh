// CAP-5: `capture_import_v3` is seeded OFF; OFF keeps the shipped import path,
// and the v3 service has no AI route.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('seeded inactive in the flag catalog', () {
    final json = File('assets/catalog/feature_flags.json').readAsStringSync();
    final m = RegExp(
            r'"key": "capture_import_v3",[^}]*"value": "(\w+)"[^}]*"is_active": (true|false)')
        .firstMatch(json);
    expect(m, isNotNull);
    expect(m!.group(1), 'false');
    expect(m.group(2), 'false');
  });

  test('default is false in the app flag defaults', () {
    final src =
        File('lib/data/catalog/feature_flag_service.dart').readAsStringSync();
    expect(src, contains("'capture_import_v3': false"));
  });

  test(
      'the shell takes the v3 branch only behind the flag, before the legacy '
      'drain body', () {
    final src = File('lib/features/app/app_shell.dart').readAsStringSync();
    final gate = src.indexOf(
        'if (_captureImportV3Enabled()) {\n        await _runCaptureImportV3();');
    // The legacy drain body now lives in LegacyCaptureDrain; the shell reaches
    // it through its provider.
    final legacy = src.indexOf('ref.read(legacyCaptureDrainProvider)');
    expect(gate, greaterThan(0));
    expect(gate, lessThan(legacy));
    expect(src, contains("featureFlags.getBool('capture_import_v3')"));
  });

  test('the import service never reaches an AI client or the AI fallback flag',
      () {
    for (final f in [
      'capture_import_service.dart',
      'capture_server_port.dart',
      'unbound_capture_prompt_service.dart',
      'legacy_capture_resolver.dart',
    ]) {
      final src = File('lib/features/capture/services/$f').readAsStringSync();
      expect(src, isNot(contains('AiParserClient')), reason: f);
      expect(src, isNot(contains('capture_ai_fallback_enabled')), reason: f);
      expect(src, isNot(contains('nativeCaptureMayUseAiFallback')), reason: f);
    }
    final service =
        File('lib/features/capture/services/capture_import_service.dart')
            .readAsStringSync();
    expect(service, contains('onDeviceOnly: true'));
  });
}
