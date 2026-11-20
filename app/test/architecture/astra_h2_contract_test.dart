import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Astra H2 source pins (the behaviour is proved in the focused tests; these
/// stop a later edit from quietly re-opening a path).
void main() {
  String read(String p) => File(p).readAsStringSync();
  final libFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  String body(String source, String signature) {
    final at = source.indexOf(signature);
    expect(at, greaterThan(-1), reason: '$signature not found');
    final open = source.indexOf('{', at + signature.length);
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}' && --depth == 0) {
        return source.substring(open, i + 1);
      }
    }
    fail('unbalanced braces after $signature');
  }

  test('runUserInitiated is gone; the OFF exceptions are account-control only',
      () {
    for (final f in libFiles) {
      expect(f.readAsStringSync(), isNot(contains('runUserInitiated')),
          reason: f.path);
    }
    final gate = read('lib/core/privacy/cloud_egress_gate.dart');
    expect(gate, contains('Future<T> runAccountControl<T>('));
    expect(
        gate,
        contains(
            'signIn, reauthenticate, deleteAccount, cancelDelete, onboardingStatus,'));
    for (final f in const [
      'lib/core/auth/supabase_auth_service.dart',
      'lib/core/auth/account_deletion_service.dart'
    ]) {
      expect(read(f), contains('runAccountControl'), reason: f);
    }
  });

  test('permits() requires resolved + a durable ON record (absent is not ON)',
      () {
    final gate = read('lib/core/privacy/cloud_egress_gate.dart');
    final permits = body(gate, 'Future<bool> permits({String? owner})');
    expect(permits, contains('!_resolved'));
    expect(permits, contains('v.record?.state == EgressState.on'));
    expect(permits, isNot(contains('record == null')));
    expect(body(gate, 'Future<String?> _decide('),
        contains("return 'unresolved'"));
  });

  test(
      'no legacy adoption of an absent record; resolution is marked after the '
      'reconcile', () {
    final reg = read(
        'lib/features/capture/services/capture_device_registration_service.dart');
    expect(reg, isNot(contains('Legacy adoption')));
    expect(reg, isNot(contains('rec == null && on')));
    final r = body(reg,
        'Future<void> resolvePendingDisable({EgressResolutionToken? resolution})');
    expect(r.indexOf('await _reconcile('),
        lessThan(r.indexOf('_gate.markResolved(token)')));
  });

  test(
      'startup: gated Supabase, ticker stopped, app_open only when permitted, '
      'Sentry not in main()', () {
    final b = read('lib/core/startup/bootstrap_runner.dart');
    final init = body(b, "await _step('supabase_init'");
    expect(init, contains('httpClient: GatedHttpClient()'));
    expect(init, contains('auth.stopAutoRefresh()'));
    expect(init, contains('permits()'));
    expect(init, isNot(contains('app_open')));
    expect(body(b, 'Future<void> _logAppOpenIfPermitted()'),
        contains('CloudEgressGate.instance.permits()'));
    final main = read('lib/main.dart');
    expect(main, isNot(contains('SentryFlutter.init')));
    expect(main, contains('SentryLifecycle.attach()'));
    expect(read('lib/core/observability/sentry_lifecycle.dart'),
        contains('_close()'));
  });

  test(
      'ads: the only MobileAds.initialize is behind the egress check; banner '
      'eligibility asks the gate', () {
    var count = 0;
    for (final f in libFiles) {
      count += RegExp(r'MobileAds\.instance\.initialize')
          .allMatches(f.readAsStringSync())
          .length;
    }
    expect(count, 1);
    final init = read('lib/features/ads/mobile_ads_initializer.dart');
    final ensure = body(init, 'static Future<void> ensureInitialized()');
    expect(ensure.indexOf('mayServe()'), lessThan(ensure.indexOf('_run()')));
    final prov = read('lib/features/ads/banner_ads_providers.dart');
    expect(prov, contains('CloudEgressGate.instance.permits()'));
    final gw = read('lib/features/report_ads/report_export_ad_gateway.dart');
    expect(gw.indexOf('MobileAdsInitializer.mayServe()'),
        lessThan(gw.indexOf('InterstitialAd.load(')));
  });

  test('url_launcher is imported by the one wrapper only', () {
    final importers = [
      for (final f in libFiles)
        if (f.readAsStringSync().contains("package:url_launcher/")) f.path
    ];
    expect(importers, ['lib/core/privacy/gated_url_launcher.dart']);
  });

  test(
      'no realtime channel is ever opened from lib (websocket is not behind '
      'the http transport)', () {
    for (final f in libFiles) {
      expect(f.readAsStringSync(), isNot(contains('.channel(')),
          reason: f.path);
    }
  });

  test('the native APNs registration carries the transition generation', () {
    final bridge =
        read('lib/features/capture/services/native_capture_bridge.dart');
    expect(bridge, contains("{'transitionGeneration': transitionGeneration}"));
    final reg = read(
        'lib/features/capture/services/capture_device_registration_service.dart');
    final loader = body(reg,
        'Future<ApnsTokenInfo?> _loadApnsToken(String owner,\n      {bool smart = false})');
    // Phase 3: only the smart-analysis lane skips the Cloud permit.
    expect(loader, contains('if (!smart && !await _gate.permits()) return null;'));
    expect(loader.indexOf('_gate.permits()'),
        lessThan(loader.indexOf('registerForRemoteNotifications')));
  });
}
