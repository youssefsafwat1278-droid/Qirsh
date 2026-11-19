import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/security/secure_storage_options.dart';
import '../../core/session/admission_authority.dart';
import 'app_database.dart';
import 'creation_policy.dart';
import 'database_access_broker.dart'
    show DatabaseOpenHandle, DatabaseOpenReservation;
import 'database_key_store.dart';
import 'database_lease.dart';
import 'replica_location.dart';

/// WP-3a — the per-UID encrypted replica CORE (storage layer only).
///
/// One SQLCipher file and one key per authenticated uid:
///
///     <AppSupport>/replicas/<uidHash>/qirsh.sqlite  (+ -wal/-shm and every
///                                                    maintenance/lease/liveness
///                                                    sidecar, same directory)
///     secure storage: qirsh.db_key.<uidHash>   (first_unlock_this_device)
///                     qirsh.replicas.v1         (the registry below)
///                     qirsh.device_salt         (HMAC salt, random, per device)
///
/// `uidHash = hex(HMAC-SHA256(deviceSalt, uid))` truncated to 128 bits, so the
/// file system never reveals the raw uid.
///
/// The registry is a HINT (state, timestamps). Ownership is decided by
/// `replica_meta.owner_uid` inside the file, asserted on every open, failing
/// CLOSED on any mismatch. The session/account wiring, sign-out and Remove-data
/// UI are WP-3b; this class is only the storage API they call.

/// Registry state of one replica.
enum ReplicaState { active, locked, migrating, quarantined }

/// WP-7 — the manifest §4.10 durable rebootstrap phase, in execution order. A
/// crash at any phase resumes from the registry marker. Wire names are the
/// manifest's (`frozen`, `extracted`, `fresh_bootstrapped`, ...).
enum RebootstrapPhase {
  frozen('frozen'),
  extracted('extracted'),
  freshBootstrapped('fresh_bootstrapped'),
  receiptsRecovered('receipts_recovered'),
  pulledMerged('pulled_merged'),
  outboxRecovered('outbox_recovered'),
  conflictsMerged('conflicts_merged'),
  swapped('swapped'),
  captureResumed('capture_resumed');

  const RebootstrapPhase(this.wire);
  final String wire;

  static RebootstrapPhase fromWire(String w) =>
      values.firstWhere((p) => p.wire == w);
}

/// The in-progress rebootstrap of one replica (counts and names only, never
/// content). Absent once `capture_resumed` has been reached.
class RebootstrapMarker {
  const RebootstrapMarker({
    required this.phase,
    required this.reason,
    required this.startedAt,
    this.swapping = false,
  });

  final RebootstrapPhase phase;

  /// The swap's file moves have begun (set before the first one): a resume must
  /// finish the swap, never rebuild or reopen the replica names mid-move.
  final bool swapping;

  /// `user_sync_state.epoch_reason` that triggered it (`purge`, `reset`,
  /// `restore`, ...). `purge` never replays anything.
  final String reason;
  final DateTime startedAt;

  Map<String, Object?> toJson() => {
        'phase': phase.wire,
        'reason': reason,
        'startedAt': startedAt.toUtc().toIso8601String(),
        if (swapping) 'swapping': true,
      };

  static RebootstrapMarker fromJson(Map<String, Object?> j) =>
      RebootstrapMarker(
        phase: RebootstrapPhase.fromWire(j['phase']! as String),
        reason: j['reason']! as String,
        startedAt: DateTime.parse(j['startedAt']! as String),
        swapping: j['swapping'] == true,
      );
}

/// One registry entry (uidHash → this).
class ReplicaEntry {
  const ReplicaEntry({
    required this.uidHash,
    required this.createdAt,
    required this.lastOpenedAt,
    required this.schemaVersion,
    required this.epoch,
    required this.state,
    this.adoptPending = false,
    this.legacyAdoptedAt,
    this.rebootstrap,
    this.retiredAt,
  });

  final String uidHash;
  final DateTime createdAt;
  final DateTime lastOpenedAt;
  final int schemaVersion;
  final int epoch;
  final ReplicaState state;

  /// Legacy adoption into this replica has started and the legacy file has not
  /// yet been renamed to `.adopted`. Drives crash recovery.
  final bool adoptPending;

  /// When the legacy file was renamed to `.adopted`; the 7-day P2 rollback
  /// grace is measured from here. Null once purged (or never adopted).
  final DateTime? legacyAdoptedAt;

  /// WP-7: the rebootstrap in progress, if any (see [RebootstrapPhase]).
  final RebootstrapMarker? rebootstrap;

  /// WP-7: when a swapped rebootstrap retired the previous replica to
  /// `<hash>.old`; the 14-day retention (manifest §13) is measured from here.
  final DateTime? retiredAt;

  ReplicaEntry copyWith({
    DateTime? lastOpenedAt,
    int? schemaVersion,
    int? epoch,
    ReplicaState? state,
    bool? adoptPending,
    DateTime? legacyAdoptedAt,
    bool clearLegacyAdoptedAt = false,
    RebootstrapMarker? rebootstrap,
    bool clearRebootstrap = false,
    DateTime? retiredAt,
    bool clearRetiredAt = false,
  }) =>
      ReplicaEntry(
        uidHash: uidHash,
        createdAt: createdAt,
        lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
        schemaVersion: schemaVersion ?? this.schemaVersion,
        epoch: epoch ?? this.epoch,
        state: state ?? this.state,
        adoptPending: adoptPending ?? this.adoptPending,
        legacyAdoptedAt: clearLegacyAdoptedAt
            ? null
            : (legacyAdoptedAt ?? this.legacyAdoptedAt),
        rebootstrap:
            clearRebootstrap ? null : (rebootstrap ?? this.rebootstrap),
        retiredAt: clearRetiredAt ? null : (retiredAt ?? this.retiredAt),
      );

  Map<String, Object?> toJson() => {
        'createdAt': createdAt.toUtc().toIso8601String(),
        'lastOpenedAt': lastOpenedAt.toUtc().toIso8601String(),
        'schemaVersion': schemaVersion,
        'epoch': epoch,
        'state': state.name,
        if (adoptPending) 'adoptPending': true,
        if (legacyAdoptedAt != null)
          'legacyAdoptedAt': legacyAdoptedAt!.toUtc().toIso8601String(),
        if (rebootstrap != null) 'rebootstrap': rebootstrap!.toJson(),
        if (retiredAt != null)
          'retiredAt': retiredAt!.toUtc().toIso8601String(),
      };

  static ReplicaEntry fromJson(String uidHash, Map<String, Object?> j) =>
      ReplicaEntry(
        uidHash: uidHash,
        createdAt: DateTime.parse(j['createdAt']! as String),
        lastOpenedAt: DateTime.parse(j['lastOpenedAt']! as String),
        schemaVersion: j['schemaVersion']! as int,
        epoch: j['epoch']! as int,
        state: ReplicaState.values.byName(j['state']! as String),
        adoptPending: j['adoptPending'] == true,
        legacyAdoptedAt: j['legacyAdoptedAt'] == null
            ? null
            : DateTime.parse(j['legacyAdoptedAt']! as String),
        rebootstrap: j['rebootstrap'] == null
            ? null
            : RebootstrapMarker.fromJson(
                (j['rebootstrap']! as Map).cast<String, Object?>()),
        retiredAt: j['retiredAt'] == null
            ? null
            : DateTime.parse(j['retiredAt']! as String),
      );
}

/// The file's `replica_meta.owner_uid` is missing or is not the requested uid.
/// Fails closed; carries no uid.
class ReplicaOwnershipException implements Exception {
  const ReplicaOwnershipException();
  @override
  String toString() => 'ReplicaOwnershipException: replica owner mismatch.';
}

/// The replica exists but is not openable in its current registry state
/// (`locked`: signed out, SYNC-Q3; `migrating`; `quarantined`).
class ReplicaUnavailableException implements Exception {
  const ReplicaUnavailableException(this.state);
  final ReplicaState state;
  @override
  String toString() => 'ReplicaUnavailableException(${state.name})';
}

/// F2 — the replica does not exist and the caller holds no creation authority
/// (cold launch, rebootstrap re-open, automatic reconcile, revoked authority). A
/// missing registry entry, file or key never authorizes creation. Nothing was
/// written. Carries no uid.
class ReplicaMissingException implements Exception {
  const ReplicaMissingException();
  @override
  String toString() => 'ReplicaMissingException: replica does not exist and '
      'creation is not authorized.';
}

