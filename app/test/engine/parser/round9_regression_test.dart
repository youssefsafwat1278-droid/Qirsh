import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/validated_capture.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// Round 9 regressions (PR-01..PR-06). Synthetic messages only.
void main() {
  const engine = ParserEngine();

  ParsedOutcome parse(String text) {
    final r = engine.parse(text, senderId: 'AlRajhi');
    return (
      recorded: r.isTransaction,
      type: r.transaction?.type,
      amount: r.transaction?.amount,
      currency: r.transaction?.currency,
      review: !r.isTransaction && r.amountDetected,
    );
  }

  test('PR-02: a notice word never makes a message silent', () {
    for (final text in [
      'Congratulations, you are the winning customer of SAR 1,000',
      'Your PIN has been changed successfully for card *1234',
      'SAR 250.00 Test Cafe 14:02. Available credit limit SAR 9,000.00',
    ]) {
      expect(ParserEngine.isIgnoredMessage(text, senderId: 'AlRajhi'), isFalse,
          reason: text);
    }
    // A genuine OTP stays silent, as at the baseline.
    expect(
        ParserEngine.isIgnoredMessage('Your OTP is 482913. Do not share it',
            senderId: 'AlRajhi'),
        isTrue);
  });

  test('PR-01: incoming money is a credit, never a pre-filled payment', () {
    for (final (text, amount) in [
      ('Payroll SAR 12,000.00 to account *5678 from Test Corp', 12000.0),
      ('Your payroll of SAR 8,500.00 has been posted to account *5678', 8500.0),
      ('SAR 300.00 posted to your account *5678 from Ali', 300.0),
      ('SAR 500.00 added to your account *5678', 500.0),
      ('Your account *5678 has been topped up with SAR 500.00', 500.0),
      ('وصلك مبلغ 750 ريال من علي', 750.0),
      ('أودع مبلغ 2,000 ريال في حسابك *5678', 2000.0),
      ('Cash deposit SAR 1,500.00 to account *5678 via ATM', 1500.0),
    ]) {
      final r = parse(text);
      expect(r.recorded, isTrue, reason: text);
      expect(r.type, TransactionType.income, reason: text);
      expect(r.amount, amount, reason: text);
    }
    // A card posting is still spending.
    expect(parse('SAR 300.00 posted to card *4521 - Test Hotel').type,
        isNot(TransactionType.income));
  });

  test('PR-04: wording that names the other direction is never confirmed', () {
    const text = 'Standing order SAR 1,000.00 received from Ali';
    // No sender (the device reads no transaction): still a contradiction.
    expect(
        localParseContradictsServer(
            text: text, direction: 'debit', type: 'payment', amount: 1000),
        isTrue);
    expect(
        localParseContradictsServer(
            text: text, direction: 'credit', type: 'income', amount: 1000),
        isFalse);
  });

  test('PR-03: a labelled figure a completed verb acts on is the amount', () {
    final due = parse('Due amount SAR 230 for Test Telecom paid successfully');
    expect([due.recorded, due.type, due.amount],
        [true, TransactionType.payment, 230.0]);
    final deposit = parse('رصيدك الجديد بعد إيداع 1,000 ريال هو 3,000 ريال');
    expect(deposit.amount, isNot(3000.0));
    // A due-date reminder is not a payment.
    expect(
        parse('تذكير: موعد سداد 1,200 ريال لبطاقتك *1234 بتاريخ 25/11')
            .recorded,
        isFalse);
  });

  test('PR-05: a receipt or approval code does not hold back a purchase', () {
    final r = parse(
        'Purchase of SAR 250.00 at SHOPX completed. Approval code 4829 for the purchase');
    expect(
        [r.recorded, r.type, r.amount], [true, TransactionType.payment, 250.0]);
  });

  test('PR-06: a server amount the text names with its currency agrees', () {
    const text =
        'Purchase of EUR 35.00 at Test Bistro Paris. Amount in SAR 143.20. Foreign fee SAR 3.58. Balance SAR 6,000.00';
    expect(
        localParseContradictsServer(
            text: text,
            direction: 'debit',
            type: 'payment',
            senderId: 'AlRajhi',
            amount: 143.20),
        isFalse);
    // A balance figure, or an unreadable amount, is never the server's honest
    // reading.
    expect(
        localParseContradictsServer(
            text: text,
            direction: 'debit',
            type: 'payment',
            senderId: 'AlRajhi',
            amount: 6000),
        isTrue);
    expect(
        localParseContradictsServer(
            text: text,
            direction: 'debit',
            type: 'payment',
            senderId: 'AlRajhi',
            amount: double.nan),
        isTrue);
  });

  test('a currency code is read as a word', () {
    expect(
        parse('Mada purchase 34.50 SAR at Test Grocery. Available balance 2,000.00 SAR')
            .currency,
        'SAR');
    expect(parse('Card *4521 used for 45 Saudi Riyals at Test Diner').currency,
        'SAR');
  });
}

typedef ParsedOutcome = ({
  bool recorded,
  TransactionType? type,
  double? amount,
  String? currency,
  bool review,
});
