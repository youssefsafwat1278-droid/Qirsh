import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../features/capture/services/native_capture_bridge.dart';
import '../backend/supabase_config.dart';
import '../security/secure_storage_options.dart';
import '../session/admission_authority.dart';
import '../session/consent_capability.dart';
import 'consent_authority.dart';

final _emptyBodyFingerprint = sha256.convert(const <int>[]).toString();

/// Astra G / C.4: the durable shared denial state and the ONE admission gate.
///
/// ## The record
/// `cloud_egress_state = {state: ON|DISABLING|OFF, owner_uid,
/// transition_generation, reserved_version}`, one per owner, kept in
/// secure storage AND an app-support file (and, on iOS, a third copy in the
/// Keychain shared group / App Group file through the native bridge methods
/// `setCloudEgressState` / `getCloudEgressState`). Any reader that finds
/// DISABLING, OFF, unreadable, corrupt or conflicting state denies egress.
///
/// ## Merge (the only reconciliation rule set)
///  * a valid DISABLING/OFF record in ANY store overrides its absence (or an ON
///    record) in the others; among restrictive records the higher generation
///    wins and, at equal generation, OFF (the commit) wins over DISABLING;
///  * a corrupt or unreadable store makes the whole readout UNCERTAIN: egress is
///    denied until a later read is clean or an explicit enable/disable rewrites
///    every store;
///  * a record for owner A is never applied to owner B and is never dropped by
///    B's writes (every write re-emits the merged records of all owners).
///
/// ## Admission
/// Every Dart network request (the [GatedHttpClient] used by every transport and
/// by the Supabase client, plus the service gates) calls [admit]. It takes a
/// short in-process lock, reads the durable state and registers the request in
/// the in-flight set. [beginDisabling] writes DISABLING under the SAME lock, so
/// no request newly passes admission after DISABLING began. The only request
/// admitted in DISABLING is the one-shot revoke ([runRevoke]).
///
/// ## Astra H2: the Cloud-OFF invariant
/// Cloud OFF blocks all automatic, background and application-data network
/// egress. The only operations permitted while OFF are explicit user-initiated
/// sign-in, re-authentication, delete-account and cancel-delete, with their
/// narrowly scoped account exchanges, including the setup check after sign-in.
/// They do not enable Cloud and authorize nothing else. They run through [runAccountControl], an
/// operation-scoped, time-boxed, endpoint-allowlisted capability (see
/// [AccountControlGrant] and [kAccountControlAllowlist]).
///
/// UNKNOWN / MISSING / CORRUPT state is OFF / UNRESOLVED / DENY:
///  * a process-level `resolved` latch: until bootstrap finished the egress
///    reconciliation ([markResolved]) admission denies EVERYTHING, grants
///    included;
///  * an absent record is not ON: [permits] is false, and only an explicit
///    enable ([enable]) writes ON.
///
/// Requests admitted before DISABLING may complete, but a response that returns
/// after the in-process epoch advanced is DISCARDED (an [EgressDeniedException]
/// reaches the caller), so it can have no state effect. [drain] waits for the
/// in-flight set (bounded) and cancels what is still running. Bytes already
/// transmitted cannot be recalled.
enum EgressState {
  on('ON'),
  disabling('DISABLING'),
  off('OFF');

  const EgressState(this.wire);
  final String wire;

  static EgressState? parse(Object? raw) {
    for (final s in values) {
      if (s.wire == raw) return s;
    }
    return null;
  }
}

@immutable
class CloudEgressRecord {
  const CloudEgressRecord({
    required this.state,
    required this.ownerUid,
    required this.transitionGeneration,
    required this.reservedVersion,
  });

  final EgressState state;

  /// '' for the signed-out scope.
  final String ownerUid;
  final int transitionGeneration;
  final int reservedVersion;

  bool get restrictive => state != EgressState.on;

  Map<String, Object?> toJson() => {
        'state': state.wire,
        'owner_uid': ownerUid,
        'transition_generation': transitionGeneration,
        'reserved_version': reservedVersion,
      };

  /// Null when [raw] is not a well-formed record (the slot is then corrupt).
  static CloudEgressRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final state = EgressState.parse(raw['state']);
    final owner = raw['owner_uid'];
    final gen = raw['transition_generation'];
    final version = raw['reserved_version'];
    if (state == null || owner is! String || gen is! int || version is! int) {
      return null;
    }
    return CloudEgressRecord(
      state: state,
      ownerUid: owner,
      transitionGeneration: gen,
      reservedVersion: version,
    );
  }

  CloudEgressRecord copyWith({
    EgressState? state,
    int? transitionGeneration,
    int? reservedVersion,
  }) =>
      CloudEgressRecord(
        state: state ?? this.state,
        ownerUid: ownerUid,
        transitionGeneration: transitionGeneration ?? this.transitionGeneration,
        reservedVersion: reservedVersion ?? this.reservedVersion,
      );

  @override
  bool operator ==(Object other) =>
      other is CloudEgressRecord &&
      other.state == state &&
      other.ownerUid == ownerUid &&
      other.transitionGeneration == transitionGeneration &&
      other.reservedVersion == reservedVersion;

  @override
  int get hashCode =>
      Object.hash(state, ownerUid, transitionGeneration, reservedVersion);
}

enum SlotStatus { absent, value, corrupt, unreadable }

class SlotRead {
  const SlotRead(this.status, [this.raw]);
  final SlotStatus status;
  final String? raw;
}

/// One durable string slot. Implemented over secure storage and over a file.
abstract class DurableSlot {
  Future<SlotRead> read();
  Future<void> write(String value);
  Future<void> delete();
}

class SecureStorageSlot implements DurableSlot {
  SecureStorageSlot(this._storage, this._key);
  final FlutterSecureStorage _storage;
  final String _key;

  @override
  Future<SlotRead> read() async {
    try {
      final v = await _storage.read(key: _key);
      return v == null
          ? const SlotRead(SlotStatus.absent)
          : SlotRead(SlotStatus.value, v);
    } catch (_) {
      return const SlotRead(SlotStatus.unreadable);
    }
  }

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

class FileSlot implements DurableSlot {
  FileSlot(this._directory, this._name);
  final Future<Directory> Function() _directory;
  final String _name;

  Future<File> _file() async => File('${(await _directory()).path}/$_name');

  @override
  Future<SlotRead> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const SlotRead(SlotStatus.absent);
      return SlotRead(SlotStatus.value, await f.readAsString());
    } catch (_) {
      return const SlotRead(SlotStatus.unreadable);
    }
  }

  @override
  Future<void> write(String value) async {
    final f = await _file();
    await f.writeAsString(value, flush: true);
  }

  @override
  Future<void> delete() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}

/// The iOS third copy (Keychain shared group + App Group file), written by the
/// native side. Native records are PER OWNER: a read names the owner, a write
/// affects only that owner. `unavailable` is any bridge failure, a null answer
/// on iOS or an `uncertain` snapshot, and is fail-closed.
class NativeEgressSlot {
  const NativeEgressSlot({required this.read, required this.write,
      this.readLayers});

  /// Reconciled admission snapshot; null means no record for [owner]. Throws
  /// when that snapshot is unavailable or uncertain. A restrictive winner can
  /// hide another physical slot's generation or unreadability; use
  /// [verifiedLayers] for generation-sensitive operations.
  final Future<CloudEgressRecord?> Function(String owner) read;
  final Future<void> Function(CloudEgressRecord record) write;

  /// Complete physical-layer evidence for generation-sensitive operations.
  /// Admission's restrictive [read] may hide a newer or unreadable layer.
  /// Injected single-layer test stores may omit this separate reader.
  final Future<List<CloudEgressRecord>> Function(String owner)? readLayers;

  Future<List<CloudEgressRecord>> verifiedLayers(String owner) async {
    final inspect = readLayers;
    if (inspect != null) return inspect(owner);
    final record = await read(owner);
    return [if (record != null) record];
  }

  static NativeEgressSlot? platformDefault() {
    if (!NativeCaptureBridge.hasNativeQueue) return null;
    return NativeEgressSlot(
      read: (owner) async {
        final snap =
            await NativeCaptureBridge.getCloudEgressState(ownerUid: owner);
        if (snap == null || snap.uncertain) {
          throw FormatException(
              'native_egress_uncertain:${snap?.uncertainReason ?? 'unknown'}');
        }
        if (owner.isEmpty) {
          if (snap.status != CloudEgressStatus.ownerless) {
            throw const FormatException('native_ownerless_unverified');
          }
          return null;
        }
        if (snap.status == CloudEgressStatus.unset) return null;
        final state = EgressState.parse(snap.state);
        final generation = snap.transitionGeneration;
        final reserved = snap.reservedVersion;
        if (snap.status != CloudEgressStatus.record ||
            state == null ||
            generation == null ||
            reserved == null ||
            generation < 0 ||
            reserved < 0 ||
            snap.ownerUid != owner) {
          throw const FormatException('native_egress_corrupt');
        }
        return CloudEgressRecord(
          state: state,
          ownerUid: owner,
          transitionGeneration: generation,
          reservedVersion: reserved,
        );
      },
      readLayers: (owner) async {
        // inspectEgress reads both physical slots under the native queue lock.
        // egressReport substitutes retirement-operation fields when operationId
        // is present; those are not stored-generation evidence. Refuse them.
        final inspected = await NativeCaptureBridge.getCloudEgressPending(
            ownerUid: owner);
        if (owner.isEmpty || inspected == null || inspected.egress.length != 2 ||
            inspected.status == CloudEgressTransitionStatus.uncertain) {
          throw const FormatException('native_egress_evidence_missing');
        }
        final records = <CloudEgressRecord>[];
        for (final layer in inspected.egress) {
          if (layer.outcome == CloudEgressLayerOutcome.absent &&
              layer.state == null && layer.transitionGeneration == null &&
              layer.reservedVersion == null && layer.operationId == null &&
              layer.ownerGeneration == null && layer.ownerEpoch == null) {
            continue;
          }
          final state = EgressState.parse(layer.state);
          if (layer.outcome != CloudEgressLayerOutcome.verified ||
              state == null || layer.transitionGeneration == null ||
              layer.reservedVersion == null || layer.operationId != null) {
            throw const FormatException('native_egress_evidence_unverified');
          }
          records.add(CloudEgressRecord(
              state: state, ownerUid: owner,
              transitionGeneration: layer.transitionGeneration!,
              reservedVersion: layer.reservedVersion!));
        }
        return records;
      },
      write: (r) => NativeCaptureBridge.setCloudEgressState(
        state: r.state.wire,
        ownerUid: r.ownerUid,
        transitionGeneration: r.transitionGeneration,
        reservedVersion: r.reservedVersion,
      ),
    );
  }
}

/// The merged view of every store.
class EgressReadout {
  const EgressReadout(this.records, this.problems);

  /// Per owner, after the merge.
  final Map<String, CloudEgressRecord> records;

  /// Names of the stores that were corrupt or unreadable (never contents).
  final List<String> problems;

  bool get uncertain => problems.isNotEmpty;
}

class EgressWriteResult {
  const EgressWriteResult(this.succeeded, this.attempted);
  final int succeeded;
  final int attempted;
  bool get any => succeeded > 0;
  bool get all => succeeded == attempted && attempted > 0;
}

/// N-E: the durable Dart-side PENDING denial of one explicit Cloud enable on
/// iOS. It is a record SEPARATE from `cloud_egress_state`: while any pending
/// record of the owner is present (or a pending layer is unreadable or corrupt)
/// every permit, admission and refresh denies, whatever the egress records or
/// the accepted settings say. It carries a Dart-allocated [localOperationId]
/// from the first write, and the full native [binding] once native `begin`
/// returned it. Never a secret, a credential or content.
@immutable
class PendingEnableRecord {
  const PendingEnableRecord({
    required this.ownerUid,
    required this.transitionGeneration,
    required this.reservedVersion,
    required this.localOperationId,
    this.binding,
  });

  final String ownerUid;
  final int transitionGeneration;
  final int reservedVersion;
  final String localOperationId;

  /// Null until native `begin` confirmed the barrier ("denied" stage).
  final CloudEgressEnableBinding? binding;

  PendingEnableRecord bound(CloudEgressEnableBinding b) => PendingEnableRecord(
        ownerUid: ownerUid,
        transitionGeneration: transitionGeneration,
        reservedVersion: reservedVersion,
        localOperationId: localOperationId,
        binding: b,
      );

  Map<String, Object?> toJson() => {
        'owner_uid': ownerUid,
        'transition_generation': transitionGeneration,
        'reserved_version': reservedVersion,
        'operation': localOperationId,
        'native': binding == null
            ? null
            : {
                'operation_id': binding!.operationId,
                'owner_generation': binding!.ownerGeneration,
                'owner_epoch': binding!.ownerEpoch,
              },
      };

  /// Null when [raw] is not a well-formed record (the layer is then corrupt).
  static PendingEnableRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final owner = raw['owner_uid'];
    final generation = raw['transition_generation'];
    final version = raw['reserved_version'];
    final op = raw['operation'];
    final native = raw['native'];
    if (owner is! String ||
        generation is! int ||
        version is! int ||
        op is! String ||
        op.isEmpty ||
        generation < 0 ||
        version < 0) {
      return null;
    }
    CloudEgressEnableBinding? binding;
    if (native != null) {
      if (native is! Map) return null;
      final id = native['operation_id'];
      final ownerGeneration = native['owner_generation'];
      final ownerEpoch = native['owner_epoch'];
      if (id is! String ||
          ownerGeneration is! int ||
          ownerEpoch is! int ||
          ownerGeneration < 0 ||
          ownerEpoch < 0) {
        return null;
      }
      binding = CloudEgressEnableBinding(
        operationId: id,
        transitionGeneration: generation,
        reservedVersion: version,
        ownerGeneration: ownerGeneration,
        ownerEpoch: ownerEpoch,
      );
    }
    return PendingEnableRecord(
      ownerUid: owner,
      transitionGeneration: generation,
      reservedVersion: version,
      localOperationId: op,
      binding: binding,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PendingEnableRecord &&
      other.ownerUid == ownerUid &&
      other.transitionGeneration == transitionGeneration &&
      other.reservedVersion == reservedVersion &&
      other.localOperationId == localOperationId &&
      other.binding == binding;

  @override
  int get hashCode => Object.hash(ownerUid, transitionGeneration,
      reservedVersion, localOperationId, binding);
}

/// Read-only evidence for explicit cold-process pending-enable recovery only.
/// Construction is private; a pending record or signed-in status is not proof.
final class PendingEnableLifetimeProof {
  PendingEnableLifetimeProof._(this.pending, this._capability, this._store,
      {PendingEnableRecord? expectedPending})
      : _expectedPending = expectedPending ?? pending;
  final PendingEnableRecord _expectedPending;
  final PendingEnableRecord pending;
  final ConsentCapability _capability;
  final CloudEgressStore _store;

