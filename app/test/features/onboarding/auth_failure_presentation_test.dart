import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/auth_service.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/auth_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import '../../../tool/visual_parity/auth_failure_surfaces.dart';

void main() {
  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final cancel in [false, true]) {
        testWidgets('failure-only Apple UI $lang dark$dark cancel$cancel',
            (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.runAsync(() async {
            final font = FontLoader('Vazirmatn');
            for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              font.addFont(rootBundle.load('assets/fonts/Vazirmatn-$w.ttf'));
            }
            await font.load();
          });
          final before = AppSession.instance.status;
          final auth = FailureOnlyAppleAuth(cancel);
          var clients = 0;
          await HttpOverrides.runZoned(() async {
            await tester.pumpWidget(ProviderScope(
                overrides: [authServiceProvider.overrideWithValue(auth)],
                child: MaterialApp(
                    theme: dark ? AppTheme.dark : AppTheme.light,
                    locale: Locale(lang),
                    supportedLocales: AppL10n.supportedLocales,
                    localizationsDelegates: AppL10n.localizationsDelegates,
                    home: const OnboardingAuthScreen())));
            await tester.pumpAndSettle();
            final button = find.byType(FilledButton);
            final l10n =
                AppL10n.of(tester.element(find.byType(OnboardingAuthScreen)));
            expect(button.hitTestable(), findsOneWidget);
            await tester.tap(button);
            await tester.pump();
            expect(auth.calls, 1);
            expect(tester.widget<FilledButton>(button).onPressed, isNull);
            expect(find.byType(CircularProgressIndicator), findsOneWidget);
            final material = tester.widget<Material>(
                find.descendant(of: button, matching: find.byType(Material)));
            const ink = Colors.black;
            final fill = material.color!.computeLuminance();
            final busyContrast = (fill + .05) / .05;
            final label = find.descendant(
                of: button, matching: find.text(l10n.startPreparing));
            expect(
                tester.renderObject<RenderParagraph>(label).text.style!.color,
                ink);
            expect(
                tester
                    .widget<CircularProgressIndicator>(
                        find.byType(CircularProgressIndicator))
                    .color,
                ink);
            await tester.tap(button, warnIfMissed: false);
            await tester.pump();
            expect(auth.calls, 1);
            auth.release();
            await tester.pumpAndSettle();
            expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
            expect(find.byType(CircularProgressIndicator), findsNothing);
            expect(find.byType(OnboardingAuthScreen), findsOneWidget);
            if (cancel) {
              expect(find.textContaining(l10n.authSignInError), findsNothing);
            } else {
              expect(find.textContaining(l10n.authSignInError), findsOneWidget);
              expect(find.textContaining('private_synthetic'), findsNothing);
            }
            expect(AppSession.instance.status, before);
            expect(clients, 0);
            expect(tester.takeException(), isNull);
            await tester.pump(const Duration(seconds: 4));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(busyContrast, greaterThanOrEqualTo(4.5),
                reason:
                    'The label and progress ring must remain readable on the actual button fill');
          }, createHttpClient: (context) {
            clients++;
            throw StateError('auth_failure_preview_must_not_create_http');
          });
          debugDefaultTargetPlatformOverride = null;
        });
      }
    }
  }
}
