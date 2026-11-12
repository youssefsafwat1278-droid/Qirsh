import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// H3 (Astra contract H, section H3): native transport enforcement.
///
/// Source pins only. Swift is NOT compiled here and the XCTests in
/// ios/RunnerTests/RunnerTests.swift have not been run; Android was not built.
/// These pins make the audit repeatable: if someone adds a second native
/// network path, a background mode, a redirect-following session, or leaks the
/// Dart account-control allowance into native code, Linux CI fails.
void main() {
  String read(String path) => File(path).readAsStringSync();

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

  /// Every native source of every iOS target (Runner, ShareBankMessage,
  /// BankMessageShortcuts, ...). Excludes Pods/ and Flutter/ (not ours: the
  /// SDK audit below covers them) and the XCTest file, whose assertions quote
  /// the forbidden tokens.
  List<File> iosSources() => Directory('ios')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => RegExp(r'\.(swift|m|mm|h|c|cc|cpp)$').hasMatch(f.path))
      .where((f) => !f.path.startsWith('ios/Pods/'))
      .where((f) => !f.path.startsWith('ios/Flutter/'))
      .where((f) => !f.path.startsWith('ios/.symlinks/'))
      .where((f) => f.path != 'ios/RunnerTests/RunnerTests.swift')
      .toList();

  const transportPath = 'ios/Runner/SharedCaptureStore.swift';
  const copyPath = 'ios/ShareBankMessage/SharedCaptureStore.swift';
  final store = read(transportPath);
  final copy = read(copyPath);
  final intent = read('ios/BankMessageShortcuts/BankMessageShortcuts.swift');
  final appDelegate = read('ios/Runner/AppDelegate.swift');
  final share = read('ios/ShareBankMessage/ShareViewController.swift');
  final xctest = read('ios/RunnerTests/RunnerTests.swift');

  group('H3.1 one gated native transport', () {
    test('the two SharedCaptureStore copies stay byte-identical', () {
      expect(File(transportPath).readAsBytesSync(),
          File(copyPath).readAsBytesSync());
      expect(copy, store);
    });

    test('the audit sees every iOS target source', () {
      final names = iosSources().map((f) => f.path).toSet();
      for (final expected in const [
        transportPath,
        copyPath,
        'ios/Runner/AppDelegate.swift',
        'ios/ShareBankMessage/ShareViewController.swift',
        'ios/BankMessageShortcuts/BankMessageShortcuts.swift',
      ]) {
        expect(names, contains(expected));
      }
    });

    test('no network API is used outside the transport, in any iOS target', () {
      const forbidden = [
        'URLSession',
        'dataTask',
        'uploadTask',
        'downloadTask',
        'NWConnection',
        'NWPathMonitor',
        'NWEndpoint',
        'CFNetwork',
        'CFReadStream',
        'CFWriteStream',
        'CFHTTP',
        'NSURLConnection',
        'NSURLSession',
        'WKWebView',
        'SFSafariViewController',
        'CFSocket',
        'GCDAsyncSocket',
        'getaddrinfo',
        'contentsOf: URL(string',
      ];
      for (final file in iosSources()) {
        if (file.path == transportPath || file.path == copyPath) continue;
        final source = file.readAsStringSync();
        // A URLRequest VALUE may only be built by the one client (it is sent
        // by nobody but the transport).
        expect(source.contains('URLRequest'),
            file.path == 'ios/BankMessageShortcuts/BankMessageShortcuts.swift',
            reason: '${file.path} builds a URLRequest');
        for (final token in forbidden) {
          expect(source, isNot(contains(token)),
              reason: '${file.path} uses $token outside the transport');
        }
      }
    });

    test('the transport is the only URLSession and is built exactly once', () {
      expect(RegExp(r'URLSession\(configuration:').allMatches(store).length, 1);
      expect(store, isNot(contains('URLSession.shared')));
      expect(store, isNot(contains('dataTask')));
      expect(store, isNot(contains('NWConnection')));
      expect(store, isNot(contains('CFNetwork')));
      expect(RegExp(r'session\.data\(for:').allMatches(store).length, 1);
      // BankMessageShortcuts only builds a URLRequest-free body and calls it.
      expect(intent, isNot(contains('URLSession')));
      expect(
          RegExp(r'SharedCaptureStore\.gatedUpload\(').allMatches(intent).length,
          1);
    });

    test('the session is ephemeral, refuses redirects, never waits or retries',
        () {
      final transport = body(store, 'static func gatedUpload(');
      expect(transport, contains('URLSessionConfiguration.ephemeral'));
      expect(transport, contains('httpCookieStorage = nil'));
      expect(transport, contains('httpShouldSetCookies = false'));
      expect(transport, contains('urlCache = nil'));
      expect(transport, contains('urlCredentialStorage = nil'));
      expect(transport, contains('waitsForConnectivity = false'));
      expect(transport, contains('delegate: RedirectRefusingDelegate()'));
      expect(transport, isNot(contains('.background')));
      expect(transport, isNot(contains('sessionSendsLaunchEvents')));
      expect(transport, isNot(contains('isDiscretionary')));
      // One attempt: no loop and no recursion inside the transport.
      expect(transport, isNot(contains('for ')));
      expect(transport, isNot(contains('while ')));
      expect(transport, isNot(contains('gatedUpload(')));
      final delegate = body(store, 'final class RedirectRefusingDelegate');
      expect(delegate, contains('willPerformHTTPRedirection'));
      expect(delegate, contains('completionHandler(nil)'));
      expect(delegate, isNot(contains('completionHandler(request)')));
    });

    test('admission runs under the flock immediately before the request', () {
      final transport = body(store, 'static func gatedUpload(');
      final admit = transport.indexOf('admitUpload(payloadID: payloadID)');
      final cleanup =
          transport.indexOf('defer { removeInflightUpload(payloadID: payloadID) }');
      final ownerCheck =
          transport.indexOf('admittedUid == ownerUid, admittedGeneration == ownerGeneration');
      final send = transport.indexOf('try await session.data(for: admitted)');
      expect(admit, greaterThan(-1));
      expect(admit, lessThan(cleanup));
      expect(cleanup, lessThan(ownerCheck),
          reason: 'a stale (owner, generation) refusal also removes the entry');
      expect(ownerCheck, lessThan(send));
      // Nothing but request preparation sits between the last check and the send.
      final between = transport.substring(ownerCheck, send);
      expect(between, isNot(contains('await')));
      expect(between, isNot(contains('Task')));
      expect(between, isNot(contains('sleep')));
      expect('throw QueueError.egressDenied'.allMatches(transport).length, 3,
          reason: 'admission, the owner check, and a withdrawal since the '
              'request began');
      // A cloud-off withdrawal epoch read BEFORE admission; registration after
      // the owner check refuses if it moved, and is cancellable until the send.
      final epoch = transport.indexOf('inflightSessions.epoch(owner)');
      final register = transport.indexOf('inflightSessions.register(');
      expect(epoch, allOf(greaterThan(-1), lessThan(admit)));
      expect(register, allOf(greaterThan(ownerCheck), lessThan(send)));
      // admitUpload = authorize + registry under ONE withQueueLock.
      final admitBody = body(store, 'static func admitUpload(payloadID: String)');
      expect(admitBody, contains('withQueueLock'));
      expect(admitBody, contains('authorizeUploadLocked(payloadID)'));
      expect(admitBody, contains('writeInflight(entries)'));
    });

    test('the client maps a refusal to egressDenied and keeps owner binding',
        () {
      expect(intent, contains('catch SharedCaptureStore.QueueError.egressDenied'));
      expect(intent, contains('throw BackendCaptureError.egressDenied'));
      expect(intent, contains('body["owner_uid"] = ownerUid'));
      expect(intent, contains('body["owner_generation"] = ownerGeneration'));
      expect(intent, isNot(contains('ownerUid: String? = nil')));
    });

    test('G3 guarantees are intact: registry, per-owner records, DEBUG seams',
        () {
      expect(store, contains('private static func authorizeUploadLocked('));
      expect(store, contains('private static func egressDenied(forOwner'));
      expect(store, contains('static func removeInflightUpload('));
      expect(store, contains('static func inflightUploads(forUid'));
      expect(store, contains('var owners: [String: CloudEgressRecord]'));
      expect(store, contains('egressGenerationIsStale('));
      // gatedUpload adds no test seam of its own.
      final transport = body(store, 'static func gatedUpload(');
      expect(transport, isNot(contains('Override')));
      expect(transport, isNot(contains('#if')));
    });
  });

  group('H3.1 extension, App Intent, background, push', () {
    test('ShareBankMessage has no network use and only queues', () {
      final dir = Directory('ios/ShareBankMessage')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.swift'))
          .map((f) => f.path.split('/').last)
          .toSet();
      expect(dir, {
        'ShareViewController.swift',
        'SharedCaptureStore.swift',
        'SharedOfferIntentStore.swift',
      });
      expect(share, contains('SharedCaptureStore.enqueue('));
      expect(share, isNot(contains('gatedUpload')));
      expect(share, isNot(contains('admitUpload')));
      expect(share, isNot(contains('URL(string')));
      final offers = read('ios/ShareBankMessage/SharedOfferIntentStore.swift');
      expect(offers, isNot(contains('gatedUpload')));
      // The transport lives in the copy's compiled image but nothing in the
      // extension calls it.
      expect(RegExp(r'gatedUpload\(').allMatches(copy).length, 1,
          reason: 'only the declaration: no caller inside the store');
    });

    test('the App Intent upload is the only caller of the transport', () {
      for (final file in iosSources()) {
        if (file.path == transportPath || file.path == copyPath) continue;
        final source = file.readAsStringSync();
        final calls = RegExp(r'gatedUpload\(').allMatches(source).length;
        expect(calls, file.path.endsWith('BankMessageShortcuts.swift') ? 1 : 0,
            reason: file.path);
      }
    });

    test(
        'background audit: the only background execution is the BGTask that '
        'runs the live engine\'s Dart drain; no native egress, no background '
        'session, no silent push', () {
      // The Runner may declare exactly fetch + processing for the capture
      // drain BGTasks (BackgroundTasks framework). Everything else stays out.
      final runnerPlist = read('ios/Runner/Info.plist');
      final modes = RegExp(
              r'<key>UIBackgroundModes</key>\s*<array>([\s\S]*?)</array>')
          .firstMatch(runnerPlist)
          ?.group(1);
      expect(
          RegExp(r'<string>([^<]+)</string>')
              .allMatches(modes ?? '')
              .map((m) => m.group(1))
              .toSet(),
          {'fetch', 'processing'});
      final ids = RegExp(r'<key>BGTaskSchedulerPermittedIdentifiers</key>'
              r'\s*<array>([\s\S]*?)</array>')
          .firstMatch(runnerPlist)
          ?.group(1);
      expect(
          RegExp(r'<string>([^<]+)</string>')
              .allMatches(ids ?? '')
              .map((m) => m.group(1))
              .toSet(),
          {
            'com.youssefsafwat.mali.capture-drain.refresh',
            'com.youssefsafwat.mali.capture-drain.processing',
          });
      expect(runnerPlist, isNot(contains('remote-notification')));
      for (final plist in const [
        'ios/ShareBankMessage/Info.plist',
        'ios/Runner/Runner.entitlements',
        'ios/Runner/RunnerQA.entitlements',
        'ios/ShareBankMessage/ShareBankMessage.entitlements',
        'ios/ShareBankMessage/ShareBankMessageQA.entitlements',
      ]) {
        final text = read(plist);
        for (final key in const [
          'UIBackgroundModes',
          'BGTaskSchedulerPermittedIdentifiers',
          'remote-notification',
          'background-fetch',
          'background-processing',
        ]) {
          expect(text, isNot(contains(key)), reason: '$plist declares $key');
        }
      }
      for (final file in iosSources()) {
        final source = file.readAsStringSync();
        final bgTaskAllowed = file.path == 'ios/Runner/AppDelegate.swift';
        for (final token in const [
          'BGTaskScheduler',
          'BackgroundTasks',
          'BGAppRefreshTask',
          'BGProcessingTask',
        ]) {
          if (bgTaskAllowed) continue;
          expect(source, isNot(contains(token)),
              reason: '${file.path} uses $token');
        }
        for (final token in const [
          'URLSessionConfiguration.background',
          'handleEventsForBackgroundURLSession',
          'performFetchWithCompletionHandler',
          'didReceiveRemoteNotification',
          'beginBackgroundTask',
        ]) {
          expect(source, isNot(contains(token)),
              reason: '${file.path} uses $token');
        }
      }
      // The BGTask handler performs no native egress: it only asks the live
      // engine's Dart drain (gated client, per-message consent) to run.
      final delegate = read('ios/Runner/AppDelegate.swift');
      final bg = delegate
          .substring(delegate.indexOf('final class CaptureBackgroundDrain'));
      for (final token in const [
        'URLSession',
        'URLRequest',
        'gatedUpload(',
        'FlutterEngine(',
      ]) {
        expect(bg, isNot(contains(token)), reason: 'BGTask handler uses $token');
      }
      expect(bg, contains('invokeMethod("runBackgroundDrain"'));
    });

    test('push registration is reached only through the gated channel', () {
      for (final file in iosSources()) {
        final source = file.readAsStringSync();
        final n = RegExp(r'registerForRemoteNotifications\(\)')
            .allMatches(source)
            .length;
        expect(n, file.path == 'ios/Runner/AppDelegate.swift' ? 1 : 0,
            reason: file.path);
      }
      final at = appDelegate.indexOf('case "registerForRemoteNotifications":');
      final gate = appDelegate.indexOf('egressAdmitsHostRequest(', at);
      final call = appDelegate.indexOf(
          'UIApplication.shared.registerForRemoteNotifications()', at);
      expect(gate, greaterThan(at));
      expect(gate, lessThan(call));
      // The refusal answers "no token" and returns before registration.
      final refusal = appDelegate.substring(gate, call);
      expect(refusal, contains('result(nil)'));
      expect(refusal, contains('return'));
      final host = body(store, 'static func egressAdmitsHostRequest(');
      expect(host, contains('withQueueLock'));
      expect(host, contains('egressDenied(forOwner: owner?.uid)'));
      expect(host, contains('egressGenerationIsStale(generation, owner: uid)'));
      expect(host, contains('?? false'));
      // No other Dart-callable route to APNs registration.
      final dart = read('lib/features/capture/services/native_capture_bridge.dart');
      expect(RegExp("invokeMethod<Object\\?>\\(\\s*'registerForRemoteNotifications'")
          .hasMatch(dart), isTrue);
    });
  });

  group('H3.1 the Dart account-control allowance never reaches native', () {
    test('native reads only the durable state; nothing persists an allowance',
        () {
      for (final source in [store, copy, appDelegate, intent, share]) {
        expect(source.toLowerCase(), isNot(contains('allowance')));
        expect(source, isNot(contains('accountControl')));
        expect(source, isNot(contains('userInitiated')));
      }
      // Admission signatures carry no caller-supplied bypass.
      expect(store, contains('static func admitUpload(payloadID: String)'));
      expect(store, contains('static func authorizeUpload(payloadID: String)'));
      final gated = store.substring(store.indexOf('static func gatedUpload('));
      final signature = gated.substring(0, gated.indexOf('{'));
      expect(signature, isNot(contains('bypass')));
      expect(signature, isNot(contains('force')));
      expect(signature, isNot(contains('override')));
      // Only the egress setter writes the record, with state/owner/generation.
      expect(store, contains('static func setCloudEgressState('));
    });

    test('the native bridge sends no allowance across the channel', () {
      final bridge =
          read('lib/features/capture/services/native_capture_bridge.dart');
      expect(bridge.toLowerCase(), isNot(contains('allowance')));
      expect(bridge, isNot(contains('accountControl')));
      expect(bridge, isNot(contains('runUserInitiated')));
      expect(bridge, isNot(contains('cloud_egress_gate')),
          reason: 'the bridge cannot read the in-process Dart grant');
    });
  });

  group('H3.2 Android Kotlin: no network use', () {
    final kotlin = Directory('android/app/src/main/kotlin')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.kt') || f.path.endsWith('.java'))
        .toList();

    test('the audit sees the capture sources', () {
      final names = kotlin.map((f) => f.path.split('/').last).toSet();
      expect(
          names,
          containsAll(<String>[
            'DurableCaptureQueue.kt',
            'SmsCaptureReceiver.kt',
            'MainActivity.kt',
            'CaptureSettings.kt',
            'SharedContentRouter.kt',
            'OfferIntentStore.kt',
          ]));
    });

    test('no HTTP / socket / WebView / background-work API', () {
      const forbidden = [
        'HttpURLConnection',
        'HttpsURLConnection',
        'URLConnection',
        'java.net.URL',
        'java.net.Socket',
        'java.net.InetAddress',
        'java.net.Proxy',
        'javax.net',
        'okhttp',
        'retrofit',
        'ktor',
        'volley',
        'WebView',
        'DownloadManager',
        'WorkManager',
        'JobScheduler',
        'JobService',
        'AlarmManager',
        'ForegroundService',
        'ConnectivityManager',
        'openConnection',
        'openStream',
        'URL(',
      ];
      for (final file in kotlin) {
        final source = file.readAsStringSync();
        // The background capture drain schedules ONE unique WorkManager work
        // that asks the live engine's Dart drain (gated HTTP client) to run;
        // the worker itself has no network code (every other token below
        // still applies to it).
        final worker = file.path.endsWith('/CaptureDrainWorker.kt');
        for (final token in forbidden) {
          if (worker && token == 'WorkManager') continue;
          expect(source, isNot(contains(token)),
              reason: '${file.path} uses $token');
        }
        // `java.net.URI` is string parsing in SharedContentRouter, not network.
        for (final m in RegExp(r'java\.net\.\w+').allMatches(source)) {
          expect(m.group(0), 'java.net.URI', reason: file.path);
        }
      }
    });

    test('the app module adds no networking dependency', () {
      final gradle = read('android/app/build.gradle.kts');
      final deps = gradle.substring(gradle.indexOf('dependencies {'));
      for (final lib in const ['okhttp', 'retrofit', 'ktor', 'volley']) {
        expect(deps, isNot(contains(lib)));
      }
    });

    test('the manifest declares no service, provider or job of ours', () {
      final manifest = read('android/app/src/main/AndroidManifest.xml')
          .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
      expect(manifest, isNot(contains('<service')));
      expect(manifest, isNot(contains('<provider')));
      expect(manifest, isNot(contains('android.permission.WAKE_LOCK')));
      expect(manifest, isNot(contains('FOREGROUND_SERVICE')));
      // The receiver exists only for SMS_RECEIVED, delivered by the system.
      expect(manifest, contains('android:permission="android.permission.BROADCAST_SMS"'));
    });
  });

  group('H3.2 native SDK init: plist / manifest settings', () {
    Map<String, String> plugins() {
      final config = jsonDecode(read('.dart_tool/package_config.json'))
          as Map<String, dynamic>;
      final out = <String, String>{};
      for (final p in config['packages'] as List) {
        final m = p as Map<String, dynamic>;
        final name = m['name'] as String;
        if (name == 'sentry_flutter' || name == 'google_mobile_ads') {
          var root = m['rootUri'] as String;
          root = root.startsWith('file://') ? Uri.parse(root).toFilePath() : root;
          out[name] = root.endsWith('/') ? root : '$root/';
        }
      }
      return out;
    }

    test('sentry_flutter removes sentry-android\'s process-start auto-init', () {
      final root = plugins()['sentry_flutter'];
      expect(root, isNotNull, reason: 'run flutter pub get');
      final manifest = read('${root}android/src/main/AndroidManifest.xml');
      // Quoted evidence (sentry_flutter 9.22.0):
      //   <provider android:name="io.sentry.android.core.SentryInitProvider"
      //             android:authorities="${applicationId}.SentryInitProvider"
      //             android:exported="false" tools:node="remove" />
      expect(manifest, contains('io.sentry.android.core.SentryInitProvider'));
      expect(manifest, contains('tools:node="remove"'));
      // The host manifest must neither re-add the provider nor flip the switch.
      final app = read('android/app/src/main/AndroidManifest.xml');
      expect(app, isNot(contains('SentryInitProvider')));
      expect(app, isNot(contains('io.sentry.auto-init')));
      expect(app, isNot(contains('io.sentry.dsn')),
          reason: 'a manifest DSN would let sentry-android start itself');
    });

    test('native Sentry starts only from sentry_flutter init (Dart-driven)', () {
      final root = plugins()['sentry_flutter']!;
      final ios = read(
          '${root}ios/sentry_flutter/Sources/sentry_flutter/SentryFlutterPlugin.swift');
      expect(RegExp(r'SentrySDK\.start').allMatches(ios).length, 1);
      expect(body(ios, 'private func initNativeSdk('),
          contains('SentrySDK.start'));
      expect(ios, contains('case "initNativeSdk":'));
      // The host app never starts it, and neither does Kotlin.
      for (final source in [store, appDelegate, intent, share]) {
        expect(source, isNot(contains('SentrySDK')));
        expect(source, isNot(contains('import Sentry')));
      }
      for (final file in Directory('android/app/src/main/kotlin')
          .listSync(recursive: true)
          .whereType<File>()) {
        expect(file.readAsStringSync(), isNot(contains('Sentry')));
      }
      // Exactly one Dart start site (H2 gates it behind the egress gate).
      final sites = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => RegExp(r'SentryFlutter\.init\(')
              .hasMatch(f.readAsStringSync()))
          .toList();
      expect(sites.length, 1, reason: sites.map((f) => f.path).join(', '));
    });

    test('Google Mobile Ads: only the application id is declared', () {
      // H-7 (ad_sdk_initialization_order_test.dart) records that neither
      // GADDelayAppMeasurementInit nor DELAY_APP_MEASUREMENT_INIT exists in the
      // SDKs bundled with google_mobile_ads 9.0.0 and that the Android
      // process-start provider only validates the application id. This pin keeps
      // the plist / manifest honest: no key that implies a protection the SDK
      // does not provide. A google_mobile_ads bump must re-run that analysis.
      final plist = read('ios/Runner/Info.plist');
      expect(plist, contains('GADApplicationIdentifier'));
      expect(plist, isNot(contains('GADDelayAppMeasurementInit')));
      final manifest = read('android/app/src/main/AndroidManifest.xml');
      expect(manifest, contains('com.google.android.gms.ads.APPLICATION_ID'));
      expect(manifest, isNot(contains('DELAY_APP_MEASUREMENT_INIT')));
      expect(read('pubspec.yaml'), contains('google_mobile_ads: 9.0.0'));
      // The plugin itself initialises the iOS SDK only on the Dart call.
      final root = plugins()['google_mobile_ads']!;
      final plugin = read(
          '${root}ios/google_mobile_ads/Sources/google_mobile_ads/FLTGoogleMobileAdsPlugin.m');
      expect(
          RegExp(r'startWithCompletionHandler').allMatches(plugin).length, 1);
      expect(plugin, contains('@"MobileAds#initialize"'));
      final pluginManifest = read('${root}android/src/main/AndroidManifest.xml');
      expect(pluginManifest, isNot(contains('<provider')));
      expect(pluginManifest, isNot(contains('<service')));
    });

    test('no native code starts an ads SDK itself', () {
      for (final source in [store, appDelegate, intent, share]) {
        expect(source, isNot(contains('GADMobileAds')));
        expect(source, isNot(contains('import GoogleMobileAds')));
      }
      for (final file in Directory('android/app/src/main/kotlin')
          .listSync(recursive: true)
          .whereType<File>()) {
        expect(file.readAsStringSync(), isNot(contains('MobileAds')));
      }
    });
  });

  group('H3.3 XCTests exist (uncompiled here; Mac proof pending)', () {
    test('the H3 XCTests are present', () {
      for (final name in const [
        'testGatedUploadDeniedInDisablingAndOff',
        'testGatedUploadStaleGenerationAndOwnerDenied',
        'testPushRegistrationStaleGenerationDenied',
        'testNoNetworkUseOutsideTheGatedTransport',
        'testExtensionHasNoNetworkPushIsGatedAndAllowanceStaysInDart',
        'testBackendClientOwnerBindingAndAdmissionOrder',
      ]) {
        expect(xctest, contains('func $name('),
            reason: name);
      }
    });
  });
}