  Future<void> verify(ConsentCapability capability) async {
    void check() {
      capability.requireCurrent();
      if (!identical(capability, _capability) || pending.ownerUid != capability.uid ||
          pending.binding == null) {
        throw const StaleAdmissionException();
      }
    }
    check();
    final b = pending.binding!;
    final dartPending = await _store.readPending();
    check();
    final dart = await _store.readDartOwnerLayers(capability.uid);
    check();
    final inspected = await NativeCaptureBridge.getCloudEgressPending(ownerUid: capability.uid);
    check();
    final owner = await NativeCaptureBridge.getCaptureOwner();
    check();
    final epoch = await NativeCaptureBridge.captureOwnerEpoch();
    check();
    bool physical(List<CloudEgressLayerReport> layers) => layers.length == 2 &&
        layers[0].layer == 'file' && layers[1].layer == 'keychain';
    bool allowed(String state, int generation, int version) =>
        version >= 0 && generation >= 0 &&
        version <= b.reservedVersion && generation <= b.transitionGeneration &&
        ((state == 'OFF' && generation < b.transitionGeneration) ||
          (state == 'ON' && generation == b.transitionGeneration && version == b.reservedVersion));
    if (dartPending.agreed(capability.uid) != _expectedPending || dart.uncertain ||
        dart.records.any((r) => !allowed(r.state == EgressState.on ? 'ON' :
            r.state == EgressState.off ? 'OFF' : 'DISABLING', r.transitionGeneration, r.reservedVersion)) ||
        owner?.uid != capability.uid || owner?.generation != b.ownerGeneration || epoch != b.ownerEpoch ||
        inspected == null || inspected.operation != 'inspect' ||
        inspected.status != CloudEgressTransitionStatus.pending || inspected.binding != b ||
        !physical(inspected.barrier) || !physical(inspected.egress) ||
        inspected.barrier.any((r) => r.outcome != CloudEgressLayerOutcome.verified ||
          r.operationId != b.operationId || r.transitionGeneration != b.transitionGeneration ||
          r.reservedVersion != b.reservedVersion || r.ownerGeneration != b.ownerGeneration ||
          r.ownerEpoch != b.ownerEpoch) || inspected.egress.any((r) {
          if (r.outcome == CloudEgressLayerOutcome.absent) {
            return r.state != null || r.transitionGeneration != null || r.reservedVersion != null ||
                r.operationId != null || r.ownerGeneration != null || r.ownerEpoch != null;
          }
          return r.outcome != CloudEgressLayerOutcome.verified || r.operationId != null ||
              r.state == null || r.transitionGeneration == null || r.reservedVersion == null ||
              !allowed(r.state!, r.transitionGeneration!, r.reservedVersion!) ||
              (r.ownerGeneration == null) != (r.ownerEpoch == null) ||
              (r.ownerGeneration != null &&
                (r.ownerGeneration != b.ownerGeneration || r.ownerEpoch != b.ownerEpoch)) ||
              (r.state == 'ON' && r.ownerGeneration == null);
        })) {
      throw const StaleAdmissionException();
    }
    // Detect loss of durable denial during native reads as well.
    final after = await _store.readPending();
    check();
    if (after.agreed(capability.uid) != _expectedPending) throw const StaleAdmissionException();
  }
}

/// Issued only after physical pending/ON and live native lifetime inspection.
/// A caller-supplied PendingEnableRecord alone cannot rebind a reservation.
final class PendingEnableCommitProof {
  PendingEnableCommitProof._(this.pending, this._capability, this._store);
  final PendingEnableRecord pending;
  final ConsentCapability _capability;
  final CloudEgressStore _store;

  /// SQL verifies the matching uid/op/version/watermark separately. This local
  /// read runs inside that transaction; native inspection happened before it.
  Future<void> verifyLocal(ConsentCapability capability) async {
    capability.requireCurrent();
    if (!identical(capability, _capability) || pending.ownerUid != capability.uid ||
        pending.binding == null) {
      throw const StaleAdmissionException();
    }
    final read = await _store.readPending();
    capability.requireCurrent();
    final layers = await _store.readDartOwnerLayers(capability.uid);
    capability.requireCurrent();
    if (read.agreed(capability.uid) != pending || layers.uncertain ||
        layers.records.length != 2 || layers.records.any((r) =>
          r.state != EgressState.on ||
          r.transitionGeneration != pending.transitionGeneration ||
          r.reservedVersion != pending.reservedVersion)) {
      throw const StaleAdmissionException();
    }
  }
}

enum PendingLayerStatus { absent, held, corrupt, unreadable }

/// One Dart pending layer as read: its status and the records it parsed.
class PendingLayer {
  const PendingLayer(this.status, [this.records = const {}]);
  final PendingLayerStatus status;
  final Map<String, PendingEnableRecord> records;

  /// An absent layer is readable (it holds nothing); corrupt and unreadable
  /// layers are not, and deny.
  bool get readable =>
      status == PendingLayerStatus.absent || status == PendingLayerStatus.held;
}

/// Both Dart pending layers, read independently (never merged across layers).
class PendingReadout {
  const PendingReadout(this.secure, this.file);
  final PendingLayer secure;
  final PendingLayer file;

  bool get unreadable => !secure.readable || !file.readable;

  /// Whether [owner]'s ON admission is denied by a pending: any pending record
  /// of the owner in either layer, or any layer that cannot be read.
  bool blocks(String owner) =>
      unreadable ||
      secure.records.containsKey(owner) ||
      file.records.containsKey(owner);

  /// The owner's operation when BOTH layers are readable and hold the identical
  /// record; null otherwise (absent, conflicting, partial or unreadable).
  PendingEnableRecord? agreed(String owner) {
    if (unreadable) return null;
    final a = secure.records[owner];
    final b = file.records[owner];
    return a != null && a == b ? a : null;
  }

  /// The owner's record when exactly one readable layer holds it and the other
  /// is readable and holds none.
  PendingEnableRecord? partial(String owner) {
    if (unreadable) return null;
    final a = secure.records[owner];
    final b = file.records[owner];
    if ((a == null) == (b == null)) return null;
    return a ?? b;
  }
}

/// Per-layer outcome of one verified Dart write: true only when the layer was
/// readable, took the write and READ BACK exactly the intended content.
class PendingWriteResult {
  const PendingWriteResult(this.secure, this.file);
  final bool secure;
  final bool file;
  bool get all => secure && file;
}

/// An in-memory layer for stores built through [CloudEgressStore.forTesting]
/// without durable pending slots (unit-test fixtures only; the platform store
/// always supplies the two durable layers).
class _VolatileSlot implements DurableSlot {
  String? _value;
  @override
  Future<SlotRead> read() async => _value == null
      ? const SlotRead(SlotStatus.absent)
      : SlotRead(SlotStatus.value, _value);
  @override
  Future<void> write(String value) async => _value = value;
  @override
  Future<void> delete() async => _value = null;
}

class CloudEgressStore {
  /// Production construction: BOTH durable pending layers are required, so a
  /// store can never be built whose pending-enable denial is merely in memory.
  CloudEgressStore({
    required DurableSlot secure,
    required DurableSlot file,
    NativeEgressSlot? native,
    required DurableSlot pendingSecure,
    required DurableSlot pendingFile,
  })  : _secure = secure,
        _file = file,
        _native = native,
        _pendingSecure = pendingSecure,
        _pendingFile = pendingFile;

  /// Unit-test fixtures only: pending layers that are omitted become in-memory
  /// (volatile) slots. Production code uses the unnamed constructor or
  /// [CloudEgressStore.platform], which cannot omit them.
  @visibleForTesting
  CloudEgressStore.forTesting({
    required DurableSlot secure,
    required DurableSlot file,
    NativeEgressSlot? native,
    DurableSlot? pendingSecure,
    DurableSlot? pendingFile,
  })  : _secure = secure,
        _file = file,
        _native = native,
        _pendingSecure = pendingSecure ?? _VolatileSlot(),
        _pendingFile = pendingFile ?? _VolatileSlot();

  factory CloudEgressStore.platform({
    FlutterSecureStorage? storage,
    Future<Directory> Function()? directory,
    NativeEgressSlot? native,
    bool useNativeDefault = true,
  }) =>
      CloudEgressStore(
        secure: SecureStorageSlot(
            storage ?? SecureStorageOptions.storage, kSecureKey),
        file: FileSlot(directory ?? getApplicationSupportDirectory, kFileName),
        native: native ??
            (useNativeDefault ? NativeEgressSlot.platformDefault() : null),
        pendingSecure: SecureStorageSlot(
            storage ?? SecureStorageOptions.storage, kPendingSecureKey),
        pendingFile: FileSlot(
            directory ?? getApplicationSupportDirectory, kPendingFileName),
      );

  /// `qirsh.` prefix so the session wipe keeps it.
  static const kSecureKey = 'qirsh.cloud_egress_state.v1';
  static const kFileName = 'cloud_egress_state.v1';

  /// The two Dart layers of the durable pending-enable denial (N-E). Distinct
  /// keys from the egress record, also `qirsh.`-prefixed so a session wipe keeps
  /// them.
  static const kPendingSecureKey = 'qirsh.cloud_egress_pending.v1';
  static const kPendingFileName = 'cloud_egress_pending.v1';

  final DurableSlot _secure;
  final DurableSlot _file;
  final NativeEgressSlot? _native;
  final DurableSlot _pendingSecure;
  final DurableSlot _pendingFile;

