import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/message_meaning.dart';
import 'package:money_companion/engine/parser/parse_result.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// Round 3 closure (owner brief 4.1, 4.2, 4.4, §5; V1-031, V1-076, V1-082,
/// V1-084): meaning before amount, amount roles, direction from the
/// clause's own verbs and prepositions, table-driven currency. Synthetic
/// messages only. Each case states the outcome the on-device parser must
/// reach with a bank sender; the same rule runs on the server
/// (process-ios-sms/message_meaning_test.ts).
void main() {
  const engine = ParserEngine();
  ParseResultView parse(String text) =>
      ParseResultView(engine.parse(text, senderId: 'AlRajhi'));

  // Round 5 (owner decision): a due-date or reminder footer is a doubt — the
  // movement is not clearly completed, so it is kept for review (never
  // dropped as a notice, never recorded on the rule reading).
  group('a due-date footer never excludes the event; it makes it a review', () {
    for (final text in [
      'Purchase completed for EGP 250; card payment due EGP 900',
      'عملية شراء بمبلغ 120 ريال لدى متجر تجريبي. تذكير: موعد سداد بطاقتك 25/11',
    ]) {
      test(text, () {
        expect(parse(text).recorded, isFalse);
        final m = ParserEngine.meaningOf(text);
        expect(m.kind, MessageKind.uncertain);
        expect(m.disposition, MessageDisposition.review);
      });
    }
  });

  group('clear notices and future or pending clauses record nothing', () {
    for (final text in [
      'Your Test Electricity bill of SAR 300 is due on 25/11',
      'فاتورة الكهرباء بمبلغ 300 ريال مستحقة في 25/11',
      'Your salary of SAR 12,000 is expected on 27/11',
      'راتبك المتوقع 12,000 ريال في 27/11',
      'Payment of SAR 500 to Test Telecom is under processing',
      'Transfer of SAR 500 to Ali scheduled for 1 Dec',
      'Your loan instalment SAR 1,200 will be executed tomorrow',
      'دفعة قادمة: سيتم خصم 1,200 ريال في 1 ديسمبر',
      'Your refund request of SAR 50 for order 1234 has been received',
      'Spend SAR 500 and get SAR 50 back this weekend',
      // A status line above a bank's field lines still decides the message.
      'Payment of SAR 100.00 to Test Telecom will be processed\n'
          'مبلغ:SAR 100.00\nلدى:TEST STORE',
      // Follow-up: a future verb with no scheduling word; an offer.
      'Annual fee of SAR 250 will be charged on 1 Dec',
      'سيتم خصم رسوم سنوية 250 ريال في 1 ديسمبر',
      'Get 20% cashback up to SAR 50.00 on your next purchase with your card. '
          'Offer ends soon',
      'احصل على استرداد نقدي 20% حتى 50 ريال على مشترياتك القادمة. '
          'ينتهي العرض قريبا',
      // An advert header split off by "!" is not a footer of a movement.
      'عرض خاص! وفر SAR 50 هذا الأسبوع فقط باستخدام بطاقة البنك',
    ]) {
      test(text, () => expect(parse(text).recorded, isFalse));
    }
    // The import paths distrust a server result for a no-movement notice.
    for (final text in [
      'Your salary of SAR 12,000 is expected on 27/11',
      'Reminder: your card payment of SAR 980 is due tomorrow',
    ]) {
      test('a notice to the import paths: $text',
          () => expect(ParserEngine.isNoticeMessage(text), isTrue));
    }
  });

  group('direction comes from the clause, not from nouns', () {
    for (final text in [
      'SAR 500 credited to Ali from your account *5678',
      'Purchase SAR 45.00 at Deposit Mart card *4521',
      'Salary payment to employees SAR 45,000 debited from account *5678',
      'Security deposit payment SAR 1,500 to Test Rentals from account *5678',
      'تم الدفع 300 ريال لشركة الإيداع',
    ]) {
      test(text, () {
        final r = parse(text);
        expect(r.recorded, isTrue);
        expect(r.type, TransactionType.payment);
      });
    }
    // Round 5: a reversal word is a doubt (review), whatever the direction.
    test('Cashback reversal: SAR 15.00 deducted from account *5678', () {
      expect(
          ParserEngine.meaningOf(
                  'Cashback reversal: SAR 15.00 deducted from account *5678')
              .disposition,
          MessageDisposition.review);
    });
    test('loyalty points are not money; the merchant ends at its sentence',
        () {
      final r = engine.parse(
          'POS purchase SAR 45.00 at Salary Store. Credited points 45',
          senderId: 'AlRajhi');
      expect(r.transaction?.type, TransactionType.payment);
      expect(r.transaction?.rawMerchant, 'Salary Store');
    });
    test('a refund credited back stays a refund', () {
      final r = parse('Merchant refund of SAR 150.00 from Card Renewal '
          'Services credited to card *1234');
      expect(r.type, TransactionType.refund);
    });
  });

  group('undecidable movements go to review, never recorded or silent', () {
    for (final text in [
      // A cash deposit is not proven income (owner brief §5).
      'Cash deposit SAR 2,000 via ATM to account *5678',
      'إيداع نقدي عبر الصراف 3,000 ريال في حسابك *5678',
      // Money between the user's own accounts.
      'SAR 1,000 debited from *1111 and deposited to *2222',
      'خصم 200 ريال من حسابك *5678 وإضافتها لحساب *9012',
      'Transfer of SAR 2,000.00 from your account *1234 to your account *5678',
      // Two movements with different amounts: never book one silently.
      // (Follow-up 3, SM-06: a cashback line is a side event of a purchase,
      // so the two-movement case is two purchases.)
      'SAR 45.00 paid at Test Mart; SAR 20.00 paid at Test Cafe',
      // Follow-up 3 (SM-01): another event's status sentence next to a
      // purchase (read not completed at 5dae2e2d) is review, never recorded.
      'Purchase of SAR 100.00 at CAFE ONE approved. Previous attempt declined.',
    ]) {
      test(text, () {
        final r = parse(text);
        expect(r.recorded, isFalse);
        expect(r.amountDetected, isTrue, reason: 'a review row');
        expect(ParserEngine.isIgnoredMessage(text, senderId: 'AlRajhi'),
            isFalse);
      });
    }
  });

  group('amount roles and currency', () {
    test('a foreign purchase is counted once, with the charged amount', () {
      final r = parse('Purchase of USD 20.00 at TestApp. Rate 3.75. '
          'Charged SAR 75.00. Card limit SAR 8,000');
      expect(r.amount, closeTo(75, 0.005));
      expect(r.currency, 'SAR');
      expect(r.foreignAmount, closeTo(20, 0.005));
      expect(r.foreignCurrency, 'USD');
    });
    test('SR1,250.00 is SAR 1,250', () {
      final r = parse('Purchase SR1,250.00 at Test Mart card *4521');
      expect(r.amount, closeTo(1250, 0.005));
      expect(r.currency, 'SAR');
    });
    test('a currency code in a merchant name is not the currency', () {
      final r = engine.parse('Purchase 30.00 at USD Store card *4521',
          senderId: 'AlRajhi');
      expect(r.transaction?.currency, isNot('USD'));
      expect(r.currencyDefaulted, isTrue);
    });
    test('an ISO code outside the Gulf list is read (table-driven)', () {
      final r = parse('Purchase 500 NGN at Test Kiosk card *4521');
      expect(r.amount, closeTo(500, 0.005));
      expect(r.currency, 'NGN');
    });
  });

  group('the meaning carries a disposition and a machine-readable reason', () {
    for (final (text, kind, reason, disposition) in [
      ('Purchase completed for EGP 250 at Test Mart. Available balance EGP 900',
          MessageKind.completedMovement, 'footer_set_aside',
          MessageDisposition.record),
      // Round 5: not clearly completed (a doubt word): review, with the reason.
      ('Purchase completed for EGP 250; card payment due EGP 900',
          MessageKind.uncertain, 'not_clearly_completed',
          MessageDisposition.review),
      ('Your Test Electricity bill of SAR 300 is due on 25/11',
          MessageKind.noMovementNotice, 'bill_due',
          MessageDisposition.noMovement),
      ('Your salary of SAR 12,000 is expected on 27/11',
          MessageKind.noMovementNotice, 'scheduled_or_expected',
          MessageDisposition.noMovement),
      ('Purchase declined: SAR 250.00 at CAFE ONE card **1234',
          MessageKind.notCompleted, 'declined_or_failed',
          MessageDisposition.review),
      ('Cash deposit SAR 2,000 via ATM to account *5678',
          MessageKind.cashDeposit, 'cash_deposit', MessageDisposition.review),
      ('SAR 1,000 debited from *1111 and deposited to *2222',
          MessageKind.ownAccountTransfer, 'own_accounts',
          MessageDisposition.review),
      ('SAR 45.00 paid at Test Mart; SAR 20.00 paid at Test Cafe',
          MessageKind.multipleEvents, 'multiple_amounts',
          MessageDisposition.review),
      ('Purchase of SAR 100.00 at CAFE ONE approved. Previous attempt declined.',
          MessageKind.uncertain, 'other_event_status',
          MessageDisposition.review),
      ('SAR 45.00 paid at Test Mart; cashback SAR 2 credited',
          MessageKind.completedMovement, 'footer_set_aside',
          MessageDisposition.record),
    ]) {
      test(text, () {
        final m = ParserEngine.meaningOf(text);
        expect([m.kind, m.reason, m.disposition], [kind, reason, disposition]);
      });
    }
    test('a message that names no currency says so (4.4)', () {
      expect(ParserEngine.meaningOf('Purchase 30.00 at USD Store card *4521')
          .currencyAbsent, isTrue);
      final r = engine.parse('Purchase 30.00 at USD Store card *4521',
          senderId: 'AlRajhi');
      expect(r.meaning?.currencyAbsent, isTrue);
      expect(
          ParserEngine.meaningOf('Purchase SAR 30.00 at Test Store card *4521')
              .currencyAbsent,
          isFalse);
    });
  });
}

/// The fields these cases read (also compiles against the pre-round-3
/// parser, which is how the "before" run was made).
class ParseResultView {
  ParseResultView(this.r);
  final ParseResult r;
  bool get recorded => r.isTransaction;
  bool get amountDetected => r.amountDetected;
  TransactionType? get type => r.transaction?.type;
  double? get amount => r.transaction?.amount;
  String? get currency => r.transaction?.currency;
  double? get foreignAmount => r.transaction?.foreignAmount;
  String? get foreignCurrency => r.transaction?.foreignCurrency;
}
