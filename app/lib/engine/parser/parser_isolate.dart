import 'dart:async';
import 'dart:isolate';
import '../../core/observability/app_diagnostics.dart';

import 'bank_profile.dart';
import 'catalog_rule_matcher.dart';
import 'parse_result.dart';
import 'parser_engine.dart';

class ParserIsolate {
  const ParserIsolate({this.timeout = const Duration(seconds: 2)});

  final Duration timeout;

  Future<ParseResult?> parse(
    String rawText, {
    String? senderId,
    List<BankProfile> bankProfiles = const [],
    List<CatalogParserRule> catalogRules = const [],
    String defaultCurrency = 'SAR',
  }) async {
    final trace = AppDiagnostics.begin(AppOperation.parsing);
    final receivePort = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _parseEntry,
        _ParserIsolateRequest(
          sendPort: receivePort.sendPort,
          rawText: rawText,
          senderId: senderId,
          bankProfiles: bankProfiles,
          catalogRules: catalogRules,
          defaultCurrency: defaultCurrency,
        ),
      );
      final message = await receivePort.first.timeout(timeout);
      if (message is ParseResult) {
        trace.finish();
        return message;
      }
      trace.finish(
          state: AppEventState.blocked, reason: AppEventReason.parseNoMatch);
      return null;
    } on TimeoutException {
      trace.finish(state: AppEventState.failed, reason: AppEventReason.timeout);
      isolate?.kill(priority: Isolate.immediate);
      return null;
    } catch (_) {
      trace.finish(
          state: AppEventState.failed, reason: AppEventReason.exception);
      return null;
    } finally {
      trace.finish(state: AppEventState.cancelled);
      receivePort.close();
    }
  }
}

void _parseEntry(_ParserIsolateRequest request) {
  try {
    final result = const ParserEngine().parse(
      request.rawText,
      senderId: request.senderId,
      bankProfiles: request.bankProfiles,
      catalogRules: request.catalogRules,
      defaultCurrency: request.defaultCurrency,
    );
    request.sendPort.send(result);
  } catch (_) {
    request.sendPort.send(null);
  }
}

class _ParserIsolateRequest {
  const _ParserIsolateRequest({
    required this.sendPort,
    required this.rawText,
    required this.senderId,
    required this.bankProfiles,
    required this.catalogRules,
    required this.defaultCurrency,
  });

  final SendPort sendPort;
  final String rawText;
  final String? senderId;
  final List<BankProfile> bankProfiles;
  final List<CatalogParserRule> catalogRules;
  final String defaultCurrency;
}
