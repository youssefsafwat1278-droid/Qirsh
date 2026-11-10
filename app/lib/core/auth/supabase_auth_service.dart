import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../privacy/cloud_egress_gate.dart';
import 'auth_coordinator.dart';
import 'auth_service.dart';

/// Audit **H-9** — Apple Sign-In nonce binding.
///
/// Apple's OIDC flow binds an identity token to ONE sign-in attempt by way of a
/// nonce: the SHA-256 hash of a fresh random value is sent with the
/// authorization request, Apple embeds that hash in the returned token, and the
/// RAW value is handed to the token exchange, which recomputes the hash and
/// compares. Without it, a still-valid Apple identity token minted for this app
/// carries no per-attempt challenge and can be replayed to the public auth
/// endpoint for its whole validity window.
///
/// Qirsh previously sent NO nonce in either direction.
///
/// Length is 32 bytes of `Random.secure()` — never a timestamp, counter or
/// `Random()` — rendered base64url. The raw value never leaves this file except
/// as the token-exchange parameter, and is never logged or persisted.
String generateAppleRawNonce({Random? random}) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

/// The value sent to Apple: lowercase hex SHA-256 of the raw nonce, which is the
/// representation Apple's `ASAuthorizationAppleIDRequest.nonce` expects and what
/// the token's `nonce` claim is compared against.
String appleHashedNonce(String rawNonce) =>
    sha256.convert(utf8.encode(rawNonce)).toString();

/// The iOS OAuth client. Its reversed form is the ONLY URL scheme registered in
/// `ios/Runner/Info.plist`, which is what makes it the canonical one — the
/// second client in `ios/GoogleService-Info.plist` has no registered scheme and
/// could never complete a callback.
const String kGoogleIosClientId =
    '881903820931-c4cttgekf9d3tcv3j2lt10ao2upk4b1m.apps.googleusercontent.com';

/// Requests a Google credential bound to the caller's nonce without replacing
/// the Qirsh session. Also used by account deletion to prove the linked subject.
Future<Map<String, String>?> authorizeIosGoogle(String nonce) =>
    const MethodChannel('mali/google_authorization')
        .invokeMapMethod<String, String>('authorize', {
      'clientId': kGoogleIosClientId,
      'nonce': appleHashedNonce(nonce),
    });

/// The WEB/server OAuth client, supplied at build time.
///
/// Android does not use an iOS client id, and `clientId` is not a supported
/// parameter there at all: `GoogleSignInPlugin.java:222-231` reinterprets it as
/// `serverClientId` with a warning, so passing the iOS client made Android call
/// `requestIdToken(<iOS client>)` — an audience Google will not mint a token
/// for. The resulting null `idToken` surfaced as "لم نستطع قراءة رمز دخول جوجل"
/// with no hint that the CONFIGURATION was wrong.
///
/// Empty until the web client exists; [googleServerClientId] is null then, and
/// [SupabaseAuthService.signInWithGoogle] fails with an explicit configuration
/// error rather than a misleading token-read error.
const String _kGoogleServerClientIdDefine =
    String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

String? get googleServerClientId {
  final value = _kGoogleServerClientIdDefine.trim();
  return value.isEmpty ? null : value;
}

/// Whether this platform can complete native Google sign-in with the
/// configuration this build actually carries.
///
/// iOS signs with the iOS client. Android REQUIRES the web client as
/// `serverClientId`; without it no id token is issued and the exchange cannot
/// happen, so the failure belongs at configuration time, not mid-flow.
bool googleSignInConfigured({TargetPlatform? platform}) {
  final target = platform ?? defaultTargetPlatform;
  if (target == TargetPlatform.android) return googleServerClientId != null;
  return true;
}

