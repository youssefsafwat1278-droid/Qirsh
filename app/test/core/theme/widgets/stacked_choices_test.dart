import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/segmented_control.dart';
import 'package:money_companion/core/theme/widgets/stacked_choices.dart';
import 'package:money_companion/features/common/app_pill_tab_bar.dart';
import 'package:money_companion/l10n/app_localizations.dart';

// SP-13: the pill selectors keep their accessibility contract in both forms —
// the one-row track (up to 1.25x) and the stacked list ([StackedChoices],
// above 1.25x). Each option is a button with its label, its selected state and
// a tap action; tapping moves the selection; each is at least 44 pt tall.
const _labels = {
  'en': ['Expense', 'Income', 'Transfer'],
  'ar': ['مصروف', 'دخل', 'تحويل'],
};

class _Host extends StatefulWidget {
  const _Host({required this.kind, required this.labels});
  final String kind;
  final List<String> labels;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int selected = 0;
  @override
  Widget build(BuildContext context) {
    final child = widget.kind == 'segmented'
        ? SegmentedControl<int>(
            options: [
              for (var i = 0; i < widget.labels.length; i++)
                SegmentOption(value: i, label: widget.labels[i]),
            ],
            value: selected,
            onChanged: (v) => setState(() => selected = v),
          )
        : AppPillTabBar(
            tabs: widget.labels,
            selectedIndex: selected,
            onSelected: (i) => setState(() => selected = i),
          );
    return Scaffold(
        body: Center(
            child: Padding(padding: const EdgeInsets.all(20), child: child)));
  }
}

void main() {
  for (final kind in ['segmented', 'pill tabs']) {
    for (final language in ['en', 'ar']) {
      for (final scale in [1.0, 2.0, 3.1]) {
        testWidgets('$kind keeps button, label, selected state and tap at '
            '${scale}x ($language)', (tester) async {
          final semantics = tester.ensureSemantics();
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final labels = _labels[language]!;
          await tester.pumpWidget(MaterialApp(
            theme: AppTheme.light,
            locale: Locale(language),
            supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: AppL10n.localizationsDelegates,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: _Host(kind: kind, labels: labels),
          ));
          await tester.pumpAndSettle();

          // The stacked form is used exactly above 1.25x.
          expect(find.byType(StackedChoices),
              scale > 1.25 ? findsOneWidget : findsNothing);

          void expectSelected(int selected) {
            for (var i = 0; i < labels.length; i++) {
              final node = tester.getSemantics(find.text(labels[i]));
              expect(
                  node,
                  containsSemantics(
                    label: labels[i],
                    isButton: true,
                    isSelected: i == selected,
                    hasTapAction: true,
                  ),
                  reason: '"${labels[i]}" at ${scale}x');
              expect(node.rect.height, greaterThanOrEqualTo(44),
                  reason: '"${labels[i]}" tap target height');
            }
          }

          expectSelected(0);
          await tester.tap(find.text(labels[2]));
          await tester.pumpAndSettle();
          expectSelected(2);
          // The semantics tap action selects too (VoiceOver double-tap).
          tester.semantics.tap(find.semantics.byLabel(labels[1]));
          await tester.pumpAndSettle();
          expectSelected(1);

          expect(tester.takeException(), isNull);
          semantics.dispose();
        });
      }
    }
  }
}
