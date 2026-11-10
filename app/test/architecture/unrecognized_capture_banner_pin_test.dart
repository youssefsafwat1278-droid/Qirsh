import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/app/capture_notification_actions.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

/// Source pins for the "unrecognized bank message" banner (Swift cannot run
/// under flutter test).
void main() {
  String read(String p) => File('${Directory.current.path}/$p').readAsStringSync();
  final shortcut = read('ios/BankMessageShortcuts/BankMessageShortcuts.swift');
  final delegate = read('ios/Runner/AppDelegate.swift');

  test('category and action ids match the Dart constants', () {
    expect(shortcut, contains('"QIRSH_UNRECOGNIZED_CAPTURE"'));
    expect(shortcut, contains('"$kActionEnableSmartAnalysis"'));
    expect(shortcut, contains('"$kActionAddManually"'));
    expect(shortcut.split('options: [.foreground]').length - 1, 2);
  });

  test('registration merges with existing categories', () {
    expect(shortcut, contains('notificationCategories()'));
    expect(shortcut, contains('setNotificationCategories(categories)'));
    expect(shortcut, contains(r'$0.identifier != unrecognizedCaptureId'));
  });

  test('plugin category list carries the category (it replaces, not merges)',
      () {
    final plugin =
        read('lib/features/capture/services/local_notification_service.dart');
    final block = plugin.substring(
        plugin.indexOf('kUnrecognizedCaptureCategory,'),
        plugin.indexOf('const windows'));
    expect(block, contains('kActionEnableSmartAnalysis'));
    expect(block, contains('kActionAddManually'));
    expect(
        block.split('DarwinNotificationActionOption.foreground').length - 1, 2);
    expect(block, contains("'تفعيل التحليل الذكي'"));
    expect(block, contains("'إضافة يدويًا'"));
    expect(shortcut, contains('"تفعيل التحليل الذكي" : "Enable Smart Analysis"'));
    expect(shortcut, contains('"إضافة يدويًا" : "Add manually"'));
    expect(kUnrecognizedCaptureCategory, 'QIRSH_UNRECOGNIZED_CAPTURE');
  });

  test('AppDelegate no longer registers at launch; Shortcut still does', () {
    expect(delegate.contains('registerUnrecognizedCapture'), isFalse);
    final generic = shortcut.substring(
        shortcut.indexOf('private func scheduleGenericFallbackNotification'));
    expect(generic,
        contains('QirshNotificationCategories.registerUnrecognizedCapture()'));
  });

  test('generic fallback uses the category; copy differs by cause', () {
    final generic = shortcut.substring(
        shortcut.indexOf('private func scheduleGenericFallbackNotification'),
        shortcut.indexOf('static func smartAnalysisInviteBody'));
    expect(generic, contains('Self.smartAnalysisInviteBody(sender: sender)'));
    expect(generic, contains('Self.backendFailureBody(sender: sender)'));
    expect(generic,
        contains('categoryIdentifier: QirshNotificationCategories.unrecognizedCaptureId'));
    expect(generic.contains('unparseableFallbackBody'), isFalse);
    expect(generic, contains('SharedCaptureStore.notificationLanguage == "ar"'));
    expect(generic, contains('"قِرش رصد رسالة بنك" : "Bank message captured"'));
    expect(generic, contains('type: "received"'));

    // Backend-failure call site uses the default (backend-failure copy) and is
    // still stored as `.sent` + failureReason; the cloud-off site opts into the
    // Smart Analysis invite and is stored as `.sent`.
    final perform = shortcut.substring(shortcut.indexOf('if config.canUseBackend {'));
    final backendPart = perform.substring(0, perform.indexOf('let outcome = try service.capture('));
    expect(backendPart,
        contains('await scheduleLocalParsedOrGenericNotification(payloadID: payloadID)'));
    expect(backendPart, contains('failureReason: attempt.failureReason'));
    final offPart = perform.substring(perform.indexOf('let outcome = try service.capture('));
    expect(offPart, contains('status: .sent'));
    expect(offPart, contains('offersSmartAnalysis: true'));
    expect(shortcut.contains('unparseableFallbackBody'), isFalse);
  });

  test('new copy text', () {
    expect(shortcut,
        contains(r'لم نتعرّف على رسالة \(sender) تلقائيًا. فعّل التحليل الذكي ليحاول قِرش فهم رسائل البنوك الجديدة، أو أضفها يدويًا.'));
    expect(shortcut,
        contains('لم نتعرّف على رسالة البنك تلقائيًا. فعّل التحليل الذكي ليحاول قِرش فهم رسائل البنوك الجديدة، أو أضفها يدويًا.'));
  });

  test('backend-failure copy text', () {
    expect(shortcut,
        contains(r'تعذّر تحليل رسالة \(sender) الآن. افتح قِرش لمراجعتها أو إضافتها يدويًا.'));
    expect(shortcut,
        contains('تعذّر تحليل رسالة البنك الآن. افتح قِرش لمراجعتها أو إضافتها يدويًا.'));
  });

  test('action is forwarded from didReceive into the route queue', () {
    expect(delegate, contains('response.actionIdentifier'));
    expect(delegate, contains('QirshNotificationCategories.actionIds.contains(actionId)'));
    for (final p in [
      'ios/Runner/SharedCaptureStore.swift',
      'ios/ShareBankMessage/SharedCaptureStore.swift'
    ]) {
      expect(read(p), contains('let action: String?'));
    }
  });

  test('CaptureNotificationRoute carries action (absent -> null)', () {
    const plain = CaptureNotificationRoute(payloadId: 'p');
    expect(plain.action, isNull);
    const withAction = CaptureNotificationRoute(action: kActionAddManually);
    expect(withAction.action, 'qirsh.add_manually');
  });
}
