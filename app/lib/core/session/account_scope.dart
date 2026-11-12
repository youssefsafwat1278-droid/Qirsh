import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';

import '../../data/db/app_database.dart';
import '../../data/db/creation_policy.dart';
import '../../data/db/database_access_broker.dart';
import '../../data/db/planning_cutover.dart';
import '../../data/db/replica_location.dart';
import '../../data/db/replica_store.dart';
import 'admission_authority.dart';
import 'local_read_authority.dart';
import 'account_fence_authority.dart';

/// WP-3b — the ACCOUNT SCOPE: the one database the UI and every service work
/// against, and the uid it belongs to.
///
/// A scope is immutable. A switch (sign-in of another uid, sign-out, removal)
/// never mutates one: the old scope is withdrawn first ([AccountScopeHost.current]
/// becomes null so the root widget disposes every provider built on it), the old
/// database is closed, and only then is the next one opened and published under a
/// new [generation]. So no handle to one uid's database can be reached from
/// another uid's scope: the previous one is closed before the next exists.
/// What a published scope may do with its database. Fixed for the scope's whole
/// life: reconnecting never flips it, it publishes a new scope and generation.
enum AccountAccessMode {
  /// The ordinary, fully initialized, writable account scope.
  writable,

  /// Offline local read: a SQLite read-only connection to the account's existing
  /// replica, published without initialization. No writer, producer or cloud
  /// authority exists under it.
  localRead,
}

@immutable
class AccountScope {
  const AccountScope({
    required this.generation,
    required this.uid,
    required this.database,
    required this.location,
    this.hasLocalData = true,
    this.planningCutoverState = PlanningCutoverState.canonical,
    this.accessMode = AccountAccessMode.writable,
    this.localReadCapability,
  });

  /// Strictly increasing across the process; the root `ProviderScope` is keyed
  /// by it.
  final int generation;

  /// Null for the SIGNED-OUT scope: an in-memory, never-persisted database that
  /// only lets the pre-login screens render. It holds no account data.
  final String? uid;
  final AppDatabase database;

  /// Null for the signed-out scope; the legacy location while a failed adoption
  /// keeps the legacy file in use.
  final ReplicaLocation? location;
  final bool hasLocalData;
  final PlanningCutoverState planningCutoverState;
  final AccountAccessMode accessMode;

  /// The process capability a local-read scope is bound to (null otherwise).
  final LocalReadCapability? localReadCapability;

  bool get isLocalRead => accessMode == AccountAccessMode.localRead;
}

/// What the per-account startup steps resolved for a freshly opened database.
class AccountScopeInit {
  const AccountScopeInit({
    this.hasLocalData = true,
    this.planningCutoverState = PlanningCutoverState.canonical,
  });
  final bool hasLocalData;
  final PlanningCutoverState planningCutoverState;
}

/// What AppSession needs from the account-scope layer (kept narrow so the session
/// layer stays decoupled from the database layer, like its other hooks).
abstract class AccountScopeControl {
  /// The uid of the published account scope, or null (signed-out / switching).
  /// The session reads it, synchronously, as the uid an accepted Remove data
  /// authorizes when no admission completed in this process.
  String? get activeUid;

  /// The published scope itself (generation, uid, live database), read-only. It
  /// lets a capability be bound to the exact database it was issued for; nothing
  /// can be created or synthesized through it. Null while switching.
  AccountScope? get activeScope;

  /// An authenticated uid is admitted: unlock its replica (registry `active`),
  /// open it and publish it, locking and closing any other uid's replica first.
  ///
  /// F2: [authority] is re-checked, for [uid], before every side effect (lock,
  /// registry write, open/create, publication); a revoked one or one of another
  /// uid throws [StaleAdmissionException] having changed nothing. Only an
  /// authority with `canCreate` may create a replica that does not exist.
  Future<void> activate(String uid, {AdmissionAuthority? authority});

  /// Explicit sign-out: lock the active replica (registry `locked`), close it and
  /// publish the signed-out scope. Nothing is deleted.
  Future<void> lock();

  /// Remove-data step 2: close the active scope WITHOUT locking, because the
  /// replica is about to be deleted. Publishes the signed-out scope.
  Future<void> detach();

