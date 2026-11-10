import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

/// CAP-7 + A6 bridge contract against a fake native channel. The native side is
/// ios/Runner/AppDelegate.swift; test/architecture/capture_notify_v2_contract_test.dart
/// pins that the same method names exist there.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('money_companion/native_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  void fake(Future<Object?> Function(MethodCall call) handler) {
    calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() => NativeCaptureBridge.debugTreatHostAsNative = true);
  tearDown(() {
    NativeCaptureBridge.debugTreatHostAsNative = false;
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('peekLegacyCaptureItems (A6)', () {
    test('maps id, raw text and the receive time; falls back to createdAt',
        () async {
      fake((_) async => [
            {
              'id': 'a',
              'text': 'raw a',
              'receivedAt': '2026-04-08T09:45:00.000Z',
              'createdAt': '2026-04-09T00:00:00.000Z',
            },
            {
              'id': 'b',
              'text': 'raw b',
              'createdAt': '2026-04-09T00:00:00.000Z'
            },
            {'id': 'c', 'text': 'raw c'},
            {'id': 7, 'text': 'bad'},
            'junk',
          ]);
      final items = await NativeCaptureBridge.peekLegacyCaptureItems();
      expect(calls.single.method, 'peekLegacyCaptureItems');
      expect(items.map((i) => i.id), ['a', 'b', 'c']);
      expect(items[0].text, 'raw a');
      expect(items[0].receivedAt, DateTime.utc(2026, 4, 8, 9, 45));
      expect(items[1].receivedAt, DateTime.utc(2026, 4, 9));
      expect(items[2].receivedAt, isNull);
    });

    test('a native refusal is "no items", not a crash', () async {
      fake((_) async =>
          throw PlatformException(code: 'queue_unavailable', message: 'x'));
      expect(await NativeCaptureBridge.peekLegacyCaptureItems(), isEmpty);
    });

    test('off iOS it does not touch the channel', () async {
      NativeCaptureBridge.debugTreatHostAsNative = false;
      fake((_) async => []);
      expect(await NativeCaptureBridge.peekLegacyCaptureItems(), isEmpty);
      expect(calls, isEmpty);
    });
  });

  group('CAP-7 channel calls', () {
    test(
        'notification language uses the app choice and defaults unsupported languages to English',
        () async {
      fake((_) async => null);
      await NativeCaptureBridge.setNotificationLanguage('ar_EG');
      await NativeCaptureBridge.setNotificationLanguage('en');
      await NativeCaptureBridge.setNotificationLanguage('fr');
      expect(
          calls.map((c) => c.method), everyElement('setNotificationLanguage'));
      expect(calls.map((c) => c.arguments), [
        {'language': 'ar'},
        {'language': 'en'},
        {'language': 'en'},
      ]);
      fake((_) async => throw PlatformException(code: 'unavailable'));
      await NativeCaptureBridge.setNotificationLanguage('ar');
    });

    test('setCaptureNotifyV2 passes the flag; a failure is swallowed',
        () async {
      fake((_) async => null);
      await NativeCaptureBridge.setCaptureNotifyV2(true);
      expect(calls.single.method, 'setCaptureNotifyV2');
      expect(calls.single.arguments, {'enabled': true});

      fake((_) async => throw PlatformException(code: 'x'));
      await NativeCaptureBridge.setCaptureNotifyV2(false);
    });

    test('withdrawDeliveredCaptureAlert is true only when one was delivered',
        () async {
      fake((_) async => true);
      expect(await NativeCaptureBridge.withdrawDeliveredCaptureAlert('id1'),
          isTrue);
      expect(calls.single.arguments, {'payloadId': 'id1'});
      fake((_) async => null);
      expect(await NativeCaptureBridge.withdrawDeliveredCaptureAlert('id1'),
          isFalse);
      fake((_) async => throw PlatformException(code: 'x'));
      expect(await NativeCaptureBridge.withdrawDeliveredCaptureAlert('id1'),
          isFalse);
    });
  });
}
