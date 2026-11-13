import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/account_completion_screen.dart';
import 'package:money_companion/features/app/app_boot_loader.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/session/f2_fixture.dart';
import '../../core/session/fake_account_scope.dart';

void main() {
  for (final language in ['en', 'ar']) {
    for (final completed in [true, false]) {
      testWidgets(
          'real account verification routes $language completed=$completed',
          (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final session = AppSession.instance;
        session.debugResetAdmissionState();
        session.configureUncoordinatedForTesting();
        session.configureInstallPresentation(null);
        session.configureAccountScope(null);
        final restoreFence = AccountFenceAuthority.replacePersistenceForTest();
        session.configureAccountScope(FakeAccountScope());
        session.configureCaptureOwnerClear(() async => true);
        await session.wipeAndReset();
        final held = Completer<http.Response>();
        var profileResponse = held.future;
        final sdk = (await tester.runAsync(() async {
          final client = SupabaseClient(
            'https://example.supabase.co',
            'synthetic-anon',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
            httpClient: MockClient((request) async {
              if (request.url.path.endsWith('/profiles')) {
                final reply = await profileResponse;
                return http.Response(reply.body, reply.statusCode,
                    headers: reply.headers, request: request);
              }
              return http.Response('{}', 200, request: request);
            }),
          );
          await F2Fixture.recoverSession_(client, 'returning-owner');
          return client;
        }))!;
        final router = GoRouter(initialLocation: '/check', routes: [
          GoRoute(
              path: '/check',
              builder: (_, __) =>
                  OnboardingAccountCompletionScreen(client: sdk)),
          GoRoute(
              path: '/',
              builder: (_, __) => const Scaffold(body: Text('HOME'))),
          GoRoute(
              path: '/onboarding/setup',
              builder: (_, __) => const Scaffold(body: Text('SETUP'))),
        ]);
        addTearDown(() async {
          if (!held.isCompleted) held.complete(http.Response('[]', 200));
          await tester.pumpWidget(const SizedBox.shrink());
          router.dispose();
          await sdk.dispose();
          session.configureAccountScope(null);
          session.configureCaptureOwnerClear(null);
          await session.wipeAndReset();
          session.debugResetAdmissionState();
          restoreFence();
        });
        await session.setIdentity(
            method: 'apple',
            userId: 'returning-owner',
            email: 'returning-owner@example.com',
            sessionCurrent: () => sdk.auth.currentSession?.isExpired == false);
        await tester.pumpWidget(MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.light,
          locale: Locale(language),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
        ));
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byType(AppBootLoader), findsOneWidget);
        final profile = http.Response(
          jsonEncode([
            {
              'onboarding_completed_at':
                  completed ? '2026-10-01T00:00:00Z' : null,
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
        if (language == 'ar' && completed) {
          held.complete(http.Response('{"message":"private detail"}', 503));
          await tester.pumpAndSettle();
          final l10n = AppL10n.of(
              tester.element(find.byType(OnboardingAccountCompletionScreen)));
          expect(find.text(l10n.onboardingAccountCheckFailed), findsOneWidget);
          expect(find.text('SETUP'), findsNothing);
          expect(find.textContaining('private detail'), findsNothing);
          // Audit L6: a reason code and a way out, never a dead end.
          expect(find.text('(E: PostgrestException)'), findsOneWidget);
          expect(find.text(l10n.onboardingUseAnotherAccount), findsOneWidget);
          profileResponse = Future.value(profile);
          await tester.tap(find.text(l10n.startRetry));
        } else {
          held.complete(profile);
        }
        for (var i = 0;
            i < 100 &&
                router.routeInformationProvider.value.uri.path == '/check';
            i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)));
        }
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text(completed ? 'HOME' : 'SETUP'), findsOneWidget);
        expect(find.text(completed ? 'SETUP' : 'HOME'), findsNothing);
      });
    }
  }
}