/// Offline local read — why [ReplicaStore.openReadOnlyReplica] refused. This
/// path attempts no application writes, key creation or registry repair.
enum LocalReadDenial {
  identity,
  salt,
  ownerMarker,
  removal,
  registry,
  replicaState,
  files,
  key,
  schema,
  ownership,
  unavailable,
}

/// The read-only open of an existing replica was refused. Carries no uid, path
/// or key.
class LocalReadUnavailableException implements Exception {
  const LocalReadUnavailableException(this.reason);
  final LocalReadDenial reason;
  @override
  String toString() => 'LocalReadUnavailableException(${reason.name})';
}

/// A verified, read-only handle on an existing replica: the file's own
/// `replica_meta` named exactly [uid] and [replicaId].
class LocalReadReplica {
  const LocalReadReplica({
    required this.uid,
    required this.replicaId,
    required this.database,
    this.reservation,
  });
  final String uid;
  final String replicaId;
  final AppDatabase database;

  /// The coordinator reservation this read-only handle was opened under (R8).
  /// Null only for a fixture opened through the explicit testing API; such a
  /// replica can never be published as a local-read scope.
  final DatabaseOpenReservation? reservation;
}

/// Result of [ReplicaStore.adoptLegacyIfPresent].
enum AdoptionOutcome {
  /// No legacy file, nothing to do.
  none,

  /// The legacy DB was copied into the owner's replica and renamed `.adopted`.
  adopted,

  /// No real owner marker: the legacy file was moved to `replicas/_quarantine/`.
  quarantined,

  /// A step failed (or the process died earlier and this launch could not
  /// finish). The legacy file is still in place and still in use; the registry
  /// state `migrating` makes the next launch retry.
  failed,

  /// The owner already has an active replica AND a legacy file reappeared (a
  /// downgrade-then-upgrade). Nothing is overwritten; WP-3b decides.
  legacyLeftover,
}

/// Fixed order of the adoption steps; a test hook may stop the process after any
/// of them.
const List<String> kAdoptionSteps = [
  'beforeCopy',
  'afterCopy',
  'afterKeyCopy',
  'afterProbe',
  'afterReplicaMeta',
  'afterRegistryActive',
  'beforeRename',
  'afterRename',
];

/// Fixed order of the swap steps (WP-7); a test hook may stop the process after
/// any of them.
const List<String> kSwapSteps = [
  'swap:beforeOldMoved',
  'swap:afterOldMoved',
  'swap:afterOldKey',
  'swap:afterFreshMoved',
  'swap:afterFreshKey',
];

/// Opens one existing replica file read-only ([AppDatabase.openReadOnlyExisting]).
typedef ReadOnlyOpener = Future<AppDatabase> Function({
  required ReplicaLocation location,
  required Future<String?> Function() readKey,
});

typedef ReplicaOpener = Future<AppDatabase> Function({
  ReplicaLocation? location,
  bool runMigrations,
  CreationPolicy creation,
});

class ReplicaStore {
  ReplicaStore({
    FlutterSecureStorage? storage,
    String? appSupportDirectory,
    DateTime Function()? now,
    ReplicaOpener? opener,
    Future<String?> Function()? readOwnerMarker,
    Future<void> Function(String step)? debugAfterAdoptionStep,
    @visibleForTesting ReadOnlyOpener? readOnlyOpener,
    @visibleForTesting
    Future<void> Function(AppDatabase db)? debugBeforeReadOnlyClose,
    this.requireCreationAuthority = true,
    this.removalDrainTimeout = const Duration(seconds: 10),
  })  : _storage = storage ?? SecureStorageOptions.storage,
        _appSupport = appSupportDirectory,
        _now = now ?? DateTime.now,
        _opener = opener ?? AppDatabase.open,
        _readOwnerMarker = readOwnerMarker,
        _debugStep = debugAfterAdoptionStep,
        _readOnlyOpener = readOnlyOpener ?? AppDatabase.openReadOnlyExisting,
        _debugBeforeReadOnlyClose = debugBeforeReadOnlyClose;

  static const String registryKey = 'qirsh.replicas.v1';
  static const String saltKey = 'qirsh.device_salt';
  static const String keyNamePrefix = 'qirsh.db_key.';
  static const String dbFileName = 'qirsh.sqlite';

  /// `RemoveDataFlow.barrierKey` / `.revokedKey`, repeated here because
  /// remove_data_flow.dart imports this file. Pinned by a test.
  static const String removalBarrierKey = 'qirsh.removal_barrier.v1';
  static const String removalRevokedKey = 'qirsh.removal_revoked.v1';

  /// The AppSession owner marker (`core/session/app_session.dart`). Read-only here.
  static const String ownerMarkerKey = 'local_data_owner_uid';
  static const String _transitionPrefix = 'owner-transition-pending:';

  /// P2 rollback grace for the `.adopted` legacy file (manifest §13).
  static const Duration adoptedGrace = Duration(days: 7);

  /// WP-7: how long a swapped rebootstrap keeps the replica it retired
  /// (manifest §13).
  static const Duration retiredReplicaRetention = Duration(days: 14);

  /// Directory/key suffixes of the side-by-side rebootstrap: `.rb` is the fresh
  /// replica being built, `.old` the retired one.
  static const String stagingSuffix = '.rb';
  static const String retiredSuffix = '.old';

  /// F2 — creating a replica (database file + key + registry entry) needs a
  /// current [AdmissionAuthority] with `canCreate`. False only for storage-layer
  /// tests that predate the admission authority and create replicas directly.
  final bool requireCreationAuthority;

  /// F2 — how long [remove] waits for secondary (background-isolate) connections
  /// to release their shared leases before it gives up. A timeout deletes
  /// NOTHING and fails the removal (its barrier is kept and resumes later).
  final Duration removalDrainTimeout;

  final FlutterSecureStorage _storage;
  final String? _appSupport;
  final DateTime Function() _now;
  final ReplicaOpener _opener;
  final Future<String?> Function()? _readOwnerMarker;
  final Future<void> Function(String step)? _debugStep;
  final ReadOnlyOpener _readOnlyOpener;
  final Future<void> Function(AppDatabase db)? _debugBeforeReadOnlyClose;

  final Map<String, AppDatabase> _open = {};
  final Map<String, AppDatabase> _staging = {};

  /// Offline local read. [_readOnly] is the published handle per uid hash;
  /// [_readOnlyLive] is EVERY read-only handle opened and not yet fully closed
  /// (published, being replaced, or just opened), so no live handle is ever
  /// untracked. A handle leaves the set only when its close has succeeded.
  final Map<String, AppDatabase> _readOnly = {};
  final Map<String, Set<AppDatabase>> _readOnlyLive = {};

  /// The coordinator-tracked handle of a read-only database opened under a
  /// reservation. It leaves the map only when its physical close was confirmed.
  final Map<AppDatabase, DatabaseOpenHandle> _readOnlyHandles = Map.identity();

  /// Per-hash serialization of read-only opens, and the invalidation generations
  /// (per hash, and store-wide for lifecycle/registry mutations) that an open
  /// captures and re-checks
  /// after every await. Per-store: this is NOT cross-isolate or cross-process
  /// exclusion.
  final Map<String, Future<void>> _readOnlyTail = {};
  final Map<String, int> _readOnlyGeneration = {};
  int _readOnlyStoreGeneration = 0;

  /// F2 — opens already dispatched per uid hash. [remove] drains them before the
  /// destructive step, so an open that passed its last authority check cannot
  /// finish AFTER the deletion and recreate the replica or its key.
  final Map<String, Set<Future<void>>> _opening = {};

  /// F2 — uid hashes whose replica is being removed. From the instant [remove]
  /// starts, every open, staging creation and swap for that hash is refused, and
  /// a retained swap stops at its next mutation boundary. Cleared when the
  /// removal finishes (an explicit re-admission may then create the replica).
  final Set<String> _removing = {};
  Future<void> _tail = Future.value();
  Future<String>? _saltFuture;

  // ------------------------------------------------------------------ paths

  Future<String> _support() async =>
      _appSupport ?? (await getApplicationSupportDirectory()).path;

  Future<String> _replicasRoot() async => p.join(await _support(), 'replicas');

  Future<ReplicaLocation> _location(String hash) async => ReplicaLocation(
        directory: p.join(await _replicasRoot(), hash),
        dbFileName: dbFileName,
        keyName: '$keyNamePrefix$hash',
      );

  Future<ReplicaLocation> _legacyLocation() async => ReplicaLocation(
        directory: await _support(),
        dbFileName: ReplicaLocation.legacyDbFileName,
        keyName: ReplicaLocation.legacyKeyName,
      );

  Future<Directory> _quarantineRoot() async =>
      Directory(p.join(await _replicasRoot(), '_quarantine'));

