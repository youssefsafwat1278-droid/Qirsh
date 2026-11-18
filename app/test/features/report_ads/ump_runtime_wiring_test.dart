import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/ads/admob_build_config.dart';
import 'package:money_companion/features/report_ads/ad_consent_service.dart';
import 'package:money_companion/features/report_ads/report_ads_analytics.dart';
import 'package:money_companion/features/report_ads/report_ads_debug_config.dart';
import 'package:money_companion/features/report_ads/report_ads_providers.dart';
import 'package:money_companion/features/report_ads/report_entitlement.dart';
import 'package:money_companion/features/report_ads/report_export_ad_gateway.dart';
import 'package:money_companion/features/report_ads/report_export_coordinator.dart';
import 'package:money_companion/features/referrals/referral_models.dart';
import 'package:money_companion/features/referrals/services/referral_service.dart';
import 'package:money_companion/core/backend/metrics_client.dart';

// ── fakes ────────────────────────────────────────────────────────────────────

/// Counting UMP consent fake. `gatherDelay` lets a test hold the gather future
/// open to exercise concurrent de-duplication.
class _FakeConsent implements AdConsentService {
  _FakeConsent({
    this.can = true,
    this.privacyRequired = false,
    this.gatherThrows = false,
    Completer<void>? gatherGate,
  }) : _gatherGate = gatherGate;

  bool can;
  bool privacyRequired;
  bool gatherThrows;
  final Completer<void>? _gatherGate;

  int gatherCalls = 0;
  int showPrivacyCalls = 0;

  @override
  Future<void> gatherConsent() async {
    gatherCalls++;
    if (_gatherGate != null) await _gatherGate.future;
    if (gatherThrows) throw StateError('UMP down');
  }

  @override
  Future<bool> canRequestAds() async => can;

  @override
  Future<bool> isPrivacyOptionsRequired() async => privacyRequired;

  @override
  Future<void> showPrivacyOptions() async {
    showPrivacyCalls++;
  }
}

class _FakeGateway implements ReportExportAdGateway {
  int preloadCalls = 0;
  int showCalls = 0;
  bool available = false;

  @override
  bool get isAvailable => available;
  @override
  Future<void> preload() async {
    preloadCalls++;
  }

  @override
  Future<ReportAdOutcome> showIfAvailable() async {
    showCalls++;
    return ReportAdOutcome.unavailable;
  }

  @override
  void dispose() {}
}

class _FakeReferralService implements ReferralService {
  _FakeReferralService(this.decision);
  final EntitlementDecision decision;
  @override
  Future<EntitlementDecision?> getEntitlementDecision() async => decision;
  @override
  Future<ReferralSummary?> getSummary() async => null;
  @override
  Future<ApplyCodeOutcome> applyCode(String code) async =>
      const ApplyCodeOutcome(ok: false);
  @override
  Future<QualificationOutcome> requestQualification() async =>
      const QualificationOutcome(qualified: false, granted: false);
}

EntitlementDecision _inactive() => EntitlementDecision(
      entitlementType: 'report_export_ad_free',
      status: 'none',
      active: false,
      endsAt: null,
      serverNow: DateTime.utc(2026, 8, 20),
    );

ReportEntitlementResolver _inactiveResolver() => ReportEntitlementResolver(
      service: _FakeReferralService(_inactive()),
      currentUserId: () => 'user-1',
    );

ReportAdsAnalytics _analytics() => ReportAdsAnalytics(
      cloudProcessingEnabled: () async => false,
      metrics: MetricsClient(),
    );

