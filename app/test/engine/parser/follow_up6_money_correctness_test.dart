import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/validated_capture.dart';
import 'package:money_companion/engine/ai/ai_candidate_validator.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/direction_signal.dart';
import 'package:money_companion/engine/parser/message_meaning.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// Follow-up 6 (round 4): the reviewer's open reproductions at a157e68e and
/// the three classes of the real-model run. The same cases run on the server
/// (process-ios-sms/follow_up6_money_correctness_test.ts). Synthetic messages
/// only. Each row is checked twice: the device's own parse, and the gates an
/// answer from a server or a model passes (the meaning hold, the meaning
/// rejection rule and the import validator) against a forged answer of
/// "completed, at `answer`".
const _dir = '../supabase/functions/process-ios-sms/';
const _bank = 'AlRajhi';
const _engine = ParserEngine();

({bool recorded, bool credit, double? amount, String? currency, TransactionType? type})
    _device(String text) {
  const none =
      (recorded: false, credit: false, amount: null, currency: null, type: null);
  if (ParserEngine.isIgnoredMessage(text, senderId: _bank)) return none;
  final r = _engine.parse(text, senderId: _bank);
  final t = r.transaction;
  if (!r.isTransaction || t == null) return none;
  final credit = t.type == TransactionType.income ||
      t.type == TransactionType.refund ||
      (t.type == TransactionType.transfer &&
          DirectionSignal.detect(text) == TxnDirection.credit);
  return (
    recorded: true,
    credit: credit,
    amount: t.amount,
    currency: t.currency,
    type: t.type
  );
}

String _meaning(String text) {
  final m = ParserEngine.meaningOf(text);
  return '${m.kind.name}:${m.reason}';
}

/// The import validator's verdict on a forged "completed, at [answer]" row.
String? _forged(String text, num answer, String currency, bool credit) =>
    validateCaptureCandidate(
      candidate: CaptureCandidate(
        amount: answer.toDouble(),
        amountText: answer == answer.roundToDouble()
            ? answer.toStringAsFixed(0)
            : answer.toString(),
        currency: currency,
        direction: credit ? 'credit' : 'debit',
        type: credit ? 'refund' : 'payment',
      ),
      text: text,
      receivedAt: DateTime.utc(2026, 11, 17, 10),
    ).reason;