  /// Rebootstrap swap (WP-7): close the active scope like [detach], but publish
  /// NO scope. The host reports [AccountScopeHost.swapInProgress] and the root
  /// shows a loading state until the next [activate] (or [detach]/[lock]) so a
  /// normal swap never flashes the signed-out routes.
  Future<void> suspendForSwap();
}

class AccountScopeHost extends ChangeNotifier implements AccountScopeControl {
  /// R8: production construction REQUIRES the coordinator, so no production host
  /// can open, track or publish a replica outside the broker's ledger.
  AccountScopeHost({
    required this.store,
    required this.initialize,
    required DatabaseAccessBroker coordinator,
    Future<AppDatabase> Function()? openSignedOut,
    Future<void> Function(ReplicaLocation location)? prepareLocation,
    Future<void> Function()? afterWithdraw,
    this.reconcileReusedScope,
  })  : _coordinator = coordinator,
        _openSignedOut = openSignedOut ?? _defaultSignedOut,
        _prepareLocation = prepareLocation,
        _afterWithdraw =
            afterWithdraw ?? (() => Future<void>.delayed(Duration.zero));

  /// R8: a host with NO coordinator, for fixtures that exercise the scope layer
  /// alone. It can never produce a local-read reservation or publish a
  /// local-read scope. An architecture pin forbids any use of this name under
  /// `lib/`.
  @visibleForTesting
  AccountScopeHost.uncoordinatedForTesting({
    required this.store,
    required this.initialize,
    Future<AppDatabase> Function()? openSignedOut,
    Future<void> Function(ReplicaLocation location)? prepareLocation,
    Future<void> Function()? afterWithdraw,
    this.reconcileReusedScope,
  })  : _coordinator = null,
        _openSignedOut = openSignedOut ?? _defaultSignedOut,
        _prepareLocation = prepareLocation,
        _afterWithdraw =
            afterWithdraw ?? (() => Future<void>.delayed(Duration.zero));

  final ReplicaStore store;

  /// O: the inert coordinator (null when none exists in this process). It only
  /// tracks opens; it grants nothing to this host.
  final DatabaseAccessBroker? _coordinator;

  /// The coordinator this host reserves with (null when none), so an owner can
  /// prove it is using the same one.
  DatabaseAccessBroker? get localReadCoordinator => _coordinator;

  /// Real handles registered with the coordinator, until they are ACTUALLY
  /// closed. A failed close leaves the entry; it is never forgotten.
  final Map<AppDatabase, DatabaseOpenHandle> _tracked = Map.identity();

  /// Per-account startup steps (seed, flags, hooks, repairs). Run on every
  /// database before it is published; a throw closes it and fails the switch.
  final Future<AccountScopeInit> Function(AppDatabase db, String? uid)
      initialize;

  /// The authority of the activation whose [initialize] is running (null when
  /// none, or for an activation without one). Host turns are serialized, so
  /// this names exactly the activation the running initialization belongs to.
  AdmissionAuthority? get initializingAuthority => _initializing;
  AdmissionAuthority? _initializing;
  final Future<AppDatabase> Function() _openSignedOut;
  final Future<void> Function(ReplicaLocation location)? _prepareLocation;

  /// Awaited, inside the host turn, when an admission WITH authority re-admits
  /// the already published writable scope of its uid (no re-initialization runs
  /// for it). Lets the owner of the scope's services recover state that only a
  /// reconciliation can (a startup freeze). It must not enqueue or drain host
  /// operations. Never called without an authority.
  final Future<void> Function(AccountScope scope, AdmissionAuthority authority)?
      reconcileReusedScope;

  /// Completes once the withdrawn scope has been torn down by the UI.
  final Future<void> Function() _afterWithdraw;

  static Future<AppDatabase> _defaultSignedOut() =>
      AppDatabase.open(executor: NativeDatabase.memory());

  AccountScope? _current;
  int _generation = 0;
  bool _swapInProgress = false;
  Future<void> _tail = Future<void>.value();

  /// The published scope; null only while a switch is in flight.
  AccountScope? get current => _current;
  @override
  String? get activeUid => _current?.uid;
  @override
  AccountScope? get activeScope => _current;

  /// True from [suspendForSwap] until the next scope is published.
  bool get swapInProgress => _swapInProgress;
  int get generation => _generation;

