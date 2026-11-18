import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/ads/admob_build_config.dart';
import 'package:money_companion/core/backend/metrics_client.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ad_controller.dart';
import 'package:money_companion/features/ads/banner_ads_analytics.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/ads/qirsh_ad_banner.dart';
import 'package:money_companion/features/referrals/referral_models.dart';
import 'package:money_companion/features/referrals/services/referral_service.dart';
import 'package:money_companion/features/report_ads/ad_consent_service.dart';
import 'package:money_companion/features/report_ads/report_ads_providers.dart';
import 'package:money_companion/features/report_ads/report_entitlement.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// ENTITLEMENT AND CONSENT — the two gates that decide whether anyone may be
/// asked for an ad at all.
///
/// ## What is real here
///
/// The REAL `ReportEntitlementResolver` runs, over a fake `ReferralService` —
/// so its own logic (signed-out handling, the null-decision case, the failure
/// path, the TTL cache) is under test rather than stubbed past. The real
/// `bannerEligibilityProvider` composes the gates, and the real `QirshAdBanner`
/// drives the real `BannerAdController`.
///
/// Earlier device work overrode `bannerEntitlementProvider` wholesale, which
/// bypassed every one of those. This does not.
///
/// The FLAG gate is forced open, because `featureFlags` is a runtime singleton
/// that throws before catalog sync and would refuse everything for a reason
/// that has nothing to do with these two gates. It has its own coverage.
///
/// ## Requests, not widgets
///
/// Every assertion is on the number of ad REQUESTS. A banner that is invisible
/// but asked is a policy failure that no screenshot would show, so "did a
/// widget appear" is never the measure here.

final _silentAnalytics = BannerAdsAnalytics(
  cloudProcessingEnabled: () async => false,
  metrics: MetricsClient(),
);

class _CountingLoader implements BannerAdLoader {
  static int requests = 0;
  static int disposals = 0;
  static void reset() {
    requests = 0;
    disposals = 0;
  }

  @override
  Object? get loadedAd => null;

  @override
  Future<int?> resolveHeight(int widthPx) async => 60;

  @override
  Future<bool> load({
    required String adUnitId,
    required int widthPx,
    required int heightPx,
    VoidCallback? onImpression,
  }) async {
    requests++;
    return false;
  }

  @override
  void dispose() => disposals++;
}

/// The entitlement service, with every answer the real one can give.
class _Referral implements ReferralService {
  _Referral({this.active = false, this.decisionIsNull = false, this.error});

  bool active;
  bool decisionIsNull;
  Object? error;
  Completer<void>? hold;

  @override
  Future<EntitlementDecision?> getEntitlementDecision() async {
    if (hold != null) await hold!.future;
    if (error != null) throw error!;
    if (decisionIsNull) return null;
    return EntitlementDecision(
      entitlementType: 'report_export_ad_free',
      status: active ? 'active' : 'none',
      active: active,
      endsAt: active ? DateTime.utc(2027) : null,
      serverNow: DateTime.utc(2026, 9, 19),
    );
  }

  @override
  Future<ReferralSummary?> getSummary() async => null;
  @override
  Future<ApplyCodeOutcome> applyCode(String code) async =>
      const ApplyCodeOutcome(ok: false);
  @override
  Future<QualificationOutcome> requestQualification() async =>
      const QualificationOutcome(qualified: false, granted: false);
}

class _Consent implements AdConsentService {
  _Consent({this.can = true});
  bool can;
  Completer<void>? hold;

  @override
  Future<bool> canRequestAds() async {
    if (hold != null) await hold!.future;
    return can;
  }

  @override
  Future<void> gatherConsent() async {}
  @override
  Future<bool> isPrivacyOptionsRequired() async => false;
  @override
  Future<void> showPrivacyOptions() async {}
}

