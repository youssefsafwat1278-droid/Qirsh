import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/features/cards/brand_mark.dart';
import 'package:money_companion/features/common/app_transaction_row.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  testWidgets('AI rows show a sparkle, not the «Smart» pill, and keep the AI '
      'wording in semantics', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(ProviderScope(
      overrides: [remoteMerchantLogosAllowedProvider.overrideWithValue(false)],
      child: MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: AppL10n.localizationsDelegates,
        home: const Scaffold(
          body: AppTransactionRow(
            title: 'Local shop',
            amount: 12,
            currency: 'EGP',
            isAi: true,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(AppTransactionRow)));
    final sparkle = find.byIcon(AppLucideIcons.sparkles);
    expect(sparkle, findsOneWidget);
    expect(tester.widget<Icon>(sparkle).size, 12);
    expect(find.text(l.commonSmart), findsNothing);
    expect(find.bySemanticsLabel(RegExp(RegExp.escape(l.a11yAi))),
        findsWidgets);
    handle.dispose();
  });
}
