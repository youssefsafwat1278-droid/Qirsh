import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/privacy/cloud_egress_gate.dart';

import '../../core/utils/id_generator.dart';

class AiParseException implements Exception {
  const AiParseException(this.reason);

  final String reason;

  @override
  String toString() => 'AiParseException($reason)';
}

class AiParseResponse {
  const AiParseResponse({
    required this.amount,
    required this.currency,
    this.amountText,
    this.merchantName,
    this.type,
    this.categoryKey,
    this.direction,
    this.occurredAt,
    this.modelUsed,
    this.promptVersion,
    this.messageType,
    this.status,
    this.currencySource,
  });

  final double amount;
  final String? amountText;
  final String currency;
  final String? merchantName;
  final String? type;
  final String? categoryKey;
  final String? direction;
  final DateTime? occurredAt;
  final String? modelUsed;

  /// The server's prompt version (V1-058); null from an older server.
  final String? promptVersion;

  /// 4.2: what kind of message the model read (`transaction`, …) and the
  /// status of the operation (`completed`, `pending`, …). Null from an older
  /// server, which never returned them.
  final String? messageType;
  final String? status;

  /// 4.4: `account_context` when the message names no currency and the server
  /// accepted the currency of the account this device matched it to.
  final String? currencySource;

  factory AiParseResponse.fromJson(Map<String, dynamic> json) {
    return AiParseResponse(
      amount: (json['amount'] as num).toDouble(),
      amountText: json['amount_text'] as String?,
      currency: json['currency'] as String,
      merchantName: json['merchant_name'] as String?,
      type: json['type'] as String?,
      categoryKey: json['category_key'] as String?,
      direction: json['direction'] as String?,
      occurredAt: json['occurred_at'] is String
          ? DateTime.tryParse(json['occurred_at'] as String)
          : null,
      modelUsed: json['model_used'] as String?,
      promptVersion: json['prompt_version'] is String
          ? json['prompt_version'] as String
          : null,
      messageType: json['message_type'] is String
          ? json['message_type'] as String
          : null,
      status: json['status'] is String ? json['status'] as String : null,
      currencySource: json['currency_source'] is String
          ? json['currency_source'] as String
          : null,
    );
  }
}

abstract class AiParserClient {
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  });
}

/// Production extraction is AI-primary; legacy/fake clients retain their
/// existing policy unless they explicitly implement this capability.
abstract class PrimaryAiParserClient implements AiParserClient {}

/// 4.3 / 4.4: what the device already knows, sent as EVIDENCE the model may
/// overrule (never as the answer): the on-device parser's reading and the
/// currency of the one existing account the message was matched to.
class AiParseContext {
  const AiParseContext({
    this.localAmountText,
    this.localCurrency,
    this.localDirection,
    this.accountCurrency,
  });

  final String? localAmountText;
  final String? localCurrency;
  final String? localDirection;
  final String? accountCurrency;

  bool get isEmpty => localAmountText == null && accountCurrency == null;

  Map<String, Object?> toJson() => {
        if (localAmountText != null)
          'local_evidence': {
            'amount_text': localAmountText,
            if (localCurrency != null) 'currency': localCurrency,
            if (localDirection != null) 'direction': localDirection,
          },
        if (accountCurrency != null) 'account_currency': accountCurrency,
      };
}

/// A client that can pass [AiParseContext]. A separate capability so the
/// existing [AiParserClient] implementations stay valid.
abstract class ContextualAiParserClient implements AiParserClient {
  Future<AiParseResponse?> parseWithContext({
    required String sanitizedSms,
    required String senderId,
    required String installId,
    required AiParseContext context,
  });
}

