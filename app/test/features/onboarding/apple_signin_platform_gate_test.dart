import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/auth/auth_service.dart';
import 'package:money_companion/core/auth/supabase_auth_service.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/onboarding/auth_screen.dart';

/// Apple Sign-In is iOS-only in V1 (`Qirsh Production/17_Apple_Production/`).
///
/// The implementation is the NATIVE flow: `getAppleIDCredential` with no
/// `webAuthenticationOptions`, exchanged through `signInWithIdToken`. That
/// cannot complete on Android, so offering the button there is a control that
/// always fails — and the failure is at the very first screen a new user sees.
///
/// Supporting Android would need three things that do not exist: a Services ID,
/// the Supabase callback registered as a Return URL, and `webAuthenticationOptions`
/// in the credential request. Until all three land, the gate must hold.
void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('iOS is the only platform offered Sign in with Apple', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(appleSignInSupported, isTrue);
  });

  test('every other platform is excluded', () {
    for (final platform in const [
      TargetPlatform.android,
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.fuchsia,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        appleSignInSupported,
        isFalse,
        reason: '$platform cannot complete the native Apple flow',
      );
    }
  });

  test('the button is rendered behind the gate, not unconditionally', () {
    // The defect this replaces: `_appleButton(c)` sat directly in the column
    // with no platform check and no dart:io import, so Android showed it.
    final src =
        File('lib/features/onboarding/auth_screen.dart').readAsStringSync();
    expect(
      src,
      matches(r'if \(appleSignInSupported\)\s+FilledButton\.icon\('),
      reason: 'the Apple button must stay behind the platform gate',
    );
    // A dart:io gate would work at runtime but could not be driven by
    // debugDefaultTargetPlatformOverride, so the tests above would be untestable.
    expect(
      src.contains("import 'dart:io'"),
      isFalse,
      reason: 'use defaultTargetPlatform so the gate stays testable',
    );
  });
  testWidgets('iOS personal auth offers Apple alone and calls only Apple', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final auth = _CancelledAppleAuth();
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authServiceProvider.overrideWithValue(auth)],
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: OnboardingAuthScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.apple), findsOneWidget);
    expect(find.textContaining('Google'), findsNothing);
    expect(find.byIcon(Icons.g_mobiledata_rounded), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(auth.appleCalls, 1);
    expect(auth.googleCalls, 0);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

class _CancelledAppleAuth extends StubAuthService {
  int appleCalls = 0;
  int googleCalls = 0;

  @override
  Future<AuthIdentity> signInWithApple() async {
    appleCalls++;
    throw const AuthCancelledException('synthetic cancellation');
  }

  @override
  Future<AuthIdentity> signInWithGoogle() async {
    googleCalls++;
    throw StateError('Google must not be offered by the personal iOS UI');
  }
}
