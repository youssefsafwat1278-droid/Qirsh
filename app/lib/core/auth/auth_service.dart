import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/supabase_config.dart';
import 'supabase_auth_service.dart';

/// هوية المستخدم بعد الدخول.
class AuthIdentity {
  const AuthIdentity(
      {required this.method, this.email, this.userId, this.isCurrent});

  /// Live capability from the successful provider response; never persisted.
  final bool Function()? isCurrent;

  final String method; // google | apple | email
  final String? email;
  final String? userId;
}

/// واجهة المصادقة. النسخة الحالية stub (بلا backend).
///
/// TODO(Sprint5-backend): استبدل StubAuthService بتنفيذ حقيقي:
/// google_sign_in + sign_in_with_apple + Email/OTP عبر Amazon SES،
/// والتحقق من id_token/identity_token على السيرفر وإصدار JWT.
abstract class AuthService {
  Future<AuthIdentity> signInWithGoogle();
  Future<AuthIdentity> signUpWithGoogle();
  Future<AuthIdentity> signInWithApple();
  Future<void> sendEmailCode(String email);
  Future<void> sendEmailSignupCode(String email);
  Future<AuthIdentity?> verifyEmailCode(
      {required String email, required String code});

  /// Clears any provider-owned native session after the app signs out.
  /// Supabase logout alone does not clear Google Sign-In's selected account.
  Future<void> signOutProviderSession();
}

class StubAuthService implements AuthService {
  static const String _stubCode = '123456';

  @override
  Future<AuthIdentity> signInWithGoogle() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return const AuthIdentity(method: 'google', email: 'user@gmail.com');
  }

  @override
  Future<AuthIdentity> signUpWithGoogle() => signInWithGoogle();

  @override
  Future<AuthIdentity> signInWithApple() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return const AuthIdentity(
        method: 'apple', email: 'user@privaterelay.appleid.com');
  }

  @override
  Future<void> sendEmailCode(String email) async {
    // stub: لا إرسال فعلي. الكود التجريبي ثابت (123456).
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  @override
  Future<void> sendEmailSignupCode(String email) => sendEmailCode(email);

  @override
  Future<AuthIdentity?> verifyEmailCode({
    required String email,
    required String code,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final clean = code.replaceAll(RegExp(r'\s'), '');
    if (clean == _stubCode) {
      return AuthIdentity(method: 'email', email: email);
    }
    return null;
  }

  @override
  Future<void> signOutProviderSession() async {}
}

final authServiceProvider = Provider<AuthService>((ref) {
  if (SupabaseConfig.isConfigured) return SupabaseAuthService();
  // Stub auth (fixed OTP) is a development convenience ONLY. A release build
  // without Supabase config must fail closed, never authenticate for real
  // (MALI-003). Bootstrap already throws earlier; this is defense in depth.
  if (kReleaseMode) {
    throw StateError(
      'Auth requested in a release build without Supabase configuration.',
    );
  }
  return StubAuthService();
});
