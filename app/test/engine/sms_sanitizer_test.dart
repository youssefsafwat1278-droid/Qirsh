import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/privacy/sms_sanitizer.dart';

void main() {
  group('SmsSanitizer — required transfer/purchase distinction', () {
    // ── REQUIRED TEST 1: transfer SMS → beneficiary absent in AI payload ──
    test(
      'transfer SMS: إلى: NAME is stripped — real person name must not reach AI',
      () {
        const sms = 'تحويل داخلي صادر\n'
            'المبلغ: 1500.00 ر.س\n'
            'إلى: سارة الأسمري\n'
            'حساب: *5438\n'
            'في: 16/04/2026 10:30';
        final sanitized = SmsSanitizer.sanitize(
          sms,
          detectedType: TransactionType.transfer,
        );
        expect(sanitized, isNot(contains('سارة')),
            reason: 'Beneficiary first name must be stripped');
        expect(sanitized, isNot(contains('الأسمري')),
            reason: 'Beneficiary family name must be stripped');
        expect(sanitized, contains('إلى:'),
            reason: 'The إلى: keyword itself is kept for context');
        expect(sanitized, contains('[REDACTED]'));
        expect(sanitized, contains('1500.00'),
            reason: 'Amount must survive — AI needs it for grounding check');
      },
    );

    // ── REQUIRED TEST 2: purchase SMS → merchant name present in AI payload ──
    test(
      'purchase/POS SMS: merchant name is kept — business name is not PII',
      () {
        const sms = 'شراء عبر نقاط البيع\n'
            'بـ: SAR 45.00\n'
            'لدى: STARBUCKS RIYADH PARK\n'
            'بطاقة: *9221\n'
            'في: 2026-04-16 09:00';
        final sanitized = SmsSanitizer.sanitize(
          sms,
          detectedType: TransactionType.payment,
        );
        expect(sanitized, contains('STARBUCKS'),
            reason: 'Merchant (business) must be kept for AI categorization');
        expect(sanitized, contains('45.00'));
      },
    );

    // ── Unknown type → strip (safer) ──
    test(
      'unknown type (null): إلى: content stripped — cannot confirm it is a business',
      () {
        const sms =
            'Amount: SAR 200.00\nTo: ABDELRAHMAN ABDALLA\nDate: 2026-04-16';
        final sanitized = SmsSanitizer.sanitize(sms);
        expect(sanitized, isNot(contains('ABDELRAHMAN')));
        expect(sanitized, isNot(contains('ABDALLA')));
        expect(sanitized, contains('To: [REDACTED]'));
        expect(sanitized, contains('200.00'));
      },
    );
  });

  group('SmsSanitizer — PII field stripping', () {
    test('full 16-digit card number is replaced with [CARD]', () {
      const sms = 'Your card 4111 1111 1111 1111 was charged SAR 50.00';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, isNot(contains('4111')));
      expect(sanitized, contains('[CARD]'));
      expect(sanitized, contains('SAR 50.00'));
    });

    test('card with dashes is replaced', () {
      const sms = 'Charge on 4111-1111-1111-1111 at NOON for SAR 120.00';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, isNot(contains('4111')));
      expect(sanitized, contains('[CARD]'));
    });

    test('masked *1234 last-4 form is kept — not PII', () {
      const sms = 'بطاقتك *9221 تم خصم SAR 25.00';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, contains('*9221'),
          reason:
              'Masked last-4 is not sensitive and helps users identify card');
    });

    test('Saudi mobile number is replaced', () {
      const sms = 'للاستفسار اتصل بـ 0512345678 أو زيارة الفرع';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, isNot(contains('0512345678')));
      expect(sanitized, contains('[PHONE]'));
    });

    test('Egyptian mobile number is replaced', () {
      const sms = 'للمساعدة 01012345678 أو اتصل بالرقم 19623';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, isNot(contains('01012345678')));
      expect(sanitized, contains('[PHONE]'));
      // 5-digit hotline (19623) should NOT be stripped — below 10-digit threshold
      expect(sanitized, contains('19623'));
    });

    test('international +966 phone is replaced', () {
      const sms = 'Contact us at +966512345678 for support';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, isNot(contains('+966512345678')));
      expect(sanitized, contains('[PHONE]'));
    });

    test('long account number (10+ digits) is replaced', () {
      const sms = 'تم تحويل المبلغ من حساب 1234567890 إلى 0987654321';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, isNot(contains('1234567890')));
      expect(sanitized, isNot(contains('0987654321')));
      expect(sanitized, contains('[ACCOUNT]'));
    });

    test('short amounts are not stripped by account-number pattern', () {
      // 250000 is 6 digits — under the 10-digit threshold
      const sms = 'Purchase SAR 250000 at BIG STORE on 2026-04-16';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, contains('250000'),
          reason: '6-digit amount must not be stripped as an account number');
    });

    test('Arabic greeting with name is replaced', () {
      const sms = 'عزيزي أحمد، تم خصم SAR 100.00 من حسابك لدى NOON';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, isNot(contains('أحمد')));
      expect(sanitized, contains('[REDACTED]'));
      expect(sanitized, contains('100.00'));
      // NOON is a merchant, kept (payment type not specified → default strips إلى: only)
      expect(sanitized, contains('NOON'));
    });

    test('income type strips sender name (salary payer may be a person)', () {
      const sms =
          'إيداع من: محمد الغامدي\nالمبلغ: 8500.00 SAR\nإلى: حسابك *1234';
      final sanitized = SmsSanitizer.sanitize(
        sms,
        detectedType: TransactionType.income,
      );
      // Income is treated like transfer: the payer's name is removed. Since
      // the round-3 redaction contract (shared fixtures, device == server ==
      // Swift) the words «إلى: حسابك» and the user's OWN suffix of at most
      // four digits are kept — they are not third-party data, and the
      // direction of the movement is read from them. This assertion used to
      // require the whole «إلى:» tail to be removed.
      expect(sanitized, isNot(contains('محمد')),
          reason: 'the payer may be a person: the name must not be sent');
      expect(sanitized, isNot(contains('الغامدي')));
      expect(sanitized, contains('حسابك'));
      expect(sanitized, contains('8500.00'));
    });
  });

  group('SmsSanitizer — amounts and dates survive', () {
    test('all amount forms are preserved after sanitization', () {
      const sms = 'Debit SAR 1,234.56 on card *4321. Balance: SAR 18,000.00';
      final sanitized = SmsSanitizer.sanitize(
        sms,
        detectedType: TransactionType.payment,
      );
      expect(sanitized, contains('1,234.56'));
      expect(sanitized, contains('18,000.00'));
    });

    test('dates are preserved', () {
      const sms = 'Purchase SAR 75.00 at CAFE ARABICA on 16/04/2026 09:30';
      final sanitized = SmsSanitizer.sanitize(
        sms,
        detectedType: TransactionType.payment,
      );
      expect(sanitized, contains('16/04/2026'));
      expect(sanitized, contains('09:30'));
    });

    test('sender bank short codes are preserved', () {
      const sms = 'SNB: شراء SAR 45.00 لدى HERFY بطاقة *5678';
      final sanitized = SmsSanitizer.sanitize(
        sms,
        detectedType: TransactionType.payment,
      );
      expect(sanitized, contains('SNB'));
      expect(sanitized, contains('HERFY'));
    });

    // ── REQUIRED: amount-with-currency suffix survives (e.g. CIB Egypt) ──
    test(
      '60.00EGP (amount glued to currency code) survives — digits < 10 are not account numbers',
      () {
        // Real CIB Egypt SMS shape. 60.00 is only 4 digits; EGP is the currency.
        const sms = 'تم خصم 60.00EGP من بطاقة المدفوعة مقدماً رقم 4907 '
            'عند FAWRY*NWR يوم 14/03 الساعه 22:29 المتاح 28.14 '
            'للمزيد إتصل ب 19623';
        final sanitized = SmsSanitizer.sanitize(
          sms,
          detectedType: TransactionType.payment,
        );
        expect(sanitized, contains('60.00EGP'),
            reason:
                'Transaction amount must survive — grounding check needs it');
        expect(sanitized, contains('28.14'),
            reason: 'Balance (5 digits max with decimal) must also survive');
        // 4907 is a 4-digit last-4 — not stripped
        expect(sanitized, contains('4907'));
        // 19623 is a 5-digit hotline — not stripped
        expect(sanitized, contains('19623'));
      },
    );

    // ── REQUIRED: 10-digit reference stripped; amount on the same message survives ──
    test(
      'ANB-style: 10-digit reference 6824106852 is stripped, amount SAR 242.00 is NOT',
      () {
        // Real ANB ATM withdrawal shape from the golden fixture corpus.
        // The reference number (6824106852) has 10 consecutive digits → stripped.
        // The amount (242.00) has only 3 consecutive digits before the decimal → kept.
        const sms = 'ATM Withdrawal\n'
            'Amount: SAR 242.00\n'
            'Card: *3456\n'
            'Reference: 6824106852\n'
            'Date: 2026-04-10 14:30';
        final sanitized = SmsSanitizer.sanitize(
          sms,
          detectedType: TransactionType.withdrawal,
        );
        expect(sanitized, isNot(contains('6824106852')),
            reason: '10-digit reference number must be stripped as [ACCOUNT]');
        expect(sanitized, contains('[ACCOUNT]'));
        expect(sanitized, contains('242.00'),
            reason: 'Transaction amount must survive intact');
        expect(sanitized, contains('SAR'), reason: 'Currency must survive');
        // *3456 is a masked last-4 — kept
        expect(sanitized, contains('*3456'));
      },
    );

    // ── Mix: two long reference numbers + two small amounts in one message ──
    test(
      'multiple long references stripped, multiple amounts kept in one message',
      () {
        const sms = 'Purchase SAR 150.00 at NOON\n'
            'Card: *7890\n'
            'Auth: 9876543210\n' // 10-digit auth code → stripped
            'Trace: 12345678901\n' // 11-digit trace → stripped
            'Balance: SAR 4,820.50\n'
            'Date: 2026-06-16';
        final sanitized = SmsSanitizer.sanitize(
          sms,
          detectedType: TransactionType.payment,
        );
        expect(sanitized, isNot(contains('9876543210')));
        expect(sanitized, isNot(contains('12345678901')));
        expect(sanitized, contains('150.00'),
            reason: 'Primary amount must survive');
        expect(sanitized, contains('4,820.50'),
            reason: 'Balance with thousands separator must survive');
      },
    );
  });

  // ── Cross-implementation parity corpus ──────────────────────────────────
  //
  // The same inputs are pinned in three places, because the sanitizer exists
  // in three implementations and divergence between them is the actual risk:
  //   this file                                   (Dart client)
  //   supabase/functions/_shared/sms_redaction_test.ts   (server floor)
  //   app/tool/verify_swift_sanitizer.sh          (Share Extension)
  // Two of the three were missing the IBAN and OTP rules while forwarding
  // text to an off-device model. Change one, change all three.
  group('SmsSanitizer — parity corpus', () {
    test('IBANs are redacted; the account rule cannot reach them', () {
      // `\b\d{10,20}\b` never matches this — there is no word boundary
      // between "SA" and the digits that follow.
      final out = SmsSanitizer.sanitize(
        'حوالة من SA0380000000608010167519 بمبلغ 500 ريال',
        detectedType: TransactionType.transfer,
      );
      expect(out, contains('[IBAN]'));
      expect(out, isNot(contains('SA0380000000608010167519')));
    });

    test('OTP digits are redacted but the cue survives', () {
      expect(
        SmsSanitizer.sanitize('Your OTP is 483920',
            detectedType: TransactionType.payment),
        'Your OTP is [OTP]',
      );
      expect(
        SmsSanitizer.sanitize('رمز التحقق: 8391',
            detectedType: TransactionType.payment),
        'رمز التحقق: [OTP]',
      );
    });

    test('amounts are never redacted by shape', () {
      // Cue-anchoring exists for exactly this: a bare 4-8 digit run is more
      // often an amount than a passcode, and the proof layer needs the amount.
      expect(
        SmsSanitizer.sanitize('شراء بمبلغ 250.75 ريال',
            detectedType: TransactionType.payment),
        'شراء بمبلغ 250.75 ريال',
      );
      expect(
        SmsSanitizer.sanitize('مبلغ 1250 ريال',
            detectedType: TransactionType.payment),
        'مبلغ 1250 ريال',
      );
    });

    test('Arabic-Indic digits are redacted, not waved through', () {
      // Every pattern used ASCII \d, so a card or account number written in
      // the digits half this market uses reached the model intact. `\b` is no
      // help either: it is defined over [A-Za-z0-9_] only, so it does not even
      // see an Arabic-Indic run as a word.
      final account = SmsSanitizer.sanitize('حساب ١٢٣٤٥٦٧٨٩٠١٢٣ خصم',
          detectedType: TransactionType.payment);
      expect(account, contains('[ACCOUNT]'));
      expect(account, isNot(contains('١٢٣٤٥٦٧٨٩٠')));

      final card = SmsSanitizer.sanitize('بطاقة ٤٥٣٩١٤٨٨٠٣٤٣٦٤٦٧',
          detectedType: TransactionType.payment);
      expect(card, contains('[CARD]'));

      final phone = SmsSanitizer.sanitize('اتصل ٠٥٥١٢٣٤٥٦٧',
          detectedType: TransactionType.payment);
      expect(phone, contains('[PHONE]'));

      // Extended Arabic-Indic (U+06F0-06F9) too.
      final extended = SmsSanitizer.sanitize('حساب ۱۲۳۴۵۶۷۸۹۰۱۲۳',
          detectedType: TransactionType.payment);
      expect(extended, contains('[ACCOUNT]'));
    });

    test('an Arabic-Indic amount still survives', () {
      // The widened digit classes must not cost the amounts their reason for
      // existing: four digits is an amount, not an account number.
      expect(
        SmsSanitizer.sanitize('مبلغ ١٢٥٠ ريال',
            detectedType: TransactionType.payment),
        'مبلغ ١٢٥٠ ريال',
      );
      expect(
        SmsSanitizer.sanitize('مبلغ ٢٥٠٫٧٥ ريال',
            detectedType: TransactionType.payment),
        'مبلغ ٢٥٠٫٧٥ ريال',
      );
    });

    test('a lower-case IBAN is the same identifier and is redacted', () {
      final out = SmsSanitizer.sanitize('IBAN sa0380000000608010167519',
          detectedType: TransactionType.transfer);
      expect(out, contains('[IBAN]'));
      expect(out, isNot(contains('sa0380000000608010167519')));
    });

    test('card wins over the generic account rule on a bare 16-digit run', () {
      expect(
        SmsSanitizer.sanitize('4539148803436467',
            detectedType: TransactionType.payment),
        '[CARD]',
      );
    });
  });
}
