import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' show IsolateNameServer, RootIsolateToken;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../core/session/admission_authority.dart';
import '../../core/session/app_session.dart';

enum DatabaseAccessMode { closed, writable, quiescing, localRead, maintenance }

class DatabaseAccessUnavailable implements Exception {
  const DatabaseAccessUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'DatabaseAccessUnavailable($reason)';
}

/// What a foreground bootstrap found when it asked a HEADLESS coordinator of
/// this VM to step aside ([DatabaseAccessBroker.reclaimFromHeadless]).
enum HeadlessYield {
  /// No coordinator is registered (or this isolate already owns one).
  none,

  /// A headless coordinator stopped and released the name; the foreground may
  /// now create its own.
  released,

  /// The registered coordinator is a FOREGROUND one: nothing changes, creation
  /// fails closed exactly as before.
  foregroundHolder,

  /// Nothing answered within the bound (a dead registration or a hung holder):
  /// nothing changes, creation fails closed exactly as before.
  unresponsive,

  /// A headless coordinator agreed to stop but had not released within the
  /// bound (an item still committing). Transient: retry.
  stillRunning,
}

/// Initial O core. A never-removed VM name mapping is the coordinator tombstone.
///
/// C2 ownership rule: exactly one coordinator per Dart VM, owned by the genuine
/// foreground bootstrap. Missing, colliding, dead or unproven authority is
/// RESTRICTIVE: the caller must stop (startup error with retry); this class never
/// unregisters, replaces or recreates a coordinator to restore availability, and
/// an empty replacement is never proof that no old holder exists. `_retained` is
/// an isolate static: it proves reuse inside this isolate only. Survival and
/// exclusivity across Flutter engine recreation, foreground/background engine
/// overlap, stale named ports and a genuine process restart are NOT proven here
/// (platform evidence required, see the unit report).
/// Background engines may discover a live port; they may never create or replace
/// it. The ONE exception is the headless cold-start capture drain
/// ([createHeadless]): it may create the coordinator only when NONE is
/// registered, and it yields to a foreground bootstrap and releases the name
/// ([reclaimFromHeadless], [releaseHeadless]); the foreground always wins.
/// The embedding must retain this VM for the OS process lifetime. This is
/// source-level coordination, not executed multi-engine lifecycle proof.
///
/// No database/lease/key/storage/native/network operation occurs here; this class
/// is bookkeeping and arbitration. WIRED callers (R4 correction): the host's
/// primary, cold-launch and in-memory signed-out opens reserve here
/// ([reserveAdmissionOpen], [reserveColdLaunchOpen], [reserveEphemeral]); headless
/// secondary opens obtain a host-issued job over the SendPort protocol; the
/// offline local-read restoration owns [beginLocalReadExclusion]. NOT wired:
/// [transition] to `maintenance` has no production caller (replica removal and
/// maintenance take their own file lease), and [transition] to `localRead` is
/// refused on purpose: a local-read mode exists only after an exclusion
/// published a verified read scope.
class DatabaseAccessBroker {
  DatabaseAccessBroker._(this._admission)
      : processNonce = _nonce(),
        _receive = ReceivePort() {
    _receive.listen(_message);
  }

