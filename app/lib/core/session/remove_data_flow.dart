import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/db/replica_store.dart';
import '../security/secure_storage_options.dart';
import 'account_scope.dart';
import 'admission_authority.dart';
import 'app_session.dart';
import '../../features/settings/profile_image_store.dart';

/// WP-3b — the Dart side of the manifest §4.4 "Remove data from this device"
/// barrier.
///
/// The native queue (App Group, flock) is CAP-6a's; this file reaches it only
/// through [RemoveDataBarrier], backed by the narrow `CaptureQueueBridge`
/// (capture_queue.dart) whose methods are the `NativeCaptureBridge` statics
/// `beginCaptureRemoval(uid)`, `getCaptureRemovalBarrier()` and
/// `finishCaptureRemoval(uid)`.
abstract class RemoveDataBarrier {
  /// Step 1 (native, under flock): write the destructive transition and clear the
  /// owner record when it is [uid]. Idempotent.
  Future<void> begin(String uid);

  /// The uid of a native barrier that is still set (a crash mid-removal), or null.
  /// Null does NOT mean "no barrier": the native record may hold only an HMAC of
  /// the uid, so a set barrier can have an unknown uid. See [nativeBarrierPresent].
  Future<String?> pendingUid();

  /// F2: true when a native barrier is set, whether or not its uid is known.
  /// "Barrier exists, uid unknown" blocks admission; it is never "nothing
  /// pending", and no uid is invented from the hash.
  Future<bool> nativeBarrierPresent();

  /// Step 5 (native, under flock): final sweep of everything owned by or hinted
  /// to [uid] or created at/after the barrier, then clear the barrier. MUST throw
  /// when the sweep cannot be confirmed.
  Future<void> finish(String uid);
}

/// "The consent question was shown" marker, per uid on this device (secure
/// storage, `qirsh.`-prefixed). Remove data deletes it so the next admission into
/// a fresh replica asks again (§4.6: a new device re-asks).
const String kConsentAskedKeyPrefix = 'qirsh.consent_asked.v1.';

/// The removal could not be completed. The barrier record is KEPT, so the next
/// launch (or the next admission) resumes it; nothing has been reported as done.
class RemoveDataIncompleteException implements Exception {
  const RemoveDataIncompleteException();
  @override
  String toString() => 'RemoveDataIncompleteException: removal not completed.';
}

/// Fixed order of the removal steps; a test hook may stop the process after any
/// of them.
const List<String> kRemovalSteps = [
  'afterBarrierRecord',
  'afterNativeBegin',
  'afterOwnerCleared',
  'afterScopeStopped',
  'afterReplicaRemoved',
  'afterServerCleanup',
  'afterFinalSweep',
  'afterRevocationRecorded',
];

/// Bookkeeping from one actual resume; never a remote-completion witness.
final class RemovalRecoveryOutcome {
  const RemovalRecoveryOutcome._(this.completed, [this.uid, this.localOnly]);
  final bool completed;
  final String? uid;
  final bool? localOnly;
}

/// A genuine original admission owns exactly one held removal queue turn.
final class PreparedRemovalReservation {
  PreparedRemovalReservation._(
      this._issuer, this._op, this._scope, this._prior);
  final RemoveDataFlow _issuer;
  final _Op _op;
  final AccountScope _scope;
  final Future<void> _prior;
  // The queue tail never throws; joined callers observe the separate outcome.
  final _terminal = Completer<void>();
  final _outcome = Completer<void>();
  Future<void>? _execution;
  Future<void>? _settlement;
  bool _executionSettled = false;
  bool _executionConfirmed = false;
  bool _abandoned = false;
}

class RemoveDataFlow {
  /// Where profile photos live (overridable in tests).
  static Future<Directory> Function() documentsDirectory =
      getApplicationDocumentsDirectory;

  RemoveDataFlow({
    required ReplicaStore store,
    required AccountScopeControl scope,
    required RemoveDataBarrier barrier,
    required Future<void> Function(String uid) clearOwnerMarker,
    Future<void> Function()? serverCleanupBestEffort,
    FlutterSecureStorage? storage,
    Future<void> Function(String step)? debugAfterStep,
    Future<void> Function()? quiesce,
    Future<void> Function(String uid)? invalidateAdmissionGeneration,
  })  : _store = store,
        _scope = scope,
        _barrier = barrier,
        _clearOwnerMarker = clearOwnerMarker,
        _serverCleanup = serverCleanupBestEffort,
        _storage = storage ?? SecureStorageOptions.storage,
        _debugStep = debugAfterStep,
        _quiesce = quiesce,
        _invalidateAdmissionGeneration = invalidateAdmissionGeneration;

