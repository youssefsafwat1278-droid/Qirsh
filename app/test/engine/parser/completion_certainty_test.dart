import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/validated_capture.dart';
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

  test('the named-direction keywords equal the server lists (drift)', () {
    final rules = jsonDecode(File(
            '../supabase/functions/process-ios-sms/parser_rules.json')
        .readAsStringSync()) as Map<String, dynamic>;
    expect((rules['debitKeywords'] as List).cast<String>(), namedDebitKeywords);
    expect(
        (rules['creditKeywords'] as List).cast<String>(), namedCreditKeywords);
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
