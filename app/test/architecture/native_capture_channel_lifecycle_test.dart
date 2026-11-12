import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/platform/device_timezone.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

/// THE NATIVE CAPTURE CHANNEL MUST EXIST BEFORE DART CAN CALL IT.
///
/// Registration lives in Swift, so its timing cannot be exercised from a Dart
/// test. What CAN be pinned is the shape that makes the timing correct, and the
/// shape is what regressed: the channel was only registered from
/// `applicationDidBecomeActive` / `sceneDidBecomeActive`, both of which fire
/// after the engine is already running Dart. Bootstrap called the channel inside
/// that window, got MissingPluginException, and — with the ownership ordering of
/// the time — that cost users their data (ac622970).
///
/// `didFinishLaunchingWithOptions` cannot do it either: under UIScene it runs
/// before any scene connects, so `rootFlutterViewController()` is nil and the
/// call there is a silent no-op. `scene(_:willConnectTo:)` is the earliest point
/// where Flutter has built the window from Main.storyboard — whose root view
/// controller IS the FlutterViewController — so its binaryMessenger exists.
void main() {
  final root = Directory.current.path;
  String read(String p) => File('$root/$p').readAsStringSync();

  const sceneDelegate = 'ios/Runner/SceneDelegate.swift';
  const appDelegate = 'ios/Runner/AppDelegate.swift';

  group('registration cannot be lost because no scene is connected yet', () {
    test('the channel is registered at scene CONNECT, not only when active',
        () {
      final src = read(sceneDelegate);
      expect(src, contains('willConnectTo'),
          reason: 'scene(_:willConnectTo:) is the earliest deterministic point; '
              'without it the first registration waits for didBecomeActive, '
              'which is after Dart is already running');

      final connect = src.substring(src.indexOf('willConnectTo'));
      final body = connect.substring(0, connect.indexOf('\n  }'));
      expect(body, contains('configureNativeCaptureChannelIfNeeded'),
          reason: 'the connect hook must actually register');
      expect(body, contains('super.scene('),
          reason: 'super builds the window and the FlutterViewController — '
              'registering before it would find no messenger');
    });

    test('registration does NOT require a foreground-active scene', () {
      // A scene can connect while still inactive (state restoration, a
      // background launch). Gating registration on active would reintroduce the
      // window this fix closes.
      final src = read(sceneDelegate);
      final connect = src.substring(src.indexOf('willConnectTo'));
      final body = connect.substring(0, connect.indexOf('\n  }'));
      expect(body.contains('activationState'), isFalse);
      expect(body.contains('.foregroundActive'), isFalse);
    });

    test('the later lifecycle hooks are KEPT as defence in depth', () {
      // Belt and braces: if a future Flutter changes when willConnectTo fires,
      // the app must still end up with a channel.
      final scene = read(sceneDelegate);
      final app = read(appDelegate);
      expect(scene, contains('sceneDidBecomeActive'));
      expect(app, contains('applicationDidBecomeActive'));
      expect(
        'configureNativeCaptureChannelIfNeeded'.allMatches(scene + app).length,
        greaterThanOrEqualTo(4),
        reason: 'connect + sceneDidBecomeActive + didFinishLaunching + '
            'applicationDidBecomeActive, plus the definition',
      );
    });
  });

  group('repeated lifecycle callbacks do not duplicate handlers', () {
    test('idempotency is per-CONTROLLER, never merely "a channel exists"', () {
      final src = read(appDelegate);
      final fn = src.substring(
          src.indexOf('func configureNativeCaptureChannelIfNeeded'));
      final body = fn.substring(0, fn.indexOf('\n  }'));

      // THE reconnect hole. `captureChannel == nil` alone is not idempotency:
      // iOS can rebuild the FlutterViewController (and its messenger) while the
      // AppDelegate survives, leaving a non-nil channel bound to a dead
      // messenger — and sending to it neither throws nor returns.
      expect(body.contains('captureChannel == nil'), isFalse,
          reason: 'a bare nil-check would no-op on reconnect and strand the '
              'app on the old messenger');
      expect(body, contains('captureChannelController === controller'),
          reason: 'identity of the CURRENT controller is what decides');
      expect(body, contains('rootFlutterViewController()'),
          reason: 'and it must still refuse to register without a messenger');
    });

    test('a NEW controller rebinds — old handler cleared, exactly one installed',
        () {
      final src = read(appDelegate);
      final fn = src.substring(
          src.indexOf('func configureNativeCaptureChannelIfNeeded'));
      final body = fn.substring(0, fn.indexOf('\n  }'));

      final clearAt = body.indexOf('setMethodCallHandler(nil)');
      final createAt = body.indexOf('FlutterMethodChannel(');
      expect(clearAt, greaterThan(-1),
          reason: 'the previous handler must be released, not leaked');
      expect(clearAt, lessThan(createAt),
          reason: 'clear the old binding BEFORE installing the new one');

      expect('FlutterMethodChannel('.allMatches(body).length, 1,
          reason: 'exactly one channel is constructed per registration');
      expect(body, contains('captureChannelController = controller'),
          reason: 'the new binding records its controller, or the next call '
              'rebinds again forever');
    });

    test('the tracked controller is a WEAK reference', () {
      final src = read(appDelegate);
      expect(src, contains('private weak var captureChannelController'),
          reason: 'a strong reference would keep a dead FlutterViewController '
              'alive and make a deallocated controller compare equal to '
              'nothing — weak reads back nil and forces a correct rebind');
    });

    test('an old channel is never treated as authoritative after a rebind', () {
      final src = read(appDelegate);
      // Every outbound use goes through the single `captureChannel` field, which
      // the rebind replaces — so nothing can hold a stale reference of its own.
      final strays = RegExp(r'let\s+\w*[Cc]hannel\s*=\s*FlutterMethodChannel\(\s*\n?\s*name:\s*"money_companion/native_capture"')
          .allMatches(src)
          .length;
      expect(strays, 1,
          reason: 'the capture channel is constructed in exactly one place');
      expect(src, contains('captureChannel?.invokeMethod'),
          reason: 'sends go through the rebindable field, optionally chained');
    });

    test('the registration path uses no force unwraps', () {
      final src = read(appDelegate);
      final fn = src.substring(
          src.indexOf('func configureNativeCaptureChannelIfNeeded'));
      final body = fn.substring(0, fn.indexOf('\n  }'));
      // `guard let` / `if let` only. A force unwrap here crashes at launch.
      expect(RegExp(r'controller!').hasMatch(body), isFalse);
      expect(RegExp(r'rootFlutterViewController\(\)!').hasMatch(body), isFalse);
    });

    test('the scene connect hook uses no force unwrap either', () {
      final src = read(sceneDelegate);
      expect(src, contains('as? AppDelegate'),
          reason: 'conditional cast, never as!');
      expect(RegExp(r'as! AppDelegate').hasMatch(src), isFalse);
    });
  });

  group('Dart startup before didBecomeActive stays supported', () {
    test('the bounded retry is still in place as defence in depth', () {
      // The Swift fix removes the race at source; the Dart retry stays because
      // "the channel is not up yet" must never again be read as "the purge
      // failed". Both layers, not one.
      expect(NativeCaptureBridge.purgeChannelRetries, greaterThan(1));
      expect(NativeCaptureBridge.purgeChannelRetryDelay.inMilliseconds,
          greaterThan(0));
    });

    test('the retry remains BOUNDED — bootstrap cannot hang on it', () {
      final total = NativeCaptureBridge.purgeChannelRetryDelay *
          (NativeCaptureBridge.purgeChannelRetries - 1);
      expect(total.inSeconds, lessThanOrEqualTo(2),
          reason: 'this runs before the first frame');
    });
  });

  group('the single-scene assumption this relies on', () {
    test('multiple scenes are not enabled', () {
      // One scene means one FlutterViewController and one engine, so a single
      // registration is sufficient. If this is ever turned on, the channel would
      // need to be per-scene and this whole design needs revisiting.
      final plist = read('ios/Runner/Info.plist');
      final at = plist.indexOf('UIApplicationSupportsMultipleScenes');
      expect(at, greaterThan(-1));
      expect(plist.substring(at, at + 120), contains('<false/>'),
          reason: 'enabling multiple scenes invalidates the one-channel design');
    });
  });
  group('the device timezone channel matches those guarantees', () {
    // A SECOND custom channel must not ship weaker lifecycle handling than the
    // one that was just hardened. Dart reaches this one from
    // LocalNotificationService.initialize(), which bootstrap runs at
    // `notifications_init` — the same pre-first-frame window that produced the
    // MissingPluginException behind ac622970. A channel registered only from
    // didBecomeActive would be reachable before it exists, and the user would
    // silently keep the Asia/Riyadh fallback for the entire session.
    String timezoneFn() {
      final src = read(appDelegate);
      final at = src.indexOf('func configureDeviceTimezoneChannelIfNeeded');
      expect(at, greaterThan(-1),
          reason: 'the timezone channel registration must exist');
      final rest = src.substring(at);
      return rest.substring(0, rest.indexOf('\n  }'));
    }

    test('it registers at scene CONNECT, not only when active', () {
      final src = read(sceneDelegate);
      final connect = src.substring(src.indexOf('willConnectTo'));
      final body = connect.substring(0, connect.indexOf('\n  }'));
      expect(body, contains('configureDeviceTimezoneChannelIfNeeded'),
          reason: 'bootstrap asks for the zone before the first frame, so the '
              'handler must exist by scene connect');
    });

    test('idempotency is per-CONTROLLER, never merely "a channel exists"', () {
      final body = timezoneFn();
      // The bare nil-check is the reconnect hole Audit 3A closed. Shipping it
      // here would reintroduce the same defect on a different channel.
      expect(body.contains('deviceTimezoneChannel == nil'), isFalse,
          reason: 'a bare nil-check would no-op on reconnect and strand the '
              'channel on the old messenger');
      expect(body, contains('deviceTimezoneChannelController === controller'),
          reason: 'identity of the CURRENT controller is what decides');
      expect(body, contains('rootFlutterViewController()'),
          reason: 'it must refuse to register without a messenger');
    });

    test('a NEW controller rebinds — old handler cleared, exactly one installed',
        () {
      final body = timezoneFn();
      final clearAt = body.indexOf('setMethodCallHandler(nil)');
      final createAt = body.indexOf('FlutterMethodChannel(');
      expect(clearAt, greaterThan(-1),
          reason: 'the previous handler must be released, not leaked');
      expect(clearAt, lessThan(createAt),
          reason: 'clear the old binding BEFORE installing the new one');
      expect('FlutterMethodChannel('.allMatches(body).length, 1,
          reason: 'exactly one channel is constructed per registration');
      expect(body, contains('deviceTimezoneChannelController = controller'),
          reason: 'the new binding records its controller, or the next call '
              'rebinds again forever');
    });

    test('the tracked controller is a WEAK reference', () {
      expect(read(appDelegate),
          contains('private weak var deviceTimezoneChannelController'),
          reason: 'a strong reference would keep a dead FlutterViewController '
              'alive; weak reads back nil and forces a correct rebind');
    });

    test('the registration path uses no force unwraps', () {
      final body = timezoneFn();
      expect(RegExp(r'controller!').hasMatch(body), isFalse);
      expect(RegExp(r'rootFlutterViewController\(\)!').hasMatch(body), isFalse);
    });

    test('it reads the zone from Foundation and never from CoreLocation', () {
      // The whole point of replacing flutter_timezone. A CoreLocation import
      // here would reintroduce ITMS-90683 through the fix for it.
      final src = read(appDelegate);
      expect(RegExp(r'^\s*(import|#import|@import)\s+.*CoreLocation',
              multiLine: true)
          .hasMatch(src),
          isFalse,
          reason: 'no CoreLocation import may return to this file');
      // The handler is shared with the headless cold-start engine.
      expect(timezoneFn(), contains('Self.installDeviceTimezoneHandler(on: channel)'));
      final installer = src.substring(
          src.indexOf('static func installDeviceTimezoneHandler('));
      expect(installer.substring(0, installer.indexOf('\n  }\n')),
          contains('TimeZone.current.identifier'));
    });

    test('the later lifecycle hooks are KEPT as defence in depth', () {
      final scene = read(sceneDelegate);
      final app = read(appDelegate);
      expect(
        'configureDeviceTimezoneChannelIfNeeded'.allMatches(scene + app).length,
        greaterThanOrEqualTo(4),
        reason: 'scene connect + sceneDidBecomeActive + didFinishLaunching + '
            'applicationDidBecomeActive, plus the definition',
      );
    });

    test('the bounded Dart retry is in place and short', () {
      // Belt and braces: the Swift fix removes the race at source, the retry
      // keeps "not up yet" from being read as "this device has no timezone".
      expect(DeviceTimezone.channelRetries, greaterThan(1));
      expect(DeviceTimezone.channelRetryDelay.inMilliseconds, greaterThan(0));
      final total = DeviceTimezone.channelRetryDelay *
          (DeviceTimezone.channelRetries - 1);
      expect(total.inSeconds, lessThanOrEqualTo(1),
          reason: 'this runs before the first frame');
    });
  });

}
