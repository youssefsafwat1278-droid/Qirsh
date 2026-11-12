import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/privacy/sanitization_edit_map.dart';
import 'package:money_companion/engine/privacy/sms_sanitizer.dart';

import '../fixtures/bank_sms_golden_fixtures.dart';

// Runs the SAME fixture file as the server's
// supabase/functions/_shared/sms_redaction_test.ts. `expected` is the server's
// output (redactThirdPartyNames(redactPii(raw)).trim()); the device with no
// detected type must produce byte-identical text, so neither side can leak
// what the other masks. All messages are synthetic.
const _fixturePath =
    '../supabase/functions/_shared/fixtures/sms_redaction_cases.json';

void main() {
  final cases = (jsonDecode(File(_fixturePath).readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  group('shared redaction fixture (device == server)', () {
    test('fixture file is non-empty', () => expect(cases, isNotEmpty));

    for (final c in cases) {
      test('${c['id']} (${c['kind']})', () {
        final raw = c['raw'] as String;
        final out = SmsSanitizer.sanitize(raw);
        expect(out, c['expected'], reason: 'device and server must agree');
        for (final keep in (c['mustKeep'] as List).cast<String>()) {
          expect(out, contains(keep), reason: 'parsing needs "$keep"');
        }
        for (final drop in (c['mustDrop'] as List).cast<String>()) {
          expect(out, isNot(contains(drop)), reason: '"$drop" is personal');
        }
        // The edit map composes the same passes; it must not drift.
        expect(sanitizeWithMap(raw).text, out);
        // Idempotent: the server re-sanitizes the device's output.
        expect(SmsSanitizer.sanitize(out), out);
      });
    }
  });

  group('purchase vs transfer counterparty', () {
    test('merchant after «من» in a purchase is kept, even for a payment type',
        () {
      const sms = 'شراء من بنده بمبلغ 88.00 ريال بطاقة مدى *4455 يوم 06/11';
      for (final t in [null, TransactionType.payment]) {
        expect(SmsSanitizer.sanitize(sms, detectedType: t), sms);
      }
    });

    test('person after «من» in a transfer is masked for every detected type',
        () {
      const sms = 'حوالة واردة من محمد عبدالله بمبلغ 500 ريال';
      for (final t in [
        null,
        TransactionType.transfer,
        TransactionType.income,
        // A parser that guessed wrong must not re-open the leak: the name rule
        // is decided by the text, not by the type.
        TransactionType.payment,
      ]) {
        final out = SmsSanitizer.sanitize(sms, detectedType: t);
        expect(out, 'حوالة واردة من [NAME] بمبلغ 500 ريال', reason: '$t');
      }
    });

    test('"To:" merchant on a detected payment is still kept (unchanged)', () {
      const sms = 'Purchase SAR 45.00\nTo: STARBUCKS RIYADH\nCard *9221';
      expect(
        SmsSanitizer.sanitize(sms, detectedType: TransactionType.payment),
        sms,
      );
    });

    test('context helper', () {
      expect(SmsSanitizer.isCounterpartyContext('Transfer received from X'),
          isTrue);
      expect(SmsSanitizer.isCounterpartyContext('Purchase from AMAZON'),
          isFalse);
      expect(SmsSanitizer.isCounterpartyContext('Refund from NOON credited'),
          isFalse);
      expect(SmsSanitizer.isCounterpartyContext('حوالة واردة من محمد'), isTrue);
      expect(SmsSanitizer.isCounterpartyContext('شراء من كارفور'), isFalse);
    });
  });

  group('merchant enrichment identifier guard', () {
    test('identifiers are detected; business names are not', () {
      for (final m in [
        'AHMED ٠٥٥١٢٣٤٥٦٧', // Arabic-Indic digits survive normalizeMerchant
        'PAY@ME.COM',
        'REF 1234567',
        'SA0380000000608010167519',
      ]) {
        expect(SmsSanitizer.containsIdentifier(m), isTrue, reason: m);
      }
      for (final m in ['STARBUCKS RIYADH', 'كارفور', 'NOON.COM', 'FAWRY*SNTRAL']) {
        expect(SmsSanitizer.containsIdentifier(m), isFalse, reason: m);
      }
    });
  });

  group('edit map stays exact around [NAME]/[REF]/[EMAIL]', () {
    test('amount span survives and still quotes itself', () {
      const sms =
          'Transfer received from MOHAMED ALI amount SAR 1,250.00 Ref 7788991';
      final m = sanitizeWithMap(sms);
      final start = sms.indexOf('1,250.00');
      expect(m.verifySpan(start, start + '1,250.00'.length), isTrue);
      final name = sms.indexOf('MOHAMED');
      expect(m.mapSpan(name, name + 7), isNull,
          reason: 'a span on a masked name is dropped, never remapped');
      expect(m.redactions.map((r) => r.label), containsAll(['[NAME]', '[REF]']));
    });
  });

  group('golden bank SMS corpus — what the AI route still receives', () {
    // For every golden fixture: the sanitized text sent to parse-sms still
    // carries the amount, the currency token, the card last digits and, for
    // purchases/refunds, the merchant. Parsing-relevant content is preserved.
    for (final f in realWorldBankSmsFixtures) {
      test(f.id, () {
        final out = SmsSanitizer.sanitize(f.rawSms);
        if (f.expectedLast4 != null) {
          expect(out, contains(f.expectedLast4!), reason: 'card last digits');
        }
        final merchant = f.expectedMerchant;
        final isBusiness = f.expectedType == TransactionType.payment ||
            f.expectedType == TransactionType.refund ||
            f.expectedType == TransactionType.withdrawal;
        if (merchant != null && isBusiness) {
          expect(out.toUpperCase(), contains(merchant.toUpperCase()),
              reason: 'merchant must reach the model');
        }
        final amount = f.expectedAmount;
        if (amount != null) {
          final digits = amount.truncate().toString();
          expect(
            RegExp(r'[0-9٠-٩][0-9٠-٩,٬]*').allMatches(out).any((m) =>
                m.group(0)!.replaceAll(RegExp('[,٬]'), '').contains(digits) ||
                _indicToLatin(m.group(0)!).contains(digits)),
            isTrue,
            reason: 'amount $amount must reach the model',
          );
        }
        expect(out, isNot(contains('[NAME]')),
            reason: 'no golden fixture carries a personal name');
      });
    }
  });
}

String _indicToLatin(String s) {
  const indic = '٠١٢٣٤٥٦٧٨٩';
  final b = StringBuffer();
  for (final ch in s.split('')) {
    final i = indic.indexOf(ch);
    b.write(i >= 0 ? '$i' : (ch == '٬' || ch == ',' ? '' : ch));
  }
  return b.toString();
}
