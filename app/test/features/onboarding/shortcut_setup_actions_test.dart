import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/shortcut_setup_actions.dart';

void main() {
  Future<void> goToTest(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.ensureVisible(find.byKey(const Key('shortcut_next')));
      await tester.tap(find.byKey(const Key('shortcut_next')));
      await tester.pumpAndSettle();
    }
  }

  Future<void> show(WidgetTester tester, ShortcutSetupActions actions, {String language = 'en'}) async {
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light, locale: Locale(language),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: Scaffold(body: SingleChildScrollView(child: actions))));
    await tester.pumpAndSettle();
    final selected = find.byKey(ValueKey('shortcut_choose_${actions.currencyCode}'));
    await tester.ensureVisible(selected);
    await tester.tap(selected);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('shortcut_begin')));
    await tester.tap(find.byKey(const Key('shortcut_begin')));
    await tester.pumpAndSettle();
  }

  testWidgets('install opens the actual public template without claiming connection', (tester) async {
    Uri? opened;
    await show(tester, ShortcutSetupActions(openUrl: (uri) async { opened = uri; return true; }));
    await tester.tap(find.byKey(const Key('shortcut_install')));
    await tester.pump();
    expect(opened.toString(), qirshShortcutInstallUrl);
    expect(find.byKey(const Key('shortcut_verified')), findsNothing);
  });

  testWidgets('a stale probe cannot confirm a newly requested test', (tester) async {
    Uri? opened;
    await show(tester, ShortcutSetupActions(openUrl: (uri) async { opened = uri; return true; }, readProbe: () async => 1));
    await goToTest(tester);
    await tester.ensureVisible(find.byKey(const Key('shortcut_test')));
    await tester.tap(find.byKey(const Key('shortcut_test')));
    await tester.pump();
    expect(opened?.queryParameters['text'], qirshShortcutProbe);
    expect(opened?.queryParameters['name'], 'QIRSH');
    expect(find.byKey(const Key('shortcut_waiting')), findsOneWidget);
    expect(find.byKey(const Key('shortcut_verified')), findsNothing);
  });

  testWidgets('only a fresh native receipt verifies the shortcut', (tester) async {
    await show(tester, ShortcutSetupActions(openUrl: (_) async => true,
      readProbe: () async => DateTime.now().millisecondsSinceEpoch + 10));
    await goToTest(tester);
    await tester.ensureVisible(find.byKey(const Key('shortcut_test')));
    await tester.tap(find.byKey(const Key('shortcut_test')));
    await tester.pump();
    expect(find.byKey(const Key('shortcut_verified')), findsOneWidget);
  });

  testWidgets('Arabic setup uses localized actions', (tester) async {
    await show(tester, const ShortcutSetupActions(), language: 'ar');
    expect(find.text('إضافة اختصار قرش'), findsOneWidget);
    await goToTest(tester);
    expect(find.text('اختبار الاتصال'), findsOneWidget);
  });

  testWidgets('visual steps explain filter and automation before harmless test', (tester) async {
    await show(tester, const ShortcutSetupActions(currencyCode: 'SAR'));
    await tester.tap(find.byKey(const Key('shortcut_next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Message contains to SAR'), findsOneWidget);
    expect(find.descendant(of: find.byType(Scaffold).last,
        matching: find.byType(Image)), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('shortcut_next')));
    await tester.tap(find.byKey(const Key('shortcut_next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('shortcut_next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Confirm Before Run OFF'), findsOneWidget);
    expect(find.byKey(const Key('shortcut_verified')), findsNothing);
  });
  testWidgets('reference opens for zoom and the guide works at larger text size', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: AppTheme.dark,
      locale: const Locale('ar'), supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.4)), child: child!),
      home: const Scaffold(body: SingleChildScrollView(child: ShortcutSetupActions()))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('shortcut_choose_EGP')));
    await tester.tap(find.byKey(const ValueKey('shortcut_choose_EGP')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('shortcut_begin')));
    await tester.tap(find.byKey(const Key('shortcut_begin')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('shortcut_next')));
    await tester.tap(find.byKey(const Key('shortcut_next')));
    await tester.pumpAndSettle();
    final reference=find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == 'تكبير صورة إعداد الاختصار في iOS');
    await tester.ensureVisible(reference);
    await tester.tap(reference);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
