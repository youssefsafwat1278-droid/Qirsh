import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/supabase_auth_service.dart';

/// Cross-model audit **H-9** — Apple Sign-In nonce binding.
///
/// Apple binds an identity token to ONE sign-in attempt via a nonce: the app
/// sends `SHA-256(raw)` with the authorization request, Apple embeds that hash
/// in the token, and the RAW value goes to the token exchange, which re-hashes
/// and compares. Qirsh previously sent **no nonce in either direction**, so a
/// still-valid Apple identity token minted for this app carried no per-attempt
/// challenge and could be replayed to the public auth endpoint.
///
/// `SignInWithApple.getAppleIDCredential` is a static and the Supabase client is
/// not injected here, so the cryptographic behaviour is tested directly and the
/// wiring/isolation is pinned by position. Anything asserted structurally is
/// labelled as such.
const _authFile = 'lib/core/auth/supabase_auth_service.dart';
String get _source => File(_authFile).readAsStringSync();

/// The body of `signInWithApple`, so Google's flow cannot satisfy these checks.
String get _appleFlow {
  final s = _source;
  final start = s.indexOf('Future<AuthIdentity> signInWithApple()');
  expect(start, greaterThan(-1));
  return s.substring(start, s.indexOf('\n  @override', start));
}

void main() {
  group('H-9 — nonce hashing is cryptographically correct', () {
    test('appleHashedNonce is lowercase hex SHA-256 of the raw value', () {
      // Known vector: sha256("test").
      expect(
        appleHashedNonce('test'),
        '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
      );
    });

    test('the hash matches an independent computation for random inputs', () {
      for (var i = 0; i < 25; i++) {
        final raw = generateAppleRawNonce();
        expect(
          appleHashedNonce(raw),
          sha256.convert(utf8.encode(raw)).toString(),
          reason: 'Apple compares its stored hash against SHA-256 of the raw '
              'nonce presented at exchange; any other representation fails',
        );
      }
    });

    test('the hash is 64 hex chars and never the raw value', () {
      final raw = generateAppleRawNonce();
      final hashed = appleHashedNonce(raw);
      expect(hashed.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(hashed), isTrue);
      expect(hashed, isNot(raw),
          reason: 'sending the RAW nonce to Apple would defeat the binding');
    });
  });

  group('H-9 — nonce generation has adequate entropy', () {
    test('nonces are unique across many draws', () {
      final seen = <String>{};
      for (var i = 0; i < 2000; i++) {
        expect(seen.add(generateAppleRawNonce()), isTrue,
            reason: 'a repeated nonce would allow cross-attempt replay');
      }
    });

    test('each nonce carries 32 bytes of randomness', () {
      // base64url of 32 bytes, padding stripped ⇒ 43 chars.
      final raw = generateAppleRawNonce();
      expect(raw.length, 43);
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(raw), isTrue);
      expect(raw.contains('='), isFalse);
    });

    test('generation is not derived from a predictable source', () {
      // Structural: the implementation must use Random.secure(), never a
      // timestamp, counter, or the non-secure default Random().
      final gen = _source.substring(
        _source.indexOf('String generateAppleRawNonce'),
        _source.indexOf('String appleHashedNonce'),
      );
      expect(gen, contains('Random.secure()'));
      for (final predictable in const [
        'DateTime.now',
        'millisecondsSinceEpoch',
        'microsecondsSinceEpoch',
        'hashCode',
      ]) {
        expect(gen.contains(predictable), isFalse,
            reason: 'nonce entropy must not come from "$predictable"');
      }
      // A bare `Random(` (non-secure) must not appear as the default source.
      expect(RegExp(r'Random\(\)').hasMatch(gen), isFalse);
    });

    test('an injected RNG is honoured (determinism only for tests)', () {
      final a = generateAppleRawNonce(random: Random(42));
      final b = generateAppleRawNonce(random: Random(42));
      expect(a, b);
      expect(a, isNot(generateAppleRawNonce()));
    });
  });

  group('H-9 — the token is bound to THIS attempt', () {
    test('the HASHED nonce is sent to Apple', () {
      expect(_appleFlow, contains('nonce: appleHashedNonce(rawNonce)'),
          reason: 'Apple must receive SHA-256(raw), not the raw value');
    });

    test('the RAW nonce is sent to the token exchange', () {
      expect(_appleFlow, contains('nonce: rawNonce'),
          reason: 'the exchange re-hashes the raw value and compares it to the '
              "token's nonce claim");
    });

    test('both halves come from ONE generated value', () {
      final gen = _appleFlow.indexOf('generateAppleRawNonce()');
      final toApple = _appleFlow.indexOf('appleHashedNonce(rawNonce)');
      final toExchange = _appleFlow.indexOf('nonce: rawNonce');
      expect(gen, greaterThan(-1), reason: 'a nonce must be generated');
      expect(gen, lessThan(toApple),
          reason: 'the nonce must exist before the authorization request');
      expect(toApple, lessThan(toExchange),
          reason: 'hash to Apple first, raw to the exchange afterwards');
    });

    test('there is no nonce-free Apple path', () {
      // The defect was an authorization request with no nonce argument at all.
      expect(
        RegExp(r'getAppleIDCredential\((?:(?!nonce:)[\s\S])*?\);')
            .hasMatch(_appleFlow),
        isFalse,
        reason: 'every getAppleIDCredential call must pass a nonce',
      );
      expect(
        RegExp(r'OAuthProvider\.apple,(?:(?!nonce:)[\s\S])*?\);')
            .hasMatch(_appleFlow),
        isFalse,
        reason: 'every Apple token exchange must pass the raw nonce',
      );
    });
  });

  group('H-9 — concurrent and stale attempts are isolated', () {
    test('the nonce is per-attempt local state, never a shared field', () {
      // A shared/instance nonce would let attempt B overwrite attempt A's
      // value — the cross-attempt case. `final rawNonce` inside the method
      // gives each concurrent attempt its own by construction.
      expect(_appleFlow, contains('final rawNonce = generateAppleRawNonce();'));
      expect(_source.contains('String _rawNonce'), isFalse,
          reason: 'no instance-level nonce field may exist');
      expect(_source.contains('_nonce ='), isFalse);
    });

    test('a superseded attempt cannot establish a session', () {
      expect(_appleFlow, contains('final attempt = ++_appleAttemptSeq;'));
      // Checked after the system sheet returns AND after the exchange.
      expect(
        RegExp(r'attempt != _appleAttemptSeq').allMatches(_appleFlow).length,
        2,
        reason: 'staleness must be re-checked after BOTH awaits — the sheet '
            'and the token exchange',
      );
    });

    test('a cancelled attempt ends as a cancellation, not a session', () {
      expect(_appleFlow, contains('AuthorizationErrorCode.canceled'));
      expect(_appleFlow, contains('AuthCancelledException'),
          reason: 'cancel must be typed, so the UI does not show a generic '
              'error and no session is created');
    });

    test('no attempt state outlives the call', () {
      // Requirement 7: nothing to clear because nothing is stored. The only
      // instance state is the monotonic counter, which holds no secret.
      expect(_source.contains('SharedPreferences'), isFalse);
      expect(_source.contains('FlutterSecureStorage'), isFalse);
      expect(_source.contains('_storage'), isFalse,
          reason: 'a nonce or identity token must never be persisted');
    });
  });

  group('H-9 — secrets are never logged', () {
    test('the auth service logs nothing at all', () {
      for (final sink in const ['print(', 'debugPrint(', 'log(', 'Sentry']) {
        expect(_source.contains(sink), isFalse,
            reason: 'identity tokens, authorization codes and nonces must '
                'never reach a log sink: found "$sink"');
      }
    });

    test('no interpolation of a nonce or token into a string', () {
      for (final leak in const [
        r'$rawNonce',
        r'$identityToken',
        r'${rawNonce}',
        r'${identityToken}',
      ]) {
        expect(_source.contains(leak), isFalse, reason: 'possible leak: $leak');
      }
    });
  });

  group('Google token exchange uses the platform nonce contract', () {
    test('iOS supplies its raw nonce and Android leaves it absent', () {
      expect(_source, contains('await authorizeIosGoogle(nonce)'));
      expect(_source, contains("'nonce': appleHashedNonce(nonce)"));
      expect(_source, contains('nonce: tokens.nonce'));
      expect(_source, contains('email: account.email, nonce: null'));
      expect(_source, contains('accessToken: tokens.accessToken'));
    });
  });

  group('H-9 — provider configuration expectations are documented', () {
    test('local Supabase config keeps Apple nonce checking ON', () {
      final config = File('../supabase/config.toml').readAsStringSync();
      final apple = config.substring(config.indexOf('[auth.external.apple]'));
      final block = apple.substring(0, apple.indexOf('\n[auth.'));
      expect(block, contains('skip_nonce_check = false'),
          reason: 'skip_nonce_check is PER-PROVIDER. Enabling it for Apple '
              'would leave the nonce binding unverified server-side and make '
              'the client fix cosmetic');
    });

    test('the runbooks say OFF for Apple, ON for Google only', () {
      for (final doc in const [
        '../docs/PRODUCTION_ROLLOUT_OPERATOR_PACKAGE.md',
        '../docs/MANUAL_RELEASE_PREREQUISITES.md',
        '../docs/FINAL_RELEASE_READINESS.md',
      ]) {
        final text = File(doc).readAsStringSync();
        expect(text.toLowerCase(), contains('apple'));
        expect(
          RegExp(r'[Ss]kip nonce checks?\s*(=|:)?\s*OFF|OFF.{0,40}Apple|Apple.{0,80}OFF')
              .hasMatch(text),
          isTrue,
          reason: '$doc must state that Apple keeps nonce checking ON '
              '(skip = OFF), or an operator will disable the H-9 fix',
        );
      }
    });
  });
}
