import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/cards/brand_mark.dart';
import 'package:money_companion/features/common/app_transaction_row.dart';
import 'package:money_companion/l10n/app_localizations.dart';

Future<void> showRow(WidgetTester tester, Money money,
    {bool isDebit = true, bool privacy = false}) async {
  await tester.pumpWidget(ProviderScope(overrides: [
    remoteMerchantLogosAllowedProvider.overrideWithValue(false),
  ], child: MaterialApp(theme: AppTheme.light,
    locale: const Locale('ar'), supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates,
    home: Scaffold(body: AppTransactionRow(
      title: 'تاجر محلي', amount: money.toDouble(), amountMoney: money,
      currency: 'دينار', isDebit: isDebit, privacyMode: privacy,
    )),
  )));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Arabic ledger keeps minus physically before the amount and all KWD digits', (tester) async {
    await showRow(tester, Money(1234, 'KWD'));
    final amount = find.text('−1.234');
    expect(amount, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(amount);
    expect(paragraph.textDirection, TextDirection.ltr);
    final sign = paragraph.getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 1)).single;
    // v2 dims the decimals in their own span, so the digits may lay out as
    // more than one box; the minus must sit left of every one of them.
    final digits = paragraph.getBoxesForSelection(const TextSelection(baseOffset: 1, extentOffset: 6));
    expect(digits, isNotEmpty);
    for (final box in digits) {
      expect(sign.left, lessThan(box.left),
          reason: 'The rendered minus must be on the physical left in Arabic.');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('canonical precision survives values beyond exact double integer precision', (tester) async {
    await showRow(tester, Money(9007199254740993, 'KWD'), isDebit: false);
    expect(find.text('+9,007,199,254,740.993'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('zero has no minus and privacy masks canonical digits', (tester) async {
    await showRow(tester, Money(0, 'KWD'));
    expect(find.text('0.000'), findsOneWidget);
    expect(find.textContaining('−0'), findsNothing);
    await showRow(tester, Money(1234, 'KWD'), privacy: true);
    expect(find.text('••••'), findsOneWidget);
    expect(find.textContaining('1.234'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
