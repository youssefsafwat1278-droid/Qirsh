import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/email_sign_in_status.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

User user({String id = 'uid-a', String email = 'user@example.test',
  bool verified = true, String? phone}) => User(
    id: id,
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-01-01T00:00:00Z',
    email: email,
    phone: phone,
    emailConfirmedAt: verified ? '2026-01-01T00:00:00Z' : null,
  );

Session session(User user, {String method = 'otp', String? subject, bool expired = false}) {
  final payload = base64Url.encode(utf8.encode(jsonEncode({
    'sub': subject ?? user.id,
    'email': user.email,
    'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + (expired ? -3600 : 3600),
    'amr': [{'method': method}],
  })));
  return Session(accessToken: 'e30.$payload.signature', tokenType: 'bearer', user: user);
}

void main() {
  test('OTP-confirmed OAuth account shows connected without an email identity', () {
    final current = user();
    expect(isEmailSignInConnected(current, null), isFalse);
    final receipt = confirmedEmailFingerprint(current);
    expect(isEmailSignInConnected(current, receipt), isTrue);
    expect(isEmailSignInConnected(user(email: 'USER@example.test'), receipt), isTrue);
    expect(isEmailSignInConnected(user(id: 'uid-b'), receipt), isFalse);
    expect(isEmailSignInConnected(user(email: 'new@example.test'), receipt), isFalse);
    expect(isEmailSignInConnected(user(verified: false), receipt), isFalse);
  });

  test('upgrade recognizes email OTP but rejects unrelated session claims', () {
    expect(sessionProvesEmailCode(session(user())), isTrue);
    expect(sessionProvesEmailCode(session(user(), method: 'oauth')), isFalse);
    expect(sessionProvesEmailCode(session(user(), subject: 'uid-b')), isFalse);
    expect(sessionProvesEmailCode(session(user(), expired: true)), isFalse);
    expect(sessionProvesEmailCode(session(user(phone: '1234'))), isFalse);
  });
}
