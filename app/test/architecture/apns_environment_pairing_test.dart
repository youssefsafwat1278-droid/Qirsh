import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A device token must be registered against the host it was actually issued
/// for.
///
/// REPRODUCED ON A REAL IPHONE: a Debug build signed `aps-environment:
/// development` registered its SANDBOX token as `production`, because
/// `AppDelegate` derived the value from `#if DEBUG` and `DEBUG` is not defined
/// in this project's Swift build conditions — `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
/// is unset on Debug, Profile AND Release, so the branch was dead and every
/// build reported "production". `process-ios-sms` routes on the stored value,
/// so every send went to api.push.apple.com with a sandbox token: a backend
/// that looks healthy and a notification that never arrives.
///
/// The Swift mapping itself is unit-tested in `ios/RunnerTests/RunnerTests.swift`.
/// This pins the contract from the Flutter side and, above all, that the NATIVE
/// value remains the single source of truth all the way to `register-push-token`.
void main() {
  String read(String path) => File(path).readAsStringSync();

  group('APNs environment comes from the signed entitlement', () {
    test('a missing profile needs store-distribution evidence', () {
      // "No profile" alone must never mean production: a stripped or
      // hand-assembled bundle would then register a guessed environment.
      final src = read('ios/Runner/AppDelegate.swift');
      expect(src, contains('static func isStoreDistributed('));
      expect(src, contains('appStoreReceiptURL'),
          reason: 'the receipt is the evidence, not the configuration name');
      expect(src, contains('name == "receipt" || name == "sandboxReceipt"'));
      // Field report 2026-11-14: a fresh TestFlight install has no receipt
      // file, so its existence must not be required; simulators never count.
      expect(src.contains('fileExists(atPath: url.path)'), isFalse);
      expect(src, contains('#if targetEnvironment(simulator)'));
      expect(src, contains('return isStoreDistributed ? "production" : nil'),
          reason: 'no receipt must fail closed');
    });

    test('nothing derives the environment from a configuration name', () {
      final src = read('ios/Runner/AppDelegate.swift');
      final start = src.indexOf('enum ApnsEnvironment');
      final end = src.indexOf('@main');
      final unit = src.substring(start, end);
      for (final forbidden in ['#if DEBUG', 'Configuration', 'Profile"', 'Release"']) {
        expect(unit.contains(forbidden), isFalse,
            reason: 'ApnsEnvironment must not consult "$forbidden"');
      }
    });

    test('the mapping is exact and unresolved values return nil', () {
      final src = read('ios/Runner/AppDelegate.swift');
      expect(src, contains('enum ApnsEnvironment'));
      expect(src, contains('case "development": return "sandbox"'));
      expect(src, contains('case "production": return "production"'));
      expect(src, contains('default: return nil'),
          reason: 'an unrecognised entitlement must not resolve to a host');
      expect(src, contains('static let entitlementKey = "aps-environment"'));
    });

    test('the registration handler never consults a compile flag', () {
      final src = read('ios/Runner/AppDelegate.swift');
      final start = src.indexOf('didRegisterForRemoteNotificationsWithDeviceToken');
      final end = src.indexOf('didFailToRegisterForRemoteNotificationsWithError');
      expect(start, isNot(-1));
      expect(end, greaterThan(start));
      final handler = src.substring(start, end);

      expect(handler.contains('#if DEBUG'), isFalse,
          reason: 'this is the exact defect: a dead compile flag chose the host');
      expect(handler, contains('ApnsEnvironment.current()'));
      expect(handler, contains('guard let environment'),
          reason: 'unresolved environment must withhold the token');
    });

    test('an unresolved environment stores nothing and reports failure', () {
      final src = read('ios/Runner/AppDelegate.swift');
      final start = src.indexOf('didRegisterForRemoteNotificationsWithDeviceToken');
      final end = src.indexOf('didFailToRegisterForRemoteNotificationsWithError');
      final handler = src.substring(start, end);

      final guardAt = handler.indexOf('guard let environment');
      final bailAt = handler.indexOf('return\n    }');
      final storeAt = handler.indexOf('SharedCaptureStore.setApnsToken');
      final notifyAt = handler.indexOf("invokeMethod(\"apnsTokenUpdated\"");

      expect(guardAt, isNot(-1));
      expect(bailAt, greaterThan(guardAt),
          reason: 'the guard must bail before anything is stored');
      expect(storeAt, greaterThan(bailAt),
          reason: 'the token must be stored only AFTER the environment resolves');
      expect(notifyAt, greaterThan(storeAt));
      expect(handler, contains('apnsRegistrationFailed'),
          reason: 'the failure must be observable, not silent');
    });

    test('the diagnostic leaks neither the token nor an identifier', () {
      final src = read('ios/Runner/AppDelegate.swift');
      final start = src.indexOf('guard let environment');
      final end = src.indexOf('SharedCaptureStore.setApnsToken');
      final bail = src.substring(start, end);
      expect(bail.contains(r'\(token)'), isFalse,
          reason: 'a device token must never reach a log');
      expect(bail, contains('NSLog("[Capture] APNs environment unresolved'));
    });
  });

  group('the native value is the single source of truth', () {
    test('Dart never invents an environment', () {
      // A fallback anywhere in Dart would silently re-create the defect.
      for (final file in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final body = file.readAsStringSync();
        expect(body.contains("'sandbox'"), isFalse,
            reason: '${file.path} hardcodes an APNs environment');
      }
    });

    test('a token with no environment is discarded, not defaulted', () {
      final bridge =
          read('lib/features/capture/services/native_capture_bridge.dart');
      expect(bridge, contains("final environment = _emptyToNull(value['environment'] as String?);"));
      expect(bridge, contains('if (token == null || environment == null) return null;'),
          reason: 'a missing environment must drop the token, not guess one');
    });

    test('register-push-token receives the native environment verbatim', () {
      final service = read(
          'lib/features/capture/services/capture_device_registration_service.dart');
      expect(service, contains('apnsEnvironment: token.environment'));
      expect(service.contains("apnsEnvironment: 'production'"), isFalse);
      expect(service.contains("apnsEnvironment: 'sandbox'"), isFalse);
    });
  });
}