  static const _name = 'qirsh.database_access_broker.O.v1';
  static final _random = Random.secure();
  static String _nonce() => List.generate(32, (_) => _random.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  /// The coordinator this isolate created, retained for its whole lifetime so a
  /// rebuilt bootstrap reuses it instead of registering a replacement.
  static DatabaseAccessBroker? _retained;

  /// The first foreground creation failure (collision, dead port, no root
  /// token). It is remembered for the isolate's lifetime: a later attempt never
  /// becomes a FRESH creation, because an empty replacement is no proof that an
  /// old holder is gone. Only a proven existing coordinator can be reused.
  static DatabaseAccessUnavailable? _creationDenied;

  /// Set by headless entry points: such an isolate may discover, never create.
  static bool _backgroundEntry = false;

  /// A background entry point (notification callback, ownerless processor)
  /// declares itself first. From then on this isolate can only [discover].
  /// RootIsolateToken alone cannot tell a background engine from the host.
  static void markBackgroundEntrypoint() => _backgroundEntry = true;

  static bool get hasRetained => _retained != null;

  /// Creates the INERT coordinator: it grants no issuer, no job, no mode, no
  /// maintenance and no opener permission, so it is safe to create before the
  /// SDK or any database exists. Only the genuine foreground bootstrap calls it,
  /// once, before its first Drift opener or destructive recovery entry; a retry
  /// or rebuild gets the retained instance. A name collision (including a dead
  /// old port) is permanently restrictive; nothing is ever replaced.
  static DatabaseAccessBroker createInert() {
    if (_backgroundEntry) {
      throw const DatabaseAccessUnavailable('background_cannot_create');
    }
    final retained = _retained;
    if (retained != null) {
      // Only a PROVEN live coordinator is reused: its port is open and is still
      // the one published under the name. Otherwise authority is unproven and
      // stays denied; nothing is unregistered or recreated.
      if (!retained.isProven) {
        throw const DatabaseAccessUnavailable('coordinator_unproven');
      }
      return retained;
    }
    final denied = _creationDenied;
    if (denied != null) throw denied;
    if (_debugHideRootToken || RootIsolateToken.instance == null) {
      throw _creationDenied =
          const DatabaseAccessUnavailable('foreground_host_required');
    }
    final broker = DatabaseAccessBroker._(null);
    if (!IsolateNameServer.registerPortWithName(
        broker._receive.sendPort, _name)) {
      broker._receive.close();
      throw _creationDenied =
          const DatabaseAccessUnavailable('coordinator_already_registered');
    }
    return _retained = broker;
  }

  // ------------------------------------------------- headless (cold start)
  //
  // The cold-start background capture drain (Android WorkManager worker / iOS
  // BGTask with no live engine) runs in a HEADLESS engine of the same VM. It may
  // create the coordinator ONLY when none is registered, holds it for the
  // duration of one bootstrap + drain, and RELEASES it (unregisters the name,
  // closes its port) when done. The foreground always wins: a foreground
  // bootstrap that finds a coordinator asks it to yield
  // ([reclaimFromHeadless]); a headless one stops at its next item boundary,
  // closes its databases and releases, and only then does the foreground create
  // its own. A foreground coordinator never yields and is never released.

  static const _yieldRequest = 'qirsh.coordinator.yield.v1';

  /// Published (with the same port) only by a headless coordinator, BEFORE it
  /// takes [_name]: a foreground bootstrap asks a holder to yield only when the
  /// holder is marked headless. Any other holder (a foreground engine, a
  /// foreign or stale registration) fails closed at once, as before.
  static const _headlessMarker = 'qirsh.database_access_broker.O.v1.headless';

  bool _headless = false;
  bool _yieldRequested = false;
  final List<SendPort> _yieldWaiters = [];

  /// Called (once per request) when a foreground bootstrap asks this headless
  /// coordinator to step aside. The holder stops at its next item boundary.
  void Function()? onYieldRequested;

  /// True once a foreground bootstrap asked this headless coordinator to yield.
  bool get yieldRequested => _yieldRequested;
  bool get isHeadless => _headless;

  /// The headless background entry's coordinator. Refused (never latched, never
  /// replacing anything) when any coordinator is already registered in the VM:
  /// a live foreground engine owns the replica and the headless run does nothing.
  static DatabaseAccessBroker createHeadless() {
    if (_backgroundEntry) {
      throw const DatabaseAccessUnavailable('background_cannot_create');
    }
    if (_retained != null) {
      throw const DatabaseAccessUnavailable('coordinator_already_registered');
    }
    final broker = DatabaseAccessBroker._(null).._headless = true;
    final port = broker._receive.sendPort;
    final marked =
        IsolateNameServer.registerPortWithName(port, _headlessMarker);
    if (!marked || !IsolateNameServer.registerPortWithName(port, _name)) {
      if (marked) IsolateNameServer.removePortNameMapping(_headlessMarker);
      broker._receive.close();
      broker._disposed = true;
      throw const DatabaseAccessUnavailable('coordinator_already_registered');
    }
    return _retained = broker;
  }

  /// Ends the headless ownership: only when every holder (pending or open) has
  /// ACTUALLY closed. Unregisters the name (only while it is still this port),
  /// tells every waiting foreground and closes the port. A refused release keeps
  /// the registration: the foreground then keeps failing closed, never opens a
  /// replica beside an unconfirmed handle.
  bool releaseHeadless() {
    if (!_headless || _disposed) return false;
    if (_holders.isNotEmpty) return false;
    if (IsolateNameServer.lookupPortByName(_name) == _receive.sendPort) {
      IsolateNameServer.removePortNameMapping(_name);
    }
    if (IsolateNameServer.lookupPortByName(_headlessMarker) ==
        _receive.sendPort) {
      IsolateNameServer.removePortNameMapping(_headlessMarker);
    }
    _disposed = true;
    _mode = DatabaseAccessMode.closed;
    for (final waiter in _yieldWaiters) {
      waiter.send(const ['released']);
    }
    _yieldWaiters.clear();
    _receive.close();
    if (identical(_retained, this)) _retained = null;
    return true;
  }

  /// A FOREGROUND bootstrap, before creating its coordinator: when the name is
  /// held by a coordinator marked headless, ask it to yield and wait (bounded)
  /// for the release. A holder that is not marked headless is never asked
  /// ([HeadlessYield.foregroundHolder]: the caller fails closed as before). A
  /// headless coordinator answers `yielding` and later `released`; a foreground
  /// one answers `denied`; a dead registration answers nothing. This never
  /// unregisters, replaces or creates anything itself.
  static Future<HeadlessYield> reclaimFromHeadless({
    Duration timeout = const Duration(seconds: 20),
    Duration poll = const Duration(milliseconds: 50),
  }) async {
    if (_retained != null) return HeadlessYield.none;
    if (IsolateNameServer.lookupPortByName(_name) == null) {
      return HeadlessYield.none;
    }
    final replies = ReceivePort();
    var yielding = false;
    var denied = false;
    replies.listen((message) {
      if (message is! List || message.isEmpty) return;
      if (message[0] == 'yielding') yielding = true;
      if (message[0] == 'denied') denied = true;
    });
    final deadline = DateTime.now().add(timeout);
    SendPort? asked;
    try {
      while (true) {
        final holder = IsolateNameServer.lookupPortByName(_name);
        if (holder == null) {
          return yielding ? HeadlessYield.released : HeadlessYield.none;
        }
        if (denied) return HeadlessYield.foregroundHolder;
        if (holder != asked &&
            IsolateNameServer.lookupPortByName(_headlessMarker) != holder) {
          return asked == null && !yielding
              ? HeadlessYield.foregroundHolder
              : HeadlessYield.unresponsive;
        }
        if (holder != asked) {
          // A new registration (or the first one): ask it.
          asked = holder;
          yielding = false;
          holder.send([_yieldRequest, replies.sendPort]);
        }
        if (!DateTime.now().isBefore(deadline)) {
          return yielding
              ? HeadlessYield.stillRunning
              : HeadlessYield.unresponsive;
        }
        await Future<void>.delayed(poll);
      }
    } finally {
      replies.close();
    }
  }

  /// Creates the coordinator AND installs a live authentic writable host. A
  /// coordinator that already exists in this isolate is never re-started.
  static DatabaseAccessBroker start(DatabaseHostAdmission admission) {
    if (!admission.isCurrent) {
      throw const DatabaseAccessUnavailable('host_issuer_required');
    }
    if (_retained != null) {
      throw const DatabaseAccessUnavailable('coordinator_already_registered');
    }
    final broker = createInert();
    broker._admission = admission;
    return broker;
  }

  /// Ledger-only coordinator that is NOT registered under the VM name. For unit
  /// tests of the reservation bookkeeping; reachable by nothing but its holder.
  @visibleForTesting
  static DatabaseAccessBroker debugUnregistered() =>
      DatabaseAccessBroker._(null);

  @visibleForTesting
  void debugDispose() {
    _disposed = true;
    _receive.close();
  }

  bool _disposed = false;

  /// True only while this coordinator's port is open AND is still the one
  /// published under the process-wide name (a lost or replaced name is unproven).
  bool get isProven =>
      !_disposed &&
      IsolateNameServer.lookupPortByName(_name) == _receive.sendPort;

  /// Test-only: forget every holder and any transition so a test that left an
  /// uncertain holder behind does not poison the next one.
  @visibleForTesting
  void debugClearLedgerForTest() {
    _holders.clear();
    _ephemeralHolders.clear();
    _holderGeneration.clear();
    _reservationPermits.clear();
    _permits.clear();
    _exclusion = null;
    _transitioning = false;
    _drain = null;
    _mode = DatabaseAccessMode.closed;
  }

  /// Test seam: behave as if no root isolate token exists (missing authority).
  static bool _debugHideRootToken = false;
  @visibleForTesting
  static set debugHideRootToken(bool value) => _debugHideRootToken = value;

  /// Test-only: forget the retained coordinator and its name so a test can stage
  /// the next failure. Production never calls this.
  @visibleForTesting
  static void debugResetForTest() {
    final retained = _retained;
    if (retained != null) {
      retained._disposed = true;
      retained._receive.close();
    }
    _retained = null;
    _creationDenied = null;
    _backgroundEntry = false;
    _debugHideRootToken = false;
    IsolateNameServer.removePortNameMapping(_name);
    IsolateNameServer.removePortNameMapping(_headlessMarker);
  }

  /// Discovery is not an authority grant. Missing discovery never bootstraps.
  static DatabaseBrokerClient? discover() {
    final port = IsolateNameServer.lookupPortByName(_name);
    return port == null ? null : DatabaseBrokerClient(port);
  }

  DatabaseHostAdmission? _admission;
  final ReceivePort _receive;
  final String processNonce;
  DatabaseAccessMode _mode = DatabaseAccessMode.closed;
  int _generation = 0;
  final Map<String, bool> _holders = {}; // false = pending open, true = opened
  final Map<Capability, _DatabaseJobPermit> _permits = {};
  final Map<String, Capability> _reservationPermits = {};
  Completer<void>? _drain;
  bool _transitioning = false;

  /// B2: the single exclusive local-read transition, while one is owned.
  DatabaseLocalReadExclusion? _exclusion;

  /// Holders that are in-memory only (signed-out ephemeral); they touch no
  /// replica file, so they neither block nor are blocked by an exclusion.
  final Set<String> _ephemeralHolders = {};

  /// Transition generation each job holder was reserved under. A close
  /// acknowledgement must present exactly this generation.
  final Map<String, int> _holderGeneration = {};

  int get _physicalHolders =>
      _holders.keys.where((id) => !_ephemeralHolders.contains(id)).length;

  void _notifyDrainIfDone() {
    final drain = _drain;
    if (drain == null || drain.isCompleted) return;
    final done = _exclusion != null ? _physicalHolders == 0 : _holders.isEmpty;
    if (done) drain.complete();
  }

  DatabaseAccessMode get mode => _mode;

  /// True while no authentic host issuer was ever installed. An inert
  /// coordinator is pure exclusion bookkeeping.
  bool get isInert => _admission == null;
  int get pendingOpens => _holders.values.where((opened) => !opened).length;
  int get openHolders => _holders.values.where((opened) => opened).length;

  /// Host issuance BEFORE a job launches. Discovery never calls this getter.
  /// Every transferable job permit binds this actual issuer and generation;
  /// retaining a client cannot adopt a later owner's authenticated scope.
  DatabaseBrokerClient get client {
    final admission = _admission;
    if (_mode != DatabaseAccessMode.writable ||
        admission == null ||
        !admission.isCurrent) {
      return DatabaseBrokerClient(_receive.sendPort);
    }
    final token = Capability();
    _permits[token] = _DatabaseJobPermit(admission, processNonce, _generation);
    return DatabaseBrokerClient._issued(
        _receive.sendPort, token, processNonce, _generation);
  }

  /// Communication endpoint only. Authentic authority stays in the coordinator.
  SendPort get endpoint => _receive.sendPort;

  /// Core scheduling only: maintenance mode is NOT authorization to touch the
  /// DB, and no production code calls this for `maintenance` (R4 correction:
  /// the primary/cold-launch/ephemeral openers and the local-read exclusion ARE
  /// wired, see the class comment). Restricts synchronously, then drains actual
  /// acknowledgements. While it runs, and after a timeout, the coordinator is
  /// quiescing and [_reserve] refuses every persistent reservation (R7); a
  /// timeout keeps every uncertain reservation/holder and grants nothing. Only
  /// [recoverFromQuiescing] leaves that state.
  Future<void> transition(DatabaseAccessMode target,
      {DatabaseHostAdmission? admission,
      Duration timeout = const Duration(seconds: 5)}) async {
    if (_transitioning || target == DatabaseAccessMode.quiescing) {
      throw const DatabaseAccessUnavailable('transition_in_progress');
    }
    if (target == DatabaseAccessMode.localRead) {
      throw const DatabaseAccessUnavailable('verified_read_scope_unwired');
    }
    if (target != DatabaseAccessMode.closed &&
        (admission == null || !admission.isCurrent)) {
      throw const DatabaseAccessUnavailable('host_issuer_required');
    }
    _transitioning = true;
    _mode = DatabaseAccessMode.quiescing;
    _generation++;
    _permits.clear(); // old jobs never inherit the next owner's lifetime
    try {
      if (_holders.isNotEmpty) {
        _drain = Completer<void>();
        await _drain!.future.timeout(timeout);
      }
      if (target != DatabaseAccessMode.closed && !admission!.isCurrent) {
        throw const DatabaseAccessUnavailable('stale_host_issuer');
      }
      if (admission != null) _admission = admission;
      _mode = target;
    } on TimeoutException {
      throw const DatabaseAccessUnavailable('cleanup_incomplete');
    } finally {
      _transitioning = false;
      _drain = null;
    }
  }

  /// B2: the ATOMIC quiescing transition for an offline local-read restoration.
  ///
  /// In one synchronous step it (a) takes sole ownership of the transition, (b)
  /// moves to [DatabaseAccessMode.quiescing] and bumps the generation, so every
  /// old reservation and job permit goes stale and every old opener/close
  /// acknowledgement of an older generation is refused for publication, and (c)
  /// makes [_reserve] and the SendPort `reserve` path refuse everything except
  /// the in-memory signed-out database and this transition's own candidate.
  /// Nothing is awaited and nothing is created. The returned object then drains
  /// ([DatabaseLocalReadExclusion.awaitDrained]), verifies legacy/unregistered
  /// holder evidence, and only afterwards hands out the candidate reservation.
  /// An empty ledger of a replacement coordinator is never proof of exclusion.
  ///
  /// This does NOT call [recoverFromQuiescing]: it acquires a NEW exclusion
  /// (refused while another transition or exclusion exists) and the owner must
  /// still complete its own drain, evidence check and candidate reservation
  /// before anything is issued. Recovery from a quiescing state that no
  /// transition owns is the separate, explicit [recoverFromQuiescing].
  DatabaseLocalReadExclusion beginLocalReadExclusion() {
    if (_disposed || _transitioning || _exclusion != null) {
      throw const DatabaseAccessUnavailable('transition_in_progress');
    }
    _transitioning = true;
    _mode = DatabaseAccessMode.quiescing;
    _generation++;
    _permits.clear();
    return _exclusion = DatabaseLocalReadExclusion._(this, _generation);
  }

  /// R7: the EXPLICIT recovery transition out of a quiescing state that no
  /// transition owns any more (a timed-out or failed local-read restoration
  /// after its exclusion was released, or a timed-out [transition]). It succeeds
  /// only when no transition is running and EVERY physical holder (pending or
  /// open) has actually closed and been acknowledged; it then bumps the
  /// generation, so no old reservation or job is revived, and returns to
  /// `closed`. It never opens writable access and never switches `localRead` to
  /// `writable`: a later writable admission must be issued by the host. Returns
  /// whether the coordinator is now free of quiescing.
  bool recoverFromQuiescing() {
    if (_disposed || _transitioning || _exclusion != null) return false;
    if (_mode != DatabaseAccessMode.quiescing) return false;
    if (_physicalHolders != 0) return false;
    _generation++;
    _permits.clear();
    _mode = DatabaseAccessMode.closed;
    return true;
  }

  void _endExclusion(DatabaseLocalReadExclusion exclusion,
      {required bool published}) {
    if (!identical(_exclusion, exclusion)) return;
    _exclusion = null;
    _transitioning = false;
    _drain = null;
    // Published read scope: local-read mode (no job, no writer). Otherwise only a
    // fully drained ledger may return to closed; an uncertain holder keeps the
    // coordinator quiescing. Nothing here re-opens writable access.
    _mode = published
        ? DatabaseAccessMode.localRead
        : (_physicalHolders == 0
            ? DatabaseAccessMode.closed
            : DatabaseAccessMode.quiescing);
  }

  // ------------------------------------------------------ private ledger
  //
  // Single-opener reservations for an ALREADY authorized in-flight operation.
  // Exclusion bookkeeping only: they carry no job permit, issue no client,
  // change no mode and cannot be reached through the SendPort protocol. The
  // reference to this coordinator is held by the bootstrap host / AppSession.

  /// Reserve BEFORE any native/Drift connection of an admission's open. Binds
  /// the uid, the authentic admission identity, the captured loss generation,
  /// this coordinator's nonce and its transition generation. [stillValid] is
  /// the owner's own in-flight predicate (admission + loss still current).
  DatabaseOpenReservation reserveAdmissionOpen({
    required String uid,
    required Object admissionIdentity,
    required int lossGeneration,
    bool Function()? stillValid,
  }) =>
      _reserve(DatabaseOpenReservation._(
          this,
          DatabaseReservationKind.admissionPrimary,
          uid,
          admissionIdentity,
          lossGeneration,
          processNonce,
          _generation,
          stillValid));

  /// Reserve BEFORE the cold-launch opener of the existing replica of [uid].
  /// [launchIdentity] is the `LaunchAdmission` the launch owner came from.
  /// Bookkeeping only (no job permit, no mode change, no creation power).
  DatabaseOpenReservation reserveColdLaunchOpen({
    required String uid,
    required Object launchIdentity,
    required int lossGeneration,
    bool Function()? stillValid,
  }) =>
      _reserve(DatabaseOpenReservation._(
          this,
          DatabaseReservationKind.coldLaunchPrimary,
          uid,
          launchIdentity,
          lossGeneration,
          processNonce,
          _generation,
          stillValid));

  /// The accountless, nonpersistent signed-out in-memory database. Selects no
  /// replica, key, owner, lease or maintenance authority.
  DatabaseOpenReservation reserveEphemeral() => _reserve(
      DatabaseOpenReservation._(this, DatabaseReservationKind.ephemeralSignedOut,
          null, null, 0, processNonce, _generation, null));

  DatabaseOpenReservation _reserve(DatabaseOpenReservation reservation) {
    if (_disposed) throw const DatabaseAccessUnavailable('coordinator_dead');
    final exclusion = _exclusion;
    final candidateKind =
        reservation.kind == DatabaseReservationKind.localReadCandidate;
    final memoryOnly =
        reservation.kind == DatabaseReservationKind.ephemeralSignedOut;
    // R7: the guard is the coordinator's STATE, not only the exclusion object.
    // Quiescing outlives the object that started it (a timed-out restoration
    // releases its exclusion while uncertain holders remain; an ordinary
    // transition quiesces without any), so every incompatible persistent
    // reservation is refused in every quiescing/transition state until an
    // explicit [recoverFromQuiescing]. Only the memory-only signed-out database
    // and the running exclusion's own verified candidate may register.
    if (exclusion != null ||
        _transitioning ||
        _mode == DatabaseAccessMode.quiescing) {
      final own = candidateKind &&
          exclusion != null &&
          identical(reservation._exclusion, exclusion);
      if (!own && !memoryOnly) {
        throw DatabaseAccessUnavailable(exclusion != null
            ? 'exclusive_transition_in_progress'
            : 'coordinator_quiescing');
      }
    } else if (candidateKind) {
      // A candidate exists only inside an owned exclusive transition.
      throw const DatabaseAccessUnavailable('exclusion_required');
    }
    _holders[reservation._id] = false; // pending open, BEFORE the opener runs
    if (reservation.kind == DatabaseReservationKind.ephemeralSignedOut) {
      _ephemeralHolders.add(reservation._id);
    }
    return reservation;
  }

  void _holderClosed(String id) {
    _holders.remove(id);
    _ephemeralHolders.remove(id);
    _holderGeneration.remove(id);
    _notifyDrainIfDone();
  }

  void _message(dynamic value) {
    if (value is List &&
        value.length == 2 &&
        value[0] == _yieldRequest &&
        value[1] is SendPort) {
      final reply = value[1] as SendPort;
      // A foreground coordinator never yields: the asker fails closed as before.
      if (!_headless || _disposed) {
        reply.send(const ['denied']);
        return;
      }
      _yieldRequested = true;
      _yieldWaiters.add(reply);
      reply.send(const ['yielding']);
      try {
        onYieldRequested?.call();
      } catch (_) {
        // The flag above is the authority; the callback only hurries it.
      }
      return;
    }
    if (value is! List || value.length != 6 || value[5] is! SendPort) return;
    final reply = value[5] as SendPort;
    final command = value[0];
    final nonce = value[1];
    final generation = value[2];
    final token = value[3];
    final permitToken = value[4];
    final permit = _permits[permitToken];
    final permitCurrent = permit != null &&
        _admission != null &&
        identical(permit.admission, _admission) &&
        permit.admission.isCurrent &&
        permit.nonce == processNonce &&
        nonce == permit.nonce &&
        permit.generation == _generation &&
        generation == permit.generation;
    if (command == 'reserve') {
      if (_exclusion != null ||
          _mode != DatabaseAccessMode.writable ||
          !permitCurrent ||
          permit.reserved) {
        reply.send(['denied']);
        return;
      }
      final id = _nonce();
      permit.reserved = true; // one bounded opener per host-issued job
      _holders[id] = false; // BEFORE the client can call its opener
      _holderGeneration[id] = _generation;
      _reservationPermits[id] = permitToken as Capability;
      reply.send(['reserved', processNonce, _generation, id]);
      return;
    }
    if (nonce != processNonce ||
        token is! String ||
        !_holders.containsKey(token) ||
        !_reservationPermits.containsKey(token) ||
        _reservationPermits[token] != permitToken) {
      reply.send(['denied']);
      return;
    }
    // An old generation may still prove ACTUAL cleanup of the holder it was
    // issued, and only that one: the acknowledgement must present exactly the
    // generation the holder was reserved under. It can never publish an opening
    // handle or reserve another one (see 'opened' / 'reserve').
    if (command == 'closed') {
      if (generation != _holderGeneration[token]) {
        reply.send(['denied']);
        return;
      }
      _holders.remove(token);
      _holderGeneration.remove(token);
      _reservationPermits.remove(token);
      _permits.remove(permitToken);
      _notifyDrainIfDone();
      reply.send(['closed']);
      return;
    }
    if (command == 'opened') {
      _holders[token] = true; // retain loser until actual cleanup confirmation
      final accepted = generation == _generation &&
          _exclusion == null &&
          _mode == DatabaseAccessMode.writable &&
          permitCurrent &&
          _reservationPermits[token] == permitToken;
      reply.send([accepted ? 'opened' : 'denied']);
      return;
    }
    reply.send(['denied']);
  }
}

class _DatabaseJobPermit {
  _DatabaseJobPermit(this.admission, this.nonce, this.generation);
  final DatabaseHostAdmission admission;
  final String nonce;
  final int generation;
  bool reserved = false;
}

/// Public construction carries communication only and cannot open. Only the
/// host broker can issue the private, one-opener transferable job permit; both
/// reservation and publication revalidate its exact issuer and generation.
class DatabaseBrokerClient {
  const DatabaseBrokerClient(this._port,
      {this.timeout = const Duration(seconds: 5)})
      : _permit = null,
        _processNonce = null,
        _generation = null;
  const DatabaseBrokerClient._issued(
      this._port, this._permit, this._processNonce, this._generation)
      : timeout = const Duration(seconds: 5);
  final SendPort _port;
  final Capability? _permit;
  final String? _processNonce;
  final int? _generation;
  final Duration timeout;

