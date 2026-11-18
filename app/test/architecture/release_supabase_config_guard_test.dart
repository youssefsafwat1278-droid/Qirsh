import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A shipping build can never be Supabase-UNCONFIGURED.
///
/// Review raised that `syncCatalog` returns before the forced parser-authority
/// refresh when `SupabaseConfig.isConfigured` is false, so an unconfigured
/// install would keep legacy parser authority. Rather than complicate
/// production runtime for a state that cannot ship, this pins the build-time
/// guarantee that makes it impossible: every workflow that produces an
/// installable artifact asserts SUPABASE_URL and SUPABASE_ANON_KEY are
/// non-empty and exits non-zero otherwise.
///
/// If that assertion is ever removed, the runtime assumption stops holding —
/// so this test fails instead.
///
/// It checks the assertion STEP, not the workflow. A guard that accepted the
/// step's NAME plus any `exit 1` elsewhere in the workflow was satisfied by a
/// step named "Assert production Supabase config" whose script was `true` —
/// verified, and the reason the step body and `ignore_failure` are pinned here.
void main() {
  final yaml = File('../codemagic.yaml').readAsStringSync();

  /// Split the file into top-level workflow blocks. The key charset is wide on
  /// purpose: a narrower one silently folds an unmatched workflow into the
  /// previous body, which HIDES a workflow from every check below.
  Map<String, String> workflows() {
    final out = <String, String>{};
    final matches = RegExp(r'^  ([A-Za-z0-9_-]+):$', multiLine: true)
        .allMatches(yaml)
        .toList();
    for (var i = 0; i < matches.length; i++) {
      final start = matches[i].start;
      final end = i + 1 < matches.length ? matches[i + 1].start : yaml.length;
      out[matches[i].group(1)!] = yaml.substring(start, end);
    }
    return out;
  }

  /// Split a workflow body into its named script steps.
  Map<String, String> steps(String body) {
    final out = <String, String>{};
    final matches =
        RegExp(r'^      - name: (.*)$', multiLine: true).allMatches(body).toList();
    for (var i = 0; i < matches.length; i++) {
      final start = matches[i].start;
      final end = i + 1 < matches.length ? matches[i + 1].start : body.length;
      out[matches[i].group(1)!.trim()] = body.substring(start, end);
    }
    return out;
  }

  const assertStep = 'Assert production Supabase config';

  /// Workflows that produce something a person can install.
  const shipping = [
    'ios-unsigned-sideload',
    'ios-signed-release',
    // Owner-authorised signed test build (artifacts only, no upload).
    'ios-signed-test-build',
    'ios-signed',
    'android-release',
  ];

  group('no shipping build can be Supabase-unconfigured', () {
    test('every shipping workflow exists', () {
      final found = workflows();
      for (final w in shipping) {
        expect(found.containsKey(w), isTrue,
            reason: '$w is gone — update this guard deliberately');
      }
    });

    test('every workflow that publishes artifacts is covered by this guard', () {
      // The list above is an allowlist, so a NEW artifact-producing workflow
      // would otherwise be invisible to every check here.
      final found = workflows();
      final publishing = found.entries
          .where((e) => e.value.contains(RegExp(r'^    artifacts:$', multiLine: true)))
          .map((e) => e.key)
          .toList();
      expect(publishing.toSet(), shipping.toSet(),
          reason: 'a workflow publishes artifacts but is not guarded — add it '
              'to `shipping` and give it the config assertion');
    });

    test('the assertion STEP itself checks both vars and fails hard', () {
      final found = workflows();
      for (final w in shipping) {
        final body = steps(found[w]!)[assertStep];
        expect(body, isNotNull, reason: '$w lost the "$assertStep" step');
        expect(body!, contains(r'${SUPABASE_URL:-}'),
            reason: '$w: the assert step no longer checks SUPABASE_URL');
        expect(body, contains(r'${SUPABASE_ANON_KEY:-}'),
            reason: '$w: the assert step no longer checks SUPABASE_ANON_KEY');
        expect(body, contains('exit 1'),
            reason: '$w: the assert step checks the config but does not fail');
        expect(body.contains('ignore_failure'), isFalse,
            reason: '$w: ignore_failure makes the assertion advisory');
      }
    });

    test('the assertion runs BEFORE the build step that consumes it', () {
      // A check that runs after the artifact is built proves nothing.
      final found = workflows();
      for (final w in shipping) {
        final body = found[w]!;
        final assertAt = body.indexOf('      - name: $assertStep');
        final buildAt =
            body.indexOf(RegExp(r'flutter build (ios|ipa|apk|appbundle)'));
        expect(assertAt, isNot(-1), reason: '$w lost the assertion step');
        expect(buildAt, isNot(-1), reason: '$w lost its build step');
        expect(assertAt, lessThan(buildAt),
            reason: '$w asserts config only AFTER building');
      }
    });

    test('android-release fails closed without the Google web client', () {
      // Sign in with Apple is iOS-only and there is no guest path, so Google is
      // Android's ONLY way in. An empty GOOGLE_SERVER_CLIENT_ID ships an app
      // nobody can log into, and no runtime check can save a released binary.
      final body = steps(workflows()['android-release']!)[assertStep]!;
      expect(body, contains(r'${GOOGLE_SERVER_CLIENT_ID:-}'));
      expect(body, contains('exit 1'));

      // iOS must NOT gate on it: the iOS client is what signs there, and
      // requiring the web client would block a valid iOS release.
      for (final w in ['ios-unsigned-sideload', 'ios-signed-release', 'ios-signed']) {
        final ios = steps(workflows()[w]!)[assertStep]!;
        expect(ios.contains(r'${GOOGLE_SERVER_CLIENT_ID:-}'), isFalse,
            reason: '$w must not require the Android-only web client');
      }
    });

    test('the runtime gate this relies on still exists', () {
      // The guard is only meaningful because the app reads these at build time.
      final config =
          File('lib/core/backend/supabase_config.dart').readAsStringSync();
      expect(config, contains("String.fromEnvironment('SUPABASE_URL')"));
      expect(config, contains("String.fromEnvironment('SUPABASE_ANON_KEY')"));
      expect(config, contains('url.isNotEmpty && anonKey.isNotEmpty'));
    });
  });
}
