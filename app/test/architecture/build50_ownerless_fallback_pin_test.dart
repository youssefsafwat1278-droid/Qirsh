// Astra H1 build-50 regression (source pin; Swift is not compiled here).
//
// When the server refuses an ownerless legacy upload with 409
// capture_owner_conflict, the App Intent must:
//   * treat every non-200 as a failure (`BackendCaptureError.http(status)`),
//   * NOT retry it (only timeout-shaped errors get the one idempotent retry),
//   * store the item durably as `.sent` with its failureReason (`http(409)`),
//   * show only the LOCAL deterministic preview banner (no server content).
// The app import of that `.sent` + `http(409)` item is covered by
// capture_import_service_test (local parse, no AI) and
// native_capture_ai_fallback_test (a 409 never reaches the in-app AI fallback).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src =
      File('ios/BankMessageShortcuts/BankMessageShortcuts.swift').readAsStringSync();

  test('every non-200 response (409 included) is a thrown http(status)', () {
    expect(
      src,
      matches(RegExp(r'guard statusCode == 200 else \{\s*'
          r'throw BackendCaptureError\.http\(statusCode\)')),
    );
  });

  test('a non-timeout failure (a 409) is never retried', () {
    expect(src,
        contains(r'guard Self.isTimeoutShaped(error) else { return (nil, "\(error)") }'));
  });

  test('the failure is stored durably as .sent with its reason, then the local '
      'deterministic banner path runs', () {
    final fallback = RegExp(
        r'let durableFallback = SharedCaptureStore\.updateStatus\(\s*'
        r'payloadID: payloadID,\s*status: \.sent,\s*'
        r'failureReason: attempt\.failureReason\s*\)\s*'
        r'if durableFallback \{[\s\S]*?'
        r'scheduleLocalParsedOrGenericNotification\(payloadID: payloadID\)');
    expect(src, matches(fallback));
  });

  test('the local banner is the on-device PreviewParser, high confidence only',
      () {
    final start =
        src.indexOf('private func scheduleLocalParsedOrGenericNotification(');
    expect(start, greaterThan(0));
    final body = src.substring(start, start + 800);
    // V1-035 (2026-11-17): the legacy branch now uses the same localized
    // builder as the v2 path, whose only local source is localDetail().
    expect(body, contains('detailedCaptureNotification()'));
    expect(body, isNot(contains('URLSession')));
    final local = src.substring(
        src.indexOf('private func localDetail() -> CaptureDetail? {'));
    final localBody = local.substring(0, local.indexOf('\n  }\n'));
    expect(localBody, contains('PreviewParser.shared'));
    expect(localBody, contains('result.isHighConfidence'));
  });
}
