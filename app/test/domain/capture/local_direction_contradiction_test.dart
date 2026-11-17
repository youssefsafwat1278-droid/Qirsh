import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/validated_capture.dart';

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