  static Map<String, CloudEgressRecord>? _parseEnvelope(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['v'] != 1 || decoded['records'] is! Map) {
        return null;
      }
      final out = <String, CloudEgressRecord>{};
      for (final e in (decoded['records'] as Map).entries) {
        final rec = CloudEgressRecord.fromJson(e.value);
        if (rec == null || e.key is! String || rec.ownerUid != e.key) {
          return null;
        }
        out[e.key as String] = rec;
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  static String _envelope(Map<String, CloudEgressRecord> records) =>
      jsonEncode({
        'v': 1,
        'records': {for (final e in records.entries) e.key: e.value.toJson()},
      });

  Future<EgressReadout> read({String? owner}) async {
    final collected = await _collect(owner);
    return EgressReadout(_merge(collected.layers), collected.problems);
  }

  /// [owner]'s records before the admission merge. Production native evidence
  /// inspects both physical slots; missing, unreadable or retirement-substituted
  /// generation evidence marks the result uncertain. Admission still uses its
  /// separate reconciled native snapshot.
  Future<({List<CloudEgressRecord> records, bool uncertain})> readOwnerLayers(
      String owner) async {
    final collected = await _collect(owner, verifyNative: true);
    return (
      records: [
        for (final layer in collected.layers)
          if (layer[owner] != null) layer[owner]!
      ],
      uncertain: collected.problems.isNotEmpty,
    );
  }

  Future<({List<Map<String, CloudEgressRecord>> layers, List<String> problems})>
      _collect(String? owner, {bool verifyNative = false, bool onlyOwner = false}) async {
    final problems = <String>[];
    final layers = <Map<String, CloudEgressRecord>>[];

    Future<void> slot(String name, DurableSlot s) async {
      final r = await s.read();
      switch (r.status) {
        case SlotStatus.absent:
          return;
        case SlotStatus.unreadable:
        case SlotStatus.corrupt:
          problems.add(name);
        case SlotStatus.value:
          final parsed = _parseEnvelope(r.raw!);
          if (parsed == null) {
            problems.add(name);
          } else {
            layers.add(parsed);
          }
      }
    }

    await slot('secure', _secure);
    await slot('file', _file);
    final native = _native;
    if (native != null) {
      // Native records are per owner: ask for the requested owner and every
      // owner the Dart stores know about (a DISABLING marker must be found).
      final owners = {
        if (owner != null) owner,
        if (!onlyOwner) for (final l in layers) ...l.keys,
      };
      if (owners.isEmpty) owners.add('');
      for (final o in owners) {
        try {
          if (verifyNative) {
            for (final rec in await native.verifiedLayers(o)) {
              layers.add({rec.ownerUid: rec});
            }
          } else {
            final rec = await native.read(o);
            if (rec != null) layers.add({rec.ownerUid: rec});
          }
        } catch (e) {
          // Diagnostic detail only: allowlisted queue evidence, never raw errors.
          final detail = e is CaptureQueueException
              ? e.safeDiagnostic
              : e is FormatException
              ? e.message.replaceFirst('native_egress_uncertain:', '')
              : e.runtimeType.toString();
          // A bound ON for an inactive UID cannot match the active native
          // lifetime. Keep other uncertainty, including any for this owner.
          if (!verifyNative &&
              owner != null &&
              owner.isNotEmpty &&
              o != owner &&
              detail == 'lifetime_fields_unbound') {
            continue;
          }
          problems.add('native:$detail');
          break;
        }
      }
    }
    return (layers: layers, problems: problems);
  }

  /// See the class docs of [CloudEgressGate] for the rules.
  static Map<String, CloudEgressRecord> _merge(
      List<Map<String, CloudEgressRecord>> layers) {
    final byOwner = <String, List<CloudEgressRecord>>{};
    for (final layer in layers) {
      for (final r in layer.values) {
        byOwner.putIfAbsent(r.ownerUid, () => []).add(r);
      }
    }
    int rank(EgressState s) => s == EgressState.off ? 1 : 0;
    return {
      for (final e in byOwner.entries)
        e.key: () {
          final restrictive = e.value.where((r) => r.restrictive).toList();
          final pool = restrictive.isNotEmpty ? restrictive : e.value;
          pool.sort((a, b) {
            final g = b.transitionGeneration.compareTo(a.transitionGeneration);
            return g != 0 ? g : rank(b.state).compareTo(rank(a.state));
          });
          return pool.first;
        }(),
    };
  }

  // ── N-E: Dart pending denial and Dart-only ON ─────────────────────────────

  static String _pendingEnvelope(Map<String, PendingEnableRecord> records) =>
      jsonEncode({
        'v': 1,
        'pending': {for (final e in records.entries) e.key: e.value.toJson()},
      });

  static Map<String, PendingEnableRecord>? _parsePendingEnvelope(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['v'] != 1 || decoded['pending'] is! Map) {
        return null;
      }
      final out = <String, PendingEnableRecord>{};
      for (final e in (decoded['pending'] as Map).entries) {
        final rec = PendingEnableRecord.fromJson(e.value);
        if (rec == null || e.key is! String || rec.ownerUid != e.key) {
          return null;
        }
        out[e.key as String] = rec;
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  static Future<PendingLayer> _readPendingLayer(DurableSlot slot) async {
    final SlotRead r;
    try {
      r = await slot.read();
    } catch (_) {
      return const PendingLayer(PendingLayerStatus.unreadable);
    }
    switch (r.status) {
      case SlotStatus.absent:
        return const PendingLayer(PendingLayerStatus.absent);
      case SlotStatus.unreadable:
        return const PendingLayer(PendingLayerStatus.unreadable);
      case SlotStatus.corrupt:
        return const PendingLayer(PendingLayerStatus.corrupt);
      case SlotStatus.value:
        final parsed = _parsePendingEnvelope(r.raw!);
        return parsed == null
            ? const PendingLayer(PendingLayerStatus.corrupt)
            : PendingLayer(PendingLayerStatus.held, parsed);
    }
  }

  /// Both pending layers, each read independently.
  Future<PendingReadout> readPending() async => PendingReadout(
      await _readPendingLayer(_pendingSecure),
      await _readPendingLayer(_pendingFile));

  /// [readPending] with the secure layer read through [secure] (ASR §12: a
  /// status-preserving accessor of the same item).
  Future<PendingReadout> readPendingVia(DurableSlot secure) async =>
      PendingReadout(await _readPendingLayer(secure),
          await _readPendingLayer(_pendingFile));

  /// Replaces [owner]'s record in ONE layer by [next] (null removes it), only
  /// when the layer is readable and [allowed] accepts what it holds for the
  /// owner, then reads the layer back. Other owners' records are carried over
  /// unchanged and verified. False = not written or not verified.
  static Future<bool> _swapPending(
    DurableSlot slot,
    String owner,
    bool Function(PendingEnableRecord? current) allowed,
    PendingEnableRecord? next,
  ) async {
    try {
      final before = await _readPendingLayer(slot);
      if (!before.readable) return false;
      final current = before.records[owner];
      if (!allowed(current)) return false;
      final map = {...before.records};
      if (next == null) {
        map.remove(owner);
      } else {
        map[owner] = next;
      }
      await slot.write(_pendingEnvelope(map));
      final after = await _readPendingLayer(slot);
      if (!after.readable || after.records[owner] != next) return false;
      for (final e in before.records.entries) {
        if (e.key != owner && after.records[e.key] != e.value) return false;
      }
      return after.records.length == map.length;
    } catch (_) {
      return false;
    }
  }

  Future<PendingWriteResult> _both(
          Future<bool> Function(DurableSlot slot) op) async =>
      PendingWriteResult(await op(_pendingSecure), await op(_pendingFile));

  /// Writes [record] into BOTH pending layers (each read back). Refuses a layer
  /// that already holds a pending record of the owner (a begin never adopts an
  /// existing operation) or cannot be read.
  Future<PendingWriteResult> beginPending(PendingEnableRecord record) => _both(
      (slot) => _swapPending(slot, record.ownerUid, (c) => c == null, record));

  /// Replaces the exact [from] with [to] in each layer holding it.
  Future<PendingWriteResult> bindPending(
          PendingEnableRecord from, PendingEnableRecord to) =>
      _both((slot) => _swapPending(slot, from.ownerUid, (c) => c == from, to));

  /// Writes [record] into the layers that hold none, leaving a layer that
  /// already holds exactly it. For an explicit retry of a partially absent
  /// pending only.
  Future<PendingWriteResult> repairPending(PendingEnableRecord record) =>
      _both((slot) async {
        final held = await _readPendingLayer(slot);
        if (held.readable && held.records[record.ownerUid] == record) {
          return true;
        }
        return _swapPending(slot, record.ownerUid, (c) => c == null, record);
      });

  /// Removes the exact [record] from each layer (read back). A layer that holds
  /// nothing of the owner, or a DIFFERENT (newer) operation, is left untouched
  /// and counts as done: nothing of this operation remains in it.
  ///
  /// [isCurrent], when given, is judged immediately before EACH layer: a caller
  /// whose proof ended mid-clear leaves the remaining layer's pending in place
  /// (a partial clear keeps denying).
  Future<PendingWriteResult> clearPending(PendingEnableRecord record,
      {bool Function()? isCurrent}) async {
    Future<bool> one(DurableSlot slot) async {
      if (isCurrent != null && !isCurrent()) return false;
      final held = await _readPendingLayer(slot);
      if (!held.readable) return false;
      final current = held.records[record.ownerUid];
      if (current == null || current != record) return true;
      return _swapPending(slot, record.ownerUid, (c) => c == record, null);
    }

    final secure = await one(_pendingSecure);
    final file = await one(_pendingFile);
    return PendingWriteResult(secure, file);
  }

  static Future<({bool readable, Map<String, CloudEgressRecord> records})>
      _readEgressLayer(DurableSlot slot) async {
    try {
      final r = await slot.read();
      switch (r.status) {
        case SlotStatus.absent:
          return (readable: true, records: <String, CloudEgressRecord>{});
        case SlotStatus.unreadable:
        case SlotStatus.corrupt:
          return (readable: false, records: <String, CloudEgressRecord>{});
        case SlotStatus.value:
          final parsed = _parseEnvelope(r.raw!);
          return parsed == null
              ? (readable: false, records: <String, CloudEgressRecord>{})
              : (readable: true, records: parsed);
      }
    } catch (_) {
      return (readable: false, records: <String, CloudEgressRecord>{});
    }
  }

  /// Unmerged physical Dart evidence. Verified absence is readable.
  Future<({List<CloudEgressRecord> records, bool uncertain})>
      readDartOwnerLayers(String owner) => readDartOwnerLayersVia(owner, _secure);

  /// [readDartOwnerLayers] with the secure layer read through [secure] (ASR
  /// §12: a status-preserving accessor of the same item).
  Future<({List<CloudEgressRecord> records, bool uncertain})>
      readDartOwnerLayersVia(String owner, DurableSlot secure) async {
    final layers = [
      await _readEgressLayer(secure),
      await _readEgressLayer(_file)
    ];
    return (
      records: [
        for (final layer in layers)
          if (layer.records[owner] != null) layer.records[owner]!
      ],
      uncertain: layers.any((layer) => !layer.readable),
    );
  }

  static Future<bool> _swapEgress(DurableSlot slot, CloudEgressRecord next,
      bool Function(CloudEgressRecord? current) allowed,
      {bool Function()? isCurrent}) async {
    try {
      final before = await _readEgressLayer(slot);
      if (!before.readable || (isCurrent != null && !isCurrent())) return false;
      if (!allowed(before.records[next.ownerUid])) return false;
      final map = {...before.records, next.ownerUid: next};
      await slot.write(_envelope(map));
      final after = await _readEgressLayer(slot);
      return after.readable && after.records[next.ownerUid] == next;
    } catch (_) {
      return false;
    }
  }

  /// Writes [record] into the TWO Dart egress layers only (never native), each
  /// read back. A corrupt or unreadable layer is refused, never repaired here.
  ///
  /// N-R9: monotone. A layer holding a NEWER generation for the owner is never
  /// replaced (its write is a failure, never a lowering).
  Future<PendingWriteResult> writeDartLayers(CloudEgressRecord record) async {
    bool notNewer(CloudEgressRecord? c) =>
        c == null ||
        (c.transitionGeneration <= record.transitionGeneration &&
            c.reservedVersion <= record.reservedVersion);
    return PendingWriteResult(
      await _swapEgress(_secure, record, notNewer),
      await _swapEgress(_file, record, notNewer),
    );
  }

  /// Restrictive compensation of the exact ON [written] in the two Dart layers:
  /// a layer that holds [written] gets OFF at the same generation (read back);
  /// a layer that holds anything else (absent, another or a newer generation)
  /// has nothing of it and is left untouched.
  Future<PendingWriteResult> restrictDartLayers(
      CloudEgressRecord written) async {
    Future<bool> one(DurableSlot slot) async {
      final held = await _readEgressLayer(slot);
      if (!held.readable) return false;
      if (held.records[written.ownerUid] != written) return true;
      return _swapEgress(
          slot, written.copyWith(state: EgressState.off), (c) => c == written);
    }

    return PendingWriteResult(await one(_secure), await one(_file));
  }

  /// N-CR-1: reads [owner]'s record back from each admitting runtime on its own
  /// (no merge): the Dart runtime is verified when at least one of its two
  /// stores holds a restrictive record at or above [generation]; the native
  /// runtime (when a native layer exists) when its reconciled record does.
  /// Unreadable or corrupt stores never count.
  Future<RestrictionReadback> readbackRestriction(
      String owner, int generation) async {
    bool holds(CloudEgressRecord? r) =>
        r != null && r.restrictive && r.transitionGeneration >= generation;
    var dart = false;
    for (final slot in [_secure, _file]) {
      try {
        final r = await slot.read();
        if (r.status != SlotStatus.value) continue;
        final parsed = _parseEnvelope(r.raw!);
        if (parsed != null && holds(parsed[owner])) dart = true;
      } catch (_) {}
    }
    bool? native;
    final slot = _native;
    if (slot != null) {
      try {
        native = holds(await slot.read(owner));
      } catch (_) {
        native = false;
      }
    }
    return RestrictionReadback(dart, native);
  }

  /// No store holds a record of [owner] with a generation above [generation],
  /// AND every relevant layer (both Dart stores and the native layer, where one
  /// exists) could be read. N-R8: an unreadable or corrupt layer cannot show a
  /// successor, so it is NOT proof that none exists; the answer is false
  /// (fail closed). Never an all-store claim from a readable subset.
  Future<bool> noNewerGeneration(String owner, int generation) async {
    try {
      final seen = await readOwnerLayers(owner);
      if (seen.uncertain) return false;
      return !seen.records.any((r) => r.transitionGeneration > generation);
    } catch (_) {
      return false;
    }
  }

  /// Writes [record] without lowering any layer's generation or replacing an
  /// unverifiable layer. Other owners keep their per-layer records unchanged.
  Future<EgressWriteResult> write(CloudEgressRecord record) async =>
      await writeUnlessNewer(record) ??
      EgressWriteResult(0, _native == null ? 2 : 3);

  /// N-R8 (N-CR-2): a CONDITIONAL write for a transition that has no authority
  /// over a successor. ONE collection of every relevant layer decides whether
  /// the generation is allowed; dispatch then conditionally rereads each
  /// target layer without substituting a different transition record:
  ///  - any layer unreadable or corrupt: null (unverified, nothing written);
  ///  - any layer holding a generation above [record]'s for the owner: null;
  ///  - [isCurrent] false after that awaited read and before the first write is
  ///    dispatched: [StaleAdmissionException], nothing written.
  /// Otherwise [record] is dispatched conditionally to every store. Native
  /// generation rejection stays independent (the native layer refuses an older record on its own).
  /// Between the read and the write other Dart callers are excluded only by the
  /// gate lock; independently operating native authority is not (its own
  /// generation guard covers it).
  Future<EgressWriteResult?> writeUnlessNewer(CloudEgressRecord record,
      {bool Function()? isCurrent}) async {
    try {
      final collected = await _collect(record.ownerUid, verifyNative: true);
      if (collected.problems.isNotEmpty) return null;
      var version = record.reservedVersion;
      for (final layer in collected.layers) {
        final held = layer[record.ownerUid];
        if (held != null && held.reservedVersion > version) version = held.reservedVersion;
        if (held != null &&
            held.transitionGeneration > record.transitionGeneration) {
          return null;
        }
      }
      if (version > record.reservedVersion) {
        if (!record.restrictive) return null;
        record = record.copyWith(reservedVersion: version);
      }
    } catch (_) {
      return null;
    }
    if (isCurrent != null && !isCurrent()) {
      throw const StaleAdmissionException();
    }
    return _dispatch(record, isCurrent: isCurrent);
  }

  /// N-R9 (N-CR-2): writes the NEXT transition of [owner]. The generation comes
  /// from a VERIFIED MAXIMUM over [owner]'s record in every relevant layer
  /// (secure, file and native), never from the restrictive merge winner (which
  /// lets an older OFF mask a newer ON). ONE read of every layer decides the
  /// generation. Dispatch then rechecks each target layer and carries over its
  /// current other-owner records without substituting the allocated record:
  ///  - any layer unreadable or corrupt: null (nothing written, no generation
  ///    claimed; the caller keeps its freeze and reports the incomplete result);
  ///  - [isCurrent] false after that awaited read and before the first write is
  ///    dispatched: [StaleAdmissionException], nothing written.
  /// [build] receives the allocated generation (strictly above every held one).
  /// Between the read and the write other Dart callers are excluded only by the
  /// gate lock; independently operating native authority is not (its own
  /// generation guard covers it).
  Future<({CloudEgressRecord record, EgressWriteResult result})?> writeAllocated(
      String owner, CloudEgressRecord Function(int generation) build,
      {bool Function()? isCurrent, bool onlyOwner = false}) async {
    CloudEgressRecord record;
    try {
      final collected = await _collect(owner, verifyNative: true, onlyOwner: onlyOwner);
      if (collected.problems.isNotEmpty) return null;
      var highest = 0;
      var version = 0;
      for (final layer in collected.layers) {
        final held = layer[owner];
        if (held != null && held.reservedVersion > version) version = held.reservedVersion;
        if (held != null && held.transitionGeneration > highest) {
          highest = held.transitionGeneration;
        }
      }
      record = build(highest + 1);
      if (version > record.reservedVersion) {
        if (!record.restrictive) return null;
        record = record.copyWith(reservedVersion: version);
      }
    } catch (_) {
      return null;
    }
    if (isCurrent != null && !isCurrent()) {
      throw const StaleAdmissionException();
    }
    return (record: record, result: await _dispatch(record, isCurrent: isCurrent));
  }

  /// Restrictive compensation of [written] that is monotone per store: a Dart
  /// layer is rewritten (read back) only when it is readable and holds nothing
  /// newer than [written] for the owner; a layer holding a newer generation is
  /// left alone (superseded, counted as taken); an unreadable or corrupt layer
  /// is never overwritten (a failure). The native layer is asked only when its
  /// own record is not newer. Other owners' records are carried over.
  Future<EgressWriteResult> restrictOwnerLayers(
      CloudEgressRecord written) async {
    final off = written.copyWith(state: EgressState.off);
    bool notNewer(CloudEgressRecord? c) =>
        c == null || c.transitionGeneration <= written.transitionGeneration;
    var ok = 0;
    var attempted = 2;
    for (final slot in [_secure, _file]) {
      try {
        final held = await _readEgressLayer(slot);
        if (!held.readable) continue;
        if (!notNewer(held.records[written.ownerUid])) {
          ok++;
        } else {
          final version = held.records[written.ownerUid]?.reservedVersion ?? 0;
          final target = version > off.reservedVersion ? off.copyWith(reservedVersion: version) : off;
          if (await _swapEgress(slot, target, (r) => notNewer(r) &&
              (r == null || r.reservedVersion <= target.reservedVersion))) {
            ok++;
          }
        }
      } catch (_) {}
    }
    final native = _native;
    if (native != null) {
      attempted++;
      try {
        final held = await native.verifiedLayers(written.ownerUid);
        if (held.any((record) => !notNewer(record))) {
          // The legacy native writer targets both slots. It cannot safely
          // restrict an old copy beside a newer one; no mutation is attempted.
          if (!held.contains(written)) ok++;
        } else {
          var target = off;
          for (final r in held) {
            if (r.reservedVersion > target.reservedVersion) {
              target = target.copyWith(reservedVersion: r.reservedVersion);
            }
          }
          await native.write(target);
          ok++;
        }
      } catch (_) {}
    }
    return EgressWriteResult(ok, attempted);
  }

  /// Rechecks each Dart layer immediately before its write: a newly unreadable
  /// layer or a newer owner generation is refused; other owners are carried
  /// over from that layer's current envelope, never from a stale merged winner.
  /// The gate lock excludes its other Dart callers. Native authority retains
  /// its independent generation guard; these slots are not a cross-process CAS.
  Future<EgressWriteResult> _dispatch(CloudEgressRecord record,
      {bool Function()? isCurrent}) async {
    // Allocation/conditional preflight already carried the maximum version.
    // A layer that advanced after that read is refused, never lowered.
    bool notNewer(CloudEgressRecord? held) =>
        held == null ||
        (held.transitionGeneration <= record.transitionGeneration &&
            held.reservedVersion <= record.reservedVersion);
    var ok = 0;
    var attempted = 2;
    if (await _swapEgress(_secure, record, notNewer,
        isCurrent: isCurrent)) {
      ok++;
    }
    if (await _swapEgress(_file, record, notNewer,
        isCurrent: isCurrent)) {
      ok++;
    }
    final native = _native;
    if (native != null) {
      attempted++;
      try {
        final held = await native.verifiedLayers(record.ownerUid);
        if (held.every(notNewer) && (isCurrent == null || isCurrent())) {
          await native.write(record);
          ok++;
        }
      } catch (_) {}
    }
    return EgressWriteResult(ok, attempted);
  }
}

/// Thrown into callers whose request was refused, cancelled or discarded.
/// A [http.ClientException] on purpose, so every transport and the Supabase
/// client treat it as an ordinary (retryable) network failure.
class EgressDeniedException extends http.ClientException {
  EgressDeniedException(this.reason) : super('egress_denied:$reason');
  final String reason;
}

class EgressWriteFailedException implements Exception {
  const EgressWriteFailedException(this.what);
  final String what;
  @override
  String toString() => 'EgressWriteFailedException($what)';
}

enum EgressGrantKind { accountControl, revoke, revokeRetry }

/// The ONLY operations allowed to reach the network while Cloud is OFF
/// (Astra H2.1). They never enable Cloud and never widen any consent.
enum AccountControlOp {
  signIn, reauthenticate, deleteAccount, cancelDelete, onboardingStatus, linkIdentity,
}

/// One exact endpoint: method + path (+ the one permitted `grant_type` query).
/// Anything else (another path, another query key, another method) is denied.
@immutable
class AccountControlEndpoint {
  const AccountControlEndpoint(this.method, this.path, {this.grantType});
  final String method;

  /// Relative to the configured Supabase URL.
  final String path;

  /// When set, the query must be EXACTLY `grant_type=<this>`; when null the
  /// query must be empty.
  final String? grantType;

  bool matches(
      String requestMethod, String relativePath, Map<String, String> q) {
    if (requestMethod.toUpperCase() != method || relativePath != path) {
      return false;
    }
    if (grantType == null) return q.isEmpty;
    return q.length == 1 && q['grant_type'] == grantType;
  }

  @override
  String toString() =>
      '$method $path${grantType == null ? '' : '?grant_type=$grantType'}';
}

/// The exact per-op OFF allowlist, derived from the app's real code paths and
/// the pinned package sources (gotrue 2.21.0, supabase 2.12.2, postgrest 2.7.1):
///
///  * `signIn` / `reauthenticate` (identical: the app has ONE interactive
///    sign-in surface, `SupabaseAuthService`, also used when a session expired):
///    Google/Apple `auth.signInWithIdToken` -> POST /auth/v1/token?grant_type=id_token
///    (gotrue_client.dart:422-434); email `signInWithOtp(email:)` -> POST
///    /auth/v1/otp (:470-500); `verifyOTP` -> POST /auth/v1/verify (:577-585).
///  * `deleteAccount` / `cancelDelete`: `rpc('request_account_deletion')` /
///    `rpc('cancel_account_deletion')` -> POST /rest/v1/rpc/<fn> (postgrest.dart:118;
///    POST because `get` defaults false), PLUS the strictly necessary
///    POST /auth/v1/token?grant_type=refresh_token that
///    `SupabaseClient._getAccessToken` (supabase_client.dart:253) issues when the
///    stored access token is expired. That refresh is allowed ONLY inside these
///    two ops.
/// `/auth/v1/user`, `/auth/v1/logout`, PostgREST tables, other RPCs,
/// functions, storage and realtime are outside those static lists. The
/// setup-status grant separately binds one field to the current account,
/// token and empty request body in AccountControlGrant.scopeViolation.
const Map<AccountControlOp, List<AccountControlEndpoint>>
    kAccountControlAllowlist = {
  AccountControlOp.signIn: [
    ..._signInEndpoints,
    AccountControlEndpoint('POST', '/functions/v1/google-enrollment'),
  ],
  AccountControlOp.reauthenticate: _signInEndpoints,
  // Explicit authenticated account management, independent of Cloud consent.
  // No table, sync, storage, logout or arbitrary profile endpoint is admitted.
  AccountControlOp.linkIdentity: [
    AccountControlEndpoint('POST', '/auth/v1/token', grantType: 'id_token'),
    AccountControlEndpoint('POST', '/auth/v1/otp'),
    AccountControlEndpoint('PUT', '/auth/v1/user'),
    AccountControlEndpoint('POST', '/auth/v1/verify'),
  ],
  AccountControlOp.deleteAccount: [
    AccountControlEndpoint('POST', '/rest/v1/rpc/request_account_deletion'),
    AccountControlEndpoint('POST', '/auth/v1/token',
        grantType: 'refresh_token'),
  ],
  AccountControlOp.cancelDelete: [
    AccountControlEndpoint('POST', '/rest/v1/rpc/cancel_account_deletion'),
    AccountControlEndpoint('POST', '/auth/v1/token',
        grantType: 'refresh_token'),
  ],
};

const List<AccountControlEndpoint> _signInEndpoints = [
  AccountControlEndpoint('POST', '/auth/v1/token', grantType: 'id_token'),
  AccountControlEndpoint('POST', '/auth/v1/otp'),
  AccountControlEndpoint('POST', '/auth/v1/verify'),
];

/// Default lifetime of an account-control grant, on a MONOTONIC clock.
///
/// Why 30 s: the longest legitimate op is delete/cancel with an expired access
/// token = one refresh exchange + one RPC, sequential. gotrue itself bounds a
/// refresh's retry window at 30 s (`Constants.autoRefreshTickDuration`), and a
/// mobile HTTPS exchange normally takes a few seconds. 30 s covers that with
/// margin; anything longer would only widen the window in which a forgotten
/// zone timer could act. The grant starts immediately BEFORE the Supabase
/// exchange (after any native Google/Apple UI returned) and ends in `finally`.
const Duration kAccountControlTtl = Duration(seconds: 30);

/// One operation-scoped grant. Admission requires [active] (not ended, not
/// expired), the configured Supabase host and an endpoint on the op's list.
class AccountControlGrant {
  AccountControlGrant._(this.op, this.id, this.ttl, this._now,
      {this.onboarding, this.linking}) : _startedAt = _now();

  final ({AdmissionAuthority authority, String accessToken})? onboarding;
  final ({String owner, bool Function() current})? linking;

  final AccountControlOp op;
  final int id;
  final Duration ttl;
  final Duration Function() _now;
  final Duration _startedAt;
  bool _ended = false;

  bool get active => !_ended && (_now() - _startedAt) < ttl;

  void _end() => _ended = true;

  /// Why [uri]/[method] is outside this grant, or null when it is inside.
  String? scopeViolation(String method, Uri uri, String supabaseUrl) {
    final base = Uri.tryParse(supabaseUrl);
    if (base == null || base.host.isEmpty) return 'grant_host';
    if (uri.scheme != base.scheme ||
        uri.host != base.host ||
        uri.port != base.port ||
        uri.userInfo.isNotEmpty) {
      return 'grant_host';
    }
    final prefix = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    if (!uri.path.startsWith(prefix)) return 'grant_endpoint';
    final relative = uri.path.substring(prefix.length);
    if (op == AccountControlOp.onboardingStatus) {
      final identity = onboarding;
      final query = uri.queryParametersAll;
      return identity != null &&
              method.toUpperCase() == 'GET' &&
              relative == '/rest/v1/profiles' &&
              query.length == 2 &&
              listEquals(query['select'], ['onboarding_completed_at']) &&
              listEquals(query['id'], ['eq.${identity.authority.uid}'])
          ? null
          : 'grant_endpoint';
    }
    for (final e in kAccountControlAllowlist[op]!) {
      if (e.matches(method, relative, uri.queryParameters)) return null;
    }
    return 'grant_endpoint';
  }
}

/// Foreground immediate deletion exchanges have a separate, body-bound grant.
/// They cannot borrow any of the legacy account-control endpoints.
enum ImmediateDeletionAction { request, status, challenge }

class _ImmediateDeletionGrant {
  _ImmediateDeletionGrant({
    required this.action, required this.owner, required this.activeOwner,
    required this.epoch, required this.current, required this.url,
    required this.fingerprint, required this.authorization, required this.ttl,
    required this.now,
  }) : started = now();
  final ImmediateDeletionAction action;
  final String owner;
  final String? activeOwner;
  final int epoch;
  final bool Function() current;
  final Uri url;
  final String fingerprint;
  final String? authorization;
  final Duration ttl;
  final Duration Function() now;
  final Duration started;
  bool ended = false;
  bool dispatched = false;
  bool get active {
    try { return !ended && now() - started < ttl && current(); }
    catch (_) { return false; }
  }

  String? violation(AdmissionRequest? request, int currentEpoch) {
    if (!active || epoch != currentEpoch) return 'deletion_stale';
    if (dispatched) return 'deletion_dispatched';
    if (request == null || request.method != 'POST' || request.url != url ||
        request.bodyFingerprint != fingerprint ||
        request.authorization != authorization ||
        request.contentType?.split(';').first.trim() != 'application/json') {
      return 'deletion_scope';
    }
    return null;
  }
}

/// Transport admission metadata: method/URL and an optional exact-byte digest;
/// never the raw body. Immediate grants also bind the ephemeral Authorization.
@immutable
class AdmissionRequest {
  const AdmissionRequest(this.method, this.url,
      {this.bodyFingerprint, this.authorization, this.contentType});
  final String method;
  final Uri url;
  final String? bodyFingerprint;
  final String? authorization;
  final String? contentType;
}

/// A per-call exception to the persistent gate, carried in the [Zone] so the
/// transport can see it. Only three exist: the one-shot revoke (DISABLING
/// only), the retry of a revoke that did not land ([EgressGrant.revokeRetry],
/// OFF at that revoke's own generation only, `set-device-consent` only) and an
/// operation-scoped account-control grant (never automatic traffic).
class EgressGrant {
  EgressGrant.accountControl(AccountControlGrant this.control)
      : kind = EgressGrantKind.accountControl,
        owner = null,
        generation = null,
        _deletion = null;
  EgressGrant._forDeletion(this._deletion)
      : kind = EgressGrantKind.accountControl, control = null, owner = null, generation = null;
  const EgressGrant.revoke(
      {required String this.owner, required int this.generation})
      : kind = EgressGrantKind.revoke,
        control = null,
        _deletion = null;

  /// Approved 2026-11-12 (product owner) — the ONE automatic exception to the
  /// Cloud-OFF rule: re-sending a revoke whose one-shot send did not land. It
  /// carries identifiers only (no SMS text, no financial data) and is admitted
  /// only while [owner]'s record is still OFF at exactly [generation] (no newer
  /// grant or transition), with no pending enable, and only as a POST to
  /// `set-device-consent` (see [CloudEgressGate.isRevokeRetryRequest]).
  const EgressGrant.revokeRetry(
      {required String this.owner, required int this.generation})
      : kind = EgressGrantKind.revokeRetry,
        control = null,
        _deletion = null;

  final EgressGrantKind kind;
  final String? owner;
  final int? generation;
  final AccountControlGrant? control;
  final _ImmediateDeletionGrant? _deletion;
}

/// One admitted request.
class EgressTicket {
  EgressTicket._(this.owner, this.epoch, this.grant, this.request,
      {this.refresh});
  final String owner;
  final int epoch;
  final EgressGrant? grant;
  final AdmissionRequest? request;

  /// Set for a coordinator refresh op's ticket (ASR §9.3).
  final RefreshAdmission? refresh;
  final Completer<void> _cancel = Completer<void>();
  bool _released = false;

  /// Completes when [CloudEgressGate.drain] gave up waiting for this request.
  Future<void> get cancelled => _cancel.future;
  bool get isCancelled => _cancel.isCompleted;
}

/// The frozen inputs of one DISABLING transition (C.4).
@immutable
class DisableFreeze {
  const DisableFreeze({
    required this.owner,
    required this.transitionGeneration,
    required this.reservedVersion,
  });
  final String owner;
  final int transitionGeneration;
  final int reservedVersion;

  EgressGrant get revokeGrant =>
      EgressGrant.revoke(owner: owner, generation: transitionGeneration);

  CloudEgressRecord record(EgressState state) => CloudEgressRecord(
        state: state,
        ownerUid: owner,
        transitionGeneration: transitionGeneration,
        reservedVersion: reservedVersion,
      );
}

/// N-CR-1: what a read-back of one owner's restrictive record found, per
/// independently admitting runtime. [dart] is true when at least one Dart store
/// (secure storage or file) holds a restrictive record at or above the expected
/// generation; [native] is null when no native layer exists, otherwise true only
/// when the native layer holds such a record. Anything unreadable is false.
@immutable
class RestrictionReadback {
  const RestrictionReadback(this.dart, this.native);
  final bool dart;
  final bool? native;
  bool get verified => dart && native != false;
}

class DrainResult {
  const DrainResult({required this.waited, required this.cancelled});
  final bool waited;
  final int cancelled;
}

class _Mutex {
  Future<void> _tail = Future<void>.value();

  Future<T> synchronized<T>(Future<T> Function() body) async {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await prev;
    try {
      return await body();
    } finally {
      done.complete();
    }
  }
}

/// ASR design v7.2 §5 — typed epoch causes.
///
/// Every mutation of the gate epoch carries a cause, and Dart-originated native
/// writes of protected capture state append one BEFORE their channel call. The
/// cause log lets an in-flight coordinator refresh decide synchronously whether
/// anything foreign happened since it started.
enum CauseClass { policy, identity }

/// The three coordinator refresh-operation kinds (§4.10).
enum RefreshOpKind { routine, accountControl, asr }

@immutable
class EpochCause {
  const EpochCause(this.kind,
      {this.causeClass = CauseClass.policy, this.identityForAsr = false});

  /// Diagnostic name; never carries an id.
  final String kind;
  final CauseClass causeClass;

  /// `explicitAttempt` is IDENTITY for ASR and POLICY for the other kinds.
  final bool identityForAsr;

  CauseClass classFor(RefreshOpKind op) =>
      identityForAsr && op == RefreshOpKind.asr ? CauseClass.identity : causeClass;

  static const scopeSwap = EpochCause('scopeSwap');
  static const scopeInit = EpochCause('scopeInit');
  static const explicitAttempt =
      EpochCause('explicitAttempt', identityForAsr: true);
  static const consentLoss = EpochCause('consentLoss');
  static const localRead = EpochCause('localRead');
  static const captureTransition = EpochCause('captureTransition');
  static const cloudDisable = EpochCause('cloudDisable');
  static const cloudEnable = EpochCause('cloudEnable');
  static const consentWithdrawn = EpochCause('consentWithdrawn');
  static const lifecycleDenied = EpochCause('lifecycleDenied');
  static const freeze = EpochCause('freeze');
  static const pendingEnable = EpochCause('pendingEnable');
  static const uncertain = EpochCause('uncertain');
  static const removal =
      EpochCause('removal', causeClass: CauseClass.identity);
  static const accountSwitch =
      EpochCause('accountSwitch', causeClass: CauseClass.identity);
  static const accountFenceRetired =
      EpochCause('accountFenceRetired', causeClass: CauseClass.identity);

  /// An advance whose site did not say why: treated as the most restrictive.
  static const untyped =
      EpochCause('untyped', causeClass: CauseClass.identity);

  /// A Dart-originated native write of protected capture state.
  const EpochCause.native(String method, {bool identity = false})
      : kind = 'native:$method',
        causeClass = identity ? CauseClass.identity : CauseClass.policy,
        identityForAsr = false;

  @override
  String toString() => 'EpochCause($kind)';
}

@immutable
class CauseEntry {
  const CauseEntry(this.position, this.cause, this.authority);
  final int position;
  final EpochCause cause;

  /// The operation the cause belongs to (its own transitions are not foreign
  /// for it), or null.
  final Object? authority;
}

/// One coordinator refresh operation's admission (§9.3). [authority] tags the
/// op's own causes.
class RefreshAdmission {
  RefreshAdmission({
    required this.kind,
    required this.startPosition,
    required this.authority,
  });

  final RefreshOpKind kind;

  /// The cause-log position the op captured when it started.
  final int startPosition;
  final Object authority;

  /// Set when P_send passed (the credential bytes were handed to the request).
  bool passedSend = false;

  /// A POLICY cause after send: custody only, never installation (§5).
  bool noInstall = false;
}

/// An owned transition hold (§11.1). Only its owner can end it.
class TransitionHoldToken {
  TransitionHoldToken._();
}

class CloudEgressGate {
  CloudEgressGate({
    CloudEgressStore? store,
    Future<String?> Function()? activeOwner,
    this.drainTimeout = const Duration(seconds: 5),
    this.nativeMaxWait = const Duration(seconds: 10),
    this.nativePoll = const Duration(milliseconds: 200),
    Future<({int count, DateTime? latestDeadline})?> Function(String owner)?
        nativeInflight,
    bool resolved = false,
    String Function()? supabaseUrl,
    this.accountControlTtl = kAccountControlTtl,
    Duration Function()? monotonic,
  })  : _nativeInflight = nativeInflight,
        _store = store,
        _activeOwner = activeOwner,
        _resolved = resolved,
        _supabaseUrl = supabaseUrl ?? (() => SupabaseConfig.url),
        _monotonic = monotonic ?? _processClock {
    // ASR §5 (C2): every Dart-originated protected native write appends its
    // typed cause to the CURRENT process gate before the channel call.
    NativeCaptureBridge.onProtectedNativeWrite ??=
        (method, {required identity, authority}) => CloudEgressGate.instance
            .noteCause(EpochCause.native(method, identity: identity),
                authority: authority);
  }

  static final Stopwatch _processStopwatch = Stopwatch()..start();
  static Duration _processClock() => _processStopwatch.elapsed;

  /// The process-wide gate. Bootstrap configures [activeOwner]; tests replace it.
  static CloudEgressGate instance = CloudEgressGate();

  static const Symbol _grantKey = #qirshEgressGrant;

  final Duration drainTimeout;

  /// Lifetime of one account-control grant (monotonic clock).
  final Duration accountControlTtl;
  final Duration Function() _monotonic;
  final String Function() _supabaseUrl;
  int _grantSeq = 0;
  bool _resolved;

  /// H2.3: false until bootstrap completed the egress reconciliation. While
  /// false admission denies EVERYTHING (grants and the revoke included) and
  /// [permits] is false.
  bool get isResolved => _resolved;

  /// Resolution OWNERSHIP: the one startup initialization attempt that is still
  /// the designated resolver. Established when a scope's initialization begins
  /// and superseded by the next [beginResolution] (a successor scope resolves
  /// itself). Separate from an attempt's mutation authority: an attempt may have
  /// lost the right to repair or mutate and still own the duty to finish its
  /// resolution restrictively.
  EgressResolutionToken? _resolutionOwner;

  EgressResolutionToken beginResolution() {
    _resolutionGeneration++;
    _resolvedSignedOut = false;
    return _resolutionOwner = EgressResolutionToken._();
  }

  bool ownsResolution(EgressResolutionToken token) =>
      identical(_resolutionOwner, token);

  /// Owner-checked completion of the process latch. A superseded attempt
  /// resolves nothing and gets false. The latch is never reset.
  bool markResolved(EgressResolutionToken token) {
    if (!ownsResolution(token)) return false;
    _resolved = true;
    _resolutionGeneration++;
    return true;
  }

  /// Resolution for a scope that runs NO writable reconciliation (offline local
  /// read, or a usable scope whose initialization never resolved). Read-only
  /// with respect to the account database: it inspects the durable gate state
  /// and freezes (never thaws) on anything uncertain, unreadable or incomplete
  /// (or always, with [freezeTag]); the settings alignment, pending-disable
  /// completion and owner repair are left to the authorized writable
  /// reconciliation. Resolves only while [token] still owns the resolution.
  Future<void> resolveRestrictively(EgressResolutionToken token,
      {String? owner, String? freezeTag}) async {
    void freeze(String tag) {
      if (ownsResolution(token)) ConsentAuthority.freeze(tag, retainTag: true);
    }

    if (freezeTag != null) freeze(freezeTag);
    try {
      final v = await view(owner: owner);
      if (v.uncertain) {
        freeze('startup_uncertain:${v.readout.problems.join(',')}');
      } else if (v.record?.state == EgressState.disabling) {
        freeze('startup_pending_disable');
      } else if (await _pendingDenies(v.owner)) {
        freeze('startup_pending_enable');
      }
    } catch (e) {
      freeze('startup_throw:${e.runtimeType}');
    }
    if (!markResolved(token)) return;
    try {
      await refresh();
    } catch (_) {
      // Resolved; a failed mirror refresh leaves the mirror closed.
    }
  }

  /// Fired whenever the synchronous permit mirror changes (Sentry, ads,
  /// banners follow it).
  final ValueNotifier<bool> permitNotifier = ValueNotifier<bool>(false);

  /// Upper bound on waiting for native extension uploads already admitted.
  final Duration nativeMaxWait;
  final Duration nativePoll;
  final Future<({int count, DateTime? latestDeadline})?> Function(String owner)?
      _nativeInflight;
  CloudEgressStore? _store;
  Future<String?> Function()? _activeOwner;

  CloudEgressStore get store => _store ??= CloudEgressStore.platform();

  /// The replica owner the request on hand belongs to (null = signed out).
  void configureActiveOwner(Future<String?> Function() activeOwner) =>
      _activeOwner = activeOwner;

  /// Whether a fresh SDK session has committed application admission. Wired by
  /// bootstrap. Unwired answers true, i.e. no extra signed-out allowance.
  void configureSessionUsable(bool Function() usable) => _sessionUsable = usable;
  bool Function() _sessionUsable = () => true;

  /// An account-control exchange that runs signed out: either no owner at all,
  /// or an explicit sign-in / re-authentication while no usable session exists
  /// (a stale owner marker with an expired, unrefreshable session: the freeze
  /// blocked the token refresh, so the app is signed out while the marker still
  /// names the user). It can only reach the allowlisted auth endpoints.
  bool _signedOutControl(AccountControlGrant? control, String owner) {
    if (control == null) return false;
    if (owner.isEmpty) return true;
    final op = control.op;
    if (op != AccountControlOp.signIn && op != AccountControlOp.reauthenticate) {
      return false;
    }
    try {
      return !_sessionUsable();
    } catch (_) {
      return false;
    }
  }

  /// Called after every state change (auto-refresh policy, sync mirror).
  Future<void> Function(bool permitsNetwork)? onPermitChanged;

  /// Astra D6 (offline local read). Wired by bootstrap to the session. While it
  /// answers true a verified local-read scope is published, and NOTHING is
  /// admitted except an operation-scoped account-control grant (explicit sign-in
  /// / reconnect): not a saved Cloud ON record, not the SDK's own refresh or
  /// resume ticks, not a service that names its owner explicitly. Fails closed:
  /// a throwing callback counts as active.
  bool Function()? localReadActive;

  bool get _localReadDenies {
    final active = localReadActive;
    if (active == null) return false;
    try {
      return active();
    } catch (_) {
      return true;
    }
  }

  final _Mutex _lock = _Mutex();

  /// N-E: owners with an explicit enable in flight IN THIS PROCESS. Set
  /// synchronously (before any await) by [freezeEnable] and dropped only when a
  /// read-back proves the owner's durable pending is gone. It is the in-process
  /// half of the Dart denial; the durable half is the pending layers.
  final Set<String> _enablePendingOwners = {};
  final Set<EgressTicket> _inFlight = {};
  Completer<void>? _idle;
  int _epoch = 0;
  bool _permitMirror = false;

  /// In-process transition epoch (P4). Advanced SYNCHRONOUSLY at the start of a
  /// disable, an enable, an account transition or a sign-out; every async
  /// mutation captures it and re-checks it before it writes.
  int get epoch => _epoch;

  /// Advances the epoch with a typed [cause] (§5). Production call sites always
  /// name their cause; the untyped default is classed IDENTITY.
  int advanceEpoch([EpochCause cause = EpochCause.untyped, Object? authority]) =>
      _advance(cause, authority: authority);

  int _advance(EpochCause cause, {Object? authority}) {
    _epoch++;
    noteCause(cause, authority: authority);
    return _epoch;
  }

  // ── ASR §5: the cause log ──────────────────────────────────────────────────

  static const int causeLogCapacity = 512;
  final List<CauseEntry> _causes = [];
  int _causeSeq = 0;

  /// Every position at or below this was dropped from the bounded log; an op
  /// that started at or below it is treated as having observed an IDENTITY
  /// cause.
  int _droppedThrough = 0;

  /// The current cause-log position (an op captures it at start).
  int get causePosition => _causeSeq;

  /// Appends [cause] synchronously and runs the refresh-ticket hook: IDENTITY →
  /// cancel every refresh ticket; POLICY → cancel every refresh ticket that has
  /// not passed P_send, and mark the others "no installation". An op's own
  /// causes ([authority]) are not foreign for it. ASR §11.2: [authority] is
  /// passed explicitly, only at the transitions an op owns (its scope
  /// initialization, SE1–SE5); there is no ambient attribution, so a cause from
  /// a listener, a service or the user is foreign to every op.
  void noteCause(EpochCause cause, {Object? authority}) {
    _causeSeq++;
    _causes.add(CauseEntry(_causeSeq, cause, authority));
    if (_causes.length > causeLogCapacity) {
      _droppedThrough = _causes.removeAt(0).position;
    }
    for (final t in _inFlight.toList()) {
      final r = t.refresh;
      if (r == null || identical(r.authority, authority)) continue;
      final cls = cause.classFor(r.kind);
      if (cls == CauseClass.identity || !r.passedSend) {
        if (!t._cancel.isCompleted) t._cancel.complete();
      } else {
        r.noInstall = true;
      }
    }
  }

  /// Whether a cause foreign to [authority] of at least [atLeast] (as classed
  /// for [kind]) was appended after [position]. An overflowed log answers true.
  bool foreignCauseSince(int position,
      {required RefreshOpKind kind,
      Object? authority,
      CauseClass atLeast = CauseClass.policy}) {
    if (position < _droppedThrough) return true;
    for (final e in _causes.reversed) {
      if (e.position <= position) break;
      if (authority != null && identical(e.authority, authority)) continue;
      if (atLeast == CauseClass.policy ||
          e.cause.classFor(kind) == CauseClass.identity) {
        return true;
      }
    }
    return false;
  }

  // ── ASR §11.1: transition holds, terminal denial, alignment zone ────────────

  final Set<TransitionHoldToken> _holds = {};

  bool get holdActive => _holds.isNotEmpty;

  /// B2: whether an ASR successor is unsettled (its session record is still
  /// `finalizing`). Wired by bootstrap; generic capture reconciliation waits
  /// for the ordered successor reconciliation instead of judging it.
  bool Function()? asrSuccessorUnsettled;
  bool get successorUnsettled => asrSuccessorUnsettled?.call() ?? false;

  /// Begins an owned hold: every Dart permit path denies until every hold
  /// ended. Outstanding ordinary tickets are cancelled (refresh tickets are
  /// governed by causes).
  TransitionHoldToken beginTransitionHold() {
    final token = TransitionHoldToken._();
    _holds.add(token);
    for (final t in _inFlight.toList()) {
      if (t.refresh == null && t.grant == null && !t._cancel.isCompleted) {
        t._cancel.complete();
      }
    }
    _setMirror(false);
    return token;
  }

  /// Removes only [token] and recomputes the mirror.
  Future<void> endTransitionHold(TransitionHoldToken token) async {
    if (!_holds.remove(token)) return;
    if (_holds.isEmpty) {
      try {
        await refresh();
      } catch (_) {}
    }
  }

  bool _terminalDenied = false;
  bool get terminalDenied => _terminalDenied;

  /// §11.4: set synchronously before an ASR failure's cleanup; denies every Dart
  /// permit path except explicit account control. Cleared only by an
  /// explicit commit ([clearTerminalDenial]).
  void terminalDeny() {
    _terminalDenied = true;
    _setMirror(false);
  }

  void clearTerminalDenial() {
    if (!_terminalDenied) return;
    _terminalDenied = false;
    unawaited(refresh().catchError((Object _) {}));
  }

  static const Symbol _alignmentKey = #qirshAlignmentZone;

  /// §4.8: runs [body] in a zone in which every request is denied BEFORE
  /// admission (so the SDK's `admin.signOut` never reaches the transport).
  Future<T> runAlignment<T>(Future<T> Function() body) =>
      runZoned(() async => await body(), zoneValues: {_alignmentKey: true});

  static bool get inAlignmentZone => Zone.current[_alignmentKey] == true;

  // ── §2: resolution generation ───────────────────────────────────────────────

  int _resolutionGeneration = 0;
  int get resolutionGeneration => _resolutionGeneration;
  bool _resolvedSignedOut = false;

  /// True after [resolveSignedOut] until the next resolution begins.
  bool get resolvedSignedOut => _resolvedSignedOut;

  /// §11.4: the signed-out resolution after an ASR failure: the process stays
  /// resolved (no restrictive owner freeze); the mirror is recomputed.
  Future<void> resolveSignedOut() async {
    _resolutionGeneration++;
    _resolvedSignedOut = true;
    try {
      await refresh();
    } catch (_) {}
  }

  /// N2: set SYNCHRONOUSLY, with the epoch advance, when an authority loss leaves
  /// a native lifecycle fence unconfirmed. While set, ordinary egress is denied;
  /// account-control and revoke grants are unaffected, so the user can still
  /// re-authenticate. Cleared only by a confirmed fence or a verified restrictive
  /// publication; it never enables anything.
  bool _lifecycleDenied = false;
  void denyForLifecycleLoss() {
    _lifecycleDenied = true;
    _advance(EpochCause.lifecycleDenied);
    _setMirror(false);
  }

  void releaseLifecycleDenial() => _lifecycleDenied = false;

  int get inFlightCount => _inFlight.length;

  /// Synchronous best-effort mirror of "this process may fetch (images)". False
  /// until a clean read says ON for the active owner; false whenever denied.
  bool get permitsNetworkSync {
    return _permitMirror &&
        _resolved &&
        !_lifecycleDenied &&
        _holds.isEmpty &&
        !_terminalDenied &&
        _enablePendingOwners.isEmpty &&
        !ConsentAuthority.egressFrozen &&
        !_localReadDenies;
  }

  Future<String> _owner(String? explicit) async {
    if (explicit != null) return explicit;
    try {
      final configured = _activeOwner;
      if (configured != null) return await configured() ?? '';
      // Unconfigured (a background path): AppSession's owner marker, read raw.
      return await SecureStorageOptions.storage
              .read(key: 'local_data_owner_uid') ??
          '';
    } catch (_) {
      return '';
    }
  }

  // Receipt recovery may explicitly operate signed out. A failed owner read
  // must never be mistaken for a successfully resolved signed-out context.
  Future<String?> _deletionOwner() async {
    try {
      final configured = _activeOwner;
      return configured != null
          ? await configured()
          : await SecureStorageOptions.storage.read(key: 'local_data_owner_uid');
    } catch (_) {
      throw EgressDeniedException('deletion_owner_unavailable');
    }
  }

  /// The merged durable view for [owner] (default: the active owner).
  Future<EgressView> view({String? owner}) async {
    final o = await _owner(owner);
    final readout = await store.read(owner: o);
    return EgressView(o, readout);
  }

  /// Service-level check: true ONLY for a resolved process, a clean read and a
  /// durable ON record for the active owner. DISABLING / OFF / uncertain /
  /// frozen / ABSENT (never explicitly enabled, e.g. an upgrade) / unresolved
  /// all answer false (Astra H2.2).
  Future<bool> permits({String? owner}) async {
    bool closed() =>
        !_resolved ||
        _lifecycleDenied ||
        ConsentAuthority.egressFrozen ||
        _localReadDenies ||
        _holds.isNotEmpty ||
        _terminalDenied;
    if (closed()) return false;
    final o = await _owner(owner);
    // N-E: an unresolved pending enable denies before anything else is judged.
    if (await _pendingDenies(o)) return false;
    final v = await view(owner: o);
    // ASR §11.1: recheck synchronously after the last await.
    return !closed() && !v.uncertain && v.record?.state == EgressState.on;
  }

  /// Wired by bootstrap: a read-only, status-preserving accessor of a secure
  /// item (ASR §12), so only an OS-confirmed not-found reads as absence. Null
  /// (or a throw) denies every session-only refresh.
  DurableSlot Function(String key)? strictSecureSlot;

  /// Wired by bootstrap: whether native positively reports [owner] OFF (its
  /// strict recovery inspection, not the restrictive getter). Null (or a
  /// throw) denies every session-only refresh.
  Future<bool> Function(String owner)? nativeVerifiedOff;

  /// Owner decision (2026-10-29): the session-only token refresh — the
  /// AuthCoordinator's `grant_type=refresh_token` exchange, which carries no
  /// financial data, SMS or sync payload — is allowed while Cloud is OFF.
  /// Cloud ON is exactly [permits]. Otherwise every process denial
  /// (unresolved, lifecycle fence, freeze, local read, hold, terminal) still
  /// denies, the pending layers must confirm no pending enable through the
  /// strict secure read, the merged view [permits] reads (native included)
  /// must be certain and absent or OFF, native must positively report OFF
  /// ([nativeVerifiedOff]), and the Dart egress layers must be
  /// verified OFF ([dartLayersVerifiedOff], confirmed absence included). Only the
  /// coordinator's routine op consults it; every other egress keeps [permits].
  Future<bool> permitsSessionRefresh({String? owner}) async {
    if (await permits(owner: owner)) return true;
    bool closed() =>
        !_resolved ||
        _lifecycleDenied ||
        ConsentAuthority.egressFrozen ||
        _localReadDenies ||
        _holds.isNotEmpty ||
        _terminalDenied;
    if (closed()) return false;
    final o = await _owner(owner);
    final strict = strictSecureSlot;
    if (strict == null || _enablePendingOwners.contains(o)) return false;
    try {
      final pending = await store
          .readPendingVia(strict(CloudEgressStore.kPendingSecureKey));
      if (pending.blocks(o)) return false;
    } catch (_) {
      return false;
    }
    // Astra (Cloud OFF delta): native uncertainty, mismatch and a winning
    // DISABLING still deny, exactly as they do for [permits].
    final v = await view(owner: o);
    final merged = v.record;
    if (v.uncertain || (merged != null && merged.state != EgressState.off)) {
      return false;
    }
    // The restrictive getter can answer OFF over an unreadable layer, a
    // pending or a disagreement: native must also positively report OFF.
    final native = nativeVerifiedOff;
    try {
      if (native == null || !await native(o)) return false;
    } catch (_) {
      return false;
    }
    if (!await dartLayersVerifiedOff(o, allowAbsent: true)) return false;
    return !closed() && !_enablePendingOwners.contains(o);
  }

  /// Both Dart egress layers of [owner], the secure one read through
  /// [strictSecureSlot]: true only when both hold the same OFF record, or
  /// ([allowAbsent]) both confirm absence. Unreadable, corrupt, partial,
  /// disagreeing, ON and DISABLING all deny.
  Future<bool> dartLayersVerifiedOff(String owner,
      {required bool allowAbsent}) async {
    final strict = strictSecureSlot;
    if (strict == null) return false;
    try {
      final seen = await store.readDartOwnerLayersVia(
          owner, strict(CloudEgressStore.kSecureKey));
      if (seen.uncertain) return false;
      if (seen.records.isEmpty) return allowAbsent;
      final first = seen.records.first;
      return seen.records.length == 2 &&
          first.state == EgressState.off &&
          first.ownerUid == owner &&
          seen.records.every((r) => r == first);
    } catch (_) {
      return false;
    }
  }

  /// Diagnostic only (Beta 1): the Dart egress layers of [owner] as a constant
  /// (absent, off, on, disabling, partial, mixed, uncertain, no_strict).
  Future<String> describeDartLayers(String owner) async {
    final strict = strictSecureSlot;
    if (strict == null) return 'no_strict';
    try {
      final seen = await store.readDartOwnerLayersVia(
          owner, strict(CloudEgressStore.kSecureKey));
      if (seen.uncertain) return 'uncertain';
      if (seen.records.isEmpty) return 'absent';
      if (seen.records.length != 2) return 'partial';
      final first = seen.records.first;
      if (!seen.records.every((r) => r == first)) return 'mixed';
      return first.state.name;
    } catch (_) {
      return 'uncertain';
    }
  }

  /// N-E: whether a pending enable of [owner] is in flight in this process, or
  /// present in (or unreadable in) either durable Dart pending layer.
  Future<bool> _pendingDenies(String owner) async {
    if (_enablePendingOwners.contains(owner)) return true;
    try {
      return (await store.readPending()).blocks(owner);
    } catch (_) {
      return true;
    }
  }

  /// The two Dart pending layers as they are now.
  Future<PendingReadout> readPending() => store.readPending();

  /// ASR §12 E3: [readPending] with a status-preserving secure-layer read.
  Future<PendingReadout> readPendingVia(DurableSlot secure) =>
      store.readPendingVia(secure);

  /// True while [owner]'s ON admission is denied by a pending enable.
  Future<bool> pendingBlocks({String? owner}) async =>
      _pendingDenies(await _owner(owner));

  /// H2.5 `url_launcher`: whether the app may hand [uri] to the OS browser. An
  /// external launch is user-visible network egress (the OS fetches the page), so
  /// it follows [permits]. The only exception is an allowlisted host inside an
  /// ACTIVE account-control grant (the configured Supabase host); no other
  /// exception exists.
  Future<bool> mayLaunchExternal(Uri uri) async {
    if (await permits()) return true;
    final control = (Zone.current[_grantKey] as EgressGrant?)?.control;
    if (control == null ||
        !control.active ||
        !_resolved ||
        _holds.isNotEmpty ||
        inAlignmentZone ||
        (ConsentAuthority.egressFrozen &&
            !_signedOutControl(control, await _owner(null)))) {
      return false;
    }
    final base = Uri.tryParse(_supabaseUrl());
    return base != null &&
        base.host.isNotEmpty &&
        uri.scheme == 'https' &&
        uri.host == base.host;
  }

  Future<String?> _decide(
      String owner, EgressGrant? grant, AdmissionRequest? request) async {
    if (!_resolved) return 'unresolved';
    if (inAlignmentZone) return 'alignment';
    // ASR §11.1: a transition hold denies every Dart permit path.
    if (_holds.isNotEmpty) return 'transition_hold';
    final revoke = grant?.kind == EgressGrantKind.revoke;
    final revokeRetry = grant?.kind == EgressGrantKind.revokeRetry;
    final control = grant?.control;
    final onboarding = control?.op == AccountControlOp.onboardingStatus;
    final linking = control?.op == AccountControlOp.linkIdentity;
    final lifecycleRestricted = control == null || onboarding || linking;
    // The setup lookup requires an admitted account and cannot recover one.
    if (lifecycleRestricted && _localReadDenies) return 'local_read';
    if (lifecycleRestricted && _terminalDenied) return 'terminal';
    if (control != null) {
      // A grant that ended or expired admits NOTHING (a zone timer or retry
      // that fires after the op finished lands here).
      if (!control.active) return 'grant_inactive';
      if (request == null) return 'grant_scope';
    }
    // A signed-out context (no owner) has no consent subject: an upgraded device
    // can hold a surviving native active owner while Dart has none, which the
    // ownerless native read reports as uncertain and freezes. Only the scoped
    // account-control exchange (the allowlisted auth endpoints, which carry no
    // user data) may pass that freeze or uncertainty, because it is the sole way
    // to learn the owner. Signing in then re-runs the per-owner reconciliation,
    // which keeps or lifts the freeze for the real uid. Ordinary egress is
    // untouched.
    final signedOutControl = _signedOutControl(control, owner);
    if (ConsentAuthority.egressFrozen && !revoke && !signedOutControl) {
      return 'frozen';
    }
    // N2: an unconfirmed native lifecycle fence denies ordinary egress. The
    // account-control allowance (re-authentication) and the revoke are exempt.
    if (_lifecycleDenied && lifecycleRestricted && !revoke) {
      return 'lifecycle_fence';
    }
    final readout = await store.read(owner: owner);
    if (readout.uncertain && !signedOutControl) return 'state_uncertain';
    final rec = readout.records[owner];
    if (revokeRetry) {
      // Not exempt from the freeze or the lifecycle fence above: an uncertain
      // state just waits for the next attempt. Only the owner's OWN revoke, only
      // while nothing superseded it, only to the revoke endpoint.
      if (grant!.owner != owner ||
          rec == null ||
          rec.state != EgressState.off ||
          rec.transitionGeneration != grant.generation) {
        return 'revoke_retry_superseded';
      }
      if (await _pendingDenies(owner)) return 'pending_enable';
      if (request != null && !isRevokeRetryRequest(request, _supabaseUrl())) {
        return 'revoke_retry_scope';
      }
      return null;
    }
    if (rec != null && rec.state == EgressState.disabling) {
      return revoke &&
              grant!.owner == owner &&
              grant.generation == rec.transitionGeneration
          ? null
          : 'disabling';
    }
    if (revoke) return 'revoke_outside_disabling';
    if (onboarding) {
      if (await _pendingDenies(owner)) return 'pending_enable';
      final identity = control?.onboarding;
      if (identity == null ||
          !identity.authority.isCurrent ||
          identity.authority.uid != owner ||
          request?.authorization != 'Bearer ${identity.accessToken}' ||
          request?.bodyFingerprint != _emptyBodyFingerprint) {
        return 'grant_identity';
      }
    }
    if (linking) {
      final identity = control?.linking;
      if (identity == null || identity.owner != owner || !identity.current()) {
        return 'grant_identity';
      }
    }
    if (control != null) {
      // Account control: exact host + method + path (+ grant_type) only, in ON,
      // OFF and unset alike. Everything else inside the allowance is denied.
      return control.scopeViolation(
          request!.method, request.url, _supabaseUrl());
    }
    // N-E: a pending enable denies every ordinary request (account control and
    // the one-shot revoke are exempt above, exactly like the lifecycle fence).
    if (await _pendingDenies(owner)) return 'pending_enable';
    if (grant?._deletion != null) return grant!._deletion!.violation(request, _epoch);
    if (rec == null || rec.state == EgressState.off) return 'off';
    return null;
  }

  /// THE admission gate. Throws [EgressDeniedException] when refused.
  Future<EgressTicket> admit(
      {String? owner, EgressGrant? grant, AdmissionRequest? request}) async {
    final g = grant ?? Zone.current[_grantKey] as EgressGrant?;
    // The lock position is taken synchronously, so admission order is call
    // order: a request made before a disable was called is decided before it.
    return _lock.synchronized(() async {
      final deletion = g?._deletion;
      final activeOwner = deletion == null ? await _owner(owner) : await _deletionOwner();
      if (deletion != null && activeOwner != deletion.activeOwner) {
        throw EgressDeniedException('deletion_owner');
      }
      final o = deletion?.owner ?? activeOwner!;
      var deny = await _decide(o, g, request);
      // ASR §11.1: recheck the hold synchronously after the last await.
      if (deny == null && _holds.isNotEmpty) deny = 'transition_hold';
      // A granted request says nothing about whether AUTOMATIC traffic may run.
      if (g == null) _setMirror(deny == null);
      if (deny != null) throw EgressDeniedException(deny);
      if (deletion != null) {
        if (!_resolved || ConsentAuthority.egressFrozen) {
          throw EgressDeniedException(!_resolved ? 'unresolved' : 'frozen');
        }
        final stale = deletion.violation(request, _epoch);
        if (stale != null) throw EgressDeniedException(stale);
        deletion.dispatched = true;
      }
      final t = EgressTicket._(o, _epoch, g, request);
      _inFlight.add(t);
      return t;
    });
  }

  // ── ASR §3.1: the single refresher ──────────────────────────────────────────

  /// The ONE token-endpoint helper: the configured base path + `/auth/v1/token`.
  static String authTokenPath(Uri base) {
    final prefix = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return '$prefix/auth/v1/token';
  }

  /// The coordinator's refresh endpoint on the configured origin, or null when
  /// Supabase is not configured.
  Uri? refreshTokenUri() {
    final base = Uri.tryParse(_supabaseUrl());
    if (base == null || base.host.isEmpty) return null;
    return base.replace(
        path: authTokenPath(base),
        queryParameters: const {'grant_type': 'refresh_token'},
        fragment: null);
  }

  /// I3: why [request] is a refresh-token request that only the AuthCoordinator
  /// may send (it never goes through this client), or null. Decided from a
  /// snapshot of the query and body bytes, before any await. Anything on the
  /// token path that cannot be read unambiguously is denied.
  String? sdkRefreshViolation(http.BaseRequest request) {
    final base = Uri.tryParse(_supabaseUrl());
    if (base == null || base.host.isEmpty) return null;
    final uri = request.url;
    if (uri.scheme != base.scheme ||
        uri.host.toLowerCase() != base.host.toLowerCase() ||
        uri.port != base.port) {
      return null;
    }
    final String path;
    try {
      path = Uri.decodeFull(uri.path)
          .replaceAll(RegExp('/{2,}'), '/')
          .replaceAll(RegExp(r'/+$'), '')
          .toLowerCase();
    } catch (_) {
      return 'sdk_refresh';
    }
    if (path != authTokenPath(base).toLowerCase()) return null;

    final grants = <String>[];
    var carriesRefreshToken = false;
    bool readForm(String raw) {
      if (raw.isEmpty) return true;
      for (final pair in raw.split('&')) {
        if (pair.isEmpty) continue;
        final i = pair.indexOf('=');
        final String k, v;
        try {
          k = Uri.decodeQueryComponent(i < 0 ? pair : pair.substring(0, i));
          v = i < 0 ? '' : Uri.decodeQueryComponent(pair.substring(i + 1));
        } catch (_) {
          return false;
        }
        if (k == 'grant_type') grants.add(v);
        if (k == 'refresh_token') carriesRefreshToken = true;
      }
      return true;
    }

    if (!readForm(uri.query)) return 'sdk_refresh';
    if (request is! http.Request) return 'sdk_refresh';
    final body = request.bodyBytes;
    if (body.isNotEmpty) {
      final type = (request.headers.entries
                  .where((e) => e.key.toLowerCase() == 'content-type')
                  .map((e) => e.value)
                  .firstOrNull ??
              '')
          .split(';')
          .first
          .trim()
          .toLowerCase();
      final String text;
      try {
        text = utf8.decode(body);
      } catch (_) {
        return 'sdk_refresh';
      }
      if (type == 'application/x-www-form-urlencoded') {
        if (!readForm(text)) return 'sdk_refresh';
      } else if (type == 'application/json') {
        final Object? json;
        try {
          json = jsonDecode(text);
        } catch (_) {
          return 'sdk_refresh';
        }
        if (json is Map) {
          if (json.containsKey('refresh_token')) carriesRefreshToken = true;
          if (json.containsKey('grant_type')) {
            final g = json['grant_type'];
            if (g is! String) return 'sdk_refresh';
            grants.add(g);
          }
        } else if (json != null) {
          return 'sdk_refresh';
        }
      } else {
        return 'sdk_refresh';
      }
    }
    if (carriesRefreshToken ||
        grants.length > 1 ||
        grants.contains('refresh_token')) {
      return 'sdk_refresh';
    }
    return null;
  }

  /// §9.3 / §4.10 P_admit for a coordinator refresh op: runs in the gate lock
  /// and registers a refresh ticket in the in-flight set (drains see it and the
  /// cause hook can cancel it). [predicate] is the op's own synchronous check,
  /// evaluated after the last await. Throws [EgressDeniedException] on refusal.
  Future<EgressTicket> admitRefreshOp({
    required RefreshOpKind kind,
    required String owner,
    required int startPosition,
    required Object authority,
    bool Function()? predicate,
  }) {
    final zoneGrant = Zone.current[_grantKey] as EgressGrant?;
    return _lock.synchronized(() async {
      String? deny;
      EgressGrant? grant;
      if (!_resolved) {
        deny = 'unresolved';
      } else if (inAlignmentZone) {
        deny = 'alignment';
      } else if (await _owner(null) != owner) {
        deny = 'owner';
      } else {
        switch (kind) {
          case RefreshOpKind.routine:
            if (!await permitsSessionRefresh(owner: owner)) {
              deny = 'routine_not_permitted';
            }
          case RefreshOpKind.accountControl:
            final control = zoneGrant?.control;
            final uri = refreshTokenUri();
            if (control == null ||
                (control.op != AccountControlOp.deleteAccount &&
                    control.op != AccountControlOp.cancelDelete) ||
                uri == null) {
              deny = 'grant_scope';
            } else {
              grant = zoneGrant;
              deny = await _decide(owner, zoneGrant, AdmissionRequest('POST', uri));
            }
          case RefreshOpKind.asr:
            if (!_localReadDenies) {
              deny = 'not_local_read';
            } else if (await _pendingDenies(owner)) {
              deny = 'pending_enable';
            }
        }
      }
      // Synchronously after the last await.
      deny ??= _refreshDenial(kind, startPosition, authority, grant);
      if (deny == null && predicate != null) {
        bool ok;
        try {
          ok = predicate();
        } catch (_) {
          ok = false;
        }
        if (!ok) deny = 'predicate';
      }
      if (deny != null) throw EgressDeniedException(deny);
      final t = EgressTicket._(owner, _epoch, grant, null,
          refresh: RefreshAdmission(
              kind: kind, startPosition: startPosition, authority: authority));
      _inFlight.add(t);
      return t;
    });
  }

  /// §9.4 P_send, the gate's half: synchronous, immediately before the first
  /// request byte. Marks the ticket as past send. Null when it may send.
  String? confirmRefreshSend(EgressTicket t) {
    final r = t.refresh;
    if (r == null) return 'not_refresh';
    if (t.isCancelled || t._released) return 'cancelled';
    final deny = _refreshDenial(r.kind, r.startPosition, r.authority, t.grant);
    if (deny != null) return deny;
    r.passedSend = true;
    return null;
  }

  String? _refreshDenial(
      RefreshOpKind kind, int start, Object authority, EgressGrant? grant) {
    if (!_resolved) return 'unresolved';
    if (inAlignmentZone) return 'alignment';
    if (_holds.isNotEmpty) return 'transition_hold';
    if (foreignCauseSince(start, kind: kind, authority: authority)) {
      return 'foreign_cause';
    }
    if (kind == RefreshOpKind.accountControl) {
      final control = grant?.control;
      return control == null || !control.active ? 'grant_inactive' : null;
    }
    if (_terminalDenied) return 'terminal';
    if (_lifecycleDenied) return 'lifecycle_fence';
    if (ConsentAuthority.egressFrozen) return 'frozen';
    if (kind == RefreshOpKind.asr) {
      return _localReadDenies ? null : 'not_local_read';
    }
    return _localReadDenies ? 'local_read' : null;
  }

  void release(EgressTicket t) {
    if (t._released) return;
    t._released = true;
    _inFlight.remove(t);
    if (_inFlight.isEmpty) {
      final idle = _idle;
      _idle = null;
      if (idle != null && !idle.isCompleted) idle.complete();
    }
  }

  /// True when a result that belongs to [t] may still be used.
  bool isCurrent(EgressTicket t) => !t.isCancelled && t.epoch == _epoch &&
      (t.grant?._deletion == null || t.grant!._deletion!.active);

  /// Runs [body] under an admitted ticket (released when it settles).
  Future<T> guarded<T>(Future<T> Function(EgressTicket ticket) body,
      {String? owner, EgressGrant? grant}) async {
    final t = await admit(owner: owner, grant: grant);
    try {
      return await runZoned(() => body(t),
          zoneValues: grant == null ? null : {_grantKey: grant});
    } finally {
      release(t);
    }
  }

  /// Runs [body] under an operation-scoped account-control grant (H2.1): the
  /// ONLY way to reach the network while Cloud is OFF. Call it immediately
  /// before the Supabase exchange, after any native Google/Apple UI returned.
  ///
  ///  * the grant lives in the [Zone] of [body]; unrelated concurrent calls do
  ///    not inherit it;
  ///  * it expires after [accountControlTtl] on a monotonic clock and is ended in
  ///    `finally` on success, failure and timeout; a timer or retry spawned in
  ///    the zone that fires later finds it inactive and is denied;
  ///  * on a timeout the requests still running under it are cancelled;
  ///  * it never writes the egress record, never flips Cloud ON and never touches
  ///    consent.
  Future<T> runAccountControl<T>(
      AccountControlOp op, Future<T> Function() body,
      {bool attempt = false,
      ({AdmissionAuthority authority, String accessToken})? onboarding,
      ({String owner, bool Function() current})? linking}) async {
    // §11.3: an explicit attempt waits (bounded) until ASR really finished; ASR
    // keeps ownership on a timeout and the attempt fails retryably.
    final quiesced = asrQuiesced;
    if (attempt && quiesced != null) {
      await quiesced().timeout(asrQuiescenceTimeout,
          onTimeout: () => throw TimeoutException('asr_quiescence'));
    }
    final control =
        AccountControlGrant._(op, ++_grantSeq, accountControlTtl, _monotonic,
            onboarding: onboarding, linking: linking);
    final grant = EgressGrant.accountControl(control);
    try {
      // `() async => await body()` on purpose: a lazily-executed builder (a
      // PostgREST rpc) only sends when it is first awaited, and that await must
      // happen INSIDE the grant zone, not in the caller's.
      return await runZoned(() async => await body(),
              zoneValues: {_grantKey: grant})
          .timeout(accountControlTtl, onTimeout: () {
        control._end();
        for (final t in _inFlight.toList()) {
          if (identical(t.grant?.control, control) && !t._cancel.isCompleted) {
            t._cancel.complete();
          }
        }
        throw TimeoutException('account_control_timeout');
      });
    } finally {
      control._end();
    }
  }

  /// Wired by the AuthCoordinator: completes when ASR holds no section, hold,
  /// pending local mutation or transport resource (§11.3).
  Future<void> Function()? asrQuiesced;
  static const Duration asrQuiescenceTimeout = Duration(seconds: 10);

  /// Explicit foreground exchange only; never an automatic Cloud OFF poller.
  Future<T> runImmediateDeletion<T>({
    required ImmediateDeletionAction action,
    required String owner,
    required String? activeOwner,
    required int epoch,
    required bool Function() isCurrent,
    required Uri functionUrl,
    required String serializedBody,
    required Future<T> Function() exchange,
    String? bearerToken,
    Duration? timeout,
  }) async {
    final base = Uri.tryParse(_supabaseUrl());
    if (base == null || base.scheme != 'https' || base.host.isEmpty ||
        base.userInfo.isNotEmpty || base.hasQuery || base.hasFragment ||
        (base.path.isNotEmpty && base.path != '/') ||
        functionUrl.scheme != base.scheme || functionUrl.host != base.host ||
        functionUrl.port != base.port || functionUrl.userInfo.isNotEmpty ||
        functionUrl.path != '/functions/v1/delete-account-immediate' ||
        functionUrl.hasQuery || functionUrl.hasFragment || owner.isEmpty ||
        (activeOwner != null && activeOwner != owner) ||
        ((action == ImmediateDeletionAction.request ||
                action == ImmediateDeletionAction.challenge) &&
            (activeOwner != owner || bearerToken == null || bearerToken.isEmpty)) ||
        (action == ImmediateDeletionAction.status && bearerToken != null)) {
      throw EgressDeniedException('deletion_scope');
    }
    dynamic body;
    try { body = jsonDecode(serializedBody); } catch (_) { body = null; }
    final status = action == ImmediateDeletionAction.status;
    final challenge = action == ImmediateDeletionAction.challenge;
    final providerChallenge = challenge && body is Map &&
        body['proof_version'] == 2 && body['email_only'] is bool;
    final keys = challenge
        ? {'action', if (providerChallenge) ...{'proof_version', 'email_only'}}
        : status
            ? {'action', 'receipt_secret'}
            : {'challenge_id', 'challenge_response', 'receipt_secret',
                if (body is Map && body.containsKey('action')) 'action'};
    if (body is! Map<String, dynamic> ||
        body.length != keys.length || !body.keys.every(keys.contains) ||
        (challenge && body['action'] != 'challenge') ||
        (!challenge &&
            (body['receipt_secret'] is! String ||
                !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(body['receipt_secret'] as String))) ||
        (status && body['action'] != 'status') ||
        (!status && !challenge && ((body.containsKey('action') && body['action'] != 'request') ||
            body['challenge_id'] is! String || (body['challenge_id'] as String).isEmpty ||
            body['challenge_response'] is! String || (body['challenge_response'] as String).isEmpty))) {
      throw EgressDeniedException('deletion_scope');
    }
    final ceiling = accountControlTtl < kAccountControlTtl ? accountControlTtl : kAccountControlTtl;
    final ttl = timeout != null && timeout < ceiling ? timeout : ceiling;
    if (ttl <= Duration.zero) throw EgressDeniedException('deletion_scope');
    final deletion = _ImmediateDeletionGrant(
      action: action, owner: owner, activeOwner: activeOwner, epoch: epoch,
      current: isCurrent, url: functionUrl,
      fingerprint: sha256.convert(utf8.encode(serializedBody)).toString(),
      authorization: status ? null : 'Bearer $bearerToken', ttl: ttl, now: _monotonic,
    );
    final grant = EgressGrant._forDeletion(deletion);
    try {
      return await runZoned(() async => await exchange(), zoneValues: {_grantKey: grant})
          .timeout(ttl);
    } finally {
      deletion.ended = true;
      for (final t in _inFlight.toList()) {
        if (identical(t.grant?._deletion, deletion) && !t._cancel.isCompleted) {
          t._cancel.complete();
        }
      }
    }
  }

  /// The ONE request admitted in DISABLING. At most one call per transition (the
  /// caller guards that with its durable `revoke_attempt`). A timeout cancels
  /// the request and is reported as [TimeoutException].
  /// The ONE request [EgressGrant.revokeRetry] may make: a POST to
  /// `set-device-consent` (the v2 `action: 'revoke'` route) on the configured
  /// host. Anything else under that grant is denied.
  static bool isRevokeRetryRequest(AdmissionRequest request, String baseUrl) {
    final base = Uri.tryParse(baseUrl);
    if (request.method != 'POST' || request.url.scheme != 'https') return false;
    if (base != null && base.host.isNotEmpty && request.url.host != base.host) {
      return false;
    }
    return request.url.path.endsWith('/functions/v1/set-device-consent');
  }

  /// Runs [body] under [EgressGrant.revokeRetry] for [owner] at [generation]:
  /// admitted only while that owner's record is still OFF at that generation
  /// (see [_decide]); every request [body] makes is admitted again with its
  /// method and URL, and must be the revoke POST.
  Future<T> runRevokeRetry<T>(String owner, int generation, Duration timeout,
      Future<T> Function() body) async {
    final grant = EgressGrant.revokeRetry(owner: owner, generation: generation);
    final t = await admit(owner: owner, grant: grant);
    try {
      return await runZoned(() => body(), zoneValues: {_grantKey: grant})
          .timeout(timeout, onTimeout: () {
        if (!t._cancel.isCompleted) t._cancel.complete();
        throw TimeoutException('revoke_retry_timeout');
      });
    } finally {
      release(t);
    }
  }

  Future<T> runRevoke<T>(
      DisableFreeze freeze, Duration timeout, Future<T> Function() body) async {
    final grant = freeze.revokeGrant;
    final t = await admit(owner: freeze.owner, grant: grant);
    try {
      return await runZoned(() => body(), zoneValues: {_grantKey: grant})
          .timeout(timeout, onTimeout: () {
        if (!t._cancel.isCompleted) t._cancel.complete();
        throw TimeoutException('revoke_timeout');
      });
    } finally {
      release(t);
    }
  }

  // ── transitions ────────────────────────────────────────────────────────────

  /// Writes DISABLING durably, under the admission lock, with the transition
  /// generation advanced FIRST. Throws [EgressWriteFailedException] when not a
  /// single store took the record (the caller then sends no revoke).
  ///
  /// [isCurrent] is judged INSIDE the lock, before the read and again before the
  /// write: a caller whose lifecycle ended while it waited for the lock writes
  /// nothing and gets a [StaleAdmissionException].
  Future<DisableFreeze> beginDisabling({
    required String owner,
    required int reservedVersion,
    bool Function()? isCurrent,
  }) =>
      _lock.synchronized(() async {
        bool stale() => isCurrent != null && !isCurrent();
        if (stale()) throw const StaleAdmissionException();
        final allocated = await store.writeAllocated(
            owner,
            (gen) => CloudEgressRecord(
                state: EgressState.disabling,
                ownerUid: owner,
                transitionGeneration: gen,
                reservedVersion: reservedVersion),
            isCurrent: isCurrent);
        _setMirror(false);
        if (stale()) throw const StaleAdmissionException();
        // N-R9: an unverifiable layer claims no generation and writes nothing.
        if (allocated == null || !allocated.result.any) {
          throw const EgressWriteFailedException('disabling');
        }
        return DisableFreeze(
            owner: owner,
            transitionGeneration: allocated.record.transitionGeneration,
            reservedVersion: allocated.record.reservedVersion);
      });

  /// Re-writes DISABLING (a failed local OFF write must leave the marker). Under
  /// the lock. N-R8: a record of a newer generation, or a layer that cannot be
  /// verified, is never replaced (false), whether or not [isCurrent] is
  /// supplied; with [isCurrent] a superseded caller writes nothing (checked
  /// before the read AND again after it, before any write is dispatched). A
  /// [StaleAdmissionException] AFTER the writes were dispatched does not mean
  /// nothing was written: the stored records are restrictive at this freeze's
  /// own generation.
  Future<bool> rewriteDisabling(DisableFreeze freeze,
          {bool Function()? isCurrent}) =>
      _lock.synchronized(() async {
        bool stale() => isCurrent != null && !isCurrent();
        if (stale()) throw const StaleAdmissionException();
        final w = await store.writeUnlessNewer(
            freeze.record(EgressState.disabling),
            isCurrent: isCurrent);
        if (w == null) return false;
        if (stale()) throw const StaleAdmissionException();
        return w.any;
      });

  /// Durable OFF. True when at least one store holds it. Never reopens traffic
  /// by itself: on false the DISABLING record is still there.
  ///
  /// N-CR-2: judged INSIDE the lock. A superseded caller ([isCurrent] false)
  /// writes nothing and gets a [StaleAdmissionException]; a record of a NEWER
  /// generation in any store (a successor's transition), or a layer that cannot
  /// be verified (N-R8), is never replaced, and the call answers false. A stale
  /// exception raised AFTER the writes were dispatched does not mean nothing was
  /// written: the stored records are OFF at this freeze's own generation.
  Future<bool> commitOff(DisableFreeze freeze, {bool Function()? isCurrent}) =>
      _lock.synchronized(() async {
        bool stale() => isCurrent != null && !isCurrent();
        if (stale()) throw const StaleAdmissionException();
        final w = await store.writeUnlessNewer(freeze.record(EgressState.off),
            isCurrent: isCurrent);
        _setMirror(false);
        if (w == null) return false;
        if (stale()) throw const StaleAdmissionException();
        return w.any;
      });

  /// Reads back, store by store, whether [freeze]'s restrictive record is held
  /// by each independently admitting runtime.
  Future<RestrictionReadback> verifyRestriction(DisableFreeze freeze) =>
      _lock.synchronized(() =>
          store.readbackRestriction(freeze.owner, freeze.transitionGeneration));

  /// An explicit enable: a NEW generation and version (strictly greater), ON in
  /// EVERY store. A partial write leaves a restrictive record behind (the merge
  /// keeps it), so it throws.
  ///
  /// [isCurrent] is judged inside the lock before the read, before the write and
  /// AFTER the awaited write: a store write can finish ON once the scope was
  /// revoked, so a stale caller restricts what it wrote (see [restrictWrittenOn])
  /// before the lock is released and gets a [StaleAdmissionException].
  Future<CloudEgressRecord> enable({
    required String owner,
    required int reservedVersion,
    bool Function()? isCurrent,
  }) =>
      _lock.synchronized(() async {
        bool stale() => isCurrent != null && !isCurrent();
        if (stale()) throw const StaleAdmissionException();
        final allocated = await store.writeAllocated(
            owner,
            (gen) => CloudEgressRecord(
                state: EgressState.on,
                ownerUid: owner,
                transitionGeneration: gen,
                reservedVersion: reservedVersion),
            isCurrent: isCurrent);
        // N-R9: an unverifiable layer claims no generation and writes nothing.
        if (allocated == null) {
          throw const EgressWriteFailedException('enable_generation');
        }
        final rec = allocated.record;
        final w = allocated.result;
        if (stale()) {
          if (!await _restrictWrittenOn(rec)) {
            throw const EgressWriteFailedException('enable_stale');
          }
          throw const StaleAdmissionException();
        }
        if (!w.all) {
          // Never leave a half-written ON behind: best-effort restrictive OFF.
          await store.restrictOwnerLayers(rec);
          throw const EgressWriteFailedException('enable');
        }
        return rec;
      });

  /// Restrictive compensation for an ON record this caller wrote (via [enable])
  /// but may no longer keep: the scope was revoked, or the local commit failed.
  ///
  /// Judged per STORE, never by the merged winner (the merge lets an older OFF
  /// in one store mask [written] ON in another, and an unreadable store hides
  /// what it holds): a store holding a strictly NEWER generation for the owner
  /// means a later legitimate transition superseded [written] and nothing is
  /// written there. If another readable store still holds [written], it is
  /// restricted independently. Unreadable stores are never overwritten; native
  /// storage independently refuses older generations.
  /// True is the bounded compensation outcome, not universal absence or native
  /// cleanup proof: the compatibility supersession case may return true when a
  /// newer readable record exists and no exact old ON is visible, even if a
  /// different layer is unreadable. False means incomplete compensation. Neither
  /// answer authorizes repair of unreadable authority.
  Future<bool> restrictWrittenOn(CloudEgressRecord written) =>
      _lock.synchronized(() => _restrictWrittenOn(written));

  Future<bool> _restrictWrittenOn(CloudEgressRecord written) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final seen = await store.readOwnerLayers(written.ownerUid);
        if (!seen.records.contains(written) &&
            seen.records.any(
                (r) => r.transitionGeneration > written.transitionGeneration)) {
          return true;
        }
        // A failed restrictive write must use its remaining retry even when
        // the first attempt already removed the last exact ON copy. An older
        // OFF in a failed layer still needs this operation's generation.
        if (attempt == 0 && !seen.uncertain && !seen.records.contains(written)) {
          return true;
        }
        final w = await store.restrictOwnerLayers(written);
        if (w.all) return true;
      } catch (_) {}
    }
    return false;
  }