void main() {
  // Decision 3.2: advertising is compiled out of Version 1 builds. These tests
  // exercise the ad pipeline itself, as a build made with
  // --dart-define=QIRSH_ADS_ENABLED=true runs it. The compiled-out behaviour
  // is covered by test/features/ads/v1_ads_compiled_out_test.dart.
  setUp(() => AdMobBuildConfig.debugAdsCompiledInOverride = true);
  tearDown(() => AdMobBuildConfig.debugAdsCompiledInOverride = false);
  // A — consent gathering happens exactly once per session, even under
  // concurrent + repeated calls, and is a no-op after completion.
  test('A: SessionAdConsent gathers once per session', () async {
    final gate = Completer<void>();
    final consent = _FakeConsent(gatherGate: gate);
    final session = SessionAdConsent(consent);

    // Three concurrent callers while the first gather is still in flight.
    final f1 = session.ensureGathered();
    final f2 = session.ensureGathered();
    final f3 = session.ensureGathered();
    // Astra H2.5: the egress check precedes the gather, so let it settle.
    await pumpEventQueue();
    expect(consent.gatherCalls, 1, reason: 'concurrent calls de-duplicated');

    gate.complete();
    await Future.wait([f1, f2, f3]);

    // A later call after completion is a pure no-op.
    await session.ensureGathered();
    expect(consent.gatherCalls, 1);
  });

  // C (part 1) — a UMP failure never propagates out of the orchestrator.
  test('C: gatherConsent failure is swallowed (fail-open latch)', () async {
    final consent = _FakeConsent(gatherThrows: true);
    final session = SessionAdConsent(consent);
    await session.ensureGathered(); // must not throw
    await session.ensureGathered(); // still latched → no second attempt
    expect(consent.gatherCalls, 1);
  });

  // B — the coordinator never preloads before UMP allows requests.
  test('B: no preload when canRequestAds is false', () async {
    final gw = _FakeGateway();
    final coord = ReportExportCoordinator(
      reportAdsEnabled: () => true,
      adConfigAvailable: () => true,
      entitlement: _inactiveResolver(),
      consent: _FakeConsent(can: false), // UMP forbids
      gateway: gw,
      analytics: _analytics(),
      mintAttemptId: () => 'a',
    );
    await coord.maybePreload();
    expect(gw.preloadCalls, 0);
  });

  // B (positive) — with UMP permitting + inactive entitlement, preload runs.
  test('B: preload runs once UMP permits requests', () async {
    final gw = _FakeGateway();
    final coord = ReportExportCoordinator(
      reportAdsEnabled: () => true,
      adConfigAvailable: () => true,
      entitlement: _inactiveResolver(),
      consent: _FakeConsent(can: true),
      gateway: gw,
      analytics: _analytics(),
      mintAttemptId: () => 'a',
    );
    await coord.maybePreload();
    expect(gw.preloadCalls, 1);
  });

  // C (part 2) — UMP unavailable ⇒ no ad shown, but the export still generates.
  test('C: UMP failure → export still generates (fail-open)', () async {
    final gw = _FakeGateway();
    var generated = 0;
    final coord = ReportExportCoordinator(
      reportAdsEnabled: () => true,
      adConfigAvailable: () => true,
      entitlement: _inactiveResolver(),
      consent: _FakeConsent(can: false),
      gateway: gw,
      analytics: _analytics(),
      mintAttemptId: () => 'a',
    );
    await coord.run(() async => generated++);
    expect(gw.showCalls, 0);
    expect(generated, 1);
  });

  // D — the privacy-options provider re-observes UMP after an invalidation.
  test('D: adPrivacyOptionsRequiredProvider refetches after invalidate',
      () async {
    final consent = _FakeConsent(privacyRequired: false);
    final container = ProviderContainer(overrides: [
      adConsentServiceProvider.overrideWithValue(consent),
    ]);
    addTearDown(container.dispose);

    expect(await container.read(adPrivacyOptionsRequiredProvider.future),
        isFalse);

    // Consent info refresh flips UMP to "required".
    consent.privacyRequired = true;
    container.invalidate(adPrivacyOptionsRequiredProvider);

    expect(await container.read(adPrivacyOptionsRequiredProvider.future),
        isTrue);
  });

  // H — debug geography is STRUCTURALLY impossible in a release build.
  group('H: debug geography cannot affect release', () {
    test('release build never forces EEA, for any define value', () {
      expect(
        ReportAdsDebugConfig.computeForceEea(
            isReleaseBuild: true, defineSet: true),
        isFalse,
      );
      expect(
        ReportAdsDebugConfig.computeForceEea(
            isReleaseBuild: true, defineSet: false),
        isFalse,
      );
    });

    test('non-release honours the define', () {
      expect(
        ReportAdsDebugConfig.computeForceEea(
            isReleaseBuild: false, defineSet: true),
        isTrue,
      );
      expect(
        ReportAdsDebugConfig.computeForceEea(
            isReleaseBuild: false, defineSet: false),
        isFalse,
      );
    });

    test('defaults are inert with no dart-defines', () {
      // No UMP_DEBUG_* defines in the test build → mechanism disabled.
      expect(ReportAdsDebugConfig.forceEeaGeography, isFalse);
      expect(ReportAdsDebugConfig.testDeviceIds, isEmpty);
    });
  });

  // R6 §2 — the report-ads placement QA override is equally release-inert and
  // strictly narrower than the real gate.
  group('R6: report-ads test override', () {
    test('release build never enables the override, for any define value', () {
      expect(
        ReportAdsDebugConfig.computeDebugOnly(
            isReleaseBuild: true, defineSet: true),
        isFalse,
      );
      expect(
        ReportAdsDebugConfig.computeDebugOnly(
            isReleaseBuild: true, defineSet: false),
        isFalse,
      );
    });

    test('non-release honours the define', () {
      expect(
        ReportAdsDebugConfig.computeDebugOnly(
            isReleaseBuild: false, defineSet: true),
        isTrue,
      );
      expect(
        ReportAdsDebugConfig.computeDebugOnly(
            isReleaseBuild: false, defineSet: false),
        isFalse,
      );
    });

    test('inert by default (no REPORT_ADS_TEST_OVERRIDE define in this build)',
        () {
      expect(ReportAdsDebugConfig.reportAdsPlacementTestOverride, isFalse);
    });

    // The override may replace ONLY the flag term: with the flag "on", every
    // other gate must still be able to veto the ad.
    test('override does NOT bypass UMP canRequestAds', () async {
      final gw = _FakeGateway();
      final coord = ReportExportCoordinator(
        reportAdsEnabled: () => true, // as if the override were active
        adConfigAvailable: () => true,
        entitlement: _inactiveResolver(),
        consent: _FakeConsent(can: false), // UMP still says no
        gateway: gw,
        analytics: _analytics(),
        mintAttemptId: () => 'ovr-1',
      );
      var generated = 0;
      await coord.run(() async => generated++);
      expect(gw.showCalls, 0, reason: 'UMP veto still wins');
      expect(generated, 1, reason: 'fail-open preserved');
    });

    test('override does NOT bypass an ACTIVE entitlement', () async {
      final gw = _FakeGateway();
      final active = ReportEntitlementResolver(
        service: _FakeReferralService(EntitlementDecision(
          entitlementType: 'report_export_ad_free',
          status: 'active',
          active: true,
          endsAt: DateTime.utc(2026, 12, 1),
          serverNow: DateTime.utc(2026, 8, 21),
        )),
        currentUserId: () => 'user-1',
      );
      final coord = ReportExportCoordinator(
        reportAdsEnabled: () => true, // as if the override were active
        adConfigAvailable: () => true,
        entitlement: active,
        consent: _FakeConsent(can: true),
        gateway: gw,
        analytics: _analytics(),
        mintAttemptId: () => 'ovr-2',
      );
      var generated = 0;
      await coord.run(() async => generated++);
      expect(gw.showCalls, 0, reason: 'ad-free entitlement still wins');
      expect(generated, 1);
    });
  });
}
