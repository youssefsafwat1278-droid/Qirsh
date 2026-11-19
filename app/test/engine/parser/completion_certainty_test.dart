import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/direction_signal.dart';
import 'package:money_companion/engine/parser/completion_certainty.dart';
import 'package:money_companion/engine/parser/message_meaning.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// Round 5 (owner decision): the completion-certainty patterns are the same
/// on the device and the server, and the families behave as documented.
void main() {
  test('the server patterns equal the Dart patterns (drift)', () {
    final server = (jsonDecode(File(
                    '../supabase/functions/process-ios-sms/parser_rules.json')
                .readAsStringSync()) as Map<String, dynamic>)['completionCertainty']
        as Map<String, dynamic>;
    expect((server['doubtPatterns'] as Map).cast<String, String>(),
        CompletionCertainty.doubtPatterns);
    expect(server['adviceClause'], CompletionCertainty.adviceClause);
    expect((server['completedFormWords'] as List).cast<String>(),
        CompletionCertainty.completedFormWords);
    expect(server['transferPattern'], CompletionCertainty.transferPattern);
  });

  // Review X (X-M1/X-M2/X-M4): the direction the rule parser reads — the
  // one a model's answer must agree with. Server twin:
  // process-ios-sms/review_x_direction_test.ts.
  group('local direction (review X wordings)', () {
    const cases = {
      'Your payroll of SAR 8,500.00 has been posted to account *5678': TxnDirection.credit,
      'Payroll SAR 12,000.00 to account *5678 from Test Corp': TxnDirection.credit,
      'أودع مبلغ 2,000 ريال في حسابك *5678': TxnDirection.credit,
      'Bonus SAR 2,000.00 to account *5678 from Test Corp': TxnDirection.credit,
      'مكافأة 2,000 ريال لحسابك *5678': TxnDirection.credit,
      'Dividend SAR 300.00 to your account *5678': TxnDirection.credit,
      'Rent SAR 3,000.00 from Test Tenant arrived in account *5678': TxnDirection.credit,
      'Cashback of SAR 18.40 has been added to your card *4521': TxnDirection.credit,
      'Fee SAR 25.00 added to your account *5678': TxnDirection.debit,
      'Annual card fee SAR 250.00 applied to card *4521': TxnDirection.debit,
      'You were billed SAR 199.00 by Test Telecom on card *4521': TxnDirection.debit,
      'المبلغ المخصوم 75.00 ريال, بطاقة 4521,': TxnDirection.debit,
      'سُدد مبلغ 300 ريال لـ Test Electricity من حساب *5678': TxnDirection.debit,
      'ATM cash SAR 500.00 card *4521 at Olaya branch': TxnDirection.debit,
      'Gym membership SAR 199.00 renewed on card *4521': TxnDirection.debit,
      'Debit SAR 45.00 card *4521 Test Diner': TxnDirection.debit,
      'Credit transaction: SAR 4,000.00 from Test Corp Payroll': TxnDirection.credit,
      'Refund for your purchase at Noon: SAR 150.00 returned to card *4521': TxnDirection.credit,
      'Standing order of SAR 1,000.00 to Ali executed today': TxnDirection.debit,
      'سداد فاتورة 300 ريال ببطاقتك الائتمانية 4521': TxnDirection.debit,
      // X-M4: conflicting cues give no local direction.
      'Purchase SAR 150.00 at Noon card *4521 completed. Merchant confirmation received':
          TxnDirection.unknown,
      'Purchase SAR 20.00 at Jarir card *4521, cashback SAR 50.00 credited':
          TxnDirection.unknown,
      'تم إيداع 50 ريال استرداد نقدي لبطاقتك 4521 عن عملية شراء بمبلغ 500 ريال':
          TxnDirection.unknown,
    };
    for (final MapEntry(key: text, value: direction) in cases.entries) {
      test(text, () {
        expect(DirectionSignal.localOf(text), direction);
        final flipped = direction == TxnDirection.credit
            ? TxnDirection.debit
            : TxnDirection.credit;
        expect(DirectionSignal.modelDirectionRefused(text, flipped), isTrue);
        if (direction != TxnDirection.unknown) {
          expect(DirectionSignal.modelDirectionRefused(text, direction), isFalse);
        }
      });
    }
  });

  test('conflicting cues are not clearly completed (X-M4)', () {
    for (final text in [
      'Purchase SAR 150.00 at Noon card *4521 completed. Merchant confirmation received',
      'Purchase SAR 20.00 at Jarir card *4521, cashback SAR 50.00 credited',
      'تم إيداع 50 ريال استرداد نقدي لبطاقتك 4521 عن عملية شراء بمبلغ 500 ريال',
    ]) {
      expect(ParserEngine.meaningOf(text).reason, 'conflicting_cues', reason: text);
    }
  });

  test('own-account moves are read locally only (X-M5)', () {
    for (final text in [
      'Your STC Pay wallet was topped up with SAR 100 from Al Rajhi card *4521',
      'تم تحويل 300 ريال من بطاقتك الائتمانية إلى حسابك الجاري',
    ]) {
      expect(ParserEngine.isOwnAccountMove(text), isTrue, reason: text);
      expect(ParserEngine.meaningOf(text).disposition,
          isNot(MessageDisposition.record), reason: text);
    }
  });

  group('doubt families (one wording each; the families are what counts)', () {
    const cases = {
      'Refund of SAR 71.00 has not been credited to your card *4521': 'negated',
      'لم يتم رد مبلغ 77 ريال عن عملية شراء لدى نون': 'negated',
      'Bill SAR 200.00, VAT SAR 30.00, total SAR 230.00 can be paid via SADAD':
          'hedged',
      'Your expected refund of SAR 73.00 may have been credited': 'hedged',
      'Purchase SAR 45.00 at Jarir card *4521 is waiting for merchant confirmation':
          'pending',
      'شراء 45 ريال لدى جرير بطاقة 4521 بحاجة إلى تأكيد التاجر': 'pending',
      'Approve purchase SAR 45.00 at Jarir card *4521? Reply Y': 'question',
      'Your order was cancelled. Refund of SAR 150.00 credited': 'cancelled',
      'Thank you. We received your late payment of SAR 2,000.00': 'late',
      'Previous purchase SAR 80.00 at Panda': 'reference',
    };
    for (final MapEntry(key: text, value: family) in cases.entries) {
      test(text, () {
        expect(CompletionCertainty.doubtOf(text), family);
        expect(ParserEngine.meaningOf(text).disposition,
            isNot(MessageDisposition.record));
      });
    }
  });

  group('security advice is not a doubt', () {
    for (final text in const [
      'Purchase SAR 45.00 at Jarir card *4521. If you did not make this transaction, call 8001',
      'Purchase SAR 45.00 at Jarir card *4521. Not you? Call 8001',
      'تم خصم 45 ريال من بطاقتك 4521 لدى جرير. إذا لم تقم بهذه العملية اتصل بنا',
    ]) {
      test(text, () {
        expect(CompletionCertainty.doubtOf(text), isNull);
        expect(ParserEngine.meaningOf(text).disposition,
            MessageDisposition.record);
      });
    }
    test('advice does not hide a doubt in another clause', () {
      expect(
          CompletionCertainty.doubtOf(
              'Purchase SAR 45.00 at Jarir pending, if not you call 8001'),
          'pending');
    });
  });

  test(
      'a redacted counterpart is not a doubt (AR-02: redaction keeps the status words)',
      () {
    expect(CompletionCertainty.doubtOf('تم تحويل 400 ريال منك إلى: [REDACTED]'),
        isNull);
    expect(
        CompletionCertainty.doubtOf(
            'حوالة 152 ريال إلى: [REDACTED] بانتظار التأكيد'),
        'pending');
  });

  test('no completed form: a bare operation is uncertain', () {
    final m = ParserEngine.meaningOf('عملية بمبلغ 500 ريال على بطاقتك *4521');
    expect(m.kind, MessageKind.uncertain);
  });

  test('transfers are recognised (never sent to the model)', () {
    expect(CompletionCertainty.isTransfer('Transfer SAR 148 to Fadi Nasser'),
        isTrue);
    expect(CompletionCertainty.isTransfer('حوالة واردة 123 ريال من حساب'),
        isTrue);
    expect(CompletionCertainty.isTransfer('Purchase SAR 45.00 at Jarir'),
        isFalse);
  });
}
