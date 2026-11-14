import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/privacy/cloud_egress_gate.dart';
import 'capture_backend_client.dart';

/// WP-6 — the v2 (JWT) consent contract of the capture backend: both calls carry
/// the device secret AND the user's JWT, and a monotonically increasing version.
/// Kept apart from [CaptureBackendClient] so the build-50 (device-secret only)
/// contract and its fakes stay untouched.
class CaptureConsentClient {
  CaptureConsentClient({
    required String supabaseUrl,
    required String anonKey,
    http.Client? httpClient,
  })  : _supabaseUrl = supabaseUrl,
        _anonKey = anonKey,
        _http = httpClient ?? GatedHttpClient();

  final String _supabaseUrl;
  final String _anonKey;
  final http.Client _http;

  Uri _uri(String name) => Uri.parse('$_supabaseUrl/functions/v1/$name');

  Map<String, String> _headers(String jwt) => {
        'Content-Type': 'application/json',
        'apikey': _anonKey,
        'Authorization': 'Bearer $jwt',
      };

  /// `link-capture-device` v2: binds the install to the JWT's user and REPLACES
  /// the consent projection (owner, both flags, version) in one statement.
  Future<void> link({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
    // C.2: the client transition generation, so a late link can never widen
    // consent over a newer disable (`p_client_generation`).
    required int clientGeneration,
  }) async {
    final response = await _http
        .post(
          _uri('link-capture-device'),
          headers: _headers(jwt),
          body: jsonEncode({
            'installId': installId,
            'deviceSecret': deviceSecret,
            'schema_version': 2,
            'consent': {
              'cloud_processing_enabled': cloud,
              'ai_consent_granted': ai,
              'version': version,
              'client_generation': clientGeneration,
            },
          }),
        )
        .timeout(const Duration(seconds: 12));
    _requireApplied(response, 'link_device');
  }

  /// `set-device-consent` v2: owner-scoped, applied only when [version] is newer
  /// than the stored one. A revocation fans out server-side in the same call.
  Future<void> setConsent({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
    required int clientGeneration,
  }) async {
    final response = await _http
        .post(
          _uri('set-device-consent'),
          headers: _headers(jwt),
          body: jsonEncode({
            'installId': installId,
            'deviceSecret': deviceSecret,
            'schema_version': 2,
            'cloud_processing_enabled': cloud,
            'ai_consent_granted': ai,
            'consent_version': version,
            'client_generation': clientGeneration,
          }),
        )
        .timeout(const Duration(seconds: 12));
    _requireApplied(response, 'set_consent');
  }

  void _requireApplied(http.Response response, String operation) {
    if (response.statusCode != 200) {
      throw CaptureBackendException(
          '${operation}_failed_${response.statusCode}');
    }
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['ok'] == true && body['applied'] == true) return;
    } on FormatException {
      throw CaptureBackendException('${operation}_invalid_receipt');
    }
    throw CaptureBackendException('${operation}_not_applied');
  }

  /// Astra G C.3: the ONE-SHOT revoke (`revoke_capture_consent`, JWT required;
  /// narrows only; idempotent per (install, owner, transition_generation)).
  /// Isolated behind this single method and [kRevokeRoute] so the edge route
  /// name G1 chooses is a one-line change. The caller makes at most one call per
  /// transition and never retries it.
  Future<RevokeResult> revoke({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required String ownerUid,
    required int transitionGeneration,
    required int version,
  }) async {
    final response = await _http
        .post(
          _uri(kRevokeRoute),
          headers: _headers(jwt),
          body: jsonEncode({
            'installId': installId,
            'deviceSecret': deviceSecret,
            'schema_version': 2,
            'action': 'revoke',
            'owner_uid': ownerUid,
            'transition_generation': transitionGeneration,
            'consent_version': version,
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw CaptureBackendException('revoke_failed_${response.statusCode}');
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        return RevokeResult(
          ok: decoded['ok'] == true,
          applied: decoded['applied'] == true,
          reason:
              decoded['reason'] is String ? decoded['reason'] as String : null,
        );
      }
    } catch (_) {}
    return const RevokeResult(ok: false, applied: false);
  }

  /// The Edge Function that exposes `revoke_capture_consent` (G1 decides:
  /// `set-device-consent` v2 `action: 'revoke'`, or a new function).
  static const String kRevokeRoute = 'set-device-consent';
}

/// `{ok, applied, reason}` as the revoke RPC returns it. Only `ok && applied` is
/// a CONFIRMED server revocation.
class RevokeResult {
  const RevokeResult({required this.ok, required this.applied, this.reason});
  final bool ok;
  final bool applied;
  final String? reason;
}