  /// The persisted barrier. `qirsh.`-prefixed so the session secure-storage wipe
  /// preserves it (a removal in progress must survive a crash AND a wipe).
  static const String barrierKey = 'qirsh.removal_barrier.v1';

  /// F2 — the durable `removed_requires_explicit_auth` state: a JSON list of the
  /// uids whose Remove data completed. `qirsh.`-prefixed so a session wipe keeps
  /// it. Only the successful commit of a whole fresh EXPLICIT admission removes
  /// an entry ([clearRevocation]); no automatic event, resume revalidation,
  /// rebootstrap or restart does. The `removing` state is the barrier record
  /// above.
  static const String revokedKey = 'qirsh.removal_revoked.v1';

  final ReplicaStore _store;
  final AccountScopeControl _scope;
  final RemoveDataBarrier _barrier;

  /// Clears the owner marker IF it still names [uid] (the uid being removed). A
  /// marker that moved to another uid meanwhile belongs to that uid and is left.
  final Future<void> Function(String uid) _clearOwnerMarker;
  final Future<void> Function()? _serverCleanup;
  final FlutterSecureStorage _storage;
  final Future<void> Function(String step)? _debugStep;

  /// Drains already-dispatched admission work (owner-marker/generation writes,
  /// scope activations, identity commits) before anything destructive runs.
  /// Supplied by the session layer.
  final Future<void> Function()? _quiesce;
  final Future<void> Function(String uid)? _invalidateAdmissionGeneration;

  /// F2 — the serialization fence. EVERY entry point ([remove], [resumePending])
  /// is an operation that takes its turn here BEFORE it reads, decides on, writes
  /// or replaces any durable removal state; the record is read inside the turn,
  /// so a caller can never act on a record another operation already completed.
  /// A second request for a uid that already has an operation not yet sealed
  /// JOINS it (upgrading it durably when stronger); anything else waits its turn.
  /// Two sweeps never run concurrently and one target's record is never
  /// overwritten by another's.
  final List<_Op> _pending = [];
  Future<void> _tail = Future<void>.value();

  /// Serializes the read-modify-write of the revoked-uid list.
  Future<void> _revokedTail = Future<void>.value();

  Future<void> _step(String name) async => _debugStep?.call(name);

  /// True while a removal has started and not finished (even when its record is
  /// unreadable: then the uid is unknown and admission stays blocked).
  Future<bool> hasPending() async =>
      barrierPending(await _storage.read(key: barrierKey));

  /// Whether the stored barrier value [raw] marks a removal in progress.
  static bool barrierPending(String? raw) => raw != null && raw.isNotEmpty;

  /// True from the moment an operation is accepted until it finished — queued or
  /// executing.
  bool get isRunning => _pending.isNotEmpty;

  /// The uids whose Remove data completed and that have not authenticated
  /// explicitly since. Throws when the record is unreadable: the caller must fail
  /// closed, never read that as "no restrictions".
  Future<Set<String>> revokedUids() async =>
      parseRevokedUids(await _storage.read(key: revokedKey));

  /// The revoked uids stored as [raw]; throws when it is malformed.
  static Set<String> parseRevokedUids(String? raw) {
    if (raw == null || raw.isEmpty) return <String>{};
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('revoked uids');
    return decoded.cast<String>().toSet();
  }

