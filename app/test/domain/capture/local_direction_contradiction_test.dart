import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/validated_capture.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// FR-02 — a server-processed capture is not imported as confirmed when the
/// device's own deterministic parse of the same text reads the opposite money
/// direction (applied by both import paths, outside the v1 contract). Only
/// debit vs credit counts; a text the device cannot read, or reads as a
/// transfer, keeps today's import. Synthetic messages only.
void main() {
  const credit = 'تم استرجاع مبلغ 100.00 ريال إلى حسابك';
  const debit = 'Purchase of SAR 100.00 at CAFE ONE card **1234. '
      'Disputed purchases may be reversed';

  test('the opposite direction is flagged; the same direction is not', () {
    expect(localParseOpposesDirection(text: credit, direction: 'debit'), isTrue);
    expect(localParseOpposesDirection(text: debit, direction: 'credit'), isTrue);
    expect(
        localParseOpposesDirection(text: credit, direction: 'credit'), isFalse);
    expect(localParseOpposesDirection(text: debit, direction: 'debit'), isFalse);
  });

  test('a type alone implies the server direction', () {
    expect(localParseOpposesDirection(text: credit, type: 'payment'), isTrue);
    expect(localParseOpposesDirection(text: credit, type: 'refund'), isFalse);
    expect(localParseOpposesDirection(text: credit, type: 'transfer'), isFalse,
        reason: 'no server direction: nothing to disagree with');
  });

  test('LR-09: the device reads the text with the capture sender', () {
    // Golden fixture sa_anb_atm_deposit_income: with its sender the device
    // reads income (a credit), so the server's credit is not opposed.
    const anbDeposit =
        'إيداع ATM\nبـ:SAR 4000.00\nالحساب:0017\nبطاقة، مدى،1922\nفي:26-06-15 10:47';
    expect(
        localParseOpposesDirection(
            text: anbDeposit, direction: 'credit', senderId: 'anb'),
        isFalse);
  });

  test('LR-04: a text the device drops as not a transaction contradicts any '
      'server result', () {
    const notice = 'Your credit limit has been changed to SAR 15,000.00';
    expect(localParseContradictsServer(text: notice, direction: 'credit'),
        isTrue);
    expect(localParseContradictsServer(text: credit, direction: 'debit'),
        isTrue, reason: 'the opposite direction');
    expect(localParseContradictsServer(text: credit, direction: 'credit'),
        isFalse);
    expect(localParseContradictsServer(text: debit, direction: 'debit'),
        isFalse);
  });

  test('NR-01: a purchase carrying a limit or activation line keeps the '
      'server result; a notice with an amount does not', () {
    for (final text in [
      'Purchase\nCard ending 4521\nAmount SAR 45.00\nAt BURGER BOUTIQUE\n'
          'Available Credit Limit: SAR 9,000.00',
      'Purchase of SAR 100.00 at SHOPX on your newly activated card *1234',
    ]) {
      expect(
          localParseContradictsServer(
              text: text, direction: 'debit', senderId: 'AlRajhi'),
          isFalse,
          reason: text);
    }
    // Kept for review on device (never silently dropped), never confirmed
    // from the server.
    const notice = 'Your credit limit is SAR 15,000';
    expect(ParserEngine.isIgnoredMessage(notice, senderId: 'AlRajhi'), isFalse);
    expect(
        localParseContradictsServer(
            text: notice, direction: 'credit', senderId: 'AlRajhi'),
        isTrue);
  });

  test(
      'OR-03: a server amount the device does not read contradicts it; '
      'none read by the device does not', () {
    const text = 'Purchase of SAR 89.50 at Test Mart with card *4521. '
        'Credit limit: SAR 20,000';
    expect(
        localParseContradictsServer(
            text: text, direction: 'debit', amount: 20000),
        isTrue);
    expect(
        localParseContradictsServer(
            text: text, direction: 'debit', amount: 89.5),
        isFalse);
    // A foreign purchase: the server may read the foreign amount.
    const fx = 'International Online Purchase\nAmount: USD 4.91 (SAR 18.44)\n'
        'At: SNAP INC';
    expect(
        localParseContradictsServer(text: fx, direction: 'debit', amount: 4.91),
        isFalse);
    expect(
        localParseContradictsServer(
            text: fx, direction: 'debit', amount: 18.44),
        isFalse);
    // The device reads no amount: only the other rules apply.
    expect(
        localParseContradictsServer(
            text: 'Card *4521 authorised at Test Diner',
            direction: 'debit',
            amount: 45),
        isFalse);
  });

  test('a transfer or an unreadable text never blocks the server result', () {
    expect(
        localParseOpposesDirection(
            text: 'Transfer of SAR 300.00 to Ali completed',
            direction: 'credit'),
        isFalse);
    expect(localParseOpposesDirection(text: 'SAR 100.00', direction: 'credit'),
        isFalse);
  });
}