  /// True only for a job client the host broker issued (never for discovery or a
  /// hand-built client). Authority is still checked by the coordinator at
  /// reserve and publication.
  bool get isHostIssued => _permit != null;

  Future<List<dynamic>> _request(String command,
      {String? nonce, int? generation, String? token}) async {
    final receive = ReceivePort();
    try {
      _port.send([
        command,
        nonce ?? _processNonce,
        generation ?? _generation,
        token,
        _permit,
        receive.sendPort
      ]);
      final answer = await receive.first.timeout(timeout);
      if (answer is! List) throw const DatabaseAccessUnavailable('bad_reply');
      return answer;
    } on TimeoutException {
      throw const DatabaseAccessUnavailable('coordinator_unresponsive');
    } finally {
      receive.close();
    }
  }

  /// Reserve first; any failed/unknown open stays registered. A returned handle
  /// rejected at publication is closed before reservation release. A failed
  /// close never sends acknowledgement and remains incomplete.
  Future<DatabaseBrokerHandle<T>> open<T>(
      {required Future<T> Function() open,
      required Future<void> Function(T) close}) async {
    final reservation = await _request('reserve');
    if (reservation[0] != 'reserved') {
      throw const DatabaseAccessUnavailable('reservation_denied');
    }
    final nonce = reservation[1] as String;
    final generation = reservation[2] as int;
    final token = reservation[3] as String;
    // If open throws, an uncertain handle may already exist. Retain reservation.
    final value = await open();
    final holder =
        DatabaseBrokerHandle<T>._(this, value, close, nonce, generation, token);
    try {
      final published = await _request('opened',
          nonce: nonce, generation: generation, token: token);
      if (published[0] != 'opened') {
        throw const DatabaseAccessUnavailable('publication_denied');
      }
      return holder;
    } catch (_) {
      await holder.close();
      rethrow;
    }
  }
}

class DatabaseBrokerHandle<T> {
  DatabaseBrokerHandle._(this._client, this.value, this._close, this._nonce,
      this._generation, this._token);
  final DatabaseBrokerClient _client;
  final T value;
  final Future<void> Function(T) _close;
  final String _nonce;
  final int _generation;
  final String _token;
  Future<void>? _closing;

