// F6 — capture recovery triggers that the platforms actually support while the
// app is in the FOREGROUND: the adaptive poll, and Android telling Dart about a
// newly stored capture while its activity is alive. No background execution is
// added or claimed (no WorkManager, no BGTask, no background modes).
//
// The drain lives in the AppShell widget State and the wake-up in Kotlin, so
// these are structural assertions plus the Dart side of the channel.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const dir = 'android/app/src/main/kotlin/com/example/money_companion';
  final shell = File('lib/features/app/app_shell.dart').readAsStringSync();
  final activity = File('$dir/MainActivity.kt').readAsStringSync();
  final queue = File('$dir/DurableCaptureQueue.kt').readAsStringSync();

  String body(String source, String signature) {
    final at = source.indexOf(signature);
    expect(at, greaterThan(-1), reason: '$signature not found');
    final open = source.indexOf('{', at + signature.length);
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}' && --depth == 0) return source.substring(open, i + 1);
    }
    fail('unbalanced braces after $signature');
  }

  group('adaptive foreground poll', () {
    test('the poll re-drives the capture drain', () {
      expect(body(shell, 'void _scheduleAdaptivePoll()'),
          contains('_drainQueuedCapturesOnPoll()'),
          reason: 'a returned connection or an SMS received on screen must '
              'not wait for the next resume');
    });

    test('it drains only when admitted and the native queue is non-empty', () {
      final poll = body(shell, 'Future<void> _drainQueuedCapturesOnPoll()');
      final admitted = poll.indexOf('AdmittedLocalWork.capture(ref) == null');
      final peek = poll.indexOf('peekPendingSharedMessages()');
      final drain = poll.indexOf('_consumeSharedInput()');
      expect(admitted, greaterThan(-1));
      expect(peek, greaterThan(admitted));
      expect(drain, greaterThan(peek),
          reason: 'an empty queue must cost no network request');
      expect(poll, contains('queued.isEmpty'));
      final due = poll.indexOf('await retryLedger.isDue(id)');
      expect(due, greaterThan(peek));
      expect(drain, greaterThan(poll.indexOf('if (!anyDue || !mounted) return;')),
          reason: 'items inside their backoff window do not trigger a drain');
    });

    test('the poll authorizes nothing: consent stays inside the drain', () {
      final poll = body(shell, 'Future<void> _drainQueuedCapturesOnPoll()');
      for (final forbidden in [
        'processIosSms',
        'retryPendingSend',
        'aiConsent',
        'onDeviceOnly: false',
      ]) {
        expect(poll.contains(forbidden), isFalse, reason: forbidden);
      }
      expect(
          File('lib/features/capture/services/legacy_capture_drain.dart')
              .readAsStringSync(),
          contains('EgressClass.aiProcessing'),
          reason: 'consent is read inside the drain, per message');
    });
  });

  group('Android wake-up while the activity is alive', () {
    test('a stored capture notifies Dart over the capture channel', () {
      expect(activity,
          contains('invokeMethod("pendingSharedMessagesAvailable", null)'));
      expect(activity, contains('DurableCaptureQueue.onStored = {'));
      final enqueue = body(queue, 'fun enqueue(item: Item)');
      expect(enqueue.indexOf('onStored?.invoke()'),
          greaterThan(enqueue.indexOf('if (!stored) return notPersisted()')),
          reason: 'Dart is told only after the item is durably stored');
    });

    test('the listener is dropped with the engine', () {
      expect(body(activity, 'override fun cleanUpFlutterEngine('),
          contains('DurableCaptureQueue.onStored = null'));
    });

    test('Dart drains when the native side says captures are pending',
        () async {
      var drains = 0;
      NativeCaptureBridge.setPendingMessagesHandler(() async => drains++);
      addTearDown(() => NativeCaptureBridge.setPendingMessagesHandler(null));
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'money_companion/native_capture',
        const StandardMethodCodec().encodeMethodCall(
            const MethodCall('pendingSharedMessagesAvailable')),
        (_) {},
      );
      expect(drains, 1);
    });
  });

  group('no background execution is added', () {
    test('Android: no WorkManager, job or foreground service', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      for (final forbidden in ['WorkManager', 'JobService', 'foregroundService']) {
        expect(manifest.contains(forbidden), isFalse, reason: forbidden);
      }
      expect(gradle.contains('work-runtime'), isFalse);
    });

    test('iOS: no background modes or BGTask identifiers', () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();
      expect(plist.contains('UIBackgroundModes'), isFalse);
      expect(plist.contains('BGTaskSchedulerPermittedIdentifiers'), isFalse);
    });
  });

  test('Android queue health carries counts only', () {
    final health = AndroidCaptureQueueHealth.fromJson(const {
      'size': 3,
      'capacity': 2000,
      'refusedFull': 0,
      'notPersisted': 3,
      'quarantined': 1,
      'unseen': 3,
    });
    expect(health.unseen, 3);
    expect(health.refusedFull + health.notPersisted, 3);
    expect(body(shell, 'Future<void> _surfaceAndroidQueueRefusals()'),
        contains('context.l10n.captureQueueNotSaved'));
  });
}
