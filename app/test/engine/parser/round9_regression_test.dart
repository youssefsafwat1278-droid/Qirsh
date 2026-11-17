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

  // Round 10 (PR-01): the round-9 credit words no longer decide a direction;
  // incoming money is income where the baseline read income, otherwise a
  // review row — never a pre-filled payment.
  test('PR-01: incoming money is never a pre-filled payment', () {
    for (final (text, amount) in [
      ('Payroll SAR 12,000.00 to account *5678 from Test Corp', 12000.0),
      ('Your payroll of SAR 8,500.00 has been posted to account *5678', 8500.0),
      ('SAR 300.00 posted to your account *5678 from Ali', 300.0),
      ('SAR 500.00 added to your account *5678', 500.0),
      ('Your account *5678 has been topped up with SAR 500.00', 500.0),
      ('وصلك مبلغ 750 ريال من علي', 750.0),
      ('أودع مبلغ 2,000 ريال في حسابك *5678', 2000.0),
      ('Payroll credit SAR 8,500.00 to account *5678 Credit limit: SAR 20,000',
        8500.0),
      // A transfer the wording does not place is booked as spending by the
      // use case: never pre-filled.
      ('Transfer of SAR 750.00 from Ali posted to account *5678 Credit limit: SAR 20,000',
        750.0),
    ]) {
      final r = parse(text);
      expect(r.recorded || r.review, isTrue, reason: text);
      if (r.recorded) {
        expect(r.type, TransactionType.income, reason: text);
        expect(r.amount, amount, reason: text);
      }
    }
    // An explicit ATM cash deposit is income.
    final atm = parse('Cash deposit SAR 1,500.00 to account *5678 via ATM');
    expect([atm.recorded, atm.type, atm.amount],
        [true, TransactionType.income, 1500.0]);
    // A card posting is still spending.
    expect(parse('SAR 300.00 posted to card *4521 - Test Hotel').type,
        isNot(TransactionType.income));
  });

  // Round 10 (QR-01 / QR-02): an outgoing movement is never income, on the
  // device with or without a bank sender.
  test('QR-01 / QR-02: debits and outgoing transfers are never income', () {
    for (final text in [
      'Wages paid to employee SAR 3,000 from your account *5678',
      'Payroll Services Co: SAR 2,500.00 debited from account *5678',
      'SAR 120 sent to your contact Ali from account *5678',
      'Money sent to Yousef SAR 200',
      'Debit posted to your account *5678: SAR 300.00',
      'Annual fee SAR 250.00 posted to your account *5678',
      'Fee SAR 25.00 added to your account *5678',
      'Instant transfer of SAR 250.00 from your account *5678 into account of Ali',
      'Transfer SAR 1,000 to Ali for rent deposit',
      'Transfer of SAR 2,000 to deposit account of Test Developer',
      'تحويل 2,000 ريال لإيداع دفعة شقة لدى شركة تجريبية',
    ]) {
      for (final sender in ['AlRajhi', null]) {
        final r = engine.parse(text, senderId: sender);
        expect(r.transaction?.type, isNot(TransactionType.income),
            reason: '$sender: $text');
        expect(r.transaction?.type, isNot(TransactionType.refund),
            reason: '$sender: $text');
      }
    }
  });

  // Round 10 (QR-02 b): a limit or balance figure a verb follows is never
  // the amount; such a notice is never recorded.
  test('QR-02: a limit or balance figure before a verb is not the amount', () {
    expect(parse('Available limit SAR 5,000 debited SAR 50 at Test Mart').amount,
        isNot(5000.0));
    for (final text in [
      'Purchase approved. Available balance SAR 9,000 debited card ending 1234',
      'Your balance SAR 5,000 after salary credited',
      'Available balance SAR 9,000 credited to your card',
      'Your available limit SAR 5,000 has been credited back',
      'Balance SAR 3,000 deducted? Check your statement',
    ]) {
      expect(parse(text).recorded, isFalse, reason: text);
    }
  });

  // Round 10 (QR-03): an amount due in a future or scheduled clause is not a
  // completed movement.
  test('QR-03: a figure due in the future is a review row', () {
    for (final text in [
      'Outstanding SAR 2,000 to be paid by 5 Dec to avoid fees',
      'Minimum due SAR 115 must be paid by 5 Dec',
      'Your credit card outstanding SAR 2,000 will be debited on 1 Dec',
    ]) {
      final r = parse(text);
      expect([r.recorded, r.review], [false, true], reason: text);
    }
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

  // Round 10: the "figure followed by a verb" reading (clause a) is gone; a
  // labelled figure is the amount only when the verb comes first — otherwise
  // a review row, never another amount.
  test('PR-03: a labelled figure is never another amount', () {
    final due = parse('Due amount SAR 230 for Test Telecom paid successfully');
    expect(due.recorded ? due.amount : 230.0, 230.0);
    expect(due.recorded || due.review, isTrue);
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