  /// Cache failure too: a repeated failed Future is never physical-close proof.
  Future<void> close() => _closing ??= _closeConfirmed();

  Future<void> _closeConfirmed() async {
    await _close(value);
    final result = await _client._request('closed',
        nonce: _nonce, generation: _generation, token: _token);
    if (result[0] != 'closed') {
      throw const DatabaseAccessUnavailable('cleanup_unconfirmed');
    }
  }
}

enum DatabaseReservationKind {
  admissionPrimary,
  ephemeralSignedOut,

  /// The cold-launch primary open of the owner `prepareLaunchAdmission` chose,
  /// minted only by AppSession/the retained bootstrap. It authorizes ONLY that
  /// existing-replica open: no creation, no background job, not committed
  /// authority. It is promoted only through committed publication.
  coldLaunchPrimary,

  /// A read-only candidate open of an offline local-read restoration.
  localReadCandidate,
}

/// A private single-opener reservation. It authorizes only the open and
/// initialization of the admission that minted it. It never issues background
/// jobs, never becomes a local-read grant and never claims onboarding is done.
class DatabaseOpenReservation {
  DatabaseOpenReservation._(
      this._broker,
      this.kind,
      this.uid,
      this.admissionIdentity,
      this.lossGeneration,
      this.coordinatorNonce,
      this.transitionGeneration,
      this._stillValid,
      {DatabaseLocalReadExclusion? exclusion})
      : _exclusion = exclusion,
        _id = DatabaseAccessBroker._nonce();

