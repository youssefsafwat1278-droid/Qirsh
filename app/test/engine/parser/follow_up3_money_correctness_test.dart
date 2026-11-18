import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/validated_capture.dart';
import 'package:money_companion/engine/ai/ai_candidate_validator.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/direction_signal.dart';
import 'package:money_companion/engine/parser/message_meaning.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';
import 'package:money_companion/engine/parser/transaction_state_cues.dart';

/// Follow-up 3 (independent review S of 7577f347, SM-01..SM-09 and the
/// held-out classes). The same cases run on the server
/// (process-ios-sms/follow_up3_money_correctness_test.ts). Synthetic
/// messages only.
const _dir = '../supabase/functions/process-ios-sms/';
const _bank = 'AlRajhi';
const _engine = ParserEngine();

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_dir$name').readAsStringSync()) as Map<String, dynamic>;

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

void main() {
  group('the review and class probes (follow_up3_cases.json)', () {
    final cases = (_json('follow_up3_cases.json')['cases'] as List)
        .cast<Map<String, dynamic>>();
    for (final c in cases) {
      final text = c['text'] as String;
      final kind = c['kind'] as String;
      final pinned = c['device'] as String?;
      test('${c['id']} [$kind${pinned == null ? '' : ' device=$pinned'}] $text',
          () {
        final o = _device(text);
        if (pinned == 'record') {
          // An OPEN defect (characterization, not acceptance): as at 5dae2e2d.
          expect(o.recorded, isTrue, reason: c['pin'] as String?);
          return;
        }
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

  // SM-01: nothing that 5dae2e2d read as not completed is ever recorded; a
  // footer rule may only make it a review row.
  group('pre-round not-completed texts are never recorded', () {
    final texts =
        (_json('pre_round_not_completed.json')['texts'] as List).cast<String>();
    test('${texts.length} texts', () {
      for (final text in texts) {
        for (final sender in [_bank, null]) {
          expect(_engine.parse(text, senderId: sender).isTransaction, isFalse,
              reason: '$sender: $text');
        }
      }
    });
  });

  // SM-01: a status sentence is never a footer; where the footer logic and
  // the whole-message status disagree, the result is review.
  test('another event\'s status sentence next to a movement is review', () {
    for (final text in [
      'Purchase of SAR 120.00 at Jarir with card *4521. Previous transaction declined.',
      'Purchase SAR 60.00 at Kudu card *4521 approved. Your earlier attempt was declined.',
    ]) {
      final m = ParserEngine.meaningOf(text);
      // By name, so this file also compiles against the pre-fix parser (the
      // "before" run).
      expect([m.kind.name, m.disposition],
          ['uncertain', MessageDisposition.review],
          reason: text);
      expect(_device(text).recorded, isFalse, reason: text);
    }
  });

  // SM-03: points or miles credited next to a purchase do not make it a credit.
  test('a purchase that credits points or miles is a debit', () {
    for (final text in [
      'Purchase SAR 450.00 at Extra card *4521, 45 points credited to your account',
      'POS SAR 120.00 at Jarir card *4521 - 12 miles credited to your account',
      'شراء 300 ريال لدى جرير بطاقة 4521 وتمت إضافة 30 نقطة إلى حسابك',
    ]) {
      expect(DirectionSignal.detect(text), isNot(TxnDirection.credit),
          reason: text);
      final o = _device(text);
      expect([o.recorded, o.credit], [true, false], reason: text);
    }
    expect(DirectionSignal.detect('SAR 500.00 credited to your account *4521'),
        TxnDirection.credit);
  });

  // SM-02: no entry point throws, whatever numbers, commas, dates, card
  // suffixes, Arabic-Indic digits or truncation the text carries.
  test('no entry point throws (fuzz)', () {
    const leads = [
      'SAR 50.00 deducted from your card',
      'Card *4521 charged SAR 35.00 at Kudu on',
      'Amount charged: SAR 12.50, card',
      'Billed AED 99.00 to card',
      'المبلغ المخصوم 75.00 ريال, بطاقة',
      'USD 20.00 at Steam, equivalent SAR 75.10',
      'Purchase of USD 20.00 at Steam card *4521, charged as SAR 75.10',
      'تم خصم 50.00 ريال من بطاقتك',
    ];
    const tails = [
      ' *4521, Jarir, 17/11/2026',
      ' 4521, 17/11/2026, 21:40',
      ' 4521,,, 1,2,3,',
      ' ٤٥٢١، ١٧/١١/٢٠٢٦، ٢١:٤٠',
      ' 1,000,000.00, 0,5, ,5',
      ' ٣٥٫٠٠, ١٬٢٥٠٫٠٠,',
      ', balance SAR 940.00,',
      ' (SAR 1,',
      ' 12.,',
      '',
    ];
    final texts = <String>[];
    for (final l in leads) {
      for (final t in tails) {
        final full = '$l$t';
        texts.add(full);
        // Truncated anywhere.
        for (var cut = 1; cut < full.length; cut += 7) {
          texts.add(full.substring(0, cut));
        }
      }
    }
    for (final text in texts) {
      try {
        _engine.parse(text, senderId: _bank);
        _engine.parse(text);
        ParserEngine.isIgnoredMessage(text, senderId: _bank);
        ParserEngine.isNoticeMessage(text, senderId: _bank);
        ParserEngine.meaningOf(text);
        ParserEngine.clauseScope(text);
        DirectionSignal.detect(text);
        DirectionSignal.flowOf(text);
        TransactionStateCues.isNotCompleted(text);
        meaningHoldReason(text);
        localParseContradictsServer(
            text: text, direction: 'debit', type: 'payment', amount: 50);
        AiCandidateValidator.bookedDirection(text, amount: 50);
        AiCandidateValidator.chargedTotal(text);
      } catch (e) {
        fail('threw $e on: $text');
      }
    }
  });

  // SM-04: a completed movement with a notice tail is never "no movement";
  // a notice with no completed movement still is.
  test('a notice tail never hides a completed movement', () {
    for (final text in [
      'Purchase SAR 230.00 at Jarir with card *4521, eligible for installments',
      'Purchase SAR 120.00 at Jarir card *4521, offer valid till 30 Nov',
      'يرجى العلم بأنه تم خصم 500 ريال لقسط مستحق',
    ]) {
      expect(ParserEngine.meaningOf(text).disposition,
          isNot(MessageDisposition.noMovement),
          reason: text);
      expect(_device(text).recorded, isTrue, reason: text);
    }
    for (final text in [
      'Your card bill of SAR 1,200.00 is due on 25 Nov',
      'Earn 5 points on every SAR 10 spent with your card',
    ]) {
      expect(ParserEngine.meaningOf(text).disposition,
          MessageDisposition.noMovement,
          reason: text);
    }
  });

  // SM-05/06: a balance total, a cashback line or a previous purchase is not a
  // second movement; two purchases stay in review.
  test('side figures are not second movements; two purchases are review', () {
    for (final text in [
      'Purchase SAR 80.00 at Danube card *4521. Cashback SAR 4.00 credited',
      'Purchase SAR 120.00 at Jarir card *4521. Previous purchase SAR 80.00 at Panda',
    ]) {
      expect(ParserEngine.meaningOf(text).kind, MessageKind.completedMovement,
          reason: text);
    }
    expect(
        ParserEngine.meaningOf('Purchase SAR 80.00 at Danube card *4521. '
                'Purchase SAR 45.00 at Kudu card *4521')
            .kind,
        MessageKind.multipleEvents);
  });

  // SM-09: no super-linear parse time; the input is bounded.
  test('long inputs parse well inside the 2-second isolate limit', () {
    final inputs = [
      'Avl. Bal. ' * 2000,
      'SAR 1.00 ' * 2500,
      'Purchase SAR 45.00 at Kudu card *4521, ' * 600,
      '٤٥٢١, ' * 4000,
      'a.' * 10000,
    ];
    for (final text in inputs) {
      final sw = Stopwatch()..start();
      _engine.parse(text, senderId: _bank);
      ParserEngine.isIgnoredMessage(text, senderId: _bank);
      ParserEngine.meaningOf(text);
      DirectionSignal.detect(text);
      TransactionStateCues.isNotCompleted(text);
      meaningHoldReason(text);
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(1500),
          reason: '${text.length} chars: ${text.substring(0, 20)}');
    }
    // A status at either end of an over-long text still decides it.
    final filler = 'Dear valued customer, ' * 200;
    expect(
        TransactionStateCues.isNotCompleted(
            '${filler}Purchase of SAR 100.00 at SHOPX declined'),
        isTrue);
    expect(
        _engine
            .parse('${filler}Purchase of SAR 100.00 at SHOPX declined',
                senderId: _bank)
            .isTransaction,
        isFalse);
  });
}
