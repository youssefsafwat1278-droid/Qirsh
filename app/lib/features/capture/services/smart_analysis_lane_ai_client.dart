import 'dart:io' show Platform;

import '../../../core/privacy/consent_authority.dart';
import '../../../core/privacy/smart_analysis_consent.dart';
import '../../../domain/entities/supporting_entities.dart';
import '../../../engine/ai/ai_parser_client.dart';
import 'capture_device_registration_service.dart' show inSmartAnalysisLane;

/// Gemini-first phase 3: the in-app analysis request (`parse-sms`) of a person
/// with smart-analysis consent and Cloud OFF goes through the gate's
/// smart-analysis lane. With Cloud ON (or no such consent) the request is made
/// exactly as before; the gate then decides as it always did.
class SmartAnalysisLaneAiParserClient
    implements PrimaryAiParserClient, ContextualAiParserClient {
  SmartAnalysisLaneAiParserClient(this._inner, {required this.laneOwner});

  final ContextualAiParserClient _inner;

  /// The lane's owner for the next request, or null for no lane.
  final Future<String?> Function() laneOwner;

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async =>
      inSmartAnalysisLane(
          await laneOwner(),
          () => _inner.parse(
              sanitizedSms: sanitizedSms,
              senderId: senderId,
              installId: installId));

  @override
  Future<AiParseResponse?> parseWithContext({
    required String sanitizedSms,
    required String senderId,
    required String installId,
    required AiParseContext context,
  }) async =>
      inSmartAnalysisLane(
          await laneOwner(),
          () => _inner.parseWithContext(
              sanitizedSms: sanitizedSms,
              senderId: senderId,
              installId: installId,
              context: context));
}

/// The lane owner of the in-app request: the signed-in account ([uid]) on iOS,
/// read fresh, while its settings hold smart-analysis consent with Cloud OFF,
/// given to the Smart Analysis wording ([record]; a dormant pre-phase-3 AI
/// choice never opens the lane). Null otherwise (Android, Cloud ON, no
/// consent, signed out, an unreadable record).
Future<String?> Function() smartAnalysisRequestLane({
  required Future<UserSettingsEntity> Function() settings,
  required String? Function() uid,
  bool Function()? isIos,
  SmartAnalysisConsentRecord? record,
}) =>
    () async {
      if (!(isIos ?? () => Platform.isIOS)()) return null;
      final s = await settings();
      if (s.cloudProcessingEnabled ||
          !ConsentAuthority.decide(EgressClass.smartAnalysis, s)) {
        return null;
      }
      final owner = uid();
      if (owner == null || owner.isEmpty) return null;
      try {
        return await (record ?? SmartAnalysisConsentRecord()).hasRecord(owner)
            ? owner
            : null;
      } catch (_) {
        return null;
      }
    };
