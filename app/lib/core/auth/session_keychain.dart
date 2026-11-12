import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// ASR design v7.2 §6.1 — Dart side of `ios/Runner/SessionKeychain.swift` and
/// `android/.../SessionKeychain.kt`.
///
/// Every result keeps the OS status class. `absent` is a positive statement that
/// the item does not exist; `unavailable` (protected data not available yet) and
/// `error` are never read as absent. A channel failure or timeout is
/// [KeychainStatus.unknown]: for a write, the outcome is not known (§6.3).
enum KeychainStatus { found, absent, ok, unavailable, error, unknown }

@immutable
class KeychainResult {
  const KeychainResult(this.status, [this.value, this.permanent = false]);

  final KeychainStatus status;

  /// Present only for [KeychainStatus.found].
  final String? value;

  /// Android only, with [KeychainStatus.error]: the item exists but can never
  /// be read again (its Keystore key is gone or invalidated, or its bytes are
  /// damaged). A retry cannot help; the record is unrecoverable. iOS never
  /// sets it.
  final bool permanent;

  /// [KeychainStatus.error] that no retry can resolve.
  bool get isUnrecoverable => status == KeychainStatus.error && permanent;

  bool get isFound => status == KeychainStatus.found;
  bool get isAbsent => status == KeychainStatus.absent;

  /// A write/delete the OS reported as successful.
  bool get isOk => status == KeychainStatus.ok;

  @override
  String toString() => 'KeychainResult($status)';
}

/// The operations the session store and the ASR eligibility reads need. Fakes
/// implement this in tests.
abstract class SessionKeychainApi {
  Future<KeychainResult> read(String key);
  Future<KeychainResult> write(String key, String value);
  Future<KeychainResult> delete(String key);

  /// Status-preserving read of an item written by `flutter_secure_storage`
  /// (same query shape as the plugin; never writes).
  Future<KeychainResult> readPluginItem(String key);

  /// Null when the platform cannot answer (treated as not available).
  Future<bool?> protectedDataAvailable();

  /// Fires when iOS reports protected data became available.
  Stream<void> get protectedDataBecameAvailable;
}

class MethodChannelSessionKeychain implements SessionKeychainApi {
  MethodChannelSessionKeychain({
    MethodChannel? channel,
    this.timeout = const Duration(seconds: 5),
  }) : _channel = channel ?? const MethodChannel('qirsh/session_keychain') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'protectedDataDidBecomeAvailable') {
        _available.add(null);
      }
    });
  }

  final MethodChannel _channel;
  final Duration timeout;
  final StreamController<void> _available = StreamController<void>.broadcast();

  static KeychainStatus _parse(Object? s) => switch (s) {
        'found' => KeychainStatus.found,
        'absent' => KeychainStatus.absent,
        'ok' => KeychainStatus.ok,
        'unavailable' => KeychainStatus.unavailable,
        _ => KeychainStatus.error,
      };

  Future<KeychainResult> _call(String method, Map<String, Object?> args) async {
    try {
      final reply = await _channel
          .invokeMapMethod<String, Object?>(method, args)
          .timeout(timeout);
      if (reply == null) return const KeychainResult(KeychainStatus.unknown);
      final status = _parse(reply['status']);
      final value = reply['value'];
      if (status == KeychainStatus.found && value is! String) {
        return const KeychainResult(KeychainStatus.error);
      }
      return KeychainResult(status, value as String?,
          status == KeychainStatus.error && reply['permanent'] == true);
    } catch (_) {
      // Lost reply, timeout or missing plugin: the native outcome is unknown.
      return const KeychainResult(KeychainStatus.unknown);
    }
  }

  @override
  Future<KeychainResult> read(String key) => _call('read', {'key': key});

  @override
  Future<KeychainResult> write(String key, String value) =>
      _call('write', {'key': key, 'value': value});

  @override
  Future<KeychainResult> delete(String key) => _call('delete', {'key': key});

  @override
  Future<KeychainResult> readPluginItem(String key) =>
      _call('readPluginItem', {'key': key});

  @override
  Future<bool?> protectedDataAvailable() async {
    try {
      return await _channel
          .invokeMethod<bool>('protectedDataAvailable')
          .timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<void> get protectedDataBecameAvailable => _available.stream;
}