void main() {
  group('the reviewer and real-model probes (follow_up6_cases.json)', () {
    final cases =
        ((jsonDecode(File('${_dir}follow_up6_cases.json').readAsStringSync())
                as Map<String, dynamic>)['cases'] as List)
            .cast<Map<String, dynamic>>();
    for (final c in cases) {
      final text = c['text'] as String;
      final kind = c['kind'] as String;
      final pinned = c['device'] as String?;
      final answer = c['answer'] as num;
      final label = text.length > 110 ? '${text.substring(0, 110)}…' : text;
      test(
          '${c['id']} [$kind${pinned == null ? '' : ' device=$pinned'}] $label',
          () {
        final o = _device(text);
        final meaning = ParserEngine.meaningOf(text);
        if (c['round5'] != null) {
          // Round 5 (owner decision): a movement that is not clearly
          // completed is a visible review row, and no answer of "completed"
          // is accepted for it.
          expect(o.recorded, isFalse);
          expect(meaning.disposition, MessageDisposition.review);
          expect(AiCandidateValidator.meaningRejectionOf(text, amount: answer),
              isNotNull);
          return;
        }
        if (kind == 'n' || kind == 'r') {
          expect(o.recorded, isFalse);
          // No answer is accepted for it: not by the hold every import path
          // applies, not by the rule both validators share, not by the
          // import validator.
          expect(meaningHoldReason(text, amount: answer), isNotNull);
          expect(AiCandidateValidator.meaningRejectionOf(text, amount: answer),
              isNotNull);
          expect(_forged(text, answer, 'SAR', false), isNotNull);
          expect(_forged(text, answer, 'EGP', false), isNotNull);
          if (kind == 'r') {
            // Visible in review with a reason, never silent.
            expect(meaning.disposition, MessageDisposition.review);
            expect(meaning.reason, isNotEmpty);
            expect(
                ParserEngine.isIgnoredMessage(text, senderId: _bank), isFalse);
            expect(_engine.parse(text, senderId: _bank).amountDetected, isTrue);
          }
          return;
        }
        // A completed movement is never a no-movement notice.
        expect(meaning.disposition, MessageDisposition.record);
        if (kind == 't') {
          expect(o.recorded, isTrue);
          expect(o.type, TransactionType.transfer);
          return;
        }
        // The right answer passes every gate.
        expect(meaningHoldReason(text, amount: answer), isNull);
        expect(AiCandidateValidator.meaningRejectionOf(text, amount: answer),
            isNull);
        if (pinned == 'review') {
          expect(o.recorded, isFalse);
          return;
        }
        expect(o.recorded, isTrue);
        expect(o.credit, kind == 'c');
        expect(o.amount, closeTo((c['amount'] as num).toDouble(), 0.005));
        expect(o.currency, c['currency']);
      });
    }
  });

  test('awaited and attempted operations are not completed (CUE-1)', () {
    for (final t in [
      'Purchase SAR 45.00 at Jarir card *4521. Awaiting merchant confirmation',
      'Attempted purchase SAR 45.00 at Jarir card *4521',
      'شراء 45 ريال لدى جرير بطاقة 4521. بانتظار تأكيد التاجر',
      'محاولة شراء 45 ريال لدى جرير بطاقة 4521',
    ]) {
      expect(_meaning(t), startsWith('notCompleted:'), reason: t);
    }
  });

  test('a future charge or credit is a notice, also for a bill with parts',
      () {
    for (final t in [
      'You will receive SAR 500.00 cashback on 01/12',
      'Bill SAR 200.00, VAT SAR 30.00, total SAR 230.00 will be charged tomorrow',
      'سوف تستلم 500 ريال استرداد نقدي بتاريخ 01/12',
    ]) {
      expect(_meaning(t), startsWith('noMovementNotice:'), reason: t);
    }
  });

  test('general advice about refunds or standing orders is a footer', () {
    expect(
        ParserEngine.isGeneralAdvice(
            'Refund requests will be processed within 7 days'),
        isTrue);
    expect(
        ParserEngine.isGeneralAdvice(
            'الأوامر المستديمة تنفذ في تاريخ الاستحقاق'),
        isTrue);
    expect(
        ParserEngine.isGeneralAdvice(
            'A refund has been initiated and will be credited within 5 days'),
        isFalse);
    expect(ParserEngine.isGeneralAdvice('Refund of SAR 99.00 will be processed'),
        isFalse);
  });

  test('a refund whose clause states the credit happened is completed', () {
    expect(
        ParserEngine.refundCredited(
            'your expected refund of sar 150.00 from noon has been credited to your card'),
        isTrue);
    expect(
        ParserEngine.refundCredited(
            'your expected refund of sar 150.00 will be credited within 5 days'),
        isFalse);
  });

  test('a labelled total that was paid is the amount; never with a status word',
      () {
    expect(
        ParserEngine.paidTotal(
                'bill sar 200.00, vat sar 30.00, total sar 230.00 paid')
            ?.value,
        230);
    expect(
        ParserEngine.paidTotal(
            'bill sar 200.00, vat sar 30.00, total sar 230.00'),
        isNull);
    expect(
        ParserEngine.paidTotal(
            'bill sar 200.00, vat sar 30.00, total sar 230.00 will be paid tomorrow'),
        isNull);
    expect(
        ParserEngine.paidTotal(
            'bill sar 200.00, vat sar 30.00, total sar 230.00 paid. transaction reversed'),
        isNull);
  });

  test('a bare operation with no verb, type or merchant is unspecified', () {
    expect(
        ParserEngine.isUnspecifiedOperation(
            'عملية بمبلغ 500 egp على بطاقتك *4521'),
        isTrue);
    expect(
        ParserEngine.isUnspecifiedOperation(
            'عملية شراء بمبلغ 500 egp على بطاقتك *4521'),
        isFalse);
    expect(
        ParserEngine.isUnspecifiedOperation(
            'transaction of egp 500.00 at carrefour on your card *4521'),
        isFalse);
  });
}
