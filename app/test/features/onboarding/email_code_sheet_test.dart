import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/widgets/email_code_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final language in ['ar', 'en']) {
    testWidgets(
        'email OTP validates, resends and keeps submit reachable: $language',
        (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var sends = 0;
      var verifies = 0;
      String? sentEmail;
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          locale: Locale(language),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: Scaffold(
              body: EmailCodeSheet(
            onSend: (email) async {
              sends++;
              sentEmail = email;
            },
            onVerify: (email, code, _) async {
              verifies++;
              return EmailCodeResult.invalid;
            },
          ))));
      final submit = find.byKey(const ValueKey('auth-email-submit'));
      await tester.tap(submit);
      await tester.pump();
      expect(sends, 0);
      await tester.enterText(find.byKey(const ValueKey('auth-email-input')),
          ' user@example.test ');
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(sends, 1);
      expect(sentEmail, 'user@example.test');
      await tester.tap(submit);
      await tester.pump();
      expect(verifies, 0);
      await tester.enterText(
          find.byKey(const ValueKey('auth-email-code')), '12345678');
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      expect(submit.hitTestable(), findsOneWidget);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(verifies, 1);
      // Resend must not require an already-valid verification code.
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pump(const Duration(seconds: 61));
      final l = AppL10n.of(tester.element(find.byType(EmailCodeSheet)));
      await tester.enterText(find.byKey(const ValueKey('auth-email-code')), '');
      await tester.ensureVisible(find.text(l.authResendCode));
      await tester.tap(find.text(l.authResendCode));
      await tester.pump();
      expect(sends, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'failed send stays on email stage without exposing exception details',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
            body: EmailCodeSheet(
                initialEmail: 'a@example.test',
                onSend: (_) async => throw StateError('private-token'),
                onVerify: (email, code, confirming) async =>
                    EmailCodeResult.invalid))));
    await tester.tap(find.byKey(const ValueKey('auth-email-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('auth-email-code')), findsNothing);
    expect(find.textContaining('private-token'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failure that is not a wrong code shows its own message',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
            body: EmailCodeSheet(
                initialEmail: 'a@example.test',
                onSend: (_) async {},
                onVerify: (email, code, confirming) async =>
                    throw const EmailCodeFailure('SIGN-IN FAILED (E: X)')))));
    await tester.tap(find.byKey(const ValueKey('auth-email-submit')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('auth-email-code')), '123456');
    await tester.tap(find.byKey(const ValueKey('auth-email-submit')));
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(EmailCodeSheet)));
    expect(find.text('SIGN-IN FAILED (E: X)'), findsOneWidget);
    expect(find.text(l.authCodeVerifyFailed), findsNothing);
  });
}

