import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:money_companion/features/ads/admob_build_config.dart';
import 'package:money_companion/features/report_ads/ad_consent_service.dart';
import '../../harness/egress_test_support.dart';

void main() {
  // Decision 3.2: advertising is compiled out of Version 1 builds. These tests
  // exercise the ad pipeline itself, as a build made with
  // --dart-define=QIRSH_ADS_ENABLED=true runs it. The compiled-out behaviour
  // is covered by test/features/ads/v1_ads_compiled_out_test.dart.
  setUp(() => AdMobBuildConfig.debugAdsCompiledInOverride = true);
  tearDown(() => AdMobBuildConfig.debugAdsCompiledInOverride = false);
  TestWidgetsFlutterBinding.ensureInitialized();
  const update = 'ConsentInformation#requestConsentInfoUpdate';
  const form = 'UserMessagingPlatform#loadAndShowConsentFormIfRequired';
  final channel = MethodChannel('plugins.flutter.io/google_mobile_ads/ump',
      StandardMethodCodec(UserMessagingCodec()));
  for (final mode in [
    'on',
    'neverOn',
    'disabling',
    'off',
    'reenabled',
    'replaced'
  ]) {
    test('concrete UMP delayed callback: $mode', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == update) {
          entered.complete();
          await release.future;
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final e = TestEgress(seedOn: mode != 'neverOn').install();
      final gathering = const UmpAdConsentService().gatherConsent();
      if (mode == 'neverOn') {
        await gathering;
        expect(calls, isEmpty);
        return;
      }
      await entered.future;
      if (mode == 'replaced') {
        TestEgress(seedOn: true).install();
      } else if (mode != 'on') {
        e.gate.advanceEpoch();
        final freeze =
            await e.gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
        if (mode != 'disabling') {
          await e.gate.commitOff(freeze);
        }
        if (mode == 'reenabled') {
          await e.gate.enable(owner: 'uid-a', reservedVersion: 3);
        }
      }
      release.complete();
      await gathering;
      expect(calls.where((x) => x == update).length, 1);
      expect(calls.where((x) => x == form).length, mode == 'on' ? 1 : 0);
    });
  }
}