/// Mounts the real banner over the real gate chain.
Widget _app({
  required _Referral referral,
  required _Consent consent,
  String? userId = 'user-1',
}) {
  return ProviderScope(
    overrides: [
      // The flag gate only — see the header note.
      bannerPlacementEnabledProvider(AdPlacement.goals).overrideWithValue(true),
      // The REAL resolver, over a fake service.
      reportEntitlementResolverProvider.overrideWithValue(
        ReportEntitlementResolver(
          service: referral,
          currentUserId: () => userId,
        ),
      ),
      adConsentServiceProvider.overrideWithValue(consent),
      bannerAdLoaderFactoryProvider.overrideWithValue(_CountingLoader.new),
      bannerAdsAnalyticsProvider.overrideWithValue(_silentAnalytics),
    ],
    child: MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.dark,
      home: const Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: 400,
            child: QirshAdBanner(placement: AdPlacement.goals),
          ),
        ),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  // Decision 3.2: advertising is compiled out of Version 1 builds. These tests
  // exercise the ad pipeline itself, as a build made with
  // --dart-define=QIRSH_ADS_ENABLED=true runs it. The compiled-out behaviour
  // is covered by test/features/ads/v1_ads_compiled_out_test.dart.
  setUp(() => AdMobBuildConfig.debugAdsCompiledInOverride = true);
  tearDown(() => AdMobBuildConfig.debugAdsCompiledInOverride = false);
  setUp(() {
    _CountingLoader.reset();
    BannerAdController.resetThrottleForTest();
  });

  group('entitlement', () {
    testWidgets('an ELIGIBLE user reaches the request', (tester) async {
      await tester.pumpWidget(
          _app(referral: _Referral(active: false), consent: _Consent()));
      await _settle(tester);
      expect(_CountingLoader.requests, 1);
    });

    testWidgets('an AD-FREE user is never asked for an ad', (tester) async {
      await tester.pumpWidget(
          _app(referral: _Referral(active: true), consent: _Consent()));
      await _settle(tester);
      expect(_CountingLoader.requests, 0,
          reason: 'verifiedActive means the user paid not to see this');
    });

    testWidgets('a FAILED entitlement lookup fails closed', (tester) async {
      await tester.pumpWidget(_app(
        referral: _Referral(error: StateError('backend down')),
        consent: _Consent(),
      ));
      await _settle(tester);
      expect(_CountingLoader.requests, 0,
          reason: 'unknown is not inactive — uncertainty means no ad');
    });

    testWidgets('a NULL decision — unconfigured backend — fails closed',
        (tester) async {
      await tester.pumpWidget(_app(
        referral: _Referral(decisionIsNull: true),
        consent: _Consent(),
      ));
      await _settle(tester);
      expect(_CountingLoader.requests, 0);
    });

    testWidgets('a SIGNED-OUT user is never asked', (tester) async {
      await tester.pumpWidget(_app(
        referral: _Referral(active: false),
        consent: _Consent(),
        userId: null,
      ));
      await _settle(tester);
      expect(_CountingLoader.requests, 0,
          reason: 'no user id resolves to unknownOrStale');
    });

    testWidgets('NOTHING is requested while entitlement is still resolving',
        (tester) async {
      // The premature-request case: a slot must not ask during the window
      // where the answer is simply not known yet.
      final referral = _Referral(active: false)..hold = Completer<void>();
      await tester.pumpWidget(_app(referral: referral, consent: _Consent()));
      await _settle(tester);
      expect(_CountingLoader.requests, 0, reason: 'the answer is not in yet');

      referral.hold!.complete();
      await _settle(tester);
      expect(_CountingLoader.requests, 1);
    });
  });

  group('consent', () {
    testWidgets('consent granted reaches the request', (tester) async {
      await tester.pumpWidget(
          _app(referral: _Referral(), consent: _Consent(can: true)));
      await _settle(tester);
      expect(_CountingLoader.requests, 1);
    });

    testWidgets('consent withheld means zero requests', (tester) async {
      await tester.pumpWidget(
          _app(referral: _Referral(), consent: _Consent(can: false)));
      await _settle(tester);
      expect(_CountingLoader.requests, 0,
          reason: 'UMP is the sole authority and it said no');
    });

    testWidgets('NOTHING is requested while consent is still resolving',
        (tester) async {
      final consent = _Consent(can: true)..hold = Completer<void>();
      await tester.pumpWidget(_app(referral: _Referral(), consent: consent));
      await _settle(tester);
      expect(_CountingLoader.requests, 0);

      consent.hold!.complete();
      await _settle(tester);
      expect(_CountingLoader.requests, 1);
    });
  });

  group('changing mid-session', () {
    testWidgets('earning ad-free mid-session drops the ad already held',
        (tester) async {
      // The promise this gate exists to keep. A held AdWidget belonging to a
      // user who has since become ad-free is the worst outcome available here,
      // and it is invisible to anything that only counts requests.
      final referral = _Referral(active: false);
      await tester.pumpWidget(_app(referral: referral, consent: _Consent()));
      await _settle(tester);
      expect(_CountingLoader.requests, 1);
      expect(_CountingLoader.disposals, 0);

      referral.active = true;
      final container = ProviderScope.containerOf(
          tester.element(find.byType(QirshAdBanner)));
      // What a real sign-in / resume / entitlement refresh does.
      container.read(reportEntitlementResolverProvider).refresh();
      container.invalidate(bannerEntitlementProvider);
      await _settle(tester);
      await _settle(tester);

      expect(_CountingLoader.disposals, 1,
          reason: 'the ad must be dropped, not merely hidden');
      expect(_CountingLoader.requests, 1, reason: 'and nothing re-requested');
      expect(tester.getSize(find.byType(QirshAdBanner)).height, 0);
    });

    testWidgets('revoking consent mid-session drops the ad already held',
        (tester) async {
      final consent = _Consent(can: true);
      await tester.pumpWidget(_app(referral: _Referral(), consent: consent));
      await _settle(tester);
      expect(_CountingLoader.requests, 1);

      consent.can = false;
      final container = ProviderScope.containerOf(
          tester.element(find.byType(QirshAdBanner)));
      container.invalidate(bannerConsentProvider);
      await _settle(tester);
      await _settle(tester);

      expect(_CountingLoader.disposals, 1);
      expect(_CountingLoader.requests, 1);
      expect(tester.getSize(find.byType(QirshAdBanner)).height, 0);
    });

    testWidgets('an entitlement that becomes ELIGIBLE mid-session may then ask',
        (tester) async {
      // The other direction, so the gate is not simply stuck closed.
      final referral = _Referral(active: true);
      await tester.pumpWidget(_app(referral: referral, consent: _Consent()));
      await _settle(tester);
      expect(_CountingLoader.requests, 0);

      referral.active = false;
      final container = ProviderScope.containerOf(
          tester.element(find.byType(QirshAdBanner)));
      container.read(reportEntitlementResolverProvider).refresh();
      container.invalidate(bannerEntitlementProvider);
      BannerAdController.resetThrottleForTest();
      await _settle(tester);
      await _settle(tester);

      expect(_CountingLoader.requests, 1);
    });
  });
}
