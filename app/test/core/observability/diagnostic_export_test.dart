import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/observability/app_diagnostics.dart';
import 'package:money_companion/core/observability/diagnostic_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(AppDiagnostics.resetForTest);
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await AppDiagnostics.resetForTest();
  });

  test('explicit support export copies local content-free events to the clipboard', () async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    AppDiagnostics.record(AppOperation.settingsSync, AppEventState.blocked,
        reason: AppEventReason.capability);
    await copyAppDiagnostics();
    expect(copied, contains('settingsSync blocked'));
    expect(copied, contains('reason=capability'));
    expect(copied, isNot(contains('Authorization')));
  });
}
