import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/session_keychain.dart';

/// The Dart side of `qirsh/session_keychain` parses what both natives send:
/// iOS (`SessionKeychain.swift`) and Android (`SessionKeychain.kt`), whose
/// replies may carry `permanent: true` on an error.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('qirsh/session_keychain.test');
  late Object? Function(MethodCall) reply;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final r = reply(call);
      if (r is PlatformException) throw r;
      return r;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  final keychain = MethodChannelSessionKeychain(channel: channel);

  test('a permanent error is unrecoverable', () async {
    reply = (_) => {'status': 'error', 'code': 'key_lost', 'permanent': true};
    final r = await keychain.read('k');
    expect(r.status, KeychainStatus.error);
    expect(r.isUnrecoverable, isTrue);
    expect(r.value, isNull);
  });

  test('an error without the flag (iOS, or transient) stays retryable',
      () async {
    reply = (_) => {'status': 'error', 'code': 'keystore_unavailable'};
    expect((await keychain.read('k')).isUnrecoverable, isFalse);
    reply = (_) => {'status': 'error', 'code': -25308};
    expect((await keychain.read('k')).isUnrecoverable, isFalse);
  });

  test('the flag means nothing on any other status', () async {
    reply = (_) => {'status': 'found', 'value': 'v', 'permanent': true};
    final r = await keychain.read('k');
    expect(r.isFound, isTrue);
    expect(r.isUnrecoverable, isFalse);
    reply = (_) => {'status': 'absent', 'permanent': true};
    expect((await keychain.read('k')).isUnrecoverable, isFalse);
  });

  test('an indeterminate native write is unknown (reconciled by a read)',
      () async {
    reply = (_) => PlatformException(code: 'indeterminate');
    expect((await keychain.write('k', 'v')).status, KeychainStatus.unknown);
  });

  test('a missing handler is never absent', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    expect((await keychain.read('k')).status, KeychainStatus.unknown);
    expect(await keychain.protectedDataAvailable(), isNull);
  });
}