class SupabaseAiParserClient
    implements PrimaryAiParserClient, ContextualAiParserClient {
  SupabaseAiParserClient({
    required String edgeFunctionUrl,
    required Future<String?> Function() getAnonJwt,
    Future<String?> Function()? loadDeviceSecret,
    http.Client? httpClient,
  })  : _url = edgeFunctionUrl,
        _getAnonJwt = getAnonJwt,
        _loadDeviceSecret = loadDeviceSecret,
        _http = httpClient ?? GatedHttpClient();

  final String _url;
  final Future<String?> Function() _getAnonJwt;

  /// MALI-060n: the server-verified device secret. When present the request is
  /// authenticated as this device; without it the hardened server returns
  /// authentication_required and the caller falls back to local parsing.
  final Future<String?> Function()? _loadDeviceSecret;
  final http.Client _http;

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) =>
      parseWithContext(
        sanitizedSms: sanitizedSms,
        senderId: senderId,
        installId: installId,
        context: const AiParseContext(),
      );

  @override
  Future<AiParseResponse?> parseWithContext({
    required String sanitizedSms,
    required String senderId,
    required String installId,
    required AiParseContext context,
  }) async {
    final jwt = await _getAnonJwt();
    if (jwt == null || jwt.isEmpty) {
      throw const AiParseException('missing_jwt');
    }
    final deviceSecret = await _loadDeviceSecret?.call();
    // One stable id for this logical request so the two attempts below (and any
    // client-level retry) are idempotent server-side — never a double AI charge.
    final requestId = IdGenerator.uuidV4();
    final body = jsonEncode({
      'sanitized_sms': sanitizedSms,
      // `sender_id` is deliberately NOT sent: no version of parse-sms has
      // ever read it (it never reaches the prompt), so transmitting the raw
      // sender — a phone number for some messages — was pure over-collection.
      // [senderId] stays in the signature for the local cascade/fakes.
      'install_id': installId,
      if (deviceSecret != null && deviceSecret.isNotEmpty)
        'device_secret': deviceSecret,
      'request_id': requestId,
      'schema_version': 1,
      'analysis_mode': 'ai_primary_v1',
      // Optional; an older server ignores them.
      ...context.toJson(),
    });
    // Up to 2 HTTP attempts with the SAME request id. The server owns bounded
    // provider retries/repair; a replay retrieves its result, never re-pays.
    // Cold starts / transient 5xx on the edge function are
    // common (e.g. a 502 then a 200), so retry once before giving up. The
    // per-attempt timeout guarantees we never hang.
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final response = await _http
            .post(
              Uri.parse(_url),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $jwt',
              },
              body: body,
            )
            .timeout(const Duration(seconds: 45));

        if (response.statusCode == 200) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          if (json['is_transaction'] == false) {
            return null; // AI explicitly says this is not a transaction
          }
          if (json['amount'] == null || json['currency'] == null) {
            throw const AiParseException('missing_amount_or_currency');
          }
          final parsed = AiParseResponse.fromJson(json);
          if (parsed.modelUsed?.endsWith('+fallback') == true) {
            throw const AiParseException('ai_deferred');
          }
          return parsed;
        }
        Map<String, dynamic>? envelope;
        try {
          envelope = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {}
        final transient = envelope?['retryable'] != false &&
            (response.statusCode == 502 ||
                response.statusCode == 503 ||
                response.statusCode == 504);
        if (transient && attempt < 2) {
          final seconds = envelope?['retry_after_seconds'];
          final wait = seconds is num ? seconds.toInt() : 0;
          if (wait > 5) throw const AiParseException('ai_deferred');
          await Future.delayed(wait > 0
              ? Duration(seconds: wait)
              : const Duration(milliseconds: 600));
          continue;
        }
        if (transient) throw const AiParseException('ai_deferred');
        var reason = 'http_${response.statusCode}';
        try {
          final json = jsonDecode(response.body);
          if (json is Map && json['error'] != null) {
            reason = '$reason:${json['error']}';
          }
        } catch (_) {
          // Keep the HTTP status if the body is not JSON.
        }
        throw AiParseException(reason);
      } catch (error) {
        if (error is AiParseException) rethrow;
        if (attempt < 2) {
          await Future.delayed(const Duration(milliseconds: 600));
          continue;
        }
        throw const AiParseException('ai_deferred');
      }
    }
    throw const AiParseException('unknown_failure');
  }
}
