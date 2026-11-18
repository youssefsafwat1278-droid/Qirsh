import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/setup_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

// The country step is one field that opens the full ISO list (decision 3.7),
// replacing the eight pills. Keep the original contrast regression: measure
// the field's copy over its composited fill in both themes and languages.
void main() {
  for (final dark in [false, true]) {
    for (final language in ['ar', 'en']) {
      for (final size in [const Size(320, 568), const Size(390, 844)]) {
        testWidgets(
            'country field is readable and unselected: $language, dark=$dark, width=${size.width}',
            (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(ProviderScope(
              child: MaterialApp(
            theme: dark ? AppTheme.dark : AppTheme.light,
            locale: Locale(language),
            supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: const [
              ...AppL10n.localizationsDelegates,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const OnboardingSetupScreen(),
          )));
          await tester.pumpAndSettle();
          final l = AppL10n.of(tester.element(find.byType(OnboardingSetupScreen)));
          final field = find.byKey(const ValueKey('setup-country-field'));
          expect(field, findsOneWidget);
          expect(
              find.descendant(of: field, matching: find.text(l.countryPickerChoose)),
              findsOneWidget,
              reason: 'no country may be preselected');
          expect(find.text(l.countryCoverageNote), findsOneWidget);
          final background =
              tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor!;
          final ink = tester.widget<Ink>(
              find.descendant(of: field, matching: find.byType(Ink)));
          final fill = (ink.decoration! as ShapeDecoration).color!;
          final text = tester.widget<Text>(find.descendant(
              of: field, matching: find.text(l.countryPickerChoose)));
          final surface = Color.alphaBlend(fill, background);
          final copy = Color.alphaBlend(text.style!.color!, surface);
          final a = surface.computeLuminance();
          final b = copy.computeLuminance();
          final ratio = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
          expect(ratio, greaterThanOrEqualTo(4.5));
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
