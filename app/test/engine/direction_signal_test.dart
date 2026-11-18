import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/direction_signal.dart';
import 'package:money_companion/engine/models/transaction_type.dart';

void main() {
  group('DirectionSignal.detect', () {
    test('clear credit wording → credit', () {
      expect(DirectionSignal.detect('تم إيداع راتب 5000 ريال في حسابك'),
          TxnDirection.credit);
      expect(DirectionSignal.detect('Salary deposit of 5000 credited'),
          TxnDirection.credit);
    });

    test('clear debit wording → debit', () {
      expect(DirectionSignal.detect('شراء بقيمة 45 ريال من ستاربكس'),
          TxnDirection.debit);
      expect(DirectionSignal.detect('Purchase of 45 SAR, payment successful'),
          TxnDirection.debit);
      expect(DirectionSignal.detect('تم الخصم 200 ريال'), TxnDirection.debit);
    });

    test('both families present → unknown (not decisive)', () {
      expect(
        DirectionSignal.detect('شراء واسترداد مبلغ'),
        TxnDirection.unknown,
      );
    });

    // Follow-up 3 (SM-03): a flow that moves reward points is not a money
    // flow, so a purchase that credits points is a purchase.
    test('reward points credited next to a purchase → debit', () {
      expect(
        DirectionSignal.detect('شراء عبر بطاقة، تم إيداع نقاط المكافآت'),
        TxnDirection.debit,
      );
    });

    test('neither family present → unknown', () {
      expect(DirectionSignal.detect('رصيدك الحالي 1200 ريال'),
          TxnDirection.unknown);
    });

    test('"credit card" alone does not count as credit', () {
      expect(DirectionSignal.detect('purchase on your credit card 45 SAR'),
          TxnDirection.debit);
    });
  });

  group('DirectionSignal.ofType', () {
    test('income / refund are credit', () {
      expect(
          DirectionSignal.ofType(TransactionType.income), TxnDirection.credit);
      expect(
          DirectionSignal.ofType(TransactionType.refund), TxnDirection.credit);
    });

    test('payment / withdrawal are debit', () {
      expect(
          DirectionSignal.ofType(TransactionType.payment), TxnDirection.debit);
      expect(DirectionSignal.ofType(TransactionType.withdrawal),
          TxnDirection.debit);
    });

    test('transfer / unknown are ambiguous', () {
      expect(DirectionSignal.ofType(TransactionType.transfer),
          TxnDirection.unknown);
      expect(DirectionSignal.ofType(TransactionType.unknown),
          TxnDirection.unknown);
    });
  });

  group('DirectionSignal.contradicts', () {
    test('income text classified as payment → contradiction', () {
      expect(
        DirectionSignal.contradicts(
            'تم إيداع راتب 5000 ريال', TransactionType.payment),
        isTrue,
      );
    });

    test('purchase text classified as income → contradiction', () {
      expect(
        DirectionSignal.contradicts(
            'شراء بقيمة 45 ريال', TransactionType.income),
        isTrue,
      );
    });

    test('matching direction → no contradiction', () {
      expect(
        DirectionSignal.contradicts(
            'شراء بقيمة 45 ريال', TransactionType.payment),
        isFalse,
      );
    });

    test('ambiguous text or type → no contradiction', () {
      expect(
        DirectionSignal.contradicts(
            'رصيدك الحالي 1200 ريال', TransactionType.payment),
        isFalse,
      );
      expect(
        DirectionSignal.contradicts(
            'تم إيداع راتب 5000 ريال', TransactionType.transfer),
        isFalse,
      );
    });
  });
}
