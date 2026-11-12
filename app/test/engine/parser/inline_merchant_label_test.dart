import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// Real-device finding (2026-11-12, tablet, consent off): a locally parsed
/// purchase showed the title "Other" — the CATEGORY name standing in for a
/// missing merchant. The SMS arrived as one line, so `لدى:BAKERY` was mid-line:
/// - `_merchant` anchors on `^` or `\b`, and Dart's `\b` only knows ASCII word
///   characters, so a mid-line Arabic label never matched — merchant = null
///   for any sender without a bank profile;
/// - with a bank profile, the bare `لدى` token kept the colon and the date and
///   balance clauses (`في:` / `الرصيد:` were only cut before whitespace).
/// The merchant is identity, not category: this test pins the merchant field
/// only; categorisation of an unknown merchant is unchanged.
const _oneLine = 'عملية شراء بطاقة:مدى;****4521 مبلغ:SAR 35.60 لدى:BAKERY '
    'في:2026-04-10 08:05 الرصيد:SAR 8,914.05';

void main() {
  const engine = ParserEngine();

  for (final sender in ['+201000000000', 'SNB', 'AlRajhiBank']) {
    test('one-line "لدى:BAKERY" keeps the merchant (sender $sender)', () {
      final r = engine.parse(_oneLine, senderId: sender);
      expect(r.isTransaction, isTrue);
      expect(r.transaction!.rawMerchant, 'BAKERY');
      expect(r.transaction!.amount, 35.60);
    });
  }

  test('multi-line, date on the merchant line: the date is cut off', () {
    final r = engine.parse(
      'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 35.60\n'
      'لدى:BAKERY في:2026-04-10 08:05\nالرصيد:SAR 8,914.05',
      senderId: '+201000000000',
    );
    expect(r.transaction!.rawMerchant, 'BAKERY');
  });

  test('a mid-line preposition without a colon is not taken as a label', () {
    final r = engine.parse(
      'تم خصم مبلغ SAR 20.00 من حسابك ****4521 في 2026-04-10',
      senderId: '+201000000000',
    );
    expect(r.transaction?.rawMerchant, isNot(startsWith('حسابك')));
  });
}
