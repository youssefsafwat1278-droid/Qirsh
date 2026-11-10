import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Enabled only after the corresponding production provider has been verified.
/// Public build configuration; OAuth and SMTP secrets never belong in the app.
class AuthMethodsConfig {
  const AuthMethodsConfig({
    this.google = const bool.fromEnvironment('QIRSH_GOOGLE_AUTH_ENABLED'),
    this.email = const bool.fromEnvironment('QIRSH_EMAIL_AUTH_ENABLED'),
    this.signup = const bool.fromEnvironment('QIRSH_ALTERNATE_SIGNUP_ENABLED'),
  });

  final bool google;
  final bool email;
  final bool signup;
}

final authMethodsConfigProvider = Provider((ref) => const AuthMethodsConfig());