  final DatabaseAccessBroker _broker;
  final String _id;
  final DatabaseReservationKind kind;
  final String? uid;
  final Object? admissionIdentity;
  final int lossGeneration;
  final String coordinatorNonce;
  final int transitionGeneration;
  final bool Function()? _stillValid;
  final DatabaseLocalReadExclusion? _exclusion;
  DatabaseOpenHandle? _handle;
  bool _released = false;
  bool _staleAtRegistration = false;
  bool _promoted = false;

  bool get hasOpened => _handle != null;

  /// Whether this reservation was issued by [broker] (R8: publication of a
  /// local-read scope accepts only its own host coordinator's candidate).
  bool isOwnedBy(DatabaseAccessBroker broker) => identical(_broker, broker);

  /// The tracked physical handle once registered (null before).
  DatabaseOpenHandle? get openHandle => _handle;

  /// Whether [database] is the real handle this reservation registered.
  bool ownsDatabase(Object database) {
    final handle = _handle;
    return handle != null && identical(handle.value, database);
  }
  bool get isPromoted => _promoted;

  /// Still the coordinator's own, its generation unchanged, not released, and
  /// the owner's in-flight predicate holds.
  bool get isCurrent =>
      !_released &&
      coordinatorNonce == _broker.processNonce &&
      transitionGeneration == _broker._generation &&
      (_exclusion?._reservationValid ?? true) &&
      (_stillValid?.call() ?? true);

