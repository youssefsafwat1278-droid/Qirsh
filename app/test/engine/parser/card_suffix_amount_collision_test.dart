import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// Real-device finding (2026-11-12, tablet, consent off): a synthetic SNB-layout
/// purchase of SAR 9.75 produced neither a transaction nor a review item.
///
/// REPRODUCED: the amount candidate `9.75` was classified as a card's last four
/// digits because the rule tested `raw.length == 4` (four CHARACTERS) on a line
/// with card context. Every two-decimal amount from 1.00 to 9.99, one-decimal
/// amounts like 99.5, and four-digit whole amounts written next to a currency
/// were discarded, the parse failed, and the capture was silently ignored.
String _snb(String amount) => 'عملية شراء بطاقة:مدى;****4521 مبلغ:SAR $amount '
    'لدى:CAFE في:2026-04-10 08:05 الرصيد:SAR 8,914.05';

void main() {
  const sender = '+201000000000';
  const engine = ParserEngine();

  group('an amount is never mistaken for a card suffix', () {
    for (final (text, value) in const [
      ('9.75', 9.75),
      ('5.00', 5.00),
      ('1.50', 1.50),
      ('9.99', 9.99),
      ('99.5', 99.5),
      ('1500', 1500.0),
    ]) {
      test('SAR $text in a card purchase is the amount', () {
        final r = engine.parse(_snb(text), senderId: sender);
        expect(r.isTransaction, isTrue);
        expect(r.transaction!.amount, value);
        expect(r.transaction!.cardLast4, '4521');
      });
    }

    test('English layout: SAR 7.50 with a card ending is the amount', () {
      final r = engine.parse(
        'Purchase of SAR 7.50 with card ending 4521 at CAFE on 2026-04-10',
        senderId: sender,
      );
      expect(r.isTransaction, isTrue);
      expect(r.transaction!.amount, 7.50);
      expect(r.transaction!.cardLast4, '4521');
    });
  });

  group('a real card suffix is still a card suffix', () {
    test('masked suffix followed directly by a currency stays the card', () {
      final r = engine.parse(
        'شراء بطاقة مدى ****4521 SAR 50.00 لدى:SHOP في:2026-04-10 08:05',
        senderId: sender,
      );
      expect(r.isTransaction, isTrue);
      expect(r.transaction!.amount, 50.00);
      expect(r.transaction!.cardLast4, '4521');
    });

    test('"ending 4521" before a currency stays the card', () {
      final r = engine.parse(
        'Purchase with card ending 4521 SAR 12.00 at SHOP on 2026-04-10',
        senderId: sender,
      );
      expect(r.isTransaction, isTrue);
      expect(r.transaction!.amount, 12.00);
      expect(r.transaction!.cardLast4, '4521');
    });

    test('the ten-plus amounts that already worked are unchanged', () {
      for (final (text, value) in const [('18.40', 18.40), ('35.60', 35.60)]) {
        final r = engine.parse(_snb(text), senderId: sender);
        expect(r.transaction!.amount, value);
        expect(r.transaction!.cardLast4, '4521');
      }
    });
  });
}
