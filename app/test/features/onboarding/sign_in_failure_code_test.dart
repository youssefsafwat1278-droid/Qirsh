import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/features/onboarding/auth_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// The sign-in failure toast carries a short, non-sensitive reason code so a field
// report says WHY (exception type; for an egress refusal the gate's reason).
void main() {
  test('an egress refusal reports the gate reason', () {
    expect(signInFailureCode(EgressDeniedException('unresolved')),
        'EgressDenied:unresolved');
    expect(signInFailureCode(EgressDeniedException('state_uncertain')),
        'EgressDenied:state_uncertain');
  });

  test('a refusal wrapped by the Supabase client still reports the reason', () {
    final wrapped = AuthRetryableFetchException(
        message: 'ClientException: egress_denied:frozen');
    expect(signInFailureCode(wrapped), 'EgressDenied:frozen');
  });

  test('other failures report only the exception type, never its message', () {
    expect(signInFailureCode(const StaleAdmissionException()),
        'StaleAdmissionException');
    expect(signInFailureCode(const AuthException('user@example.com token abc')),
        isNot(contains('example')));
    expect(signInFailureCode(const FormatException('secret')), 'FormatException');
  });

  // Audit W1: only the server's rejection of the code itself is "wrong code".
  test('emailCodeRejected: only an expired/invalid code from the server', () {
    expect(
        emailCodeRejected(AuthApiException('Token has expired or is invalid',
            statusCode: '403', code: 'otp_expired')),
        isTrue);
    expect(emailCodeRejected(EgressDeniedException('disabling')), isFalse);
    expect(
        emailCodeRejected(AuthRetryableFetchException(
            message: 'ClientException: egress_denied:frozen')),
        isFalse);
    expect(emailCodeRejected(const StaleAdmissionException()), isFalse);
    expect(
        emailCodeRejected(
            AuthApiException('rate limited', statusCode: '429',
                code: 'over_request_rate_limit')),
        isFalse);
  });
}