/// Builds the platform-correct client. Extracted so the platform split is
/// testable: injecting a fake in the constructor would leave the branch that
/// actually decides `clientId` vs `serverClientId` unexercised.
GoogleSignIn buildGoogleSignIn(TargetPlatform platform) {
  final isAndroid = platform == TargetPlatform.android;
  return GoogleSignIn(
    scopes: const ['email'],
    // iOS/macOS only. On Android `clientId` is not supported and the plugin
    // silently reinterprets it as serverClientId
    // (GoogleSignInPlugin.java:222-231) — the defect this replaces.
    clientId: isAndroid ? null : kGoogleIosClientId,
    // ANDROID ONLY, deliberately. On iOS the Google SDK turns serverClientId
    // into the OAuth `audience` parameter — GIDSignIn.m:726-727 sets
    // additionalParameters[@"audience"] = serverClientID — so the iOS id token
    // would be minted for the WEB client instead of the iOS one. iOS sign-in
    // works today against a Supabase provider that lists the iOS client;
    // populating the define for Android's sake would silently flip the iOS
    // audience and break it, and no test could catch it. Keeping it
    // Android-only decouples the platforms: each carries its own audience and
    // neither can break the other. Supabase must list BOTH client ids.
    serverClientId: isAndroid ? googleServerClientId : null,
  );
}

class SupabaseAuthService implements AuthService {
  SupabaseAuthService({
    supabase.SupabaseClient? client,
    GoogleSignIn? googleSignIn,
    TargetPlatform? platform,
  })  : _client = client ?? supabase.Supabase.instance.client,
        _platform = platform ?? defaultTargetPlatform,
        _googleSignIn = googleSignIn ??
            buildGoogleSignIn(platform ?? defaultTargetPlatform);

  final TargetPlatform _platform;
  final supabase.SupabaseClient _client;
  final GoogleSignIn _googleSignIn;

  /// ESCALATED (Astra H2.1): interactive sign-in / re-authentication is an
  /// explicit account-control operation, the only network allowed while Cloud is
  /// OFF. The grant starts HERE, immediately before the Supabase exchange and
  /// after the native Google/Apple UI returned (the native UI runs only on an
  /// explicit tap). It is scoped to the sign-in endpoints, expires on a
  /// monotonic TTL, ends in `finally`, and never enables Cloud or widens any
  /// consent. The app has one interactive surface (also used when a session
  /// expired), so [AccountControlOp.signIn] covers re-authentication too; the
  /// two ops carry identical allowlists.
  ///
  /// ASR §4.4/§4.6: with the AuthCoordinator, a session-establishing exchange
  /// belongs to the explicit attempt in the zone (an unattributed one is
  /// denied), waits for ASR quiescence, and runs inside the coordinator's
  /// mutation section with the explicit exclusion set.
  Future<T> _accountControl<T>(Future<T> Function() body,
      {bool establishesSession = true}) {
    final gate = CloudEgressGate.instance;
    final coord = AuthCoordinator.active;
    if (coord == null) {
      return gate.runAccountControl(AccountControlOp.signIn, body);
    }
    if (!establishesSession) {
      return gate.runAccountControl(AccountControlOp.signIn, body);
    }
    final intent = AuthAttemptZone.current;
    if (intent == null) {
      return Future.error(
          EgressDeniedException('account_control_unattributed'));
    }
    return gate.runAccountControl(AccountControlOp.signIn,
        () => coord.explicitExchange(intent, body),
        attempt: true);
  }

  @override
  Future<void> signOutProviderSession() => _googleSignIn.signOut();

  bool Function() _responseCurrent(supabase.AuthResponse response) {
    final session = response.session;
    bool current() {
      final actual = _client.auth.currentSession;
      return session != null &&
          response.user?.id == session.user.id &&
          !session.isExpired &&
          actual?.user.id == session.user.id &&
          actual?.accessToken == session.accessToken;
    }

    if (!current()) {
      throw const AuthException('انتهت صلاحية جلسة تسجيل الدخول.');
    }
    return current;
  }

  @override
  Future<AuthIdentity> signInWithGoogle() => _exchangeGoogle(create: false);

  @override
  Future<AuthIdentity> signUpWithGoogle() => _exchangeGoogle(create: true);

