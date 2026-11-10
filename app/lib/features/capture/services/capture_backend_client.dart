import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/privacy/cloud_egress_gate.dart';
class CaptureBackendClient {
  CaptureBackendClient({
    required String supabaseUrl,
    required String anonKey,
    http.Client? httpClient,
    Duration processIosSmsTimeout = const Duration(seconds: 25),
    bool notificationDetails = false,
  })  : _supabaseUrl = supabaseUrl,
        _anonKey = anonKey,
        _http = httpClient ?? GatedHttpClient(),
        _processIosSmsTimeout = processIosSmsTimeout,
        _notificationDetails = notificationDetails;

  final String _supabaseUrl;
  final String _anonKey;
  final http.Client _http;
  final Duration _processIosSmsTimeout;
  final bool _notificationDetails;

  Uri _functionUri(String name) =>
      Uri.parse('$_supabaseUrl/functions/v1/$name');

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'apikey': _anonKey,
        'Authorization': 'Bearer $_anonKey',
      };

  Future<String> registerDevice({
    required String installId,
    String platform = 'ios',
  }) async {
    final response = await _http
        .post(
          _functionUri('register-device'),
          headers: _headers,
          body: jsonEncode({
            'installId': installId,
            'platform': platform,
          }),
        )
        .timeout(const Duration(seconds: 12));
    final json = _decode(response);
    final secret = json['deviceSecret'] as String?;
    if (response.statusCode != 200 || secret == null || secret.isEmpty) {
      throw CaptureBackendException('register_failed_${response.statusCode}');
    }
    return secret;
  }

  /// MALI-060n — pushes this device's consent to the server so the AI/paid
  /// endpoints can enforce it authoritatively. Consent is never a per-request
  /// caller-supplied boolean; it lives on the verified capture_devices row.
  Future<void> setDeviceConsent({
    required String installId,
    required String deviceSecret,
    required bool aiConsentGranted,
    required bool cloudProcessingEnabled,
  }) async {
    final response = await _http
        .post(
          _functionUri('set-device-consent'),
          headers: _headers,
          body: jsonEncode({
            'installId': installId,
            'deviceSecret': deviceSecret,
            'ai_consent_granted': aiConsentGranted,
            'cloud_processing_enabled': cloudProcessingEnabled,
            'schema_version': 1,
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw CaptureBackendException(
          'set_consent_failed_${response.statusCode}');
    }
  }

  Future<void> linkDevice({
    required String installId,
    required String deviceSecret,
    required String jwt,
  }) async {
    final response = await _http
        .post(
          _functionUri('link-capture-device'),
          headers: {
            ..._headers,
            'Authorization': 'Bearer $jwt',
          },
          body: jsonEncode({
            'installId': installId,
            'deviceSecret': deviceSecret,
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw CaptureBackendException(
        'link_device_failed_${response.statusCode}',
      );
    }
  }

  Future<void> unlinkDevice({
    required String installId,
    required String deviceSecret,
  }) async {
    final response = await _http
        .post(
          _functionUri('unlink-capture-device'),
          headers: _headers,
          body: jsonEncode({
            'installId': installId,
            'deviceSecret': deviceSecret,
          }),
        )
        .timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) {
      throw CaptureBackendException(
        'unlink_device_failed_${response.statusCode}',
      );
    }
  }

  Future<void> registerPushToken({
    required String installId,
    required String deviceSecret,
    required String apnsToken,
    required String apnsEnvironment,
  }) async {
    final response = await _http
        .post(
          _functionUri('register-push-token'),
          headers: _headers,
          body: jsonEncode({
            'installId': installId,
            'deviceSecret': deviceSecret,
            'apnsToken': apnsToken,
            'apnsEnvironment': apnsEnvironment,
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw CaptureBackendException(
        'register_push_failed_${response.statusCode}',
      );
    }
  }

  /// Replays a durable native `pendingSend` payload with its original
  /// idempotency key. A 2xx response is a definitive terminal acknowledgement.
  Future<void> processIosSms({
    required String installId,
    required String deviceSecret,
    required String payloadId,
    required String smsText,
    required DateTime receivedAt,
    required bool allowAi,
    String? sender,
    String? locale,
    // C.1: the stamped owner and the owner generation the item was stamped
    // under are ALWAYS sent (an ownerless upload is impossible). `schemaV2`
    // only selects the schema marker; the owner fields ride on both versions.
    required String ownerUid,
    required int ownerGeneration,
    bool schemaV2 = false,
  }) async {
    final response = await _http
        .post(
          _functionUri('process-ios-sms'),
          headers: _headers,
          body: jsonEncode({
            'installId': installId,
            'deviceSecret': deviceSecret,
            'payloadId': payloadId,
            'smsText': smsText,
            'sanitizedText': smsText,
            'sender': sender,
            'receivedAt': receivedAt.toUtc().toIso8601String(),
            'locale': locale,
            'tzOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
            'allowAi': allowAi,
            'notificationDetails': _notificationDetails,
            if (allowAi) 'analysis_mode': 'ai_primary_v1',
            if (allowAi) 'backgroundAnalysis': true,
            if (allowAi) 'localNotification': false,
            if (schemaV2) 'schema_version': 2,
            'owner_uid': ownerUid,
            'owner_generation': ownerGeneration,
          }),
        )
        // Unlike the App Intent's strict 8-second budget, this replay runs
        // after Flutter is open. Give a cold Edge Function enough time for
        // bounded AI parsing and APNs without forcing another app resume.
        .timeout(_processIosSmsTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CaptureBackendException(
        'process_ios_sms_failed_${response.statusCode}',
      );
    }
  }

  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    List<String> ackPayloadIds = const [],
  }) async {
    final response = await _http
        .post(
          _functionUri('sync-captures'),
          headers: _headers,
          body: jsonEncode({
            'installId': installId,
            'deviceSecret': deviceSecret,
            'ackPayloadIds': ackPayloadIds,
          }),
        )
        .timeout(const Duration(seconds: 12));
    final json = _decode(response);
    if (response.statusCode != 200) {
      throw CaptureBackendException('sync_failed_${response.statusCode}');
    }
    final captures = json['captures'];
    if (captures is! List) return const [];
    return [
      for (final item in captures)
        if (item is Map)
          ProcessedCaptureDto.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  static Map<String, dynamic> _decode(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}

class ProcessedCaptureDto {
  const ProcessedCaptureDto({
    required this.payloadId,
    required this.status,
    required this.parsed,
    required this.notification,
    this.sanitizedText,
    this.failureReason,
    this.createdAt,
    this.state,
  });

  final String payloadId;
  final String status;
  final Map<String, dynamic> parsed;
  final Map<String, dynamic> notification;
  final String? sanitizedText;
  final String? failureReason;
  final DateTime? createdAt;

  /// v2 contract only: `processed` | `rejected` | `retryable`. Null on the
  /// legacy contract, which carries `status` alone.
  final String? state;

  factory ProcessedCaptureDto.fromJson(Map<String, dynamic> json) {
    return ProcessedCaptureDto(
      payloadId: json['payload_id'] as String? ?? '',
      status: json['status'] as String? ?? 'rejected',
      parsed: json['parsed'] is Map
          ? Map<String, dynamic>.from(json['parsed'] as Map)
          : const {},
      notification: json['notification'] is Map
          ? Map<String, dynamic>.from(json['notification'] as Map)
          : const {},
      sanitizedText: json['sanitized_text'] as String?,
      failureReason: json['failure_reason'] as String?,
      createdAt: json['created_at'] is String
          ? DateTime.tryParse(json['created_at'] as String)?.toUtc()
          : null,
      state: json['state'] as String?,
    );
  }
}

class CaptureBackendException implements Exception {
  const CaptureBackendException(this.reason);

  final String reason;

  @override
  String toString() => 'CaptureBackendException($reason)';
}
