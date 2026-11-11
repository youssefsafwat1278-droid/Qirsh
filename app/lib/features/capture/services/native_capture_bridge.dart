import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../domain/entities/captured_message.dart';
import '../../../domain/services/captured_timestamp.dart';

/// A single bank message drained from the native share queue.
class SharedCapturedMessage {
  const SharedCapturedMessage({
    required this.text,
    required this.source,
    this.id,
    this.receivedAt,
    this.sender,
    this.senderName,
    this.senderId,
    this.locale,
    this.status,
    this.failureReason,
    this.receivedAtInferred,
    this.ownerUid,
    this.localOnly,
  });

  final String? id;
  final String text;
  final String? sender;
  final String? senderName;
  final String? senderId;
  final String? locale;
  final String? status;
  final String? failureReason;
  final CapturedMessageSource source;
  final DateTime? receivedAt;

  /// R9: true when the iOS Shortcut did not pass Date Received and the native
  /// layer inferred the receive time; null when the native layer did not report
  /// it (share extension, builds before R9).
  final bool? receivedAtInferred;

  /// CAP-6: the uid this item is stamped to (queue v3). The native peek returns
  /// only the active owner's items; CAP-5 still checks equality before import.
  final String? ownerUid;

  /// CAP-6 §4.3: bound by an explicit claim. Import it with the local
  /// deterministic parser only: no upload, no AI.
  final bool? localOnly;
}

/// The active capture owner `{uid, uidHash, generation}` held natively (§4.2).
class CaptureOwnerRecord {
  const CaptureOwnerRecord({
    required this.uid,
    required this.uidHash,
    required this.generation,
  });

  final String uid;
  final String uidHash;
  final int generation;

  static CaptureOwnerRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final uid = raw['uid'];
    final hash = raw['uidHash'];
    final generation = raw['generation'];
    if (uid is! String || hash is! String || generation is! int) return null;
    return CaptureOwnerRecord(uid: uid, uidHash: hash, generation: generation);
  }
}

/// Exact native restrictive owner proof. A nullable/Boolean publication result
/// cannot widen a lifecycle; callers must verify the captured UID/epoch/version.
class RestrictiveCaptureOwnerReceipt {
  const RestrictiveCaptureOwnerReceipt(this.owner, this.phase);
  final CaptureOwnerRecord? owner;
  final CloudEgressEnableResult phase;

  static RestrictiveCaptureOwnerReceipt? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final copy = Map<Object?, Object?>.from(raw);
    final ownerRaw = copy.remove('owner');
    final phase = CloudEgressEnableResult.tryParse(copy);
    final owner =
        ownerRaw == null ? null : CaptureOwnerRecord.tryParse(ownerRaw);
    if (phase == null ||
        phase.operation != 'publishRestrictive' ||
        (ownerRaw != null && owner == null)) {
      return null;
    }
    return RestrictiveCaptureOwnerReceipt(owner, phase);
  }

  bool confirms(
      {required String uid, required int expectedEpoch, required int version}) {
    final value = owner;
    return value != null &&
        value.uid == uid &&
        value.uidHash.length == 64 &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(value.uidHash) &&
        value.generation > 0 &&
        phase.status == CloudEgressTransitionStatus.done &&
        phase.ownerGeneration == value.generation &&
        phase.ownerEpoch == expectedEpoch &&
        phase.egress.length == 2 &&
        phase.egress.every((r) =>
            r.outcome == CloudEgressLayerOutcome.verified &&
            r.state == 'OFF' &&
            r.ownerGeneration == value.generation &&
            r.ownerEpoch == expectedEpoch &&
            r.reservedVersion == version);
  }
}

/// How the explicit Cloud enable asks for its restrictive owner publication: the
/// reserved [version] and, when the owner's two native egress layers were
/// inspected as agreeing OFF, that exact record (native then refuses if it moved).
/// Used only for the one publication the explicit operation authorizes.
class RestrictivePublishPlan {
  const RestrictivePublishPlan(this.version,
      {this.expectedTransitionGeneration,
      this.expectedReservedVersion,
      this.expectedLifetimeOwnerGeneration,
      this.expectedLifetimeOwnerEpoch,
      this.expectedOffCopies,
      this.expectedRetiredCopies});
  final int version;
  final int? expectedTransitionGeneration;
  final int? expectedReservedVersion;
  final int? expectedLifetimeOwnerGeneration;
  final int? expectedLifetimeOwnerEpoch;

  /// Explicit reconciliation of independently readable OFF copies. Native
  /// compares each physical copy again under its write lock before publishing.
  final List<CloudEgressLayerReport>? expectedOffCopies;

  /// Explicit normalisation of a RETIRED OFF (a lifetime fence's record): the
  /// two inspected physical reports. Native republishes a fresh restrictive
  /// lifetime only while both layers still hold exactly this snapshot.
  final List<CloudEgressLayerReport>? expectedRetiredCopies;

  /// Both snapshot modes replace the stored lifetime, so a lifetime this
  /// process already holds is never reused for them.
  bool get requiresFreshLifetime =>
      expectedOffCopies != null || expectedRetiredCopies != null;
}

/// Why a restrictive owner publication produced no receipt. An allowlisted
/// constant (never a uid, hash, version, message or token); diagnostic only.
class RestrictiveOwnerRefusal {
  const RestrictiveOwnerRefusal(this.reason);
  final String reason;
}

/// The reconciled native `cloud_egress_state` (C.4 / C.5).
enum CloudEgressStatus { unset, ownerless, record, uncertain }

class CloudEgressSnapshot {
  const CloudEgressSnapshot(
    this.status, {
    this.state,
    this.ownerUid,
    this.transitionGeneration,
    this.reservedVersion,
    this.ownerEpoch,
    this.ownerGeneration,
    this.uncertainReason,
  });

  final CloudEgressStatus status;

  /// Diagnostic constant naming the native branch that reported `uncertain`.
  final String? uncertainReason;
  final int? ownerEpoch;
  final int? ownerGeneration;

  /// `ON`, `DISABLING` or `OFF`; set only when [status] is `record`.
  final String? state;
  final String? ownerUid;
  final int? transitionGeneration;
  final int? reservedVersion;

  /// Unreadable, corrupt or conflicting native state: egress is DENIED.
  bool get uncertain => status == CloudEgressStatus.uncertain;

  /// Null on a malformed answer; the caller treats null as unavailable (deny).
  static CloudEgressSnapshot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    switch (raw['status']) {
      case 'ownerless':
        final epoch = raw['ownerEpoch'];
        final generation = raw['ownerGeneration'];
        final contract = raw['contractVersion'];
        if (contract is! int ||
            contract != 1 ||
            epoch is! int ||
            epoch < 0 ||
            generation is! int ||
            generation < 0 ||
            raw.length != 4) {
          return null;
        }
        return CloudEgressSnapshot(CloudEgressStatus.ownerless,
            ownerEpoch: epoch, ownerGeneration: generation);
      case 'unset':
        return const CloudEgressSnapshot(CloudEgressStatus.unset);
      case 'uncertain':
        final reason = raw['reason'];
        return CloudEgressSnapshot(CloudEgressStatus.uncertain,
            uncertainReason:
                reason is String && RegExp(r'^[a-z_/]{1,64}$').hasMatch(reason)
                    ? reason
                    : null);
      case 'record':
        final state = raw['state'];
        final uid = raw['ownerUid'];
        final generation = raw['transitionGeneration'];
        final version = raw['reservedVersion'];
        if (state is! String ||
            uid is! String ||
            generation is! int ||
            version is! int) {
          return null;
        }
        return CloudEgressSnapshot(
          CloudEgressStatus.record,
          state: state,
          ownerUid: uid,
          transitionGeneration: generation,
          reservedVersion: version,
        );
    }
    return null;
  }
}

/// Outcome of one pending-enable phase (native `TransitionStatus`). Only [done]
/// is success; every other value is a refusal or an uncertain outcome.
enum CloudEgressTransitionStatus {
  done,
  incomplete,
  conflict,
  stale,
  noBarrier,
  uncertain,
  pending,

  /// The native active owner is absent, another owner, or no longer the owner
  /// lifecycle (generation / epoch) the operation was bound to. Nothing was
  /// written and the barrier, if any, keeps denying.
  ownerMismatch,
}

/// What one native layer (file or keychain) holds / what a phase did to it.
enum CloudEgressLayerOutcome {
  verified,
  restricted,
  alreadyRestrictive,
  superseded,
  absent,
  cleared,
  notOurs,
  unreadable,
  writeFailed,
  mismatch,
}

/// The full identity of one native pending-enable operation: the nonsecret
/// native-created [operationId], the egress [transitionGeneration] and
/// [reservedVersion] it enables, and the EXISTING F2 evidence of the owner
/// lifecycle it was bound to ([ownerGeneration], [ownerEpoch]). Every phase after
/// `begin` must present all of it; native refuses any mismatch.
class CloudEgressEnableBinding {
  const CloudEgressEnableBinding({
    required this.operationId,
    required this.transitionGeneration,
    required this.reservedVersion,
    required this.ownerGeneration,
    required this.ownerEpoch,
  });

  final String operationId;
  final int transitionGeneration;
  final int reservedVersion;
  final int ownerGeneration;
  final int ownerEpoch;

  @override
  bool operator ==(Object other) =>
      other is CloudEgressEnableBinding &&
      other.operationId == operationId &&
      other.transitionGeneration == transitionGeneration &&
      other.reservedVersion == reservedVersion &&
      other.ownerGeneration == ownerGeneration &&
      other.ownerEpoch == ownerEpoch;

  @override
  int get hashCode => Object.hash(operationId, transitionGeneration,
      reservedVersion, ownerGeneration, ownerEpoch);
}

class CloudEgressLayerReport {
  const CloudEgressLayerReport({
    required this.layer,
    required this.outcome,
    this.state,
    this.transitionGeneration,
    this.reservedVersion,
    this.operationId,
    this.ownerGeneration,
    this.ownerEpoch,
  });

  /// `file` or `keychain`.
  final String layer;
  final CloudEgressLayerOutcome outcome;

  /// `ON`, `DISABLING` or `OFF` for an egress layer that holds an entry.
  final String? state;
  final int? transitionGeneration;
  final int? reservedVersion;
  final String? operationId;
  final int? ownerGeneration;
  final int? ownerEpoch;
}

/// The structured native reply of a pending-enable phase (consent-security
/// amendment). It is NEVER success by itself: use the phase-specific
/// `confirms…` methods, which also check both layers and the full operation
/// binding. [tryParse] is strict; null means malformed and must be treated as a
/// failure.
/// ASR §7.2: the identity of native expiry evidence (no uid, key or content).
class NativeExpiryEvidence {
  const NativeExpiryEvidence({
    required this.evidenceId,
    required this.ownerGeneration,
    required this.ownerEpoch,
    required this.sessionLifecycle,
  });

  final String evidenceId;
  final int ownerGeneration;
  final int ownerEpoch;
  final int sessionLifecycle;

  static const _keys = {
    'evidenceId',
    'ownerGeneration',
    'ownerEpoch',
    'sessionLifecycle'
  };

  static NativeExpiryEvidence? tryParse(Object? raw) {
    if (raw is! Map ||
        raw.length != _keys.length ||
        !raw.keys.every(_keys.contains)) {
      return null;
    }
    final id = raw['evidenceId'];
    final generation = raw['ownerGeneration'];
    final epoch = raw['ownerEpoch'];
    final lifecycle = raw['sessionLifecycle'];
    if (id is! String ||
        !CloudEgressEnableResult._operationIdPattern.hasMatch(id) ||
        generation is! int ||
        generation <= 0 ||
        epoch is! int ||
        epoch < 0 ||
        lifecycle is! int ||
        lifecycle < 0) {
      return null;
    }
    return NativeExpiryEvidence(
        evidenceId: id,
        ownerGeneration: generation,
        ownerEpoch: epoch,
        sessionLifecycle: lifecycle);
  }

  @override
  bool operator ==(Object other) =>
      other is NativeExpiryEvidence &&
      other.evidenceId == evidenceId &&
      other.ownerGeneration == ownerGeneration &&
      other.ownerEpoch == ownerEpoch &&
      other.sessionLifecycle == sessionLifecycle;

  @override
  int get hashCode =>
      Object.hash(evidenceId, ownerGeneration, ownerEpoch, sessionLifecycle);
}

/// ASR §7.4: what `inspectRecoveryEvidence` saw under one native lock.
enum RecoveryEvidenceKind { expiryEvidence, liveOn, none }

