import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/backend/supabase_config.dart';
import '../../../core/privacy/cloud_egress_gate.dart';
import '../../../core/privacy/consent_authority.dart';
import '../../../core/utils/install_id.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import 'capture_backend_client.dart';
import 'capture_device_registration_service.dart';
import 'capture_import_ports.dart';
import 'capture_sync_service.dart';
import 'native_capture_bridge.dart';

/// `sync-captures` on the v2 contract: `schema_version: 2` plus the user JWT, so
/// the server scopes the call to `jwt.uid == device user == claimed_user_id`
/// (§4.8). A separate class on purpose: [CaptureBackendClient] keeps the
/// legacy (build-50) request shape untouched.
class CaptureSyncV2Client {
  CaptureSyncV2Client({
    required String supabaseUrl,
    required String anonKey,
    http.Client? httpClient,
  })  : _supabaseUrl = supabaseUrl,
        _anonKey = anonKey,
        _http = httpClient ?? GatedHttpClient();

  final String _supabaseUrl;
  final String _anonKey;
  final http.Client _http;

  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    required String jwt,
    List<String> ackPayloadIds = const [],
  }) async {
    final response = await _http
        .post(
          Uri.parse('$_supabaseUrl/functions/v1/sync-captures'),
          headers: {
            'Content-Type': 'application/json',
            'apikey': _anonKey,
            'Authorization': 'Bearer $jwt',
          },
          body: jsonEncode({
            'installId': installId,
            'deviceSecret': deviceSecret,
            'ackPayloadIds': ackPayloadIds,
            'schema_version': 2,
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw CaptureBackendException('sync_failed_${response.statusCode}');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      decoded = null;
    }
    final captures = decoded is Map ? decoded['captures'] : null;
    // Unknown is not empty: see CaptureBackendClient.syncCaptures.
    if (captures is! List) {
      throw const CaptureBackendException('sync_failed_malformed');
    }
    return [
      for (final item in captures)
        if (item is Map)
          ProcessedCaptureDto.fromJson(Map<String, dynamic>.from(item)),
    ];
  }
}

/// [CaptureServerPort] over the capture edge functions. Cloud off, an
/// unconfigured backend or a missing device secret is [CaptureFetchStatus.notConfigured]:
/// nothing is sent and the device parses locally.
class BackendCaptureServerPort implements CaptureServerPort {
  BackendCaptureServerPort({
    required DriftUserSettingsRepository settingsRepository,
    required CaptureDeviceRegistrationService registrationService,
    required CaptureSyncService captureSyncService,
    CaptureBackendClient? client,
    CaptureSyncV2Client? v2Client,
    bool? backendConfigured,
    Future<String> Function()? loadInstallId,
    Future<bool> Function()? useContractV2,
    Future<String?> Function()? accessToken,
  })  : _settings = settingsRepository,
        _registration = registrationService,
        _sync = captureSyncService,
        _client = client,
        _v2Client = v2Client,
        _backendConfigured = backendConfigured,
        _loadInstallId = loadInstallId,
        _useContractV2 = useContractV2,
        _accessToken = accessToken;

  final DriftUserSettingsRepository _settings;
  final CaptureDeviceRegistrationService _registration;
  final CaptureSyncService _sync;
  final CaptureBackendClient? _client;
  final CaptureSyncV2Client? _v2Client;
  final bool? _backendConfigured;
  final Future<String> Function()? _loadInstallId;
  final Future<bool> Function()? _useContractV2;
  final Future<String?> Function()? _accessToken;

  Future<({String installId, String secret})?> _credentials() async {
    final settings = await _settings.getSettings();
    final configured = _backendConfigured ?? SupabaseConfig.isConfigured;
    if (!settings.cloudProcessingEnabled ||
        !configured ||
        ConsentAuthority.egressFrozen) {
      return null;
    }
    await _registration.syncBackendState();
    // A-12-min R5: no legacy device-credential call (fetch, ACK) without a
    // uid-bound ack for this user at Cloud ON; "not configured" imports locally.
    if (!await _registration.isLinkedForCloud()) return null;
    final secret = await _registration.readDeviceSecret();
    if (secret == null || secret.isEmpty) return null;
    return (
      installId: await (_loadInstallId ?? InstallId.get)(),
      secret: secret,
    );
  }

  CaptureBackendClient get _legacy =>
      _client ??
      CaptureBackendClient(
        supabaseUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
      );

  CaptureSyncV2Client get _v2 =>
      _v2Client ??
      CaptureSyncV2Client(
        supabaseUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
      );

  Future<List<ProcessedCaptureDto>> _call(
    ({String installId, String secret}) credentials,
    List<String> ackIds,
  ) async {
    if (await (_useContractV2?.call() ?? Future.value(false))) {
      final jwt = await _accessToken?.call();
      if (jwt == null || jwt.isEmpty) {
        throw const CaptureBackendException('sync_failed_401');
      }
      return _v2.syncCaptures(
        installId: credentials.installId,
        deviceSecret: credentials.secret,
        jwt: jwt,
        ackPayloadIds: ackIds,
      );
    }
    return _legacy.syncCaptures(
      installId: credentials.installId,
      deviceSecret: credentials.secret,
      ackPayloadIds: ackIds,
    );
  }

  static int? _statusOf(CaptureBackendException e) =>
      int.tryParse(e.reason.split('_').last);

  @override
  Future<CaptureServerFetch> fetchResults() async {
    final credentials = await _credentials();
    if (credentials == null) {
      return const CaptureServerFetch(CaptureFetchStatus.notConfigured);
    }
    try {
      final captures = await _call(credentials, const []);
      return CaptureServerFetch(CaptureFetchStatus.ok, {
        for (final c in captures)
          if (c.payloadId.isNotEmpty) c.payloadId: c,
      });
    } on CaptureBackendException catch (e) {
      final status = _statusOf(e);
      return CaptureServerFetch(
        status == 401 || status == 403 || status == 409
            ? CaptureFetchStatus.refused
            : CaptureFetchStatus.unavailable,
      );
    } catch (_) {
      return const CaptureServerFetch(CaptureFetchStatus.unavailable);
    }
  }

  @override
  Future<CaptureUploadStatus> retryUpload(SharedCapturedMessage message) async {
    try {
      // Any status: the import service decides which items need an upload.
      return await _sync.retryPendingSend(message, true)
          ? CaptureUploadStatus.sent
          : CaptureUploadStatus.notAllowed;
    } on CaptureBackendException catch (e) {
      final status = _statusOf(e);
      if (status == 429) return CaptureUploadStatus.rateLimited;
      return status == 409
          ? CaptureUploadStatus.conflict
          : CaptureUploadStatus.unavailable;
    } catch (_) {
      return CaptureUploadStatus.unavailable;
    }
  }

  @override
  Future<void> acknowledge(List<String> payloadIds) async {
    if (payloadIds.isEmpty) return;
    final credentials = await _credentials();
    if (credentials == null) return;
    try {
      await _call(credentials, payloadIds);
    } catch (_) {
      // Best-effort: the receipt makes the next run's ack idempotent.
    }
  }
}
