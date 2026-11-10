import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/auth/auth_methods_config.dart';
import 'package:money_companion/core/auth/auth_service.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/auth_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _PreviewAuth extends StubAuthService {
  String? sentTo;
  String? signupSentTo;

  @override
  Future<void> sendEmailCode(String email) async => sentTo = email;

  @override
  Future<void> sendEmailSignupCode(String email) async => signupSentTo = email;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Future<void> capture(String name) async {
    final bytes = await binding.takeScreenshot(name);
    const previewDir = String.fromEnvironment('QIRSH_AUTH_PREVIEW_DIR');
    if (previewDir.isNotEmpty) {
      await File('$previewDir/$name.png').writeAsBytes(bytes);
    }
  }

  testWidgets('Google, Apple and email fit the compact iPhone auth screen',
      (tester) async {
    for (final (language, dark) in [
      ('ar', false),
      ('en', false),
      ('ar', true),
      ('en', true)
    ]) {
      final mode = dark ? 'dark' : 'light';
      final auth = _PreviewAuth();
      await tester.pumpWidget(ProviderScope(
        key: ValueKey('$language-$mode'),
        overrides: [
          authMethodsConfigProvider.overrideWithValue(
              const AuthMethodsConfig(google: true, email: true, signup: true)),
          authServiceProvider.overrideWithValue(auth),
        ],
        child: MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          debugShowCheckedModeBanner: false,
          locale: Locale(language),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: const OnboardingAuthScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      final google = find.byKey(const ValueKey('auth-google'));
      final email = find.byKey(const ValueKey('auth-email'));
      expect(google.hitTestable(), findsOneWidget);
      expect(email.hitTestable(), findsOneWidget);
      expect(find.byIcon(Icons.apple).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture('qirsh127-auth-$language-$mode');

      await tester.tap(email);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('auth-email-input')),
          'preview@example.test');
      final submit = find.byKey(const ValueKey('auth-email-submit'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(auth.sentTo, 'preview@example.test');
      expect(find.byKey(const ValueKey('auth-email-code')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture('qirsh127-email-code-$language-$mode');
      Navigator.of(
              tester.element(find.byKey(const ValueKey('auth-email-code'))))
          .pop();
      await tester.pumpAndSettle();

      final toggle = find.byKey(const ValueKey('auth-toggle-signup'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await capture('qirsh129-create-account-$language-$mode');
      await tester.ensureVisible(email);
      await tester.tap(email);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('auth-email-input')),
          'new-preview@example.test');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(auth.signupSentTo, 'new-preview@example.test');
      expect(auth.sentTo, 'preview@example.test');
      expect(tester.takeException(), isNull);
    }
  });
}