class RecoveryEvidenceSnapshot {
  const RecoveryEvidenceSnapshot({
    required this.kind,
    required this.ownerGeneration,
    required this.ownerEpoch,
    required this.mutationCounter,
    this.state,
    this.transitionGeneration,
    this.reservedVersion,
    this.lifetimeOwnerGeneration,
    this.lifetimeOwnerEpoch,
    this.expiryEvidence,
  });

  final RecoveryEvidenceKind kind;
  final int? ownerGeneration;
  final int? ownerEpoch;
  final int? mutationCounter;
  final String? state;
  final int? transitionGeneration;
  final int? reservedVersion;
  final int? lifetimeOwnerGeneration;
  final int? lifetimeOwnerEpoch;
  final NativeExpiryEvidence? expiryEvidence;

  /// Positive native OFF (session-only refresh, Cloud OFF): a live owner with
  /// no removal barrier, no pending, and both native layers readable and agreed
  /// on an OFF record. Native sends a record only after all of that held
  /// (`SharedCaptureStore.inspectRecoveryEvidence`); absence is not OFF.
  bool get verifiedOff =>
      mutationCounter != null &&
      ownerGeneration != null &&
      ownerEpoch != null &&
      kind != RecoveryEvidenceKind.liveOn &&
      state == 'OFF';

  static int? _int(Map<Object?, Object?> raw, String key) {
    final v = raw[key];
    return v is int && v >= 0 ? v : null;
  }

  /// Any malformed reply is null (the caller denies).
  static RecoveryEvidenceSnapshot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    RecoveryEvidenceKind? kind;
    for (final k in RecoveryEvidenceKind.values) {
      if (k.name == raw['kind']) kind = k;
    }
    if (kind == null) return null;
    final rec = raw['record'];
    if (rec != null && rec is! Map) return null;
    final evidenceRaw = rec is Map ? rec['expiryEvidence'] : null;
    final evidence =
        evidenceRaw == null ? null : NativeExpiryEvidence.tryParse(evidenceRaw);
    if (evidenceRaw != null && evidence == null) return null;
    final snapshot = RecoveryEvidenceSnapshot(
      kind: kind,
      ownerGeneration: _int(raw, 'ownerGeneration'),
      ownerEpoch: _int(raw, 'ownerEpoch'),
      mutationCounter: _int(raw, 'mutationCounter'),
      state: rec is Map ? rec['state'] as String? : null,
      transitionGeneration:
          rec is Map ? _int(rec, 'transitionGeneration') : null,
      reservedVersion: rec is Map ? _int(rec, 'reservedVersion') : null,
      lifetimeOwnerGeneration:
          rec is Map ? _int(rec, 'lifetimeOwnerGeneration') : null,
      lifetimeOwnerEpoch: rec is Map ? _int(rec, 'lifetimeOwnerEpoch') : null,
      expiryEvidence: evidence,
    );
    // A positive kind must carry everything its predicate is built from.
    if (kind != RecoveryEvidenceKind.none &&
        (snapshot.ownerGeneration == null ||
            snapshot.ownerEpoch == null ||
            snapshot.mutationCounter == null ||
            snapshot.transitionGeneration == null ||
            snapshot.reservedVersion == null ||
            (kind == RecoveryEvidenceKind.expiryEvidence &&
                evidence == null))) {
      return null;
    }
    return snapshot;
  }
}

class CloudEgressEnableResult {
  const CloudEgressEnableResult({
    required this.operation,
    required this.status,
    required this.barrier,
    required this.egress,
    this.operationId,
    this.transitionGeneration,
    this.reservedVersion,
    this.ownerGeneration,
    this.ownerEpoch,
    this.expiryEvidence,
    this.mutationCounter,
    this.egressVersionFrontier,
  });

  static const _operations = {
    'begin',
    'writeOn',
    'restrict',
    'complete',
    'abandon',
    'inspect',
    'revoke',
    'publishRestrictive',
    'mintExpiry',
    'invalidateExpiry',
    'retireSuccessor',
  };
  static const _topKeys = {
    'contractVersion',
    'operation',
    'status',
    'operationId',
    'transitionGeneration',
    'reservedVersion',
    'ownerGeneration',
    'ownerEpoch',
    'barrier',
    'egress',
    'expiryEvidence',
    'mutationCounter',
    'egressVersionFrontier',
  };
  static const _layerKeys = {
    'layer',
    'outcome',
    'state',
    'transitionGeneration',
    'reservedVersion',
    'operationId',
    'ownerGeneration',
    'ownerEpoch',
  };
  static const _layerNames = ['file', 'keychain'];
  static final _operationIdPattern = RegExp(r'^[0-9a-f]{32}$');

  final String operation;
  final CloudEgressTransitionStatus status;
  final String? operationId;
  final int? transitionGeneration;
  final int? reservedVersion;
  final int? ownerGeneration;
  final int? ownerEpoch;

  /// Pending-barrier layers, in order `file`, `keychain`.
  final List<CloudEgressLayerReport> barrier;

  /// Egress-state layers, in order `file`, `keychain` (empty when not read).
  final List<CloudEgressLayerReport> egress;

  /// ASR §7.2: the expiry evidence both layers hold after an expiry revoke/mint.
  final NativeExpiryEvidence? expiryEvidence;

  /// ASR §7.4: the native `egressMutationCounter` read under the same lock.
  final int? mutationCounter;

  /// Inspection only: the highest reserved version the owner's stored egress
  /// entries carry, counting a retirement's own version (a layer report shows
  /// only one of the two). Null when no layer holds an entry of the owner.
  final int? egressVersionFrontier;

  /// The operation this reply is about, or null when any part of its identity is
  /// missing (then nothing can be resumed, restricted or finished with it).
  CloudEgressEnableBinding? get binding {
    final id = operationId;
    final generation = transitionGeneration;
    final version = reservedVersion;
    final ownerGen = ownerGeneration;
    final epoch = ownerEpoch;
    if (id == null ||
        generation == null ||
        version == null ||
        ownerGen == null ||
        epoch == null) {
      return null;
    }
    return CloudEgressEnableBinding(
      operationId: id,
      transitionGeneration: generation,
      reservedVersion: version,
      ownerGeneration: ownerGen,
      ownerEpoch: epoch,
    );
  }

  static T? _enumByName<T extends Enum>(List<T> values, Object? raw) {
    for (final v in values) {
      if (v.name == raw) return v;
    }
    return null;
  }

  /// -1 marks a present but invalid value (valid ones are >= 0).
  static int? _optionalInt(Map<Object?, Object?> raw, String key) {
    if (!raw.containsKey(key)) return null;
    final value = raw[key];
    return value is int && value >= 0 ? value : -1;
  }

  static bool _validId(Map<Object?, Object?> raw) {
    if (!raw.containsKey('operationId')) return true;
    final id = raw['operationId'];
    return id is String && _operationIdPattern.hasMatch(id);
  }

  static CloudEgressLayerReport? _parseLayer(Object? raw) {
    if (raw is! Map || !raw.keys.every(_layerKeys.contains)) return null;
    final layer = raw['layer'];
    final outcome = _enumByName(CloudEgressLayerOutcome.values, raw['outcome']);
    if (layer is! String || !_layerNames.contains(layer) || outcome == null) {
      return null;
    }
    final state = raw['state'];
    if (raw.containsKey('state') &&
        !(state is String &&
            const {'ON', 'DISABLING', 'OFF'}.contains(state))) {
      return null;
    }
    final generation = _optionalInt(raw, 'transitionGeneration');
    final version = _optionalInt(raw, 'reservedVersion');
    final ownerGeneration = _optionalInt(raw, 'ownerGeneration');
    final ownerEpoch = _optionalInt(raw, 'ownerEpoch');
    if (generation == -1 ||
        version == -1 ||
        ownerGeneration == -1 ||
        ownerEpoch == -1 ||
        !_validId(raw)) {
      return null;
    }
    return CloudEgressLayerReport(
      layer: layer,
      outcome: outcome,
      state: state as String?,
      transitionGeneration: generation,
      reservedVersion: version,
      operationId: raw['operationId'] as String?,
      ownerGeneration: ownerGeneration,
      ownerEpoch: ownerEpoch,
    );
  }

  /// Exactly `file` then `keychain` (or, when [allowEmpty], nothing).
  static List<CloudEgressLayerReport>? _parseLayers(Object? raw,
      {required bool allowEmpty}) {
    if (raw is! List) return null;
    if (raw.isEmpty) return allowEmpty ? const [] : null;
    if (raw.length != _layerNames.length) return null;
    final out = <CloudEgressLayerReport>[];
    for (var i = 0; i < raw.length; i++) {
      final report = _parseLayer(raw[i]);
      if (report == null || report.layer != _layerNames[i]) return null;
      out.add(report);
    }
    return out;
  }

  static CloudEgressEnableResult? tryParse(Object? raw) {
    if (raw is! Map || !raw.keys.every(_topKeys.contains)) return null;
    final operation = raw['operation'];
    final status =
        _enumByName(CloudEgressTransitionStatus.values, raw['status']);
    if (raw['contractVersion'] != 1 ||
        operation is! String ||
        !_operations.contains(operation) ||
        status == null) {
      return null;
    }
    final generation = _optionalInt(raw, 'transitionGeneration');
    final version = _optionalInt(raw, 'reservedVersion');
    final ownerGeneration = _optionalInt(raw, 'ownerGeneration');
    final ownerEpoch = _optionalInt(raw, 'ownerEpoch');
    final barrier = _parseLayers(raw['barrier'], allowEmpty: false);
    final egress = _parseLayers(raw['egress'], allowEmpty: true);
    final counter = _optionalInt(raw, 'mutationCounter');
    final frontier = _optionalInt(raw, 'egressVersionFrontier');
    final evidence = raw.containsKey('expiryEvidence')
        ? NativeExpiryEvidence.tryParse(raw['expiryEvidence'])
        : null;
    if (generation == -1 ||
        version == -1 ||
        ownerGeneration == -1 ||
        ownerEpoch == -1 ||
        counter == -1 ||
        frontier == -1 ||
        (raw.containsKey('expiryEvidence') && evidence == null) ||
        barrier == null ||
        egress == null ||
        !_validId(raw)) {
      return null;
    }
    return CloudEgressEnableResult(
      operation: operation,
      status: status,
      operationId: raw['operationId'] as String?,
      transitionGeneration: generation,
      reservedVersion: version,
      ownerGeneration: ownerGeneration,
      ownerEpoch: ownerEpoch,
      barrier: barrier,
      egress: egress,
      expiryEvidence: evidence,
      mutationCounter: counter,
      egressVersionFrontier: frontier,
    );
  }

  bool get _isDone => status == CloudEgressTransitionStatus.done;

  bool _boundTo(CloudEgressEnableBinding b) =>
      operationId == b.operationId &&
      transitionGeneration == b.transitionGeneration &&
      reservedVersion == b.reservedVersion &&
      ownerGeneration == b.ownerGeneration &&
      ownerEpoch == b.ownerEpoch;

  /// The barrier layer holds exactly this operation, owner binding included.
  bool _holdsOperation(CloudEgressLayerReport r) =>
      r.outcome == CloudEgressLayerOutcome.verified &&
      r.operationId == operationId &&
      r.transitionGeneration == transitionGeneration &&
      r.reservedVersion == reservedVersion &&
      r.ownerGeneration == ownerGeneration &&
      r.ownerEpoch == ownerEpoch;

  bool _holdsOn(CloudEgressLayerReport r) =>
      r.outcome == CloudEgressLayerOutcome.verified &&
      r.state == 'ON' &&
      r.transitionGeneration == transitionGeneration &&
      r.reservedVersion == reservedVersion;

  bool _barrierGone(CloudEgressLayerReport r) =>
      r.outcome == CloudEgressLayerOutcome.cleared ||
      r.outcome == CloudEgressLayerOutcome.absent;

  /// N: absent pending is never evidence of revocation. BOTH existing egress
  /// layers must contain the exact outgoing lifecycle retirement, read back.
  bool confirmsLifetimeRevoked(CloudEgressEnableBinding expected) =>
      operation == 'revoke' &&
      _isDone &&
      _boundTo(expected) &&
      egress.length == 2 &&
      egress.every((r) =>
          r.outcome == CloudEgressLayerOutcome.verified &&
          r.state == 'OFF' &&
          r.operationId == expected.operationId &&
          r.ownerGeneration == expected.ownerGeneration &&
          r.ownerEpoch == expected.ownerEpoch &&
          r.transitionGeneration == expected.transitionGeneration &&
          r.reservedVersion == expected.reservedVersion);

