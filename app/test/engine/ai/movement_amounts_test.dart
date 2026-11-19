// Dev siblings d/e: several movements in one message, and the total a
// message states for one movement made of parts. Same fixture as the server
// (`_shared/movement_amounts_test.ts`): device and server must agree.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/validated_capture.dart';
import 'package:money_companion/engine/ai/ai_candidate_validator.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/parser/message_meaning.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

void main() {
  final cases = (jsonDecode(File(
                  '../supabase/functions/_shared/fixtures/movement_amount_cases.json')
              .readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  for (final c in cases) {
    test('movement amounts: ${c['id']}', () {
      final text = c['text'] as String;
      final separate = AiCandidateValidator.separateMovementAmounts(text);
      final expected = (c['separate'] as List?)
          ?.map((v) => (v as num).toDouble())
          .toList();
      expect(separate, expected);
      expect(AiCandidateValidator.statedTotal(text),
          (c['statedTotal'] as num?)?.toDouble());
    });
  }

  // Follow-up 13: any non-record meaning rejects; the not-completed reason
  // whenever the meaning is not completed, or is non-record and the text
  // carries a not-completed cue (an over-length text scanned whole). A
  // completed reversal (record) is not rejected on a cue alone.
  test('the validators reject every non-record meaning, not-completed first',
      () {
    final filler = List.filled(260, 'Thank you for banking with us.').join(' ');
    final cases = <String, String?>{
      'Purchase of SAR 100.00 at SHOPX declined': 'transaction_not_completed',
      'Purchase of SAR 100.00 at SHOPX declined. $filler':
          'transaction_not_completed',
      'Purchase of SAR 100.00 at SHOPX approved. Previous attempt declined.':
          'transaction_not_completed',
      'Purchase of SAR 120.00 at Jarir with card *4521. Previous transaction declined.':
          null,
      // Round 5 (owner decision): a reversal word is a doubt.
      'Reversal processed: SAR 140.00 for Pine Books returned to card *1907.':
          'message_meaning_not_clearly_completed',
    };
    for (final MapEntry(key: text, value: expected) in cases.entries) {
      final meaning = ParserEngine.meaningOf(text);
      final r = const AiCandidateValidator().validate(
        response: const AiParseResponse(
            amount: 100,
            amountText: '100.00',
            currency: 'SAR',
            type: 'payment',
            direction: 'debit'),
        sanitizedText: text,
        localParsed: null,
        messageText: text,
      );
      final c = validateCaptureCandidate(
        candidate: const CaptureCandidate(
            amount: 100, amountText: '100.00', currency: 'SAR',
            direction: 'debit'),
        text: text,
        receivedAt: DateTime.utc(2026, 11, 17),
      );
      final rule = AiCandidateValidator.meaningRejectionOf(text, amount: 100);
      if (expected != null) expect(rule, expected, reason: text);
      if (meaning.disposition != MessageDisposition.record) {
        expect(rule, isNotNull, reason: text);
        expect(r.accepted, isFalse, reason: text);
        expect(c.accepted, isFalse, reason: text);
      }
      if (rule == 'transaction_not_completed') {
        expect(r.rejectionReason, rule, reason: text);
        expect(c.reason, rule, reason: text);
      } else if (rule != null) {
        // (Round 5: an uncertain meaning; an ungrounded figure may be
        // reported first.)
        expect(r.accepted, isFalse, reason: text);
        expect(c.accepted, isFalse, reason: text);
      } else {
        expect(r.rejectionReason, isNot('transaction_not_completed'),
            reason: text);
      }
    }
  });

  group('meaning hold (dev siblings d/e)', () {
    test('two purchases in one message are held, whatever the server read', () {
      expect(
          meaningHoldReason(
              'Card *1111 used: SAR 64.00 at Oak Bakery; SAR 210.50 at Pine Books.',
              amount: 64),
          'multiple_amounts');
      expect(
          meaningHoldReason(
              'عمليتا شراء ببطاقتك 4444: 130.00 ريال لدى متجر النخيل و 45.00 ريال لدى مقهى السدر'),
          'multiple_amounts');
    });

    test('one purchase with a balance or a footer is not held', () {
      expect(
          meaningHoldReason(
              'Purchase SAR 120.00 at Oak Bakery card *1111. Available balance SAR 3,400.00'),
          isNull);
      // Round 5 (owner decision): a reference to an earlier operation is a
      // doubt.
      expect(
          meaningHoldReason(
              'Salary SAR 12,000.00 credited to account *4521. Previous salary SAR 11,500.00'),
          'not_clearly_completed');
    });

    test('a tip form records only at the total it states', () {
      const text =
          'You paid SAR 115.00 at Lark Cafe (SAR 100.00 + SAR 15.00 tip) with card *5555.';
      // Without an answer, or with the base, the parser's review stands.
      expect(meaningHoldReason(text), isNotNull);
      expect(meaningHoldReason(text, amount: 100), isNotNull);
      expect(meaningHoldReason(text, amount: 115), isNull);
    });
  });

  // Follow-up 15 (VAL-1): a tip / VAT / service-fee total that reads as
  // declined, pending, failed or reversed is never released at its stated
  // total (hold, import validator, AI validator); a completed one is. Server
  // twin: process-ios-sms/meaning_gate_test.ts on the same fixture.
  final totals = ((jsonDecode(File(
                  '../supabase/functions/_shared/fixtures/total_status_cases.json')
              .readAsStringSync()) as Map)['cases'] as List)
      .cast<Map<String, dynamic>>();
  for (final c in totals) {
    test('total forms: ${c['id']}', () {
      final text = c['text'] as String;
      final amount = c['amount'] as num;
      final held = c['held'] as bool;
      // Round 5 (owner decision): no completed-event form — review, at any
      // figure (never 'transaction_not_completed').
      final review = c['review'] == true;
      expect(AiCandidateValidator.meaningRejectionOf(text, amount: amount),
          held
              ? 'transaction_not_completed'
              : review
                  ? 'message_meaning_total_with_parts'
                  : null);
      expect(meaningHoldReason(text, amount: amount) != null, held || review);
      final v = validateCaptureCandidate(
        candidate: CaptureCandidate(
            amount: amount.toDouble(),
            amountText: amount.toStringAsFixed(2),
            currency: 'SAR',
            direction: 'debit'),
        text: text,
        receivedAt: DateTime.utc(2026, 11, 17),
      );
      if (held) expect(v.reason, 'transaction_not_completed');
    });
  }
}
