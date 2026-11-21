import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

/// Cross-model audit **H-15 / H-16** (Batch 15) — CI authority / release-gate
/// enforcement.
///
/// H-15: a release workflow could jump pub-get → sign → build → submit without
/// running the canonical verification. H-16: the workflow holding the ONLY
/// Android compile coverage had no `triggering:` block, so it never ran
/// automatically.
///
/// These are STRUCTURAL assertions over the PARSED codemagic.yaml (not fragile
/// whitespace/regex scans): every artifact-producing workflow must invoke the
/// canonical gate BEFORE any signing/build/submit step, the quality workflow
/// must auto-trigger and carry a fatal Android compile, and release workflows
/// must stay manual (no accidental store submission from a PR).
YamlMap get _cm =>
    loadYaml(File('../codemagic.yaml').readAsStringSync()) as YamlMap;

YamlMap _workflow(String name) {
  final w = (_cm['workflows'] as YamlMap)[name];
  expect(w, isNotNull, reason: 'workflow $name missing');
  return w as YamlMap;
}

/// The ordered step scripts of a workflow, as (name, script) pairs.
List<({String name, String script})> _steps(String workflow) {
  final scripts = _workflow(workflow)['scripts'] as YamlList;
  return [
    for (final s in scripts)
      (
        name: (s as YamlMap)['name']?.toString() ?? '',
        script: s['script']?.toString() ?? '',
      ),
  ];
}

/// Index of the first step whose name or script contains [needle], or -1.
int _firstStep(List<({String name, String script})> steps, String needle) {
  for (var i = 0; i < steps.length; i++) {
    if (steps[i].name.contains(needle) || steps[i].script.contains(needle)) {
      return i;
    }
  }
  return -1;
}

/// Every workflow that builds a distributable artifact.
///
/// `ios-signed-release` is not listed: by owner decision (2026-11-21) its
/// canonical gates run locally before every push to release/*, because with
/// them the workflow exceeded Codemagic's 120-minute limit.
const _artifactWorkflows = [
  'ios-unsigned-sideload',
  'android-release',
];

