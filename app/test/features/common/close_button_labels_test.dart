import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/common/app_sheet_scaffold.dart';
import 'package:money_companion/l10n/app_localizations.dart';

// UX-04: icon-only close (X) buttons carry an accessible name.
void main() {
  for (final language in ['en', 'ar']) {
    testWidgets('shared sheet close button is named ($language)',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        locale: Locale(language),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: AppL10n.localizationsDelegates,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => const AppSheetScaffold(
                    title: 'Synthetic', body: SizedBox(height: 40)),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final close = MaterialLocalizations.of(
              tester.element(find.byType(AppSheetScaffold)))
          .closeButtonTooltip;
      expect(close, isNotEmpty);
      // VoiceOver names the button from its tooltip.
      expect(tester.getSemantics(find.byTooltip(close)).tooltip, close);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await tester.tap(find.byTooltip(close));
      await tester.pumpAndSettle();
      expect(find.byType(AppSheetScaffold), findsNothing);
      semantics.dispose();
    });
  }

  test('every close IconButton named in the audit has a tooltip', () {
    const files = [
      'lib/features/common/app_sheet_scaffold.dart',
      'lib/features/goals/goal_form_screen.dart',
      'lib/features/goals/goal_details_screen.dart',
      'lib/features/budgets/budget_form_screen.dart',
      'lib/features/capture/manual_paste_screen.dart',
      'lib/features/capture/sms_permission_screen.dart',
      'lib/features/coupons/merchant_offers_screen.dart',
      'lib/features/coupons/savings_screen.dart',
      'lib/features/settings/sign_in_methods_sheet.dart',
      'lib/features/onboarding/widgets/email_code_sheet.dart',
    ];
    final closeIcon = RegExp(r'AppLucideIcons\.x\b|Icons\.close\b');
    for (final path in files) {
      final source = File(path).readAsStringSync();
      var checked = 0;
      for (final match in 'IconButton('.allMatches(source)) {
        // The button's own arguments: up to the icon it shows.
        final rest = source.substring(match.end);
        final icon = rest.indexOf('icon:');
        if (icon < 0) continue;
        final args = rest.substring(0, rest.indexOf('\n', icon));
        if (!closeIcon.hasMatch(args)) continue;
        checked++;
        expect(args, contains('tooltip:'), reason: '$path close button');
      }
      expect(checked, greaterThan(0), reason: '$path has a close button');
    }
  });
}