  /// `begin` achieved: the barrier for exactly this generation and version, bound
  /// to a native owner lifecycle, is read back from BOTH layers. A resume passes
  /// the [resumed] binding it asked for, and the reply must be that operation.
  /// The caller learns [binding] from this result.
  bool confirmsBarrierEstablished({
    required int transitionGeneration,
    required int reservedVersion,
    CloudEgressEnableBinding? resumed,
  }) {
    final b = binding;
    return operation == 'begin' &&
        _isDone &&
        b != null &&
        b.transitionGeneration == transitionGeneration &&
        b.reservedVersion == reservedVersion &&
        (resumed == null || b == resumed) &&
        barrier.length == 2 &&
        barrier.every(_holdsOperation);
  }

  /// `writeOn` achieved: ON(generation, version) is read back from BOTH layers.
  bool confirmsOnWritten(CloudEgressEnableBinding b) =>
      operation == 'writeOn' &&
      _isDone &&
      _boundTo(b) &&
      egress.length == 2 &&
      egress.every(_holdsOn);

  /// `restrict` achieved: no layer still holds this operation's ON. A layer that
  /// is `superseded` belongs to a newer generation and is reported, not claimed.
  bool confirmsRestricted(CloudEgressEnableBinding b) =>
      operation == 'restrict' &&
      _isDone &&
      _boundTo(b) &&
      egress.length == 2 &&
      egress.every((r) => const {
            CloudEgressLayerOutcome.restricted,
            CloudEgressLayerOutcome.alreadyRestrictive,
            CloudEgressLayerOutcome.superseded,
            CloudEgressLayerOutcome.absent,
          }.contains(r.outcome));

  /// `complete` achieved: ON in both egress layers AND the barrier entry removed
  /// from both layers, all read back by native code, for the still-live owner
  /// lifecycle the operation was bound to.
  bool confirmsCompleted(CloudEgressEnableBinding b) =>
      operation == 'complete' &&
      _isDone &&
      _boundTo(b) &&
      egress.length == 2 &&
      egress.every(_holdsOn) &&
      barrier.length == 2 &&
      barrier.every(_barrierGone);

  /// `abandon` achieved: the barrier entry removed from both layers while no
  /// layer holds any ON for the owner.
  bool confirmsAbandoned(CloudEgressEnableBinding b) =>
      operation == 'abandon' &&
      _isDone &&
      _boundTo(b) &&
      egress.length == 2 &&
      !egress.any((r) => r.state == 'ON') &&
      barrier.length == 2 &&
      barrier.every(_barrierGone);
}

/// A-12-min R2: the native verdict on whether a persisted capture may leave the
/// device. Fail-closed: anything but [allowed] means zero egress.
enum CaptureUploadDecision { allowed, localOnly, waiting }

class CaptureUploadAuthorization {
  const CaptureUploadAuthorization(
    this.decision, {
    this.ownerUid,
    this.allowAi = false,
    this.contractV2 = false,
    this.ownerGeneration,
  });

  /// Zero egress. Used off iOS and whenever the native call fails.
  static const CaptureUploadAuthorization denied =
      CaptureUploadAuthorization(CaptureUploadDecision.localOnly);

  final CaptureUploadDecision decision;

  /// The stamped owner; set only when [decision] is allowed.
  final String? ownerUid;

  /// C.1: the owner generation the item was stamped under; set only when
  /// [decision] is allowed. The upload sends it as `owner_generation`.
  final int? ownerGeneration;

  /// The owner's consent mirror (never the install-level flag).
  final bool allowAi;

  /// The mirrored `capture_contract_v2` capability: the upload then carries
  /// `owner_uid` and `schema_version` 2.
  final bool contractV2;

  bool get allowed => decision == CaptureUploadDecision.allowed;
}

/// WP-8 quota state of one queue scope against the manifest §4.5 limits.
enum CaptureQuotaState {
  ok,
  near,
  full;

  static CaptureQuotaState parse(Object? raw) => CaptureQuotaState.values
      .firstWhere((s) => s.name == raw, orElse: () => CaptureQuotaState.ok);
}

/// Native queue statistics for diagnostics. Counts, bytes and quota state ONLY:
/// no text, sender, amount, merchant, account, id or uid, and no per-capture
/// list. Each queued item is in exactly one of [stamped], [localOnly],
/// [waiting] and [unbound].
class CaptureQueueStats {
  const CaptureQueueStats({
    required this.stamped,
    required this.localOnly,
    required this.waiting,
    required this.unbound,
    required this.activeOwnerBytes,
    required this.unboundBytes,
    required this.deviceBytes,
    required this.ownerQuota,
    required this.unboundQuota,
    required this.deviceQuota,
    this.migrationPending = false,
  });

  /// Stamped to the active owner and eligible to upload.
  final int stamped;

  /// Stamped to the active owner, never uploaded (captured with Cloud OFF).
  final int localOnly;

  /// Another owner's, or no owner is active: invisible until that owner returns.
  final int waiting;
  final int unbound;
  final int activeOwnerBytes;
  final int unboundBytes;
  final int deviceBytes;
  final CaptureQuotaState ownerQuota;
  final CaptureQuotaState unboundQuota;
  final CaptureQuotaState deviceQuota;

  /// The v2 queue is not migrated yet; its items are counted as unbound.
  final bool migrationPending;

  int get total => stamped + localOnly + waiting + unbound;

  static CaptureQueueStats? tryParse(Object? raw) {
    if (raw is! Map) return null;
    int n(String k) => raw[k] is int ? raw[k] as int : 0;
    return CaptureQueueStats(
      stamped: n('stamped'),
      localOnly: n('localOnly'),
      waiting: n('waiting'),
      unbound: n('unbound'),
      activeOwnerBytes: n('activeOwnerBytes'),
      unboundBytes: n('unboundBytes'),
      deviceBytes: n('deviceBytes'),
      ownerQuota: CaptureQuotaState.parse(raw['ownerQuota']),
      unboundQuota: CaptureQuotaState.parse(raw['unboundQuota']),
      deviceQuota: CaptureQuotaState.parse(raw['deviceQuota']),
      migrationPending: raw['migrationPending'] == true,
    );
  }
}

/// An unbound `legacy_v2` queue item as the native layer lists it (A6). The
/// text is the raw SMS: never log it.
class LegacyQueueItem {
  const LegacyQueueItem({
    required this.id,
    required this.text,
    required this.receivedAt,
  });

  final String id;
  final String text;
  final DateTime? receivedAt;
}

/// What the "N bank messages were received while you were signed out" prompt
/// may show: a count and the senders (§4.3). [ids] is the snapshot the claim /
/// discard CAS is checked against; it is never displayed.
class UnboundCaptureSummary {
  const UnboundCaptureSummary({required this.ids, required this.senders});

  final List<String> ids;
  final List<String> senders;

  int get count => ids.length;
}

enum CaptureClaimStatus {
  /// The CAS held; [CaptureClaimResult.count] items were bound / discarded.
  applied,

  /// The items changed since the prompt snapshot. Nothing was mutated.
  stale,

  /// uid, owner record, generation, replica owner and session uid did not all
  /// agree. Nothing was mutated.
  ownerMismatch,
}

class CaptureClaimResult {
  const CaptureClaimResult(this.status, this.count);

  final CaptureClaimStatus status;
  final int count;

  bool get applied => status == CaptureClaimStatus.applied;
}

/// §4.4 destructive barrier for a Remove-data run.
class CaptureRemovalBarrier {
  const CaptureRemovalBarrier({
    required this.nonce,
    required this.uidHash,
    required this.startedAt,
  });

  final String nonce;
  final String uidHash;
  final String startedAt;

  static CaptureRemovalBarrier? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final nonce = raw['nonce'];
    final hash = raw['uidHash'];
    final startedAt = raw['startedAt'];
    if (nonce is! String || hash is! String || startedAt is! String) {
      return null;
    }
    return CaptureRemovalBarrier(
      nonce: nonce,
      uidHash: hash,
      startedAt: startedAt,
    );
  }
}

/// F2 — what a read of the native Remove-data barrier found. The four outcomes
/// stay DISTINCT: [absent] (nothing is pending), [present], [malformed] (the
/// native layer answered with something unreadable: a barrier IS there) and — as
/// a thrown [CaptureQueueException] — a transport/read error. Only [absent] means
/// "no barrier"; collapsing malformed into absent would read a set barrier as
/// permission to admit.
enum CaptureRemovalBarrierPresence { absent, present, malformed }

class CaptureRemovalBarrierRead {
  const CaptureRemovalBarrierRead.absent()
      : presence = CaptureRemovalBarrierPresence.absent,
        barrier = null;
  const CaptureRemovalBarrierRead._present(CaptureRemovalBarrier this.barrier)
      : presence = CaptureRemovalBarrierPresence.present;
  const CaptureRemovalBarrierRead.malformed()
      : presence = CaptureRemovalBarrierPresence.malformed,
        barrier = null;

  final CaptureRemovalBarrierPresence presence;
  final CaptureRemovalBarrier? barrier;

  /// A native answer: null is absent, a well-formed record is present, anything
  /// else is malformed.
  static CaptureRemovalBarrierRead parse(Object? raw) {
    if (raw == null) return const CaptureRemovalBarrierRead.absent();
    final barrier = CaptureRemovalBarrier.tryParse(raw);
    if (barrier == null) return const CaptureRemovalBarrierRead.malformed();
    return CaptureRemovalBarrierRead._present(barrier);
  }
}

/// Why the native queue refused a write (v3). Nothing was written in any case.
enum CaptureQueueFailure {
  /// §4.5 count or byte quota exhausted. Nothing is evicted.
  quotaExceeded,

  /// A Remove-data barrier is in force (§4.4).
  removalInProgress,

  /// The active owner is not the owner the caller required.
  ownerChanged,

  /// Any other refusal (key, lock, unreadable queue, channel).
  unavailable,
}

/// Thrown by the owner / claim / barrier calls when the native layer refuses.
/// Callers MUST treat it as "the operation did not happen" and fail closed.
/// The native `cloud_egress_state` of one owner.
/// Strict getter-only diagnostic vocabulary; never carries native error text.
final class CaptureSnapshotDiagnostic {
  const CaptureSnapshotDiagnostic._(this.stage, this.category);
  final String stage;
  final String category;
  static CaptureSnapshotDiagnostic? parse(Object? raw) {
    if (raw is! Map ||
        raw.length != 3 ||
        raw['contract'] != 'snapshot_v1' ||
        !const {
          'lock',
          'barrier',
          'activeowner',
          'hmac',
          'ownerlesshint',
          'inflight'
        }.contains(raw['stage']) ||
        !const {
          'lock_unavailable',
          'interaction_not_allowed',
          'missing_entitlement',
          'decode',
          'key_other',
          'unreadable',
          'unexpected'
        }.contains(raw['category'])) {
      return null;
    }
    return CaptureSnapshotDiagnostic._(
        raw['stage'] as String, raw['category'] as String);
  }
}

class CaptureQueueException implements Exception {
  const CaptureQueueException(this.code, [this.message, this.diagnostic]);
  final CaptureSnapshotDiagnostic? diagnostic;

  String get safeDiagnostic {
    final safeCode = const {
      'queue_unavailable',
      'quota_exceeded',
      'removal_in_progress',
      'owner_changed',
      'stale_generation',
      'egress_denied',
      'bad_args',
      'channel_unavailable',
    }.contains(code)
        ? code
        : 'unknown';
    final d = diagnostic;
    return d == null ? safeCode : '$safeCode/${d.stage}/${d.category}';
  }

  /// `queue_unavailable`, `quota_exceeded`, `removal_in_progress`,
  /// `owner_changed`, `stale_generation` (P4: the write carried an older
  /// transition generation, or a config write was refused), `egress_denied`
  /// (C.4: a widening write while egress is denied/uncertain), `bad_args` or
  /// `channel_unavailable`.
  final String code;
  final String? message;

  CaptureQueueFailure get failure => _failureForCode(code);

  @override
  String toString() => 'CaptureQueueException($code)';
}

CaptureQueueFailure _failureForCode(String code) {
  switch (code) {
    case 'quota_exceeded':
      return CaptureQueueFailure.quotaExceeded;
    case 'removal_in_progress':
      return CaptureQueueFailure.removalInProgress;
    case 'owner_changed':
      return CaptureQueueFailure.ownerChanged;
    default:
      return CaptureQueueFailure.unavailable;
  }
}

