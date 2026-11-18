import 'package:flutter/material.dart' show Widget;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:google_mobile_ads/src/ad_instance_manager.dart'
    show instanceManager;
import 'package:money_companion/features/ads/admob_build_config.dart';
import 'package:money_companion/core/privacy/gated_url_launcher.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/ads/mobile_ads_initializer.dart';
import 'package:money_companion/features/report_ads/ad_consent_service.dart';
import 'package:money_companion/features/report_ads/report_ads_providers.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../harness/egress_test_support.dart';

/// Astra H2.5: google_mobile_ads and url_launcher while the egress gate does not
/// permit.
class _Launcher extends UrlLauncherPlatform with MockPlatformInterfaceMixin {
  final launched = <String>[];
  @override
  Widget Function(LinkInfo)? get linkDelegate => null;
  @override
  Future<bool> canLaunch(String url) async => true;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

class _CountingConsent implements AdConsentService {
  int gathers = 0;
  @override
  Future<void> gatherConsent() async => gathers++;
  @override
  Future<bool> canRequestAds() async => true;
  @override
  Future<bool> isPrivacyOptionsRequired() async => true;
  @override
  Future<void> showPrivacyOptions() async {}
}

void main() {
  // Decision 3.2: advertising is compiled out of Version 1 builds. These tests
  // exercise the ad pipeline itself, as a build made with
  // --dart-define=QIRSH_ADS_ENABLED=true runs it. The compiled-out behaviour
  // is covered by test/features/ads/v1_ads_compiled_out_test.dart.
  setUp(() => AdMobBuildConfig.debugAdsCompiledInOverride = true);
  tearDown(() => AdMobBuildConfig.debugAdsCompiledInOverride = false);
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> adCalls;

  setUp(() {
    adCalls = [];
    MobileAdsInitializer.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(instanceManager.channel, (call) async {
      adCalls.add(call.method);
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(instanceManager.channel, null);
    MobileAdsInitializer.resetForTest();
  });

  group('Mobile Ads SDK', () {
    test('no MobileAds.initialize while unresolved / absent / OFF / DISABLING',
        () async {
      TestEgress(resolved: false, seedOn: true).install();
      await MobileAdsInitializer.ensureInitialized();
      TestEgress().install(); // resolved, no record
      await MobileAdsInitializer.ensureInitialized();
      final off = TestEgress(seedOn: true).install();
      await off.gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      await MobileAdsInitializer.ensureInitialized();
      expect(adCalls, isEmpty);
      expect(MobileAdsInitializer.isInitialized, isFalse);
    });

    test('permitted: the SDK initialize IS reached (control)', () async {
      TestEgress(seedOn: true).install();
      await MobileAdsInitializer.ensureInitialized();
      expect(adCalls, contains('MobileAds#initialize'));
    });

    test(
        'UMP: nothing gathered and nothing latched while not permitted; the '
        'privacy-options entry is hidden', () async {
      TestEgress().install();
      expect(await const UmpAdConsentService().isPrivacyOptionsRequired(),
          isFalse);
      await const UmpAdConsentService().gatherConsent(); // returns, no SDK call
      await const UmpAdConsentService().showPrivacyOptions();
      final fake = _CountingConsent();
      final session = SessionAdConsent(fake);
      await session.ensureGathered();
      expect(fake.gathers, 0);
      TestEgress(seedOn: true).install();
      await session.ensureGathered();
      expect(fake.gathers, 1, reason: 'not latched by the OFF attempt');
    });
  });

  group('banners', () {
    test('eligibility is re-evaluated whenever the permit state changes',
        () async {
      final e = TestEgress(seedOn: true).install();
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final seen = <int>[];
      c.listen(egressPermitRevisionProvider, (_, n) => seen.add(n),
          fireImmediately: true);
      await e.gate.refresh(); // mirror false -> true
      await pumpEventQueue();
      await e.gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      await pumpEventQueue();
      expect(seen.toSet().length, greaterThanOrEqualTo(2));
    });
  });

  group('url_launcher: one wrapper, denied unless permitted', () {
    late _Launcher launcher;
    setUp(() {
      launcher = _Launcher();
      UrlLauncherPlatform.instance = launcher;
    });

    test('OFF / absent / unresolved: nothing reaches the platform launcher',
        () async {
      final u = Uri.parse('https://example.com/privacy');
      TestEgress().install();
      expect(await launchExternalUrl(u), isFalse);
      TestEgress(resolved: false, seedOn: true).install();
      expect(await launchExternalUrl(u), isFalse);
      expect(launcher.launched, isEmpty);
    });

    test('ON: launched', () async {
      TestEgress(seedOn: true).install();
      expect(
          await launchExternalUrl(Uri.parse('https://example.com/p')), isTrue);
      expect(launcher.launched, ['https://example.com/p']);
    });
  });
}
