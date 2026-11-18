import 'package:flutter/foundation.dart';

/// Build-time AdMob configuration — the SINGLE registry of every AdMob input
/// this app has, for every format.
///
/// AdMob identifiers are DEPLOYMENT/BUILD configuration — never Admin-editable
/// DB rows, never business data, never a remote feature-config value (docs
/// REFERRAL_ADS_ADMIN_SYSTEM.md §3). There are exactly six release inputs, all
/// supplied at build time:
///
///   ADMOB_APP_ID_IOS          ADMOB_INTERSTITIAL_IOS      ADMOB_BANNER_IOS
///   ADMOB_APP_ID_ANDROID      ADMOB_INTERSTITIAL_ANDROID  ADMOB_BANNER_ANDROID
///
/// BANNERS were added here rather than in a sibling config file. Both reviewers
/// of the banner plan reached that conclusion independently, for the same
/// reason: the guard test's value is that a single canonical registry makes
/// ADDING an AdMob input a visible, deliberate diff. Two config files would
/// replace one strong invariant with two weaker per-file ones, and the app id
/// is SDK-wide anyway — it is not the report placement's property.
///
/// The App IDs additionally have to reach the native layer (iOS `Info.plist`
/// `GADApplicationIdentifier`, Android manifest `…ads.APPLICATION_ID`), so a
/// release build must supply each App ID to BOTH the native build setting and
/// the matching dart-define. Dart owns the *eligibility* decision; the native
/// value is what the SDK reads. See docs/FINAL_RELEASE_READINESS.md.
///
/// Safety model:
///  * DEBUG / PROFILE — Google's official TEST identifiers, always. Development
///    and QA never touch a production unit, and R6's physical verification runs
///    entirely on these.
///  * RELEASE — production identifiers must be supplied explicitly and must be
///    well-formed. Anything missing or malformed ⇒ **ads unavailable**, which
///    the coordinator treats as "no ad → the report still generates"
///    (fail-open). A shipping release NEVER silently falls back to the TEST
///    identifiers.
class AdMobBuildConfig {
  AdMobBuildConfig._();

  /// Google's public TEST publisher. Every identifier below that begins with
  /// this prefix is a documented Google sample value and can never serve a real
  /// (billable) ad — which is why they are safe to hardcode.
  static const String googleTestPublisher = 'ca-app-pub-3940256099942544';

  // Google's official sample/TEST identifiers.
  static const String testAppIdIos = '$googleTestPublisher~1458002511';
  static const String testAppIdAndroid = '$googleTestPublisher~3347511713';
  static const String testInterstitialIos = '$googleTestPublisher/4411468910';
  static const String testInterstitialAndroid =
      '$googleTestPublisher/1033173712';
  static const String testBannerIos = '$googleTestPublisher/2934735716';
  static const String testBannerAndroid = '$googleTestPublisher/6300978111';

  // Production identifiers — supplied ONLY at build time, absent by default.
  static const String _prodAppIdIos = String.fromEnvironment('ADMOB_APP_ID_IOS');
  static const String _prodAppIdAndroid =
      String.fromEnvironment('ADMOB_APP_ID_ANDROID');
  static const String _prodInterstitialIos =
      String.fromEnvironment('ADMOB_INTERSTITIAL_IOS');
  static const String _prodInterstitialAndroid =
      String.fromEnvironment('ADMOB_INTERSTITIAL_ANDROID');
  static const String _prodBannerIos = String.fromEnvironment('ADMOB_BANNER_IOS');
  static const String _prodBannerAndroid =
      String.fromEnvironment('ADMOB_BANNER_ANDROID');

  // Shape validation (§15). App IDs use `~`, ad units use `/` — mixing the two
  // up is the classic AdMob misconfiguration, and it must degrade to "no ads"
  // rather than reach the SDK.
  //
  // Audit H-7: these mirror the shape the native SDK itself enforces —
  // `^ca-app-pub-[0-9]{16}~[0-9]{10}$`, verified by disassembling
  // `zzev#attachInfo` in play-services-ads-api:25.3.0, which throws
  // IllegalStateException at PROCESS START on a mismatch. Keeping the Dart gate
  // looser than the SDK's would let a value pass here and still crash at launch.
  static final RegExp _appIdShape = RegExp(r'^ca-app-pub-[0-9]{16}~[0-9]{10}$');
  static final RegExp _unitIdShape =
      RegExp(r'^ca-app-pub-[0-9]{16}/[0-9]{10}$');

  /// Whether [value] is a well-formed AdMob **application** id (`…~…`).
  static bool isValidAppId(String value) => _appIdShape.hasMatch(value);

  /// Whether [value] is a well-formed AdMob **ad unit** id (`…/…`).
  static bool isValidUnitId(String value) => _unitIdShape.hasMatch(value);