  void requireCurrent() {
    if (!isCurrent) throw const StaleAdmissionException();
  }

  /// Registers the REAL handle immediately after the opener returned it. It is
  /// tracked even if this reservation went stale during the open: a stale or
  /// failing opener's handle stays registered until actually closed.
  DatabaseOpenHandle registerOpened(Object database,
      {required Future<void> Function() close}) {
    final existing = _handle;
    if (existing != null) return existing;
    _staleAtRegistration = !isCurrent;
    final handle = DatabaseOpenHandle._(this, database, close);
    _handle = handle;
    _broker._holders[_id] = true;
    return handle;
  }

  /// Only for an outcome KNOWN to precede any native open (nothing exists to
  /// track). Never forgets a registered handle; an unknown failure keeps the
  /// pending reservation.
  void releaseUnopened() {
    _released = true;
    if (_handle == null) _broker._holderClosed(_id);
  }

  /// Committed-publication promotion: allowed only for the exact registered
  /// primary handle of [uid], on the same coordinator and generation, that was
  /// current when registered. Grants no broker authority by itself.
  bool promoteCommitted(Object database, {required String uid}) {
    final handle = _handle;
    final ok = (kind == DatabaseReservationKind.admissionPrimary ||
            kind == DatabaseReservationKind.coldLaunchPrimary) &&
        handle != null &&
        !handle.isClosed &&
        !_staleAtRegistration &&
        !_released &&
        this.uid == uid &&
        identical(handle.value, database) &&
        coordinatorNonce == _broker.processNonce &&
        transitionGeneration == _broker._generation;
    if (ok) _promoted = true;
    return ok;
  }
}

/// The tracked physical handle of a reservation.
class DatabaseOpenHandle {
  DatabaseOpenHandle._(this._reservation, this.value, this._close);
  final DatabaseOpenReservation _reservation;
  final Object value;
  final Future<void> Function() _close;
  Future<void>? _closing;
  bool _closed = false;

