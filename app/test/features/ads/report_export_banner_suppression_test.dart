import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/ads/admob_build_config.dart';
import 'package:money_companion/core/backend/metrics_client.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/ads/report_banner_suppression.dart';
import 'package:money_companion/features/referrals/referral_models.dart';
import 'package:money_companion/features/referrals/services/referral_service.dart';
import 'package:money_companion/features/report_ads/ad_consent_service.dart';
import 'package:money_companion/features/report_ads/report_ads_analytics.dart';
import 'package:money_companion/features/report_ads/report_entitlement.dart';
import 'package:money_companion/features/report_ads/report_export_ad_gateway.dart';
import 'package:money_companion/features/report_ads/report_export_coordinator.dart';

/// THE REPORTS BANNER MUST NOT SERVE DURING AN EXPORT AD JOURNEY.
///
/// The route gate covers the configuration page and the ad notice, because both
/// are Flutter routes. It covers nothing between them and nothing during the
/// interstitial — a native full-screen ad pushes no route at all, so
/// `ModalRoute.isCurrent` stays true and `ModalRouteObserver` never sees it.
///
/// Each test here holds the coordinator inside one of those windows and asks
/// the real eligibility gate whether the banner may serve. Every one of them
/// FAILS without `ReportBannerSuppression.beginJourney()`, because before it
/// the answer was yes.

class _FakeReferral implements ReferralService {
  @override
  Future<EntitlementDecision?> getEntitlementDecision() async =>
      EntitlementDecision(
        entitlementType: 'report_export_ad_free',
        status: 'none',
        active: false,
        endsAt: null,
        serverNow: DateTime.utc(2026, 9, 19),
      );
  @override
  Future<ReferralSummary?> getSummary() async => null;
  @override
  Future<ApplyCodeOutcome> applyCode(String code) async =>
      const ApplyCodeOutcome(ok: false);
  @override
  Future<QualificationOutcome> requestQualification() async =>
      const QualificationOutcome(qualified: false, granted: false);
}

class _FakeConsent implements AdConsentService {
  @override
  Future<bool> canRequestAds() async => true;
  @override
  Future<void> gatherConsent() async {}
  @override
  Future<bool> isPrivacyOptionsRequired() async => false;
  @override
  Future<void> showPrivacyOptions() async {}
}

/// A gateway whose stages can be held open, so a test can stand inside each
/// window rather than race it.
class _HoldingGateway implements ReportExportAdGateway {
  _HoldingGateway({this.holdPreload, this.holdShow});

  final Completer<void>? holdPreload;
  final Completer<void>? holdShow;
  bool _available = false;

  @override
  bool get isAvailable => _available;

  @override
  Future<void> preload() async {
    if (holdPreload != null) await holdPreload!.future;
    _available = true;
  }

  @override
  Future<ReportAdOutcome> showIfAvailable() async {
    if (holdShow != null) await holdShow!.future;
    _available = false;
    return ReportAdOutcome.dismissed;
  }

  @override
  void dispose() {}
}

ReportExportCoordinator _coordinator(ReportExportAdGateway gateway) {
  return ReportExportCoordinator(
    reportAdsEnabled: () => true,
    adConfigAvailable: () => true,
    entitlement: ReportEntitlementResolver(
      service: _FakeReferral(),
      currentUserId: () => 'user-1',
    ),
    consent: _FakeConsent(),
    gateway: gateway,
    analytics: ReportAdsAnalytics(
      cloudProcessingEnabled: () async => false,
      metrics: MetricsClient(),
    ),
  );
}

/// The real eligibility gate, with only its external inputs stubbed. The flag
/// gate and the suppression check are the shipping ones — overriding
/// `bannerEligibilityProvider` itself would bypass exactly what is under test.
Future<bool?> _mayServe(AdPlacement placement) async {
  final container = ProviderContainer(overrides: [
    bannerPlacementEnabledProvider(placement).overrideWithValue(true),
    bannerEntitlementProvider
        .overrideWith((ref) async => ReportEntitlementState.verifiedInactive),
    bannerConsentProvider.overrideWith((ref) async => true),
  ]);
  addTearDown(container.dispose);
  return container.read(bannerEligibilityProvider(placement).future);
}

