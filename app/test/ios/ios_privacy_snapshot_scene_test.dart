import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// IOS-03 — STATIC source contract. The app uses the UIScene lifecycle
// (Info.plist UIApplicationSceneManifest + SceneDelegate), under which UIKit
// does not deliver the app-delegate background/foreground callbacks and
// AppDelegate.window is not the scene's window. The app-switcher privacy cover
// must therefore be installed and removed from the SceneDelegate, on the
// scene's window. Behaviour itself needs simulator/device confirmation.

String _body(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) return '';
  final next = source.indexOf('override func', start + signature.length);
  return source.substring(start, next < 0 ? source.length : next);
}

void main() {
  final plist = File('ios/Runner/Info.plist').readAsStringSync();
  final scene = File('ios/Runner/SceneDelegate.swift').readAsStringSync();

  test('the app runs under the UIScene lifecycle', () {
    expect(plist, contains('<key>UIApplicationSceneManifest</key>'));
    expect(plist, contains('SceneDelegate</string>'));
  });

  test('sceneDidEnterBackground installs the cover on the scene window', () {
    expect(_body(scene, 'func sceneDidEnterBackground('),
        contains('installPrivacySnapshotView(in: window)'));
  });

  test('B24: the cover goes up as soon as the scene resigns active', () {
    expect(_body(scene, 'func sceneWillResignActive('),
        contains('installPrivacySnapshotView(in: window)'));
  });

  test('the cover is removed when the scene returns', () {
    expect(_body(scene, 'func sceneWillEnterForeground('),
        contains('removePrivacySnapshotView()'));
    expect(_body(scene, 'func sceneDidBecomeActive('),
        contains('removePrivacySnapshotView()'));
  });
}
