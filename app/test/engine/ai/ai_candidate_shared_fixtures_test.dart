import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/ai/ai_candidate_validator.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';

// Runs the SAME fixture file as the server's
// supabase/functions/_shared/ai_candidate_validator_test.ts. A disagreement
// between the two validators must be reported, never papered over here.
const _fixturePath =
    '../supabase/functions/_shared/fixtures/ai_candidate_cases.json';

TransactionType _type(Map<String, dynamic> ai) {
  switch (ai['type']) {
    case 'payment':
      return TransactionType.payment;
    case 'withdrawal':
      return TransactionType.withdrawal;
    case 'transfer':
      return TransactionType.transfer;
    case 'income':
      return TransactionType.income;
    case 'refund':
      return TransactionType.refund;
  }
  return TransactionType.unknown;
}

void main() {
  final cases = (jsonDecode(File(_fixturePath).readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  test('fixture file is non-empty', () => expect(cases, isNotEmpty));

  for (final c in cases) {
    test('shared AI candidate fixture: ${c['name']}', () {
      final ai = c['ai'] as Map<String, dynamic>;
      final local = c['local'] as Map<String, dynamic>?;
      // Round 5: a device-only verdict where the meaning gate differs.
      final expected =
          (c['expected_device'] ?? c['expected']) as Map<String, dynamic>;
      final aiDate = ai['occurred_at'] is String
          ? DateTime.tryParse(ai['occurred_at'] as String)
          : null;

      final result = const AiCandidateValidator().validate(
        response: AiParseResponse(
          amount: (ai['amount'] as num).toDouble(),
          amountText: ai['amount_text'] as String?,
          currency: ai['currency'] as String,
          merchantName: ai['merchant'] as String?,
          type: ai['type'] as String?,
          categoryKey: ai['category'] as String?,
          direction: ai['direction'] as String?,
          occurredAt: aiDate,
        ),
        sanitizedText: c['sanitized_text'] as String,
        localParsed: local == null
            ? null
            : ParsedTransaction(
                amountText: local['amount_text'] as String?,
                amount: (local['amount'] as num).toDouble(),
                currency: local['currency'] as String,
                type: TransactionType.payment,
                source: TransactionSource.bank,
                rawMerchant: local['merchant'] as String?,
              ),
        referenceTime: DateTime.parse(c['received_at'] as String),
        messageText: c['sanitized_text'] as String,
        normalizedType: _type(ai),
      );

      expect(result.accepted, expected['accepted']);
      if (!result.accepted) {
        expect(result.rejectionReason, expected['reason']);
      } else {
        expect(result.currency, expected['currency']);
        expect(result.merchantName, expected['merchant']);
        expect(
          result.occurredAt != null && result.occurredAt == aiDate,
          expected['occurred_at_kept'] ?? false,
        );
      }
    });
  }
}
