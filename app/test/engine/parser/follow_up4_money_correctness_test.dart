import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/direction_signal.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// Follow-up 4 (independent re-review S at 7dd6efa8: NEW-1, NEW-2, NEW-3,
/// SM-06, SM-07 and the held-out classes). The same cases run on the server
/// (process-ios-sms/follow_up4_money_correctness_test.ts). Synthetic
/// messages only.
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
  group('the review and class probes (follow_up4_cases.json)', () {
    final cases = ((jsonDecode(File('${_dir}follow_up4_cases.json')
                .readAsStringSync()) as Map<String, dynamic>)['cases'] as List)
        .cast<Map<String, dynamic>>();
    for (final c in cases) {
      final text = c['text'] as String;
      final kind = c['kind'] as String;
      final pinned = c['device'] as String?;
      final label = text.length > 120 ? '${text.substring(0, 120)}…' : text;
      test('${c['id']} [$kind${pinned == null ? '' : ' device=$pinned'}] $label',
          () {
        final o = _device(text);
        if (kind == 'n' || kind == 'r' || pinned == 'review') {
          expect(o.recorded, isFalse);
          if (kind == 'r' || pinned == 'review') {
            // A review row, never silent.
            expect(ParserEngine.isIgnoredMessage(text, senderId: _bank),
                isFalse);
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

  // NEW-1: direction comes from the primary clause; a later reward or
  // cashback credit with a smaller or no figure is a side event.
  test('a purchase with a reward credit clause is a debit', () {
    for (final text in [
      'Purchase SAR 45.00 at Noon card *4521, cashback SAR 2.00 credited to your account',
      'Purchase SAR 45.00 at Noon card *4521, Qitaf credited to your account',
      'شراء 45 ريال لدى نون بطاقة 4521، تم إيداع استرداد نقدي 2 ريال',
    ]) {
      expect(DirectionSignal.detect(text), isNot(TxnDirection.credit),
          reason: text);
    }
    // The reward credit alone stays a credit.
    for (final text in [
      'Cashback SAR 20.00 credited to your card *4521',
      'Reward of SAR 100.00 credited to your account *4521',
    ]) {
      expect(DirectionSignal.detect(text), TxnDirection.credit, reason: text);
    }
  });

  // NEW-2: a completed primary clause is never no_movement because of a tail.
  test('a completed purchase with a reward or reminder tail is recorded', () {
    for (final text in [
      'Purchase SAR 230.00 at Jarir with card *4521 and earn rewards',
      'Purchase SAR 230.00 at Jarir with card *4521, total spent this month SAR 3,200',
      'خصم 99 ريال اشتراك شاهد من بطاقتك 4521، تذكير بالتجديد',
    ]) {
      expect(_meaning(text), startsWith('completedMovement:'), reason: text);
    }
  });

  // NEW-3: a text over the bound is read in part, so it is never recorded.
  test('a text over the bound with a status in the unread middle is review', () {
    final pad = List.filled(20, 'Dear valued customer, thank you for banking with us.')
        .join(' ');
    final text =
        'Purchase SAR 45.00 at Jarir card *4521. $pad Transaction declined. $pad '
        'Thank you.';
    expect(text.length, greaterThan(ParserEngine.maxTextLength));
    expect(_meaning(text), 'uncertain:over_length');
    expect(_device(text).recorded, isFalse);
    // A text at the bound is read whole.
    const short = 'Purchase SAR 45.00 at Jarir card *4521';
    expect(_device(short).recorded, isTrue);
  });

  // SM-07: device and server agree on G000 (tip total) and T79.
  test('a tip with a second figure is review; an unauthorised one is not completed',
      () {
    expect(_meaning('Purchase SAR 85.00 at Test Cafe, tip SAR 15.00, total SAR 100.00'),
        'uncertain:tip_component');
    expect(_meaning('Transaction unauthorised: SAR 100.00 at CAFE ONE'),
        'notCompleted:declined_or_failed');
  });
}
