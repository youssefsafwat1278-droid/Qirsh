import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/section_photo_header.dart';
import 'package:money_companion/features/common/app_header.dart';
import 'package:money_companion/features/common/app_screen_scaffold.dart';

void main() {
  for (final reduceMotion in [false, true]) {
    testWidgets(
        'photo header gives way to reachable content, reduce motion $reduceMotion',
        (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var headerTaps = 0;
      var contentTaps = 0;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 59),
            disableAnimations: reduceMotion,
          ),
          child: child!,
        ),
        home: AppScreenScaffold(
          scrollHeader: true,
          header: AppHeader(
            title: 'Accounts',
            sectionPhoto: QirshSectionPhoto.accounts,
            action: IconButton(
              tooltip: 'Add account',
              onPressed: () => headerTaps++,
              icon: const Icon(Icons.add),
            ),
          ),
          body: ListView.builder(
            itemExtent: 64,
            itemCount: 40,
            itemBuilder: (_, index) => ListTile(
              title: Text('Account $index'),
              onTap: () => contentTaps++,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Accounts')).dy, greaterThan(59));
      await tester.tap(find.byTooltip('Add account'));
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Add account').hitTestable(), findsNothing);
      final inner = find.descendant(
          of: find.byType(ListView), matching: find.byType(Scrollable));
      await tester.scrollUntilVisible(find.text('Account 39'), 450,
          scrollable: inner);
      await tester.pumpAndSettle();
      expect(find.text('Account 39').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Account 39'));
      expect([headerTaps, contentTaps], [1, 1]);
      expect(tester.takeException(), isNull);
    });
  }
}
