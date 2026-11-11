import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/app/startup_loading_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// The startup screen is the one surface that runs before the saved language
/// can be read — the database is exactly what has not opened yet. Its copy used
/// to be hardcoded Arabic, so these assertions passed in every locale,
/// including the English build where the screen also read Arabic. They are
/// parameterized by language now, which is what makes them able to fail.
Widget _app(Widget child, String lang) {
  return MaterialApp(
    theme: AppTheme.light,
    locale: Locale(lang),
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: child,
  );
}

typedef _Copy = ({
  String lang,
  String preparing,
  String failed,
  String retry,
  String timeout,
  String stepPrefix,
});

const _cases = <_Copy>[
  (
    lang: 'ar',
    preparing: 'جارٍ تجهيز التطبيق...',
    failed: 'تعذّر تجهيز التطبيق',
    retry: 'إعادة المحاولة',
    timeout: 'استغرق التجهيز وقتًا أطول من المتوقع',
    stepPrefix: 'معرّف:',
  ),
  (
    lang: 'en',
    preparing: 'Getting Qirsh ready…',
    failed: 'Qirsh could not start',
    retry: 'Try again',
    timeout: 'Startup is taking longer than expected',
    stepPrefix: 'Step:',
  ),
];

void main() {
  for (final c in _cases) {
    group('startup loading screen (${c.lang})', () {
      testWidgets('shows the loading body with a spinner when there is no error',
          (tester) async {
        await tester
            .pumpWidget(_app(StartupLoadingScreen(onRetry: () {}), c.lang));
        await tester.pump();

        // The launch loader: the coin (and, only if loading runs long, a
        // ring around it), never a separate spinner.
        expect(find.byKey(const Key('qirsh_stable_loader')), findsOneWidget);
        expect(find.text(c.preparing), findsNothing);
        expect(find.byType(Text), findsNothing,
            reason: 'normal loading must not flash between languages');
        expect(find.text(c.retry), findsNothing);
      });

      testWidgets('shows the generic retry state for a non-timeout error',
          (tester) async {
        var retried = false;
        await tester.pumpWidget(_app(
          StartupLoadingScreen(
            error: Exception('boom'),
            onRetry: () => retried = true,
          ),
          c.lang,
        ));
        await tester.pump();

        expect(find.text(c.failed), findsOneWidget);
        expect(find.text(c.retry), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);

        await tester.tap(find.text(c.retry));
        expect(retried, isTrue);
      });

      testWidgets('shows timeout-specific copy for a BootstrapTimeoutException',
          (tester) async {
        await tester.pumpWidget(_app(
          StartupLoadingScreen(
            error: const BootstrapTimeoutException('database_open'),
            lastStep: 'database_open',
            onRetry: () {},
          ),
          c.lang,
        ));
        await tester.pump();

        expect(find.text(c.timeout), findsOneWidget);
        // The step id is a diagnostic identifier, never translated.
        expect(find.textContaining('database_open'), findsOneWidget);
      });

      testWidgets('does not show a diagnostic identifier when lastStep is null',
          (tester) async {
        await tester.pumpWidget(_app(
          StartupLoadingScreen(error: Exception('boom'), onRetry: () {}),
          c.lang,
        ));
        await tester.pump();

        expect(find.textContaining(c.stepPrefix), findsNothing);
      });
    });
  }
}
