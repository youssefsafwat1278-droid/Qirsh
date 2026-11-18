import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/direction_signal.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// Follow-up 5 (held-out sibling families a-f and reviewer S3). The same
/// cases run on the server (process-ios-sms/follow_up5_money_correctness_test.ts).
/// Synthetic messages only.
const _dir = '../supabase/functions/process-ios-sms/';
const _bank = 'AlRajhi';
const _engine = ParserEngine();

/// The on-device outcome: recorded (with a direction) or not.
({bool recorded, bool credit, double? amount, String? currency}) _device(
    String text) {
  if (ParserEngine.isIgnoredMessage(text, senderId: _bank)) {
    return (recorded: false, credit: false, amount: null, currency: null);
  }
  final r = _engine.parse(text, senderId: _bank);
  final t = r.transaction;
  if (!r.isTransaction || t == null) {
    return (recorded: false, credit: false, amount: null, currency: null);
  }
  final credit = t.type == TransactionType.income ||
      t.type == TransactionType.refund ||
      (t.type == TransactionType.transfer &&
          DirectionSignal.detect(text) == TxnDirection.credit);
  return (
    recorded: true,
    credit: credit,
    amount: t.amount,
    currency: t.currency
  );
}

String _meaning(String text) {
  final m = ParserEngine.meaningOf(text);
  // By name, so this file also compiles against the pre-fix parser (the
  // "before" run).
  return '${m.kind.name}:${m.reason}';
}

void main() {
  group('the review and class probes (follow_up5_cases.json)', () {
    final cases =
        ((jsonDecode(File('${_dir}follow_up5_cases.json').readAsStringSync())
                as Map<String, dynamic>)['cases'] as List)
            .cast<Map<String, dynamic>>();
    for (final c in cases) {
      final text = c['text'] as String;
      final kind = c['kind'] as String;
      final pinned = c['device'] as String?;
      final label = text.length > 120 ? '${text.substring(0, 120)}…' : text;
      test(
          '${c['id']} [$kind${pinned == null ? '' : ' device=$pinned'}] $label',
          () {
        final o = _device(text);
        if (kind == 'n' || kind == 'r' || pinned == 'review') {
          expect(o.recorded, isFalse);
          if (kind == 'r' || pinned == 'review') {
            // A review row, never silent.
            expect(
                ParserEngine.isIgnoredMessage(text, senderId: _bank), isFalse);
            expect(_engine.parse(text, senderId: _bank).amountDetected, isTrue);
          }
          return;
        }
        expect(o.recorded, isTrue);
        expect(o.credit, kind == 'c');
        expect(o.amount, closeTo((c['amount'] as num).toDouble(), 0.005));
        expect(o.currency, c['currency']);
      });
    }
  });

  // (a) a refund or reversal is completed only when a clause states the
  // credit happened.
  test('a requested or reviewed refund with no completed credit is pending',
      () {
    for (final t in [
      'Refund of SAR 120.00 initiated. It will be credited within 5 days.',
      'Your refund request of EGP 300.00 has been submitted. Expected in 7 days.',
      'تم استلام طلب استرجاع مبلغ 150 ريال وهو قيد المراجعة',
    ]) {
      expect(ParserEngine.isRefundPending(t.toLowerCase()), isTrue, reason: t);
      expect(_meaning(t), 'notCompleted:pending', reason: t);
    }
    expect(
        ParserEngine.isRefundPending(
            'refund of sar 120.00 credited to your account'),
        isFalse);
  });

  // (b) setting up or scheduling is not execution.
  test('a scheduled standing order is a notice; an executed one is not', () {
    expect(
        _meaning(
            'Standing order of SAR 500.00 to Ali will be executed on 01/12'),
        'noMovementNotice:scheduled_or_expected');
    expect(_meaning('أمر دائم بمبلغ 2000 ريال إلى المالك نُفذ من حسابك *5678'),
        isNot('noMovementNotice:scheduled_or_expected'));
    // No future or scheduling cue (the verb redacted away): read as before.
    expect(_meaning('أمر مستديم 2000 ريال إلى: [REDACTED] من حسابك'),
        isNot('noMovementNotice:scheduled_or_expected'));
  });

  // (c) money between two named own-account types is an own-account move.
  test('a transfer between named account types is own-account', () {
    expect(
        _meaning(
                'SAR 1,000.00 transferred from your Savings account to your Current account')
            .startsWith('ownAccountTransfer'),
        isTrue);
  });

  // (d) two merchant figures in one sentence are two events.
  test('two purchases in one sentence count two merchant figures', () {
    expect(
        ParserEngine.merchantFigureCount(
            'purchases: sar 30.00 at kudu and sar 55.00 at panda'),
        2);
  });

  // (e) a total with its parts is the total, never a part.
  test('a total stated with its parts', () {
    expect(
        ParserEngine.partsTotal(
            'dinner aed 260.00 + 10% service aed 26.00, total aed 286.00'),
        286);
    expect(
        ParserEngine.partsTotal(
            'purchase sar 100.00, fee sar 0.00, available balance sar 5,000.00'),
        isNull);
  });

  // S3: a bill paid WITH a credit card is a purchase, not a card repayment.
  test('a bill paid with a credit card is recorded', () {
    final o = _device('سداد فاتورة الاتصالات 230 ريال ببطاقتك الائتمانية 4521');
    expect([o.recorded, o.credit, o.amount], [true, false, 230]);
  });
}
