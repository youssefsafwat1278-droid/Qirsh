import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

/// MALI-013 — Android automatic financial-SMS capture.
///
/// Play treats `RECEIVE_SMS` as a restricted permission and grants an exception
/// only for SMS-based money management. Everything asserted here is something
/// the review checks or something whose regression would be invisible:
///
///   • the manifest asks for RECEIVE_SMS and nothing wider,
///   • the receiver can only be reached by the OS,
///   • a granted permission is not treated as consent,
///   • the privacy-filter rule has not been loosened back to `amount OR keyword`,
///   • the privacy policy describes what actually ships.
///
/// The Kotlin filter itself has no unit test: the project has no JVM or
/// instrumentation test source set for Android, so these are structural
/// assertions over the source instead. That is weaker than executing it and is
/// recorded as such in `Qirsh Production/18_Android_SMS_Capture/`.
void main() {
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  // Comments are load-bearing here: the permission spent months commented out,
  // and a naive grep reported it as present the whole time.
  final effective = manifest.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  group('effective release manifest', () {
    test('RECEIVE_SMS is declared', () {
      expect(effective, contains('android.permission.RECEIVE_SMS'),
          reason: 'automatic capture is a core V1 feature');
    });

    test('no wider SMS permission is requested', () {
      // Each of these enlarges the Play declaration and none is used by the
      // implementation, which reads broadcast intents only.
      for (final permission in const [
        'READ_SMS',
        'SEND_SMS',
        'WRITE_SMS',
        'RECEIVE_MMS',
        'RECEIVE_WAP_PUSH',
      ]) {
        expect(effective.contains(permission), isFalse,
            reason: '$permission is not used and must not be declared');
      }
    });

    test('no NotificationListenerService', () {
      // Documentation claimed one for months. There has never been one, and
      // declaring it would invite a second restricted-permission review.
      expect(effective.contains('NotificationListener'), isFalse);
    });

    test('the SMS receiver is declared and OS-only', () {
      expect(effective, contains('.SmsCaptureReceiver'));
      expect(effective, contains('android.provider.Telephony.SMS_RECEIVED'));
      // Without BROADCAST_SMS any app could inject a fake bank SMS.
      expect(effective, contains('android:permission="android.permission.BROADCAST_SMS"'));
    });

    test('the receiver is manifest-declared, not runtime-registered', () {
      // It must start when the process is not running; a runtime-registered
      // receiver cannot, which would silently break closed-app capture.
      expect(effective, contains('<receiver'));
    });
  });

  group('native gating', () {
    final settings = File(
      'android/app/src/main/kotlin/com/example/money_companion/CaptureSettings.kt',
    ).readAsStringSync();

    test('a granted permission is not consent — opt-in defaults to false', () {
      expect(settings, contains('getBoolean(KEY_AUTO_ENABLED, false)'));
    });

    test('revocation fails capture closed', () {
      // isAutoCaptureEnabled re-checks the permission every call, so revoking
      // in system settings stops capture without the app being involved.
      expect(settings, contains('if (!hasReceiveSmsPermission(context)) return false'));
    });

    test('opt-in is reset on identity change', () {
      expect(settings, contains('fun reset('));
    });

    test('the opt-in counts only for the active owner (never signed out)', () {
      // Per-account memory: the receiver's gate is the policy, which needs an
      // active owner whose own opt-in it is (CaptureOptInPolicyTest, JVM).
      expect(settings, contains('CaptureOwnerPolicy.captureAllowed('));
      expect(settings, contains('DurableCaptureQueue.get(context).activeOwnerHash()'));
    });
  });

  group('receiver privacy prefilter', () {
    final receiver = File(
      'android/app/src/main/kotlin/com/example/money_companion/SmsCaptureReceiver.kt',
    ).readAsStringSync();

    test('filtering happens before anything is enqueued', () {
      final filterAt = receiver.indexOf('shouldRetain(');
      final enqueueAt = receiver.indexOf('.enqueue(');
      expect(filterAt, greaterThan(-1));
      expect(filterAt, lessThan(enqueueAt),
          reason: 'a non-financial message must never reach durable storage');
    });

    test('the rule is sender-aware, not a flat OR', () {
      // The previous rule was `hasAmount || hasKeyword` for every sender, so a
      // personal message containing "card" was retained. Numeric senders — where
      // personal messages come from — now require both signals.
      expect(receiver, contains('isAlphanumericSender'));
      expect(receiver, contains('hasAmount || hasKeyword'));
      expect(receiver, contains('hasAmount && hasKeyword'));
    });

    test('an unknown sender takes the strict path', () {
      // Absent evidence must not buy the loose rule.
      expect(receiver, contains('if (s.isEmpty()) return false'));
    });

    test('one-time codes are dropped', () {
      expect(receiver, contains('isLikelyOtp'));
    });

    test('the prefilter does not become a second parser', () {
      // The authoritative parse lives in the Dart engine. Anything resembling
      // extraction here would drift from it and be invisible when it did.
      for (final smell in const ['ParsedTransaction', 'amountValue', 'merchant']) {
        expect(receiver.contains(smell), isFalse,
            reason: 'the receiver must classify, never extract');
      }
    });

    test('multipart reconstruction and the SMS timestamp are preserved', () {
      expect(receiver, contains('for (part in messages)'));
      expect(receiver, contains('timestampMillis'));
    });
  });

  group('permission result contract', () {
    test('denied and permanently denied are distinguishable', () {
      // They need different UX: one can retry the dialog, the other can only be
      // resolved in system settings. Collapsing them yields a button that
      // silently does nothing.
      expect(
        SmsPermissionResult.fromJson(const {'status': 'denied'}).status,
        SmsPermissionStatus.denied,
      );
      expect(
        SmsPermissionResult.fromJson(const {'status': 'permanently_denied'})
            .status,
        SmsPermissionStatus.permanentlyDenied,
      );
    });

    test('granted permission is reported separately from enablement', () {
      final r = SmsPermissionResult.fromJson(
        const {'status': 'granted', 'granted': true, 'enabled': false},
      );
      expect(r.granted, isTrue);
      expect(r.enabled, isFalse,
          reason: 'permission granted is not the same as user opt-in');
    });

    test('an unknown status fails closed', () {
      final r = SmsPermissionResult.fromJson(const {'status': 'nonsense'});
      expect(r.status, SmsPermissionStatus.unavailable);
      expect(r.granted, isFalse);
      expect(r.enabled, isFalse);
    });
  });

  group('disclosure ordering', () {
    final service = File(
      'lib/features/capture/services/android_sms_capture_service.dart',
    ).readAsStringSync();

    test('the disclosure is a required parameter, not a convention', () {
      // Passing it in makes the Play-required ordering structural: there is no
      // path to the system dialog that skips it.
      expect(service, contains('required Future<bool> Function() showDisclosure'));
    });

    test('declining never requests the permission', () {
      final declineAt = service.indexOf('if (!accepted)');
      final requestAt = service.indexOf('requestReceiveSmsPermission()');
      expect(declineAt, greaterThan(-1));
      expect(declineAt, lessThan(requestAt));
    });

    test('capture is only enabled after a granted result', () {
      final guardAt =
          service.indexOf('if (result.status != SmsPermissionStatus.granted)');
      final enableAt = service.indexOf('setAutomaticSmsCaptureEnabled(true)');
      expect(guardAt, greaterThan(-1));
      expect(guardAt, lessThan(enableAt));
    });
  });

  group('other platforms and paths are unaffected', () {
    test('share capture needs no permission', () {
      final settings = File(
        'android/app/src/main/kotlin/com/example/money_companion/CaptureSettings.kt',
      ).readAsStringSync();
      expect(settings, contains('fun supportsShareCapture(): Boolean = true'));
    });

    test('the automatic path is Android-only', () {
      final service = File(
        'lib/features/capture/services/android_sms_capture_service.dart',
      ).readAsStringSync();
      expect(service, contains('if (!Platform.isAndroid)'));
    });

    test('iOS declares no SMS capability', () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();
      expect(plist.contains('SMS'), isFalse);
    });
  });

  group('privacy policy matches what ships', () {
    final policy = File('../docs/legal/PRIVACY_POLICY.md').readAsStringSync();

    test('SMS access is disclosed', () {
      expect(policy, contains('RECEIVE_SMS'));
      expect(policy.toLowerCase(), contains('incoming sms'));
    });

    test('the stale notification-access claim is gone', () {
      // There has never been a NotificationListenerService; the policy claimed
      // notification access was the core permission.
      expect(policy.contains('Notification access'), isFalse);
    });

    test('it states the two-key lock and the off switch', () {
      // Matched on fragments, not full sentences: the source is hard-wrapped
      // Markdown with inline emphasis, so a sentence match would fail on
      // reflow or on a `**bold**` marker rather than on meaning.
      expect(policy.toLowerCase(), contains('enough on its own'));
      expect(policy.toLowerCase(), contains('automatic capture stays'));
      expect(policy.toLowerCase(), contains('revoke the permission'));
    });

    test('it does not overclaim that message text never leaves the device', () {
      // capture_sync_service sends SmsSanitizer.sanitize(text) to the backend
      // when cloudProcessingEnabled is on, and the server persists it. An
      // earlier draft said "not sent to any AI provider" full stop — a false
      // privacy promise, which is worse than no promise.
      expect(policy.toLowerCase(), contains('sanitized'));
      expect(policy.toLowerCase(), contains('does leave your device'));
      expect(policy.toLowerCase(), contains('separate consent'));
    });

    test('sanitization is described accurately, not vaguely', () {
      // The policy must name what is stripped, because the user cannot inspect
      // the payload and "sanitized" alone means nothing to them.
      for (final claim in const [
        'full card numbers',
        'phone numbers',
        'account numbers',
      ]) {
        expect(policy.toLowerCase(), contains(claim));
      }
    });

    test('the localized disclosure makes the same claim in both locales', () {
      // A disclosure that overclaims in one language is still an overclaim.
      for (final arb in const ['lib/l10n/app_ar.arb', 'lib/l10n/app_en.arb']) {
        final content = File(arb).readAsStringSync();
        expect(content, contains('smsDisclosureOnDevice'));
        expect(content.contains('No message text is sent to any AI provider'),
            isFalse,
            reason: '\$arb still carries the corrected-away absolute claim');
      }
    });
  });
  // ── REACHABILITY ─────────────────────────────────────────────────────────
  //
  // Every test above proves the enable path is CORRECT. For months none of
  // them noticed it was also UNREACHABLE: the manifest declared RECEIVE_SMS,
  // the receiver was registered, the service and the disclosure both existed —
  // and no UI called any of it, so a user could never switch the feature on.
  //
  // That is not a cosmetic gap. Google Play requires a declared restricted
  // permission to enable core functionality a reviewer can actually exercise,
  // and the privacy policy was already live telling users the app captures
  // bank SMS. A correct feature nobody can reach fails both.
  group('the enable path is reachable from production code', () {
    Iterable<File> libDart() => Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    int callersOf(String symbol, String declaredIn) {
      var n = 0;
      for (final f in libDart()) {
        final path = f.path.replaceAll(r'\\', '/');
        if (path.endsWith(declaredIn)) continue;
        if (f.readAsStringSync().contains(symbol)) n++;
      }
      return n;
    }

    test('AndroidSmsCaptureService has at least one production caller', () {
      expect(
        callersOf('AndroidSmsCaptureService',
            'features/capture/services/android_sms_capture_service.dart'),
        greaterThan(0),
        reason: 'the service exists but nothing calls it — the feature would '
            'ship unreachable, exactly as it did before MALI-013 was wired',
      );
    });

    test('the disclosure is shown from production code, not only tests', () {
      expect(
        callersOf('showSmsCaptureDisclosure',
            'features/capture/widgets/sms_capture_disclosure.dart'),
        greaterThan(0),
        reason: 'Play requires the disclosure immediately before the system '
            'dialog; a disclosure with no caller means no compliant path',
      );
    });

    test('the toggle renders from the platform, not a stored local flag', () {
      // A cached bool would leave the switch ON for a permission Android has
      // already revoked — the app claiming to read a user's bank messages when
      // it cannot.
      final providers =
          File('lib/features/settings/settings_providers.dart').readAsStringSync();
      expect(providers, contains('captureCapabilitiesProvider'));
      expect(providers, contains('AndroidSmsCaptureService.instance.capabilities()'));
    });

    test('Settings no longer claims the app does not read SMS', () {
      final settings =
          File('lib/features/settings/settings_screen.dart').readAsStringSync();
      expect(settings.contains('ولا يقرأ إشعارات البنك أو رسائل SMS من النظام'),
          isFalse,
          reason: 'that sentence was false as a description of what this build '
              'implements and declares');
      expect(settings, contains('smsCaptureTrustNotice'),
          reason: 'the replacement copy must come from l10n, not be inlined');
    });
  });

}