  Future<T> _revokedLocked<T>(Future<T> Function() f) {
    final run = _revokedTail.then((_) => f());
    _revokedTail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// A fresh EXPLICIT admission of [uid] committed completely (authority, owner
  /// marker and generation, registry, database and key, scope publication,
  /// identity): it may be admitted by automatic paths again.
  Future<void> clearRevocation(String uid, {required AdmissionAuthority authority}) =>
      _revokedLocked(() async {
        authority.requireFor(uid);
        final revoked = await revokedUids();
        authority.requireFor(uid);
        if (!revoked.remove(uid)) return;
        if (revoked.isEmpty) {
          await _storage.delete(key: revokedKey);
        } else {
          await _storage.write(
              key: revokedKey, value: jsonEncode(revoked.toList()..sort()));
        }
        if (!authority.isCurrent) {
          // A dispatched storage mutation cannot be cancelled. Restore the
          // restriction under this same list lock before releasing stale work.
          revoked.add(uid);
          await _storage.write(
              key: revokedKey, value: jsonEncode(revoked.toList()..sort()));
          throw const StaleAdmissionException();
        }
      });

  Future<void> _addRevoked(String uid) => _revokedLocked(() async {
        final revoked = await revokedUids()
          ..add(uid);
        await _storage.write(
          key: revokedKey,
          value: jsonEncode(revoked.toList()..sort()),
        );
      });

  /// No I/O, notifications or callbacks after the final genuine proof check.
  PreparedRemovalReservation? reservePreparedRemoval(
      DatabaseHostAdmission originalAdmission,
      AdmissionAuthority originalOrigin) {
    if (!originalOrigin.isCurrent ||
        originalOrigin.uid != originalAdmission.uid ||
        _pending.isNotEmpty) {
      return null;
    }
    final scope = _scope.activeScope;
    if (scope == null ||
        scope.isLocalRead ||
        scope.uid != originalAdmission.uid ||
        scope.generation != originalAdmission.scopeGeneration ||
        !identical(scope.database, originalAdmission.database) ||
        !originalAdmission.isCurrent ||
        _pending.isNotEmpty ||
        !identical(_scope.activeScope, scope)) {
      return null;
    }
    final op = _Op(uid: originalAdmission.uid, revoke: true, localOnly: true);
    final reservation = PreparedRemovalReservation._(this, op, scope, _tail);
    op.done = reservation._outcome.future;
    // A prepared caller need not have an ordinary joiner. Observe the error
    // here without changing the original Future returned to actual joiners.
    unawaited(
        op.done!.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    _pending.add(op);
    _tail = reservation._terminal.future;
    return reservation;
  }

  Future<void> runPreparedRemoval(PreparedRemovalReservation reservation) {
    if (!identical(reservation._issuer, this) ||
        reservation._abandoned ||
        !_pending.contains(reservation._op)) {
      return Future<void>.error(const RemoveDataIncompleteException());
    }
    return reservation._execution ??= () async {
      final op = reservation._op;
      try {
        await reservation._prior;
        op.started = true;
        if (!identical(_scope.activeScope, reservation._scope)) {
          throw const RemoveDataIncompleteException();
        }
        await _removeBody(op, prepared: true);
        reservation._executionConfirmed = true;
      } finally {
        reservation._executionSettled = true;
      }
    }();
  }

  /// Keep the slot and true barrier until the session's own cleanup settles.
  Future<void> settlePreparedRemoval(PreparedRemovalReservation reservation,
      {required bool localCleanupConfirmed}) {
    if (!identical(reservation._issuer, this) ||
        reservation._abandoned ||
        !reservation._executionSettled) {
      return Future<void>.error(const RemoveDataIncompleteException());
    }
    return reservation._settlement ??= () async {
      var confirmed = false;
      try {
        if (localCleanupConfirmed && reservation._executionConfirmed) {
          final raw = await _readRaw();
          final record = raw == null ? null : _Record.tryParse(raw);
          if (record == null ||
              record.uid != reservation._op.uid ||
              record.uidHash != reservation._op.hash ||
              !record.localOnly ||
              record.revoke != reservation._op.revoke) {
            throw const RemoveDataIncompleteException();
          }
          await _storage.delete(key: barrierKey);
          if (await _readRaw() != null) {
            throw const RemoveDataIncompleteException();
          }
          confirmed = true;
        } else if (localCleanupConfirmed) {
          throw const RemoveDataIncompleteException();
        }
      } finally {
        _pending.remove(reservation._op);
        if (confirmed) {
          reservation._outcome.complete();
        } else {
          reservation._outcome
              .completeError(const RemoveDataIncompleteException());
        }
        reservation._terminal.complete();
      }
    }();
  }

  void abandonPreparedRemoval(PreparedRemovalReservation reservation) {
    if (!identical(reservation._issuer, this) ||
        reservation._abandoned ||
        reservation._execution != null ||
        !_pending.contains(reservation._op)) {
      return;
    }
    reservation._abandoned = true;
    _pending.remove(reservation._op);
    reservation._outcome.completeError(const RemoveDataIncompleteException());
    reservation._terminal.complete();
  }

  /// Removes [uid]'s replica and everything native that belongs to it (§4.4).
  /// Throws [RemoveDataIncompleteException] (barrier kept) when a step could not
  /// be confirmed; returns normally only after step 6's precondition holds.
  ///
  /// [revokeAdmission] (default) is an explicit user removal: on completion the
  /// uid stays unadmittable until a new explicit authentication. The rebootstrap
  /// `purge` passes false: it is a server-driven recovery that re-admits. An
  /// explicit removal that overlaps a purge of the same uid JOINS it and upgrades
  /// it — in memory and in the durable record — so the purge's completion still
  /// requires explicit authentication; a purge never downgrades an explicit one.
  Future<void> remove(String uid, {bool revokeAdmission = true}) {
    for (final op in _pending) {
      if (op.uid == uid && !op.sealed) {
        if (revokeAdmission && !op.revoke) _upgrade(op);
        return op.done!;
      }
    }
    final op = _Op(uid: uid, revoke: revokeAdmission);
    return op.done = _enqueue<void>(op, () => _removeBody(op));
  }

  /// Launch / admission: finishes a removal a crash left behind. Returns true
  /// when none is pending or it has now completed; false when it could not be
  /// completed (the caller must not admit anyone yet).
  ///
  /// F2: an unreadable Dart record, or a native barrier whose uid cannot be
  /// recovered, is "cannot complete", never "nothing pending". The record is read
  /// inside the serialized turn.
  Future<bool> resumePending() => _resumeOperation().resumed!;

  Future<RemovalRecoveryOutcome> resumePendingWithOutcome() =>
      _resumeOperation().recovery!;

  _Op _resumeOperation() {
    if (_pending.isNotEmpty) {
      final last = _pending.last;
      if (last.isResume && !last.started) return last;
    }
    final op = _Op(uid: null, revoke: true)..isResume = true;
    op.recovery = _enqueue<RemovalRecoveryOutcome>(op, _resumeBody);
    op.resumed = op.recovery!.then((outcome) => outcome.completed);
    return op;
  }

  Future<T> _enqueue<T>(_Op op, Future<T> Function() body) {
    _pending.add(op);
    final prior = _tail;
    final run = () async {
      try {
        await prior;
      } catch (_) {}
      op.started = true;
      try {
        return await body();
      } finally {
        _pending.remove(op);
      }
    }();
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// A join that is stronger than the operation it joins: made durable before the
  /// caller proceeds, so a crash from here on resumes as an explicit removal.
  void _upgrade(_Op op) {
    op.revoke = true;
    if (!op.recordIssued) return; // the record will be written with revoke:true
    op.recordWrites = op.recordWrites.then((_) async {
      try {
        await _storage.write(key: barrierKey, value: op.recordJson());
      } catch (e) {
        op.recordError ??= e;
      }
    });
  }

  Future<void> _removeBody(_Op op, {bool prepared = false}) async {
    final uid = op.uid!;
    final raw = await _readRaw();
    if (raw != null) {
      final other = _Record.tryParse(raw);
      if (other == null) throw const RemoveDataIncompleteException();
      if (other.uid != uid) {
        // A prepared operation never executes another owner's leftover.
        if (prepared) throw const RemoveDataIncompleteException();
        await _runLeftover(other);
      } else {
        op.revoke =
            op.revoke || other.revoke; // never weaker than what is durable
        op.localOnly = op.localOnly || other.localOnly;
      }
    }
    if (prepared) {
      final marker = await AppSession.instance.readLocalDataOwnerUid();
      if (marker != null && marker.isNotEmpty && marker != uid) {
        throw const RemoveDataIncompleteException();
      }
    }
    op.hash = await _store.uidHash(uid);
    // Step 1. The durable record goes first: from here a crash is resumed, and
    // the native barrier is (re)written idempotently on resume. Issued in one
    // synchronous block with its flag, so a join can neither miss nor reorder it.
    op.recordIssued = true;
    op.recordWrites = _storage
        .write(key: barrierKey, value: op.recordJson())
        .catchError((Object e) {
      op.recordError ??= e;
    });
    await op.recordWrites;
    if (op.recordError != null) throw const RemoveDataIncompleteException();
    try {
      await _step('afterBarrierRecord');
    } catch (_) {
      throw const RemoveDataIncompleteException();
    }
    await _run(op, prepared: prepared);
  }

  Future<RemovalRecoveryOutcome> _resumeBody() async {
    try {
      final raw = await _readRaw();
      _Record record;
      if (raw != null) {
        final parsed = _Record.tryParse(raw);
        if (parsed == null) return const RemovalRecoveryOutcome._(false);
        record = parsed;
      } else {
        // A native barrier with no Dart record (crash between the two writes).
        final uid = await _barrier.pendingUid();
        if (uid != null) {
          record = _Record(
              uid: uid, uidHash: await _store.uidHash(uid), localOnly: true);
          // Missing Dart mode cannot grant remote permission, and must survive
          // another interruption before any native/destructive work.
          await _storage.write(
              key: barrierKey, value: jsonEncode(record.toJson()));
        } else if (await _barrier.nativeBarrierPresent()) {
          return const RemovalRecoveryOutcome._(false);
        } else {
          return const RemovalRecoveryOutcome._(true);
        }
      }
      await _runLeftover(record);
      return RemovalRecoveryOutcome._(true, record.uid, record.localOnly);
    } catch (_) {
      return const RemovalRecoveryOutcome._(false);
    }
  }

  /// Executes a removal a previous process recorded. Inside the caller's turn.
  Future<void> _runLeftover(_Record record) => _run(
      _Op(uid: record.uid, revoke: record.revoke, localOnly: record.localOnly)
        ..hash = record.uidHash);

  Future<void> _run(_Op op, {bool prepared = false}) async {
    final uid = op.uid!;
    try {
      await _invalidateAdmissionGeneration?.call(uid);
      await _quiesce?.call();
      await _barrier.begin(uid);
      await _step('afterNativeBegin');
      if (prepared) {
        await AppSession.instance
            .clearLocalDataOwnerMarker(uid, strictOriginalOwner: true);
      } else {
        await _clearOwnerMarker(uid);
      }
      await _step('afterOwnerCleared');
      // Step 2.
      await _scope.detach();
      await _step('afterScopeStopped');
      // Step 3.
      await _store.remove(uid);
      await _storage.delete(key: '$kConsentAskedKeyPrefix$uid');
      // The account's profile photo lives outside its database folder.
      try {
        await deleteProfileImagesOf(
            documents: await documentsDirectory(), uid: uid);
      } catch (_) {
        // Best effort: a photo that cannot be found or deleted never blocks
        // the removal of the account's data.
      }
      await _step('afterReplicaRemoved');
      // Step 4, best effort.
      final cleanup = _serverCleanup;
      if (cleanup != null && !op.localOnly) {
        try {
          await cleanup().timeout(const Duration(seconds: 4));
        } catch (_) {}
      }
      await _step('afterServerCleanup');
      // Step 5.
      await _barrier.finish(uid);
      await _step('afterFinalSweep');
      // Joins that upgraded the record are flushed, then the operation is SEALED
      // in the same synchronous block: from here a request for this uid is a new
      // operation, so what is recorded below cannot change under it.
      while (true) {
        final writes = op.recordWrites;
        await writes;
        if (identical(writes, op.recordWrites)) break;
      }
      if (op.recordError != null) throw const RemoveDataIncompleteException();
      op.sealed = true;
      // The completed revocation is persisted BEFORE the active recovery record
      // is cleared, so there is no instant at which neither exists.
      if (op.revoke) {
        await _addRevoked(uid);
      }
      await _step('afterRevocationRecorded');
      if (!prepared) await _storage.delete(key: barrierKey);
    } on RemoveDataIncompleteException {
      rethrow;
    } catch (_) {
      throw const RemoveDataIncompleteException();
    }
  }

  Future<String?> _readRaw() async {
    final raw = await _storage.read(key: barrierKey);
    return (raw == null || raw.isEmpty) ? null : raw;
  }
}

/// One accepted operation on the serialized queue.
class _Op {
  _Op({required this.uid, required this.revoke, this.localOnly = false});

  /// The uid being removed; null for a resume (which learns it from the record).
  final String? uid;

  /// Whether completion records the uid as `removed_requires_explicit_auth`.
  /// Only ever raised, never lowered.
  bool revoke;
  bool localOnly;
  String? hash;
  bool isResume = false;
  bool started = false;

  /// After this the operation is committing its result: a new request for the
  /// same uid is a new operation, not a join.
  bool sealed = false;

  /// The durable record has been issued (so a stronger join rewrites it).
  bool recordIssued = false;
  Future<void> recordWrites = Future<void>.value();
  Object? recordError;
  Future<void>? done;
  Future<bool>? resumed;
  Future<RemovalRecoveryOutcome>? recovery;

  String recordJson() => jsonEncode(
        _Record(uid: uid!, uidHash: hash!, revoke: revoke, localOnly: localOnly)
            .toJson(),
      );
}

class _Record {
  const _Record(
      {required this.uid,
      required this.uidHash,
      this.revoke = true,
      this.localOnly = false});
  final String uid;
  final String uidHash;

  /// Whether completion records the uid as `removed_requires_explicit_auth`.
  final bool revoke;
  final bool localOnly;

  Map<String, Object?> toJson() => {
        'uid': uid,
        'uidHash': uidHash,
        'revoke': revoke,
        if (localOnly) 'localOnly': true,
      };

  static _Record fromJson(Map<String, Object?> j) => _Record(
        uid: j['uid']! as String,
        uidHash: j['uidHash']! as String,
        revoke: j['revoke'] != false,
        localOnly: j.containsKey('localOnly') ? j['localOnly']! as bool : false,
      );

  /// Null when the record cannot be read (corrupt): the caller fails closed.
  static _Record? tryParse(String raw) {
    try {
      return fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }
}
