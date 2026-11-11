import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/shortcut_setup_actions.dart';

class _MemoryStore implements ShortcutSetupStore {
  _MemoryStore([Map<String, ShortcutSetupRecord>? records])
      : records = {...?records};
  Map<String, ShortcutSetupRecord> records;
  @override
  Future<Map<String, ShortcutSetupRecord>> load() async => {...records};
  @override
  Future<void> save(Map<String, ShortcutSetupRecord> value) async =>
      records = {...value};
}

void main() {
  Future<void> goToTest(WidgetTester tester) async {
    while (find.byKey(const Key('shortcut_test')).evaluate().isEmpty) {
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

  testWidgets('visual steps explain the shortcut and automation before harmless test', (tester) async {
    await show(tester, const ShortcutSetupActions(currencyCode: 'SAR'));
    expect(find.text('Step 1 of 4'), findsOneWidget);
    await tester.tap(find.byKey(const Key('shortcut_next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Open Qirsh SAR in Shortcuts'), findsWidgets);
    expect(find.descendant(of: find.byType(Scaffold).last,
        matching: find.byType(Image)), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('shortcut_next')));
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

  testWidgets('a dedicated shortcut skips the filter step and runs by its own name', (tester) async {
    final opened = <Uri>[];
    await show(tester, ShortcutSetupActions(openUrl: (uri) async { opened.add(uri); return true; }, store: _MemoryStore()));
    expect(find.text('Step 1 of 4'), findsOneWidget);
    expect(find.textContaining('already listens for messages containing EGP'), findsOneWidget);
    await tester.tap(find.byKey(const Key('shortcut_next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Message contains'), findsNothing);
    await goToTest(tester);
    expect(find.text('Step 4 of 4'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('shortcut_test')));
    await tester.tap(find.byKey(const Key('shortcut_test')));
    await tester.pump();
    expect(opened.last.queryParameters['name'], 'QIRSH');
  });

  test('a keyword without a verified link falls back to the shared template', () {
    const unlinked = ShortcutKeyword('XYZ', 'XYZ', shortcutName: 'Qirsh XYZ');
    expect(unlinked.hasDedicatedShortcut, isFalse);
    expect(unlinked.runName, qirshTemplateShortcutName);
    expect(unlinked.installLink, qirshShortcutInstallUrl);
  });

  testWidgets('USD installs and runs its own published shortcut in 4 steps', (tester) async {
    final opened = <Uri>[];
    await show(tester, ShortcutSetupActions(currencyCode: 'USD', openUrl: (uri) async { opened.add(uri); return true; }, store: _MemoryStore()));
    expect(find.text('Step 1 of 4'), findsOneWidget);
    await tester.tap(find.byKey(const Key('shortcut_install')));
    await tester.pump();
    expect(opened.last.toString(), 'https://www.icloud.com/shortcuts/48e9741970124e459d24d59882ebfe5f');
    await tester.tap(find.byKey(const Key('shortcut_next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Message contains'), findsNothing);
    expect(find.textContaining('Open Qirsh USD in Shortcuts'), findsWidgets);
  });

  test('every iCloud link in the catalog is the one verified published link', () {
    // Links are added only after a real Shortcuts share; nothing is guessed.
    // Each link was checked against its iCloud record: name "Qirsh <term>",
    // trigger "Message contains <term>", and the same Process Bank SMS action
    // as QIRSH. Every keyword now has one, so none needs the filter step.
    final dedicated = qirshShortcutKeywords.where((k) => k.hasDedicatedShortcut);
    expect(dedicated.length, qirshShortcutKeywords.length);
    for (final k in dedicated) {
      expect(k.installUrl, startsWith('https://www.icloud.com/shortcuts/'), reason: k.term);
    }
    expect(dedicated.map((k) => k.installUrl).toSet().length, dedicated.length);
    expect(qirshShortcutKeywords.first.installUrl, qirshShortcutInstallUrl);
    expect(qirshShortcutKeywords.map((k) => k.term).toSet().length, qirshShortcutKeywords.length);
  });

  testWidgets('a fresh probe is saved as tested, never as On', (tester) async {
    final store = _MemoryStore();
    await show(tester, ShortcutSetupActions(openUrl: (_) async => true, store: store,
      readProbe: () async => DateTime.now().millisecondsSinceEpoch + 10));
    await goToTest(tester);
    await tester.ensureVisible(find.byKey(const Key('shortcut_test')));
    await tester.tap(find.byKey(const Key('shortcut_test')));
    await tester.pumpAndSettle();
    expect(store.records['EGP']?.testedAt, isNotNull);
    expect(store.records['EGP']?.confirmedAt, isNull);
    await tester.tap(find.byKey(const Key('shortcut_next')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shortcut_state_tested')), findsOneWidget);
    expect(find.text('On'), findsNothing);
  });

  testWidgets('only the user confirms automation, and it survives a restart', (tester) async {
    final store = _MemoryStore();
    await show(tester, ShortcutSetupActions(openUrl: (_) async => true, store: store));
    await goToTest(tester);
    await tester.ensureVisible(find.byKey(const Key('shortcut_confirm')));
    await tester.tap(find.byKey(const Key('shortcut_confirm')));
    await tester.pumpAndSettle();
    expect(store.records['EGP']?.confirmedAt, isNotNull);
    expect(store.records['EGP']?.testedAt, isNull);
    expect(find.byKey(const Key('shortcut_state_confirmed')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light, locale: const Locale('en'),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: Scaffold(body: SingleChildScrollView(child: ShortcutSetupActions(store: store)))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shortcut_state_confirmed')), findsOneWidget);
    expect(find.text('On'), findsNothing);
  });

  testWidgets('a second keyword for the same currency warns about double capture', (tester) async {
    final store = _MemoryStore({'EGP': const ShortcutSetupRecord(confirmedAt: 1)});
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light, locale: const Locale('en'),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: Scaffold(body: SingleChildScrollView(child: ShortcutSetupActions(store: store)))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shortcut_overlap')), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('shortcut_choose_جم')));
    await tester.tap(find.byKey(const ValueKey('shortcut_choose_جم')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shortcut_overlap')), findsOneWidget);
    expect(find.textContaining('already set up EGP'), findsOneWidget);
    // A different currency is independent.
    await tester.ensureVisible(find.byKey(const ValueKey('shortcut_currency_USD')));
    await tester.tap(find.byKey(const ValueKey('shortcut_currency_USD')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shortcut_overlap')), findsNothing);
  });

  testWidgets('a dedicated non-EGP keyword installs and runs its own shortcut', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light, locale: const Locale('en'),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: Scaffold(body: SingleChildScrollView(child: ShortcutSetupActions(
        openUrl: (uri) async { opened.add(uri); return true; }, store: _MemoryStore())))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('shortcut_choose_جم')));
    await tester.tap(find.byKey(const ValueKey('shortcut_choose_جم')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('shortcut_begin')));
    await tester.tap(find.byKey(const Key('shortcut_begin')));
    await tester.pumpAndSettle();
    expect(find.text('Step 1 of 4'), findsOneWidget);
    await tester.tap(find.byKey(const Key('shortcut_install')));
    await tester.pump();
    expect(opened.last.toString(), 'https://www.icloud.com/shortcuts/f4427bb0ae21448eb6b621586d21d1c7');
    await tester.tap(find.byKey(const Key('shortcut_next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Open Qirsh جم in Shortcuts'), findsWidgets);
    await tester.tap(find.byKey(const Key('shortcut_edit')));
    await tester.pump();
    expect(opened.last.queryParameters['name'], 'Qirsh جم');
    await goToTest(tester);
    await tester.ensureVisible(find.byKey(const Key('shortcut_test')));
    await tester.tap(find.byKey(const Key('shortcut_test')));
    await tester.pump();
    expect(opened.last.queryParameters['name'], 'Qirsh جم');
  });
}
