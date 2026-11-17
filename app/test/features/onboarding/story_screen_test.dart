import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/features/onboarding/story_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

Widget _app({Locale locale = const Locale('ar')}) {
  final router = GoRouter(
    initialLocation: '/welcome',
    routes: [
      GoRoute(
        path: '/welcome',
        builder: (context, state) => const OnboardingStoryScreen(),
      ),
      GoRoute(
        path: '/onboarding/brand',
        builder: (context, state) => const Scaffold(body: Text('BRAND')),
      ),
    ],
  );
  return MaterialApp.router(
    routerConfig: router,
    locale: locale,
    supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: const [
      ...AppL10n.localizationsDelegates,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (context, child) => MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: child!,
    ),
  );
}

void main() {
  setUp(() {
    // Keep every test on a stable, representative phone canvas unless a
    // test overrides it for a specific size/text-scale scenario.
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  Future<void> setSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets(
      'first page renders the promise title; CTA appears once copy finishes',
      (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pump();

    // Block copy renders via WordRevealText's Text.rich, so find.text() needs
    // findRichText: true to see it — plain find.text() only matches Text.data.
    expect(find.text('متحمّسين\nنبدأ معك', findRichText: true), findsOneWidget);
    expect(find.text('المصروفات الصغيرة بتفرق'), findsNothing);

    // Reduced motion reveals every block instantly, but each block still
    // mounts on its own frame — settle the cascade before the CTA appears.
    await tester.pumpAndSettle();
    expect(find.text('كمّل'), findsOneWidget);
  });

  testWidgets('second page renders after a swipe gesture', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // RTL locale: PageView's forward direction follows Directionality, so
    // advancing to the next page is a rightward (positive dx) drag here, not
    // the LTR-style leftward swipe.
    await tester.drag(find.byType(PageView), const Offset(500, 0));
    await tester.pumpAndSettle();

    expect(find.text('المصروفات الصغيرة بتفرق', findRichText: true),
        findsOneWidget);
    expect(find.text('ابدأ مع قِرش'), findsOneWidget);
    expect(find.text('متحمّسين\nنبدأ معك'), findsNothing);

    // flutter_animate schedules its own internal (non-Scheduler) Timer for
    // page-2's illustration animation, which pumpAndSettle doesn't wait on.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });

  testWidgets('continue CTA moves programmatically to page 2', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('كمّل'));
    await tester.pumpAndSettle();

    expect(find.text('المصروفات الصغيرة بتفرق'), findsOneWidget);
    expect(find.text('متحمّسين\nنبدأ معك'), findsNothing);
  });

  testWidgets('skip exits the complete story and navigates to brand',
      (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pump();

    await tester.tap(find.text('تخطّي'));
    await tester.pumpAndSettle();

    expect(find.text('BRAND'), findsOneWidget);
    expect(find.byType(OnboardingStoryScreen), findsNothing);
  });

  testWidgets('final CTA navigates exactly once despite repeated taps',
      (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('كمّل'));
    await tester.pumpAndSettle();

    final startCta = find.text('ابدأ مع قِرش');
    await tester.tap(startCta);
    await tester.tap(startCta);
    await tester.tap(startCta);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('BRAND'), findsOneWidget);
  });

  testWidgets('page semantics reflect the current page', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('الصفحة 1 من 2'), findsOneWidget);

    await tester.tap(find.text('كمّل'));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('الصفحة 2 من 2'), findsOneWidget);
  });

  testWidgets('copy is sourced from localization, not hardcoded Arabic',
      (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_app(locale: const Locale('en')));
    await tester.pumpAndSettle();

    expect(find.text('Excited\nto start with you', findRichText: true),
        findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
    expect(find.text('متحمّسين\nنبدأ معك'), findsNothing);
  });

  testWidgets('large accessibility text does not overflow on a small phone',
      (tester) async {
    await setSize(tester, const Size(320, 568));
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          disableAnimations: true,
          textScaler: TextScaler.linear(1.25),
        ),
        child: _app(),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    await tester.tap(find.text('كمّل'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('RTL: Arabic locale lays the screen out right-to-left',
      (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pump();

    final direction = Directionality.of(
      tester.element(find.text('متحمّسين\nنبدأ معك', findRichText: true)),
    );
    expect(direction, TextDirection.rtl);
  });
}
