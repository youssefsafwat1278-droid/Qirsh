import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/validated_capture.dart';
import 'package:money_companion/engine/ai/ai_candidate_validator.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';
import 'package:money_companion/engine/parser/shared_preview_parser.dart';
import 'package:money_companion/engine/parser/transaction_state_cues.dart';

/// DATA-01 / REV-01 / REV-02 / REV-04 / V1-001 residuals — every probe from the audits, run on
/// every on-device path. The table is shared with the server test
/// (`process-ios-sms/parse_test.ts`) so the two runtimes judge the same text.
/// Synthetic messages only.
const _casesPath = '../supabase/functions/process-ios-sms/declined_cases.json';
const _deviationsPath =
    '../supabase/functions/process-ios-sms/declined_cases_deviations.json';
const _notCompleted = 'transaction_not_completed';

void main() {
  final table =
      jsonDecode(File(_casesPath).readAsStringSync()) as Map<String, dynamic>;
  final cases = (table['cases'] as List).cast<Map<String, dynamic>>();
  const engine = ParserEngine();
  final preview = SharedPreviewParser.fromJsonString(
      File('assets/catalog/parser_rules.json').readAsStringSync());

  test('the table covers all outcomes', () {
    // V1-RES5 (NR-05): `expect` is the true outcome of the text; `device`
    // is the on-device outcome where it knowingly differs (no total change).
    expect(cases.map((c) => c['expect']).toSet(), {
      'not_completed',
      'completed_payment',
      'completed_credit',
      'completed_income',
      'completed_withdrawal',
      'completed_transfer_in',
      // Round 10 (Q's probes): money moved between the user's own accounts.
      'completed_transfer_own',
      'ignored',
    });
    expect(cases.map((c) => c['device']).whereType<String>().toSet(), {
      'review',
      'not_completed',
      'transfer',
      // Round 9: no amount read (a bank sender's Smart Inbox card), and an
      // incoming transfer recorded as income (same direction).
      'dropped',
      'completed_income',
      // Round 10: open defects carried from the baseline ([defect] rows only).
      'completed_payment',
      'completed_credit',
    });
  });

  // Round 8 (item 6) — a deviation can only make a completed row MORE
  // visible than recorded (review, a recoverable server leg), never silent,
  // never another amount, never another direction unless it is a pinned open
  // defect; and the SET of deviating rows is pinned by a checked-in
  // allowlist, so adding or editing a deviation means editing it too.
  test('deviations are constrained and pinned', () {
    final allow = jsonDecode(File(_deviationsPath).readAsStringSync())
        as Map<String, dynamic>;
    final pinned = (allow['rows'] as List).cast<Map<String, dynamic>>();
    String key(Map<String, dynamic> c) => jsonEncode([
          c['text'],
          c['device'],
          c['server'],
          c['ai'],
          c['defect'],
        ]);
    final deviating = cases.where((c) =>
        c['device'] != null ||
        c['server'] != null ||
        c['ai'] != null ||
        c['defect'] != null);
    expect(pinned.length, allow['count']);
    expect(deviating.map(key).toSet(), pinned.map(key).toSet());
    expect(deviating.length, allow['count']);
    for (final c in cases) {
      final completed = (c['expect'] as String).startsWith('completed_');
      if (!completed) continue;
      expect(c['amount'], isA<num>(), reason: '${c['text']}');
      // Completed rows are run with a bank sender: never ignored (silent).
      // ('dropped' = no amount read: a Smart Inbox card, asserted below.)
      expect(c['device'], isNot('ignored'), reason: '${c['text']}');
      expect(['dropped', 'ignored'], isNot(contains(c['server'])),
          reason: '${c['text']}');
      // Round 9 (PR-01): another recorded outcome is only ever the same
      // direction — a credit row never deviates to a payment or withdrawal,
      // a debit row never to income or a refund — unless it is a pinned open
      // defect (below).
    }
    // Round 10: Q's probes are in the table with their hand truth, so the
    // outcomes the code still gets wrong (each the same as, or better than,
    // at ab5dc10a) are pinned as open defects: a recorded outcome in the
    // other direction, or for a row that is not a completed movement or is a
    // transfer between own accounts, on either side. Only those rows carry a
    // defect, and only Q's rows (V1-RES10) may.
    const credit = {
      'completed_credit',
      'completed_income',
      'completed_transfer_in'
    };
    for (final c in cases) {
      final want = c['expect'] as String;
      bool wrong(String? side) {
        if (side == null) return false;
        if (!want.startsWith('completed_')) {
          return side.startsWith('completed_') || side == 'transfer';
        }
        if (!side.startsWith('completed_')) return false;
        return want == 'completed_transfer_own' ||
            credit.contains(side) != credit.contains(want);
      }

      if (wrong(c['device'] as String?) || wrong(c['server'] as String?)) {
        expect(c['defect'], isA<String>(), reason: '${c['text']}');
      }
      if (c['defect'] != null) {
        expect(c['src'], startsWith('V1-RES10 '), reason: '${c['text']}');
      }
    }
  });

  for (final c in cases) {
    final text = c['text'] as String;
    final expected = (c['device'] ?? c['expect']) as String;
    final review = expected == 'not_completed';
    final completed = (c['expect'] as String).startsWith('completed_');

    test('[${c['src']}] ${c['expect']}/$expected: $text', () {
      expect(TransactionStateCues.isNotCompleted(text), review,
          reason: 'cue verdict');

      // On-device parse (also what the iOS import's local fallback runs).
      final r = engine.parse(text, senderId: 'AlRajhi');
      // FR-13: an ignore word on a transaction message (a security footer)
      // is a review row, never a silent drop; a real OTP/promotion is dropped.
      if (expected == 'review' || expected == 'ignored') {
        final ignored = expected == 'ignored';
        expect(r.isTransaction, isFalse, reason: 'never confirmed money');
        expect(r.amountDetected, !ignored, reason: 'review row');
        expect(
            ParserEngine.isIgnoredMessage(text, senderId: 'AlRajhi'), ignored);
        // Round 8: a completed fee the device keeps for review (its amount is
        // set aside, OR-03) may get the detailed preview; one held back by an
        // ignore word or a notice line, or anything not completed, never does.
        // (Round 10: an open defect of Q's — as at ab5dc10a — pins a notice
        // that still gets the detailed preview.)
        if ((c['defect'] as String? ?? '')
            .contains('detailed purchase preview')) {
          expect(preview.parse(text).isHighConfidence, isTrue,
              reason: 'preview');
        } else if (!(c['expect'] as String).startsWith('completed_') ||
            ParserEngine.hasIgnoreWord(text.toLowerCase()) ||
            ParserEngine.isNoticeMessage(text)) {
          expect(preview.parse(text).isHighConfidence, isFalse,
              reason: 'preview');
        } else {
          expect(preview.parse(text).outcome, isNot(PreviewOutcome.ignored),
              reason: 'preview');
        }
        return;
      }
      // OR-03: a recorded completed row carries the table's amount (never a
      // limit, balance or code figure).
      // (An open defect row pins its type only: its amount may be the one
      // the baseline read.)
      if (r.isTransaction &&
          (c['expect'] as String).startsWith('completed_') &&
          c['defect'] == null) {
        // (or, for a foreign purchase, the foreign amount in its currency,
        // as on the server).
        final foreign = c['foreign'] as Map<String, dynamic>?;
        if (foreign != null &&
            r.transaction!.currency == foreign['currency']) {
          expect(r.transaction!.amount,
              closeTo((foreign['amount'] as num), 0.005),
              reason: 'amount');
        } else {
          expect(r.transaction!.amount, closeTo((c['amount'] as num), 0.005),
              reason: 'amount');
        }
        // Round 9: and the currency the text names.
        if (c['currency'] != null && foreign == null) {
          expect(r.transaction!.currency, c['currency'], reason: 'currency');
        }
      }
      switch (expected) {
        case 'not_completed':
          expect(r.isTransaction, isFalse, reason: 'never confirmed money');
          // Transaction-shaped: the capture becomes a Smart Inbox review row.
          expect(r.amountDetected, isTrue);
          expect(ParserEngine.isIgnoredMessage(text, senderId: 'AlRajhi'),
              isFalse);
        case 'completed_payment':
          expect(r.isTransaction, isTrue);
          expect(r.transaction!.type, TransactionType.payment);
        case 'completed_credit':
          expect(r.isTransaction, isTrue);
          // A refund or reversal returns money: the refund type, which nets
          // against spend (never income, never a payment).
          expect(r.transaction!.type, TransactionType.refund);
        // V1-RES4 (LR-04): a genuine salary/deposit, cash withdrawal or
        // incoming transfer is still recorded.
        case 'completed_income':
          expect(r.isTransaction, isTrue);
          expect(r.transaction!.type, TransactionType.income);
        case 'completed_withdrawal':
          expect(r.isTransaction, isTrue);
          expect(r.transaction!.type, TransactionType.withdrawal);
        case 'completed_transfer_in':
        case 'completed_transfer_own':
        case 'transfer':
          expect(r.isTransaction, isTrue);
          expect(r.transaction!.type, TransactionType.transfer);
        // NR-01: no amount read (a fee line the extractor does not take):
        // not recorded, but never silently ignored — a bank sender's
        // capture becomes a Smart Inbox card.
        case 'dropped':
          expect(r.isTransaction, isFalse);
          expect(r.amountDetected, isFalse);
          expect(ParserEngine.isIgnoredMessage(text, senderId: 'AlRajhi'),
              isFalse);
      }

      // Dart notification preview (V1-061): it judges declined cues with
      // [TransactionStateCues], so a message that did not complete never
      // gets the detailed "purchase detected" notification (tashkeel and
      // tatweel forms included), and a completed one whose merchant name or
      // advice contains a cue word is not reduced to the generic one.
      // (The Swift preview still matches the asset's list by substring.)
      final p = preview.parse(text);
      // Round 9: nothing recorded (no amount read) never gets the detailed
      // preview either.
      if (expected == 'dropped' && completed) {
        // A completed movement whose amount the device does not read: the
        // preview may still describe it.
      } else if (review || expected == 'dropped') {
        expect(p.isHighConfidence, isFalse, reason: 'preview');
      } else if (p.outcome == PreviewOutcome.ignored) {
        // Round 9: the sender-less preview stays generic only for a text the
        // sender-less engine does not record (recorded with the bank's
        // profile) and that an ignore or notice word holds back.
        expect(engine.parse(text).isTransaction, isFalse, reason: 'preview');
        expect(
            ParserEngine.hasIgnoreWord(text.toLowerCase()) ||
                ParserEngine.isNoticeMessage(text) ||
                ParserEngine.isNonTransactionText(text),
            isTrue,
            reason: 'preview');
      }

      // AI-validated and AI-primary candidates, in either direction.
      for (final type in ['payment', 'refund']) {
        final v = const AiCandidateValidator().validate(
          response: AiParseResponse(
              amount: 100, amountText: '100.00', currency: 'SAR', type: type),
          sanitizedText: text,
          localParsed: null,
          messageText: text,
          normalizedType: type == 'payment'
              ? TransactionType.payment
              : TransactionType.refund,
        );
        if (review) {
          expect(v.accepted, isFalse, reason: 'AI $type');
          expect(v.rejectionReason, _notCompleted, reason: 'AI $type');
        } else {
          expect(v.rejectionReason, isNot(_notCompleted), reason: 'AI $type');
        }
        // NR-02: a notice or footer word on a real movement never makes the
        // validator call it "not a transaction" — except the pinned rows
        // (`ai`) with a notice line and no money word, which the AI may not
        // confirm (they stay in review).
        if ((c['expect'] as String).startsWith('completed_')) {
          if (c['ai'] == 'not_a_transaction') {
            // Rejected (whichever check reports it first), and the text is
            // one the validator calls not a transaction, as on the server.
            expect(v.accepted, isFalse, reason: 'AI $type');
            expect(ParserEngine.isNonTransactionText(text), isTrue,
                reason: 'AI $type');
          } else {
            expect(v.rejectionReason, isNot('not_a_transaction'),
                reason: 'AI $type');
          }
        }
      }

      // Server-processed result imported on iOS (REV-03).
      for (final direction in ['debit', 'credit']) {
        final v = validateCaptureCandidate(
          candidate: CaptureCandidate(
              amount: 100,
              amountText: '100.00',
              currency: 'SAR',
              direction: direction),
          text: text,
          receivedAt: DateTime.utc(2026, 11, 17),
        );
        if (review) {
          expect(v.accepted, isFalse, reason: 'import $direction');
          expect(v.reason, _notCompleted, reason: 'import $direction');
        } else {
          expect(v.reason, isNot(_notCompleted), reason: 'import $direction');
          // FR-02: a server answer in the opposite direction to the device's
          // own reading is never imported as confirmed (import-path rule).
          // (A text the device cannot read, or reads as a transfer, keeps the
          // server result.)
          final local = engine.parse(text);
          final localDirection = !local.isTransaction
              ? null
              : local.transaction!.type.isExpense
                  ? 'debit'
                  : local.transaction!.type == TransactionType.transfer
                      ? null
                      : 'credit';
          expect(localParseOpposesDirection(text: text, direction: direction),
              localDirection != null && localDirection != direction,
              reason: 'opposite import $direction');
        }
      }
    });
  }
}