  // ── N-E: the durable pending denial of an explicit enable ──────────────────

  /// Freezes [owner]'s ON admission SYNCHRONOUSLY: the epoch advances, the
  /// permit mirror drops and the in-process marker denies, before the first
  /// await of the enable. Only a read-back-verified [clearPendingEnable] (or a
  /// startup that finds no pending) ends it.
  void freezeEnable(String owner, {Object? authority}) {
    _enablePendingOwners.add(owner);
    _advance(EpochCause.freeze, authority: authority);
    _setMirror(false);
  }

  /// The next transition generation for [owner]: one above the highest record of
  /// ANY readable store (native included) or pending. Refuses when a store is
  /// corrupt or unreadable (no guessed counter).
  Future<int> allocateEnableGeneration(String owner) =>
      _lock.synchronized(() async {
        // Generations are per owner. A previous owner's native operation
        // cannot contribute to this owner's generation frontier.
        final seen = await store._collect(owner,
            verifyNative: true, onlyOwner: true);
        if (seen.problems.isNotEmpty) {
          throw EgressWriteFailedException(
              'allocate_generation/${seen.problems.join(',')}');
        }
        final pending = (await store.readPending()).agreed(owner);
        var highest = pending?.transitionGeneration ?? 0;
        for (final layer in seen.layers) {
          final r = layer[owner];
          if (r != null && r.transitionGeneration > highest) {
            highest = r.transitionGeneration;
          }
        }
        return highest + 1;
      });

