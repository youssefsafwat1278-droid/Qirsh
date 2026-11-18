import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

/// R8C — the Android compile CI contract.
///
/// Android used to be compiled only by `android-release`, i.e. on release day and
/// behind the real signing inputs, so a plugin/Gradle defect could not be seen
/// until the worst possible moment. These guards keep an Android compile in the
/// ordinary pre-release path and keep it honest: hard-failing, pinned, using the
/// vendored file_picker, and free of production signing/AdMob requirements.
String _ci() => File('../codemagic.yaml').readAsStringSync();

/// The body of one named Codemagic workflow, so assertions about the quality
/// gate cannot be satisfied by text belonging to the release workflow.
String _workflow(String name) {
  final ci = _ci();
  final start = ci.indexOf('  $name:');
  expect(start, greaterThan(-1), reason: 'workflow $name not found');
  final next = RegExp(r'\n  [a-z][a-z0-9-]*:\n').firstMatch(ci.substring(start + 1));
  return next == null
      ? ci.substring(start)
      : ci.substring(start, start + 1 + next.start);
}

void main() {
  group('pre-release Android compile coverage', () {
    test('the canonical quality workflow compiles Android', () {
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('flutter build apk --debug'),
          reason: 'an Android compile must run before release day, not on it');
      expect(quality, contains('Android compile gate'));
    });

    test('the gate is hard — never allow-failure or ignored', () {
      final quality = _workflow('backend-and-quality-gates');
      for (final soft in const [
        'ignore_failure',
        'allow_failure',
        'continue-on-error',
        '|| true',
      ]) {
        expect(quality.contains(soft), isFalse,
            reason: 'the Android gate must fail the build: found "$soft"');
      }
      // `set -eu` means an intermediate failure aborts rather than continuing.
      expect(quality, contains('set -eu'));
    });

    test('the gate proves the artifact exists, not just the exit code', () {
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('build/app/outputs/flutter-apk/app-debug.apk'));
    });
  });

  // Added 2026-09-03. iOS had the identical gap and it was hiding a real break:
  // `Cannot find 'SharedOfferIntentStore' in scope` — a share-extension type in
  // no build target, invisible because BOTH Xcode workflows are manual-only and
  // nothing here had ever compiled iOS. Same defect class and same feature as
  // the Android package bug. These assertions exist so the gate that caught it
  // cannot be quietly dropped.
  group('pre-release iOS compile coverage', () {
    test('the canonical quality workflow compiles iOS', () {
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('flutter build ios --debug --no-codesign'),
          reason: 'an iOS compile must run before release day, not on it');
      expect(quality, contains('iOS compile gate'));
    });

    test('the iOS gate needs no signing identity', () {
      // The point of --no-codesign: Apple portal access and the provisioning
      // profile are BLOCKED external dependencies. A gate that needed them
      // could never run, so it would be disabled and the coverage lost.
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('--no-codesign'));
      for (final signing in const [
        'CERTIFICATE_PRIVATE_KEY',
        'APP_STORE_CONNECT',
        'xcode-project use-profiles',
      ]) {
        expect(quality.contains(signing), isFalse,
            reason: 'the iOS gate must not depend on signing: found "$signing"');
      }
    });

    test('the gate proves the app AND the embedded extension were built', () {
      // The defect lived in the share extension, which is a separate binary. A
      // Runner.app produced without its .appex would read as success.
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('build/ios/iphoneos/Runner.app'));
      expect(quality, contains('PlugIns/ShareBankMessage.appex'));
    });
  });

  group('toolchain pinning', () {
    test('Flutter and JDK are pinned on the compile workflow', () {
      // 3.44.2 -> 3.47.3 on 2026-09-26. The literal tracks the locally proven
      // SDK, so it moves when that does; this is the pin being maintained, not
      // relaxed.
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('flutter: 3.47.3'),
          reason: 'the compile must reproduce the locally proven Flutter');
      expect(quality, contains('java: 17'),
          reason: 'AGP 9 + jvmTarget 17 require JDK 17');
    });

    test('EVERY workflow pins the same Flutter, not just the compile gate', () {
      // Codemagic build 64 died at `flutter pub get` before compiling anything:
      // ios-signed-release still pinned 3.44.2, whose flutter_localizations
      // requires intl 0.20.2 exactly, while pubspec.lock was resolved against
      // 3.47.3 which requires ^0.20.3. Two SDK-pinned constraints, no solution.
      //
      // The compile gate alone was pinned, so nothing noticed the other three
      // drifting. This pins the AGREEMENT: one SDK across every workflow.
      final ci = File('../codemagic.yaml').readAsStringSync();
      final pins = RegExp(r'^\s*flutter:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$',
              multiLine: true)
          .allMatches(ci)
          .map((m) => m.group(1))
          .toList();

      expect(pins, isNotEmpty, reason: 'no Flutter pins found at all');
      expect(pins.toSet(), hasLength(1),
          reason: 'workflows disagree on the Flutter SDK: $pins — a lagging '
              'pin is what broke build 64');
      expect(pins.first, '3.47.3');
    });

    test('the pinned NDK is installed rather than assumed', () {
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('28.2.13676358'),
          reason: 'sqlite3mc is a native asset; the NDK version must be explicit');
    });

    test('the project toolchain itself is unchanged', () {
      final settings =
          File('android/settings.gradle.kts').readAsStringSync();
      expect(settings, contains('"9.0.1"'), reason: 'AGP');
      expect(settings, contains('"2.3.20"'), reason: 'Kotlin');
      final wrapper = File('android/gradle/wrapper/gradle-wrapper.properties')
          .readAsStringSync();
      expect(wrapper, contains('gradle-9.1.0'));
    });
  });

  group('the gate uses the vendored file_picker', () {
    test('CI refuses to build if resolution falls back to pub.dev', () {
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('path: ../third_party/file_picker'),
          reason: 'CI must assert the vendored fork is wired');
      expect(quality, contains('QIRSH_FORK.md'),
          reason: 'the failure message should point at the provenance doc');
    });

    test('the companion dependencies stay unmigrated', () {
      final lock = File('pubspec.lock').readAsStringSync();
      expect(lock, contains('version: "10.1.4"'), reason: 'share_plus');
      expect(lock, contains('version: "9.2.4"'), reason: 'flutter_secure_storage');
      expect(RegExp(r'name: win32\n(?:.*\n)*?    version: "6\.').hasMatch(lock),
          isFalse, reason: 'win32 must stay on 5.x');
    });
  });

  // Added 2026-09-05 after Codemagic REJECTED the whole file with
  //   "backend-and-quality-gates -> triggering -> when: extra fields not permitted"
  // `when` is a WORKFLOW-level key and a sibling of `triggering`, never a child.
  // Nested, the config does not merely misbehave — it fails schema validation, so
  // NO workflow runs at all and the repository silently loses every gate it
  // believes it has. That is the worst failure mode available here, and it is
  // invisible to every other test, because they all read the YAML as text.
  // Added 2026-09-05 when the production AdMob identifiers were wired in.
  //
  // STRUCTURAL, not textual. Every other codemagic assertion in this file greps
  // the YAML as a string, which cannot tell "the group is attached to this
  // workflow" from "the word appears somewhere in a comment". Group attachment
  // decides which builds carry production monetization credentials, so it is
  // parsed properly.
  group('admob group attachment', () {
    Map<String, List<String>> groupsByWorkflow() {
      final doc = loadYaml(File('../codemagic.yaml').readAsStringSync()) as Map;
      final workflows = doc['workflows'] as Map;
      return {
        for (final entry in workflows.entries)
          entry.key as String: (((entry.value as Map)['environment']
                          as Map?)?['groups'] as List?)
                      ?.map((e) => e.toString())
                      .toList() ??
                  const <String>[],
      };
    }

    test('admob is attached to EXACTLY the Android signed release workflow',
        () {
      // Owner decision 3.2 (2026-11-17): Version 1 (iPhone) has no advertising,
      // so no iOS workflow carries production AdMob credentials any more.
      final groups = groupsByWorkflow();
      final withAdmob = groups.entries
          .where((e) => e.value.contains('admob'))
          .map((e) => e.key)
          .toSet();
      expect(withAdmob, {'android-release'},
          reason: 'production AdMob credentials belong to the Android signed '
              'release build and nowhere else');
    });

    test('no iOS workflow can compile ads in or pass an AdMob id (3.2)', () {
      for (final wf in const [
        'ios-signed',
        'ios-signed-release',
        'ios-unsigned-sideload',
      ]) {
        final body = _workflow(wf);
        expect(body.contains('--dart-define=QIRSH_ADS_ENABLED'), isFalse,
            reason: '$wf must not compile advertising in');
        expect(RegExp(r'--dart-define=ADMOB_').hasMatch(body), isFalse,
            reason: '$wf must not pass AdMob identifiers to Dart');
        expect(body.contains("printf 'ADMOB_APP_ID_IOS"), isFalse,
            reason: '$wf must not write an AdMob app id into Info.plist');
      }
      for (final wf in const ['ios-signed', 'ios-signed-release']) {
        expect(_workflow(wf), contains('rm -f ios/Flutter/AdMob.xcconfig'),
            reason: '$wf must remove a stale AdMob.xcconfig before building');
      }
      // Android (outside V1) keeps its existing ads behaviour explicitly.
      expect(_workflow('android-release'),
          contains('--dart-define=QIRSH_ADS_ENABLED=true'));
    });

    test('admob is NOT attached to the quality gate', () {
      // That workflow runs AUTOMATICALLY on every push and pull request. It must
      // carry no production monetization credential it does not need — the same
      // reason it carries no signing key and performs no store upload.
      expect(groupsByWorkflow()['backend-and-quality-gates'],
          isNot(contains('admob')),
          reason: 'the auto-triggered quality gate must never hold production '
              'AdMob configuration');
    });

    test('admob is NOT attached to the unsigned sideload', () {
      // A sideload artifact is for testing. Production ad units in a build that
      // is handed around informally is how test traffic becomes real traffic.
      expect(groupsByWorkflow()['ios-unsigned-sideload'], isNot(contains('admob')),
          reason: 'the unsigned sideload build must not carry production ad units');
    });

    test('the groups each release workflow actually needs are all present', () {
      // Attaching admob must not have displaced anything. Android in particular
      // needs google_play for the upload key, and BOTH need supabase or the
      // build fails its own fail-closed backend assertion.
      final groups = groupsByWorkflow();
      expect(groups['android-release'],
          containsAll(<String>['supabase', 'google_play', 'admob']));
      expect(groups['ios-signed-release'], contains('supabase'));
      expect(groups['ios-unsigned-sideload'], contains('supabase'));
    });
  });

  group('codemagic schema shape', () {
    test('`when` is never nested inside `triggering`', () {
      final lines = File('../codemagic.yaml').readAsLinesSync();
      // `triggering:` children are indented deeper than the key itself. Walk the
      // block and fail if `when:` appears inside it.
      for (var i = 0; i < lines.length; i++) {
        final m = RegExp(r'^(\s*)triggering:\s*$').firstMatch(lines[i]);
        if (m == null) continue;
        final baseIndent = m.group(1)!.length;
        for (var j = i + 1; j < lines.length; j++) {
          final line = lines[j];
          if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
          final indent = line.length - line.trimLeft().length;
          if (indent <= baseIndent) break; // left the triggering block
          expect(RegExp(r'^\s*when:').hasMatch(line), isFalse,
              reason: 'codemagic.yaml:${j + 1} nests `when:` inside '
                  '`triggering:`. Codemagic rejects the entire file — no '
                  'workflow runs. Move `when:` to workflow level, as a sibling '
                  'of `triggering:`.');
        }
      }
    });

    test('the changeset exclusion survived the move', () {
      // The move must not quietly drop the docs-only skip, or every README edit
      // spends two native builds.
      final ci = File('../codemagic.yaml').readAsStringSync();
      expect(ci, contains('changeset:'));
      expect(ci, contains("- 'docs/**'"));
      expect(ci, contains("- '**/*.md'"));
    });

    test('the quality gate still triggers automatically on the dev path', () {
      // The whole reason this workflow exists is that it must not sit behind a
      // human pressing Run. A schema fix must not cost that.
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('triggering:'));
      for (final needed in const [
        '- push',
        '- pull_request',
        'cancel_previous_builds: true',
        "pattern: 'feat/*'",
      ]) {
        expect(quality, contains(needed),
            reason: 'automatic triggering lost "$needed"');
      }
    });
  });

  // Added 2026-09-04 while reconciling the iOS release config. These are about
  // what a SUCCESSFUL build does, which is the part nobody looks at until it has
  // already happened.
  group('iOS release config safety', () {
    test('auto-submit is on ONLY with the authorisation recorded beside it', () {
      // INVERTED 2026-09-26, deliberately.
      //
      // This asserted `submit_to_testflight: true` was absent, because on
      // 2026-09-04 submission was not authorised, no iOS build had run on a
      // physical device, and until 2026-09-03 iOS did not compile at all. All
      // three have since changed and the owner authorised TestFlight upload for
      // 1.0.0 (41).
      //
      // The guard is not dropped, because what it was really protecting against
      // was auto-submit arriving SILENTLY. So it still has teeth: if the flag is
      // on, the block must carry the dated authorisation note and say in as many
      // words that this is TestFlight and not App Review. Turning it on without
      // saying why still fails.
      final ios = _workflow('ios-signed-release');
      if (!ios.contains('submit_to_testflight: true')) return;

      expect(ios.contains('AUTO-SUBMIT IS ON'), isTrue,
          reason: 'auto-submit may only be enabled alongside a dated note '
              'recording who authorised it and why');
      expect(ios.contains('TESTFLIGHT ONLY'), isTrue,
          reason: 'the block must state that this uploads for internal '
              'distribution and does NOT submit for App Review');
    });

    test('release config carries no placeholder bundle identifier', () {
      // The template id (com.example.*) shipping in a release config is the iOS
      // analogue of the Kotlin package bug: it looks fine until an artifact is
      // signed and rejected, or worse, accepted under the wrong identity.
      final ci = File('../codemagic.yaml').readAsStringSync();
      expect(ci.contains('com.example'), isFalse,
          reason: 'codemagic.yaml contains a com.example placeholder id');
      expect(ci.contains('moneyCompanion'), isFalse,
          reason: 'codemagic.yaml contains the stale moneyCompanion id');
      expect(ci, contains('bundle_identifier: com.youssefsafwat.mali'),
          reason: 'the signed iOS workflow must name the authoritative bundle id');
    });

    test('every iOS bundle id in the Xcode project is under the app id', () {
      // Runner, the share extension and the test host. The extension is a
      // separate signed binary and needs its own App ID and profile; a stale one
      // here fails at export, long after the compile that looked fine.
      final pbx =
          File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
      final ids = RegExp(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);')
          .allMatches(pbx)
          // Values carrying a build-setting reference are quoted in pbxproj
          // (PRODUCT_BUNDLE_IDENTIFIER = "com.youssefsafwat.mali$(SUFFIX)"),
          // so strip quotes before checking the prefix.
          .map((m) => m.group(1)!.trim().replaceAll('"', ''))
          .toSet();
      expect(ids, isNotEmpty);
      for (final id in ids) {
        expect(id.startsWith('com.youssefsafwat.mali'), isTrue,
            reason: 'unexpected iOS bundle identifier: $id');
      }
    });
  });

  group('separation of responsibilities', () {
    test('the compile gate needs no signing key', () {
      final quality = _workflow('backend-and-quality-gates');
      for (final secret in const [
        'ANDROID_KEYSTORE_BASE64',
        'ANDROID_KEYSTORE_PASSWORD',
        'ANDROID_KEY_ALIAS',
        'ANDROID_KEY_PASSWORD',
        'google_play',
      ]) {
        expect(quality.contains(secret), isFalse,
            reason: 'a debug compile must not require $secret');
      }
    });

    test('the compile gate needs no production AdMob configuration', () {
      final quality = _workflow('backend-and-quality-gates');
      for (final v in const ['ADMOB_APP_ID_ANDROID', 'ADMOB_INTERSTITIAL_ANDROID']) {
        expect(quality.contains(v), isFalse,
            reason: 'ordinary verification must not need production $v');
      }
    });

    test('the release workflow still demands explicit signing inputs', () {
      final release = _workflow('android-release');
      expect(release, contains('ANDROID_KEYSTORE_BASE64'));
      expect(release, contains('Materialise upload keystore'));
      expect(release, contains('flutter build appbundle --release'),
          reason: 'the real Play artifact stays in the release workflow');
    });

    test('GitHub Actions stays verification-only (no Android secrets)', () {
      final gha = File('../.github/workflows/ci.yml').readAsStringSync();
      expect(gha, contains('ci_gates.sh'));
      for (final secret in const [
        'ANDROID_KEYSTORE_BASE64',
        'ANDROID_KEY_PASSWORD',
      ]) {
        expect(gha.contains(secret), isFalse,
            reason: 'do not duplicate release secrets into GitHub: $secret');
      }
    });
  });

  group('ci_gates.sh boundary', () {
    // Deliberate: ci_gates.sh must stay portable. Forcing every local run to
    // fetch a ~3 GB NDK would destroy its usefulness, so the Android compile
    // lives in the CI workflow as a second mandatory stage instead.
    test('the portable local suite does not require Android tooling', () {
      final gates = File('../tools/ci_gates.sh').readAsStringSync();
      for (final heavy in const [
        'flutter build apk',
        'flutter build appbundle',
        'sdkmanager',
        'gradlew',
      ]) {
        expect(gates.contains(heavy), isFalse,
            reason: 'ci_gates.sh must stay portable: found "$heavy"');
      }
    });
  });

  group('release workflow ordering (§13)', () {
    test('the artifact signer is inspected before the key is shredded', () {
      final release = _workflow('android-release');
      expect(release, contains('Inspect release artifact signer'));
      expect(release.indexOf('Build release App Bundle'),
          lessThan(release.indexOf('Inspect release artifact signer')),
          reason: 'inspect after building');
      expect(release.indexOf('Inspect release artifact signer'),
          lessThan(release.indexOf('Shred materialised keystore')),
          reason: 'inspect before the key disappears');
    });

    test('a debug-signed or unsigned artifact fails the release', () {
      final release = _workflow('android-release');
      expect(release, contains('Android Debug'),
          reason: 'the debug certificate must be explicitly rejected');
      expect(release, contains('is not signed'));
    });
  });
}