  // ---------------------------------------------------------------- uid hash

  Future<String> _deviceSalt() => _saltFuture ??= () async {
        final existing = await _storage.read(key: saltKey);
        if (existing != null && existing.isNotEmpty) return existing;
        final rng = Random.secure();
        final salt = List<int>.generate(32, (_) => rng.nextInt(256))
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        await _storage.write(key: saltKey, value: salt);
        return salt;
      }()
          .catchError((Object error, StackTrace stack) {
        // Not cached: a failed keychain read (protected data locked) is asked
        // again by the next call, not replayed for the life of the process.
        _saltFuture = null;
        Error.throwWithStackTrace(error, stack);
      });

  /// `hex(HMAC-SHA256(deviceSalt, uid))`, truncated to 128 bits.
  Future<String> uidHash(String uid) async =>
      _hashWithSalt(await _deviceSalt(), uid);

  static String _hashWithSalt(String salt, String uid) {
    final mac = Hmac(sha256, utf8.encode(salt));
    return mac.convert(utf8.encode(uid)).toString().substring(0, 32);
  }

  // ---------------------------------------------------------------- registry

  Future<Map<String, ReplicaEntry>> _readRegistry() async {
    final raw = await _storage.read(key: registryKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw) as Map<String, Object?>;
      return {
        for (final e in json.entries)
          e.key: ReplicaEntry.fromJson(
              e.key, (e.value! as Map).cast<String, Object?>()),
      };
    } catch (_) {
      // The registry is a hint, never authority: an unreadable one is empty and
      // is rebuilt from the replicas themselves as they are opened.
      return {};
    }
  }

  Future<void> _writeRegistry(Map<String, ReplicaEntry> m) => _storage.write(
        key: registryKey,
        value: jsonEncode({for (final e in m.entries) e.key: e.value.toJson()}),
      );

  /// Serialised read-modify-write of one entry (null result removes it).
  Future<void> _mutate(
      String hash, ReplicaEntry? Function(ReplicaEntry? current) f,
      {void Function()? guard}) {
    // Registry mutations can change offline eligibility or replace ownership.
    _readOnlyStoreGeneration++;
    _invalidateReadOnly(hash);
    final run = _tail.then((_) async {
      final reg = await _readRegistry();
      guard?.call();
      final next = f(reg[hash]);
      if (next == null) {
        reg.remove(hash);
      } else {
        reg[hash] = next;
      }
      guard?.call();
      await _writeRegistry(reg);
      _invalidateReadOnly(hash);
    });
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Every registry entry (never ownership authority).
  Future<List<ReplicaEntry>> list() async =>
      (await _readRegistry()).values.toList();

  /// Marks the replica `locked` (signed out; refuses open) or `active`.
  /// Returns false when no entry exists.
  Future<bool> setState(String uid, ReplicaState state,
      {AdmissionAuthority? authority}) async {
    authority?.requireFor(uid);
    _readOnlyStoreGeneration++;
    final hash = await uidHash(uid);
    void guard() {
      authority?.requireFor(uid);
      if (authority != null) _requireNotRemoving(hash);
    }

    guard();
    var found = false;
    await _mutate(hash, (c) {
      if (c == null) return null;
      found = true;
      return c.copyWith(state: state);
    }, guard: guard);
    return found;
  }

  // -------------------------------------------------------------- open/close

  /// Opens the replica of [uid].
  ///
  /// F2: CREATING a replica needs [authority] (current, `canCreate`); without it
  /// a missing database fails with [ReplicaMissingException] before any file,
  /// key or registry entry is written. An existing replica opens with or without
  /// authority, but a supplied authority is re-checked before every effect.
  ///
  /// Fails closed with [ReplicaUnavailableException] for `locked`/`migrating`/
  /// `quarantined` entries (call [setState] with `active` first once the session
  /// has authenticated), and with [ReplicaOwnershipException] when the file's
  /// `replica_meta.owner_uid` is absent or not [uid]. At most one open handle per
  /// uid is kept: a second call returns the already-open database.
  Future<AppDatabase> openReplica(
    String uid, {
    AdmissionAuthority? authority,
  }) async {
    if (uid.isEmpty || uid.startsWith(_transitionPrefix)) {
      throw const ReplicaOwnershipException();
    }
    authority?.requireFor(uid);
    final hash = await uidHash(uid);
    _requireNotRemoving(hash);
    // Re-checked after the await, so a cached handle is never returned to an
    // authority that was revoked while the salt was read.
    authority?.requireFor(uid);
    final already = _open[hash];
    if (already != null &&
        already.lifecycleState == DatabaseLifecycleState.open) {
      return already;
    }
    var openedHere = false;
    final db = await _track(hash, () async {
      final opened = await _openReplicaChecked(uid, hash, authority);
      openedHere = true;
      return opened;
    });
    if (authority != null && !authority.isCurrent) {
      // Revoked between the last check inside the open and this continuation: the
      // handle this call opened is not handed out.
      if (openedHere && identical(_open[hash], db)) {
        _open.remove(hash);
        await db.close();
      }
      throw const StaleAdmissionException();
    }
    return db;
  }

  Future<AppDatabase> _openReplicaChecked(
    String uid,
    String hash,
    AdmissionAuthority? authority,
  ) async {
    final entry = (await _readRegistry())[hash];
    if (entry != null && entry.state != ReplicaState.active) {
      throw ReplicaUnavailableException(entry.state);
    }
    authority?.requireFor(uid);
    if (entry == null &&
        requireCreationAuthority &&
        (authority == null || !authority.canCreate)) {
      throw const ReplicaMissingException();
    }
    final loc = await _location(hash);
    final existed = await File(loc.dbPath).exists();
    _requireNotRemoving(hash);
    final policy = _creationPolicy(uid, existed, authority);
    final db = await _opener(
      location: loc,
      runMigrations: true,
      creation: policy,
    );
    try {
      final owner = await _readMeta(db);
      if (owner == null && !existed) {
        authority?.requireFor(uid);
        await _writeMeta(db, uid);
      } else if (owner != uid) {
        throw const ReplicaOwnershipException();
      }
      authority?.requireFor(uid);
      _requireNotRemoving(hash);
      final now = _now();
      final version = await _userVersion(db);
      await _mutate(
        hash,
        (c) {
          if (c == null &&
              requireCreationAuthority &&
              (authority == null || !authority.canCreate)) {
            throw const ReplicaMissingException();
          }
          return c?.copyWith(
                  lastOpenedAt: now,
                  schemaVersion: version,
                  state: ReplicaState.active) ??
              ReplicaEntry(
                uidHash: hash,
                createdAt: now,
                lastOpenedAt: now,
                schemaVersion: version,
                epoch: 0,
                state: ReplicaState.active,
              );
        },
        guard: () {
          authority?.requireFor(uid);
          _requireNotRemoving(hash);
        },
      );
      authority?.requireFor(uid);
      _requireNotRemoving(hash);
    } catch (_) {
      await db.close();
      rethrow;
    }
    return _open[hash] = db;
  }

  /// What the open of [uid]'s replica may create. A missing registry entry, file
  /// or key is never permission: only a current authority of exactly this uid
  /// that may create is (or a storage-layer test that predates the authority).
  CreationPolicy _creationPolicy(
    String uid,
    bool existed,
    AdmissionAuthority? authority,
  ) {
    authority?.requireFor(uid);
    if (existed) return CreationPolicy.denied(authority: authority, uid: uid);
    if (authority != null) {
      if (!authority.canCreate) throw const ReplicaMissingException();
      return CreationPolicy.authorized(authority, uid);
    }
    if (!requireCreationAuthority) return const CreationPolicy.unrestricted();
    throw const ReplicaMissingException();
  }

  void _requireNotRemoving(String hash) {
    if (_removing.contains(hash)) throw const StaleAdmissionException();
  }

  Future<T> _track<T>(String hash, Future<T> Function() open) {
    final run = open();
    final done = run.then<void>((_) {}, onError: (Object _) {});
    (_opening[hash] ??= {}).add(done);
    done.whenComplete(() => _opening[hash]?.remove(done));
    return run;
  }

  Future<void> _drainOpens(String hash) async {
    while (true) {
      final pending = _opening[hash];
      if (pending == null || pending.isEmpty) return;
      await Future.wait(pending.toList());
    }
  }

  /// The pre-WP-3a shared database location (for the failed-adoption fallback).
  Future<ReplicaLocation> legacyLocation() => _legacyLocation();

  /// Where [uid]'s replica lives (whether or not it exists yet).
  Future<ReplicaLocation> locationFor(String uid) async =>
      _location(await uidHash(uid));

  /// Where the signed-in account's database lives, resolved from persisted state
  /// only (the owner marker + the registry), for code that has no in-memory
  /// account scope: the background capture/notification isolates and the backup
  /// service. Null when no account is admitted or its replica is not `active`
  /// (signed out = locked, SYNC-Q3), so such callers fail closed instead of
  /// opening someone else's file. A `migrating` replica whose legacy file is
  /// still in place resolves to the legacy file (a failed adoption "leaves the
  /// legacy file in place and in use").
  Future<ReplicaLocation?> activeLocation() async {
    final marker = await _marker();
    if (marker == null ||
        marker.isEmpty ||
        marker.startsWith(_transitionPrefix)) {
      return null;
    }
    final hash = await uidHash(marker);
    final entry = (await _readRegistry())[hash];
    if (entry == null) return null;
    // WP-7: until `swapped` has committed no background isolate may open the
    // replica a rebootstrap is replacing (capture delivery stays disabled).
    final rb = entry.rebootstrap;
    if (rb != null && rb.phase.index < RebootstrapPhase.swapped.index) {
      return null;
    }
    if (entry.state == ReplicaState.active) return _location(hash);
    if (entry.state == ReplicaState.migrating) {
      final legacy = await _legacyLocation();
      if (await File(legacy.dbPath).exists()) return legacy;
    }
    return null;
  }

  /// Closes every open handle (replicas and fresh staging replicas) without
  /// deleting anything. Idempotent.
  Future<void> closeAll() async {
    _readOnlyStoreGeneration++;
    for (final db in [..._open.values, ..._staging.values]) {
      await db.close();
    }
    _open.clear();
    _staging.clear();
    for (final hash in _readOnlyLive.keys.toList()) {
      await _closeAllReadOnly(hash);
    }
  }

  /// Closes the open replica of [uid], if any. Idempotent.
  Future<void> closeReplica(String uid) async {
    _readOnlyStoreGeneration++;
    final hash = await uidHash(uid);
    _invalidateReadOnly(hash);
    await _open.remove(hash)?.close();
    await _closeAllReadOnly(hash);
  }

  static Future<String?> _readMeta(AppDatabase db) async {
    final rows =
        await db.customSelect('SELECT owner_uid FROM replica_meta;').get();
    return rows.isEmpty ? null : rows.single.read<String>('owner_uid');
  }

  static Future<void> _writeMeta(AppDatabase db, String uid) async {
    final rng = Random.secure();
    final replicaId = List<int>.generate(16, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await db.customStatement(
      'INSERT INTO replica_meta(id, owner_uid, replica_id, server_epoch, '
      'created_at) VALUES (1, ?, ?, 0, ?);',
      [uid, replicaId, DateTime.now().toUtc().toIso8601String()],
    );
  }

  static Future<int> _userVersion(AppDatabase db) async =>
      (await db.customSelect('PRAGMA user_version;').getSingle())
          .read<int>('user_version');

  // ------------------------------------------------ offline local read (core)

  /// The device salt as it EXISTS. Unlike [_deviceSalt] this never mints one:
  /// without the original salt the uid hash (and so the replica) cannot be found.
  Future<String> _existingSalt() async {
    final String? salt;
    try {
      salt = await _storage.read(key: saltKey);
    } catch (_) {
      throw const LocalReadUnavailableException(LocalReadDenial.salt);
    }
    if (salt == null || salt.isEmpty) {
      throw const LocalReadUnavailableException(LocalReadDenial.salt);
    }
    return salt;
  }

  /// A flag that, when present, must really be a bool. [ReplicaEntry.fromJson]
  /// reads `== true`, so a string or number would silently read as "not set".
  static void _requireBoolIfPresent(Map<String, Object?> m, String key) {
    if (m.containsKey(key) && m[key] is! bool) {
      throw FormatException('registry flag $key');
    }
  }

  /// The registry as stored. Unlike [_readRegistry] an unreadable or malformed
  /// registry THROWS instead of reading as empty, and so does a restricting flag
  /// of the wrong type (`adoptPending`, `rebootstrap.swapping`) or an unknown
  /// rebootstrap phase. Omitted optional fields are legitimate and stay absent.
  Future<Map<String, ReplicaEntry>> _readRegistryStrict() async {
    final raw = await _storage.read(key: registryKey);
    if (raw == null || raw.isEmpty) return {};
    return _parseRegistryStrict(raw);
  }

  static Map<String, ReplicaEntry> _parseRegistryStrict(String raw) {
    final json = jsonDecode(raw) as Map<String, Object?>;
    final result = <String, ReplicaEntry>{};
    for (final e in json.entries) {
      final entry = (e.value! as Map).cast<String, Object?>();
      _requireBoolIfPresent(entry, 'adoptPending');
      final marker = entry['rebootstrap'];
      if (marker != null) {
        _requireBoolIfPresent(
            (marker as Map).cast<String, Object?>(), 'swapping');
      }
      result[e.key] = ReplicaEntry.fromJson(e.key, entry);
    }
    return result;
  }

  /// Restrictive evidence wins: throws [LocalReadUnavailableException] unless
  /// every durable record agrees that [uid]'s replica [hash] is the signed-in
  /// owner's, active and not being removed. Reads only; any read that fails, and
  /// any restricting record that parses as JSON but is malformed, is a refusal.
  Future<void> _requireLocalReadable(String uid, String hash) async {
    LocalReadUnavailableException deny(LocalReadDenial r) =>
        LocalReadUnavailableException(r);
    if (_removing.contains(hash)) throw deny(LocalReadDenial.removal);
    try {
      final marker = await _marker();
      if (marker != uid) throw deny(LocalReadDenial.ownerMarker);

      final barrier = await _storage.read(key: removalBarrierKey);
      if (barrier != null && barrier.isNotEmpty) {
        throw deny(LocalReadDenial.removal);
      }
      final revoked = await _storage.read(key: removalRevokedKey);
      if (revoked != null && revoked.isNotEmpty) {
        final decoded = jsonDecode(revoked);
        // A list of uid strings and nothing else: an element that is not a
        // non-empty string cannot be read as "not this uid".
        if (decoded is! List ||
            decoded.any((u) => u is! String || u.isEmpty) ||
            decoded.contains(uid)) {
          throw deny(LocalReadDenial.removal);
        }
      }
      final root = Directory(await _replicasRoot());
      if (await root.exists()) {
        await for (final e in root.list()) {
          final name = p.basename(e.path);
          if (name.startsWith('_removing.$hash')) {
            throw deny(LocalReadDenial.removal);
          }
        }
      }

      final raw = await _storage.read(key: registryKey);
      if (raw == null || raw.isEmpty) throw deny(LocalReadDenial.registry);
      final entry = (await _readRegistryStrict())[hash];
      if (entry == null) throw deny(LocalReadDenial.registry);
      final rb = entry.rebootstrap;
      if (entry.state != ReplicaState.active ||
          entry.adoptPending ||
          (rb != null &&
              (rb.swapping ||
                  rb.phase.index < RebootstrapPhase.swapped.index))) {
        throw deny(LocalReadDenial.replicaState);
      }
    } on LocalReadUnavailableException {
      rethrow;
    } catch (_) {
      // An unreadable record is not evidence of absence.
      throw deny(LocalReadDenial.unavailable);
    }
    if (_removing.contains(hash)) throw deny(LocalReadDenial.removal);
  }

  // Read-only handle lifecycle. Every handle is in [_readOnlyLive] from the
  // moment it exists until its close has FINISHED, so at every await a handle is
  // either tracked or closed, never live and untracked.

  void _invalidateReadOnly(String hash) =>
      _readOnlyGeneration[hash] = (_readOnlyGeneration[hash] ?? 0) + 1;

  Future<void> _closeReadOnly(String hash, AppDatabase db) async {
    await _debugBeforeReadOnlyClose?.call(db);
    await db.close();
    // A failed close has an unknown outcome and must remain tracked. In
    // particular, AppDatabase caches its close future: failure is not proof
    // that retrying it can release the underlying connection.
    _readOnlyLive[hash]?.remove(db);
    if (identical(_readOnly[hash], db)) _readOnly.remove(hash);
    // The coordinator's holder is released only by a close that completed.
    final handle = _readOnlyHandles[db];
    if (handle != null) {
      await handle.close();
      _readOnlyHandles.remove(db);
    }
  }

  /// Best-effort cleanup for an already failing open. A failed close remains
  /// tracked; explicit draining must report that failure before any deletion.
  Future<void> _discardReadOnly(String hash, AppDatabase db) async {
    try {
      await _closeReadOnly(hash, db);
    } catch (_) {
      // Retained for a later explicit drain; no successful close is claimed.
    }
  }

  Future<void> _closeAllReadOnly(String hash) async {
    for (final db in List.of(_readOnlyLive[hash] ?? const <AppDatabase>{})) {
      await _closeReadOnly(hash, db);
    }
  }

  /// Runs [f] after every earlier read-only open of [hash] has finished.
  Future<T> _serializeReadOnly<T>(String hash, Future<T> Function() f) {
    final run = (_readOnlyTail[hash] ?? Future<void>.value()).then((_) => f());
    final tail = run.then<void>((_) {}, onError: (Object _) {});
    _readOnlyTail[hash] = tail;
    tail.whenComplete(() {
      if (identical(_readOnlyTail[hash], tail)) _readOnlyTail.remove(hash);
    });
    return run;
  }

  /// Every read-only handle that is open or still closing (tests).
  @visibleForTesting
  Iterable<AppDatabase> get debugReadOnlyLive =>
      [for (final set in _readOnlyLive.values) ...set];

  /// Opens [uid]'s EXISTING replica for reading only, after verifying every
  /// piece of durable evidence; the offline local-read counterpart of
  /// [openReplica]. It is not [openReplica]: it holds no [AdmissionAuthority],
  /// cannot create, adopt, repair, unlock, migrate or register anything, and
  /// writes to neither secure storage nor the registry nor the database.
  ///
  /// Required, all read-only: the device salt, the owner marker naming [uid], no
  /// removal barrier / revoked entry / tombstone, an `active` registry entry for
  /// the uid hash (no adoption, swap or rebootstrap in progress), the database
  /// file, its stored key, an exactly current schema, and a `replica_meta` row
  /// whose `owner_uid` is [uid] and `replica_id` is [replicaId]. The evidence is
  /// checked again after the open, immediately before the handle is published.
  /// Refusal throws [LocalReadUnavailableException] and closes the handle or
  /// retains it for incomplete cleanup. It attempts no application writes, key
  /// creation or registry repair; destructive work waits for confirmed closure.
  ///
  /// Opens of one replica are serialized in this store; the newest published
  /// handle replaces (and closes) the previous one. Locking ([lockVerified]),
  /// [closeReplica], [closeAll] and removal invalidate opens already in flight:
  /// they re-check after every await and close what they opened instead of
  /// publishing it. This is a per-store fence, not cross-isolate exclusion.
  ///
  /// [reserve] (offline restoration, phase two): called once the evidence above
  /// validated and BEFORE the connection is touched, it returns the coordinator
  /// reservation this candidate open runs under. The real handle is registered
  /// with it the instant the opener returns it (a failed verification's handle
  /// stays registered until its close is confirmed); an outcome known to precede
  /// any connection releases it, an unknown one keeps it pending.
  ///
  /// [verifyExclusion] (B2) receives the replica's location after the evidence
  /// above validated and BEFORE [reserve]: the owner checks non-creating
  /// legacy/unregistered-holder evidence there and throws to deny. Any throw is
  /// an unavailable replica; nothing was opened.
  Future<LocalReadReplica> openReadOnlyReplica(
    String uid, {
    required String replicaId,
    required DatabaseOpenReservation Function(String uid) reserve,
    required void Function(ReplicaLocation location) verifyExclusion,
  }) =>
      _openReadOnlyReplica(uid,
          replicaId: replicaId,
          reserve: reserve,
          verifyExclusion: verifyExclusion);

  /// R8: the ONLY way to open a read-only replica without the coordinator
  /// reservation and exclusion evidence. A fixture seam: the result carries no
  /// reservation, so [AccountScopeHost.restoreLocalRead] refuses to publish it,
  /// and an architecture pin forbids any use of this name under `lib/`.
  @visibleForTesting
  Future<LocalReadReplica> openReadOnlyReplicaUncoordinatedForTesting(
    String uid, {
    required String replicaId,
  }) =>
      _openReadOnlyReplica(uid, replicaId: replicaId);

  Future<LocalReadReplica> _openReadOnlyReplica(
    String uid, {
    required String replicaId,
    DatabaseOpenReservation Function(String uid)? reserve,
    void Function(ReplicaLocation location)? verifyExclusion,
  }) async {
    if (uid.isEmpty || replicaId.isEmpty || uid.startsWith(_transitionPrefix)) {
      throw const LocalReadUnavailableException(LocalReadDenial.identity);
    }
    final storeGeneration = _readOnlyStoreGeneration;
    final hash = _hashWithSalt(await _existingSalt(), uid);
    final generation = _readOnlyGeneration[hash] ?? 0;
    void requireCurrent() {
      if (storeGeneration != _readOnlyStoreGeneration ||
          generation != (_readOnlyGeneration[hash] ?? 0)) {
        throw const LocalReadUnavailableException(LocalReadDenial.unavailable);
      }
    }

    return _track(
        hash,
        () => _serializeReadOnly(hash, () async {
              requireCurrent();
              await _requireLocalReadable(uid, hash);
              requireCurrent();
              final loc = await _location(hash);
              requireCurrent();
              if (verifyExclusion != null) {
                try {
                  verifyExclusion(loc);
                } catch (_) {
                  throw const LocalReadUnavailableException(
                      LocalReadDenial.unavailable);
                }
              }
              DatabaseOpenReservation? reservation;
              if (reserve != null) {
                try {
                  reservation = reserve(uid);
                  reservation.requireCurrent();
                } on LocalReadUnavailableException {
                  reservation?.releaseUnopened();
                  rethrow;
                } catch (_) {
                  // Nothing was opened; a refused or stale reservation denies.
                  reservation?.releaseUnopened();
                  throw const LocalReadUnavailableException(
                      LocalReadDenial.unavailable);
                }
              }
              final AppDatabase opened;
              try {
                opened = await _readOnlyOpener(
                  location: loc,
                  readKey: () => _storage.read(key: loc.keyName),
                );
              } on ReadOnlyCleanupIncompleteException catch (error) {
                // The opener created this handle but could not close it after
                // verification failed. Register it before the tracked open
                // settles, so removal must drain its real close before deletion.
                (_readOnlyLive[hash] ??= {}).add(error.database);
                if (reservation != null) {
                  _readOnlyHandles[error.database] = reservation
                      .registerOpened(error.database, close: error.database.close);
                }
                throw const LocalReadUnavailableException(
                    LocalReadDenial.unavailable);
              } on LocalDatabaseKeyUnavailableException {
                reservation?.releaseUnopened(); // refused before any connection
                throw const LocalReadUnavailableException(LocalReadDenial.key);
              } on ReadOnlySchemaUnsupportedException {
                reservation?.releaseUnopened(); // its handle was closed first
                throw const LocalReadUnavailableException(
                    LocalReadDenial.schema);
              } on FileSystemException {
                reservation?.releaseUnopened(); // no file: nothing to open
                throw const LocalReadUnavailableException(
                    LocalReadDenial.files);
              } catch (_) {
                // Unknown: a connection may exist, so the reservation stays.
                throw const LocalReadUnavailableException(
                    LocalReadDenial.unavailable);
              }
              // Tracked at once: nothing is awaited between the open and this line.
              (_readOnlyLive[hash] ??= {}).add(opened);
              if (reservation != null) {
                _readOnlyHandles[opened] =
                    reservation.registerOpened(opened, close: opened.close);
              }
              try {
                requireCurrent();
                final rows = await opened
                    .customSelect(
                        'SELECT owner_uid, replica_id FROM replica_meta;')
                    .get();
                requireCurrent();
                if (rows.length != 1 ||
                    rows.single.read<String>('owner_uid') != uid ||
                    rows.single.read<String>('replica_id') != replicaId) {
                  throw const LocalReadUnavailableException(
                      LocalReadDenial.ownership);
                }
                await _requireLocalReadable(uid, hash);
                requireCurrent();
                // Publish. The pointer moves with no await after the last check; the
                // previous handle is then closed, and a failed or overtaken close fails
                // this open and closes the new handle too.
                final previous = _readOnly[hash];
                _readOnly[hash] = opened;
                if (previous != null) await _closeReadOnly(hash, previous);
                requireCurrent();
              } on LocalReadUnavailableException {
                await _discardReadOnly(hash, opened);
                rethrow;
              } catch (_) {
                await _discardReadOnly(hash, opened);
                throw const LocalReadUnavailableException(
                    LocalReadDenial.unavailable);
              }
              return LocalReadReplica(
                  uid: uid,
                  replicaId: replicaId,
                  database: opened,
                  reservation: reservation);
            }));
  }

  /// Marks [uid]'s EXISTING registry entry `locked` and reports whether the
  /// registry, read back inside the same serialized turn, really says `locked`.
  /// False (nothing claimed) when there is no salt, no entry, an unreadable
  /// registry, or the write or its readback failed. Never creates an entry or a
  /// salt, and never replaces a registry it could not parse.
  ///
  /// It invalidates read-only opens in flight (before the write and again once it
  /// is read back) so none publishes after the lock. It does NOT close a handle
  /// that was already published: draining the host's users of it is the caller's
  /// job (not solved here).
  Future<bool> lockVerified(String uid, {bool Function()? stillValid}) async {
    if (!(stillValid?.call() ?? true)) return false;
    final String hash;
    try {
      hash = _hashWithSalt(await _existingSalt(), uid);
    } on LocalReadUnavailableException {
      return false;
    }
    if (!(stillValid?.call() ?? true)) return false;
    final run = _tail.then((_) async {
      var dispatched = false;
      try {
        if (!(stillValid?.call() ?? true)) return false;
        final reg = await _readRegistryStrict();
        // The caller's expected lifecycle is checked after the queued read,
        // immediately before dispatching the registry mutation.
        if (!(stillValid?.call() ?? true)) return false;
        final entry = reg[hash];
        if (entry == null) return false;
        // Only an eligible restrictive turn may invalidate its target's opens.
        // A refused turn and another uid's candidate have no shared effect.
        _invalidateReadOnly(hash);
        dispatched = true;
        if (entry.state != ReplicaState.locked) {
          reg[hash] = entry.copyWith(state: ReplicaState.locked);
          await _writeRegistry(reg);
        }
        return (await _readRegistryStrict())[hash]?.state ==
            ReplicaState.locked;
      } finally {
        // A dispatched write must drain even when its caller becomes stale.
        // Its target stays invalid until completion; a stale pre-dispatch no-op
        // must not invalidate a successor that began in the meantime.
        if (dispatched) _invalidateReadOnly(hash);
      }
    });
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    try {
      return await run;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------- WP-7 rebootstrap (§4.10)

  /// The rebootstrap marker of [uid]'s replica, or null when none is in progress.
  Future<RebootstrapMarker?> rebootstrapMarker(String uid) async =>
      (await _readRegistry())[await uidHash(uid)]?.rebootstrap;

  /// ASR E11 (§9.2/§12): [uid]'s replica exactly as local read itself
  /// requires it, and no rebootstrap anywhere — a non-empty, strictly parsed
  /// registry (malformed flags throw) whose entry for [uid] is `active` and
  /// not adoption-pending. [read] is the status-preserving accessor: it throws
  /// unless the item's absence is confirmed. Any failure, absence or
  /// restriction is false.
  Future<bool> asrRegistryPermits(String uid,
      {required Future<String?> Function(String key) read}) async {
    try {
      final raw = await read(registryKey);
      if (raw == null || raw.isEmpty) return false;
      final registry = _parseRegistryStrict(raw);
      if (registry.values.any((e) => e.rebootstrap != null)) return false;
      final hash = await uidHash(uid);
      final entry = registry[hash];
      return entry != null &&
          entry.state == ReplicaState.active &&
          !entry.adoptPending &&
          !_removing.contains(hash);
    } catch (_) {
      return false;
    }
  }

  /// Every replica with a rebootstrap in progress (launch resume).
  Future<List<ReplicaEntry>> pendingRebootstraps() async => [
        for (final e in await list())
          if (e.rebootstrap != null) e,
      ];

  /// Starts a rebootstrap at `frozen` (a no-op when one is already recorded, so
  /// the original reason survives a resume). False when the uid has no registry
  /// entry.
  Future<bool> beginRebootstrap(String uid, String reason) async {
    _readOnlyStoreGeneration++;
    final hash = await uidHash(uid);
    var found = false;
    await _mutate(hash, (c) {
      if (c == null) return null;
      found = true;
      if (c.rebootstrap != null) return c;
      return c.copyWith(
        rebootstrap: RebootstrapMarker(
          phase: RebootstrapPhase.frozen,
          reason: reason,
          startedAt: _now(),
        ),
      );
    });
    return found;
  }

  /// Durably advances the marker. Never moves it backwards; reaching
  /// `capture_resumed` ends the rebootstrap (the marker is removed).
  Future<void> advanceRebootstrap(String uid, RebootstrapPhase phase) async {
    _readOnlyStoreGeneration++;
    final hash = await uidHash(uid);
    await _mutate(hash, (c) {
      final m = c?.rebootstrap;
      if (c == null || m == null) return c;
      if (phase == RebootstrapPhase.captureResumed) {
        return c.copyWith(clearRebootstrap: true);
      }
      if (phase.index <= m.phase.index) return c;
      return c.copyWith(
        rebootstrap: RebootstrapMarker(
            phase: phase,
            reason: m.reason,
            startedAt: m.startedAt,
            swapping: m.swapping),
      );
    });
  }

  /// Opens (creating on first use) the FRESH replica a rebootstrap builds next to
  /// the live one: `replicas/<hash>.rb/` with its own key. It is owned by [uid]
  /// (asserted like [openReplica]), never registered as the replica, and never
  /// reachable by [activeLocation] / [openReplica] until [swapStaging].
  Future<AppDatabase> openStaging(
    String uid, {
    AdmissionAuthority? authority,
  }) async {
    if (uid.isEmpty || uid.startsWith(_transitionPrefix)) {
      throw const ReplicaOwnershipException();
    }
    authority?.requireFor(uid);
    final hash = await uidHash(uid);
    _requireNotRemoving(hash);
    authority?.requireFor(uid);
    final already = _staging[hash];
    if (already != null &&
        already.lifecycleState == DatabaseLifecycleState.open) {
      return already;
    }
    return _track(hash, () async {
      final loc = ReplicaLocation(
        directory: p.join(await _replicasRoot(), '$hash$stagingSuffix'),
        dbFileName: dbFileName,
        keyName: '$keyNamePrefix$hash$stagingSuffix',
      );
      final existed = await File(loc.dbPath).exists();
      _requireNotRemoving(hash);
      final policy = _creationPolicy(uid, existed, authority);
      final db = await _opener(
        location: loc,
        runMigrations: true,
        creation: policy,
      );
      try {
        final owner = await _readMeta(db);
        if (owner == null && !existed) {
          authority?.requireFor(uid);
          await _writeMeta(db, uid);
        } else if (owner != uid) {
          throw const ReplicaOwnershipException();
        }
        authority?.requireFor(uid);
        _requireNotRemoving(hash);
      } catch (_) {
        await db.close();
        rethrow;
      }
      return _staging[hash] = db;
    });
  }

  /// Deletes the fresh replica (directory and key) of an abandoned rebootstrap.
  Future<void> discardStaging(String uid) async {
    final hash = await uidHash(uid);
    await _staging.remove(hash)?.close();
    final dir = Directory(p.join(await _replicasRoot(), '$hash$stagingSuffix'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await _storage.delete(key: '$keyNamePrefix$hash$stagingSuffix');
  }

  /// Commits the swap: the live replica becomes `<hash>.old` (kept for
  /// [retiredReplicaRetention]) and the fresh one takes its place, then the
  /// marker is advanced to `swapped` and `retiredAt` stamped. Every step is
  /// decided from what is on disk, so a crash after any of [kSwapSteps] is
  /// finished by calling this again. Open handles are closed first; the caller
  /// reopens the replica through the account scope afterwards.
  ///
  /// F2: the swap shares [remove]'s exclusion. It is tracked like an open (so a
  /// removal waits for it instead of racing it) and it re-verifies [authority]
  /// and the removal flag immediately before EVERY mutation — each file move and
  /// each key write — so a removal accepted while it is paused stops it at its
  /// next boundary with a [StaleAdmissionException], and no key write or move
  /// lands after the removal.
  Future<void> swapStaging(
    String uid, {
    AdmissionAuthority? authority,
  }) async {
    authority?.requireFor(uid);
    _readOnlyStoreGeneration++;
    final hash = await uidHash(uid);
    _requireNotRemoving(hash);
    authority?.requireFor(uid);
    return _track(hash, () => _swap(uid, hash, authority));
  }

  Future<void> _swap(
    String uid,
    String hash,
    AdmissionAuthority? authority,
  ) async {
    void guard() {
      _requireNotRemoving(hash);
      authority?.requireFor(uid);
    }

    await closeReplica(uid);
    await _staging.remove(hash)?.close();
    guard();
    await _mutate(hash, (c) {
      final m = c?.rebootstrap;
      if (c == null || m == null) return c;
      return c.copyWith(
          rebootstrap: RebootstrapMarker(
              phase: m.phase,
              reason: m.reason,
              startedAt: m.startedAt,
              swapping: true));
    }, guard: guard);
    guard();
    final root = await _replicasRoot();
    final main = Directory(p.join(root, hash));
    final fresh = Directory(p.join(root, '$hash$stagingSuffix'));
    final old = Directory(p.join(root, '$hash$retiredSuffix'));
    final key = '$keyNamePrefix$hash';
    final freshKey = '$key$stagingSuffix';
    final oldKey = '$key$retiredSuffix';

    // A: not started (the live replica and the fresh one both exist). Any older
    // retained replica is superseded.
    if (await main.exists() && await fresh.exists()) {
      await _step('swap:beforeOldMoved');
      guard();
      if (await old.exists()) {
        guard();
        await old.delete(recursive: true);
      }
      guard();
      await _storage.delete(key: oldKey);
      guard();
      await main.rename(old.path);
      await _step('swap:afterOldMoved');
    }
    guard();
    // B: the live replica is retired but its key is not yet kept under the old
    // name (the live key still is the old replica's: it is only replaced in E).
    if (!await main.exists() && await old.exists()) {
      final existing = await _storage.read(key: oldKey);
      if (existing == null || existing.isEmpty) {
        final k = await _storage.read(key: key);
        if (k != null && k.isNotEmpty) {
          guard();
          await _storage.write(key: oldKey, value: k);
        }
      }
      await _step('swap:afterOldKey');
    }
    guard();
    // C: the fresh replica takes the live name.
    if (!await main.exists() && await fresh.exists()) {
      guard();
      await fresh.rename(main.path);
      await _step('swap:afterFreshMoved');
    }
    guard();
    // D: the live key becomes the fresh replica's.
    final fk = await _storage.read(key: freshKey);
    if (fk != null && fk.isNotEmpty) {
      guard();
      await _storage.write(key: key, value: fk);
      guard();
      await _storage.delete(key: freshKey);
    }
    await _step('swap:afterFreshKey');
    guard();
    if (!await main.exists()) {
      throw const FileSystemException('rebootstrap swap has no replica');
    }

    final hasOld = await old.exists();
    final now = _now();
    guard();
    await _mutate(hash, (c) {
      if (c == null) return null;
      final m = c.rebootstrap;
      final already = m?.phase == RebootstrapPhase.swapped;
      return c.copyWith(
        state: ReplicaState.active,
        retiredAt: hasOld ? (already ? c.retiredAt ?? now : now) : null,
        rebootstrap: m == null
            ? null
            : RebootstrapMarker(
                phase: RebootstrapPhase.swapped,
                reason: m.reason,
                startedAt: m.startedAt),
      );
    }, guard: guard);
  }

  /// Deletes retired replicas whose [retiredReplicaRetention] has passed (their
  /// directory and key). Safe to call on every launch.
  Future<void> purgeExpiredRetired() async {
    final now = _now();
    for (final e in await list()) {
      final at = e.retiredAt;
      if (at == null || now.difference(at) < retiredReplicaRetention) continue;
      final dir = Directory(
          p.join(await _replicasRoot(), '${e.uidHash}$retiredSuffix'));
      if (await dir.exists()) await dir.delete(recursive: true);
      await _storage.delete(key: '$keyNamePrefix${e.uidHash}$retiredSuffix');
      await _mutate(e.uidHash, (c) => c?.copyWith(clearRetiredAt: true));
    }
  }

  // ------------------------------------------------------------------ remove

  /// Deletes the replica of [uid]: its directory (database, WAL/SHM, every
  /// sidecar), its key and its registry entry. Only that uid's. Idempotent and
  /// crash-safe: the directory is first renamed (atomic) to a `_removing.<hash>`
  /// tombstone, then the key, the registry entry and the tombstone are removed;
  /// a crash after the rename is finished by [recoverPendingRemovals] (or by
  /// calling remove again). Open handles are closed first.
  Future<void> remove(String uid) async {
    _readOnlyStoreGeneration++;
    await _removeHash(await uidHash(uid));
  }

  /// F2: removal is exclusive, in this order:
  ///   1. REVOKE: from this synchronous instant every open, staging creation and
  ///      swap for this hash is refused ([_removing]);
  ///   2. DRAIN the primary side: opens and swaps already dispatched finish (a
  ///      swap stops at its next mutation boundary) and the open handles close;
  ///   3. DRAIN the secondary side: the exclusive database lease is taken through
  ///      the existing maintenance protocol, so background-isolate connections
  ///      holding shared leases release before anything is deleted (a timeout
  ///      deletes nothing and fails the removal);
  ///   4. rename every variant (`<hash>`, `.rb`, `.old`) to a tombstone WHILE the
  ///      lease is held: the maintenance intent travels with the live directory,
  ///      so exclusion is continuous until the directory is gone, and a late
  ///      secondary then finds no directory (the lease protocol never creates
  ///      one);
  ///   5. delete the keys, the registry entry and the tombstones.
  /// All three variants are always removed — without consulting the registry,
  /// whose bookkeeping an interrupted swap may never have completed.
  Future<void> _removeHash(String hash) async {
    _removing.add(hash);
    _invalidateReadOnly(hash);
    try {
      await _drainOpens(hash);
      await _open.remove(hash)?.close();
      await _staging.remove(hash)?.close();
      await _closeAllReadOnly(hash);
      final root = await _replicasRoot();
      const suffixes = ['', stagingSuffix, retiredSuffix];

      DatabaseFileLease? lease;
      final main = Directory(p.join(root, hash));
      if (await main.exists()) {
        final location = await _location(hash);
        final liveness =
            await AppDatabase.initProcessLiveness(location: location);
        if (!liveness.acquiredExclusive) {
          throw const DatabaseLeaseUnavailable('process_lock_unavailable');
        }
        final manager = await AppDatabase.appSupportLeaseManager(
          location: location,
        );
        lease = await manager.acquireExclusive(timeout: removalDrainTimeout);
      }
      final tombs = <Directory>[];
      try {
        for (final suffix in suffixes) {
          final dir = Directory(p.join(root, '$hash$suffix'));
          AppDatabase.dropProcessLiveness(
            ReplicaLocation(
              directory: dir.path,
              dbFileName: dbFileName,
              keyName: '$keyNamePrefix$hash$suffix',
            ),
          );
          final tomb = Directory(p.join(root, '_removing.$hash$suffix'));
          if (await dir.exists()) {
            if (await tomb.exists()) await tomb.delete(recursive: true);
            await dir.rename(tomb.path);
          }
          tombs.add(tomb);
        }
      } finally {
        await lease?.release();
      }
      for (final suffix in suffixes) {
        await _storage.delete(key: '$keyNamePrefix$hash$suffix');
      }
      await _mutate(hash, (_) => null);
      for (final tomb in tombs) {
        if (await tomb.exists()) await tomb.delete(recursive: true);
      }
    } finally {
      _removing.remove(hash);
    }
  }

  /// Finishes any removal that was interrupted after its directory rename.
  Future<void> recoverPendingRemovals() async {
    final root = Directory(await _replicasRoot());
    if (!await root.exists()) return;
    await for (final e in root.list()) {
      final name = p.basename(e.path);
      if (e is Directory && name.startsWith('_removing.')) {
        // `_removing.<hash>[.rb|.old]`; the hash is hex, so the first dot ends it.
        await _removeHash(name.substring('_removing.'.length).split('.').first);
        if (await e.exists()) await e.delete(recursive: true);
      }
    }
  }

  // ---------------------------------------------------------- legacy adoption

  /// True when a legacy database with no provable owner sits in
  /// `replicas/_quarantine/` (surface "This device has data from an unknown
  /// account"). Derived from the file system, so it survives registry loss.
  /// Quarantined files are never opened or inspected.
  Future<bool> hasQuarantinedLegacyData() async {
    final q = await _quarantineRoot();
    if (!await q.exists()) return false;
    await for (final e in q.list()) {
      if (e is Directory && p.basename(e.path).startsWith('legacy-')) {
        return true;
      }
    }
    return false;
  }

  /// One-time, crash-recoverable adoption of the legacy shared database (sync
  /// plan §05). Safe to call on every launch; also deletes `.adopted` files
  /// older than [adoptedGrace]. Never throws for ordinary failures: those return
  /// [AdoptionOutcome.failed] with the legacy file untouched and in use. Runtime
  /// admission cancellation throws and is drained by removal; it never falls
  /// back to opening the legacy file after its authority has been revoked.
  Future<AdoptionOutcome> adoptLegacyIfPresent(
      {AdmissionAuthority? authority}) async {
    authority?.requireFor(authority.uid);
    final legacy = await _legacyLocation();
    if (authority == null) {
      final outcome = await _adoptOrQuarantine(legacy);
      await _purgeExpiredAdopted(legacy);
      return outcome;
    }
    final hash = await uidHash(authority.uid);
    void guard() {
      authority.requireFor(authority.uid);
      _requireNotRemoving(hash);
    }

    guard();
    return _track(hash, () async {
      guard();
      final outcome = await _adoptOrQuarantine(legacy,
          authority: authority, runtimeHash: hash, guard: guard);
      guard();
      await _purgeExpiredAdopted(legacy, runtimeHash: hash, guard: guard);
      guard();
      return outcome;
    });
  }

  Future<AdoptionOutcome> _adoptOrQuarantine(ReplicaLocation legacy,
      {AdmissionAuthority? authority,
      String? runtimeHash,
      void Function()? guard}) async {
    guard?.call();
    if (!await File(legacy.dbPath).exists()) {
      for (final e in await list()) {
        if (runtimeHash != null && e.uidHash != runtimeHash) continue;
        if (e.adoptPending && await File('${legacy.dbPath}.adopted').exists()) {
          await _mutate(e.uidHash,
              (c) => c?.copyWith(adoptPending: false, legacyAdoptedAt: _now()),
              guard: guard);
        }
      }
      guard?.call();
      return AdoptionOutcome.none;
    }
    final marker = await _marker();
    guard?.call();
    if (authority != null && marker != authority.uid) {
      throw const ReplicaOwnershipException();
    }
    if (marker == null ||
        marker.isEmpty ||
        marker.startsWith(_transitionPrefix)) {
      try {
        await _quarantine(legacy);
        return AdoptionOutcome.quarantined;
      } on Exception {
        return AdoptionOutcome.failed;
      }
    }
    final hash = await uidHash(marker);
    final entry = (await _readRegistry())[hash];
    guard?.call();
    if (entry != null &&
        entry.state == ReplicaState.active &&
        !entry.adoptPending) {
      return AdoptionOutcome.legacyLeftover;
    }
    final target = await _location(hash);
    guard?.call();
    try {
      if (entry != null &&
          entry.state == ReplicaState.active &&
          entry.adoptPending) {
        await _finishRename(legacy, hash, guard: guard);
        return AdoptionOutcome.adopted;
      }
      await _adopt(legacy, target, marker, hash,
          authority: authority, guard: guard);
      return AdoptionOutcome.adopted;
    } on StaleAdmissionException {
      rethrow;
    } on Exception {
      guard?.call();
      return AdoptionOutcome.failed;
    }
  }

  Future<String?> _marker() => _readOwnerMarker != null
      ? _readOwnerMarker()
      : _storage.read(key: ownerMarkerKey);

  Future<void> _step(String name) async => _debugStep?.call(name);

  Future<void> _adopt(
      ReplicaLocation legacy, ReplicaLocation target, String uid, String hash,
      {AdmissionAuthority? authority, void Function()? guard}) async {
    guard?.call();
    final now = _now();
    // Re-entrant start: `migrating` + adoptPending, whatever a previous attempt
    // left behind is discarded and redone from the (untouched) legacy file.
    await _mutate(
      hash,
      (c) => ReplicaEntry(
        uidHash: hash,
        createdAt: c?.createdAt ?? now,
        lastOpenedAt: now,
        schemaVersion: 0,
        epoch: 0,
        state: ReplicaState.migrating,
        adoptPending: true,
      ),
      guard: guard,
    );
    await _step('beforeCopy');
    guard?.call();
    final dir = Directory(target.directory);
    if (await dir.exists()) {
      guard?.call();
      await dir.delete(recursive: true);
    }
    guard?.call();
    await dir.create(recursive: true);
    guard?.call();

    // Fold any WAL into the main file so a plain file copy is complete.
    final src = await _opener(
      location: legacy,
      runMigrations: false,
      creation: CreationPolicy.denied(authority: authority, uid: uid),
    );
    try {
      guard?.call();
      final row = await src
          .customSelect('PRAGMA wal_checkpoint(TRUNCATE);')
          .getSingle();
      if (row.read<int>('busy') != 0) {
        throw const FileSystemException('legacy checkpoint busy');
      }
    } finally {
      await src.close();
    }
    if (await File(legacy.walPath).exists() &&
        await File(legacy.walPath).length() > 0) {
      throw const FileSystemException('legacy WAL not folded');
    }
    guard?.call();
    await File(legacy.dbPath).copy(target.dbPath);
    await _step('afterCopy');

    final legacyKey = await _storage.read(key: legacy.keyName);
    if (legacyKey == null || legacyKey.isEmpty) {
      throw const LocalDatabaseKeyUnavailableException();
    }
    guard?.call();
    await _storage.write(key: target.keyName, value: legacyKey);
    await _step('afterKeyCopy');

    guard?.call();
    final copy = await _opener(
      location: target,
      runMigrations: true,
      creation: CreationPolicy.denied(authority: authority, uid: uid),
    );
    try {
      guard?.call();
      final integrity =
          await copy.customSelect('PRAGMA integrity_check;').get();
      if (integrity.length != 1 ||
          integrity.single.read<String>('integrity_check') != 'ok') {
        throw const FileSystemException('adopted copy failed integrity check');
      }
      guard?.call();
      await copy.customSelect('SELECT count(*) FROM sqlite_master;').get();
      await _step('afterProbe');
      guard?.call();
      if (await _readMeta(copy) != null) {
        throw const FileSystemException('unexpected replica_meta in legacy');
      }
      guard?.call();
      await _writeMeta(copy, uid);
      await _step('afterReplicaMeta');
      final version = await _userVersion(copy);
      await _mutate(hash, (c) => c!.copyWith(schemaVersion: version),
          guard: guard);
    } finally {
      await copy.close();
    }
    await _mutate(hash, (c) => c!.copyWith(state: ReplicaState.active),
        guard: guard);
    await _step('afterRegistryActive');
    await _finishRename(legacy, hash, guard: guard);
  }

  /// Renames the legacy file (+ WAL/SHM, main file LAST so its existence stays
  /// the "adoption incomplete" signal) to `.adopted`, then stamps the grace
  /// start. Idempotent.
  Future<void> _finishRename(ReplicaLocation legacy, String hash,
      {void Function()? guard}) async {
    await _step('beforeRename');
    for (final path in [legacy.walPath, legacy.shmPath, legacy.dbPath]) {
      final f = File(path);
      if (await f.exists()) {
        guard?.call();
        await f.rename('$path.adopted');
      }
    }
    await _step('afterRename');
    await _mutate(
        hash, (c) => c?.copyWith(adoptPending: false, legacyAdoptedAt: _now()),
        guard: guard);
  }

  /// Moves the legacy file with no provable owner into `_quarantine/` without
  /// opening it. Staged through `incoming/` so a crash mid-move resumes into the
  /// same directory (main file moved last).
  Future<void> _quarantine(ReplicaLocation legacy) async {
    final root = await _quarantineRoot();
    final staging = Directory(p.join(root.path, 'incoming'));
    await staging.create(recursive: true);
    for (final path in [legacy.walPath, legacy.shmPath, legacy.dbPath]) {
      final f = File(path);
      if (await f.exists()) {
        await f.rename(p.join(staging.path, p.basename(path)));
      }
    }
    await staging
        .rename(p.join(root.path, 'legacy-${_now().microsecondsSinceEpoch}'));
  }

  /// Deletes `.adopted` legacy files whose 7-day grace has passed (P2 rollback
  /// window over). Also drops the legacy key, but only when no legacy database
  /// file exists that would still need it.
  Future<void> _purgeExpiredAdopted(ReplicaLocation legacy,
      {String? runtimeHash, void Function()? guard}) async {
    final now = _now();
    for (final e in await list()) {
      if (runtimeHash != null && e.uidHash != runtimeHash) continue;
      guard?.call();
      final at = e.legacyAdoptedAt;
      if (at == null || now.difference(at) < adoptedGrace) continue;
      for (final path in [legacy.walPath, legacy.shmPath, legacy.dbPath]) {
        final f = File('$path.adopted');
        if (await f.exists()) {
          guard?.call();
          await f.delete();
        }
      }
      if (!await File(legacy.dbPath).exists()) {
        guard?.call();
        await _storage.delete(key: legacy.keyName);
      }
      await _mutate(e.uidHash, (c) => c?.copyWith(clearLegacyAdoptedAt: true),
          guard: guard);
    }
  }
}
