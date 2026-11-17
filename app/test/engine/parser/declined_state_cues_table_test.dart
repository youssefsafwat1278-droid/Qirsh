import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/validated_capture.dart';
import 'package:money_companion/engine/ai/ai_candidate_validator.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';
import 'package:money_companion/engine/parser/transaction_state_cues.dart';

/// DATA-01 / REV-01 / REV-02 / REV-04 — every probe from the audits, run on
/// every on-device path. The table is shared with the server test
/// (`process-ios-sms/parse_test.ts`) so the two runtimes judge the same text.
/// Synthetic messages only.
const _casesPath = '../supabase/functions/process-ios-sms/declined_cases.json';
const _notCompleted = 'transaction_not_completed';

void main() {
  final table =
      jsonDecode(File(_casesPath).readAsStringSync()) as Map<String, dynamic>;
  final cases = (table['cases'] as List).cast<Map<String, dynamic>>();
  const engine = ParserEngine();

  test('the table covers all three outcomes', () {
    expect(cases.map((c) => c['expect']).toSet(),
        {'review', 'payment', 'credit'});
  });

  for (final c in cases) {
    final text = c['text'] as String;
    final expected = c['expect'] as String;
    final review = expected == 'review';

    test('[${c['src']}] $expected: $text', () {
      expect(TransactionStateCues.isNotCompleted(text), review,
          reason: 'cue verdict');

      // On-device parse (also what the iOS import's local fallback runs).
      final r = engine.parse(text, senderId: 'AlRajhi');
      switch (expected) {
        case 'review':
          expect(r.isTransaction, isFalse, reason: 'never confirmed money');
          // Transaction-shaped: the capture becomes a Smart Inbox review row.
          expect(r.amountDetected, isTrue);
          expect(ParserEngine.isIgnoredMessage(text, senderId: 'AlRajhi'),
              isFalse);
        case 'payment':
          expect(r.isTransaction, isTrue);
          expect(r.transaction!.type, TransactionType.payment);
        case 'credit':
          expect(r.isTransaction, isTrue);
          final engineType = c['engineType'] as String?;
          if (engineType != null) {
            // Pre-existing type, unchanged by DATA-01 (see the table readme).
            expect(r.transaction!.type.name, engineType);
          } else {
            expect(r.transaction!.type.isExpense, isFalse);
          }
      }

      // AI-validated and AI-primary candidates, in either direction.
      for (final type in ['payment', 'refund']) {
        final v = const AiCandidateValidator().validate(
          response: AiParseResponse(
              amount: 100, amountText: '100.00', currency: 'SAR', type: type),
          sanitizedText: text,
          localParsed: null,
          messageText: text,
          normalizedType: type == 'payment'
              ? TransactionType.payment
              : TransactionType.refund,
        );
        if (review) {
          expect(v.accepted, isFalse, reason: 'AI $type');
          expect(v.rejectionReason, _notCompleted, reason: 'AI $type');
        } else {
          expect(v.rejectionReason, isNot(_notCompleted), reason: 'AI $type');
        }
      }

      // Server-processed result imported on iOS (REV-03).
      for (final direction in ['debit', 'credit']) {
        final v = validateCaptureCandidate(
          candidate: CaptureCandidate(
              amount: 100,
              amountText: '100.00',
              currency: 'SAR',
              direction: direction),
          text: text,
          receivedAt: DateTime.utc(2026, 11, 17),
        );
        if (review) {
          expect(v.accepted, isFalse, reason: 'import $direction');
          expect(v.reason, _notCompleted, reason: 'import $direction');
        } else {
          expect(v.reason, isNot(_notCompleted), reason: 'import $direction');
        }
      }
    });
  }
}
