import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/shortcut_setup_actions.dart';
import 'package:money_companion/features/app/app_boot_loader.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('visual shortcut walkthrough in both languages and themes', (tester) async {
    for (final lang in ['en','ar']) {
      for (final dark in [false,true]) {
        await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, key: ValueKey('loader-$lang-$dark'),
          theme: dark ? AppTheme.dark : AppTheme.light, locale: Locale(lang),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: const AppBootLoader()));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byType(Text), findsNothing);
        await tester.runAsync(() async {
          await File('/private/tmp/qirsh123-visual-current').writeAsString('$lang-${dark ? 'dark' : 'light'}-loader');
          await Future<void>.delayed(const Duration(seconds: 3));
        });
        await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, key: ValueKey('$lang-$dark'),
          theme: dark ? AppTheme.dark : AppTheme.light,
          locale: Locale(lang), supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: Scaffold(appBar: AppBar(title: Text(lang == 'ar' ? 'إعداد اختصار قرش' : 'Qirsh Shortcut Setup')),
            body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(16),
              child: ShortcutSetupActions(openUrl: (_) async => true, readProbe: () async => 0))))));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await File('/private/tmp/qirsh123-visual-current').writeAsString('$lang-${dark ? 'dark' : 'light'}-catalog');
          await Future<void>.delayed(const Duration(seconds: 3));
        });
        await tester.ensureVisible(find.byKey(const ValueKey('shortcut_choose_EGP')));
        await tester.tap(find.byKey(const ValueKey('shortcut_choose_EGP')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('shortcut_begin')));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await File('/private/tmp/qirsh123-visual-current').writeAsString('$lang-${dark ? 'dark' : 'light'}-filter');
          await Future<void>.delayed(const Duration(seconds: 3));
        });
        await tester.tap(find.byKey(const Key('shortcut_begin')));
        for (var step=0;step<5;step++) {
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            await File('/private/tmp/qirsh123-visual-current').writeAsString('$lang-${dark ? 'dark' : 'light'}-$step');
            await Future<void>.delayed(const Duration(seconds: 3));
          });
          if(step<4) {
            await tester.ensureVisible(find.byKey(const Key('shortcut_next')));
            await tester.tap(find.byKey(const Key('shortcut_next')));
          }
        }
      }
    }
  });
}
