// Round 4 (requirements C and D): the request bodies the app sends, built by
// the production code from the shared labelled set
// (`supabase/functions/_shared/fixtures/sms_leak_labelled_cases.json`), and
// the merchant key a redacted message yields. No tagged third-party name,
// number or one-time code may be in any string field. Synthetic data only.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/services/learned_rule_precedence.dart';
import 'package:money_companion/domain/services/shared_category_learning.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';
import 'package:money_companion/engine/privacy/sms_sanitizer.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// Every string anywhere inside [value], with its path.
List<(String, String)> _strings(Object? value, [String path = '']) {
  if (value is String) return [(path, value)];
  if (value is List) {
    return [
      for (var i = 0; i < value.length; i++) ..._strings(value[i], '$path[$i]')
    ];
  }
  if (value is Map) {
    return [
      for (final e in value.entries)
        ..._strings(e.value, path.isEmpty ? '${e.key}' : '$path.${e.key}')
    ];
  }
  return const [];
}

void main() {
  final rows = (jsonDecode(File(
              '../supabase/functions/_shared/fixtures/sms_leak_labelled_cases.json')
          .readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();
  List<String> secretsOf(Map<String, dynamic> row) =>
      (row['secrets'] as List).cast<String>();
  final people = rows.where((r) => secretsOf(r).isNotEmpty).toList();
  final merchants = rows.where((r) => r['merchant'] != null).toList();

  test('the set covers people and merchants', () {
    expect(people.length, greaterThan(100));
    expect(merchants.length, greaterThan(19));
  });

  test('process-ios-sms upload: no tagged token in any string field', () async {
    // The caller passes exactly this (capture_sync_service.dart).
    expect(
      File('lib/features/capture/services/capture_sync_service.dart')
          .readAsStringSync(),
      contains('smsText: SmsSanitizer.sanitize(message.text),'),
    );
    final leaks = <String>[];
    for (final row in rows) {
      Map<String, dynamic>? body;
      final client = CaptureBackendClient(
        supabaseUrl: 'https://example.supabase.co',
        anonKey: 'anon',
        httpClient: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return Response('{}', 200);
        }),
      );
      final raw = row['raw'] as String;
      await client.processIosSms(
        installId: 'install',
        deviceSecret: 'secret',
        payloadId: 'payload',
        smsText: SmsSanitizer.sanitize(raw),
        sender: 'ExampleBank',
        receivedAt: DateTime.utc(2026, 11, 17, 10),
        locale: 'ar',
        allowAi: true,
        ownerUid: 'owner',
        ownerGeneration: 1,
        schemaV2: true,
        textLength: raw.length,
      );
      expect(body!['smsText'], row['expected']);
      expect(body!['sanitizedText'], row['expected']);
      for (final (path, value) in _strings(body)) {
        for (final s in secretsOf(row)) {
          if (value.contains(s)) leaks.add('${row['id']}: "$s" in $path');
        }
      }
    }
    expect(leaks, isEmpty);
  });

  test('AI request (parse-sms): no tagged token in any string field', () async {
    final leaks = <String>[];
    for (final row in rows) {
      Map<String, dynamic>? body;
      final client = SupabaseAiParserClient(
        edgeFunctionUrl: 'https://example.supabase.co/functions/v1/parse-sms',
        getAnonJwt: () async => 'jwt',
        loadDeviceSecret: () async => 'secret',
        httpClient: MockClient((request) async {
          body ??= jsonDecode(request.body) as Map<String, dynamic>;
          return Response('{}', 400);
        }),
      );
      final raw = row['raw'] as String;
      try {
        await client.parseWithContext(
          // What add_transaction_usecase.dart sends, under the type hint that
          // used to keep «إلى حساب <name>».
          sanitizedSms:
              SmsSanitizer.sanitize(raw, detectedType: TransactionType.payment),
          senderId: 'ExampleBank',
          installId: 'install',
          context: const AiParseContext(),
        );
      } on Object {
        // The stub refuses; only the request matters here.
      }
      expect(body, isNotNull, reason: '${row['id']}: no request was built');
      expect(body!['sanitized_sms'], row['expected']);
      for (final (path, value) in _strings(body)) {
        for (final s in secretsOf(row)) {
          if (value.contains(s)) leaks.add('${row['id']}: "$s" in $path');
        }
      }
    }
    expect(leaks, isEmpty);
  });

  test('shared learning: a person row never yields a contribution body',
      () async {
    final leaks = <String>[];
    final at = DateTime.utc(2026, 11, 17);
    for (final row in people) {
      final raw = row['raw'] as String;
      // The worst case: the device parser read a merchant out of the raw
      // message and typed the row as a payment.
      final merchant = const ParserEngine()
          .parse(raw, senderId: 'ExampleBank')
          .transaction
          ?.rawMerchant;
      if (merchant == null) continue;
      final contribution = sharedContributionFor(
        TransactionEntity(
          id: 'tx',
          amountMoney: Money.fromLegacyReal(85, 'SAR'),
          currency: 'SAR',
          type: TransactionTypeEntity.payment,
          source: TransactionSourceEntity.bank,
          direction: TransactionDirectionEntity.debit,
          occurredAt: at,
          rawMessage: raw,
          parseConfidence: 0.9,
          status: TransactionStatus.confirmed,
          createdAt: at,
          updatedAt: at,
          rawMerchant: merchant,
        ),
        'shopping',
      );
      if (contribution == null) continue;
      for (final (path, value) in _strings(contribution.toJson())) {
        for (final s in secretsOf(row)) {
          if (value.contains(s.toUpperCase())) {
            leaks.add('${row['id']}: "$s" in $path ($value)');
          }
        }
      }
    }
    expect(leaks, isEmpty);
  });

  test('masksPartOf: a person merchant is recognised, a business is not', () {
    for (final row in merchants) {
      expect(
          SmsSanitizer.masksPartOf(
              row['raw'] as String, row['merchant'] as String),
          isFalse,
          reason: '${row['id']}');
    }
    for (final row in people.where((r) => (r['id'] as String).contains('pair'))) {
      final name = secretsOf(row)
          .where((s) => RegExp(r'\p{L}', unicode: true).hasMatch(s))
          .join(' ');
      if (name.isEmpty) continue;
      expect(SmsSanitizer.masksPartOf(row['raw'] as String, name), isTrue,
          reason: '${row['id']}');
    }
  });

  group('saved category rule after redaction', () {
    late AppDatabase db;
    late DriftMerchantCategoryRepository rules;
    setUp(() async {
      db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );
      rules = DriftMerchantCategoryRepository(db);
    });
    tearDown(() => db.close());

    String? merchantOf(String text) => const ParserEngine()
        .parse(text, senderId: 'ExampleBank')
        .transaction
        ?.rawMerchant;

    test('a merchant that must survive keeps its rule key and its rule',
        () async {
      final failures = <String>[];
      var matched = 0;
      for (final row in merchants) {
        final raw = row['raw'] as String;
        final redacted = SmsSanitizer.sanitize(raw);
        expect(redacted, contains(row['merchant'] as String));
        final before = merchantOf(raw);
        final after = merchantOf(redacted);
        final beforeKey =
            before == null ? '' : AppDatabase.normalizeMerchant(before);
        final afterKey =
            after == null ? '' : AppDatabase.normalizeMerchant(after);
        if (beforeKey != afterKey) {
          failures.add('${row['id']}: "$beforeKey" became "$afterKey"');
          continue;
        }
        if (before == null) continue;
        // An enabled saved rule for the merchant still matches what the
        // redacted text yields.
        await rules.confirmMerchantCategory(
            rawMerchant: before, categoryKey: 'shopping', isUserConfirmed: true);
        final hit = await learnedRuleCategoryFor(rules, after);
        if (hit?.categoryKey != 'shopping' || hit?.userConfirmed != true) {
          failures.add('${row['id']}: the saved rule for "$before" is lost');
        } else {
          matched++;
        }
      }
      expect(failures, isEmpty);
      expect(matched, greaterThan(merchants.length ~/ 3),
          reason: 'the device parser reads a merchant from most rows');
    });

    test('no person name is a merchant of the redacted text', () {
      final failures = <String>[];
      for (final row in people) {
        final merchant = merchantOf(SmsSanitizer.sanitize(row['raw'] as String));
        if (merchant == null) continue;
        final key = AppDatabase.normalizeMerchant(merchant);
        for (final s in secretsOf(row)) {
          if (merchant.contains(s) || key.contains(s.toUpperCase())) {
            failures.add('${row['id']}: "$s" in merchant "$merchant"');
          }
        }
      }
      expect(failures, isEmpty);
    });
  });
}
