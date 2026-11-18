import 'dart:async';

import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../core/privacy/cloud_egress_gate.dart';
import 'admob_build_config.dart';

/// One-time Google Mobile Ads SDK initialization, shared by every ad format.
///
/// This used to live as a private instance method with a private static latch
/// inside the report-export interstitial gateway. That was fine while there was
/// exactly one format; with a banner it becomes wrong twice over — the banner
/// cannot reach it, and two independent latches would let both formats race
/// `initialize()` on cold start.
///
/// Single-flight and bounded: concurrent callers await the same future, and a
/// hung platform channel resolves as "not initialized" rather than leaving every
/// future caller waiting forever. It is deliberately NOT a Riverpod provider —
/// the SDK's own state is process-global, so modelling it as anything else would
/// be a lie a test could not enforce.
class MobileAdsInitializer {
  MobileAdsInitializer._();

  static const Duration _timeout = Duration(seconds: 10);

  static bool _initialized = false;
  static Future<void>? _inFlight;

  /// True once the SDK's own initializer has completed successfully.
  /// (Deliberately not naming the call in prose: a guard test counts call
  /// sites by grepping for it, and a doc comment is not an exemption.)
  static bool get isInitialized => _initialized;

  /// Initialize once. Never throws: a failure leaves [isInitialized] false and
  /// callers simply get no ad, which every caller already treats as normal.
  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    // Astra H2.5: the Ads SDK is network egress to Google. No initialize (and
    // therefore no ad load) unless the egress gate permits: resolved, a durable
    // ON record, no freeze. The callers already treat "not initialized" as "no
    // ad", which is the product behaviour while Cloud is OFF.
    if (!await mayServe()) return;
    return _inFlight ??= _run();
  }

  /// Whether ad/UMP network may run right now. Every ad entry point asks this.
  static Future<bool> mayServe() async {
    // Decision 3.2: a build without ads compiled in never reaches the SDK or
    // UMP, whatever the remote flags say.
    if (!AdMobBuildConfig.adsCompiledIn) return false;
    try {
      return await CloudEgressGate.instance.permits();
    } catch (_) {
      return false;
    }
  }

  static Future<void> _run() async {
    try {
      await MobileAds.instance.initialize().timeout(_timeout);
      _initialized = true;
    } catch (_) {
      // Left false on purpose. A retry is allowed on the next opportunity
      // because `_inFlight` is cleared below — but nothing retries in a loop,
      // since every caller is driven by a user-visible ad opportunity.
    } finally {
      _inFlight = null;
    }
  }

  /// Test-only reset. The SDK latch is process-global, so a test that asserts
  /// first-call behaviour has to be able to put it back.
  static void resetForTest() {
    _initialized = false;
    _inFlight = null;
  }
}
