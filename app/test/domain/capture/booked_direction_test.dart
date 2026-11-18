// Closure round, follow-up 6 (4): the device's contradiction checks use the
// direction it would BOOK — the clause structure of the sentence carrying the
// amount — so a correct answer is not overruled by a points/cashback line, a
// cue word in a merchant name, a deposit word on an outgoing transfer, a
// refund or an OTP footer; a real contradiction is still caught. Synthetic.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/validated_capture.dart';
import 'package:money_companion/engine/ai/ai_candidate_validator.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/models/transaction_type.dart';

TransactionType _type(String t) => switch (t) {
      'payment' => TransactionType.payment,
      'transfer' => TransactionType.transfer,
      'refund' => TransactionType.refund,
      'income' => TransactionType.income,
      _ => TransactionType.unknown,
    };

void main() {
  ({bool imported, String? importReason, String? deviceReason}) check(
      String text, double amount, String type, String direction,
      [String? merchant]) {
    final lc = localParseContradictsServer(
        text: text,
        direction: direction,
        type: type,
        senderId: 'SNB',
        amount: amount,
        merchant: merchant);
    final v = validateCaptureCandidate(
      text: text,
      receivedAt: DateTime.utc(2026, 6, 16, 12),
      candidate: CaptureCandidate(
          amount: amount,
          amountText: amount.toStringAsFixed(2),
          currency: 'SAR',
          direction: direction,
          type: type,
          merchant: merchant),
    );
    final d = const AiCandidateValidator().validate(
      response: AiParseResponse(
          amount: amount,
          amountText: amount.toStringAsFixed(2),
          currency: 'SAR',
          type: type,
          direction: direction,
          merchantName: merchant,
          messageType: 'transaction',
          status: 'completed'),
      sanitizedText: text,
      localParsed: null,
      messageText: text,
      normalizedType: _type(type),
      referenceTime: DateTime.utc(2026, 6, 16, 12),
    );
    return (
      imported: !lc && v.accepted,
      importReason: v.reason,
      deviceReason: d.rejectionReason
    );
  }

  const correct = <(String, double, String, String, String?)>[
    ('POS purchase SAR 45.00 at Salary Store. Credited points 45', 45,
        'payment', 'debit', 'Salary Store'),
    ('Purchase SAR 45.00 at SHOP card *1234. Cashback points credited to your wallet',
        45, 'payment', 'debit', null),
    ('Transfer of SAR 500.00 to Deposit Holdings Ltd from your account *1234 completed',
        500, 'transfer', 'debit', null),
    ('Purchase of SAR 80.00 at Refund Mart with card *1234', 80, 'payment',
        'debit', null),
    ('Refund of SAR 80.00 from SHOP credited to your card *1234', 80, 'refund',
        'credit', null),
    ('Purchase of SAR 80.00 at SHOP with card *1234. Never share your OTP with anyone.',
        80, 'payment', 'debit', null),
  ];
  for (final (text, amount, type, direction, merchant) in correct) {
    test('a correct answer is not contradicted: $text', () {
      final r = check(text, amount, type, direction, merchant);
      expect(r.imported, isTrue, reason: 'import: ${r.importReason}');
      expect(r.deviceReason, isNull);
    });
  }

  const wrong = <(String, double, String, String)>[
    ('SAR 750.00 credited to your account *1234 from Ali', 750, 'payment',
        'debit'),
    ('Your account *1234 was credited. Amount SAR 300.00 from SHOP', 300,
        'payment', 'debit'),
    ('Purchase of SAR 80.00 at SHOP debited from card *1234', 80, 'refund',
        'credit'),
    ('Transfer of SAR 500.00 to Deposit Holdings Ltd from your account *1234 completed',
        500, 'income', 'credit'),
  ];
  for (final (text, amount, type, direction) in wrong) {
    test('a real contradiction is still caught: $type for $text', () {
      final r = check(text, amount, type, direction);
      expect(r.imported, isFalse);
      expect(r.deviceReason, 'direction_contradiction');
    });
  }
}
