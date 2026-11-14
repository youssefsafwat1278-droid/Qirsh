import 'dart:async';
import 'dart:convert';

import '../security/secure_storage_options.dart';

/// Foreground Dart-isolate custody only. This is not a cross-process CAS.
enum ImmediateDeletionPhase { created, mayHaveBeenSent, completed }

class ImmediateDeletionReceipt {
  const ImmediateDeletionReceipt({
    required this.owner,
    required this.operationId,
    required this.receiptSecret,
    required this.phase,
  });

  final String owner;
  final String operationId;
  final String? receiptSecret;
  final ImmediateDeletionPhase phase;

  String encode() => jsonEncode({
        'v': 1,
        'owner': owner,
        'operation_id': operationId,
        'receipt_secret': receiptSecret,
        'phase': phase.name,
      });

  @override
  String toString() => 'ImmediateDeletionReceipt(phase: ${phase.name})';
}

class ImmediateDeletionReceiptStoreException implements Exception {
  const ImmediateDeletionReceiptStoreException();
  @override
  String toString() => 'ImmediateDeletionReceiptStoreException';
}

class _ReceiptLock {
  Future<void>? _tail;

  Future<T> run<T>(Future<T> Function() body) {
    final result = (_tail ?? Future<void>.value()).then((_) => body());
    late final Future<void> tail;
    void release() {
      // Keep queued work serialized, but do not retain an idle future from
      // the async zone of a previous caller (such as a widget test).
      if (identical(_tail, tail)) _tail = null;
    }

    tail = result.then<void>((_) => release(),
        onError: (Object _, StackTrace __) => release());
    _tail = tail;
    return result;
  }
}

/// A dedicated versioned qirsh. namespace survives the existing session wipe.
/// The existing storage options and preserve rule are not changed.
class ImmediateDeletionReceiptStore {
  ImmediateDeletionReceiptStore({
    Future<String?> Function(String key)? read,
    Future<void> Function(String key, String value)? write,
    Future<void> Function(String key)? delete,
    Object? authority,
  })  : _read = read ?? ((key) => SecureStorageOptions.storage.read(key: key)),
        _write = write ??
            ((key, value) =>
                SecureStorageOptions.storage.write(key: key, value: value)),
        // Injected read/write without an injected delete never reaches the
        // platform: abandoning a receipt then fails closed.
        _delete = delete ??
            (write == null
                ? ((key) => SecureStorageOptions.storage.delete(key: key))
                : ((key) => throw const ImmediateDeletionReceiptStoreException())),
        authority = authority ?? _secureAuthority;

  static final Object _secureAuthority = Object();
  static final Expando<_ReceiptLock> _locks = Expando<_ReceiptLock>();
  final Object authority;
  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final Future<void> Function(String key) _delete;

  static String storageKey(String owner) =>
      'qirsh.immediate_deletion.v1.${base64Url.encode(utf8.encode(owner)).replaceAll('=', '')}';

  /// Facades sharing a storage backend must share this authority. The platform
  /// default shares one authority across all instances in this Dart isolate.
  Future<T> serialized<T>(Future<T> Function() body) =>
      (_locks[authority] ??= _ReceiptLock()).run(body);

  Future<ImmediateDeletionReceipt?> load(String owner) async {
    try {
      if (owner.isEmpty) throw const ImmediateDeletionReceiptStoreException();
      final raw = await _read(storageKey(owner));
      if (raw == null) return null;
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> ||
          value.length != 5 ||
          !value.keys.every(const {'v', 'owner', 'operation_id', 'receipt_secret', 'phase'}.contains) ||
          value['v'] is! int ||
          value['v'] != 1 ||
          value['owner'] != owner ||
          value['operation_id'] is! String ||
          !(value['operation_id'] as String).contains(RegExp(r'^[A-Za-z0-9_-]{1,128}$'))) {
        throw const ImmediateDeletionReceiptStoreException();
      }
      final phase = ImmediateDeletionPhase.values
          .where((p) => p.name == value['phase']).firstOrNull;
      final secret = value['receipt_secret'];
      if (phase == null ||
          (secret != null &&
              (secret is! String ||
                  !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(secret))) ||
          (phase != ImmediateDeletionPhase.completed && secret == null)) {
        throw const ImmediateDeletionReceiptStoreException();
      }
      return ImmediateDeletionReceipt(
        owner: owner,
        operationId: value['operation_id'] as String,
        receiptSecret: secret as String?,
        phase: phase,
      );
    } catch (_) {
      throw const ImmediateDeletionReceiptStoreException();
    }
  }

  Future<void> writeVerified(ImmediateDeletionReceipt receipt) async {
    try {
      final encoded = receipt.encode();
      await _write(storageKey(receipt.owner), encoded);
      final readback = await load(receipt.owner);
      if (readback?.encode() != encoded) {
        throw const ImmediateDeletionReceiptStoreException();
      }
    } catch (_) {
      throw const ImmediateDeletionReceiptStoreException();
    }
  }

  /// Removes this owner's receipt and proves it is gone. Callers must hold
  /// [serialized] and have compared the record they are abandoning first.
  Future<void> deleteVerified(String owner) async {
    try {
      if (owner.isEmpty) throw const ImmediateDeletionReceiptStoreException();
      await _delete(storageKey(owner));
      if (await load(owner) != null) {
        throw const ImmediateDeletionReceiptStoreException();
      }
    } catch (_) {
      throw const ImmediateDeletionReceiptStoreException();
    }
  }
}
