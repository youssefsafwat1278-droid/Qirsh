import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/l10n_ext.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/cards/brand_mark.dart';
import 'package:money_companion/features/common/app_transaction_row.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('merchant and Smart share the original title line',
      (tester) async {
    for (final (language, dark) in [
      ('en', false),
      ('ar', false),
      ('en', true),
      ('ar', true),
    ]) {
      var opened = false;
      final ar = language == 'ar';
      final subtitle = ar ? '9:59 م · تحويلات' : '9:59 PM · Transfers';
      await tester.pumpWidget(ProviderScope(
        key: ValueKey('$language-$dark'),
        overrides: [
          remoteMerchantLogosAllowedProvider.overrideWithValue(false)
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: dark ? AppTheme.dark : AppTheme.light,
          locale: Locale(language),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: Scaffold(
            appBar: AppBar(title: Text(ar ? 'العمليات' : 'Transactions')),
            body: SafeArea(
                child: ListView(children: [
              AppTransactionRow(
                key: const ValueKey('preview-smart-transaction'),
                title: 'InstaPay',
                amount: 100,
                amountMoney: Money(10000, 'EGP'),
                currency: 'EGP',
                isAi: true,
                subtitle: subtitle,
                onTap: () => opened = true,
              ),
              const Divider(),
              AppTransactionRow(
                title: ar ? 'دخل' : 'Income',
                amount: 2000,
                amountMoney: Money(200000, 'EGP'),
                currency: 'EGP',
                isDebit: false,
                subtitle: ar ? '8:30 م · دخل' : '8:30 PM · Income',
              ),
              const Divider(),
              AppTransactionRow(
                title: 'Netflix',
                amount: 250,
                amountMoney: Money(25000, 'EGP'),
                currency: 'EGP',
                subtitle: ar ? '7:15 م · اشتراكات' : '7:15 PM · Subscriptions',
                isPending: true,
              ),
              const Divider(),
              AppTransactionRow(
                title: ar ? 'تاجر محلي' : 'Local merchant',
                amount: 9007199254740.993,
                amountMoney: Money(9007199254740993, 'KWD'),
                currency: 'KWD',
                subtitle: ar ? '6:20 م · مشتريات' : '6:20 PM · Shopping',
              ),
            ])),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('preview-smart-transaction'));
      final label = tester.element(row).l10n.commonSmart;
      final titleBounds = tester
          .getRect(find.descendant(of: row, matching: find.text('InstaPay')));
      final badgeBounds =
          tester.getRect(find.descendant(of: row, matching: find.text(label)));
      final subtitleBounds = tester
          .getRect(find.descendant(of: row, matching: find.text(subtitle)));
      expect(
          (titleBounds.center.dy - badgeBounds.center.dy).abs(), lessThan(3));
      expect(subtitleBounds.top, greaterThanOrEqualTo(titleBounds.bottom));
      await tester.tap(row);
      expect(opened, isTrue);
      expect(find.text('−9,007,199,254,740.993'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final mode = dark ? 'dark' : 'light';
      final name = 'transaction-rows-$language-$mode';
      final screenshot = await binding.takeScreenshot(name);
      const directory = String.fromEnvironment('QIRSH_ROW_PREVIEW_DIR');
      if (directory.isNotEmpty) {
        await File('$directory/$name.png').writeAsBytes(screenshot);
      }
    }
  });
}
