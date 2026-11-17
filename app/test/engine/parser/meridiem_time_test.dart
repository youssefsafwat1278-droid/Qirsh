import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';
import 'package:money_companion/engine/parser/transaction_timestamp_extractor.dart';

/// Phone report: transaction hours and AM/PM were wrong. Arabic ص/م were not
/// read at all, and the ISO date path ignored AM/PM.
void main() {
  const engine = ParserEngine();
  // Year-less dates resolve against the processing time (DATA-04).
  const year = 2026;

  DateTime? parsedAt(String sms) => engine
      .parse(sms,
          senderId: 'IPN',
          defaultCurrency: 'EGP',
          now: DateTime(year, 11, 17))
      .transaction
      ?.occurredAt;

  group('ParserEngine reads the hour with its AM/PM marker', () {
    final cases = <String, DateTime>{
      'IPN transfer sent with amount of EGP 1.00 from 1938 on 28/10 at 12:02 AM. Ref# 1a':
          DateTime(year, 10, 28, 0, 2),
      'IPN transfer sent with amount of EGP 1.00 from 1938 on 28/10 at 01:43 PM. Ref# 1a':
          DateTime(year, 10, 28, 13, 43),
      'IPN transfer sent with amount of EGP 1.00 from 1938 on 28/10 at 12:15 PM. Ref# 1a':
          DateTime(year, 10, 28, 12, 15),
      'تم خصم 89.00 جنيه لدى STARBUCKS يوم 28/10 الساعة 09:15 م':
          DateTime(year, 10, 28, 21, 15),
      'تم خصم 89.00 جنيه لدى STARBUCKS يوم 28/10 الساعة 09:15 ص':
          DateTime(year, 10, 28, 9, 15),
      'تم خصم 89.00 جنيه لدى STARBUCKS يوم 28/10 الساعة 07:30 مساءً':
          DateTime(year, 10, 28, 19, 30),
      'تم خصم 89.00 جنيه لدى STARBUCKS يوم 28/10 الساعة 12:30 صباحا':
          DateTime(year, 10, 28, 0, 30),
      // A following Arabic word is not a marker; 24-hour stays as written.
      'تم تحويل 5.00 جنيه يوم 28/10 الساعة 13:29 من حسابك':
          DateTime(year, 10, 28, 13, 29),
      'Purchase EGP 20.00 at SHELL on 28/10/2026 at 9:05 p.m. card 1234':
          DateTime(2026, 10, 28, 21, 5),
      'Purchase EGP 20.00 at SHELL on 2026-10-28 11:40 PM card 1234':
          DateTime(2026, 10, 28, 23, 40),
    };
    cases.forEach((sms, expected) {
      test(sms, () => expect(parsedAt(sms), expected));
    });
  });

  group('TransactionTimestampExtractor reads Arabic and English markers', () {
    final cases = <String, DateTime>{
      'تم الخصم يوم 28/10/2026 الساعة 08:10 م': DateTime(2026, 10, 28, 20, 10),
      'تم الخصم يوم 28/10/2026 الساعة 08:10 ص': DateTime(2026, 10, 28, 8, 10),
      'Debit on 2026-10-28 at 12:05 AM': DateTime(2026, 10, 28, 0, 5),
      'Debit on 28/10/2026 at 12:05 PM': DateTime(2026, 10, 28, 12, 5),
      'Debit on 28/10/2026 18:04': DateTime(2026, 10, 28, 18, 4),
    };
    cases.forEach((sms, expected) {
      test(sms,
          () => expect(TransactionTimestampExtractor.extract(sms), expected));
    });
  });

  test('hourWithMeridiem converts 12-hour times to 24-hour', () {
    const h = TransactionTimestampExtractor.hourWithMeridiem;
    expect(
        [h(12, 'AM'), h(12, 'pm'), h(1, 'PM'), h(11, 'am')], [0, 12, 13, 11]);
    expect([h(12, 'ص'), h(12, 'م'), h(9, 'م'), h(9, 'مساء')], [0, 12, 21, 21]);
    expect(
        [h(9, 'a.m.'), h(9, 'p.m.'), h(13, 'PM'), h(9, null)], [9, 21, 13, 9]);
  });
}