void main() {
  // Decision 3.2: advertising is compiled out of Version 1 builds. These tests
  // exercise the ad pipeline itself, as a build made with
  // --dart-define=QIRSH_ADS_ENABLED=true runs it. The compiled-out behaviour
  // is covered by test/features/ads/v1_ads_compiled_out_test.dart.
  setUp(() => AdMobBuildConfig.debugAdsCompiledInOverride = true);
  tearDown(() => AdMobBuildConfig.debugAdsCompiledInOverride = false);
  setUp(ReportBannerSuppression.resetForTest);

  test('baseline: with no journey running, Reports may serve', () async {
    expect(await _mayServe(AdPlacement.reports), isTrue);
  });

  test('NO banner while the coordinator is preparing the ad', () async {
    // Entitlement resolved, consent granted, preload in flight. No Flutter
    // route is on screen in this window — the configuration page has already
    // popped — so nothing else suppresses the banner here.
    final hold = Completer<void>();
    final gateway = _HoldingGateway(holdPreload: hold);
    final run = _coordinator(gateway).run(() async {});
    await Future<void>.delayed(Duration.zero);

    expect(await _mayServe(AdPlacement.reports), isFalse,
        reason: 'the export ad journey is in flight');

    hold.complete();
    await run;
  });

  test('NO banner while the interstitial is being presented', () async {
    // THE window the route gate cannot see: a native interstitial pushes no
    // Flutter route, so `ModalRoute.isCurrent` is true and `modalRouteOpen` is
    // false for its entire lifetime.
    final hold = Completer<void>();
    final gateway = _HoldingGateway(holdShow: hold);
    final run = _coordinator(gateway).run(() async {});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(await _mayServe(AdPlacement.reports), isFalse,
        reason: 'an interstitial is on screen and nothing else knows');

    hold.complete();
    await run;
  });

  test('NO banner while the report is generating', () async {
    // The ad is gone by now, but the user is still inside the flow they
    // started. Suppressing to the end of generation costs one impression and
    // avoids an ad appearing under a progress indicator.
    final hold = Completer<void>();
    final gateway = _HoldingGateway();
    final run = _coordinator(gateway).run(() async => hold.future);
    await Future<void>.delayed(Duration.zero);

    expect(await _mayServe(AdPlacement.reports), isFalse);

    hold.complete();
    await run;
  });

  test('the banner returns once the journey ends — after the cooldown',
      () async {
    // A real window, just a short one: the expiry is delivered by a timer, so
    // it has to be crossed rather than simulated.
    ReportBannerSuppression.cooldown = const Duration(milliseconds: 80);
    final gateway = _HoldingGateway();
    await _coordinator(gateway).run(() async {});

    // The journey is over, but an ad was shown, so the cooldown holds.
    expect(ReportBannerSuppression.journeyActive, isFalse);
    expect(await _mayServe(AdPlacement.reports), isFalse,
        reason: 'the post-interstitial cooldown');

    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(await _mayServe(AdPlacement.reports), isTrue);
  });

  test('a journey that throws still releases the suppression', () async {
    // A journey left open is a banner that never comes back. The pairing is in
    // a `finally` for this reason, and this is what proves it.
    final gateway = _HoldingGateway();
    await expectLater(
      _coordinator(gateway).run(() async => throw StateError('boom')),
      throwsStateError,
    );
    expect(ReportBannerSuppression.journeyActive, isFalse);
  });

  test('suppression never leaks to another placement', () async {
    final hold = Completer<void>();
    final run = _coordinator(_HoldingGateway(holdShow: hold)).run(() async {});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(await _mayServe(AdPlacement.reports), isFalse);
    expect(await _mayServe(AdPlacement.goals), isTrue,
        reason: 'Reports is the only surface with two formats');

    hold.complete();
    await run;
  });
}
