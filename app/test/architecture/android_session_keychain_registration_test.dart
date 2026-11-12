import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// THE ANDROID SESSION KEYCHAIN MUST EXIST ON EVERY ENGINE, SEALED AND LOCAL.
///
/// Without a `qirsh/session_keychain` handler every coordinated session load
/// deferred, so an Android build with a configured backend never left the
/// loading screen (the channel had only an iOS side). Registration is native,
/// so its presence is pinned here; its behaviour is covered by
/// `android/app/src/test/.../SessionVaultTest.kt` (JVM) and
/// `integration_test/android_session_keychain_test.dart` (device).
void main() {
  final root = Directory.current.path;
  String read(String p) => File('$root/$p').readAsStringSync();

  const dir = 'android/app/src/main/kotlin/com/example/money_companion';
  final activity = read('$dir/MainActivity.kt');
  final worker = read('$dir/CaptureDrainWorker.kt');
  final keychain = read('$dir/SessionKeychain.kt');

  test('the activity engine registers it while configuring the engine', () {
    final configure =
        activity.substring(activity.indexOf('fun configureFlutterEngine'));
    final body = configure.substring(0, configure.indexOf('\n    }\n'));
    expect(body, contains('SessionKeychainChannel.register('));
  });

  test('the headless engine registers it BEFORE Dart runs', () {
    final start = worker.substring(worker.indexOf('override fun start('));
    final register = start.indexOf('SessionKeychainChannel.register(');
    final execute = start.indexOf('executeDartEntrypoint(');
    expect(register, greaterThan(0));
    expect(execute, greaterThan(register));
  });

  test('channel name matches the Dart side', () {
    expect(keychain, contains('const val NAME = "qirsh/session_keychain"'));
    expect(read('lib/core/auth/session_keychain.dart'),
        contains("MethodChannel('qirsh/session_keychain')"));
  });

  test('owned items: Keystore AES-GCM, no_backup, no plaintext path', () {
    expect(keychain, contains('"AndroidKeyStore"'));
    expect(keychain, contains('KeyProperties.BLOCK_MODE_GCM'));
    expect(keychain, contains('AES/GCM/NoPadding'));
    expect(keychain, contains('noBackupFilesDir'));
    expect(keychain, isNot(contains('setUserAuthenticationRequired(true)')),
        reason: 'refresh and capture run while the phone is locked');
    // Every stored value goes through seal(); nothing writes a raw value.
    expect(keychain, contains('items[itemName(name)] = sealed'));
  });

  test('one serial executor shared by every engine (§6.3)', () {
    expect(keychain, contains('internal object SessionKeychainChannel'));
    expect(keychain, contains('Executors.newSingleThreadExecutor'));
  });

  test('backup and device transfer stay disabled for the whole app', () {
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
  });
}