  /// Recover a lost native-begin reply before acquiring the process lifetime.
  /// The candidate binding comes from inspect; full proof validation runs before
  /// persisting it, and again over the two bound copies before issuing a proof.
  Future<PendingEnableLifetimeProof> bindPendingEnableLifetime(
      ConsentCapability capability, PendingEnableRecord pending,
      CloudEgressEnableBinding binding) async {
    if (pending.binding != null ||
        binding.transitionGeneration != pending.transitionGeneration ||
        binding.reservedVersion != pending.reservedVersion) {
      throw const StaleAdmissionException();
    }
    final bound = pending.bound(binding);
    await PendingEnableLifetimeProof._(bound, capability, store,
        expectedPending: pending).verify(capability);
    capability.requireCurrent();
    if (!(await bindPendingEnable(from: pending, to: bound)).all) {
      throw const StaleAdmissionException();
    }
    capability.requireCurrent();
    return provePendingEnableLifetime(capability, bound);
  }

  Future<PendingEnableLifetimeProof> provePendingEnableLifetime(
      ConsentCapability capability, PendingEnableRecord pending) async {
    final proof = PendingEnableLifetimeProof._(pending, capability, store);
    await proof.verify(capability);
    return proof;
  }

  /// Proves the live operation before the consent-only SQL drain.
  Future<PendingEnableCommitProof> provePendingEnableCommit(
      ConsentCapability capability, PendingEnableRecord pending) async {
    final proof = PendingEnableCommitProof._(pending, capability, store);
    await proof.verifyLocal(capability);
    final b = pending.binding!;
    final owner = await NativeCaptureBridge.getCaptureOwner();
    capability.requireCurrent();
    final epoch = await NativeCaptureBridge.captureOwnerEpoch();
    capability.requireCurrent();
    final inspected = await NativeCaptureBridge.getCloudEgressPending(ownerUid: capability.uid);
    capability.requireCurrent();
    bool physical(List<CloudEgressLayerReport> layers) => layers.length == 2 &&
        layers[0].layer == 'file' && layers[1].layer == 'keychain';
    if (owner?.uid != capability.uid || owner?.generation != b.ownerGeneration ||
        epoch != b.ownerEpoch || inspected == null || inspected.operation != 'inspect' ||
        inspected.status != CloudEgressTransitionStatus.pending || inspected.binding != b ||
        !physical(inspected.barrier) || !physical(inspected.egress) ||
        inspected.barrier.any((r) => r.outcome != CloudEgressLayerOutcome.verified ||
          r.operationId != b.operationId || r.transitionGeneration != b.transitionGeneration ||
          r.reservedVersion != b.reservedVersion || r.ownerGeneration != b.ownerGeneration ||
          r.ownerEpoch != b.ownerEpoch) ||
        inspected.egress.any((r) => r.outcome != CloudEgressLayerOutcome.verified ||
          r.state != 'ON' || r.operationId != null ||
          r.transitionGeneration != b.transitionGeneration || r.reservedVersion != b.reservedVersion ||
          r.ownerGeneration != b.ownerGeneration || r.ownerEpoch != b.ownerEpoch)) {
      throw const StaleAdmissionException();
    }
    await proof.verifyLocal(capability);
    return proof;
  }

