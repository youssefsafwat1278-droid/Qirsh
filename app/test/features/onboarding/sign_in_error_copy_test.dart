import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:money_companion/core/auth/auth_methods_config.dart';
import 'package:money_companion/core/auth/auth_service.dart';
import 'package:money_companion/core/auth/supabase_auth_service.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/auth_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// Owner report (iPhone): Continue with Google → choose an account → Cancel
/// showed «تعذّر تسجيل الدخول. جرب تاني. (E: PlatformException)». A cancel is not
/// an error, and no failure may show an exception class name or an `(E: …)`
/// reason code.
class _FailingAuth implements AuthService {
  _FailingAuth(this.error);
  final Object error;

  @override
  Future<AuthIdentity> signInWithGoogle() async => throw error;

  @override
  Future<AuthIdentity> signInWithApple() async => throw error;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected_auth_operation');
}

Future<AppL10n> _tapSignIn(
    WidgetTester tester, String lang, String button, Object error) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(_FailingAuth(error)),
        authMethodsConfigProvider
            .overrideWithValue(const AuthMethodsConfig(google: true)),
      ],
      child: MaterialApp(
          theme: AppTheme.light,
          locale: Locale(lang),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: const OnboardingAuthScreen())));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(button)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return AppL10n.of(tester.element(find.byType(OnboardingAuthScreen)));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
  debugDefaultTargetPlatformOverride = null;
}

void _expectNoTechnicalText() {
  expect(find.textContaining('(E:'), findsNothing);
  expect(find.textContaining('Exception'), findsNothing);
  expect(find.textContaining('google_authorization_failed'), findsNothing);
}

void main() {
  for (final lang in ['ar', 'en']) {
    for (final button in ['auth-google', 'auth-apple']) {
      testWidgets('$button: cancelling shows nothing ($lang)', (tester) async {
        final l = await _tapSignIn(tester, lang, button,
            const AuthCancelledException('تم إلغاء تسجيل الدخول.'));
        expect(find.textContaining(l.authSignInError), findsNothing);
        expect(find.textContaining(l.repoErrNetwork), findsNothing);
        expect(find.textContaining('تم إلغاء'), findsNothing);
        _expectNoTechnicalText();
        expect(find.byType(OnboardingAuthScreen), findsOneWidget);
        await _settle(tester);
      });
    }

    testWidgets('a real failure shows only the plain message ($lang)',
        (tester) async {
      // What the iOS Google channel returns for a failed authorization.
      final l = await _tapSignIn(tester, lang, 'auth-google',
          PlatformException(code: 'google_authorization_failed'));
      expect(find.text(l.authSignInError), findsOneWidget);
      _expectNoTechnicalText();
      await _settle(tester);
    });

    testWidgets('a network failure says to check the connection ($lang)',
        (tester) async {
      final l = await _tapSignIn(tester, lang, 'auth-apple',
          supabase.AuthRetryableFetchException(
              message: 'ClientException with SocketException: Failed host '
                  'lookup'));
      expect(find.text(l.repoErrNetwork), findsOneWidget);
      expect(find.textContaining(l.authSignInError), findsNothing);
      _expectNoTechnicalText();
      await _settle(tester);
    });

    testWidgets('an HTTP client failure says to check the connection ($lang)',
        (tester) async {
      final l = await _tapSignIn(tester, lang, 'auth-google',
          http.ClientException('Connection refused'));
      expect(find.text(l.repoErrNetwork), findsOneWidget);
      _expectNoTechnicalText();
      await _settle(tester);
    });

    testWidgets('an egress refusal is not reported as a connection problem '
        '($lang)', (tester) async {
      final l = await _tapSignIn(tester, lang, 'auth-google',
          supabase.AuthRetryableFetchException(
              message: 'ClientException: egress_denied:frozen'));
      expect(find.text(l.authSignInError), findsOneWidget);
      expect(find.textContaining(l.repoErrNetwork), findsNothing);
      _expectNoTechnicalText();
      expect(find.textContaining('egress'), findsNothing);
      await _settle(tester);
    });

    testWidgets('a build without Google says so, without a code ($lang)',
        (tester) async {
      final l = await _tapSignIn(tester, lang, 'auth-google',
          const AuthConfigurationException('غير متاح'));
      expect(find.text(l.authGoogleUnavailable), findsOneWidget);
      _expectNoTechnicalText();
      await _settle(tester);
    });
  }

  test('iOS: Google\'s own Cancel (OAuth access_denied) ends as a cancel', () {
    // The Google page's Cancel redirects with error=access_denied, which
    // AppAuth reports in OIDOAuthAuthorizationErrorDomain with code
    // OIDErrorCodeOAuthAccessDenied — not as userCanceledAuthorizationFlow.
    // Both must reach Dart as `nil` (→ AuthCancelledException), not as
    // google_authorization_failed. Source pin: no device run proves this.
    final swift = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final start = swift.indexOf('func configureGoogleAuthorization(');
    final body = swift.substring(start, swift.indexOf('result(["idToken"', start));
    final cancel = body.indexOf('result(nil)');
    expect(cancel, greaterThan(0));
    final condition = body.substring(0, cancel);
    expect(condition, contains('OIDErrorCode.userCanceledAuthorizationFlow'));
    expect(condition, contains('OIDOAuthAuthorizationErrorDomain'));
    expect(condition, contains('OIDErrorCodeOAuth.accessDenied'));
  });
}
