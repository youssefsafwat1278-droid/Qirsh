import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../backend/supabase_config.dart';
import '../security/secure_storage_options.dart';

/// "Help improve categories for everyone" — the separate switch for shared
/// category learning. ON unless this account turned it off, on this device
/// (owner's decision: on by default, never forced; the change-category and
/// confirm sheets say so at the moment of sharing).
///
/// Stored in the device keychain / EncryptedSharedPreferences
/// ([SecureStorageOptions]: this-device-only, never iCloud-synced, Android
/// backup disabled), one key per account: `qirsh.shared_learning.v1.<sha256
/// of the uid>`. It is not in the Drift database, so an app backup or restore
/// never carries it, and no other account's key is ever read. Signed out means
/// no uid, which means OFF. Both choices are written explicitly, so an OFF
/// survives; a missing key is the default (ON); an unreadable store is OFF.
///
/// It is a preference, not consent: sending still needs Cloud AND AI consent.
class SharedLearningPreference {
  SharedLearningPreference({
    Future<String?> Function(String key)? read,
    Future<void> Function(String key, String value)? write,
  })  : _read = read ?? ((k) => SecureStorageOptions.storage.read(key: k)),
        _write = write ??
            ((k, v) => SecureStorageOptions.storage.write(key: k, value: v));

  /// An in-memory store, for tests.
  factory SharedLearningPreference.memory([Map<String, String>? backing]) {
    final m = backing ?? <String, String>{};
    return SharedLearningPreference(
      read: (k) async => m[k],
      write: (k, v) async => m[k] = v,
    );
  }

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;

  static const _on = 'on';
  static const _off = 'off';

  static String keyFor(String uid) =>
      'qirsh.shared_learning.v1.${sha256.convert(utf8.encode(uid))}';

  Future<bool> isOn(String? uid) async {
    if (uid == null || uid.isEmpty) return false;
    try {
      return await _read(keyFor(uid)) != _off;
    } catch (_) {
      return false; // unreadable = OFF
    }
  }

  Future<void> set(String uid, bool on) async {
    if (uid.isEmpty) return;
    await _write(keyFor(uid), on ? _on : _off);
  }
}

final sharedLearningPreferenceProvider =
    Provider<SharedLearningPreference>((_) => SharedLearningPreference());

/// The signed-in account the preference belongs to; null when signed out.
final sharedLearningAccountProvider = Provider<String? Function()>((_) => () =>
    SupabaseConfig.isConfigured
        ? supabase.Supabase.instance.client.auth.currentUser?.id
        : null);

/// The current account's choice. Invalidate after changing it.
final sharedLearningOptInProvider = FutureProvider.autoDispose<bool>((ref) {
  final uid = ref.watch(sharedLearningAccountProvider)();
  return ref.watch(sharedLearningPreferenceProvider).isOn(uid);
});