  /// Phase 2: persists [record] in BOTH Dart pending layers, each read back.
  Future<PendingWriteResult> beginPendingEnable(PendingEnableRecord record) =>
      _lock.synchronized(() => store.beginPending(record));

  /// Phase 3: records the native binding (exact [from] -> [to]) per layer.
  Future<PendingWriteResult> bindPendingEnable(
          {required PendingEnableRecord from,
          required PendingEnableRecord to}) =>
      _lock.synchronized(() => store.bindPending(from, to));

  /// Explicit retry only: re-persists an exact record in the layer that lost it.
  Future<PendingWriteResult> repairPendingEnable(PendingEnableRecord record) =>
      _lock.synchronized(() => store.repairPending(record));

  /// Phase 6 / compensation: removes the exact operation from each layer (read
  /// back). The in-process marker is dropped only when a fresh read shows the
  /// owner has no pending left in either layer.
  Future<PendingWriteResult> clearPendingEnable(PendingEnableRecord record,
          {bool Function()? isCurrent}) =>
      _lock.synchronized(() async {
        final result = await store.clearPending(record, isCurrent: isCurrent);
        try {
          if (!(await store.readPending()).blocks(record.ownerUid)) {
            _enablePendingOwners.remove(record.ownerUid);
          }
        } catch (_) {}
        return result;
      });