  bool get isClosed => _closed;

  /// Cached failure too: a repeated failed Future is never physical-close
  /// proof. Only a close that actually completed releases the holder.
  Future<void> close() => _closing ??= _closeConfirmed();

  Future<void> _closeConfirmed() async {
    await _close();
    _closed = true;
    _reservation._broker._holderClosed(_reservation._id);
  }
}

/// Evidence about holders that are NOT in the coordinator ledger (a legacy or
/// unregistered opener), read WITHOUT creating anything: no lease directory, no
/// intent, no lock/instance file, no key, salt or sidecar.
///
/// R5 — ABSENCE MUST BE VERIFIED, NOT INFERRED. `FileSystemEntity.typeSync`
/// documents `notFound` for a missing entry AND for other lookup failures
/// (permission, loop, unresolved link), so it is never used as absence proof.
/// Instead the replica directory itself is listed (without following links): a
/// name that is not in a successful listing of its parent is verified absent,
/// while a failed listing, an entry that is present but of an unexpected type
/// (a link of any kind, a file where the lease directory belongs), a lease or
/// intent name (including a half-published temporary record) and a
/// lease/intent path that is not a direct child of the replica directory all
/// DENY. The directory is created before the lease record is written
/// (`DatabaseLeaseManager._acquireShared` creates it, then publishes the
/// record through a temporary file and a rename), so an existing EMPTY lease
/// directory is the normal state after every lease was released and is also
/// the window of a creator between those two steps: only the exclusion below
/// (not this snapshot) can distinguish them.
///
/// In-process lease-creator inventory (the exclusion argument). A snapshot proves
/// nothing about a creator that starts after it, so the caller may use this only
/// while every in-process creator is DRAINED or PREVENTED through check, open and
/// publication, which [DatabaseLocalReadExclusion] arranges:
///  * `AppDatabase.openSecondary` (the only `acquireShared` caller): reached by
///    the notification/capture isolates solely through a host-issued job over
///    the SendPort protocol. The exclusion bumps the generation and clears
///    every permit synchronously, so no job can reserve; a job that reserved
///    earlier is a pending/open holder that [DatabaseLocalReadExclusion
///    .awaitDrained] waits to see physically closed (its lease released with
///    the connection) before this check can run.
///  * Primary, cold-launch and in-memory opens create no lease (`acquireShared`
///    is not on their path); the first two are persistent reservations refused
///    for the whole exclusion, the third touches no file.
///  * `acquireExclusive`/`publishIntentOnly` create an INTENT, which this
///    evidence reads as a denial. The complete production creator inventory is:
///      - replica removal (`ReplicaStore`, `acquireExclusive`), driven by Remove
///        data, which the session serialises with the restoration;
///      - `AppDatabase.runFileExclusiveMaintenance` (via
///        `runExclusiveMaintenance`), whose only production caller is the backup
///        restore (`RestoreService.execute`, reached through
///        `EncryptedBackupService.commitRestore` and the restore prompt's
///        `RestoreController`). It is NOT serialised by Remove data. It is
///        drained or denied instead: (1) `RestoreService.execute` runs inside
///        `AppSession.runMaintenanceParticipant`, so the restoration's
///        `drainAdmissions` awaits a running restore and a restore that has not
///        started is refused (no journal write, lease or intent) from the
///        moment a restoration begins until its outcome, and while a read scope
///        is published; (2) the restoration's suspension closes the database,
///        and `AppDatabase.close` refuses every maintenance caller that is
///        queued or still draining (no intent created) and awaits the one that
///        already holds the gate, so no maintenance intent can appear after the
///        exclusion's verification and none overlaps the published read scope.
///    A maintenance caller that bypasses the database object it was admitted
///    through is not covered (see the inventory document).
///  * `initProcessLiveness`/`recoverEndedInstances` only DELETE records of ended
///    instances at startup, before any restoration.
/// An opener that bypasses these entrances, or a second OS process, is NOT
/// excluded by this evidence (the OS-process protocol is out of scope); where
/// exclusion cannot be established the caller refuses/defers.
class LegacyHolderEvidence {
  const LegacyHolderEvidence._(this.isClear, this.reason);
  final bool isClear;
  final String reason;