  Future<T> _serial<T>(Future<T> Function() f) {
    final run = _tail.then((_) => f());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Launch: open [uid]'s replica WITHOUT unlocking it (a locked replica must stay
  /// closed until its uid authenticates, SYNC-Q3). A locked / quarantined replica
  /// or a null [uid] opens the signed-out scope.
  Future<AccountScope> openAtLaunch(
    String? uid, {
    DatabaseOpenReservation? Function(String uid)? reserveLaunch,
  }) async {
    final generation = _generation;
    final expected = _current;
    var denied = false;
    if (uid != null) {
      try {
        await AccountFenceAuthority.shared.guard(uid,
            current: () => _generation == generation && identical(_current, expected));
      } on AccountFenceDeniedException {
        denied = true;
      }
    }
    return _serial(() async {
      if (_generation != generation || !identical(_current, expected)) {
        throw const StaleAdmissionException();
      }
      if (denied) {
        await _withdraw();
        return _publishSignedOut();
      }
      if (uid != null) AccountFenceAuthority.shared.requireInHostTurn(uid, current: true);
      await _withdraw();
      if (uid != null) {
        AccountFenceAuthority.shared.requireInHostTurn(uid, current: _generation == generation);
        final reservation = reserveLaunch?.call(uid);
        try {
          final opened = await _openAccount(uid,
              _openingAuthority(uid, null, canCreate: false));
          return await _publishOpened(uid, opened, reservation: reservation);
        } on ReplicaUnavailableException {
          reservation?.releaseUnopened();
        } on ReplicaMissingException {
          reservation?.releaseUnopened();
        }
      }
      return _publishSignedOut();
    });
  }

  @override
  Future<void> activate(String uid, {AdmissionAuthority? authority}) async {
    final generation = _generation;
    final expected = _current;
    authority?.requireFor(uid);
    await AccountFenceAuthority.shared.guard(uid, current: () =>
        _generation == generation && identical(_current, expected) &&
        (authority?.isCurrent ?? true));
    return _serial(() async {
        // Checked when this turn STARTS, not only when it was queued: a removal
        // accepted while it waited must find it stale.
        authority?.requireFor(uid);
        AccountFenceAuthority.shared.requireInHostTurn(uid, current:
            _generation == generation && identical(_current, expected) &&
            (authority?.isCurrent ?? true));
        authority?.requireFor(uid);
        final reservation = authority?.openReservation;
        if (reservation != null &&
            (reservation.kind != DatabaseReservationKind.admissionPrimary ||
                reservation.uid != uid ||
                !reservation.isCurrent)) {
          // Another uid's, or a stale, reservation opens nothing.
          reservation.releaseUnopened();
          throw const StaleAdmissionException();
        }
        // A local-read scope is never reused for an admission: reconnecting
        // replaces it (database and generation) with a normal writable scope.
        if (_current?.uid == uid &&
            !_current!.isLocalRead &&
            _current!.database.lifecycleState == DatabaseLifecycleState.open) {
          // Nothing is opened for this admission: its primary is already
          // published (and tracked, if it was opened under a reservation).
          reservation?.releaseUnopened();
          await store.setState(uid, ReplicaState.active, authority: authority);
          AccountFenceAuthority.shared.requireInHostTurn(uid,
              current: _generation == generation && (authority?.isCurrent ?? true));
          authority?.requireFor(uid);
          final reused = _current!;
          final reconcile = reconcileReusedScope;
          if (authority != null && reconcile != null) {
            await reconcile(reused, authority);
            AccountFenceAuthority.shared.requireInHostTurn(uid,
                current: _generation == generation && authority.isCurrent);
            authority.requireFor(uid);
            if (!identical(_current, reused)) {
              throw const StaleAdmissionException();
            }
          }
          return;
        }
        var nativeOpenMayHaveStarted = false;
        try {
          await _withdraw(lockPrevious: true);
          AccountFenceAuthority.shared.requireInHostTurn(uid,
              current: _generation == generation && (authority?.isCurrent ?? true));
          authority?.requireFor(uid);
          reservation?.requireCurrent();
          await store.setState(uid, ReplicaState.active, authority: authority);
          AccountFenceAuthority.shared.requireInHostTurn(uid,
              current: _generation == generation && (authority?.isCurrent ?? true));
          reservation?.requireCurrent();
          nativeOpenMayHaveStarted = true;
          final (AppDatabase, ReplicaLocation?) opened;
          try {
            opened = await _openAccount(uid, _openingAuthority(uid, authority,
                canCreate: authority?.canCreate ?? !store.requireCreationAuthority));
          } on ReplicaUnavailableException {
            nativeOpenMayHaveStarted = false; // refused before any open
            rethrow;
          } on ReplicaMissingException {
            nativeOpenMayHaveStarted = false;
            rethrow;
          }
          await _publishOpened(
            uid,
            opened,
            authority: authority,
            reservation: reservation,
          );
        } catch (_) {
          // An outcome known to precede every open releases the reservation;
          // anything else keeps it pending (a handle may exist).
          if (!nativeOpenMayHaveStarted) reservation?.releaseUnopened();
          // The previous scope is already withdrawn: never leave the root
          // without one, whatever stopped the activation.
          await _publishSignedOut();
          rethrow;
        }
      });
  }

  @override
  Future<void> lock() => _serial(() async {
        await _withdraw(lockPrevious: true);
        await _publishSignedOut();
      });

  /// O8-2: [lock], but only when [expected] is still the published scope at the
  /// moment this turn STARTS in the serial queue. A scope published meanwhile by
  /// an independent admission is none of the caller's business and is left
  /// alone. Returns whether the lock ran.
  Future<bool> lockIfCurrent(AccountScope expected) => _serial(() async {
        if (!identical(_current, expected)) return false;
        await _withdraw(lockPrevious: true);
        await _publishSignedOut();
        return true;
      });

  @override
  Future<void> detach() => _serial(() async {
        if (_current == null) return; // launch-time resume: nothing is open yet
        await _withdraw();
        await _publishSignedOut();
      });

  @override
  Future<void> suspendForSwap() => _serial(() async {
        if (_current == null) return;
        _swapInProgress = true;
        await _withdraw(); // notifies: the root shows the swap loading state
      });

  /// Offline local read, phase two's reservation seam: the callback the
  /// restoration hands [LocalReadAuthority.restore] so the candidate open is
  /// registered with the coordinator before the connection is touched. The
  /// reservation comes ONLY from [exclusion] (owned, drained, legacy evidence
  /// verified) and only for this host's own coordinator; a host with no
  /// coordinator or another one cannot produce it (B1: no coordinator, no
  /// local read).
  DatabaseOpenReservation Function(String uid) localReadReserver({
    required DatabaseLocalReadExclusion exclusion,
    bool Function()? stillValid,
  }) {
    final coordinator = _coordinator;
    if (coordinator == null || !identical(exclusion.broker, coordinator)) {
      throw const DatabaseAccessUnavailable('coordinator_required');
    }
    return (uid) =>
        exclusion.reserveLocalReadCandidate(uid: uid, stillValid: stillValid);
  }

  /// Closes the current scope without locking or publishing another (the
  /// writable half of a writable-to-local-read transition). The registry stays
  /// `active`: the read-only restoration needs it. No-op when nothing is open.
  Future<void> suspendForLocalRead() => suspendForSwap();

  /// Publishes the signed-out scope only when nothing is published (a failed
  /// restoration after the writable scope was closed); never touches a scope
  /// another admission published meanwhile.
  Future<void> ensureScopePublished() => _serial(() async {
        if (_current == null) await _publishSignedOut();
      });

  /// Publishes the offline local-read scope for a restoration that
  /// [LocalReadAuthority.restore] verified. It accepts nothing else: not an
  /// [AdmissionAuthority], not a uid. It runs none of the account startup:
  /// no initialize, prepareLocation, migration, seed, registry write, adoption,
  /// repair, owner publication, capture hook, settings default or telemetry.
  ///
  /// Publishes only while the host is empty (a scope published meanwhile, e.g. a
  /// reconnect, wins), the capability is still the live grant, the handle is the
  /// read-only one the restoration reserved, and [stillValid] holds. Every
  /// refusal closes the verified handle through its tracked close first.
  Future<AccountScope> restoreLocalRead(
    LocalReadRestore verified, {
    bool Function()? stillValid,
  }) =>
      _serial(() async {
        final capability = verified.capability;
        final replica = verified.replica;
        if (capability == null || replica == null) {
          throw const StaleLocalReadException();
        }
        final db = replica.database;
        // R8: publication needs the coordinator and the EXACT exclusion-backed
        // reservation under which this read-only handle was opened: the
        // reservation travels with the verified replica, is a local-read
        // candidate of THIS host's coordinator for this uid, owns this very
        // database, still holds its fence, and the coordinator tracks the real
        // handle. Absent, mismatched, stale or untracked evidence refuses.
        final reservation = replica.reservation;
        final coordinator = _coordinator;
        final handle = reservation?.openHandle;
        final exclusive = coordinator != null &&
            reservation != null &&
            reservation.kind == DatabaseReservationKind.localReadCandidate &&
            reservation.isOwnedBy(coordinator) &&
            reservation.uid == replica.uid &&
            reservation.ownsDatabase(db) &&
            reservation.isCurrent &&
            handle != null &&
            !handle.isClosed;
        if (exclusive) _tracked[db] = handle;
        Future<Never> refuse(Object error) async {
          await _close(db, replica.uid);
          throw error;
        }

        if (!exclusive ||
            !AccountFenceAuthority.shared.permits(replica.uid) ||
            !db.isReadOnly ||
            replica.uid != capability.uid ||
            replica.replicaId != capability.replicaId ||
            !capability.isCurrent ||
            db.lifecycleState != DatabaseLifecycleState.open ||
            _current != null ||
            (stillValid != null && !stillValid())) {
          return refuse(const StaleLocalReadException());
        }
        final scope = AccountScope(
          generation: ++_generation,
          uid: replica.uid,
          database: db,
          location: null,
          accessMode: AccountAccessMode.localRead,
          localReadCapability: capability,
        );
        _current = scope;
        _swapInProgress = false;
        notifyListeners();
        return scope;
      });

  /// Launch, FIRST (before anything reads or writes the owner marker): finishes a
  /// removal that was interrupted after its directory rename, then adopts the
  /// legacy shared database into its owner's replica (or quarantines it when no
  /// owner is provable, B4). Must run before the session reconcile claims the
  /// marker, or an unowned legacy file would be adopted by whoever is restored.
  Future<AdoptionOutcome> recoverAtLaunch() async {
    await store.recoverPendingRemovals();
    final outcome = await store.adoptLegacyIfPresent();
    // WP-7: a replica a swapped rebootstrap retired is deleted after 14 days.
    await store.purgeExpiredRetired();
    return outcome;
  }

  AdmissionAuthority _openingAuthority(String uid,
      AdmissionAuthority? source, {required bool canCreate}) {
    final generation = _generation;
    return AdmissionAuthority(uid, () => _generation == generation &&
        AccountFenceAuthority.shared.permits(uid) && (source?.isCurrent ?? true),
        canCreate: canCreate, epoch: source?.epoch ?? 0,
        openReservation: source?.openReservation);
  }

  /// Opens the uid's replica; a `migrating` one (interrupted adoption) is retried
  /// once, and while it still cannot finish the legacy file stays in use.
  Future<(AppDatabase, ReplicaLocation?)> _openAccount(
    String uid,
    AdmissionAuthority? authority,
  ) async {
    try {
      return await _openReplica(uid, authority);
    } on ReplicaUnavailableException catch (e) {
      if (e.state != ReplicaState.migrating) rethrow;
    }
    authority?.requireFor(uid);
    final outcome = await store.adoptLegacyIfPresent(authority: authority);
    authority?.requireFor(uid);
    if (outcome == AdoptionOutcome.adopted) return _openReplica(uid, authority);
    final legacy = await store.legacyLocation();
    authority?.requireFor(uid);
    await _prepareLocation?.call(legacy);
    authority?.requireFor(uid);
    return (
      await AppDatabase.open(
        location: legacy,
        creation: CreationPolicy.denied(authority: authority, uid: uid),
      ),
      legacy,
    );
  }

  Future<(AppDatabase, ReplicaLocation?)> _openReplica(
    String uid,
    AdmissionAuthority? authority,
  ) async {
    final db = await store.openReplica(uid, authority: authority);
    return (db, await store.locationFor(uid));
  }

  Future<AccountScope> _publishOpened(
    String uid,
    (AppDatabase, ReplicaLocation?) opened, {
    AdmissionAuthority? authority,
    DatabaseOpenReservation? reservation,
  }) async {
    final (db, location) = opened;
    // The returned handle is registered BEFORE initialization or publication.
    _track(db, reservation, () async {
      await store.closeReplica(uid);
      await db.close(); // idempotent; covers the legacy-in-use handle too
    });
    return _publish(
      db,
      uid,
      location,
      authority: authority,
      reservation: reservation,
      closeOnFailure: () => _close(db, uid),
    );
  }

  Future<AccountScope> _publishSignedOut() async {
    final reservation = _coordinator?.reserveEphemeral();
    // An uncertain open keeps its pending ephemeral reservation (no release).
    final db = await _openSignedOut();
    _track(db, reservation, db.close);
    return _publish(db, null, null, closeOnFailure: () => _close(db, null));
  }

  /// Registers [db] with its reservation. A database already tracked (the
  /// store handed back its existing handle) keeps its original holder.
  void _track(AppDatabase db, DatabaseOpenReservation? reservation,
      Future<void> Function() close) {
    if (reservation == null) return;
    if (_tracked.containsKey(db)) {
      reservation.releaseUnopened();
      return;
    }
    _tracked[db] = reservation.registerOpened(db, close: close);
  }

  Future<AccountScope> _publish(
    AppDatabase db,
    String? uid,
    ReplicaLocation? location, {
    AdmissionAuthority? authority,
    DatabaseOpenReservation? reservation,
    required Future<void> Function() closeOnFailure,
  }) async {
    final AccountScopeInit init;
    try {
      if (uid != null) {
        AccountFenceAuthority.shared.requireInHostTurn(uid,
            current: authority?.isCurrent ?? true);
      }
      _initializing = authority;
      try {
        init = await initialize(db, uid);
      } finally {
        _initializing = null;
      }
      if (uid != null) {
        AccountFenceAuthority.shared.requireInHostTurn(uid,
            current: authority?.isCurrent ?? true);
      }
      // A stale activation never publishes: Remove data may have been accepted
      // while the replica was opening or initializing.
      if (authority != null && uid != null) authority.requireFor(uid);
      // The same for a reservation whose issuer lost its authority meanwhile.
      reservation?.requireCurrent();
    } catch (_) {
      await closeOnFailure();
      rethrow;
    }
    final scope = AccountScope(
      generation: ++_generation,
      uid: uid,
      database: db,
      location: location,
      hasLocalData: init.hasLocalData,
      planningCutoverState: init.planningCutoverState,
    );
    _current = scope;
    _swapInProgress = false;
    notifyListeners();
    return scope;
  }

  /// Runs only after affected operations drain; a delayed old cleanup never
  /// withdraws, locks or closes a different published scope.
  Future<void> closeAccountFenceScope(AccountScope expected) => _serial(() async {
    if (!identical(_current, expected) || _generation != expected.generation) return;
    await _withdraw();
    await _publishSignedOut();
  });

  /// The headless cold-start drain is done (or yields to the foreground):
  /// withdraws and ACTUALLY closes the published database, publishing nothing
  /// in its place. Its tracked handle's close releases the coordinator holder.
  Future<void> closeForHeadlessRelease() => _serial(_withdraw);

  Future<void> _close(AppDatabase db, String? uid) async {
    final handle = _tracked[db];
    if (handle != null) {
      // A read-only handle also lives in the store's own read-only bookkeeping;
      // its tracked close runs there first so both release together.
      if (db.isReadOnly && uid != null) await store.closeReplica(uid);
      // The tracked close IS the close; only its success releases the holder.
      await handle.close();
      _tracked.remove(db);
      return;
    }
    if (uid != null) await store.closeReplica(uid);
    await db.close(); // idempotent; covers the legacy-in-use handle too
  }

  /// Withdraws the published scope (the UI disposes every provider built on it),
  /// then closes its database. Optionally locks the previous uid's replica FIRST,
  /// so a crash mid-switch leaves it locked, never open to the next sign-in.
  Future<void> _withdraw({bool lockPrevious = false}) async {
    final prev = _current;
    if (prev == null) return;
    if (lockPrevious && prev.uid != null) {
      await store.setState(prev.uid!, ReplicaState.locked);
    }
    _current = null;
    notifyListeners();
    await _afterWithdraw();
    await _close(prev.database, prev.uid);
  }
}
