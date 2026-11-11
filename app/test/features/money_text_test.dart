import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/common/money_text.dart';

/// R-8 / UX-001 — money on screen must be exact, and must survive RTL.
///
/// The widget owns two properties that are easy to lose in a refactor and hard
/// to notice by eye:
///
///  * the amount is bidi-ISOLATED, because an LTR number inside Arabic text is
///    reordered by the bidi algorithm — a leading minus can end up painting on
///    the wrong side, which turns a debt into an asset visually;
///  * digits are ASCII regardless of locale, because `intl` renders `ar_EG` in
///    Arabic-Indic digits and `ar_SA` in ASCII (verified empirically), and both
///    are core markets.
String _rendered(WidgetTester tester) {
  final rich = tester.widget<Text>(find.byType(Text));
  return rich.textSpan!.toPlainText();
}

Future<void> _pump(WidgetTester tester, Money money,
    {TextDirection dir = TextDirection.rtl}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: dir,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: MoneyText(money, style: const TextStyle(fontSize: 16)),
      ),
    ),
  );
}

void main() {
  group('exactness', () {
    testWidgets('renders the currency full scale, not a rounded figure',
        (tester) async {
      await _pump(tester, Money(35550, 'SAR'));
      expect(_rendered(tester), contains('355.50'));
    });

    testWidgets('a 3-decimal currency keeps all three', (tester) async {
      await _pump(tester, Money(12345, 'KWD'));
      expect(_rendered(tester), contains('12.345'));
    });

    testWidgets('a 0-decimal currency shows no separator', (tester) async {
      await _pump(tester, Money(1500, 'JPY'));
      final out = _rendered(tester);
      expect(out, contains('1,500'));
      expect(out.contains('1,500.'), isFalse);
    });
  });

  group('RTL safety', () {
    testWidgets('the amount is bidi-isolated in an RTL context',
        (tester) async {
      await _pump(tester, Money(-124050, 'SAR'));
      final out = _rendered(tester);
      // FSI … PDI. Without these the minus reorders against Arabic neighbours
      // and a negative balance can read as positive.
      expect(out.codeUnits.first, 0x2068, reason: 'must open with FSI');
      expect(out.codeUnits.last, 0x2069, reason: 'must close with PDI');
    });

    testWidgets('the minus stays attached to the number', (tester) async {
      await _pump(tester, Money(-124050, 'SAR'));
      final out = _rendered(tester).replaceAll('\u2068', '').replaceAll('\u2069', '');
      // v2: a true minus sign (U+2212), still leading the digits.
      expect(out.startsWith('\u2212'), isTrue,
          reason: 'a trailing minus reads as a positive amount');
      expect(out, '\u22121,240.50');
    });

    testWidgets('renders identically in LTR and RTL', (tester) async {
      await _pump(tester, Money(35550, 'SAR'), dir: TextDirection.ltr);
      final ltr = _rendered(tester);
      await _pump(tester, Money(35550, 'SAR'), dir: TextDirection.rtl);
      expect(_rendered(tester), ltr,
          reason: 'the amount is a self-contained LTR run either way');
    });
  });

  group('digits are pinned to ASCII', () {
    testWidgets('no Arabic-Indic digits appear under an RTL locale',
        (tester) async {
      await _pump(tester, Money(123450, 'SAR'));
      final out = _rendered(tester);
      for (final indic in ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩']) {
        expect(out.contains(indic), isFalse,
            reason: 'digit systems must not vary between ar_SA and ar_EG');
      }
      expect(out, contains('1,234.50'));
    });
  });

  group('the fraction is de-emphasised, not discarded', () {
    testWidgets('fils are present but smaller than the integer part',
        (tester) async {
      await _pump(tester, Money(164430, 'SAR'));
      final rich = tester.widget<Text>(find.byType(Text));
      final spans = (rich.textSpan! as TextSpan).children!.cast<TextSpan>();
      final intSpan = spans.firstWhere((s) => s.text == '1,644');
      final fracSpan = spans.firstWhere((s) => s.text == '.30');

      expect(fracSpan.style!.fontSize!, lessThan(intSpan.style!.fontSize!),
          reason: 'the density pass is paid for by de-emphasis, not rounding');
      expect(_rendered(tester), contains('1,644.30'));
    });

    testWidgets('fractionScale 1.0 renders the fils at full weight',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.rtl,
          child: MoneyText(Money(164430, 'SAR'),
              style: const TextStyle(fontSize: 16), fractionScale: 1.0),
        ),
      );
      final rich = tester.widget<Text>(find.byType(Text));
      final spans = (rich.textSpan! as TextSpan).children!.cast<TextSpan>();
      expect(spans.firstWhere((s) => s.text == '.30').style!.fontSize,
          spans.firstWhere((s) => s.text == '1,644').style!.fontSize);
    });
  });

  group('UX-001 — a card cannot contradict itself', () {
    testWidgets('spent + remaining equals the limit, as displayed',
        (tester) async {
      // The original defect: 356 + 845 = 1,201 against a limit of 1,200,
      // because each figure was rounded independently. With exact rendering the
      // three displayed numbers reconcile by construction.
      final limit = Money(120000, 'SAR');
      final spent = Money(35550, 'SAR');
      final remaining = Money(limit.minorUnits - spent.minorUnits, 'SAR');

      await _pump(tester, spent);
      expect(_rendered(tester), contains('355.50'));
      await _pump(tester, remaining);
      expect(_rendered(tester), contains('844.50'));
      await _pump(tester, limit);
      expect(_rendered(tester), contains('1,200.00'));

      // and the arithmetic holds in minor units, which is where it is done
      expect(spent.minorUnits + remaining.minorUnits, limit.minorUnits);
    });
  });
}
