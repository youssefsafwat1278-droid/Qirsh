import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/auth_methods_config.dart';
import 'package:money_companion/core/auth/auth_service.dart';
import 'package:money_companion/features/onboarding/auth_screen.dart';
import 'package:money_companion/features/onboarding/widgets/email_code_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// Adversarial scenario 4: wrong, expired and already-used email codes.
///
/// What the server actually returns (Supabase GoTrue `/verify`): every one of
/// the three is HTTP 403 `otp_expired` "Token has expired or is invalid" (a
/// used code is deleted, so it is "not found" exactly like a wrong one). The
/// app is driven through the real auth screen and its email sheet.
class _EmailAuth extends StubAuthService {
  _EmailAuth(this.failure);
  Object failure;

  @override
  Future<void> sendEmailCode(String email) async {}

  @override
  Future<AuthIdentity?> verifyEmailCode(
      {required String email, required String code}) async {
    throw failure;
  }
}

supabase.AuthApiException _goTrue403() =>
    supabase.AuthApiException('Token has expired or is invalid',
        statusCode: '403', code: 'otp_expired');

void main() {
  Future<String?> messageFor(WidgetTester tester, Object failure,
      {Duration wait = Duration.zero}) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = _EmailAuth(failure);
    // A fresh tree: no sheet or route left over from an earlier call.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(auth),
        authMethodsConfigProvider
            .overrideWithValue(const AuthMethodsConfig(email: true)),
      ],
      child: const MaterialApp(
        locale: Locale('en'),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: AppL10n.localizationsDelegates,
        home: OnboardingAuthScreen(),
      ),
    ));
    await tester.pumpAndSettle();
    final emailButton = find.byKey(const ValueKey('auth-email'));
    await tester.ensureVisible(emailButton);
    await tester.pumpAndSettle();
    await tester.tap(emailButton);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('auth-email-input')), 'user@example.test');
    await tester.tap(find.byKey(const ValueKey('auth-email-submit')));
    await tester.pumpAndSettle();
    // The user comes back to the sheet [wait] after the code was sent.
    if (wait > Duration.zero) await tester.pump(wait);
    await tester.enterText(
        find.byKey(const ValueKey('auth-email-code')), '123456');
    final submit = find.byKey(const ValueKey('auth-email-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    final sheet = find.byType(EmailCodeSheet);
    expect(sheet, findsOneWidget, reason: 'the sheet stays open on failure');
    final l = AppL10n.of(tester.element(sheet));
    // The sheet's error line: whichever known message is on screen.
    for (final candidate in [
      l.authCodeVerifyFailed,
      l.invalidOtpCode,
    ]) {
      if (find.text(candidate).evaluate().isNotEmpty) return candidate;
    }
    final texts = find
        .descendant(of: sheet, matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .toList();
    return texts.join(' | ');
  }

  testWidgets(
      'ADV-4: an expired code (verified 61 min after the send) is told apart '
      'from a wrong code (verified at once)', (tester) async {
    final wrong = await messageFor(tester, _goTrue403());
    final expired = await messageFor(tester, _goTrue403(),
        wait: const Duration(minutes: 61));
    expect(tester.takeException(), isNull);
    expect(expired, isNot(wrong),
        reason: 'both show "$wrong": an expired code is reported as a code '
            'to re-check, never as "request a new code"');
  });

  testWidgets(
      'ADV-4 (server-limited): an already-used code gets the server answer of '
      'a wrong code, so the app shows the same message', (tester) async {
    final wrong = await messageFor(tester, _goTrue403());
    final used = await messageFor(tester, _goTrue403());
    // Documented, not a defect of the app: GoTrue deletes a used token, so
    // /verify answers 403 otp_expired exactly as for a wrong one.
    expect(used, wrong);
  });

  testWidgets('control: a non-code failure is NOT reported as a wrong code',
      (tester) async {
    final wrong = await messageFor(tester, _goTrue403());
    final network = await messageFor(
        tester, supabase.AuthRetryableFetchException(message: 'offline'));
    expect(network, isNot(wrong));
  });
}