class ApnsTokenInfo {
  const ApnsTokenInfo({
    required this.token,
    required this.environment,
  });

  final String token;
  final String environment;
}

class ApnsRegistrationFailure {
  const ApnsRegistrationFailure({
    required this.message,
    required this.occurredAt,
    this.domain,
    this.code,
  });

  final String message;
  final DateTime occurredAt;
  final String? domain;
  final int? code;
}

class CaptureNotificationRoute {
  const CaptureNotificationRoute({
    this.payloadId,
    this.transactionId,
    this.smartInboxItemId,
    this.notificationType,
    this.source,
    this.receivedAt,
    this.notificationLogId,
    this.action,
  });

  final String? payloadId;
  final String? transactionId;
  final String? smartInboxItemId;
  final String? notificationType;
  final String? source;
  final DateTime? receivedAt;
  final String? notificationLogId;

  /// Notification action button identifier; null for a plain banner tap.
  final String? action;
}

/// One notification lifecycle event recorded natively (iOS Shortcut local
/// fallback notifications) and drained here for Flutter to fold into the
/// local `notification_log_events` outbox — see
/// docs/NOTIFICATION_PIPELINE_AUDIT.md Phase 1.
class NativeNotificationLogEvent {
  const NativeNotificationLogEvent({
    required this.notificationLogId,
    required this.eventType,
    required this.channel,
    required this.notificationType,
    this.relatedEntityType,
    this.relatedEntityId,
    this.errorCode,
    this.errorReason,
    this.occurredAt,
    this.eventId,
    this.ownerUid,
    this.ownerGeneration,
    this.originKind,
  });

  final String notificationLogId;
  final String eventType;
  final String channel;
  final String notificationType;
  final String? relatedEntityType;
  final String? relatedEntityId;
  final String? errorCode;
  final String? errorReason;
  final DateTime? occurredAt;
  final String? eventId;
  final String? ownerUid;
  final int? ownerGeneration;
  final String? originKind;
}

/// MALI-013 — honest capture capabilities for Android (share always; SMS is
/// opt-in and two-key: declared in the build AND granted AND enabled). The old
/// `hasSmsPermission()` conflated notification and SMS permission; these fields
/// keep them strictly separate.
class CaptureCapabilities {
  const CaptureCapabilities({
    this.supportsShareCapture = true,
    this.receiveSmsDeclared = false,
    this.hasReceiveSmsPermission = false,
    this.canUseAutomaticSmsCapture = false,
    this.isAutomaticSmsCaptureEnabled = false,
    this.hasNotificationPermission = false,
  });

  /// "Share to Mali" — always available, needs no permission.
  final bool supportsShareCapture;

  /// Whether RECEIVE_SMS is declared in this build's manifest at all
  /// (false in a Play-safe, share-only build → automatic capture "not
  /// included in this build").
  final bool receiveSmsDeclared;
  final bool hasReceiveSmsPermission;

  /// The build declares + the OS grants RECEIVE_SMS (auto capture is possible).
  final bool canUseAutomaticSmsCapture;

  /// The user has turned automatic capture on AND it is permitted.
  final bool isAutomaticSmsCaptureEnabled;

  /// Notification permission — NEVER conflated with SMS.
  final bool hasNotificationPermission;

  factory CaptureCapabilities.fromJson(Map<String, dynamic> json) {
    return CaptureCapabilities(
      supportsShareCapture: json['supportsShareCapture'] as bool? ?? true,
      receiveSmsDeclared: json['receiveSmsDeclared'] as bool? ?? false,
      hasReceiveSmsPermission:
          json['hasReceiveSmsPermission'] as bool? ?? false,
      canUseAutomaticSmsCapture:
          json['canUseAutomaticSmsCapture'] as bool? ?? false,
      isAutomaticSmsCaptureEnabled:
          json['isAutomaticSmsCaptureEnabled'] as bool? ?? false,
      hasNotificationPermission:
          json['hasNotificationPermission'] as bool? ?? false,
    );
  }
}

/// Outcome of the Android runtime RECEIVE_SMS request.
///
/// `denied` and `permanentlyDenied` are separated deliberately: only the first
/// can be retried with a dialog. The second needs the Settings route, and
/// showing a button that silently does nothing is worse than showing none.
enum SmsPermissionStatus {
  /// Build does not declare RECEIVE_SMS — the automatic path is not in this build.
  unavailable,
  granted,

  /// Denied, but the system will still show the dialog if asked again.
  denied,

  /// "Don't ask again", or the OS blocks the prompt. Only Settings can change it.
  permanentlyDenied,

  /// A request is already in flight; never queue a second dialog.
  inProgress,
}

/// The full answer to a permission request: the outcome plus the resulting
/// capability state, so callers never infer consent from the outcome alone.
///
/// `granted` and `enabled` are separate on purpose — a granted permission is
/// NOT consent to read. The user opt-in is its own stored key.
class SmsPermissionResult {
  const SmsPermissionResult({
    required this.status,
    required this.declared,
    required this.granted,
    required this.enabled,
  });

  final SmsPermissionStatus status;
  final bool declared;
  final bool granted;
  final bool enabled;

  static const SmsPermissionResult unsupported = SmsPermissionResult(
    status: SmsPermissionStatus.unavailable,
    declared: false,
    granted: false,
    enabled: false,
  );

  factory SmsPermissionResult.fromJson(Map<String, dynamic> json) {
    return SmsPermissionResult(
      status: switch (json['status'] as String?) {
        'granted' => SmsPermissionStatus.granted,
        'denied' => SmsPermissionStatus.denied,
        'permanently_denied' => SmsPermissionStatus.permanentlyDenied,
        'in_progress' => SmsPermissionStatus.inProgress,
        _ => SmsPermissionStatus.unavailable,
      },
      declared: json['declared'] as bool? ?? false,
      granted: json['granted'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? false,
    );
  }
}

class NativeCaptureBridge {
  NativeCaptureBridge._();

  static const MethodChannel _channel =
      MethodChannel('money_companion/native_capture');
  static Future<void> Function()? _pendingMessagesHandler;
  static Future<void> Function(ApnsTokenInfo token)? _apnsTokenHandler;
  static Future<void> Function(ApnsRegistrationFailure failure)?
      _apnsFailureHandler;
  static Future<void> Function()? _notificationRouteHandler;

  static void setPendingMessagesHandler(
    Future<void> Function()? handler,
  ) {
    _pendingMessagesHandler = handler;
    _configureMethodHandler();
  }

  static void setApnsTokenUpdatedHandler(
    Future<void> Function(ApnsTokenInfo token)? handler,
  ) {
    _apnsTokenHandler = handler;
    _configureMethodHandler();
  }

  static void setApnsRegistrationFailedHandler(
    Future<void> Function(ApnsRegistrationFailure failure)? handler,
  ) {
    _apnsFailureHandler = handler;
    _configureMethodHandler();
  }

  static void setNotificationRouteHandler(
    Future<void> Function()? handler,
  ) {
    _notificationRouteHandler = handler;
    _configureMethodHandler();
  }

