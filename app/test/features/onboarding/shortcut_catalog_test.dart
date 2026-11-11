import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/shortcut_setup_actions.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  Future<void> show(WidgetTester tester, {Future<bool> Function(Uri)? open, double scale = 1}) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('en'),
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(body: SingleChildScrollView(
        child: ShortcutSetupActions(openUrl: open),
      )),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('search chooses USD and editor targets its own published shortcut', (tester) async {
    Uri? opened;
    await show(tester, open: (uri) async { opened = uri; return true; });
    await tester.enterText(find.byKey(const Key('shortcut_search')), 'USD');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shortcut_choose_EGP')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('shortcut_choose_USD')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('shortcut_begin')));
    await tester.tap(find.byKey(const Key('shortcut_begin')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('shortcut_next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Message contains'), findsNothing);
    expect(find.textContaining('Open Qirsh USD in Shortcuts'), findsWidgets);
    expect(find.textContaining('Date Received'), findsNothing);
    await tester.tap(find.byKey(const Key('shortcut_edit')));
    await tester.pump();
    expect(opened?.host, 'open-shortcut');
    expect(opened?.queryParameters['name'], 'Qirsh USD');
  });

  testWidgets('changing currency clears search and selects its matching filter', (tester) async {
    await show(tester);
    await tester.enterText(find.byKey(const Key('shortcut_search')), 'USD');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('shortcut_currency_SAR')));
    await tester.tap(find.byKey(const ValueKey('shortcut_currency_SAR')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('shortcut_search'))).controller!.text, isEmpty);
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('shortcut_choose_SAR'))).selected, isTrue);
    expect(find.byKey(const ValueKey('shortcut_choose_USD')), findsNothing);
  });

  testWidgets('manual completion says reviewed and never claims iOS is On', (tester) async {
    await show(tester, scale: 1.4);
    await tester.ensureVisible(find.byKey(const ValueKey('shortcut_choose_EGP')));
    await tester.tap(find.byKey(const ValueKey('shortcut_choose_EGP')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('shortcut_begin')));
    await tester.tap(find.byKey(const Key('shortcut_begin')));
    await tester.pumpAndSettle();
    // EGP has a dedicated shortcut, so there is no filter step: 4 steps.
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byKey(const Key('shortcut_next')));
      await tester.pumpAndSettle();
    }
    expect(find.text('Steps reviewed'), findsOneWidget);
    expect(find.text('On'), findsNothing);
  });

  testWidgets('large-text compact guide keeps Next above the screen edge', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await show(tester, scale: 1.4);
    await tester.ensureVisible(find.byKey(const ValueKey('shortcut_choose_EGP')));
    await tester.tap(find.byKey(const ValueKey('shortcut_choose_EGP')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('shortcut_begin')));
    await tester.tap(find.byKey(const Key('shortcut_begin')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      final next = find.byKey(const Key('shortcut_next'));
      expect(tester.getBottomRight(next).dy, lessThanOrEqualTo(568));
      if (i < 3) {
        await tester.tap(next);
        await tester.pumpAndSettle();
      }
    }
    expect(tester.takeException(), isNull);
  });
}