  static const _deny = LegacyHolderEvidence._;

  static LegacyHolderEvidence inspect({
    required String replicaDirectory,
    required String leaseDir,
    required String intentPath,
  }) {
    try {
      final directoryType =
          FileSystemEntity.typeSync(replicaDirectory, followLinks: false);
      if (directoryType == FileSystemEntityType.link) {
        return _deny(false, 'unexpected_link');
      }
      if (directoryType != FileSystemEntityType.directory) {
        // `notFound` here may be a failed lookup: never proof of absence.
        return _deny(false, 'replica_directory_unknown');
      }
      if (p.dirname(leaseDir) != replicaDirectory ||
          p.dirname(intentPath) != replicaDirectory) {
        return _deny(false, 'unexpected_layout');
      }
      // A SUCCESSFUL listing of the parent is the absence proof. A failure
      // throws (permission, vanished directory, I/O) and denies below.
      final names = {
        for (final entry
            in Directory(replicaDirectory).listSync(followLinks: false))
          p.basename(entry.path),
      };
      if (names.contains(p.basename(intentPath))) {
        return _deny(false, 'maintenance_intent');
      }
      if (!names.contains(p.basename(leaseDir))) {
        return _deny(true, 'no_lease_directory');
      }
      final type = FileSystemEntity.typeSync(leaseDir, followLinks: false);
      if (type == FileSystemEntityType.link) {
        return _deny(false, 'unexpected_link');
      }
      if (type != FileSystemEntityType.directory) {
        return _deny(false, 'lease_directory_unknown');
      }
      if (Directory(leaseDir).listSync(followLinks: false).isNotEmpty) {
        return _deny(false, 'lease_present');
      }
      return _deny(true, 'no_leases');
    } catch (_) {
      return _deny(false, 'evidence_unreadable');
    }
  }

  /// Test seams: explicit evidence outcomes.
  static const clear = LegacyHolderEvidence._(true, 'test_clear');
  static const unknown = LegacyHolderEvidence._(false, 'test_unknown');
}

/// Sole ownership of the atomic quiescing transition for an offline local-read
/// restoration (B2). It is the ONLY way to obtain a local-read candidate
/// reservation, and only in this order: [awaitDrained] (every pending open and
/// physical handle, including secondaries registered by other isolates, ACTUALLY
/// closed and acknowledged), [verifyLegacyHolders] (non-creating evidence), then
/// [reserveLocalReadCandidate]. The fence is retained until [release], which the
/// owner calls after open, decrypted verification and publication (or failure).
class DatabaseLocalReadExclusion {
  DatabaseLocalReadExclusion._(this._broker, this.generation);
  final DatabaseAccessBroker _broker;
  final int generation;
  bool _drained = false;
  bool _evidenceVerified = false;
  bool _released = false;
  bool _published = false;
  bool _candidateReserved = false;

  DatabaseAccessBroker get broker => _broker;
  bool get isOwned =>
      !_released &&
      identical(_broker._exclusion, this) &&
      generation == _broker._generation;
  bool get isVerified => isOwned && _drained && _evidenceVerified;

  /// A candidate stays valid while the fence is owned and after a successful
  /// publication; a failed/abandoned transition makes it stale.
  bool get _reservationValid => _released ? _published : isOwned;

  /// Completes only when no pending open or physical handle remains. A timeout
  /// (dead/unresponsive holder, failed close) keeps every uncertain holder and
  /// the quiescing mode, grants nothing and throws.
  Future<void> awaitDrained(
      {Duration timeout = const Duration(seconds: 5)}) async {
    if (!isOwned) throw const DatabaseAccessUnavailable('exclusion_lost');
    if (_broker._physicalHolders != 0) {
      final drain = _broker._drain = Completer<void>();
      try {
        await drain.future.timeout(timeout);
      } on TimeoutException {
        throw const DatabaseAccessUnavailable('cleanup_incomplete');
      }
    }
    if (!isOwned || _broker._physicalHolders != 0) {
      throw const DatabaseAccessUnavailable('exclusion_lost');
    }
    _drained = true;
  }

  /// Missing or unknown evidence denies.
  void verifyLegacyHolders(LegacyHolderEvidence evidence) {
    if (!isOwned || !_drained) {
      throw const DatabaseAccessUnavailable('exclusion_not_drained');
    }
    if (!evidence.isClear) {
      throw DatabaseAccessUnavailable('legacy_holder:${evidence.reason}');
    }
    _evidenceVerified = true;
  }

  /// The local-read candidate reservation: only under verified exclusion, once.
  DatabaseOpenReservation reserveLocalReadCandidate({
    required String uid,
    bool Function()? stillValid,
  }) {
    if (!isVerified) {
      throw const DatabaseAccessUnavailable('exclusion_not_verified');
    }
    if (_candidateReserved) {
      throw const DatabaseAccessUnavailable('candidate_already_reserved');
    }
    _candidateReserved = true;
    return _broker._reserve(DatabaseOpenReservation._(
        _broker,
        DatabaseReservationKind.localReadCandidate,
        uid,
        null,
        0,
        _broker.processNonce,
        generation,
        stillValid,
        exclusion: this));
  }

  /// Ends the transition. [published] true: the read scope was published and the
  /// coordinator is in local-read mode. Otherwise it returns to closed only when
  /// the ledger is empty, else stays quiescing.
  void release({required bool published}) {
    if (_released) return;
    _published = published;
    _released = true;
    _broker._endExclusion(this, published: published);
  }
}
