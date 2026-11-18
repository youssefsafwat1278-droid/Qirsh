import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/admob_build_config.dart';

/// Banner ad-unit configuration.
///
/// The property that matters: a development build can NEVER touch a production
/// unit, and a release build can never quietly fall back to Google's sample
/// units. Both directions are failures — the first spends someone's ad budget
/// on a simulator, the second ships an app that earns nothing and looks fine.

void main() {
  // Decision 3.2: advertising is compiled out of Version 1 builds. These tests
  // exercise the ad pipeline itself, as a build made with
  // --dart-define=QIRSH_ADS_ENABLED=true runs it. The compiled-out behaviour
  // is covered by test/features/ads/v1_ads_compiled_out_test.dart.
  setUp(() => AdMobBuildConfig.debugAdsCompiledInOverride = true);
  tearDown(() => AdMobBuildConfig.debugAdsCompiledInOverride = false);
  test('debug/profile builds resolve Google TEST banner units', () {
    // The suite runs in debug, so this is the live path, not a simulation.
    expect(AdMobBuildConfig.isTestMode, isTrue);
    expect(
      AdMobBuildConfig.bannerUnitId(TargetPlatform.iOS),
      AdMobBuildConfig.testBannerIos,
    );
    expect(
      AdMobBuildConfig.bannerUnitId(TargetPlatform.android),
      AdMobBuildConfig.testBannerAndroid,
    );
    for (final unit in const [
      AdMobBuildConfig.testBannerIos,
      AdMobBuildConfig.testBannerAndroid,
    ]) {
      expect(unit, startsWith(AdMobBuildConfig.googleTestPublisher),
          reason: 'a test unit that is not Google\'s cannot be billed to '
              'nobody — it is billed to somebody');
      expect(AdMobBuildConfig.isValidUnitId(unit), isTrue);
    }
  });

  test('the two banner test units are distinct from the interstitial units',
      () {
    // A copy-paste that reused the interstitial unit for banners would still
    // "work" in QA and would report every banner as an interstitial.
    final units = {
      AdMobBuildConfig.testBannerIos,
      AdMobBuildConfig.testBannerAndroid,
      AdMobBuildConfig.testInterstitialIos,
      AdMobBuildConfig.testInterstitialAndroid,
    };
    expect(units.length, 4);
  });

  group('release resolution (pure, no release build required)', () {
    const prodUnit = 'ca-app-pub-1234567890123456/1234567890';

    test('an absent production unit resolves to null — fail closed', () {
      expect(
        AdMobBuildConfig.resolve(
          isTestBuild: false,
          testValue: AdMobBuildConfig.testBannerIos,
          prodValue: '',
          isValid: AdMobBuildConfig.isValidUnitId,
        ),
        isNull,
      );
    });

    test('a malformed production unit resolves to null', () {
      for (final bad in const [
        'ca-app-pub-1234567890123456~1234567890', // an APP id, not a unit
        'ca-app-pub-123/1234567890', // too few publisher digits
        'not-an-id',
        'ca-app-pub-1234567890123456/12345678901', // too many unit digits
      ]) {
        expect(
          AdMobBuildConfig.resolve(
            isTestBuild: false,
            testValue: AdMobBuildConfig.testBannerIos,
            prodValue: bad,
            isValid: AdMobBuildConfig.isValidUnitId,
          ),
          isNull,
          reason: bad,
        );
      }
    });

    test('a release NEVER falls back to the Google test publisher', () {
      expect(
        AdMobBuildConfig.resolve(
          isTestBuild: false,
          testValue: AdMobBuildConfig.testBannerIos,
          prodValue: AdMobBuildConfig.testBannerAndroid,
          isValid: AdMobBuildConfig.isValidUnitId,
        ),
        isNull,
        reason: 'a production artifact running on sample units is a silent '
            'zero-revenue release',
      );
    });

    test('a well-formed production unit is used verbatim', () {
      expect(
        AdMobBuildConfig.resolve(
          isTestBuild: false,
          testValue: AdMobBuildConfig.testBannerIos,
          prodValue: '  $prodUnit  ',
          isValid: AdMobBuildConfig.isValidUnitId,
        ),
        prodUnit,
      );
    });
  });

  test('a banner needs BOTH an app id and a unit id', () {
    // A unit without an app id makes the SDK initialise against whatever the
    // native layer happens to carry, which on a release with no injected value
    // is the placeholder — the exact silent-test-identifier case this guards.
    expect(AdMobBuildConfig.isBannerConfiguredFor(TargetPlatform.iOS),
        AdMobBuildConfig.appId(TargetPlatform.iOS) != null &&
            AdMobBuildConfig.bannerUnitId(TargetPlatform.iOS) != null);
  });

  test('every placement resolves to the configured banner unit', () {
    for (final placement in AdPlacement.values) {
      for (final platform in const [
        TargetPlatform.iOS,
        TargetPlatform.android,
      ]) {
        expect(
          bannerUnitFor(placement, platform),
          AdMobBuildConfig.bannerUnitId(platform),
          reason: '${placement.key} on $platform',
        );
      }
    }
  });

  test('placement keys are stable and unique', () {
    // The key is a remote flag suffix and an analytics dimension. Deriving it
    // from `name` would let a Dart rename silently change both at once.
    final keys = AdPlacement.values.map((p) => p.key).toList();
    expect(keys.toSet().length, keys.length);
    expect(keys, contains('transactions_list'));
    for (final k in keys) {
      expect(RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(k), isTrue, reason: k);
    }
  });
}
