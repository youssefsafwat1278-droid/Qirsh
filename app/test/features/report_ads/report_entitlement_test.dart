import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/referrals/referral_models.dart';
import 'package:money_companion/features/referrals/services/referral_service.dart';
import 'package:money_companion/features/ads/admob_build_config.dart';
import 'package:money_companion/features/report_ads/report_entitlement.dart';

class _FakeService implements ReferralService {
  _FakeService();
  EntitlementDecision? decision;
  Object? error;
  int calls = 0;

  @override
  Future<EntitlementDecision?> getEntitlementDecision() async {
    calls++;
    if (error != null) throw error!;
    return decision;
  }

  @override
  Future<ReferralSummary?> getSummary() async => null;
  @override
  Future<ApplyCodeOutcome> applyCode(String code) async => const ApplyCodeOutcome(ok: false);
  @override
  Future<QualificationOutcome> requestQualification() async =>
      const QualificationOutcome(qualified: false, granted: false);
}

EntitlementDecision _dec({required bool active}) => EntitlementDecision(
      entitlementType: 'report_export_ad_free',
      status: active ? 'active' : 'none',
      active: active,
      endsAt: active ? DateTime.utc(2026, 9, 1) : null,
      serverNow: DateTime.utc(2026, 8, 17),
    );

void main() {
  // Decision 3.2: advertising is compiled out of Version 1 builds. These tests
  // exercise the ad pipeline itself, as a build made with
  // --dart-define=QIRSH_ADS_ENABLED=true runs it. The compiled-out behaviour
  // is covered by test/features/ads/v1_ads_compiled_out_test.dart.
  setUp(() => AdMobBuildConfig.debugAdsCompiledInOverride = true);
  tearDown(() => AdMobBuildConfig.debugAdsCompiledInOverride = false);
  group('three-state resolution', () {
    test('active decision → verifiedActive', () async {
      final svc = _FakeService()..decision = _dec(active: true);
      final r = ReportEntitlementResolver(service: svc, currentUserId: () => 'u1');
      expect(await r.resolve(), ReportEntitlementState.verifiedActive);
    });

    test('inactive decision → verifiedInactive', () async {
      final svc = _FakeService()..decision = _dec(active: false);
      final r = ReportEntitlementResolver(service: svc, currentUserId: () => 'u1');
      expect(await r.resolve(), ReportEntitlementState.verifiedInactive);
    });

    test('thrown lookup → unknownOrStale (never "inactive")', () async {
      final svc = _FakeService()..error = Exception('unreachable');
      final r = ReportEntitlementResolver(service: svc, currentUserId: () => 'u1');
      expect(await r.resolve(), ReportEntitlementState.unknownOrStale);
    });

    test('null decision (unconfigured) → unknownOrStale', () async {
      final svc = _FakeService()..decision = null;
      final r = ReportEntitlementResolver(service: svc, currentUserId: () => 'u1');
      expect(await r.resolve(), ReportEntitlementState.unknownOrStale);
    });

    test('signed-out (no user id) → unknownOrStale, no network call', () async {
      final svc = _FakeService()..decision = _dec(active: false);
      final r = ReportEntitlementResolver(service: svc, currentUserId: () => null);
      expect(await r.resolve(), ReportEntitlementState.unknownOrStale);
      expect(svc.calls, 0);
    });
  });

  group('cache + TTL', () {
    test('fresh cache is reused without a second network call', () async {
      final svc = _FakeService()..decision = _dec(active: false);
      final r = ReportEntitlementResolver(service: svc, currentUserId: () => 'u1');
      await r.resolve();
      await r.resolve();
      expect(svc.calls, 1); // second resolve served from cache
    });

    test('M: a STALE (TTL-expired) VERIFIED_INACTIVE + failing refresh → UNKNOWN', () async {
      var now = 0;
      final svc = _FakeService()..decision = _dec(active: false);
      final r = ReportEntitlementResolver(
        service: svc,
        currentUserId: () => 'u1',
        ttl: const Duration(minutes: 5),
        nowMs: () => now,
      );
      expect(await r.resolve(), ReportEntitlementState.verifiedInactive);
      // Advance past the TTL and make the refresh fail.
      now = const Duration(minutes: 6).inMilliseconds;
      svc.error = Exception('timeout');
      // A stale inactive is NOT returned as fresh; the failed refetch → UNKNOWN.
      expect(await r.resolve(), ReportEntitlementState.unknownOrStale);
    });
  });

  group('account keying (§7)', () {
    test('L: a different user id never reuses the previous entry', () async {
      var uid = 'u1';
      final svc = _FakeService()..decision = _dec(active: true); // u1 active
      final r = ReportEntitlementResolver(service: svc, currentUserId: () => uid);
      expect(await r.resolve(), ReportEntitlementState.verifiedActive);

      // Account switch: u2 is inactive — the u1 "active" entry must NOT leak.
      uid = 'u2';
      svc.decision = _dec(active: false);
      expect(await r.resolve(), ReportEntitlementState.verifiedInactive);
      expect(svc.calls, 2); // a fresh lookup happened for u2
    });

    test('L: clear() drops the cache (logout)', () async {
      final svc = _FakeService()..decision = _dec(active: false);
      final r = ReportEntitlementResolver(service: svc, currentUserId: () => 'u1');
      await r.resolve();
      r.clear();
      await r.resolve();
      expect(svc.calls, 2); // cache cleared → refetched
    });
  });

  group('build-time config (§16/§17)', () {
    test('dev/test uses Google TEST units and is configured', () {
      expect(AdMobBuildConfig.isTestMode, isTrue); // kDebugMode in tests
      expect(AdMobBuildConfig.isConfiguredFor(TargetPlatform.iOS), isTrue);
      expect(AdMobBuildConfig.isConfiguredFor(TargetPlatform.android), isTrue);
      expect(
        AdMobBuildConfig.interstitialUnitId(TargetPlatform.iOS),
        AdMobBuildConfig.testInterstitialIos,
      );
      expect(
        AdMobBuildConfig.interstitialUnitId(TargetPlatform.android),
        AdMobBuildConfig.testInterstitialAndroid,
      );
    });

    test('the test units belong to Google\'s test publisher (never a real unit)', () {
      expect(AdMobBuildConfig.testInterstitialIos, contains('3940256099942544'));
      expect(AdMobBuildConfig.testInterstitialAndroid, contains('3940256099942544'));
    });
  });
}
