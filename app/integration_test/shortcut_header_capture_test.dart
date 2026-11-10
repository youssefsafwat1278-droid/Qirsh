import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/shortcut_setup_actions.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Qirsh guide header remains readable in both themes', (tester) async {
    for (final dark in [false, true]) {
      await tester.pumpWidget(MaterialApp(
        key: ValueKey(dark), debugShowCheckedModeBanner: false,
        theme: dark ? AppTheme.dark : AppTheme.light, locale: const Locale('ar'),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: AppL10n.localizationsDelegates,
        home: const Scaffold(body: SingleChildScrollView(
          padding: EdgeInsets.all(16), child: ShortcutSetupActions())),
      ));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('shortcut_begin')));
      await tester.tap(find.byKey(const Key('shortcut_begin')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await File('/private/tmp/qirsh123-header-current').writeAsString(dark ? 'dark' : 'light');
        await Future<void>.delayed(const Duration(seconds: 5));
      });
    }
  });
}