  /// Ends the in-process freeze of [owner] when a fresh read proves it has no
  /// pending enable left (nothing was ever persisted, or it was cleared). A
  /// pending that is present or unreadable keeps the freeze.
  Future<void> thawEnable(String owner) => _lock.synchronized(() async {
        try {
          if (!(await store.readPending()).blocks(owner)) {
            _enablePendingOwners.remove(owner);
          }
        } catch (_) {}
      });

  /// Phase 4: Dart-ONLY ON (secure + file), never native and never the generic
  /// multi-store writer. Each layer is read back.
  Future<PendingWriteResult> writeDartOn(CloudEgressRecord on) =>
      _lock.synchronized(() => store.writeDartLayers(on));

  /// Compensation of [written] in the Dart layers (see
  /// [CloudEgressStore.restrictDartLayers]).
  Future<PendingWriteResult> restrictDartLayers(CloudEgressRecord written) =>
      _lock.synchronized(() => store.restrictDartLayers(written));

  /// Aligns an observed ON record down to OFF (settings are more restrictive).
  /// The generation is allocated from the verified maximum of every layer; an
  /// unverifiable layer writes nothing (null). The initializing service's
  /// currency is checked inside the queue, after allocation and at dispatch.
  Future<EgressWriteResult?> alignOff(CloudEgressRecord observed,
          {bool Function()? isCurrent, bool onlyOwner = false}) =>
      _lock.synchronized(() async {
        if (isCurrent != null && !isCurrent()) {
          throw const StaleAdmissionException();
        }
        return (await store.writeAllocated(
                observed.ownerUid,
                (gen) => observed.copyWith(
                    state: EgressState.off, transitionGeneration: gen),
                isCurrent: isCurrent, onlyOwner: onlyOwner))
            ?.result;
      });

