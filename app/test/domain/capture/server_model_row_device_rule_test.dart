import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/validated_capture.dart';

/// Gemini-first phase 2 (class D): the device applies the server's rule to a
/// server row whose reading is the model's (parserSource `ai`): it holds the
/// row only for an explicit contradiction in the text, never because its own
/// parser reads the text differently or has no reading. Synthetic messages.
void main() {
  Map<String, dynamic> row(String direction, String type) =>
      {'parserSource': 'ai', 'direction': direction, 'type': type};

  CaptureValidation validate(String text, double amount, String amountText,
          String direction, String type, {String? merchant}) =>
      validateCaptureCandidate(
        candidate: CaptureCandidate(
            amount: amount,
            amountText: amountText,
            currency: 'EGP',
            direction: direction,
            type: type,
            merchant: merchant),
        text: text,
        receivedAt: DateTime.utc(2026, 11, 18, 20),
        modelDecided: true,
        fromModel: true,
      );

  test('"charged by" is a debit cue: an IPN debit transfer is not refused', () {
    const text = 'Your account was charged by EGP 1105 on 18/11 at 08:36 PM. '
        'IPN REF# 123456';
    expect(modelRowDirectionRefused(row('debit', 'transfer'), text), isFalse);
    expect(validate(text, 1105, '1105', 'debit', 'transfer').accepted, isTrue);
    expect(
        localParseContradictsServer(
            text: text,
            direction: 'debit',
            type: 'transfer',
            amount: 1105,
            modelRow: true),
        isFalse);
  });

  test('an English card purchase the device reads differently is kept', () {
    const text =
        'Your card ending 1234 was charged for EGP 118.00 at SALARY CAFE on 12/05/2026';
    expect(modelRowDirectionRefused(row('debit', 'payment'), text), isFalse);
    expect(
        localParseContradictsServer(
            text: text,
            direction: 'debit',
            type: 'payment',
            amount: 118,
            modelRow: true),
        isFalse);
    expect(
        validate(text, 118, '118.00', 'debit', 'payment',
                merchant: 'SALARY CAFE')
            .accepted,
        isTrue);
  });

  test('an explicit cue the model contradicts still holds the row', () {
    const text = 'تم خصم 120.00 جنيه من حسابك لدى متجر النور';
    expect(modelRowDirectionRefused(row('credit', 'income'), text), isTrue);
    expect(validate(text, 120, '120.00', 'credit', 'income').accepted, isFalse);
  });

  test('a cancelled purchase answered as a refund is kept (server twin)', () {
    const text = 'تم الغاء الشراء بمبلغ 250 جنيه على بطاقتك المنتهية 1234 لدى NOON';
    expect(meaningHoldReason(text, amount: 250, modelDecided: true,
        modelRow: true), isNull);
    expect(modelRowDirectionRefused(row('credit', 'refund'), text), isFalse);
    expect(validate(text, 250, '250', 'credit', 'refund').accepted, isTrue);
    expect(
        localParseContradictsServer(
            text: text, direction: 'credit', type: 'refund', amount: 250,
            modelRow: true),
        isFalse);
    // A rule-parse row keeps the old rule.
    expect(meaningHoldReason(text, amount: 250), isNotNull);
  });

  test('an advert tail does not overrule the transaction clause', () {
    const text = 'Deposit of EGP 3000 on 18/11. Enjoy 10% discount on purchases '
        'with your card';
    expect(meaningHoldReason(text, amount: 3000, modelDecided: true,
        modelRow: true), isNull);
    expect(modelRowDirectionRefused(row('credit', 'income'), text), isFalse);
    expect(validate(text, 3000, '3000', 'credit', 'income').accepted, isTrue);
    expect(
        localParseContradictsServer(
            text: text, direction: 'credit', type: 'income', amount: 3000,
            modelRow: true),
        isFalse);
  });

  test('the OTP/advert filter still drops a model row', () {
    expect(
        localParseContradictsServer(
            text: 'Your OTP is 482913. Do not share it. Amount EGP 50.00',
            direction: 'debit',
            modelRow: true),
        isTrue);
  });

  test('Persian and Arabic-Indic digits ground a plain-decimal amount_text '
      '(class B device twin)', () {
    expect(captureAmountTokens('تم خصم ۱۲۵٫۵۰ جم من حسابك'), contains('125.50'));
    expect(captureAmountTokens('تم خصم ١،٢٥٠ جنيه من حسابك'), contains('1250'));
    expect(
        validate('تم خصم ۱۲۵٫۵۰ جم من حسابك لدى متجر', 125.5, '125.50',
                'debit', 'payment')
            .accepted,
        isTrue);
  });

  test('an advert tail is set aside, a completed-event sentence never is '
      '(server twin)', () {
    const advert = 'Deposit of EGP 3000 on 18/11. Enjoy 10% discount on '
        'purchases with your card';
    expect(withoutAdvertTail(advert).trimRight(), 'Deposit of EGP 3000 on 18/11.');
    expect(withoutAdvertTail(advert).length, advert.length);
    for (final text in const [
      'Transfer of EGP 50 from your card. Credited to the beneficiary now',
      'تحويل 50 جنيه. تم الخصم من حسابك الآن',
      'شراء 384 ريال لدى جرير بطاقة *4521. العملية قيد الانتظار.',
      'Purchase SAR 50 at Jarir. Transaction pending now',
    ]) {
      expect(withoutAdvertTail(text), text);
    }
  });
}