  Future<AuthIdentity> _exchangeGoogle({required bool create}) async {
    final tokens = await _googleTokens();
    final response = await _accountControl(() async {
      if (create) {
        final permit = await _client.functions.invoke('google-enrollment', body: {
          'id_token': tokens.idToken,
          'nonce': tokens.nonce == null ? null : appleHashedNonce(tokens.nonce!),
        });
        final result = permit.data;
        if (permit.status != 200 || result is! Map || result['allowed'] != true) {
          throw const AuthException('google_enrollment_unavailable');
        }
      }
      return _client.auth.signInWithIdToken(
        provider: supabase.OAuthProvider.google,
        idToken: tokens.idToken,
        accessToken: tokens.accessToken,
        nonce: tokens.nonce,
      );
    });
    return AuthIdentity(isCurrent: _responseCurrent(response), method: 'google',
      email: response.user?.email ?? tokens.email, userId: response.user?.id);
  }

  Future<({String idToken, String? accessToken, String? email, String? nonce})>
      _googleTokens() async {
    if (!googleSignInConfigured(platform: _platform)) {
      // Honest failure: nothing about the user's action was wrong.
      throw const AuthConfigurationException(
        'تسجيل الدخول بجوجل غير متاح في هذه النسخة. استخدم طريقة أخرى.',
      );
    }
    if (_platform == TargetPlatform.iOS) {
      final nonce = generateAppleRawNonce();
      final tokens = await authorizeIosGoogle(nonce);
      if (tokens == null) {
        throw const AuthCancelledException('تم إلغاء تسجيل الدخول بجوجل.');
      }
      final idToken = tokens['idToken'];
      final accessToken = tokens['accessToken'];
      if (idToken == null || idToken.isEmpty || accessToken == null || accessToken.isEmpty) {
        throw const AuthException('لم نستطع قراءة رمز دخول جوجل.');
      }
      return (idToken: idToken, accessToken: accessToken, email: null, nonce: nonce);
    }
    final account = await _googleSignIn.signIn();
    if (account == null) {
      throw const AuthCancelledException('تم إلغاء تسجيل الدخول بجوجل.');
    }
    final auth = await account.authentication;
    final idToken = auth.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw const AuthException('لم نستطع قراءة رمز دخول جوجل.');
    }
    return (idToken: idToken, accessToken: auth.accessToken, email: account.email, nonce: null);
  }

  Future<T> _identityControl<T>(String owner, bool Function() current,
      Future<T> Function() exchange) {
    final coordinator = AuthCoordinator.active;
    if (coordinator == null || !current() || _client.auth.currentUser?.id != owner) {
      throw const AuthException('identity_not_current');
    }
    return CloudEgressGate.instance.runAccountControl(
      AccountControlOp.linkIdentity,
      () => coordinator.updateLinkedIdentity(
          owner: owner, current: current, exchange: exchange),
      linking: (owner: owner, current: current),
    );
  }

  Future<void> linkGoogleIdentity({required String owner, required bool Function() current}) async {
    final tokens = await _googleTokens();
    await _identityControl(owner, current, () async {
      final response = await _client.auth.linkIdentityWithIdToken(
        provider: supabase.OAuthProvider.google, idToken: tokens.idToken,
        accessToken: tokens.accessToken, nonce: tokens.nonce);
      if (response.user?.id != owner) throw const AuthException('identity_owner_changed');
    });
  }

  Future<void> sendEmailLink({required String owner, required String email,
      required bool Function() current}) => _identityControl(owner, current, () async {
    if (_client.auth.currentUser?.email?.toLowerCase() == email.trim().toLowerCase()) {
      await _client.auth.signInWithOtp(email: email.trim(), shouldCreateUser: false);
    } else {
      await _client.auth.updateUser(supabase.UserAttributes(email: email.trim()));
    }
  });

  /// Returns false when secure email change still needs the old address's code.
  Future<bool> verifyEmailLink({required String owner, required String email,
      required String code, required bool confirmingCurrentEmail, required String currentEmail,
      required bool Function() current}) => _identityControl(owner, current, () async {
    try {
      final sameEmail = currentEmail.toLowerCase() == email.trim().toLowerCase();
      await _client.auth.verifyOTP(email: confirmingCurrentEmail ? currentEmail : email.trim(), token: code.trim(),
        type: sameEmail ? supabase.OtpType.email : supabase.OtpType.emailChange);
    } on supabase.AuthException catch (error) {
      // Secure email change returns HTTP 200 without a session after the first
      // confirmation. The pinned SDK reports this precise local error.
      // The next step must still establish the same owner's session with the
      // requested verified email. API errors are never swallowed.
      if (confirmingCurrentEmail || currentEmail.isEmpty ||
          currentEmail.toLowerCase() == email.trim().toLowerCase() ||
          error.runtimeType != supabase.AuthException ||
          error.message != 'An error occurred on token verification.') {
        rethrow;
      }
      return false;
    }
    final user = _client.auth.currentUser;
    if (user?.id != owner || user?.email?.toLowerCase() != email.trim().toLowerCase()) {
      throw const AuthException('email_confirmation_incomplete');
    }
    return true;
  });

  /// Monotonic per-attempt marker. Each Apple sign-in owns its nonce as a LOCAL
  /// value (so two concurrent attempts can never share or overwrite one), and
  /// this additionally ensures a stale attempt that completes late cannot
  /// establish a session behind a newer one.
  int _appleAttemptSeq = 0;

  @override
  Future<AuthIdentity> signInWithApple() async {
    final attempt = ++_appleAttemptSeq;
    // Per-attempt, function-scoped: nothing to clear on a terminal outcome
    // because nothing outlives this frame. Never logged, never persisted.
    final rawNonce = generateAppleRawNonce();

    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        // Apple receives the HASH; the raw value is proved at exchange time.
        nonce: appleHashedNonce(rawNonce),
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      // A cancelled attempt must end as a cancellation, not an opaque error —
      // and it establishes no session, leaving this attempt's nonce unused.
      if (e.code == AuthorizationErrorCode.canceled) {
        throw const AuthCancelledException('تم إلغاء تسجيل الدخول بـ Apple.');
      }
      throw const AuthException('تعذّر تسجيل الدخول بـ Apple.');
    }

    if (attempt != _appleAttemptSeq) {
      // Superseded while the system sheet was open.
      throw const AuthCancelledException('تم إلغاء تسجيل الدخول بـ Apple.');
    }

    final identityToken = credential.identityToken;
    if (identityToken == null || identityToken.isEmpty) {
      throw const AuthException('لم نستطع قراءة رمز دخول Apple.');
    }

    final response = await _accountControl(() => _client.auth.signInWithIdToken(
          provider: supabase.OAuthProvider.apple,
          idToken: identityToken,
          // The RAW nonce for THIS attempt. The backend re-hashes it and compares
          // against the token's `nonce` claim, so a token minted for a different
          // attempt (or with no nonce at all) cannot be exchanged here.
          nonce: rawNonce,
        ));

    if (attempt != _appleAttemptSeq) {
      throw const AuthCancelledException('تم إلغاء تسجيل الدخول بـ Apple.');
    }

    final email = response.user?.email ?? credential.email;
    return AuthIdentity(
      isCurrent: _responseCurrent(response),
      method: 'apple',
      email: email,
      userId: response.user?.id,
    );
  }

  @override
  Future<void> sendEmailCode(String email) => _sendEmailCode(email, create: false);

  @override
  Future<void> sendEmailSignupCode(String email) => _sendEmailCode(email, create: true);

  Future<void> _sendEmailCode(String email, {required bool create}) =>
      _accountControl(
        () => _client.auth.signInWithOtp(email: email.trim(), shouldCreateUser: create),
        establishesSession: false,
      );

  @override
  Future<AuthIdentity?> verifyEmailCode({
    required String email,
    required String code,
  }) async {
    final token = code.replaceAll(RegExp(r'\s'), '');
    final response = await _accountControl(() => _client.auth.verifyOTP(
          email: email,
          token: token,
          type: supabase.OtpType.email,
        ));
    final user = response.user;
    if (user == null) return null;
    return AuthIdentity(
      isCurrent: _responseCurrent(response),
      method: 'email',
      email: user.email ?? email,
      userId: user.id,
    );
  }
}

class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AuthCancelledException extends AuthException {
  const AuthCancelledException(super.message);
}

/// The build cannot complete this provider's flow at all — a missing or
/// malformed OAuth configuration, not a transient failure.
///
/// Distinct from [AuthException] because the UI must NOT tell the user to try
/// again: retrying a misconfigured build fails forever.
class AuthConfigurationException extends AuthException {
  const AuthConfigurationException(super.message);
}