  static void _configureMethodHandler() {
    if (_pendingMessagesHandler == null &&
        _apnsTokenHandler == null &&
        _apnsFailureHandler == null &&
        _notificationRouteHandler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pendingSharedMessagesAvailable') {
        await _pendingMessagesHandler?.call();
        return null;
      }
      if (call.method == 'apnsTokenUpdated') {
        final token = _tokenInfoFrom(call.arguments);
        if (token != null) {
          await _apnsTokenHandler?.call(token);
        }
        return null;
      }
      if (call.method == 'apnsRegistrationFailed') {
        final failure = _apnsFailureFrom(call.arguments);
        if (failure != null) {
          await _apnsFailureHandler?.call(failure);
        }
        return null;
      }
      if (call.method == 'pendingNotificationRouteAvailable') {
        await _notificationRouteHandler?.call();
        return null;
      }
      throw MissingPluginException('Unknown native capture callback');
    });
  }

  /// MALI-013 — honest Android capture capabilities. Replaces the old
  /// `hasSmsPermission()` which mislabelled the NOTIFICATION permission as SMS.
  /// On non-Android platforms only share capture applies.
  static Future<CaptureCapabilities> captureCapabilities() async {
    if (!Platform.isAndroid) {
      return const CaptureCapabilities(supportsShareCapture: true);
    }
    try {
      final raw = await _channel.invokeMethod<String>('captureCapabilities');
      if (raw == null) {
        return const CaptureCapabilities(supportsShareCapture: true);
      }
      return CaptureCapabilities.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return const CaptureCapabilities(supportsShareCapture: true);
    }
  }

  /// Turn automatic SMS capture on/off (persisted natively). Returns the
  /// effective state — false unless RECEIVE_SMS is granted, whatever was asked.
  static Future<bool> setAutomaticSmsCaptureEnabled(bool enabled) async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>(
          'setAutomaticSmsCaptureEnabled',
          {'enabled': enabled},
        ) ??
        false;
  }

  /// Ask Android for RECEIVE_SMS.
  ///
  /// The caller MUST have shown the prominent disclosure immediately before
  /// this — Play requires it, and the native side deliberately shows no UI of
  /// its own so the disclosure cannot be skipped by calling straight through.
  ///
  /// Never throws: a platform error resolves to `unsupported` so a failure here
  /// can only ever leave automatic capture off, never on.
  static Future<SmsPermissionResult> requestReceiveSmsPermission() async {
    if (!Platform.isAndroid) return SmsPermissionResult.unsupported;
    try {
      final raw =
          await _channel.invokeMethod<String>('requestReceiveSmsPermission');
      if (raw == null) return SmsPermissionResult.unsupported;
      return SmsPermissionResult.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } on PlatformException {
      return SmsPermissionResult.unsupported;
    } on MissingPluginException {
      return SmsPermissionResult.unsupported;
    }
  }

  static Future<void> openAppSettings() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _channel.invokeMethod<void>('openAppSettings');
  }

  static Future<bool> hasPendingSharedMessages() async {
    if (!Platform.isIOS) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('hasPendingSharedMessages') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> setBackendConfig({
    required bool cloudProcessingEnabled,
    required String installId,
    required String backendUrl,
    required String anonKey,
    bool aiConsentGranted = false,
    String? deviceSecret,

    /// Mirror of the server capability `capture_contract_v2`. Default false:
    /// the App Intent keeps uploading on the legacy contract.
    bool captureContractV2 = false,

    /// P4: when BOTH are given the native write is refused with
    /// [CaptureQueueException] `stale_generation` if [transitionGeneration] is
    /// older than the stored egress generation for [ownerUid]. Omitted: no
    /// generation guard (a widening write is still refused natively while egress
    /// is denied or uncertain).
    String? ownerUid,
    int? transitionGeneration,
  }) async {
    if (!Platform.isIOS) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setCaptureBackendConfig', {
        'cloudProcessingEnabled': cloudProcessingEnabled,
        'installId': installId,
        'deviceSecret': deviceSecret,
        'backendUrl': backendUrl,
        'anonKey': anonKey,
        'aiConsentGranted': aiConsentGranted,
        'captureContractV2': captureContractV2,
        if (ownerUid != null) 'ownerUid': ownerUid,
        if (transitionGeneration != null)
          'transitionGeneration': transitionGeneration,
      });
    } on PlatformException catch (e) {
      if (e.code == 'stale_generation') {
        throw CaptureQueueException(e.code, e.message);
      }
      rethrow;
    } on MissingPluginException {
      return;
    }
  }

  /// N-R8 (N-CR-1): the same `setCaptureBackendConfig` call, but for a caller
  /// that must treat a normal return as "the native method ran and accepted".
  /// A missing method or channel ([MissingPluginException]), any other platform
  /// failure and a platform without the native queue all PROPAGATE: only a
  /// native acknowledgment returns normally. That return is an execution
  /// acknowledgment, not independent crash-durability proof (the native write is
  /// an optional defaults write); the verified native egress record remains the
  /// security evidence. `stale_generation` surfaces as [CaptureQueueException].
  static Future<void> setBackendConfigAcknowledged({
    required bool cloudProcessingEnabled,
    required String installId,
    required String backendUrl,
    required String anonKey,
    bool aiConsentGranted = false,
    String? deviceSecret,
    bool captureContractV2 = false,
    String? ownerUid,
    int? transitionGeneration,
  }) async {
    if (!_hasNativeQueue) {
      throw const CaptureQueueException(
          'unsupported', 'no native capture queue on this platform');
    }
    try {
      await _channel.invokeMethod<void>('setCaptureBackendConfig', {
        'cloudProcessingEnabled': cloudProcessingEnabled,
        'installId': installId,
        'deviceSecret': deviceSecret,
        'backendUrl': backendUrl,
        'anonKey': anonKey,
        'aiConsentGranted': aiConsentGranted,
        'captureContractV2': captureContractV2,
        if (ownerUid != null) 'ownerUid': ownerUid,
        if (transitionGeneration != null)
          'transitionGeneration': transitionGeneration,
      });
    } on PlatformException catch (e) {
      if (e.code == 'stale_generation') {
        throw CaptureQueueException(e.code, e.message);
      }
      rethrow;
    }
  }

  // ── CAP-6 queue v3: owner record, unbound claim, Remove-data barrier ───────
  //
  // Every call below runs natively under the queue flock. They throw
  // [CaptureQueueException] when the native layer refuses and do nothing on
  // platforms without the iOS queue. The account-scoped drain/import that uses
  // them (WP-3 / CAP-5) is NOT implemented here.

  static bool get _hasNativeQueue => debugTreatHostAsNative || Platform.isIOS;

  /// Whether this platform has the native v3 queue (iOS). Platforms without it
  /// (Android, manual paste) have no native upload gate to consult.
  static bool get hasNativeQueue => _hasNativeQueue;

  /// ASR §5 (C2): the native writes of egress, pending, barrier or owner state
  /// issued from Dart, and whether each is an IDENTITY cause (removal, barrier,
  /// owner clear) rather than POLICY.
  static const Map<String, bool> protectedNativeWrites = {
    'publishCaptureOwner': false,
    'publishRestrictiveCaptureOwner': false,
    'repairActiveOwnerGeneration': false,
    'revokeCaptureAuthorizationLifetime': false,
    'setCaptureConsentMirror': false,
    'setCloudEgressState': false,
    'beginCloudEgressEnable': false,
    'writeCloudEgressEnableOn': false,
    'restrictCloudEgressEnable': false,
    'finishCloudEgressEnable': false,
    'resolveLegacyCaptureItems': false,
    'mintExpiryEvidenceForLiveOn': false,
    'invalidateExpiryEvidence': false,
    'retireSuccessor': false,
    'clearCaptureOwner': true,
    'beginCaptureRemoval': true,
    'finishCaptureRemoval': true,
    'purgeAllCaptureState': true,
  };

  /// Wired by the egress gate: appends the typed cause of a protected native
  /// write. Called synchronously BEFORE the channel call. [authority] is the
  /// ASR op an owned successor-chain write belongs to (§11.2); every other
  /// write passes none and is foreign to every op.
  static void Function(String method,
      {required bool identity, Object? authority})? onProtectedNativeWrite;

  static void _noteProtectedWrite(String method, Object? authority) {
    final identity = protectedNativeWrites[method];
    if (identity != null) {
      onProtectedNativeWrite?.call(method,
          identity: identity, authority: authority);
    }
  }

  static Future<T?> _queueCall<T>(
    String method, [
    Map<String, Object?>? arguments,
    Object? causeAuthority,
  ]) async {
    _noteProtectedWrite(method, causeAuthority);
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw CaptureQueueException(
          e.code,
          e.message,
          method == 'getCloudEgressState'
              ? CaptureSnapshotDiagnostic.parse(e.details)
              : null);
    } on MissingPluginException {
      throw const CaptureQueueException('channel_unavailable');
    }
  }

  /// Publishes [uid] as the active capture owner together with its consent
  /// mirror, in ONE native flock (A-12-min R4): the mirror is written first, the
  /// owner second. Cloud OFF publishes locally; Cloud ON only after
  /// `link_capture_device(consent)` succeeded (§4.2). [expectedEpoch] (from
  /// [captureOwnerEpoch], read BEFORE any network step) is a compare-and-swap: a
  /// sign-out / transition / removal clear in between makes the native call fail
  /// (`owner_changed`) instead of publishing a stale owner. Refused
  /// (`removal_in_progress`) during a barrier.
  static Future<CaptureOwnerRecord?> publishCaptureOwner({
    required String uid,
    required bool cloud,
    required bool ai,
    required int version,
    required int expectedEpoch,
    int? transitionGeneration,
  }) async {
    if (!_hasNativeQueue) return null;
    return CaptureOwnerRecord.tryParse(
      await _queueCall<Object?>('publishCaptureOwner', {
        'uid': uid,
        'cloud': cloud,
        'ai': ai,
        'version': version,
        'expectedEpoch': expectedEpoch,
        if (transitionGeneration != null)
          'transitionGeneration': transitionGeneration,
      }),
    );
  }

  /// Re-claims the SAME active owner with a fresh generation when only the
  /// native generation counter is inconsistent. Null when unavailable or refused.
  static Future<CaptureOwnerRecord?> repairActiveOwnerGeneration(
      {required String uid}) async {
    if (!_hasNativeQueue) return null;
    try {
      return CaptureOwnerRecord.tryParse(await _queueCall<Object?>(
          'repairActiveOwnerGeneration', {'uid': uid}));
    } catch (_) {
      return null;
    }
  }

  /// N: a restrictive local publication receipt; no backend linking is performed.
  static Future<RestrictiveCaptureOwnerReceipt?>
      publishRestrictiveCaptureOwner({
    required String uid,
    required int version,
    required int expectedEpoch,
    int? expectedTransitionGeneration,
    int? expectedReservedVersion,
    int? expectedLifetimeOwnerGeneration,
    int? expectedLifetimeOwnerEpoch,
    List<CloudEgressLayerReport>? expectedOffCopies,
    List<CloudEgressLayerReport>? expectedRetiredCopies,
    ({String evidenceId, int expectedCounter})? successorOf,
    Object? causeAuthority,
  }) async {
    if (!_hasNativeQueue) return null;
    return RestrictiveCaptureOwnerReceipt.tryParse(
        await _queueCall<Object?>('publishRestrictiveCaptureOwner', {
      'uid': uid, 'version': version, 'expectedEpoch': expectedEpoch,
      if (expectedOffCopies != null)
        'expectedOffCopies': [
          for (final r in expectedOffCopies) {
            'layer': r.layer,
            'transitionGeneration': r.transitionGeneration,
            'reservedVersion': r.reservedVersion,
            if (r.ownerGeneration != null) 'ownerGeneration': r.ownerGeneration,
            if (r.ownerEpoch != null) 'ownerEpoch': r.ownerEpoch,
          },
        ],
      // The inspected retired OFF snapshot: a held layer names its retirement,
      // an absent layer only itself.
      if (expectedRetiredCopies != null)
        'expectedRetiredCopies': [
          for (final r in expectedRetiredCopies)
            {
              'layer': r.layer,
              if (r.outcome == CloudEgressLayerOutcome.verified) ...{
                'operationId': r.operationId,
                'transitionGeneration': r.transitionGeneration,
                'reservedVersion': r.reservedVersion,
                'ownerGeneration': r.ownerGeneration,
                'ownerEpoch': r.ownerEpoch,
              },
            },
        ],
      // ASR §7.5 SE1: a successor of exactly this expiry evidence.
      if (successorOf != null) ...{
        'successorEvidenceId': successorOf.evidenceId,
        'successorExpectedCounter': successorOf.expectedCounter,
      },
      // Recovery mode: native writes only while BOTH layers still hold exactly
      // this inspected OFF record, and `version` is strictly above it.
      if (expectedTransitionGeneration != null &&
          expectedReservedVersion != null) ...{
        'expectedTransitionGeneration': expectedTransitionGeneration,
        'expectedReservedVersion': expectedReservedVersion,
        // Absent means the agreed UNBOUND legacy record (no lifetime evidence).
        if (expectedLifetimeOwnerGeneration != null)
          'expectedLifetimeOwnerGeneration': expectedLifetimeOwnerGeneration,
        if (expectedLifetimeOwnerEpoch != null)
          'expectedLifetimeOwnerEpoch': expectedLifetimeOwnerEpoch,
      },
    }, causeAuthority));
  }

  /// ASR §7.2: [expirySessionLifecycle] only for cause `sessionExpiry`; native
  /// then mints expiry evidence when (and only when) its conditions hold.
  static Future<CloudEgressEnableResult?> revokeCaptureAuthorizationLifetime({
    required String ownerUid,
    required CloudEgressEnableBinding binding,
    int? expirySessionLifecycle,
  }) async {
    if (!_hasNativeQueue) return null;
    return CloudEgressEnableResult.tryParse(
        await _queueCall<Object?>('revokeCaptureAuthorizationLifetime', {
      ..._phaseArguments(ownerUid, binding),
      if (expirySessionLifecycle != null)
        'expirySessionLifecycle': expirySessionLifecycle,
    }));
  }

  /// ASR §7.4: one locked read-only snapshot. Null off iOS or on any failure.
  static Future<RecoveryEvidenceSnapshot?> inspectRecoveryEvidence(
      {required String ownerUid}) async {
    if (!_hasNativeQueue) return null;
    try {
      return RecoveryEvidenceSnapshot.tryParse(await _queueCall<Object?>(
          'inspectRecoveryEvidence', {'ownerUid': ownerUid}));
    } catch (_) {
      return null;
    }
  }

  /// ASR §7.4: true only when native confirms no protected write since
  /// [expectedCounter]; false on any failure.
  static Future<bool> confirmRecoveryEvidence(int expectedCounter) async {
    if (!_hasNativeQueue) return false;
    try {
      return await _queueCall<bool>('confirmRecoveryEvidence',
              {'expectedCounter': expectedCounter}) ==
          true;
    } catch (_) {
      return false;
    }
  }

  /// ASR §7.6 E2-b: conditional expiry retirement of an inspected live ON.
  static Future<CloudEgressEnableResult?> mintExpiryEvidenceForLiveOn({
    required String ownerUid,
    required int ownerGeneration,
    required int ownerEpoch,
    required int transitionGeneration,
    required int reservedVersion,
    required int sessionLifecycle,
    required int expectedCounter,
  }) async {
    if (!_hasNativeQueue) return null;
    return _enableResult(
        'mintExpiry',
        await _queueCall<Object?>('mintExpiryEvidenceForLiveOn', {
          'ownerUid': ownerUid,
          'ownerGeneration': ownerGeneration,
          'ownerEpoch': ownerEpoch,
          'transitionGeneration': transitionGeneration,
          'reservedVersion': reservedVersion,
          'sessionLifecycle': sessionLifecycle,
          'expectedCounter': expectedCounter,
        }));
  }

  /// ASR §7.7: removes exactly [evidenceId] natively.
  static Future<CloudEgressEnableResult?> invalidateExpiryEvidence(
      {required String ownerUid, required String evidenceId}) async {
    if (!_hasNativeQueue) return null;
    return _enableResult(
        'invalidateExpiry',
        await _queueCall<Object?>('invalidateExpiryEvidence',
            {'ownerUid': ownerUid, 'evidenceId': evidenceId}));
  }

  /// ASR §7.5: exact retirement of successor lifetime [successorGeneration].
  static Future<CloudEgressEnableResult?> retireSuccessor({
    required String ownerUid,
    required int successorGeneration,
    required int ownerEpoch,
    required String operationId,
    Object? causeAuthority,
  }) async {
    if (!_hasNativeQueue) return null;
    return _enableResult(
        'retireSuccessor',
        await _queueCall<Object?>('retireSuccessor', {
          'ownerUid': ownerUid,
          'successorGeneration': successorGeneration,
          'ownerEpoch': ownerEpoch,
          'operationId': operationId,
        }, causeAuthority));
  }

  /// ASR §7.5.1: `finished`, `behindBarrier` or `other` (also on any failure).
  static Future<String> inspectSuccessor({
    required String ownerUid,
    required int successorGeneration,
    required int ownerEpoch,
    required String operationId,
  }) async {
    if (!_hasNativeQueue) return 'other';
    try {
      final raw = await _queueCall<Object?>('inspectSuccessor', {
        'ownerUid': ownerUid,
        'successorGeneration': successorGeneration,
        'ownerEpoch': ownerEpoch,
        'operationId': operationId,
      });
      return raw == 'finished' || raw == 'behindBarrier'
          ? raw as String
          : 'other';
    } catch (_) {
      return 'other';
    }
  }

  /// The owner epoch, bumped natively by every owner clear. 0 off iOS.
  static Future<int> captureOwnerEpoch() async {
    if (!_hasNativeQueue) return 0;
    return await _queueCall<int>('captureOwnerEpoch') ?? 0;
  }

  /// A-12-min R2: the single upload gate. Every egress of a persisted capture,
  /// including the app's `pendingSend` replay, needs [CaptureUploadAuthorization.allowed].
  /// Off iOS, and on any native failure, the answer is [CaptureUploadAuthorization.denied].
  static Future<CaptureUploadAuthorization> authorizeCaptureUpload(
      String payloadId) async {
    if (!_hasNativeQueue) return CaptureUploadAuthorization.denied;
    try {
      final raw = await _queueCall<Object?>(
          'authorizeCaptureUpload', {'payloadId': payloadId});
      if (raw is! Map) return CaptureUploadAuthorization.denied;
      switch (raw['decision']) {
        case 'allowed':
          final uid = raw['ownerUid'];
          if (uid is! String || uid.isEmpty) {
            return CaptureUploadAuthorization.denied;
          }
          return CaptureUploadAuthorization(
            CaptureUploadDecision.allowed,
            ownerUid: uid,
            allowAi: raw['allowAi'] == true,
            contractV2: raw['contractV2'] == true,
            ownerGeneration: raw['ownerGeneration'] is int
                ? raw['ownerGeneration'] as int
                : null,
          );
        case 'waiting':
          return const CaptureUploadAuthorization(
              CaptureUploadDecision.waiting);
        default:
          return CaptureUploadAuthorization.denied;
      }
    } on CaptureQueueException {
      return CaptureUploadAuthorization.denied;
    }
  }

  /// WP-8 diagnostics: queue counts, bytes and quota state (content-free, read
  /// only, no per-capture list). Null off iOS or when the native call fails.
  static Future<CaptureQueueStats?> captureQueueStats() async {
    if (!_hasNativeQueue) return null;
    try {
      return CaptureQueueStats.tryParse(
          await _queueCall<Object?>('captureQueueStats'));
    } on CaptureQueueException {
      return null;
    }
  }

  /// Clears the active owner (sign-out, or the start of an account transition).
  /// [clearHint] true at a transition: captures made during it are unbound with
  /// no hint. At a plain sign-out the hint stays so the same uid can recover.
  static Future<void> clearCaptureOwner({required bool clearHint}) async {
    if (!_hasNativeQueue) return;
    await _queueCall<Object?>('clearCaptureOwner', {'clearHint': clearHint});
  }

  static Future<CaptureOwnerRecord?> getCaptureOwner() async {
    if (!_hasNativeQueue) return null;
    return CaptureOwnerRecord.tryParse(
      await _queueCall<Object?>('getCaptureOwner'),
    );
  }

  /// Advisory per-owner consent mirror, read by the App Intent for the stamped
  /// owner only (§4.6). Written by the consent flow (WP-6).
  static Future<void> setCaptureConsentMirror({
    required String uid,
    required bool cloud,
    required bool ai,
    required int version,
    int? transitionGeneration,
  }) async {
    if (!_hasNativeQueue) return;
    await _queueCall<Object?>('setCaptureConsentMirror', {
      'uid': uid,
      'cloud': cloud,
      'ai': ai,
      'version': version,
      if (transitionGeneration != null)
        'transitionGeneration': transitionGeneration,
    });
  }

  /// C.4: writes `cloud_egress_state` to BOTH native stores (shared Keychain and
  /// an App Group file) under the queue flock. [state] is `ON`, `DISABLING` or
  /// `OFF`. Throws [CaptureQueueException]: `stale_generation` (older than the
  /// stored generation for [ownerUid], or an ON that is not strictly newer than
  /// a stored OFF/DISABLING at the same generation), `egress_denied` (ON over a wholly unreadable/corrupt state: write a
  /// restrictive state first), `queue_unavailable` (no store took it; an ON
  /// needs both). A restrictive write succeeds if at least one store took it.
  /// No-op off iOS (Android keeps its own store).
  static Future<void> setCloudEgressState({
    required String state,
    required String ownerUid,
    required int transitionGeneration,
    required int reservedVersion,
  }) async {
    if (!_hasNativeQueue) return;
    await _queueCall<Object?>('setCloudEgressState', {
      'state': state,
      'ownerUid': ownerUid,
      'transitionGeneration': transitionGeneration,
      'reservedVersion': reservedVersion,
    });
  }

  /// C.5: the reconciled native `cloud_egress_state` entry of [ownerUid] (a valid
  /// DISABLING/OFF in either store wins). The state is stored per owner (keyed by
  /// the HMAC uidHash): another owner's entry is never applied to, or discarded
  /// by, this call. Null off iOS. Throws [CaptureQueueException] when the native
  /// layer is unavailable: the caller MUST fail closed on that, on null, and on
  /// [CloudEgressSnapshot.uncertain] (an unreadable store denies every owner).
  static Future<CloudEgressSnapshot?> getCloudEgressState({
    required String ownerUid,
  }) async {
    if (!_hasNativeQueue) return null;
    return CloudEgressSnapshot.tryParse(
      await _queueCall<Object?>('getCloudEgressState', {'ownerUid': ownerUid}),
    );
  }

  /// Pending explicit-enable barrier (consent-security amendment), phase 1.
  /// Persists the owner's pending denial in BOTH native layers, read back, BEFORE
  /// any ON is written. The operation is bound natively to the COMMITTED native
  /// active owner and its F2 generation / epoch: with no committed owner (a first
  /// use whose publication is deferred or not yet committed) or another owner the
  /// reply is `ownerMismatch` and nothing is written or minted, so the caller
  /// must wait or refuse honestly. A fresh begin NEVER adopts an existing
  /// operation, even with identical parameters: it is a `conflict` that reports
  /// the pending operation. A [resume] of that exact operation (its full binding,
  /// from [getCloudEgressPending]) is the only way to repair it. The returned
  /// [CloudEgressEnableResult.binding] is what every later phase must present.
  /// Throws [CaptureQueueException] `removal_in_progress` during Remove data and
  /// `malformed_transition_result` for any reply that is not a valid result. Null
  /// off iOS (no native layer). Success is ONLY
  /// [CloudEgressEnableResult.confirmsBarrierEstablished].
  static Future<CloudEgressEnableResult?> beginCloudEgressEnable({
    required String ownerUid,
    required int transitionGeneration,
    required int reservedVersion,
    CloudEgressEnableBinding? resume,
    ({String evidenceId, int expectedCounter})? successor,
    Object? causeAuthority,
  }) async {
    if (resume != null && successor != null) {
      throw ArgumentError('a successor begin is never a resume');
    }
    if (resume != null &&
        (resume.transitionGeneration != transitionGeneration ||
            resume.reservedVersion != reservedVersion)) {
      throw ArgumentError('resume must name the same generation and version');
    }
    if (!_hasNativeQueue) return null;
    return _enableResult(
      'begin',
      await _queueCall<Object?>('beginCloudEgressEnable', {
        'ownerUid': ownerUid,
        'transitionGeneration': transitionGeneration,
        'reservedVersion': reservedVersion,
        if (resume != null) 'resumeOperationId': resume.operationId,
        if (resume != null) 'resumeOwnerEpoch': resume.ownerEpoch,
        if (successor != null) ...{
          'successorEvidenceId': successor.evidenceId,
          'successorExpectedCounter': successor.expectedCounter,
        },
      }, successor == null ? null : causeAuthority),
    );
  }

  static Map<String, Object?> _phaseArguments(
          String ownerUid, CloudEgressEnableBinding binding) =>
      {
        'ownerUid': ownerUid,
        'operationId': binding.operationId,
        'transitionGeneration': binding.transitionGeneration,
        'reservedVersion': binding.reservedVersion,
        'ownerGeneration': binding.ownerGeneration,
        'ownerEpoch': binding.ownerEpoch,
      };

  /// Phase 2: writes ON for the exact pending operation into each native egress
  /// layer and reads each back, only while the operation's owner lifecycle is
  /// still the live one (else `ownerMismatch`). The barrier stays, so nothing is
  /// admitted yet. Success is ONLY [CloudEgressEnableResult.confirmsOnWritten].
  static Future<CloudEgressEnableResult?> writeCloudEgressEnableOn({
    required String ownerUid,
    required CloudEgressEnableBinding binding,
    int? expectedCounter,
    Object? causeAuthority,
  }) async {
    if (!_hasNativeQueue) return null;
    return _enableResult(
      'writeOn',
      await _queueCall<Object?>('writeCloudEgressEnableOn', {
        ..._phaseArguments(ownerUid, binding),
        if (expectedCounter != null) 'expectedCounter': expectedCounter,
      }, causeAuthority),
    );
  }

  /// Phase 3, compensation: per layer, and only for an operation the native
  /// barrier proves. No barrier, an unreadable barrier or another operation
  /// writes nothing (`noBarrier` / `uncertain` / `conflict`); a newer generation
  /// and an unreadable layer are never touched. Never lifts the barrier. Success
  /// is ONLY [CloudEgressEnableResult.confirmsRestricted]; anything else keeps
  /// denial.
  static Future<CloudEgressEnableResult?> restrictCloudEgressEnable({
    required String ownerUid,
    required CloudEgressEnableBinding binding,
    Object? causeAuthority,
  }) async {
    if (!_hasNativeQueue) return null;
    return _enableResult(
      'restrict',
      await _queueCall<Object?>('restrictCloudEgressEnable',
          _phaseArguments(ownerUid, binding), causeAuthority),
    );
  }

  /// Phase 4: the only way the barrier is lifted. [abandon] false completes the
  /// operation: native re-reads the Remove-data barrier and the live owner under
  /// its lock (an older queued complete after a logout / readmission is an
  /// `ownerMismatch` and clears nothing) and verifies ON in both egress layers.
  /// [abandon] true abandons it: native requires NO ON for the owner in either
  /// layer (a prior grant is not exempt: restrict it first). Success is ONLY
  /// [CloudEgressEnableResult.confirmsCompleted] / [confirmsAbandoned]; a
  /// partial clear is `incomplete` and the remaining layer keeps denying.
  static Future<CloudEgressEnableResult?> finishCloudEgressEnable({
    required String ownerUid,
    required CloudEgressEnableBinding binding,
    required bool abandon,
    int? expectedCounter,
    Object? causeAuthority,
  }) async {
    if (expectedCounter != null && abandon) {
      throw ArgumentError('a counter-bound finish is a completion');
    }
    if (!_hasNativeQueue) return null;
    return _enableResult(
      abandon ? 'abandon' : 'complete',
      await _queueCall<Object?>('finishCloudEgressEnable', {
        ..._phaseArguments(ownerUid, binding),
        'abandon': abandon,
        if (expectedCounter != null) 'expectedCounter': expectedCounter,
      }, causeAuthority),
    );
  }

  /// Read-only: what each native layer holds for [ownerUid]'s pending barrier and
  /// egress entry, so a restart can find the operation it must finish. Null off
  /// iOS.
  static Future<CloudEgressEnableResult?> getCloudEgressPending({
    required String ownerUid,
  }) async {
    if (!_hasNativeQueue) return null;
    return _enableResult(
      'inspect',
      await _queueCall<Object?>(
          'getCloudEgressPending', {'ownerUid': ownerUid}),
    );
  }

  /// A malformed, null or wrong-operation reply on iOS is a failure, never a
  /// result: the caller must fail closed on the exception.
  static CloudEgressEnableResult _enableResult(String operation, Object? raw) {
    final parsed = CloudEgressEnableResult.tryParse(raw);
    if (parsed == null || parsed.operation != operation) {
      throw const CaptureQueueException('malformed_transition_result');
    }
    return parsed;
  }

  /// C.4: native (App Intent / extension) uploads already admitted for
  /// [ownerUid] and not yet past their registry deadline (admitted_at + the
  /// 8 s URLSession timeout + 2 s). Disable must wait until [latestDeadline]
  /// (entries past it count as finished). Null means unavailable (unreadable
  /// registry or no lock): the caller fails closed by waiting the longest
  /// possible deadline. Off iOS there is no native process: count 0.
  static Future<({int count, DateTime? latestDeadline})?>
      nativeInflightUploads({
    required String ownerUid,
  }) async {
    if (!_hasNativeQueue) return (count: 0, latestDeadline: null);
    try {
      final raw = await _queueCall<Object?>(
          'nativeInflightUploads', {'ownerUid': ownerUid});
      if (raw is! Map) return null;
      final count = raw['count'];
      if (count is! int) return null;
      final ms = raw['latestDeadlineMs'];
      return (
        count: count,
        latestDeadline:
            ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null,
      );
    } on CaptureQueueException {
      return null;
    }
  }

  /// The unbound items hinted to [uid]; empty when there are none, or when the
  /// hint is another uid's or absent.
  static Future<UnboundCaptureSummary> unboundCaptureSummary(String uid) async {
    if (!_hasNativeQueue) {
      return const UnboundCaptureSummary(ids: [], senders: []);
    }
    final raw =
        await _queueCall<Object?>('unboundCaptureSummary', {'uid': uid});
    if (raw is! Map) return const UnboundCaptureSummary(ids: [], senders: []);
    List<String> strings(Object? v) =>
        v is List ? v.whereType<String>().toList() : const <String>[];
    return UnboundCaptureSummary(
      ids: strings(raw['ids']),
      senders: strings(raw['senders']),
    );
  }

  /// "Add them to my account" (§4.3): the native CAS. [uid], [replicaOwnerUid]
  /// and [sessionUid] must all be equal and [generation] the current owner
  /// generation, else nothing is mutated.
  static Future<CaptureClaimResult> claimUnboundCaptures({
    required String uid,
    required int generation,
    required String replicaOwnerUid,
    required String sessionUid,
    required List<String> ids,
  }) =>
      _claimCall('claimUnboundCaptures', uid, generation, replicaOwnerUid,
          sessionUid, ids);

  /// "Discard them": the same CAS, then deletes the items.
  static Future<CaptureClaimResult> discardUnboundCaptures({
    required String uid,
    required int generation,
    required String replicaOwnerUid,
    required String sessionUid,
    required List<String> ids,
  }) =>
      _claimCall('discardUnboundCaptures', uid, generation, replicaOwnerUid,
          sessionUid, ids);

  static Future<CaptureClaimResult> _claimCall(
    String method,
    String uid,
    int generation,
    String replicaOwnerUid,
    String sessionUid,
    List<String> ids,
  ) async {
    if (!_hasNativeQueue) {
      return const CaptureClaimResult(CaptureClaimStatus.stale, 0);
    }
    final raw = await _queueCall<Object?>(method, {
      'uid': uid,
      'generation': generation,
      'replicaOwnerUid': replicaOwnerUid,
      'sessionUid': sessionUid,
      'ids': ids,
    });
    final map = raw is Map ? raw : const <Object?, Object?>{};
    final count = map['count'] is int ? map['count'] as int : 0;
    switch (map['status']) {
      case 'applied':
        return CaptureClaimResult(CaptureClaimStatus.applied, count);
      case 'owner_mismatch':
        return const CaptureClaimResult(CaptureClaimStatus.ownerMismatch, 0);
      default:
        // Unknown or missing status: treat as "did not happen".
        return const CaptureClaimResult(CaptureClaimStatus.stale, 0);
    }
  }

  /// §4.7: the adopted replica's verdict on items migrated from the v2 queue.
  /// [consumedIds] (receipt `capture_payload:<id>` or tx.id == capture_id) are
  /// removed; [suspectedIds] (fingerprint match) are annotated for review only.
  /// Returns how many items were removed.
  static Future<int> resolveLegacyCaptureItems({
    List<String> consumedIds = const [],
    List<String> suspectedIds = const [],
  }) async {
    if (!_hasNativeQueue) return 0;
    final removed = await _queueCall<int>('resolveLegacyCaptureItems', {
      'consumedIds': consumedIds,
      'suspectedIds': suspectedIds,
    });
    return removed ?? 0;
  }

  /// A6 (CAP-7): the unbound `legacy_v2` items, read-only, for the resolver's
  /// fingerprint check. Content-bearing: never log it. Empty off iOS, and on any
  /// native failure (the check then simply does not run).
  static Future<List<LegacyQueueItem>> peekLegacyCaptureItems() async {
    if (!_hasNativeQueue) return const [];
    try {
      final raw = await _queueCall<Object?>('peekLegacyCaptureItems');
      if (raw is! List) return const [];
      final items = <LegacyQueueItem>[];
      for (final entry in raw) {
        if (entry is! Map) continue;
        final id = entry['id'];
        final text = entry['text'];
        if (id is! String || text is! String) continue;
        DateTime? at(Object? v) => v is String ? DateTime.tryParse(v) : null;
        items.add(LegacyQueueItem(
          id: id,
          text: text,
          receivedAt: at(entry['receivedAt']) ?? at(entry['createdAt']),
        ));
      }
      return items;
    } on CaptureQueueException {
      return const [];
    }
  }

  /// Mirrors Qirsh's chosen language for capture notifications while closed.
  static Future<int> shortcutSetupProbeStatus() async {
    try {
      final value = await _channel.invokeMethod<num>('shortcutSetupProbeStatus');
      return value?.toInt() ?? 0;
    } on MissingPluginException {
      return 0;
    } on PlatformException {
      return 0;
    }
  }

  static Future<void> setNotificationLanguage(String code) async {
    if (!_hasNativeQueue) return;
    final language = code.toLowerCase().split(RegExp('[-_]')).first == 'ar'
        ? 'ar'
        : 'en';
    try {
      await _channel.invokeMethod<void>(
          'setNotificationLanguage', {'language': language});
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  /// CAP-7: mirrors the `capture_notify_v2` flag for the App Intent. Best-effort.
  static Future<void> setCaptureNotifyV2(bool enabled) async {
    if (!_hasNativeQueue) return;
    try {
      await _channel
          .invokeMethod<void>('setCaptureNotifyV2', {'enabled': enabled});
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  /// Mirrors the user's "hide lock-screen content" preference for the App
  /// Intent, which builds capture banners without Flutter. Best-effort.
  static Future<void> setHideCaptureDetails(bool hide) async {
    if (!_hasNativeQueue) return;
    try {
      await _channel
          .invokeMethod<void>('setHideCaptureDetails', {'hide': hide});
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  /// CAP-7 correction: removes this capture's still-delivered App Intent banner.
  /// True only when one was delivered (so a correction replaces it).
  static Future<bool> withdrawDeliveredCaptureAlert(String payloadId) async {
    if (!_hasNativeQueue) return false;
    try {
      return await _channel.invokeMethod<bool>(
              'withdrawDeliveredCaptureAlert', {'payloadId': payloadId}) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Remove-data step 1 (§4.4): persists the barrier and clears the owner record
  /// if it is [uid]'s. Idempotent for the same uid (a resumed removal).
  static Future<CaptureRemovalBarrier?> beginCaptureRemoval(String uid) async {
    if (!_hasNativeQueue) return null;
    return CaptureRemovalBarrier.tryParse(
      await _queueCall<Object?>('beginCaptureRemoval', {'uid': uid}),
    );
  }

  /// A barrier left by a removal that crashed; a launch that finds one resumes
  /// the removal from the replica teardown step.
  static Future<CaptureRemovalBarrier?> getCaptureRemovalBarrier() async =>
      (await readCaptureRemovalBarrier()).barrier;

  /// F2: the barrier read with absent / present / malformed kept distinct; a
  /// transport or read error throws [CaptureQueueException]. The removal flow
  /// uses this one: only a successful read of "absent" lets anyone be admitted.
  static Future<CaptureRemovalBarrierRead> readCaptureRemovalBarrier() async {
    if (!_hasNativeQueue) return const CaptureRemovalBarrierRead.absent();
    return CaptureRemovalBarrierRead.parse(
      await _queueCall<Object?>('getCaptureRemovalBarrier'),
    );
  }

  /// Remove-data step 5 (§4.4): the final sweep; clears the barrier. Returns how
  /// many queue items were deleted.
  static Future<int> finishCaptureRemoval(String uid) async {
    if (!_hasNativeQueue) return 0;
    return await _queueCall<int>('finishCaptureRemoval', {'uid': uid}) ?? 0;
  }

  static Future<ApnsTokenInfo?> registerForRemoteNotifications(
      {int? transitionGeneration}) async {
    if (!_hasNativeQueue) return null; // iOS only (or the host test seam)
    try {
      final result = await _channel.invokeMethod<Object?>(
          'registerForRemoteNotifications',
          {'transitionGeneration': transitionGeneration});
      return _tokenInfoFrom(result);
    } on MissingPluginException {
      return null;
    }
  }

  static Future<ApnsTokenInfo?> getApnsToken() async {
    if (!Platform.isIOS) return null;
    try {
      final result = await _channel.invokeMethod<Object?>('getApnsToken');
      return _tokenInfoFrom(result);
    } on MissingPluginException {
      return null;
    }
  }

  static Future<ApnsRegistrationFailure?> getApnsRegistrationFailure() async {
    if (!Platform.isIOS) return null;
    try {
      final result =
          await _channel.invokeMethod<Object?>('getApnsRegistrationFailure');
      return _apnsFailureFrom(result);
    } on MissingPluginException {
      return null;
    }
  }

  static Future<String?> consumePendingSharedInput() async {
    if (!Platform.isIOS) {
      return null;
    }
    final text =
        await _channel.invokeMethod<String>('consumePendingSharedInput');
    if (text == null || text.trim().isEmpty) {
      return null;
    }
    return text;
  }

  /// Returns the native capture queue WITHOUT deleting it (per-item lease,
  /// MALI-012). Call [acknowledgeSharedMessage] for each message only after
  /// its local import committed — a kill mid-drain re-delivers exactly the
  /// unacknowledged remainder instead of losing the whole batch.
  static Future<List<SharedCapturedMessage>> peekPendingSharedMessages() async {
    return _fetchSharedMessages('peekPendingSharedMessages');
  }

  /// Positively acknowledges (removes) one leased message from the native
  /// queue after its import committed. Returns false when the native layer
  /// doesn't support acks or the id was already gone.
  static Future<bool> acknowledgeSharedMessage(String payloadId) async {
    if (!Platform.isIOS && !Platform.isAndroid) return false;
    try {
      final removed = await _channel.invokeMethod<bool>(
        'acknowledgeSharedMessage',
        {'payloadId': payloadId},
      );
      return removed ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// MALI-054n: purges ALL user-owned native capture residue (the App Group
  /// pending-message queue + its metadata, notification routes, and notification
  /// log events on iOS; the durable SharedPreferences queue on Android) so one
  /// identity's captured bank messages can never be imported under another.
  /// Install-level config (device secret, backend URL/keys, install id, APNs
  /// token) is deliberately preserved.
  ///
  /// Returns true when the purge is confirmed (or there is nothing native to
  /// purge on this platform). Returns false when it could NOT be confirmed
  /// (channel/plugin error) — callers MUST treat false as "residue may remain"
  /// and fail closed at user-admission boundaries.
  /// How long to keep waiting for the native channel during startup.
  ///
  /// Under the UIScene lifecycle the capture channel cannot be registered in
  /// `didFinishLaunchingWithOptions` — there is no FlutterViewController yet, so
  /// `rootFlutterViewController()` returns nil and registration is deferred to
  /// `applicationDidBecomeActive`. Dart bootstrap runs inside that window, so
  /// the first call here can legitimately find no handler. That is "not ready",
  /// NOT "failed", and the two must not be confused: the ownership transition
  /// treats a failed purge as a reason to withhold admission, and treating a
  /// startup race as a permanent failure is what stranded the owner marker.
  ///
  /// Bounded on purpose. Six attempts at 150ms is ~0.9s of patience, which
  /// comfortably covers scene attachment without turning a genuinely absent
  /// handler (a build with the channel removed) into an indefinite hang.
  @visibleForTesting
  static const int purgeChannelRetries = 6;
  @visibleForTesting
  static const Duration purgeChannelRetryDelay = Duration(milliseconds: 150);

  /// Test seam: lets a test drive the retry loop without real delays.
  @visibleForTesting
  static Future<void> Function(Duration)? debugDelayOverride;

  /// Test seam: the retry only exists on the platforms that have the channel,
  /// and a host test runs on neither. Without this the loop is unreachable.
  @visibleForTesting
  static bool debugTreatHostAsNative = false;

  static Future<bool> purgeAllCaptureState() async {
    if (!debugTreatHostAsNative && !Platform.isIOS && !Platform.isAndroid) {
      return true;
    }
    for (var attempt = 0;; attempt++) {
      try {
        _noteProtectedWrite('purgeAllCaptureState', null);
        final ok = await _channel.invokeMethod<bool>('purgeAllCaptureState');
        return ok ?? false;
      } on MissingPluginException {
        // Channel not registered YET. Retry — but never forever.
        if (attempt >= purgeChannelRetries - 1) return false;
        final delay = debugDelayOverride;
        if (delay != null) {
          await delay(purgeChannelRetryDelay);
        } else {
          await Future<void>.delayed(purgeChannelRetryDelay);
        }
      } on PlatformException {
        // A real native failure. The handler ran and refused; retrying would
        // just repeat it, and pretending it is a startup race would hide it.
        return false;
      }
    }
  }

  static Future<List<SharedCapturedMessage>> _fetchSharedMessages(
    String method,
  ) async {
    if (!debugTreatHostAsNative && !Platform.isIOS && !Platform.isAndroid) {
      return const [];
    }
    final String? json;
    try {
      json = await _channel.invokeMethod<String>(method);
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      // An older native layer without the peek/ack handlers reports
      // notImplemented as a PlatformException — treat as empty; the caller
      // falls back to the destructive consume path.
      return const [];
    }
    if (json == null || json.trim().isEmpty) {
      return const [];
    }
    final List<dynamic> decoded;
    try {
      decoded = jsonDecode(json) as List<dynamic>;
    } on FormatException {
      return const [];
    }
    final messages = <SharedCapturedMessage>[];
    for (final item in decoded) {
      if (item is! Map) {
        continue;
      }
      final text = (item['text'] as String?)?.trim() ?? '';
      if (text.isEmpty) {
        continue;
      }
      final rawId = (item['id'] as String?)?.trim();
      final rawSender = (item['sender'] as String?)?.trim();
      final rawSenderName = (item['senderName'] as String?)?.trim();
      final rawSenderId = (item['senderId'] as String?)?.trim();
      final rawSource = (item['source'] as String?)?.trim();
      final rawReceivedAt = (item['receivedAt'] as String?)?.trim();
      final rawLocale = (item['locale'] as String?)?.trim();
      final rawStatus = (item['status'] as String?)?.trim();
      final rawFailureReason = (item['failureReason'] as String?)?.trim();
      final rawInferred = item['receivedAtInferred'];
      final rawOwnerUid = (item['ownerUid'] as String?)?.trim();
      final rawLocalOnly = item['localOnly'];
      final sender = _firstNonEmpty([rawSenderId, rawSender, rawSenderName]);
      messages.add(
        SharedCapturedMessage(
          id: _emptyToNull(rawId),
          text: text,
          source: Platform.isIOS
              ? _iosCapturedSource(rawSource)
              : CapturedMessageSource.androidShare,
          sender: sender,
          senderName: _emptyToNull(rawSenderName),
          senderId: _emptyToNull(rawSenderId),
          locale: _emptyToNull(rawLocale),
          status: _emptyToNull(rawStatus),
          failureReason: _emptyToNull(rawFailureReason),
          receivedAtInferred: rawInferred is bool ? rawInferred : null,
          ownerUid: _emptyToNull(rawOwnerUid),
          localOnly: rawLocalOnly is bool ? rawLocalOnly : null,
          // MALI-068n §11 — native epoch is authoritative; the ISO string is a
          // legacy fallback; unknown → null (never `now`).
          receivedAt: resolveCapturedReceivedAt(
            epochMs: item['receivedAtEpochMs'] as int?,
            isoString: rawReceivedAt,
          ),
        ),
      );
    }
    return messages;
  }

  /// Returns a drained message to the native queue after processing failed —
  /// the drain is destructive, so this is what keeps a failing message from
  /// being lost. The native side skips its host wake-up notification to avoid
  /// an immediate drain → fail → re-enqueue loop; the message is retried on
  /// the next resume/launch drain instead. Best-effort: on Android (no handler
  /// yet) or bridge failure the message is dropped exactly as before this fix.
  static Future<bool> reEnqueueSharedMessage(
    SharedCapturedMessage message,
  ) async =>
      await reEnqueueSharedMessageChecked(message) == null;

  /// [reEnqueueSharedMessage] that says WHY a refused write was refused (null =
  /// re-enqueued). The item goes back under its original [message.ownerUid] or
  /// not at all (`ownerChanged`); `quotaExceeded` and `removalInProgress` leave
  /// the queue untouched.
  static Future<CaptureQueueFailure?> reEnqueueSharedMessageChecked(
    SharedCapturedMessage message,
  ) async {
    if (!Platform.isIOS) return CaptureQueueFailure.unavailable;
    try {
      await _channel.invokeMethod<void>('reEnqueueSharedMessage', {
        'text': message.text,
        'sender': message.sender,
        'senderName': message.senderName,
        'senderId': message.senderId,
        'source': message.source == CapturedMessageSource.iosShortcut
            ? 'ios_shortcut'
            : message.source == CapturedMessageSource.iosShare
                ? 'ios_share'
                : null,
        'receivedAt': message.receivedAt?.toIso8601String(),
        'locale': message.locale,
        'status': message.status,
        'failureReason': message.failureReason,
        'payloadId': message.id,
        'receivedAtInferred': message.receivedAtInferred,
        'ownerUid': message.ownerUid,
        'localOnly': message.localOnly,
      });
      return null;
    } on PlatformException catch (e) {
      return _failureForCode(e.code);
    } on MissingPluginException {
      return CaptureQueueFailure.unavailable;
    }
  }

  static Future<List<CaptureNotificationRoute>>
      consumePendingNotificationRoutes() async {
    if (!Platform.isIOS) return const [];
    final String? json;
    try {
      json = await _channel
          .invokeMethod<String>('consumePendingNotificationRoutes');
    } on MissingPluginException {
      return const [];
    }
    if (json == null || json.trim().isEmpty) return const [];
    final List<dynamic> decoded;
    try {
      decoded = jsonDecode(json) as List<dynamic>;
    } on FormatException {
      return const [];
    }
    return [
      for (final item in decoded)
        if (item is Map)
          CaptureNotificationRoute(
            payloadId: _emptyToNull(_asString(item['payloadId'])),
            transactionId: _emptyToNull(_asString(item['transactionId'])),
            smartInboxItemId: _emptyToNull(_asString(item['smartInboxItemId'])),
            notificationType: _emptyToNull(_asString(item['notificationType'])),
            source: _emptyToNull(_asString(item['source'])),
            receivedAt: resolveCapturedReceivedAt(
              epochMs: item['receivedAtEpochMs'] as int?,
              isoString: item['receivedAt'] is String
                  ? item['receivedAt'] as String
                  : null,
            ),
            notificationLogId:
                _emptyToNull(_asString(item['notificationLogId'])),
            action: _emptyToNull(_asString(item['action'])),
          ),
    ];
  }

  /// Drains the iOS Shortcut extension's local notification-scheduling
  /// events (created/sent/failed) recorded via SharedCaptureStore. Returns
  /// an empty list on Android or when nothing is pending.
  static Future<List<NativeNotificationLogEvent>>
      consumePendingNotificationLogEvents(
          {String? ownerUid, int? ownerGeneration}) async {
    if (!Platform.isIOS) return const [];
    final String? json;
    try {
      json = await _channel
          .invokeMethod<String>('consumePendingNotificationLogEvents', {
        'ownerUid': ownerUid,
        'ownerGeneration': ownerGeneration,
      });
    } on MissingPluginException {
      return const [];
    }
    if (json == null || json.trim().isEmpty) return const [];
    final List<dynamic> decoded;
    try {
      decoded = jsonDecode(json) as List<dynamic>;
    } on FormatException {
      return const [];
    }
    return [
      for (final item in decoded)
        if (item is Map &&
            item['notificationLogId'] is String &&
            item['eventType'] is String &&
            item['channel'] is String &&
            item['notificationType'] is String)
          NativeNotificationLogEvent(
            eventId: item['eventId'] as String?,
            ownerUid: item['ownerUid'] as String?,
            ownerGeneration: item['ownerGeneration'] as int?,
            originKind: item['originKind'] as String?,
            notificationLogId: item['notificationLogId'] as String,
            eventType: item['eventType'] as String,
            channel: item['channel'] as String,
            notificationType: item['notificationType'] as String,
            relatedEntityType:
                _emptyToNull(_asString(item['relatedEntityType'])),
            relatedEntityId: _emptyToNull(_asString(item['relatedEntityId'])),
            errorCode: _emptyToNull(_asString(item['errorCode'])),
            errorReason: _emptyToNull(_asString(item['errorReason'])),
            occurredAt: item['occurredAt'] is String
                ? DateTime.tryParse(item['occurredAt'] as String)?.toUtc()
                : null,
          ),
    ];
  }

  static Future<bool> acknowledgeNotificationLogEvent({
    required String eventId,
    required String ownerUid,
    required int ownerGeneration,
  }) async {
    if (!Platform.isIOS) return false;
    try {
      return await _channel
              .invokeMethod<bool>('acknowledgeNotificationLogEvent', {
            'eventId': eventId,
            'ownerUid': ownerUid,
            'ownerGeneration': ownerGeneration,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  static CapturedMessageSource _iosCapturedSource(String? source) {
    return source == 'ios_shortcut' || source == 'shortcut'
        ? CapturedMessageSource.iosShortcut
        : CapturedMessageSource.iosShare;
  }

  static String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      final clean = _emptyToNull(value);
      if (clean != null) return clean;
    }
    return null;
  }

  static String? _emptyToNull(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// Like a `value as String?` cast, but tolerant of an unexpected JSON type
  /// (e.g. a number) instead of throwing — one malformed field in a decoded
  /// native payload must not take down the whole list comprehension it's
  /// part of. See notification_log_service_test.dart / requirement 9 of the
  /// Phase 1 notification-tracking hardening pass.
  static String? _asString(Object? value) => value is String ? value : null;

  static ApnsTokenInfo? _tokenInfoFrom(Object? value) {
    if (value is! Map) return null;
    final token = _emptyToNull(value['token'] as String?);
    final environment = _emptyToNull(value['environment'] as String?);
    if (token == null || environment == null) return null;
    return ApnsTokenInfo(token: token, environment: environment);
  }

  static ApnsRegistrationFailure? _apnsFailureFrom(Object? value) {
    if (value is! Map) return null;
    final message = _emptyToNull(value['message'] as String?);
    final occurredAtRaw = _emptyToNull(value['occurredAt'] as String?);
    final occurredAt = occurredAtRaw == null
        ? null
        : DateTime.tryParse(occurredAtRaw)?.toUtc();
    if (message == null || occurredAt == null) return null;
    return ApnsRegistrationFailure(
      message: message,
      occurredAt: occurredAt,
      domain: _emptyToNull(value['domain'] as String?),
      code: value['code'] is int ? value['code'] as int : null,
    );
  }
}

/// COUPONS Phase 5 — a shared merchant link, staged natively.
///
/// Deliberately NOT a capture. It arrives through its own channel method from
/// its own store, so a shopping URL is never one missed switch case away from
/// the SMS parser.
class OfferIntent {
  const OfferIntent({
    required this.id,
    required this.url,
    required this.host,
    required this.receivedAt,
  });

  final String id;

  /// Already sanitized natively: scheme, host and path only. The query and
  /// fragment were destroyed before this was written to disk.
  final String url;
  final String host;
  final String receivedAt;

  static OfferIntent? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    final host = raw['host'];
    if (url is! String || host is! String || url.isEmpty || host.isEmpty) {
      return null;
    }
    // Refuse anything still carrying a query or fragment even though the native
    // side strips them. This is the last checkpoint before a URL enters the app,
    // and the cost of the check is nothing.
    if (url.contains('?') || url.contains('#') || !url.startsWith('https://')) {
      return null;
    }
    return OfferIntent(
      id: raw['id'] as String? ?? '',
      url: url,
      host: host,
      receivedAt: raw['receivedAt'] as String? ?? '',
    );
  }
}

/// Drains merchant links the user shared into Qirsh.
///
/// Returns empty on any failure, including a platform without the method — an
/// offer intent has no durability requirement. The worst case for losing one is
/// that the user taps the link again, whereas a lost bank message is a missing
/// transaction, which is why the two paths have different guarantees.
Future<List<OfferIntent>> drainOfferIntents() async {
  try {
    final raw = await const MethodChannel('money_companion/native_capture')
        .invokeMethod<String>('drainOfferIntents');
    if (raw == null || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .map(OfferIntent.tryParse)
        .whereType<OfferIntent>()
        .toList(growable: false);
  } catch (_) {
    return const [];
  }
}