  /// Writes an arbitrary record under the lock (startup reconciliation).
  Future<EgressWriteResult> writeRecord(CloudEgressRecord record) =>
      _lock.synchronized(() => store.write(record));

  /// Waits for the in-flight set to drain (bounded by [drainTimeout]) and
  /// cancels whatever is still running. Only after this may OFF be committed.
  Future<DrainResult> drain() async {
    if (_inFlight.isEmpty) {
      return const DrainResult(waited: false, cancelled: 0);
    }
    final idle = _idle ??= Completer<void>();
    await idle.future.timeout(drainTimeout, onTimeout: () {});
    if (_inFlight.isEmpty) return const DrainResult(waited: true, cancelled: 0);
    final pending = _inFlight.toList();
    for (final t in pending) {
      if (!t._cancel.isCompleted) t._cancel.complete();
      release(t);
    }
    return DrainResult(waited: true, cancelled: pending.length);
  }

  /// Waits for native extension uploads admitted before DISABLING: until the
  /// count is 0 or the latest native deadline, never longer than [nativeMaxWait].
  /// An unavailable answer waits out the whole bound. Off iOS there is nothing.
  Future<void> drainNative(String owner) async {
    final query = _nativeInflight ??
        (NativeCaptureBridge.hasNativeQueue
            ? (String o) =>
                NativeCaptureBridge.nativeInflightUploads(ownerUid: o)
            : null);
    if (query == null) return;
    final limit = DateTime.now().add(nativeMaxWait);
    while (true) {
      ({int count, DateTime? latestDeadline})? r;
      try {
        r = await query(owner);
      } catch (_) {}
      final now = DateTime.now();
      if (r == null) {
        final left = limit.difference(now);
        if (left > Duration.zero) await Future<void>.delayed(left);
        return;
      }
      final cap = r.latestDeadline != null && r.latestDeadline!.isBefore(limit)
          ? r.latestDeadline!
          : limit;
      if (r.count == 0 || !now.isBefore(cap)) return;
      await Future<void>.delayed(nativePoll);
    }
  }

  /// Refreshes the synchronous mirror and tells [onPermitChanged].
  Future<void> refresh() async {
    final v = await view();
    final pendingDenies = await _pendingDenies(v.owner);
    _setMirror(_resolved &&
        !v.uncertain &&
        !pendingDenies &&
        v.record?.state == EgressState.on);
  }

  void _setMirror(bool permits) {
    final next = permits &&
        _resolved &&
        !_lifecycleDenied &&
        _holds.isEmpty &&
        !_terminalDenied &&
        !ConsentAuthority.egressFrozen &&
        !_localReadDenies;
    if (next == _permitMirror) return;
    _permitMirror = next;
    permitNotifier.value = next;
    final cb = onPermitChanged;
    if (cb != null) unawaited(cb(next).catchError((_) {}));
  }
}

/// Identity of one startup initialization attempt's claim to resolve the
/// process latch ([CloudEgressGate.beginResolution]).
class EgressResolutionToken {
  EgressResolutionToken._();
}

class EgressView {
  const EgressView(this.owner, this.readout);
  final String owner;
  final EgressReadout readout;
  bool get uncertain => readout.uncertain;
  CloudEgressRecord? get record => readout.records[owner];
}

/// The transport every Dart network path uses. Admission happens per request;
/// the ticket is held until the response body has been read. A response that
/// arrives after the epoch advanced (or after a drain gave up on it) is
/// discarded with [EgressDeniedException].
class GatedHttpClient extends http.BaseClient {
  GatedHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final gate = CloudEgressGate.instance;
    // Freeze bytes AND headers before classification and the first admission
    // await. The same private snapshot is classified, fingerprinted and sent,
    // so a mutable caller cannot replace a classified/admitted body or inject a
    // status Authorization afterwards.
    List<int>? bytes;
    Map<String, String>? headers;
    if (request is http.Request) {
      bytes = List<int>.unmodifiable(request.bodyBytes);
      headers = Map<String, String>.unmodifiable(request.headers);
    }
    // I3 (ASR §3.1): only the AuthCoordinator refreshes, through its own
    // transport. Every other refresh-token request is denied here, before
    // admission, in every mode and under every grant.
    final refresh = gate.sdkRefreshViolation(bytes == null
        ? request
        : (http.Request(request.method, request.url)
          ..headers.addAll(headers!)
          ..bodyBytes = bytes));
    if (refresh != null) throw EgressDeniedException(refresh);
    // §4.8: nothing from an alignment zone reaches admission.
    if (CloudEgressGate.inAlignmentZone) throw EgressDeniedException('alignment');
    final grant = Zone.current[CloudEgressGate._grantKey] as EgressGrant?;
    final deletion = grant?._deletion;
    final bindsBody =
        deletion != null || grant?.control?.op == AccountControlOp.onboardingStatus;
    if (deletion != null && bytes == null) {
      throw EgressDeniedException('deletion_stream');
    }
    String? header(String name) {
      for (final e in (headers ?? request.headers).entries) {
        if (e.key.toLowerCase() == name) return e.value;
      }
      return null;
    }
    final ticket = await gate.admit(request: AdmissionRequest(request.method, request.url,
      bodyFingerprint:
          bindsBody && bytes != null ? sha256.convert(bytes).toString() : null,
      authorization: header('authorization'), contentType: header('content-type')));
    if (deletion != null && !gate.isCurrent(ticket)) {
      gate.release(ticket);
      throw EgressDeniedException('stale');
    }
    final result = Completer<http.StreamedResponse>();
    var settled = false;
    void fail(Object e, [StackTrace? s]) {
      if (settled) return;
      settled = true;
      gate.release(ticket);
      result.completeError(e, s);
    }

    // H2.1: a granted request must not follow redirects (a 3xx could leave the
    // allowlisted endpoint or host). Set before the request is finalized.
    if (ticket.grant?.control != null ||
        ticket.grant?.kind == EgressGrantKind.revokeRetry) {
      request.followRedirects = false;
    }
    unawaited(
        ticket.cancelled.then((_) => fail(EgressDeniedException('cancelled'))));
    http.BaseRequest outgoing = request;
    if (request is http.Request) {
      outgoing = http.AbortableRequest(request.method, request.url,
          abortTrigger: ticket.cancelled)
        ..headers.addAll(headers ?? request.headers)
        ..bodyBytes = bytes ?? request.bodyBytes
        ..followRedirects = deletion != null ? false : request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..persistentConnection = request.persistentConnection;
    }
    final Future<http.StreamedResponse> transport;
    if (deletion != null) {
      try {
        transport = _inner.send(outgoing);
      } catch (error, stack) {
        fail(error, stack);
        return result.future;
      }
    } else {
      transport = _inner.send(outgoing);
    }
    transport.then((resp) {
      if (settled) {
        resp.stream.drain<void>().catchError((_) {});
        return;
      }
      settled = true;
      result.complete(http.StreamedResponse(
        _track(gate, ticket, resp.stream),
        resp.statusCode,
        contentLength: resp.contentLength,
        request: resp.request,
        headers: resp.headers,
        isRedirect: resp.isRedirect,
        persistentConnection: resp.persistentConnection,
        reasonPhrase: resp.reasonPhrase,
      ));
    }, onError: (Object e, StackTrace s) => fail(e, s));
    return result.future;
  }

  static Stream<List<int>> _track(CloudEgressGate gate, EgressTicket ticket,
      Stream<List<int>> body) async* {
    try {
      await for (final chunk in body) {
        if (!gate.isCurrent(ticket)) throw EgressDeniedException('stale');
        yield chunk;
      }
      if (!gate.isCurrent(ticket)) throw EgressDeniedException('stale');
    } finally {
      gate.release(ticket);
    }
  }

  @override
  void close() => _inner.close();
}
