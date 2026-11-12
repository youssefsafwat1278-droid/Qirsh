// The legacy native drain's per-message routing rule (pure function). Its
// execution is covered end to end by legacy_capture_drain_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/legacy_capture_drain_policy.dart';

LegacyDrainRoute route({
  bool aiSelected = true,
  String? status,
  bool hasPayloadId = true,
  String? failureReason,
  bool mayUseAiFallback = false,
  bool uploadsNatively = true,
  bool inAppAiEnabled = true,
  bool relayResultUnknown = false,
}) =>
    legacyDrainRoute(
      aiSelected: aiSelected,
      status: status,
      hasPayloadId: hasPayloadId,
      failureReason: failureReason,
      mayUseAiFallback: mayUseAiFallback,
      uploadsNatively: uploadsNatively,
      inAppAiEnabled: inAppAiEnabled,
      relayResultUnknown: relayResultUnknown,
    );

void main() {
  group('AI not selected (Cloud or AI consent off, or a localOnly item)', () {
    test('every item is ingested on device, whatever else is true', () {
      for (final native in [true, false]) {
        for (final status in ['sent', 'pendingSend', 'pending', null]) {
          expect(
              route(
                  aiSelected: false,
                  status: status,
                  uploadsNatively: native,
                  mayUseAiFallback: true),
              LegacyDrainRoute.ingest);
        }
      }
    });
  });

  group('Android (no native upload pipeline), AI selected', () {
    test('analysed by the in-app AI when the kill switch and consent allow',
        () {
      expect(route(uploadsNatively: false), LegacyDrainRoute.ingestWithAi);
    });

    test('kill switch off / AI not allowed: deterministic, on device', () {
      expect(route(uploadsNatively: false, inAppAiEnabled: false),
          LegacyDrainRoute.ingestOnDevice);
    });

    test('it is never uploaded through the iOS relay', () {
      for (final status in ['sent', 'pendingSend', 'pending', null]) {
        expect(route(uploadsNatively: false, status: status),
            isNot(LegacyDrainRoute.upload));
      }
    });
  });

  group('iOS, AI selected', () {
    test('a pendingSend item is replayed with its own payload id', () {
      expect(
          route(status: 'pendingSend', failureReason: 'ai_primary_pending'),
          LegacyDrainRoute.upload);
    });

    test('items the server never received are uploaded, not parked', () {
      expect(route(status: 'pending'), LegacyDrainRoute.upload); // share
      expect(route(status: 'sent'), LegacyDrainRoute.upload); // .waiting
      expect(route(status: 'sent', failureReason: 'timeout'),
          LegacyDrainRoute.upload);
    });

    test('a capture refused for good at capture time stays on device', () {
      expect(route(status: 'sent', failureReason: 'http(409)'),
          LegacyDrainRoute.ingestOnDevice);
    });

    test('F8: a sent item waits while the relay result is unknown', () {
      expect(route(status: 'sent', relayResultUnknown: true),
          LegacyDrainRoute.wait);
      expect(
          route(
              status: 'sent',
              failureReason: 'timeout',
              relayResultUnknown: true),
          LegacyDrainRoute.upload,
          reason: 'the server never analysed it: there is no result to wait '
              'for');
    });

    test('the shipped consented AI fallback candidate keeps its route', () {
      expect(
          route(
              status: 'sent', failureReason: 'timeout', mayUseAiFallback: true),
          LegacyDrainRoute.ingestWithAi);
    });

    test('no payload id: ingested on device (nothing idempotent to upload)',
        () {
      expect(route(status: 'sent', hasPayloadId: false),
          LegacyDrainRoute.ingest);
    });
  });
}
