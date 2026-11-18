import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/validated_capture.dart';
import 'package:money_companion/domain/finance/currency_scale.dart';
import 'package:money_companion/engine/ai/ai_candidate_validator.dart';

// Closure round, follow-up 6 (3): the AI validators take the parser's
// currency table (parser_rules.json currencyTable.iso), limited to the codes
// in the detection registry (kDetectionCurrencyScale), not the ISO-wide
// storage table. Server twin: _shared/ai_currency_table_drift_test.ts.
void main() {
  final rules = jsonDecode(
      File('../supabase/functions/process-ios-sms/parser_rules.json')
          .readAsStringSync()) as Map<String, dynamic>;
  final iso = ((rules['currencyTable'] as Map<String, dynamic>)['iso'] as List)
      .cast<String>();

  test('currency codes are the parser table limited to detection codes', () {
    final expected = [
      for (final c in iso)
        if (kDetectionCurrencyScale.containsKey(c)) c
    ];
    expect(AiCandidateValidator.currencyCodes, expected);
    expect(kCaptureCurrencyCodes, expected);
    expect(expected, containsAll(['SAR', 'JPY', 'KWD', 'INR', 'NGN']));
    for (final code in kDetectionCurrencyScale.keys) {
      expect(iso, contains(code), reason: code);
    }
  });

  test('a non-core code counts only in capitals next to a figure', () {
    expect(AiCandidateValidator.currencyGrounded('NGN', 'NGN 5,000.00 paid'),
        isTrue);
    expect(
        AiCandidateValidator.currencyGrounded('NGN', '₦5,000.00 paid'), isTrue);
    expect(AiCandidateValidator.currencyGrounded('NGN', 'ngn 5,000.00 paid'),
        isFalse);
    expect(AiCandidateValidator.currencyGrounded('TZS', 'TZS account notice'),
        isFalse);
    expect(AiCandidateValidator.currencyGrounded('SAR', 'sar 5.00'), isTrue);
  });

  test('an import candidate in a table currency is accepted', () {
    final out = validateCaptureCandidate(
      text: 'NGN 5,000.00 debited from your card at SHOP',
      receivedAt: DateTime.utc(2026, 6, 16, 12),
      candidate: const CaptureCandidate(
        amount: 5000,
        amountText: '5,000.00',
        currency: 'NGN',
        direction: 'debit',
        type: 'payment',
      ),
    );
    expect(out.reason, isNull);
    expect(out.capture!.currency, 'NGN');
  });
}