  /// Pure resolution, exposed so release semantics are testable without
  /// producing a release build. Returns null when the value is absent or
  /// malformed — the caller treats null as "not configured".
  ///
  /// NOT `@visibleForTesting` any more: every format's unit resolver in this
  /// class routes through it, so the annotation would now be false — and the
  /// analyzer would reject the banner resolver above.
  static String? resolve({
    required bool isTestBuild,
    required String testValue,
    required String prodValue,
    required bool Function(String) isValid,
  }) {
    if (isTestBuild) return testValue;
    final trimmed = prodValue.trim();
    if (trimmed.isEmpty || !isValid(trimmed)) return null;
    // A shipping release must never resolve to Google's TEST publisher: that
    // would mean a production artifact quietly running on sample identifiers.
    if (trimmed.startsWith(googleTestPublisher)) return null;
    return trimmed;
  }

  /// The AdMob **application** id for [platform], or null when unavailable.
  static String? appId(TargetPlatform platform) {
    final isIos = platform == TargetPlatform.iOS;
    return resolve(
      isTestBuild: isTestMode,
      testValue: isIos ? testAppIdIos : testAppIdAndroid,
      prodValue: isIos ? _prodAppIdIos : _prodAppIdAndroid,
      isValid: isValidAppId,
    );
  }

  /// The interstitial **ad unit** id for [platform], or null when unavailable.
  static String? interstitialUnitId(TargetPlatform platform) {
    final isIos = platform == TargetPlatform.iOS;
    return resolve(
      isTestBuild: isTestMode,
      testValue: isIos ? testInterstitialIos : testInterstitialAndroid,
      prodValue: isIos ? _prodInterstitialIos : _prodInterstitialAndroid,
      isValid: isValidUnitId,
    );
  }

  /// The banner **ad unit** id for [platform], or null when unavailable.
  ///
  /// One unit serves every banner placement in V1 because V1 ships exactly one
  /// placement. A second placement should get its own unit — per-placement
  /// units are how AdMob reporting tells you which placement is actually worth
  /// keeping, and a shared unit makes that question unanswerable.
  static String? bannerUnitId(TargetPlatform platform) {
    final isIos = platform == TargetPlatform.iOS;
    return resolve(
      isTestBuild: isTestMode,
      testValue: isIos ? testBannerIos : testBannerAndroid,
      prodValue: isIos ? _prodBannerIos : _prodBannerAndroid,
      isValid: isValidUnitId,
    );
  }

  /// Whether this build can serve a BANNER on [platform]. Both halves are
  /// required, for the same reason as [isConfiguredFor]: a unit id without an
  /// application id has the SDK initialise against whatever the native layer
  /// carries.
  static bool isBannerConfiguredFor(TargetPlatform platform) =>
      adsCompiledIn &&
      appId(platform) != null &&
      bannerUnitId(platform) != null;

  /// Decision 3.2 (Version 1 has no advertising): ads are compiled OUT of a
  /// build unless it is built with `--dart-define=QIRSH_ADS_ENABLED=true`.
  /// A compile-time constant, so no remote feature flag can turn advertising
  /// back on in a build made without it. When false, nothing initialises the
  /// Mobile Ads SDK, nothing calls UMP, and no banner or interstitial is
  /// loaded ([MobileAdsInitializer.mayServe], `UmpAdConsentService`).
  static const bool _adsBuildEnabled =
      bool.fromEnvironment('QIRSH_ADS_ENABLED');

  /// Test-only switch for the existing ad tests, which exercise the ad
  /// pipeline itself. Ignored in release builds (`kReleaseMode` is a
  /// compile-time constant), so it cannot enable ads in a shipped binary.
  @visibleForTesting
  static bool debugAdsCompiledInOverride = false;

  /// Whether this build may run advertising at all. See [_adsBuildEnabled].
  static bool get adsCompiledIn =>
      _adsBuildEnabled || (!kReleaseMode && debugAdsCompiledInOverride);

  /// Whether this build has a COMPLETE, usable AdMob configuration for
  /// [platform]. Both halves are required: an ad unit without a matching
  /// application id would have the SDK initialise against whatever the native
  /// layer happens to carry (in a release with no injected value, the placeholder
  /// fallback), which is exactly the silent test-identifier shipping this guards
  /// against. Incomplete ⇒ no ad opportunity ⇒ the report still generates.
  static bool isConfiguredFor(TargetPlatform platform) =>
      adsCompiledIn &&
      appId(platform) != null &&
      interstitialUnitId(platform) != null;

  /// True in dev/QA builds where the TEST identifiers are in force. Surfaced so
  /// callers and tests can assert that development never touches production.
  static bool get isTestMode => kDebugMode || kProfileMode;

  /// True when this build carries a genuine production AdMob configuration
  /// (used by the release guard and by diagnostics; never by ad logic).
  static bool get isProductionConfigured =>
      !isTestMode &&
      (appId(TargetPlatform.iOS) != null ||
          appId(TargetPlatform.android) != null);
}
