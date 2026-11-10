import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// This receipt is for presentation only. Auth still verifies every OTP.
const emailSignInReceiptStorageKey = 'auth_email_sign_in_v1';

String? confirmedEmailFingerprint(User? user) {
  final address = user?.email?.trim().toLowerCase();
  if (user == null ||
      address == null ||
      address.isEmpty ||
      user.emailConfirmedAt == null) {
    return null;
  }
  return sha256.convert(utf8.encode(jsonEncode([user.id, address]))).toString();
}

/// Upgrade sessions issued after verifying an email code in an older build.
/// An OTP claim alone is ambiguous for users who can also receive SMS codes.
bool sessionProvesEmailCode(Session? session) {
  if (session == null ||
      session.isExpired ||
      (session.user.phone?.isNotEmpty ?? false) ||
      confirmedEmailFingerprint(session.user) == null) {
    return false;
  }
  try {
    final claims = jsonDecode(utf8.decode(base64Url.decode(
      base64Url.normalize(session.accessToken.split('.')[1]),
    ))) as Map<String, dynamic>;
    final methods = claims['amr'];
    return claims['sub'] == session.user.id &&
        claims['email'] is String &&
        (claims['email'] as String).trim().toLowerCase() ==
            session.user.email!.trim().toLowerCase() &&
        methods is List &&
        methods.any((method) => method is Map && method['method'] == 'otp');
  } catch (_) {
    return false;
  }
}

bool isEmailSignInConnected(User? user, String? receipt) {
  final fingerprint = confirmedEmailFingerprint(user);
  return fingerprint != null &&
      (fingerprint == receipt ||
          (user?.identities?.any((identity) => identity.provider == 'email') ??
              false));
}
