import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:google_mobile_ads/src/ad_instance_manager.dart'
    show instanceManager;
// ignore: implementation_imports
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:money_companion/core/backend/metrics_client.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/admob_build_config.dart';
import 'package:money_companion/features/ads/banner_ads_analytics.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/ads/mobile_ads_initializer.dart';
import 'package:money_companion/features/ads/qirsh_ad_banner.dart';
import 'package:money_companion/features/referrals/referral_models.dart';
import 'package:money_companion/features/referrals/services/referral_service.dart';
import 'package:money_companion/features/report_ads/ad_consent_service.dart';
import 'package:money_companion/features/report_ads/report_ads_analytics.dart';
import 'package:money_companion/features/report_ads/report_ads_providers.dart';
import 'package:money_companion/features/report_ads/report_entitlement.dart';
import 'package:money_companion/features/report_ads/report_export_ad_gateway.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// Decision 3.2 — Version 1 has no advertising, and a remote flag must not
/// reactivate it. Production has all eight ad flags ON, so every flag is
/// forced ON here, Cloud/egress is permitted (the test default), the user is
/// an eligible non-ad-free user — and still nothing may reach the Mobile Ads
/// SDK or UMP: no initialise, no banner, no interstitial, no consent form.
///
/// This is a build without `--dart-define=QIRSH_ADS_ENABLED=true` (the V1
/// build). The control group switches the test-only override on to prove the
/// same harness DOES see SDK traffic when ads are compiled in, so the
/// "nothing happened" assertions are not vacuous.

final _umpChannel = MethodChannel('plugins.flutter.io/google_mobile_ads/ump',
    StandardMethodCodec(UserMessagingCodec()));

/// Every advertising flag that is ON in production (production-comparison
/// §4.3): the banner master, the six placements and the report interstitial.
const _productionAdFlags = [
  'enable_banner_ads',
  'enable_banner_dashboard',
  'enable_banner_transactions_list',
  'enable_banner_reports',
  'enable_banner_goals',
  'enable_banner_subscriptions',
  'enable_banner_achievements',
  'enable_report_ads',
];

class _Referral implements ReferralService {
  int lookups = 0;
  @override
  Future<EntitlementDecision?> getEntitlementDecision() async {
    lookups++;
    return EntitlementDecision(
      entitlementType: 'report_export_ad_free',
      status: 'none',
      active: false,
      endsAt: null,
      serverNow: DateTime.utc(2026, 11, 17),
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

List<Override> _allFlagsOn(_Referral referral) => [
      bannerAdsEnabledProvider.overrideWithValue(true),
      for (final p in AdPlacement.values)
        bannerPlacementEnabledProvider(p).overrideWithValue(true),
      reportAdsEnabledProvider.overrideWithValue(true),
      reportEntitlementResolverProvider.overrideWithValue(
        ReportEntitlementResolver(
          service: referral,
          currentUserId: () => 'user-1',
        ),
      ),
      bannerAdsAnalyticsProvider.overrideWithValue(BannerAdsAnalytics(
        cloudProcessingEnabled: () async => false,
        metrics: MetricsClient(),
      )),
      reportAdsAnalyticsProvider.overrideWithValue(ReportAdsAnalytics(
        cloudProcessingEnabled: () async => false,
        metrics: MetricsClient(),
      )),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> sdkCalls;

  setUp(() {
    sdkCalls = [];
    AdMobBuildConfig.debugAdsCompiledInOverride = false;
    MobileAdsInitializer.resetForTest();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(instanceManager.channel, (call) async {
      sdkCalls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(_umpChannel, (call) async {
      sdkCalls.add(call.method);
      return true;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(instanceManager.channel, null);
    messenger.setMockMethodCallHandler(_umpChannel, null);
    AdMobBuildConfig.debugAdsCompiledInOverride = false;
    MobileAdsInitializer.resetForTest();
  });

  test('the eight production ad flags are the ones this test forces ON', () {
    expect(
      {
        'enable_banner_ads',
        'enable_report_ads',
        for (final p in AdPlacement.values) p.flagKey,
      },
      _productionAdFlags.toSet(),
    );
  });

  group('V1 build (QIRSH_ADS_ENABLED not set), every ad flag ON', () {
    test('ads are not compiled in and no ad configuration resolves', () {
      expect(AdMobBuildConfig.adsCompiledIn, isFalse);
      expect(AdMobBuildConfig.isConfiguredFor(TargetPlatform.iOS), isFalse);
      expect(
          AdMobBuildConfig.isBannerConfiguredFor(TargetPlatform.iOS), isFalse);
      expect(
          AdMobBuildConfig.isConfiguredFor(TargetPlatform.android), isFalse);
    });

    test('no SDK initialise and no UMP request or form', () async {
      await MobileAdsInitializer.ensureInitialized();
      expect(MobileAdsInitializer.isInitialized, isFalse);
      expect(await MobileAdsInitializer.mayServe(), isFalse);

      const ump = UmpAdConsentService();
      await SessionAdConsent(ump).ensureGathered();
      await ump.gatherConsent();
      expect(await ump.canRequestAds(), isFalse);
      expect(await ump.isPrivacyOptionsRequired(), isFalse);
      await ump.showPrivacyOptions();

      expect(sdkCalls, isEmpty);
    });

    test('no interstitial: preload and export reach neither SDK nor lookup',
        () async {
      final referral = _Referral();
      final container = ProviderContainer(overrides: _allFlagsOn(referral));
      addTearDown(container.dispose);

      final gateway = AdMobReportExportAdGateway();
      addTearDown(gateway.dispose);
      await gateway.preload();
      expect(gateway.isAvailable, isFalse);

      final coordinator = container.read(reportExportCoordinatorProvider);
      await coordinator.maybePreload();
      var generated = 0;
      var noticeShown = 0;
      await coordinator.run(
        () async => generated++,
        confirmAdNotice: () async {
          noticeShown++;
          return true;
        },
      );

      expect(generated, 1, reason: 'the report itself still generates');
      expect(noticeShown, 0, reason: 'no ad notice without an ad');
      expect(referral.lookups, 0,
          reason: 'not even the ad-free entitlement is looked up');
      expect(sdkCalls, isEmpty);
    });

    testWidgets('no banner on any placement', (tester) async {
      final referral = _Referral();
      await tester.pumpWidget(ProviderScope(
        overrides: _allFlagsOn(referral),
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: const [
            ...AppL10n.localizationsDelegates,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(children: [
                for (final p in AdPlacement.values)
                  SizedBox(width: 400, child: QirshAdBanner(placement: p)),
              ]),
            ),
          ),
        ),
      ));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      final container = ProviderScope.containerOf(
          tester.element(find.byType(Scaffold)));
      for (final p in AdPlacement.values) {
        expect(await container.read(bannerEligibilityProvider(p).future),
            isFalse,
            reason: '${p.key} must not be eligible');
      }
      expect(referral.lookups, 0);
      expect(sdkCalls, isEmpty);
    });
  });

  group('control: the same harness sees SDK traffic when ads are compiled in',
      () {
    test('initialise and UMP are reached', () async {
      AdMobBuildConfig.debugAdsCompiledInOverride = true;
      await MobileAdsInitializer.ensureInitialized();
      await const UmpAdConsentService().canRequestAds();
      expect(sdkCalls, contains('MobileAds#initialize'));
      expect(sdkCalls, contains('ConsentInformation#canRequestAds'));
    });
  });
}