void main() {
  group('H-15 — the canonical gate precedes artifact production', () {
    for (final wf in _artifactWorkflows) {
      test('$wf runs ci_gates.sh (strict) before any build/sign/submit', () {
        final steps = _steps(wf);
        final gateAt = _firstStep(steps, 'ci_gates.sh');
        expect(gateAt, greaterThan(-1),
            reason: '$wf must invoke the canonical gate');
        // Strict so a missing tool cannot hollow-pass a release gate.
        expect(steps[gateAt].script, contains('REQUIRE_ALL_GATES=1'),
            reason: '$wf must run the gate in strict mode');

        // The gate must come before EVERY artifact/signing action.
        for (final action in const [
          'flutter build',
          'xcode-project use-profiles',
          'Materialise upload keystore',
          'Materialise AdMob',
          'Build signed IPA',
          'Build release App Bundle',
          'Build unsigned',
          'Package .app',
        ]) {
          final at = _firstStep(steps, action);
          if (at > -1) {
            expect(gateAt, lessThan(at),
                reason: '$wf: the gate must precede "$action" so a gate '
                    'failure makes it unreachable');
          }
        }
      });

      test('$wf gate steps are FATAL (no allow/ignore-failure)', () {
        final scripts = _workflow(wf)['scripts'] as YamlList;
        for (final s in scripts) {
          final step = s as YamlMap;
          final name = step['name']?.toString() ?? '';
          if (name.contains('ci_gates.sh') ||
              name.contains('Canonical gates')) {
            final script = step['script'].toString();
            // Codemagic step-level soft-fail fields must be absent on a gate.
            expect(step['ignore_failure'], isNot(true), reason: '$wf: $name');
            expect(step.containsKey('allow_failure'), isFalse);
            // The gate INVOCATION itself must not be softened (a `|| true` on a
            // preliminary best-effort line like keychain-unlock is fine — with
            // `set -eu`, a failing ci_gates.sh still aborts the step).
            expect(script, contains('set -eu'),
                reason: '$wf: $name must abort on any preceding failure');
            expect(
                RegExp(r'ci_gates\.sh.*\|\|\s*true').hasMatch(script), isFalse,
                reason: '$wf: the gate invocation must not be `|| true`d');
            expect(script.contains('ci_gates.sh || '), isFalse);
          }
        }
      });
    }

    test('ios-signed-release: the App Store upload never submits',
        () {
      final wf = _workflow('ios-signed-release');
      // The workflow uploads to App Store Connect, but it never asks for external beta or App Review itself
      // (REL-03 / V1-009): those are deliberate owner actions.
      final asc = (wf['publishing'] as YamlMap)['app_store_connect'] as YamlMap?;
      expect(asc, isNotNull,
          reason: 'this test guards the uploading workflow specifically');
      expect(asc!['auth'], 'integration');
      expect(asc['submit_to_testflight'], isFalse,
          reason: 'submit_to_testflight requests external beta review');
      expect(asc.containsKey('submit_to_app_store'), isFalse,
          reason: 'the pipeline must never submit for App Review by itself');
    });

    test('android-release: gate precedes keystore AND build', () {
      final steps = _steps('android-release');
      final gate = _firstStep(steps, 'ci_gates.sh');
      expect(gate, greaterThan(-1));
      expect(gate, lessThan(_firstStep(steps, 'Materialise upload keystore')));
      expect(gate, lessThan(_firstStep(steps, 'Build release App Bundle')));
    });
  });

  group('H-16 — the Android compile gate runs automatically and fatally', () {
    test('the quality workflow has a real push/PR trigger', () {
      final wf = _workflow('backend-and-quality-gates');
      final trig = wf['triggering'] as YamlMap?;
      expect(trig, isNotNull,
          reason: 'without triggering:, the Android compile never runs '
              'automatically (H-16)');
      final events = (trig!['events'] as YamlList).map((e) => e.toString());
      expect(events, containsAll(['push', 'pull_request']));
    });

    test('the triggered workflow carries the Android compile gate', () {
      final steps = _steps('backend-and-quality-gates');
      final at = _firstStep(steps, 'flutter build apk --debug');
      expect(at, greaterThan(-1),
          reason: 'the Android compile must be part of the auto-triggered '
              'workflow, not a separate manual one');
    });

    test('the Android compile is fatal (set -eu, artifact proof, no soft-fail)',
        () {
      final steps = _steps('backend-and-quality-gates');
      final compile =
          steps.firstWhere((s) => s.name.contains('Android compile'));
      expect(compile.script, contains('set -eu'));
      expect(compile.script, contains('app-debug.apk'),
          reason: 'proves the artifact exists, not just the exit code');
      for (final soft in const ['|| true', 'ignore_failure', 'allow_failure']) {
        expect(compile.script.contains(soft), isFalse, reason: soft);
      }
    });

    test('the quality workflow uses the ONE canonical script (no drift)', () {
      // Requirement 4: it runs tools/ci_gates.sh, not a hand-duplicated list.
      final steps = _steps('backend-and-quality-gates');
      expect(_firstStep(steps, 'ci_gates.sh'), greaterThan(-1));
    });
  });

  group('iOS release build-number collision preflight', () {
    test('queries the exact app and version before building the signed IPA',
        () {
      final steps = _steps('ios-signed-release');
      final preflightAt = _firstStep(
          steps, 'Resolve next iOS build number from App Store Connect');
      final buildAt = _firstStep(steps, 'Build signed IPA');

      expect(preflightAt, greaterThan(-1));
      expect(preflightAt, lessThan(buildAt));
      final preflight = steps[preflightAt].script;
      expect(preflight, contains('app-store-connect apps list'));
      expect(
          preflight, contains('--bundle-id-identifier com.youssefsafwat.mali'));
      expect(preflight, contains('--strict-match-identifier'));
      expect(preflight, contains('app-store-connect get-latest-build-number'));
      expect(preflight, contains('--version-string "\$MARKETING_VERSION"'));
      expect(preflight,
          contains('IOS_BUILD_NUMBER=\$((LATEST_BUILD_NUMBER + 1))'));
      expect(preflight, contains('>> "\$CM_ENV"'));
    });

    test('passes the resolved marketing version and build number to Flutter',
        () {
      final steps = _steps('ios-signed-release');
      final build = steps[_firstStep(steps, 'Build signed IPA')].script;
      expect(build, contains('--build-name="\$IOS_MARKETING_VERSION"'));
      expect(build, contains('--build-number="\$IOS_BUILD_NUMBER"'));
    });
  });

  group('trigger safety (requirements 10 / 11)', () {
    test('release/artifact workflows are NOT auto-triggered', () {
      for (final wf in _artifactWorkflows) {
        expect(_workflow(wf).containsKey('triggering'), isFalse,
            reason: '$wf must stay manual — an ordinary PR/push must never '
                'sign, submit, or distribute an artifact');
      }
    });

    test('no store upload was added to the quality workflow', () {
      final pub = _workflow('backend-and-quality-gates')['publishing'];
      final s = pub?.toString() ?? '';
      expect(s.contains('app_store_connect'), isFalse);
      expect(s.contains('google_play'), isFalse);
      expect(s.contains('testflight'), isFalse,
          reason:
              'the automatic quality workflow must never publish to a store');
    });

    test('the debug compile gate carries no signing secrets or prod AdMob', () {
      final steps = _steps('backend-and-quality-gates');
      final compile =
          steps.firstWhere((s) => s.name.contains('Android compile'));
      for (final secret in const [
        'ANDROID_KEYSTORE_BASE64',
        'ANDROID_KEY_PASSWORD',
        'ADMOB_APP_ID_ANDROID',
        'ADMOB_INTERSTITIAL_ANDROID',
      ]) {
        expect(compile.script.contains(secret), isFalse,
            reason: 'a debug compile must not require $secret');
      }
    });
  });

  group('strict gate preserves each reason (requirement 7)', () {
    final gates = File('../tools/ci_gates.sh').readAsStringSync();

    test('the three non-pass reasons are distinct classifiers, not one bucket',
        () {
      // A broad "external" bucket erased the distinction between a
      // caller-skipped mandatory test (fatal for a release) and an
      // artifact-dependent gate (deferred to post-build).
      expect(gates, contains('unavail()'), reason: 'UNAVAILABLE_TOOL');
      expect(gates, contains('caller_skipped()'),
          reason: 'CALLER_SKIPPED — a bypassed mandatory test');
      expect(gates, contains('artifact_pending()'),
          reason: 'ARTIFACT_NOT_YET_BUILT — deferred to post-build');
    });

    test(
        'strict fatality = tool-missing OR caller-skipped (NOT artifact-pending)',
        () {
      expect(
          gates,
          contains(
              'strict_fatal=\$((tool_missing_count + caller_skipped_count))'),
          reason: 'artifact-pending must never make a release gate fail');
    });

    test('SKIP_FLUTTER_TEST is classified caller_skipped (fatal under strict)',
        () {
      // The escape hatch: a release caller must not skip the mandatory tests.
      final flutterStages = RegExp(
              r'caller_skipped "flutter test (bulk|crypto) \(SKIP_FLUTTER_TEST=1\)"')
          .allMatches(gates)
          .length;
      expect(flutterStages, 2,
          reason: 'both flutter test stages must be caller_skipped, so '
              'SKIP_FLUTTER_TEST=1 is fatal under REQUIRE_ALL_GATES=1');
      expect(gates.contains('external "flutter test'), isFalse,
          reason: 'must not be re-labelled to a non-fatal external bucket');
    });

    test('iOS packaging pre-build is artifact_pending, not caller_skipped', () {
      expect(gates, contains('artifact_pending "ios packaging'),
          reason: 'it genuinely cannot run before the build');
    });

    test('release workflows pass REQUIRE_ALL_GATES=1', () {
      for (final wf in _artifactWorkflows) {
        final steps = _steps(wf);
        final gate = steps[_firstStep(steps, 'ci_gates.sh')];
        expect(gate.script, contains('REQUIRE_ALL_GATES=1'));
      }
    });
  });

  group('NEW-H-1 — one build-time-provenanced IPA is verified and published',
      () {
    final verifier =
        File('../tools/verify_ios_release_artifact.sh').readAsStringSync();
    final stamper = File('../tools/stamp_ios_provenance.sh').readAsStringSync();

    test('signed candidate discovery fails unless cardinality is exactly one',
        () {
      final steps = _steps('ios-signed-release');
      final release =
          steps[_firstStep(steps, 'verify_ios_release_artifact.sh')];

      expect(release.script, contains('--resolve-only "\$IPA_DIR"'),
          reason:
              'the exported candidate set must be resolved once before use');
      expect(release.script, contains('CANDIDATE='));
      expect(release.script, isNot(contains('head -1')),
          reason: 'a first match is not an exact-one assertion');
      expect(release.script, isNot(contains('ls build/ios/ipa')));
      expect(release.script, isNot(contains('build/ios/ipa/*.ipa')),
          reason: 'the release step must pass a resolved path, not a glob');

      expect(verifier, contains('expected exactly one IPA'));
      expect(verifier, contains('[ "\$count" -eq 1 ]'),
          reason: 'zero and multiple candidates must both fail');
      expect(verifier, isNot(contains('head -1')));

      final build = steps[_firstStep(steps, 'Build signed IPA')].script;
      expect(build, contains('rm -rf build/ios/ipa'),
          reason: 'a stale single IPA must be removed before this build');
      expect(build.indexOf('rm -rf build/ios/ipa'),
          lessThan(build.indexOf('flutter build ipa')));
    });

    test('published IPA path is the exact named path stamped and verified', () {
      final workflow = _workflow('ios-signed-release');
      final environment = workflow['environment'] as YamlMap;
      final vars = environment['vars'] as YamlMap;
      final releasePath = vars['IOS_RELEASE_IPA'].toString();
      final artifacts =
          (workflow['artifacts'] as YamlList).map((a) => a.toString()).toList();
      final steps = _steps('ios-signed-release');
      final release =
          steps[_firstStep(steps, 'verify_ios_release_artifact.sh')];

      expect(releasePath, 'app/build/ios/ipa/money_companion-signed.ipa');
      expect(releasePath, isNot(contains('*')));
      expect(artifacts.where((a) => a == r'$IOS_RELEASE_IPA'), hasLength(1),
          reason: 'Codemagic/TestFlight must collect only the named IPA');
      expect(
          artifacts.any((a) => a.contains('*.ipa') || a.endsWith('/**/*.ipa')),
          isFalse,
          reason: 'a wildcard could publish a stale unverified sibling');
      expect(release.script, contains(r'$CM_BUILD_DIR/$IOS_RELEASE_IPA'));
      expect(release.script,
          contains('bash ../tools/stamp_ios_provenance.sh "\$IPA"'));
      expect(release.script,
          contains('bash ../tools/verify_ios_release_artifact.sh "\$IPA"'));
    });

    test('provenance is produced after export and before verification', () {
      final steps = _steps('ios-signed-release');
      final buildAt = _firstStep(steps, 'Build signed IPA');
      final lifecycleAt = _firstStep(steps, 'stamp_ios_provenance.sh');
      expect(lifecycleAt, greaterThan(buildAt));

      final lifecycle = steps[lifecycleAt].script;
      final stampAt = lifecycle.indexOf('stamp_ios_provenance.sh');
      final verifyAt =
          lifecycle.indexOf('verify_ios_release_artifact.sh "\$IPA"');
      expect(stampAt, greaterThan(-1));
      expect(verifyAt, greaterThan(stampAt),
          reason: 'verification must consume, not manufacture, provenance');

      final stampInvocation = RegExp(
        r'^\s*bash\s+.*stamp_ios_provenance\.sh\s+"\$IPA"\s*$',
        multiLine: true,
      );
      expect(stampInvocation.hasMatch(verifier), isFalse,
          reason: 'the verifier must never create provenance itself');
      expect(verifier,
          contains('missing pre-existing build-time provenance sidecar'));
    });

    test('sidecar cryptographically binds exact IPA, commit, and build inputs',
        () {
      expect(stamper, contains('SIDE="\$ARTIFACT.provenance"'),
          reason: 'the record stays external to the signed bundle');
      expect(stamper, contains('artifact_sha256=\$ARTIFACT_SHA'));
      expect(stamper, contains('git_commit=\$COMMIT'));
      expect(stamper, contains('ios_input_sha=\$IOS_INPUT_SHA'));

      expect(verifier, contains('REC_ARTIFACT_SHA'));
      expect(verifier, contains('"\$REC_ARTIFACT_SHA" = "\$SHA_BEFORE"'));
      expect(verifier, contains('"\$REC_COMMIT" = "\$CURRENT_COMMIT"'));
      expect(verifier, contains('"\$REC_INPUT_SHA" = "\$CURRENT_INPUT_SHA"'));
      expect(verifier, contains('"\$REC_PATH" = "\$IPA"'));
      expect(verifier, contains("unzip -q \"\$IPA\" 'Payload/*'"),
          reason: 'inspect the payload inside the exact hashed IPA');
      expect(verifier, contains('[ "\$APP_COUNT" -eq 1 ]'),
          reason: 'the embedded app cannot use first-match selection either');
    });

    test('no operation after signing/stamping may change the IPA bytes', () {
      final steps = _steps('ios-signed-release');
      final lifecycle =
          steps[_firstStep(steps, 'stamp_ios_provenance.sh')].script;
      expect(lifecycle, contains('SHA_BEFORE_MOVE='));
      expect(lifecycle, contains('SHA_AFTER_MOVE='));
      expect(
          lifecycle, contains('[ "\$SHA_AFTER_MOVE" = "\$SHA_BEFORE_MOVE" ]'));

      final afterStamp = lifecycle.substring(
          lifecycle.indexOf('bash ../tools/stamp_ios_provenance.sh'));
      for (final mutation in [
        RegExp(r'\bzip\b'),
        RegExp(r'\bcodesign\b'),
        RegExp(r'\b(mv|cp|rm)\b[^\n]*\$IPA'),
      ]) {
        expect(mutation.hasMatch(afterStamp), isFalse,
            reason: 'the final signed bytes must be immutable after stamping');
      }

      expect(verifier, contains('SHA_BEFORE='));
      expect(verifier, contains('SHA_AFTER='));
      expect(verifier, contains('[ "\$SHA_AFTER" = "\$SHA_BEFORE" ]'));
    });

    test('unsigned sideload uses one explicit path for package/verify/publish',
        () {
      final workflow = _workflow('ios-unsigned-sideload');
      final environment = workflow['environment'] as YamlMap;
      final vars = environment['vars'] as YamlMap;
      final artifacts =
          (workflow['artifacts'] as YamlList).map((a) => a.toString()).toList();
      final steps = _steps('ios-unsigned-sideload');
      final package = steps[_firstStep(steps, 'Package .app')].script;
      final verifyAt = _firstStep(steps, 'verify_ios_release_artifact.sh');
      final verify = steps[verifyAt].script;

      expect(vars['IOS_UNSIGNED_IPA'].toString(),
          'app/money_companion-unsigned.ipa');
      expect(artifacts.where((a) => a == r'$IOS_UNSIGNED_IPA'), hasLength(1));
      expect(package, contains(r'IPA="$CM_BUILD_DIR/$IOS_UNSIGNED_IPA"'));
      expect(verify, contains(r'IPA="$CM_BUILD_DIR/$IOS_UNSIGNED_IPA"'));
      expect(verify, contains('stamp_ios_provenance.sh "\$IPA"'));
      expect(verify, contains('verify_ios_release_artifact.sh "\$IPA"'));
      expect(verifyAt, greaterThan(_firstStep(steps, 'Package .app')));
    });

    test('synthetic regression harness is non-vacuous for old stamp-at-verify',
        () {
      final harness = File('../tools/test_verify_ios_release_artifact.sh')
          .readAsStringSync();
      expect(harness, contains('zero candidate IPAs fail closed'));
      expect(harness, contains('multiple candidate IPAs fail closed'));
      expect(harness, contains('missing pre-existing provenance is rejected'));
      expect(harness, contains('[ ! -e "\$IPA.provenance" ]'),
          reason: 'the old verifier created provenance during this assertion');
      expect(
          harness,
          contains(
              'non-vacuity control: legacy stamp-at-verify accepts unstamped fixture'));
      expect(harness,
          contains('stamping and verification do not alter signed IPA bytes'));
    });

    test('android-release keeps its mandatory post-build signer inspection',
        () {
      final steps = _steps('android-release');
      final buildAt = _firstStep(steps, 'Build release App Bundle');
      final inspectAt = _firstStep(steps, 'Inspect release artifact signer');
      expect(inspectAt, greaterThan(buildAt),
          reason: 'signer inspection must remain a mandatory post-build gate');
      final inspect = steps[inspectAt];
      expect(inspect.script, contains('is not signed'));
      expect(inspect.script, contains('Android Debug'),
          reason: 'a debug/unsigned artifact must be rejected');
    });
  });
}
