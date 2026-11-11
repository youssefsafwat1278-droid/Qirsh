import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_typography.dart';

void main() {
  // B2-D — BEHAVIORAL/structural font contract (replaces the old source-text
  // test that asserted the literal `GoogleFonts.alexandria` spelling and thereby
  // cemented the runtime-fetch anti-pattern). These check the rendered/declared
  // font CONFIGURATION, so a formatting-only refactor cannot fail the contract.
  group('bundled font contract', () {
    test(
        'pubspec registers ONE IBMPlexSansArabic family with the '
        '400/500/600/700 weight→file mapping and no runtime google_fonts', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('family: IBMPlexSansArabic'));
      for (final pair in const [
        (400, 'IBMPlexSansArabic-Regular.ttf'),
        (500, 'IBMPlexSansArabic-Medium.ttf'),
        (600, 'IBMPlexSansArabic-SemiBold.ttf'),
        (700, 'IBMPlexSansArabic-Bold.ttf'),
      ]) {
        expect(pubspec, contains('asset: assets/fonts/${pair.$2}'),
            reason: 'weight ${pair.$1} asset declared');
        expect(pubspec, contains('weight: ${pair.$1}'));
      }
      // The bundled fallback families stay registered too.
      expect(pubspec, contains('family: Vazirmatn'));
      expect(pubspec, contains('family: Alexandria'));
      // No runtime GoogleFonts dependency remains — nothing can fetch at runtime.
      expect(pubspec, isNot(contains('google_fonts:')));
    });

    // PRIMARY FAMILY CHANGED, 2026-09-18. This contract asserted
    // IBMPlexSansArabic because that was the approved family at the time. The
    // design prototype names Vazirmatn first (`--f: "Vazirmatn Local",
    // "Vazirmatn",…`) and the owner has made the prototype the authority for
    // typography, so the assertions were updated rather than left to hold the
    // old face in place.
    //
    // What the contract is actually FOR is unchanged and still asserted: one
    // bundled family per face, every weight mapped, no runtime network fetch,
    // and Arabic + Latin from the same primary.
    test('custom() uses the bundled Vazirmatn family + fallbacks', () {
      final s =
          AppTypography.custom(size: 16, weight: FontWeight.w400, height: 1.5);
      expect(s.fontFamily, 'Vazirmatn');
      expect(s.fontFamilyFallback,
          containsAllInOrder(['IBMPlexSansArabic', 'Alexandria']));
    });

    test('every requested weight is preserved on the primary family', () {
      // Weight resolution to the matching bundled TTF is Flutter-engine work
      // driven by the pubspec mapping above; at the style layer the requested
      // FontWeight is carried through unchanged for all four mapped weights.
      for (final w in const [
        FontWeight.w400,
        FontWeight.w500,
        FontWeight.w600,
        FontWeight.w700,
      ]) {
        final s = AppTypography.custom(size: 16, weight: w, height: 1.5);
        expect(s.fontFamily, 'Vazirmatn');
        expect(s.fontWeight, w);
      }
    });

    // UX-002 — these pin the APPROVED scale (`docs/design/BRAND_AND_DESIGN_SYSTEM.md` §7),
    // not whatever the file happened to contain. Title-2 and Headline are
    // SemiBold 600 there; the implementation had drifted to Bold 700, and that
    // drift is what this test previously froze in place. A snapshot of the
    // current value protects nothing — it only makes the next correction look
    // like a regression.
    test('named styles match the approved spec: size/weight/height/features',
        () {
      const c = Color(0xFF000000);
      final body = AppTypography.body(c);
      // Calm Capital v2 §2.4: Arabic body needs ≥1.6 line height (16/26).
      expect((body.fontFamily, body.fontSize, body.fontWeight, body.height),
          ('Vazirmatn', 16.0, FontWeight.w400, 26 / 16));
      final t2 = AppTypography.title2(c);
      // §7 Title-2: SemiBold. (Size is one step below the spec's 22 by the
      // documented density deviation — see app_typography.dart.)
      expect((t2.fontFamily, t2.fontSize, t2.fontWeight, t2.height),
          ('Vazirmatn', 20.0, FontWeight.w600, 1.24));
      // v2 amount.hero: Alexandria 600, 48/52.
      final hero = AppTypography.amountHero(c);
      expect(hero.fontFamily, 'Alexandria');
      expect(hero.fontSize, 48);
      expect(hero.fontWeight, FontWeight.w600);
      expect(hero.fontFeatures, contains(const FontFeature.tabularFigures()));
    });

    test('textTheme maps Material slots to the primary family with metrics',
        () {
      final theme = AppTypography.textTheme(const Color(0xFF111111));
      expect(theme.bodyLarge!.fontFamily, 'Vazirmatn');
      expect(theme.bodyLarge!.fontSize, 16);
      expect(theme.headlineMedium!.fontFamily, 'Vazirmatn'); // title2
      expect(theme.headlineMedium!.fontSize, 20);
      expect(theme.headlineMedium!.fontWeight, FontWeight.w600); // §7 SemiBold
    });

    test('the mono family is bundled with its weights and licence', () {
      // `--f-mono: "IBM Plex Mono"`. Bundled, never fetched.
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('family: IBMPlexMono'));
      expect(pubspec, contains('asset: assets/fonts/IBMPlexMono-Regular.ttf'));
      expect(pubspec, contains('asset: assets/fonts/IBMPlexMono-Bold.ttf'));
      expect(File('assets/fonts/IBMPlexMono-Regular.ttf').existsSync(), isTrue);
      expect(File('assets/fonts/IBMPlexMono-Bold.ttf').existsSync(), isTrue);
      // SIL OFL 1.1 shipped beside the face, like every other bundled family.
      expect(File('assets/fonts/IBMPlexMono-OFL.txt').existsSync(), isTrue);
    });

    test('mono() is the mono face, with tabular figures by default', () {
      final s = AppTypography.mono(size: 10);
      expect(s.fontFamily, 'IBMPlexMono');
      expect(s.fontFeatures, contains(const FontFeature.tabularFigures()));
      // A monospaced string here is nearly always a number, an id or a code.
      final proportional = AppTypography.mono(size: 10, tabular: false);
      expect(proportional.fontFeatures, isEmpty);
    });

    test('mono() falls back to the UI family so Arabic never breaks', () {
      // THE failure mode this face invites: IBM Plex Mono is Latin-only, and
      // the design's own card-network badge renders «مدى» in it. Without a
      // fallback that has Arabic, the badge is tofu.
      final s = AppTypography.mono(size: 10);
      expect(s.fontFamilyFallback, isNotNull);
      expect(s.fontFamilyFallback!.first, 'Vazirmatn',
          reason: 'Arabic mono copy should match the rest of the interface');
      expect(s.fontFamilyFallback, contains('IBMPlexSansArabic'));
    });

    testWidgets('an Arabic network badge renders through the fallback',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: Text('مدى',
                style: AppTypography.mono(
                    size: 12, color: const Color(0xFF84B740))),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      final style = tester.widget<Text>(find.text('مدى')).style!;
      expect(style.fontFamily, 'IBMPlexMono');
      expect(style.fontFamilyFallback, contains('Vazirmatn'));
    });

    testWidgets('offline: Arabic + English render with the bundled family, no network',
        (tester) async {
      // No google_fonts import remains in the typography path, so no runtime
      // fetch is even possible — a bundled family renders on a cold offline
      // launch. Both scripts resolve without exception.
      await tester.pumpWidget(MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: Column(children: [
              Text('مصروفات اليوم',
                  style: AppTypography.body(const Color(0xFF000000))),
              Text('Balance 1,250.00 EGP',
                  style: AppTypography.amountSmall(const Color(0xFF000000))),
            ]),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(tester.widget<Text>(find.text('مصروفات اليوم')).style!.fontFamily,
          'Vazirmatn');
      expect(find.text('Balance 1,250.00 EGP'), findsOneWidget);
    });
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'Arabic typography renders without overflow at 320px and 1.25x in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final color =
            brightness == Brightness.light ? Colors.black : Colors.white;
        final typographyTheme = ThemeData(
          brightness: brightness,
          fontFamily: 'Alexandria',
          textTheme: TextTheme(
            displayLarge: TextStyle(
              fontFamily: 'Alexandria',
              fontSize: 36,
              fontWeight: FontWeight.w700,
              height: 1.06,
              letterSpacing: 0,
              color: color,
            ),
            bodyLarge: TextStyle(
              fontFamily: 'Alexandria',
              fontSize: 16,
              fontWeight: FontWeight.w400,
              height: 1.55,
              letterSpacing: 0,
              color: color,
            ),
            titleMedium: TextStyle(
              fontFamily: 'Alexandria',
              fontSize: 18,
              fontWeight: FontWeight.w600,
              height: 1.3,
              letterSpacing: 0,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: typographyTheme,
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 720),
                textScaler: TextScaler.linear(1.25),
              ),
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: Scaffold(
                  body: SafeArea(
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Text(
                          'متحمّسين نبدأ معك لإدارة مالية أوضح وأسهل',
                          style: typographyTheme.textTheme.displayLarge,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'قِرش يساعدك على فهم مصروفاتك واتخاذ قراراتك بثقة.',
                          style: typographyTheme.textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'مصروفات اليوم 12,450.75 EGP',
                          style: typographyTheme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 16),
                        const FilledButton(
                          onPressed: null,
                          child: Text('ابدأ رحلتك مع Qirsh'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        expect(find.textContaining('متحمّسين'), findsOneWidget);
        expect(find.textContaining('12,450.75 EGP'), findsOneWidget);
      },
    );
  }
}
