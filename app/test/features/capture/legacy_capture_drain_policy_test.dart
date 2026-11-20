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
  group('AI not selected (Smart Analysis off, or a localOnly item)', () {
    // Gemini-first phase 3 (owner decision): on iOS nothing is sent and the
    // device's own reading records nothing; the message waits for Smart
    // Analysis (or the person records it). Never an upload or an AI request.
    test('iOS: every item with a payload id waits for Smart Analysis', () {
      for (final status in ['sent', 'pendingSend', 'pending', null]) {
        expect(
            route(
                aiSelected: false,
                status: status,
                uploadsNatively: true,
                mayUseAiFallback: true),
            LegacyDrainRoute.awaitSmartAnalysis);
      }
    });

    test('Android, or an item without a payload id: ingested on device', () {
      for (final status in ['sent', 'pendingSend', 'pending', null]) {
        expect(
            route(
                aiSelected: false,
                status: status,
                uploadsNatively: false,
                mayUseAiFallback: true),
            LegacyDrainRoute.ingest);
        expect(
            route(
                aiSelected: false,
                status: status,
                hasPayloadId: false,
                mayUseAiFallback: true),
            LegacyDrainRoute.ingest);
      }
    });

    test('never an upload or an AI request', () {
      for (final native in [true, false]) {
        for (final status in ['sent', 'pendingSend', 'pending', null]) {
          final r = route(
              aiSelected: false,
              status: status,
              uploadsNatively: native,
              mayUseAiFallback: true);
          expect(r, isNot(LegacyDrainRoute.upload));
          expect(r, isNot(LegacyDrainRoute.ingestWithAi));
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
