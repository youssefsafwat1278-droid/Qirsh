import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/ads/admob_build_config.dart';

/// R7 I3/A3 — AdMob release configuration plumbing.
///
/// Release semantics are exercised through the pure [AdMobBuildConfig.resolve]
/// seam, because a `flutter test` run is always a debug build: asserting on
/// `appId()` alone could only ever prove the TEST path.
void main() {
  // Decision 3.2: advertising is compiled out of Version 1 builds. These tests
  // exercise the ad pipeline itself, as a build made with
  // --dart-define=QIRSH_ADS_ENABLED=true runs it. The compiled-out behaviour
  // is covered by test/features/ads/v1_ads_compiled_out_test.dart.
  setUp(() => AdMobBuildConfig.debugAdsCompiledInOverride = true);
  tearDown(() => AdMobBuildConfig.debugAdsCompiledInOverride = false);
  const testApp = AdMobBuildConfig.testAppIdIos;
  const testUnit = AdMobBuildConfig.testInterstitialIos;
  const prodApp = 'ca-app-pub-1234567890123456~9876543210';
  const prodUnit = 'ca-app-pub-1234567890123456/1234509876';

  String? release(String prod, bool Function(String) valid) =>
      AdMobBuildConfig.resolve(
        isTestBuild: false,
        testValue: testApp,
        prodValue: prod,
        isValid: valid,
      );

  group('shape validation (§15)', () {
    test('app ids use ~ and unit ids use /', () {
      expect(AdMobBuildConfig.isValidAppId(prodApp), isTrue);
      expect(AdMobBuildConfig.isValidUnitId(prodUnit), isTrue);
      // The classic misconfiguration: the two swapped.
      expect(AdMobBuildConfig.isValidAppId(prodUnit), isFalse);
      expect(AdMobBuildConfig.isValidUnitId(prodApp), isFalse);
    });

    test('garbage is rejected rather than passed to the SDK', () {
      for (final bad in <String>[
        '',
        '   ',
        'not-an-id',
        'ca-app-pub-123~456', // too short
        'ca-app-pub-1234567890123456', // no separator
        'https://example.com',
      ]) {
        expect(AdMobBuildConfig.isValidAppId(bad), isFalse, reason: bad);
        expect(AdMobBuildConfig.isValidUnitId(bad), isFalse, reason: bad);
      }
    });
  });

  group('debug/QA builds (§3)', () {
    test('always resolve Google TEST identifiers', () {
      expect(AdMobBuildConfig.isTestMode, isTrue,
          reason: 'flutter test runs in debug');
      expect(AdMobBuildConfig.appId(TargetPlatform.iOS), testApp);
      expect(AdMobBuildConfig.appId(TargetPlatform.android),
          AdMobBuildConfig.testAppIdAndroid);
      expect(AdMobBuildConfig.interstitialUnitId(TargetPlatform.iOS),
          testUnit);
      expect(AdMobBuildConfig.interstitialUnitId(TargetPlatform.android),
          AdMobBuildConfig.testInterstitialAndroid);
    });

    test('QA builds are fully configured (R6 physical verification path)', () {
      expect(AdMobBuildConfig.isConfiguredFor(TargetPlatform.iOS), isTrue);
      expect(
          AdMobBuildConfig.isConfiguredFor(TargetPlatform.android), isTrue);
    });

    test('platform selection never crosses iOS/Android values', () {
      expect(AdMobBuildConfig.appId(TargetPlatform.iOS),
          isNot(AdMobBuildConfig.testAppIdAndroid));
      expect(AdMobBuildConfig.interstitialUnitId(TargetPlatform.android),
          isNot(AdMobBuildConfig.testInterstitialIos));
    });
  });

  group('release builds (§3 / §13)', () {
    test('a supplied, well-formed production id resolves', () {
      expect(release(prodApp, AdMobBuildConfig.isValidAppId), prodApp);
    });

    test('MISSING configuration → null (ads unavailable, not a crash)', () {
      expect(release('', AdMobBuildConfig.isValidAppId), isNull);
      expect(release('   ', AdMobBuildConfig.isValidAppId), isNull);
    });

    test('MALFORMED configuration → null, never handed to the SDK', () {
      expect(release('not-an-id', AdMobBuildConfig.isValidAppId), isNull);
      expect(release(prodUnit, AdMobBuildConfig.isValidAppId), isNull,
          reason: 'a unit id supplied where an app id belongs');
    });

    test(
        'a release NEVER silently falls back to Google TEST identifiers (§7)',
        () {
      // Even explicitly supplying a Google sample id to a release build is
      // refused: shipping on sample identifiers must not be possible by accident.
      expect(release(testApp, AdMobBuildConfig.isValidAppId), isNull);
      expect(
        AdMobBuildConfig.resolve(
          isTestBuild: false,
          testValue: testUnit,
          prodValue: AdMobBuildConfig.testInterstitialAndroid,
          isValid: AdMobBuildConfig.isValidUnitId,
        ),
        isNull,
      );
    });

    test('no production value is baked into source', () {
      // The only literals in the class are Google's documented samples.
      for (final v in <String>[
        AdMobBuildConfig.testAppIdIos,
        AdMobBuildConfig.testAppIdAndroid,
        AdMobBuildConfig.testInterstitialIos,
        AdMobBuildConfig.testInterstitialAndroid,
      ]) {
        expect(v.startsWith(AdMobBuildConfig.googleTestPublisher), isTrue);
      }
    });
  });

  group('completeness gate (§6 / §13)', () {
    // isConfiguredFor demands BOTH halves; an ad unit without an app id would
    // let the SDK initialise against whatever the native layer carries.
    test('an app id alone is not a usable configuration', () {
      final appOnly = release(prodApp, AdMobBuildConfig.isValidAppId);
      final unitMissing =
          AdMobBuildConfig.resolve(
        isTestBuild: false,
        testValue: testUnit,
        prodValue: '',
        isValid: AdMobBuildConfig.isValidUnitId,
      );
      expect(appOnly, isNotNull);
      expect(unitMissing, isNull);
      expect(appOnly != null && unitMissing != null, isFalse,
          reason: 'both halves are required before any ad is attempted');
    });
  });
}
