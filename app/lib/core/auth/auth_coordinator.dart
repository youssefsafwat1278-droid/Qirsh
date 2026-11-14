import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../privacy/cloud_egress_gate.dart';
import '../privacy/consent_authority.dart';
import 'auth_diagnostics.dart';
import 'refresh_transport.dart';
import 'session_record.dart';
import 'session_store.dart';

/// ASR design v7.2 §4 — the AuthCoordinator.
///
/// The single refresher (I3) and the only writer of the session store (I4).
/// Every SDK session mutation the app causes and every store write runs inside
/// its [AuthMutationSection] (I5). SDK auth events never write, remove or admit;
/// the coordinator only tags them (§4.5) so AppSession can tell its own
/// mutations from unattributed ones.

// ─────────────────────────────────────────────────────────────── SDK port

/// The SDK surface the coordinator drives. [GoTrueAuthPort] wraps the real
/// client; tests substitute their own.
abstract class SdkAuthPort {
  Session? get currentSession;

  /// The SDK's synchronous auth-state stream (`onAuthStateChangeSync`): the same
  /// [AuthState] objects AppSession later receives on the async stream.
  Stream<AuthState> get syncEvents;

  /// `auth.recoverSession(canonical)` — silent for a fresh same-owner session.
  Future<void> recoverSession(String canonical);

  /// `auth.signOut(scope: local)`; the coordinator runs it in the gate's
  /// alignment zone so its server call is denied before admission (§4.8).
  Future<void> signOutLocal();
}

class GoTrueAuthPort implements SdkAuthPort {
  GoTrueAuthPort(this.auth);
  final GoTrueClient auth;

  @override
  Session? get currentSession => auth.currentSession;

  @override
  // ignore: invalid_use_of_internal_member
  Stream<AuthState> get syncEvents => auth.onAuthStateChangeSync;

  @override
  Future<void> recoverSession(String canonical) async {
    await auth.recoverSession(canonical);
  }

  @override
  Future<void> signOutLocal() => auth.signOut(scope: SignOutScope.local);
}

// ─────────────────────────────────────────────────────────────── tags (§4.5)

enum AuthTagKind { explicit, install, alignment, init, unattributed }

@immutable
class AuthTag {
  const AuthTag(this.kind, [this.id]);
  final AuthTagKind kind;

  /// The attempt or op id (diagnostic; never a user id).
  final Object? id;

  bool get isCoordinator => kind != AuthTagKind.unattributed;

  @override
  String toString() => 'AuthTag(${kind.name})';
}

// ─────────────────────────────────────────────────────────────── section (§4.6)

/// The coordinator's async mutex. FIFO; not re-entrant.
class AuthMutationSection {
  Future<void> _tail = Future<void>.value();
  int _depth = 0;

  /// True while a holder runs or a waiter is queued.
  bool get busy => _depth > 0;

  Future<T> run<T>(Future<T> Function() body) {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    _depth++;
    return prev.then((_) => body()).whenComplete(() {
      _depth--;
      done.complete();
    });
  }
}

// ─────────────────────────────────────────────────────────────── refresh ops

/// How one refresh op ended (§4.3, §10.3).
enum RefreshOutcomeKind {
  /// `RefreshCommitted`: a new session is durable ([RefreshOutcome.receipt]).
  committed,

  /// `RefreshDead`: a definitive 4xx; owner and data are kept.
  dead,

  /// No credential byte was sent (`reserved` → `retryable`, or `markedNotSent`).
  notSent,

  /// The request may have been sent; the record stays `dispatchMarked`.
  possiblySent,

  /// The token's dispatch budget (3) is used up: local read + sign-in.
  exhausted,

  /// Refused before anything was written or connected.
  denied,

  /// The predecessor is no longer committed; the result was discarded.
  stale,
}

@immutable
class RefreshReceipt {
  const RefreshReceipt({
    required this.opId,
    required this.lifecycle,
    required this.seq,
    required this.digest,
    required this.predecessorDigest,
    required this.sdkBaseline,
    required this.owner,
    required this.intentSeq,
  });
  final String opId;
  final int lifecycle;
  final int seq;
  final String digest;
  final String predecessorDigest;
  final String sdkBaseline;
  final String owner;

  /// The intent position the op started at: a later removal intent
  /// supersedes every step bound to this receipt.
  final int intentSeq;
}

/// The result of [AuthCoordinator.installForAsr]: the hold and exclusion are
/// set; [installed] says whether SDK memory now holds the receipt's session.
/// Phase 4c B2: the durable state of an adoption write whose outcome was not
/// acknowledged — [unresolved] when the record cannot be read back, which is
/// never treated as either answer.
enum AdoptionCheck { confirmed, notInState, unresolved }

class AsrInstall {
  AsrInstall(this.hold, {required this.installed});
  final TransitionHoldToken hold;
  final bool installed;
}

@immutable
class RefreshOutcome {
  const RefreshOutcome(this.kind,
      {this.reason,
      this.receipt,
      this.installed = false,
      this.noInstall = false});
  final RefreshOutcomeKind kind;

  /// Diagnostic only.
  final String? reason;
  final RefreshReceipt? receipt;

  /// The committed session was installed into SDK memory.
  final bool installed;

  /// A POLICY cause after send: custody only, never installation (§5).
  final bool noInstall;

  @override
  String toString() =>
      'RefreshOutcome(${kind.name}${reason == null ? '' : ', $reason'})';
}

/// The per-kind hooks of one op (§4.10). Every hook is optional.
class RefreshOpSpec {
  const RefreshOpSpec({
    required this.kind,
    required this.deadline,
    this.preAdmit,
    this.admitPredicate,
    this.preSend,
    this.sendPredicate,
    this.ordinaryAdmissionHeld,
    this.installPredicate,
    this.acceptPredicate,
    this.install = true,
  });

  final RefreshOpKind kind;
  final Duration deadline;

  /// Awaited before P_admit / P_send (e.g. `confirmRecoveryEvidence`).
  final Future<bool> Function()? preAdmit;
  final Future<bool> Function()? preSend;

  /// Synchronous, inside the gate lock / immediately before `add`.
  final bool Function()? admitPredicate;
  final bool Function()? sendPredicate;

  /// accountControl (V3): whether the process holds a current ordinary
  /// admission for the owner (authenticated normal mode). Asked at P_admit and
  /// synchronously at commit; only then the existing disposition is kept.
  final bool Function()? ordinaryAdmissionHeld;

  /// Awaited, then rechecked synchronously right before installation.
  final Future<bool> Function()? installPredicate;

  /// ASR P_accept (decision (a)): synchronous; false discards the response
  /// (e.g. the op lost the foreground, even if the app already resumed).
  final bool Function()? acceptPredicate;

  /// False for ASR: installation is the orchestrator's (§9.6).
  final bool install;
}

class _Op {
  _Op(this.id, this.spec, this.intentSeq, this.startPosition, this.sdkBaseline);
  final String id;
  final RefreshOpSpec spec;
  final int intentSeq;
  final int startPosition;
  final String sdkBaseline;
  late String owner;
  late int lifecycle;
  late int expectedSeq;
  late String refreshToken;
  late String tokenDigest;
  late String predecessorDigest;
  bool heldOrdinary = false;
  late Duration startedMono;
  late DateTime startedWall;
  EgressTicket? ticket;
  RefreshChannel? channel;
  bool cancelled = false;
  String? cancelReason;

  /// Diagnostic only (Beta 1): phase times (monotonic) and response facts,
  /// all constants or numbers — never a token or identifier.
  Duration? openedAt, markedAt, sentAt, answeredAt;
  int? status;
  String? invalid;

  void cancel(String reason) {
    if (cancelled) return;
    cancelled = true;
    cancelReason = reason;
    channel?.cancel();
  }
}

/// Definitive refresh failures (§4.3): the token can never be used again.
const Set<String> kDefinitiveRefreshErrors = {
  'invalid_grant',
  'refresh_token_not_found',
  'refresh_token_already_used',
  'session_not_found',
  'session_expired',
  'user_not_found',
  'user_banned',
};

/// Errors of the explicit-exchange bracket.
class ExplicitRefused implements Exception {
  const ExplicitRefused(this.reason);
  final String reason;
  @override
  String toString() => 'ExplicitRefused($reason)';
}

// ─────────────────────────────────────────────────────────────── attempt zone

/// §4.4: the explicit attempt an interactive sign-in belongs to travels in the
/// zone from the UI (`AuthAttemptZone.run`) to the account-control exchange.
class AuthAttemptZone {
  static const Symbol _key = #qirshAuthAttempt;

  static Future<T> run<T>(int intent, Future<T> Function() body) =>
      runZoned(body, zoneValues: {_key: intent});

  static int? get current => Zone.current[_key] as int?;
}

// ─────────────────────────────────────────────────────────────── coordinator

class AuthCoordinator {
  /// The process coordinator, set by bootstrap once the session store is loaded
  /// (null in tests and builds without Supabase: the legacy SDK paths apply).
  static AuthCoordinator? active;

  /// §4.9: every logout caller. With a coordinator the removal commits durably
  /// and aligns memory first; the server revocation (what `auth.signOut()`
  /// sends today) is then a separate request under ordinary egress policy.
  static Future<void> logout(GoTrueClient auth) async {
    final coord = active;
    if (coord == null) {
      await auth.signOut();
      return;
    }
    final token = auth.currentSession?.accessToken;
    await coord.removal();
    if (token == null) return;
    try {
      await auth.admin.signOut(token);
    } catch (_) {
      // The local removal is authoritative; revocation is best effort.
    }
  }

  AuthCoordinator({
    required this.store,
    required this.gate,
    required this.channelFactory,
    DateTime Function()? wallClock,
    Duration Function()? monotonic,
    Random? random,
    this.transportQuiesceBound = const Duration(seconds: 15),
    this.transportAbandonAfter = const Duration(seconds: 60),
  })  : _wall = wallClock ?? DateTime.now,
        _mono = monotonic ?? _processClock,
        _random = random ?? Random.secure();

  static final Stopwatch _stopwatch = Stopwatch()..start();
  static Duration _processClock() => _stopwatch.elapsed;

  final SessionStore store;
  final CloudEgressGate gate;

  /// One fresh channel per op (the op-owned transport, §10).
  final RefreshChannel Function() channelFactory;
  final DateTime Function() _wall;
  final Duration Function() _mono;
  final Random _random;

  /// L4: how long [runRefresh] waits for an op's transport closure to be
  /// confirmed before treating it as unconfirmed (B8 latch, terminal denial)
  /// and releasing the ticket anyway — a closing future that never completes
  /// must not hold the op (and every later sign-in) forever.
  final Duration transportQuiesceBound;

  /// L4: how long the B8 transport latch refuses exchanges (monotonic). After
  /// it the unconfirmed descriptor is abandoned: explicit sign-in (and routine
  /// refresh) may run again. A confirmed explicit commit clears it sooner.
  final Duration transportAbandonAfter;

  final AuthMutationSection section = AuthMutationSection();

  SdkAuthPort? _sdk;
  StreamSubscription<AuthState>? _events;

  /// Called when an untagged/unattributed session-bearing event was observed
  /// after attachment (§4.7 → restrictive alignment by AppSession).
  void Function(AuthState state)? onUnattributedMutation;

  /// Called after a routine/accountControl installation (replaces the SDK's
  /// former `tokenRefreshed`, §4.7).
  void Function(RefreshReceipt receipt)? onCredentialRotated;

  /// Called after `RefreshDead` (AppSession's expired/invalid path, §4.3).
  void Function()? onCredentialDead;

  String _newId() {
    final b = List<int>.generate(12, (_) => _random.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  // ── identity model (§4.1) ─────────────────────────────────────────────────

  int _intentSeq = 0;
  int _removalIntentSeq = 0;
  int get intentSeq => _intentSeq;

  /// Synchronous: an explicit attempt starts (AppSession.beginAuthAttempt).
  int registerAttemptIntent() => ++_intentSeq;

  /// Synchronous removal intent (§6.4-1): supersedes every op that started
  /// before it and cancels every refresh ticket (IDENTITY cause).
  int beginRemovalIntent() {
    _removalIntentSeq = ++_intentSeq;
    gate.noteCause(EpochCause.removal);
    _activeOp?.cancel('removal');
    return _removalIntentSeq;
  }

  bool removalSince(int intentSeq) => _removalIntentSeq > intentSeq;

  // ── exclusions (§4.6) ────────────────────────────────────────────────────

  int? _explicitExclusion;
  String? _asrExclusion;
  int? get explicitExclusion => _explicitExclusion;
  String? get asrExclusion => _asrExclusion;

  /// ASR (§9.6): set synchronously in the same block as the install check.
  void setAsrExclusion(String opId) => _asrExclusion = opId;

  /// Released only by the ASR orchestrator once one of the §4.6 outcomes is
  /// established.
  void releaseAsrExclusion(String opId) {
    if (_asrExclusion == opId) _asrExclusion = null;
  }

  // ── SDK baseline (§9.6) ──────────────────────────────────────────────────

  String _sdkBaseline = emptyDigest;

  /// Digest of what SDK memory holds by coordinator authority.
  String get sdkBaseline => _sdkBaseline;

  /// §9.6 lineage (B10): the digests this process committed by a coordinator
  /// `RefreshCommitted` since the current baseline was set. A committed record
  /// in it descends from the baseline through coordinator refreshes only.
  final Set<String> _lineage = {};

  void _setBaseline(String digest) {
    _sdkBaseline = digest;
    _lineage.clear();
  }

  bool _unattributed = false;

  /// An unattributed SDK session mutation was observed this process (§4.5).
  bool get unattributedMutation => _unattributed;

  String get sdkDigest => sessionDigest(_sdk?.currentSession);

  // ── load / attach / tags ─────────────────────────────────────────────────

  LoadResult? _load;
  LoadResult? get loadResult => _load;

  /// §6.8: loads the store. The record [LoadResult.served] is what the one-shot
  /// SDK storage serves; the baseline is set when the SDK reports it installed.
  Future<LoadResult> load() async => _load = await store.load();

  final Expando<AuthTag> _tags = Expando<AuthTag>('authTag');
  AuthTag? _activeMutation;
  final Map<int, String> _explicitDigests = {};

  /// The tag the coordinator gave [state] at its synchronous delivery, or null
  /// (untagged: delivered before attachment).
  AuthTag? tagOf(AuthState state) => _tags[state];

  /// Subscribes to the SDK's synchronous stream. Call before the SDK can emit
  /// (bootstrap attaches from the one-shot storage's first read, §3.2).
  void attach(SdkAuthPort sdk) {
    if (identical(_sdk, sdk)) return;
    _events?.cancel();
    _sdk = sdk;
    var listening = true;
    _events = sdk.syncEvents.listen((state) {
      // A replay delivered while subscribing was not seen synchronously.
      if (listening) return;
      _onSync(state);
    }, onError: (Object _) {});
    listening = false;
  }

  /// Bootstrap brackets `Supabase.initialize` with these so the init event is
  /// tagged `init` (§4.7).
  void beginInit() => _activeMutation = const AuthTag(AuthTagKind.init);

  /// Ends the init bracket. [served] is the record the one-shot storage handed
  /// to `setInitialSession` (null when nothing was served).
  void endInit({SessionRecord? served}) {
    if (_activeMutation?.kind == AuthTagKind.init) _activeMutation = null;
    _setBaseline(served == null ? emptyDigest : served.digest);
  }

  void _onSync(AuthState state) {
    if (_tags[state] != null) return; // replay: keeps its original tag
    final active = _activeMutation;
    final tag = active ?? const AuthTag(AuthTagKind.unattributed);
    _tags[state] = tag;
    if (tag.kind == AuthTagKind.explicit && state.session != null) {
      _explicitDigests[tag.id! as int] = sessionDigest(state.session);
    }
    if (tag.kind == AuthTagKind.unattributed &&
        (state.session != null || state.event == AuthChangeEvent.signedOut)) {
      _unattributed = true;
      onUnattributedMutation?.call(state);
    }
  }

  Future<T> _mutate<T>(AuthTag tag, Future<T> Function() body) async {
    final previous = _activeMutation;
    _activeMutation = tag;
    try {
      return await body();
    } finally {
      _activeMutation = previous;
    }
  }

  // ── automatic admission (§4.7) ───────────────────────────────────────────

  /// Why no automatic route may admit the current SDK session, or null.
  /// Evaluate synchronously at the admission decision and after every await.
  String? automaticAdmissionDenial() {
    if (_explicitExclusion != null) return 'explicit_exclusion';
    if (_asrExclusion != null) return 'asr_exclusion';
    if (store.indeterminate) return 'indeterminate';
    if (_unattributed) return 'unattributed';
    final c = store.committed;
    if (c == null || c.isTombstone) return 'no_record';
    if (c.credential != CredentialState.live) return 'dead';
    if (c.admission != AdmissionDisposition.ordinary) {
      return 'requires_adoption';
    }
    final a = c.adoption?.state;
    if (a == AdoptionState.pending || a == AdoptionState.failed) {
      return 'barred';
    }
    if (_barred(c)) return 'barred';
    if (sdkDigest != c.digest) {
      // B10: a routine successor kept in custody (§4.10) is not an SDK
      // mutation: SDK memory still holds the coordinator baseline and the
      // record descends from it through coordinator refreshes only. The
      // routine continuation installs it; no route admits until then.
      return sdkDigest == _sdkBaseline && _lineage.contains(c.digest)
          ? custodySuccessor
          : 'sdk_mismatch';
    }
    return null;
  }

  /// [automaticAdmissionDenial] for a committed routine successor in custody.
  static const String custodySuccessor = 'custody_successor';

  /// Routine admission: none of [automaticAdmissionDenial]'s denials except a
  /// custody successor, which the routine op continues (B10).
  bool _routineAdmissible() {
    final d = automaticAdmissionDenial();
    return d == null || d == custodySuccessor;
  }

  /// §9.7: the §4.7 predicate for the adoption of the ASR op that holds the
  /// exclusion. Its own exclusion and its own `pending`/`finalizing` record are
  /// the only exemptions; everything else is as strict as
  /// [automaticAdmissionDenial].
  String? asrAdoptionDenial(RefreshReceipt receipt) {
    if (_explicitExclusion != null) return 'explicit_exclusion';
    if (_asrExclusion != receipt.opId) return 'asr_exclusion';
    if (store.indeterminate) return 'indeterminate';
    if (_unattributed) return 'unattributed';
    if (removalSince(receipt.intentSeq)) return 'removal';
    final c = store.committed;
    if (c == null || c.isTombstone || c.owner != receipt.owner) {
      return 'no_record';
    }
    if (c.credential != CredentialState.live) return 'dead';
    if (c.lifecycle != receipt.lifecycle || c.digest != receipt.digest) {
      return 'stale';
    }
    final a = c.adoption;
    final own = a != null &&
        a.opId == receipt.opId &&
        ((a.state == AdoptionState.pending &&
                c.admission == AdmissionDisposition.requiresAdoption) ||
            (a.state == AdoptionState.finalizing &&
                c.admission == AdmissionDisposition.ordinary));
    if (!own || _barred(c)) return 'barred';
    if (sdkDigest != c.digest) return 'sdk_mismatch';
    return null;
  }

  // ── explicit attempts (§4.4, §4.6) ───────────────────────────────────────

  /// Runs the explicit provider exchange [sdkCall] (e.g. `signInWithIdToken`)
  /// inside the section with the exclusion set. A refused exchange is aligned
  /// before the exclusion is released; a successful one keeps the exclusion
  /// until [commitExplicit] or [abandonExplicit].
  ///
  /// Phase 4c B8: refused while a previous op's transport closure is
  /// unconfirmed and not yet abandoned ([transportLatched]) — checked on entry
  /// and again immediately before [sdkCall] runs, so no authentication
  /// exchange starts beside a recently unconfirmed descriptor.
  Future<T> explicitExchange<T>(int attemptId, Future<T> Function() sdkCall) {
    if (removalSince(attemptId)) {
      return Future.error(const ExplicitRefused('removal'));
    }
    if (_latched) {
      return Future.error(const ExplicitRefused('transport_unconfirmed'));
    }
    _explicitExclusion = attemptId;
    return section.run(() async {
      try {
        if (_latched) {
          throw const ExplicitRefused('transport_unconfirmed');
        }
        return await _mutate(AuthTag(AuthTagKind.explicit, attemptId), sdkCall);
      } catch (_) {
        await _alignLocked(AuthTag(AuthTagKind.alignment, attemptId));
        if (_explicitExclusion == attemptId) _explicitExclusion = null;
        _explicitDigests.remove(attemptId);
        rethrow;
      }
    });
  }

  /// `ExplicitCommit` (§4.2): lifecycle `L+1`, `admission: ordinary`, clears
  /// refresh-op state, adoption and the automatic-admission bar. Returns the
  /// committed record, or null when refused (memory is then aligned).
  Future<SessionRecord?> commitExplicit(int attemptId,
      {required bool Function() attemptCurrent}) {
    return section.run(() async {
      SessionRecord? result;
      try {
        result = await _commitExplicitLocked(attemptId, attemptCurrent);
      } finally {
        if (result == null) {
          await _alignLocked(AuthTag(AuthTagKind.alignment, attemptId));
        }
        if (_explicitExclusion == attemptId) _explicitExclusion = null;
        _explicitDigests.remove(attemptId);
      }
      return result;
    });
  }

  Future<SessionRecord?> _commitExplicitLocked(
      int attemptId, bool Function() attemptCurrent) async {
    if (removalSince(attemptId) || !attemptCurrent()) return null;
    if (store.indeterminate && !await store.resolve()) return null;
    final session = _sdk?.currentSession;
    final tagged = _explicitDigests[attemptId];
    if (session == null || tagged == null || sessionDigest(session) != tagged) {
      return null;
    }
    final String canonical;
    try {
      canonical = canonicalSession(session.toJson());
    } on FormatException {
      return null;
    }
    final next = SessionRecord(
      ns: store.ns,
      installId: store.installId!,
      seq: store.nextSeqFloor + 1,
      lifecycle: store.lifecycleFloor + 1,
      kind: RecordKind.session,
      owner: session.user.id,
      session: canonical,
      admission: AdmissionDisposition.ordinary,
    );
    if (removalSince(attemptId) || !attemptCurrent()) return null;
    final w = await store.write(next);
    if (w != WriteOutcome.committed) return null;
    _setBaseline(next.digest);
    _unattributed = false;
    // §11.4: only a confirmed, still-current explicit commit ends an ASR
    // terminal denial.
    if (!removalSince(attemptId) && attemptCurrent()) {
      gate.clearTerminalDenial();
      // L4: a confirmed sign-in also ends the B8 transport latch, so routine
      // refresh resumes without waiting for [transportAbandonAfter].
      _transportUnconfirmed = false;
      _unconfirmedAt = null;
    }
    return next;
  }

  /// The attempt ended without a commit (stale, cancelled): align memory and
  /// release the exclusion.
  Future<void> abandonExplicit(int attemptId) async {
    if (_explicitExclusion != attemptId &&
        !_explicitDigests.containsKey(attemptId)) {
      return;
    }
    return section.run(() async {
      try {
        await _alignLocked(AuthTag(AuthTagKind.alignment, attemptId));
      } finally {
        if (_explicitExclusion == attemptId) _explicitExclusion = null;
        _explicitDigests.remove(attemptId);
      }
    });
  }

  /// An authenticated, same-owner identity edit. Unlike sign-in this cannot
  /// create an admission, replace the owner, or clear refresh attempt limits.
  Future<T> updateLinkedIdentity<T>({required String owner,
      required bool Function() current, required Future<T> Function() exchange}) {
    final intent = _intentSeq;
    return section.run(() async {
      final before = store.committed;
      bool live() => current() && _intentSeq == intent && !removalSince(intent);
      if (!live() || _transportUnconfirmed || _activeOp != null ||
          automaticAdmissionDenial() != null || before?.owner != owner ||
          before?.refreshOp != null || ordinaryAdmissionHeld?.call() != true) {
        throw const ExplicitRefused('identity_not_current');
      }
      try {
        final result = await _mutate(const AuthTag(AuthTagKind.install), exchange);
        final session = _sdk?.currentSession;
        if (!live() || session == null || session.isExpired || session.user.id != owner) {
          throw const ExplicitRefused('identity_owner_changed');
        }
        final next = before!.copyWith(seq: before.seq + 1,
            session: canonicalSession(session.toJson()));
        if (await store.write(next) != WriteOutcome.committed) {
          throw const ExplicitRefused('identity_persistence');
        }
        if (!live()) throw const ExplicitRefused('identity_superseded');
        _setBaseline(next.digest);
        return result;
      } catch (_) {
        await _alignLocked(const AuthTag(AuthTagKind.alignment));
        rethrow;
      }
    });
  }

  // ── removal (§4.9, §6.4) ─────────────────────────────────────────────────

  /// Logout, Remove data, immediate deletion, account switch. The intent is
  /// synchronous; the commit is ordered after the current section holder.
  /// Returns true when the removal is durable. Memory is aligned either way.
  Future<bool> removal() {
    final intent = beginRemovalIntent();
    return section.run(() async {
      var durable = false;
      try {
        durable = await store.remove();
      } finally {
        await _alignLocked(AuthTag(AuthTagKind.alignment, 'removal:$intent'));
      }
      return durable;
    });
  }

  // ── memory-only alignment (§4.8) ─────────────────────────────────────────

  /// Aligns SDK memory with the committed record (no server call ever).
  Future<bool> align() =>
      section.run(() => _alignLocked(AuthTag(AuthTagKind.alignment, _newId())));

  Future<bool> _alignLocked(AuthTag tag) async {
    final sdk = _sdk;
    if (sdk == null) return true;
    final c = store.committed;
    final fresh = c != null &&
        !store.indeterminate &&
        c.credential == CredentialState.live &&
        c.admission == AdmissionDisposition.ordinary &&
        c.adoption?.state != AdoptionState.pending &&
        c.adoption?.state != AdoptionState.failed &&
        !_barred(c) &&
        _remaining(c) > const Duration(seconds: 60);
    if (fresh && sdkDigest == c.digest) {
      _setBaseline(c.digest);
      return true;
    }
    // Memory of another owner, or nothing to recover: clear it first.
    final current = sdk.currentSession;
    if (current != null && (!fresh || current.user.id != c.owner)) {
      try {
        await _mutate(tag, () => gate.runAlignment(sdk.signOutLocal));
      } catch (_) {
        // admin.signOut is denied in the zone by design; memory was cleared
        // before its first await (gotrue_client.dart:943-944).
      }
      if (sdk.currentSession != null) return false;
    }
    if (fresh) {
      try {
        await _mutate(tag, () => sdk.recoverSession(c.session!));
      } catch (_) {}
      if (sdkDigest == c.digest) {
        _setBaseline(c.digest);
        return true;
      }
      if (sdk.currentSession != null) {
        try {
          await _mutate(tag, () => gate.runAlignment(sdk.signOutLocal));
        } catch (_) {}
      }
    }
    final cleared = sdk.currentSession == null;
    if (cleared) _setBaseline(emptyDigest);
    return cleared && !fresh;
  }

  Duration _remaining(SessionRecord c) {
    final exp = c.sdkSession?.expiresAt;
    if (exp == null) return Duration.zero;
    return DateTime.fromMillisecondsSinceEpoch(exp * 1000).difference(_wall());
  }

  // ── refresh engine (§10.3) ───────────────────────────────────────────────

  _Op? _activeOp;
  final List<Completer<void>> _idleWaiters = [];

  /// True while a refresh op holds a reservation, ticket or transport.
  bool get refreshing => _activeOp != null;

  /// Completes when no op holds a reservation, ticket or transport resource
  /// and the section is free (§10.4 quiescence, §11.3).
  Future<void> quiesced() async {
    while (_activeOp != null || section.busy) {
      if (_activeOp != null) {
        final c = Completer<void>();
        _idleWaiters.add(c);
        await c.future;
      } else {
        await section.run(() async {});
      }
    }
  }

  /// §11.3 explicit handover: [quiesced], then — Phase 4c B8 — a prompt
  /// refusal while an op's transport closure is unconfirmed and not yet
  /// abandoned ([transportLatched]): quiescence beside such a descriptor is no
  /// handover.
  Future<void> handoverQuiesced() async {
    await quiesced();
    if (_latched) {
      throw const ExplicitRefused('transport_unconfirmed');
    }
  }

  /// Cancels the running op (deadline, background, explicit intent).
  void cancelActive(String reason) => _activeOp?.cancel(reason);

  /// Phase 4c B8: set when an op's transport closure could not be confirmed
  /// (closure failed, or not confirmed within [transportQuiesceBound]). While
  /// latched ([_latched]) no replacement exchange — refresh, explicit sign-in
  /// or handover — runs beside the descriptor. L4: the latch is not for the
  /// process lifetime; it lapses [transportAbandonAfter] (monotonic) after it
  /// was set, and a confirmed explicit commit clears it, so a stuck closure
  /// can never bar sign-in until the app is force-quit.
  bool _transportUnconfirmed = false;
  Duration? _unconfirmedAt;

  bool get _latched =>
      _transportUnconfirmed &&
      _mono() - _unconfirmedAt! < transportAbandonAfter;

  /// Whether a previous op's transport closure was unconfirmed and no
  /// confirmed explicit commit has since cleared it (the gate's terminal
  /// denial set with it also stands until such a commit).
  bool get transportUnconfirmed => _transportUnconfirmed;

  /// Whether exchanges are currently refused for an unconfirmed closure
  /// ([transportUnconfirmed] and [transportAbandonAfter] not yet elapsed).
  bool get transportLatched => _latched;

  /// Runs one refresh op of [spec.kind] for the committed owner.
  Future<RefreshOutcome> runRefresh(RefreshOpSpec spec) async {
    if (_activeOp != null) {
      return const RefreshOutcome(RefreshOutcomeKind.denied, reason: 'busy');
    }
    if (_latched) {
      return const RefreshOutcome(RefreshOutcomeKind.denied,
          reason: 'transport_unconfirmed');
    }
    final op =
        _Op(_newId(), spec, _intentSeq, gate.causePosition, _sdkBaseline);
    _activeOp = op;
    final started = _mono();
    op
      ..startedMono = started
      ..startedWall = _wall();
    final deadline = Timer(spec.deadline, () => op.cancel('deadline'));
    try {
      final out = await _drive(op, started);
      _diagnose(op, out);
      return out;
    } finally {
      deadline.cancel();
      final ch = op.channel;
      if (ch != null) {
        ch.cancel();
        try {
          // L4: bounded — a closing future that never completes must not hold
          // the op (ticket, _activeOp) forever. _drive has returned, so the
          // channel's response is no longer awaited by anything: a late reply
          // can never be validated, committed or installed.
          await ch.quiesced().timeout(transportQuiesceBound);
        } catch (_) {
          // §10.4: closure not confirmed (failed or timed out) — no quiescence
          // to rely on, so this process fails closed before the ticket is
          // released, and the transport latch bars later exchanges (B8) until
          // it is abandoned or an explicit commit clears it.
          _transportUnconfirmed = true;
          _unconfirmedAt = _mono();
          gate.terminalDeny();
        }
      }
      final t = op.ticket;
      if (t != null) gate.release(t);
      _activeOp = null;
      for (final w in _idleWaiters) {
        if (!w.isCompleted) w.complete();
      }
      _idleWaiters.clear();
    }
  }

  RefreshOutcome _out(RefreshOutcomeKind k, String reason) =>
      RefreshOutcome(k, reason: reason);

  /// Diagnostic only (Beta 1): one constant summary per op for
  /// [AuthDiagnostics]: kind, outcome and reason, the phase times in ms since
  /// the op started (-: not reached), the HTTP status and a failed validation
  /// check. Never a token, digest or identifier.
  void _diagnose(_Op op, RefreshOutcome out) {
    String at(Duration? d) =>
        d == null ? '-' : '${(d - op.startedMono).inMilliseconds}';
    try {
      AuthDiagnostics.add('${op.spec.kind.name} '
          '${out.kind.name}:${out.reason ?? '-'} '
          'open=${at(op.openedAt)} mark=${at(op.markedAt)} '
          'send=${at(op.sentAt)} reply=${at(op.answeredAt)} '
          'end=${at(_mono())} http=${op.status ?? '-'}'
          '${op.invalid == null ? '' : ' invalid=${op.invalid}'}');
    } catch (_) {}
  }

  bool _ownsRecord(_Op op, RefreshOpState state) {
    final c = store.committed;
    return !store.indeterminate &&
        c != null &&
        c.lifecycle == op.lifecycle &&
        c.seq == op.expectedSeq &&
        c.refreshOp?.opId == op.id &&
        c.refreshOp?.state == state;
  }

  /// ASR decision (a): the deadline holds on both clocks. A suspended process
  /// does not advance the monotonic clock (nor fire the timer), so the wall
  /// clock is rechecked too; a wall clock that went backwards also expires.
  bool _asrExpired(_Op op) {
    if (op.spec.kind != RefreshOpKind.asr) return false;
    final wall = _wall().difference(op.startedWall);
    return _mono() - op.startedMono >= op.spec.deadline ||
        wall.isNegative ||
        wall >= op.spec.deadline;
  }

  bool _opLive(_Op op) =>
      !op.cancelled &&
      !_asrExpired(op) &&
      !removalSince(op.intentSeq) &&
      !(op.ticket?.isCancelled ?? false) &&
      (op.spec.kind == RefreshOpKind.accountControl ||
          _explicitExclusion == null) &&
      (op.spec.kind == RefreshOpKind.asr || _asrExclusion == null);

  Future<RefreshOutcome> _drive(_Op op, Duration started) async {
    final spec = op.spec;

    // reserve (§10.3 row 1)
    final reserve = await section.run(() => _reserve(op));
    if (reserve != null) return reserve;

    // P_admit (§9.3)
    if (spec.preAdmit != null && !await spec.preAdmit!()) {
      return _out(RefreshOutcomeKind.notSent, 'pre_admit');
    }
    if (spec.ordinaryAdmissionHeld != null) {
      op.heldOrdinary = spec.ordinaryAdmissionHeld!();
    }
    try {
      op.ticket = await gate.admitRefreshOp(
        kind: spec.kind,
        owner: op.owner,
        startPosition: op.startPosition,
        authority: op,
        predicate: () =>
            _opLive(op) &&
            _ownsRecord(op, RefreshOpState.reserved) &&
            (spec.admitPredicate?.call() ?? true),
      );
    } on EgressDeniedException catch (e) {
      return _out(RefreshOutcomeKind.denied, e.reason);
    }
    unawaited(op.ticket!.cancelled.then((_) => op.cancel('cause')));

    // connect (§10.2): no await between the live check and openUrl.
    if (!_opLive(op)) return _preConnectFailure(op, 'cancelled');
    final ch = op.channel = channelFactory();
    try {
      await ch.open();
      op.openedAt = _mono();
    } catch (_) {
      return _preConnectFailure(op, op.cancelReason ?? 'connect');
    }
    if (!_opLive(op)) {
      return _preConnectFailure(op, op.cancelReason ?? 'cancelled');
    }

    // mark dispatch (§10.3 rows 3/4)
    final mark = await section.run(() => _markDispatch(op));
    if (mark != null) return mark;
    op.markedAt = _mono();

    // P_send (§9.4)
    if (spec.preSend != null && !await spec.preSend!()) {
      return _out(RefreshOutcomeKind.notSent, 'marked_not_sent');
    }
    final Future<RefreshHttpResult> response;
    {
      // One synchronous block up to `add`.
      final deny = !_opLive(op) ||
              !_ownsRecord(op, RefreshOpState.dispatchMarked)
          ? 'cancelled'
          : gate.confirmRefreshSend(op.ticket!) ??
              ((spec.sendPredicate?.call() ?? true) ? null : 'send_predicate');
      if (deny != null) {
        return _out(RefreshOutcomeKind.notSent, 'marked_not_sent:$deny');
      }
      response = ch.send(op.refreshToken);
      op.sentAt = _mono();
    }

    final RefreshHttpResult result;
    try {
      result = await response;
    } catch (_) {
      return _out(
          RefreshOutcomeKind.possiblySent, op.cancelReason ?? 'transport');
    }
    op
      ..answeredAt = _mono()
      ..status = result.statusCode;
    final noInstall = op.ticket!.refresh!.noInstall;

    // validation (§10.6) + acceptance (§9.5)
    final dead = _definitiveFailure(result);
    if (dead) {
      return section.run(() => _commitDead(op));
    }
    final canonical = _validate(op, result);
    if (canonical == null) {
      return _out(RefreshOutcomeKind.possiblySent, 'invalid_response');
    }
    final committed = await section.run(() => _commitRefreshed(op, canonical));
    if (committed.kind != RefreshOutcomeKind.committed) return committed;

    // installation (§4.10)
    if (!spec.install || noInstall || op.ticket!.refresh!.noInstall) {
      return RefreshOutcome(RefreshOutcomeKind.committed,
          receipt: committed.receipt, noInstall: noInstall);
    }
    final installed = await _install(op, committed.receipt!);
    return RefreshOutcome(RefreshOutcomeKind.committed,
        receipt: committed.receipt, installed: installed);
  }

  Future<RefreshOutcome?> _reserve(_Op op) async {
    if (store.indeterminate && !await store.resolve()) {
      return _out(RefreshOutcomeKind.denied, 'indeterminate');
    }
    if (!_opLive(op)) return _out(RefreshOutcomeKind.denied, 'cancelled');
    final c = store.committed;
    if (c == null || c.isTombstone || c.owner == null) {
      return _out(RefreshOutcomeKind.denied, 'no_record');
    }
    if (c.credential != CredentialState.live) {
      return _out(RefreshOutcomeKind.denied, 'dead');
    }
    final a = c.adoption?.state;
    if (a == AdoptionState.pending ||
        a == AdoptionState.failed ||
        _barred(c)) {
      return _out(RefreshOutcomeKind.denied, 'barred');
    }
    if (op.spec.kind == RefreshOpKind.routine &&
        c.admission != AdmissionDisposition.ordinary) {
      return _out(RefreshOutcomeKind.denied, 'requires_adoption');
    }
    if (c.refreshOp?.state == RefreshOpState.exhausted) {
      return _out(RefreshOutcomeKind.exhausted, 'exhausted');
    }
    final token = c.sdkSession?.refreshToken;
    if (token == null || token.isEmpty) {
      return _out(RefreshOutcomeKind.denied, 'no_refresh_token');
    }
    final digest = sha256Hex(token);
    final dispatches = c.tokenDispatches?.digest == digest
        ? c.tokenDispatches!
        : TokenDispatches(digest: digest, count: 0);
    if (dispatches.count >= 3) {
      return _out(RefreshOutcomeKind.exhausted, 'dispatch_budget');
    }
    final next = c.copyWith(
      seq: c.seq + 1,
      refreshOp: () => RefreshOpRecord(
          opId: op.id,
          lifecycle: c.lifecycle,
          tokenDigest: digest,
          state: RefreshOpState.reserved,
          expectedSeq: c.seq + 1),
      tokenDispatches: () => dispatches,
    );
    final w = await store.write(next);
    if (w != WriteOutcome.committed) {
      return _out(RefreshOutcomeKind.denied, 'reserve_${w.name}');
    }
    op
      ..owner = c.owner!
      ..lifecycle = c.lifecycle
      ..expectedSeq = next.seq
      ..refreshToken = token
      ..tokenDigest = digest
      ..predecessorDigest = c.digest;
    return null;
  }

  /// `reserved` → `retryable` (`preConnectFailure`): no credential bytes.
  Future<RefreshOutcome> _preConnectFailure(_Op op, String reason) =>
      section.run(() async {
        if (_ownsRecord(op, RefreshOpState.reserved)) {
          final c = store.committed!;
          final next = c.copyWith(
              seq: c.seq + 1,
              refreshOp: () => c.refreshOp!.copyWith(
                  state: RefreshOpState.retryable, expectedSeq: c.seq + 1));
          if (await store.write(next) == WriteOutcome.committed) {
            op.expectedSeq = next.seq;
          }
        }
        return _out(RefreshOutcomeKind.notSent, reason);
      });

  Future<RefreshOutcome?> _markDispatch(_Op op) async {
    if (!_opLive(op) || !_ownsRecord(op, RefreshOpState.reserved)) {
      return _out(RefreshOutcomeKind.notSent, op.cancelReason ?? 'not_owner');
    }
    final c = store.committed!;
    final count = c.tokenDispatches?.digest == op.tokenDigest
        ? c.tokenDispatches!.count
        : 0;
    if (count >= 3) {
      final next = c.copyWith(
          seq: c.seq + 1,
          refreshOp: () => c.refreshOp!.copyWith(
              state: RefreshOpState.exhausted, expectedSeq: c.seq + 1));
      if (await store.write(next) == WriteOutcome.committed) {
        op.expectedSeq = next.seq;
      }
      return _out(RefreshOutcomeKind.exhausted, 'dispatch_budget');
    }
    final next = c.copyWith(
      seq: c.seq + 1,
      refreshOp: () => c.refreshOp!.copyWith(
          state: RefreshOpState.dispatchMarked, expectedSeq: c.seq + 1),
      tokenDispatches: () =>
          TokenDispatches(digest: op.tokenDigest, count: count + 1),
    );
    final w = await store.write(next);
    if (w == WriteOutcome.committed) {
      op.expectedSeq = next.seq;
      return null;
    }
    // Confirmed failed: stays reserved, no bytes. Unknown: the store reloaded;
    // only an exact match of our mark counts (then marked, not sent).
    final now = store.committed;
    if (w == WriteOutcome.indeterminate ||
        (now != null &&
            now.refreshOp?.opId == op.id &&
            now.refreshOp?.state == RefreshOpState.dispatchMarked)) {
      return _out(RefreshOutcomeKind.notSent, 'marked_not_sent:unknown');
    }
    return _out(RefreshOutcomeKind.notSent, 'mark_failed');
  }

  static bool _definitiveFailure(RefreshHttpResult r) {
    if (r.statusCode != 400 && r.statusCode != 401 && r.statusCode != 403) {
      return false;
    }
    final j = r.json;
    if (j is! Map) return false;
    final code = j['error_code'] ?? j['error'];
    return code is String && kDefinitiveRefreshErrors.contains(code);
  }

  /// §10.6. Returns the canonical session or null.
  String? _validate(_Op op, RefreshHttpResult r) {
    // Diagnostic only: names the failed check (a constant).
    String? fail(String why) {
      op.invalid = why;
      return null;
    }

    if (r.statusCode != 200 || r.isRedirect) return fail('status');
    final j = r.json;
    if (j is! Map<String, dynamic>) return fail('json');
    try {
      final token = j['access_token'];
      if (token is! String) return fail('access_token');
      final claims = _claims(token);
      final exp = claims?['exp'];
      final wallNow = _wall().millisecondsSinceEpoch ~/ 1000;
      if (claims == null || claims['sub'] != op.owner) return fail('sub');
      if (exp is! int || exp <= wallNow + 60) return fail('exp');
      final expiresAt = j['expires_at'];
      if (expiresAt is int && (expiresAt - exp).abs() > 5) {
        return fail('expires_at');
      }
      final user = j['user'];
      if (user is! Map || user['id'] != op.owner) return fail('user');
      final rt = j['refresh_token'];
      if (rt is! String || rt.isEmpty || rt == op.refreshToken) {
        return fail('refresh_token');
      }
      final type = j['token_type'];
      if (type is! String || type.toLowerCase() != 'bearer') {
        return fail('token_type');
      }
      return canonicalSession(j);
    } catch (_) {
      return fail('parse');
    }
  }

  static Map<String, Object?>? _claims(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final decoded = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Predecessor + no-IDENTITY acceptance (§9.5), shared by both commits.
  bool _accepts(_Op op) =>
      !removalSince(op.intentSeq) &&
      !gate.foreignCauseSince(op.startPosition,
          kind: op.spec.kind, authority: op, atLeast: CauseClass.identity) &&
      // ASR decision (a): a deadline/background/explicit cancel before
      // acceptance discards the response.
      !(op.spec.kind == RefreshOpKind.asr &&
          (op.cancelled ||
              _asrExpired(op) ||
              !(op.spec.acceptPredicate?.call() ?? true))) &&
      _ownsRecord(op, RefreshOpState.dispatchMarked);

  Future<RefreshOutcome> _commitDead(_Op op) async {
    if (!_accepts(op)) return _out(RefreshOutcomeKind.stale, 'predecessor');
    final c = store.committed!;
    final next = c.copyWith(
        seq: c.seq + 1,
        credential: CredentialState.dead,
        refreshOp: () => null);
    final w = await store.write(next);
    if (w != WriteOutcome.committed) {
      return _out(RefreshOutcomeKind.possiblySent, 'dead_${w.name}');
    }
    onCredentialDead?.call();
    return const RefreshOutcome(RefreshOutcomeKind.dead);
  }

  Future<RefreshOutcome> _commitRefreshed(_Op op, String canonical) async {
    if (!_accepts(op)) return _out(RefreshOutcomeKind.stale, 'predecessor');
    final c = store.committed!;
    final AdmissionDisposition disposition;
    switch (op.spec.kind) {
      case RefreshOpKind.routine:
        disposition = c.admission;
      case RefreshOpKind.accountControl:
        final held =
            op.heldOrdinary && (op.spec.ordinaryAdmissionHeld?.call() ?? false);
        disposition =
            held ? c.admission : AdmissionDisposition.requiresAdoption;
      case RefreshOpKind.asr:
        disposition = AdmissionDisposition.requiresAdoption;
    }
    final next = c.copyWith(
      seq: c.seq + 1,
      session: canonical,
      admission: disposition,
      refreshOp: () => null,
      tokenDispatches: () => null,
    );
    final w = await store.write(next);
    if (w != WriteOutcome.committed) {
      return _out(RefreshOutcomeKind.possiblySent, 'commit_${w.name}');
    }
    _lineage.add(next.digest);
    return RefreshOutcome(RefreshOutcomeKind.committed,
        receipt: RefreshReceipt(
          opId: op.id,
          lifecycle: next.lifecycle,
          seq: next.seq,
          digest: next.digest,
          predecessorDigest: op.predecessorDigest,
          sdkBaseline: op.sdkBaseline,
          owner: op.owner,
          intentSeq: op.intentSeq,
        ));
  }

  /// Routine / accountControl installation (§4.10): silent `recoverSession`
  /// iff SDK memory still equals the op's baseline, the receipt is still the
  /// committed record and no cause or exclusion intervened.
  Future<bool> _install(_Op op, RefreshReceipt receipt) async {
    final ip = op.spec.installPredicate;
    if (ip != null && !await ip()) return false;
    return section.run(() async {
      final c = store.committed;
      final sdk = _sdk;
      bool ok() =>
          sdk != null &&
          c != null &&
          identical(store.committed, c) &&
          c.seq == receipt.seq &&
          c.digest == receipt.digest &&
          c.owner == op.owner &&
          // routine: ordinary only; accountControl: the grant is still active
          // and owner-bound (Cloud may be OFF; a requiresAdoption session in
          // memory is still refused by every automatic route, §4.7).
          (op.spec.kind == RefreshOpKind.accountControl
              ? op.ticket!.grant?.control?.active == true
              : c.admission == AdmissionDisposition.ordinary) &&
          _sdkBaseline == op.sdkBaseline &&
          sdkDigest == op.sdkBaseline &&
          !removalSince(op.intentSeq) &&
          _explicitExclusion == null &&
          _asrExclusion == null &&
          !op.ticket!.refresh!.noInstall &&
          !gate.foreignCauseSince(op.startPosition,
              kind: op.spec.kind, authority: op, atLeast: CauseClass.identity);
      if (!ok()) return false;
      try {
        await _mutate(AuthTag(AuthTagKind.install, op.id),
            () => sdk!.recoverSession(c!.session!));
      } catch (_) {
        return false;
      }
      if (sdkDigest != receipt.digest) return false;
      _setBaseline(receipt.digest);
      // §4.10 "After install": account control grants no admission and no
      // ordinary egress, so nothing downstream is told about the rotation.
      if (op.spec.kind == RefreshOpKind.routine) {
        onCredentialRotated?.call(receipt);
      }
      return true;
    });
  }

  // ── routine scheduler (§3.3) ─────────────────────────────────────────────

  Timer? _tick;
  bool _schedulerOn = false;
  static const Duration refreshLead = Duration(seconds: 90);
  static const Duration retryAfter = Duration(seconds: 15);

  /// Routine policy hooks, wired by bootstrap (ordinary egress authority).
  Future<bool> Function()? routinePermitted;

  /// Drives routine refreshes while the gate permits ordinary egress
  /// (replaces the SDK ticker; bootstrap calls it from `onPermitChanged`).
  void setSchedulerEnabled(bool on) {
    _schedulerOn = on;
    _tick?.cancel();
    _tick = null;
    if (on) _schedule(Duration.zero);
  }

  void _schedule(Duration after) {
    _tick?.cancel();
    if (!_schedulerOn) return;
    _tick = Timer(after, () => unawaited(_onTick()));
  }

  Future<void> _onTick() async {
    final c = store.committed;
    if (!_schedulerOn || c == null) return;
    final remaining = _remaining(c);
    if (remaining > refreshLead &&
        automaticAdmissionDenial() != custodySuccessor) {
      _schedule(remaining - refreshLead);
      return;
    }
    final out = await refreshIfDue();
    if (out?.kind == RefreshOutcomeKind.committed) {
      _schedule(Duration.zero);
    } else if (out?.kind != RefreshOutcomeKind.dead &&
        out?.kind != RefreshOutcomeKind.exhausted) {
      _schedule(retryAfter);
    }
  }

  /// A routine refresh when the committed session is within [refreshLead] of
  /// expiry and ordinary egress is permitted; null when not due.
  /// A committed routine successor in custody is installed first, without
  /// network, while it has more than [refreshLead] left (B10).
  Future<RefreshOutcome?> refreshIfDue() async {
    final c = store.committed;
    if (c == null || !_routineAdmissible()) return null;
    final custody = automaticAdmissionDenial() == custodySuccessor;
    if (!custody && _remaining(c) > refreshLead) return null;
    // Phase 4c B10: the policy check is bound to this cause position; the
    // continuation refuses any cause since it.
    final checkedAt = gate.causePosition;
    final permitted = routinePermitted;
    if (permitted != null && !await permitted()) return null;
    if (custody && _remaining(c) > refreshLead) {
      return _continueRoutine(checkedAt);
    }
    // A due custody successor is refreshed instead; its result installs
    // through the same lineage (§9.9 A13).
    return runRefresh(RefreshOpSpec(
      kind: RefreshOpKind.routine,
      deadline: const Duration(seconds: 30),
      admitPredicate: _routineAdmissible,
      sendPredicate: _routineAdmissible,
      installPredicate: routinePermitted,
    ));
  }

  /// §4.10 routine continuation (B10): installs the committed custody
  /// successor into SDK memory under the routine policy (checked by the
  /// caller at cause position [checkedAt]) and the lineage, rechecked in one
  /// section block. Phase 4c: the policy is revalidated there synchronously,
  /// right before installation — any cause since [checkedAt] (a Cloud disable
  /// while waiting for the section included), a hold, a freeze or a terminal
  /// denial refuses. Never sends.
  Future<RefreshOutcome> _continueRoutine(int checkedAt) {
    return section.run(() async {
      final c = store.committed;
      final sdk = _sdk;
      if (sdk == null ||
          c == null ||
          _activeOp != null ||
          automaticAdmissionDenial() != custodySuccessor ||
          _remaining(c) <= refreshLead) {
        return _out(RefreshOutcomeKind.denied, 'continuation');
      }
      if (gate.foreignCauseSince(checkedAt, kind: RefreshOpKind.routine) ||
          gate.holdActive ||
          gate.terminalDenied ||
          ConsentAuthority.egressFrozen) {
        return _out(RefreshOutcomeKind.denied, 'continuation_policy');
      }
      final receipt = RefreshReceipt(
        opId: _newId(),
        lifecycle: c.lifecycle,
        seq: c.seq,
        digest: c.digest,
        predecessorDigest: _sdkBaseline,
        sdkBaseline: _sdkBaseline,
        owner: c.owner!,
        intentSeq: _intentSeq,
      );
      try {
        await _mutate(AuthTag(AuthTagKind.install, receipt.opId),
            () => sdk.recoverSession(c.session!));
      } catch (_) {
        return _out(RefreshOutcomeKind.denied, 'continuation_install');
      }
      if (sdkDigest != c.digest || !identical(store.committed, c)) {
        return _out(RefreshOutcomeKind.denied, 'continuation_install');
      }
      _setBaseline(c.digest);
      onCredentialRotated?.call(receipt);
      return RefreshOutcome(RefreshOutcomeKind.committed,
          receipt: receipt, installed: true);
    });
  }

  /// Wired by bootstrap: the process holds a current ordinary admission for
  /// the committed owner (authenticated normal mode, not local read).
  bool Function()? ordinaryAdmissionHeld;

  /// §3.5: inside an active deleteAccount/cancelDelete grant, when the session
  /// is within 90 s of expiry.
  Future<RefreshOutcome?> refreshForAccountControl(
      {required bool Function() ordinaryAdmissionHeld}) async {
    final c = store.committed;
    if (c == null || _remaining(c) > const Duration(seconds: 90)) return null;
    return runRefresh(RefreshOpSpec(
      kind: RefreshOpKind.accountControl,
      deadline: gate.accountControlTtl,
      ordinaryAdmissionHeld: ordinaryAdmissionHeld,
    ));
  }

  /// Seconds of validity the committed session has left (≤ 0 when expired).
  Duration committedRemaining() {
    final c = store.committed;
    return c == null ? Duration.zero : _remaining(c);
  }

  // ── ASR installation and durable adoption state (§9.6, §11.4, §7.5.1) ────

  /// §9.9 receipt-only continuation: the committed record is a `live`,
  /// `requiresAdoption` session of [owner] that was never installed, and SDK
  /// memory still equals the coordinator baseline. Null otherwise.
  RefreshReceipt? continuationReceipt(String owner) {
    final c = store.committed;
    if (store.indeterminate ||
        _activeOp != null ||
        _unattributed ||
        c == null ||
        c.isTombstone ||
        c.owner != owner ||
        c.credential != CredentialState.live ||
        c.admission != AdmissionDisposition.requiresAdoption ||
        c.adoption != null ||
        _barred(c) ||
        c.refreshOp != null ||
        c.digest == _sdkBaseline ||
        sdkDigest != _sdkBaseline) {
      return null;
    }
    return RefreshReceipt(
      opId: _newId(),
      lifecycle: c.lifecycle,
      seq: c.seq,
      digest: c.digest,
      predecessorDigest: c.digest,
      sdkBaseline: _sdkBaseline,
      owner: owner,
      intentSeq: _intentSeq,
    );
  }

  /// §9.6: in one section block, checks the receipt against the committed
  /// record and SDK memory, then sets `asrExclusion`, begins the hold and
  /// installs. Null when the check failed (nothing was set). Otherwise the
  /// exclusion and hold are the caller's to release per §4.6/§11.4, whether or
  /// not [AsrInstall.installed].
  Future<AsrInstall?> installForAsr(RefreshReceipt receipt,
      {required bool Function() predicate}) {
    return section.run(() async {
      final c = store.committed;
      final sdk = _sdk;
      if (sdk == null ||
          store.indeterminate ||
          c == null ||
          c.isTombstone ||
          c.lifecycle != receipt.lifecycle ||
          c.seq != receipt.seq ||
          c.digest != receipt.digest ||
          c.owner != receipt.owner ||
          c.credential != CredentialState.live ||
          c.admission != AdmissionDisposition.requiresAdoption ||
          c.adoption != null ||
          _barred(c) ||
          _unattributed ||
          _sdkBaseline != receipt.sdkBaseline ||
          sdkDigest != _sdkBaseline ||
          _explicitExclusion != null ||
          _asrExclusion != null ||
          _activeOp != null ||
          removalSince(receipt.intentSeq) ||
          !predicate()) {
        return null;
      }
      _asrExclusion = receipt.opId;
      final hold = gate.beginTransitionHold();
      try {
        await _mutate(AuthTag(AuthTagKind.install, receipt.opId),
            () => sdk.recoverSession(c.session!));
      } catch (_) {
        return AsrInstall(hold, installed: false);
      }
      final ok = sdkDigest == receipt.digest;
      if (ok) _setBaseline(receipt.digest);
      return AsrInstall(hold, installed: ok);
    });
  }

  /// §4.6(2) safe local read, the coordinator part: the committed record of
  /// the receipt's lifecycle keeps every ordinary route closed, and SDK memory
  /// holds exactly it or nothing.
  bool safeLocalRead(RefreshReceipt receipt) {
    final c = store.committed;
    if (store.indeterminate || c == null || c.lifecycle != receipt.lifecycle) {
      return false;
    }
    final a = c.adoption?.state;
    final closed = c.admission == AdmissionDisposition.requiresAdoption ||
        a == AdoptionState.pending ||
        a == AdoptionState.failed ||
        _barred(c);
    final memory = _sdk?.currentSession;
    return closed && (memory == null || sdkDigest == c.digest);
  }

  /// One adoption-state write in the section, owned by `opId` and lifecycle.
  /// True only when the write is confirmed (success, or the reload shows it).
  Future<bool> _writeAdoption(RefreshReceipt receipt,
      SessionRecord? Function(SessionRecord c) derive) {
    return section.run(() async {
      if (store.indeterminate && !await store.resolve()) return false;
      final c = store.committed;
      if (c == null ||
          c.isTombstone ||
          c.lifecycle != receipt.lifecycle ||
          c.owner != receipt.owner ||
          removalSince(receipt.intentSeq)) {
        return false;
      }
      final next = derive(c);
      if (next == null) return false;
      return await store.write(next) == WriteOutcome.committed;
    });
  }

  /// `AdoptionPending` (from no adoption) or `AdoptionFailed` (from this op's
  /// pending/finalizing-free state).
  Future<bool> writeAdoption(RefreshReceipt receipt, AdoptionState state) {
    assert(state != AdoptionState.finalizing);
    return _writeAdoption(receipt, (c) {
      final a = c.adoption;
      if (state == AdoptionState.pending) {
        if (a != null ||
            c.admission != AdmissionDisposition.requiresAdoption ||
            c.digest != receipt.digest) {
          return null;
        }
      } else if (a == null ||
          a.opId != receipt.opId ||
          a.state == AdoptionState.finalizing) {
        return null;
      }
      return c.copyWith(
          seq: c.seq + 1,
          adoption: () => AdoptionRecord(
              state: state, lifecycle: c.lifecycle, opId: receipt.opId));
    });
  }

  /// `AdoptionFinalizing{awaiting}` after writable publication; writes
  /// `admission: ordinary` in the same record write (§4.6(1)).
  Future<bool> writeFinalizing(RefreshReceipt receipt,
      {SuccessorRecord? successor}) {
    return _writeAdoption(receipt, (c) {
      final a = c.adoption;
      if (a == null ||
          a.opId != receipt.opId ||
          a.state != AdoptionState.pending ||
          c.digest != receipt.digest) {
        return null;
      }
      return c.copyWith(
          seq: c.seq + 1,
          admission: AdmissionDisposition.ordinary,
          adoption: () => AdoptionRecord(
              state: AdoptionState.finalizing,
              lifecycle: c.lifecycle,
              opId: receipt.opId,
              successor: successor));
    });
  }

  /// §7.5.1 `finish` transitions of this op's finalizing successor.
  Future<bool> writeFinish(RefreshReceipt receipt, FinishState finish) {
    return _writeAdoption(receipt, (c) {
      final a = c.adoption;
      final s = a?.successor;
      if (a == null ||
          a.opId != receipt.opId ||
          a.state != AdoptionState.finalizing ||
          s == null ||
          s.finish.index >= finish.index) {
        return null;
      }
      return c.copyWith(
          seq: c.seq + 1,
          adoption: () => AdoptionRecord(
              state: AdoptionState.finalizing,
              lifecycle: a.lifecycle,
              opId: a.opId,
              successor: s.withFinish(finish)));
    });
  }

  /// Whether the durable record holds this op's adoption in [state]: an
  /// indeterminate store is resolved first, and an unresolvable one is
  /// [AdoptionCheck.unresolved] (B2: never decided on a stale in-memory record,
  /// and never read as "not in state").
  Future<AdoptionCheck> checkAdoption(
      RefreshReceipt receipt, AdoptionState state) {
    return section.run(() async {
      if (store.indeterminate && !await store.resolve()) {
        return AdoptionCheck.unresolved;
      }
      final a = store.committed?.adoption;
      return a != null && a.opId == receipt.opId && a.state == state
          ? AdoptionCheck.confirmed
          : AdoptionCheck.notInState;
    });
  }

  /// `AdoptionComplete`: the finalizing field of this op is cleared.
  Future<bool> completeAdoption(RefreshReceipt receipt) {
    return _writeAdoption(receipt, (c) {
      final a = c.adoption;
      if (a == null ||
          a.opId != receipt.opId ||
          a.state != AdoptionState.finalizing) {
        return null;
      }
      return c.copyWith(seq: c.seq + 1, adoption: () => null);
    });
  }

  int? _blockedLifecycle;

  /// Whether the committed lifecycle is barred from automatic admission
  /// (durably, or by this process's not-yet-confirmed barrier).
  bool _barred(SessionRecord c) =>
      c.autoAdmissionBlocked == c.lifecycle || _blockedLifecycle == c.lifecycle;

  /// The committed record is barred (durably or in this process).
  bool get committedBarred {
    final c = store.committed;
    return c != null && _barred(c);
  }

  /// §7.7, synchronous: bars the committed lifecycle in this process at once
  /// and returns it — the lifecycle the loss happened in, which the durable
  /// write ([markAutoAdmissionBlocked]) must name.
  int? blockAutoAdmission() {
    final c = store.committed;
    if (c == null || c.isTombstone) return null;
    return _blockedLifecycle = c.lifecycle;
  }

  /// §7.7 barrier: `autoAdmissionBlocked = L` for exactly [lifecycle], the one
  /// captured when the loss happened. A newer lifecycle committed meanwhile
  /// (e.g. an explicit sign-in queued ahead) is never barred by an older loss.
  Future<bool> markAutoAdmissionBlocked({required int lifecycle}) {
    return section.run(() async {
      if (store.indeterminate && !await store.resolve()) return false;
      final c = store.committed;
      if (c == null || c.isTombstone) return false;
      if (c.lifecycle != lifecycle) return true; // superseded: nothing to bar
      if (c.autoAdmissionBlocked == c.lifecycle) return true;
      return await store.write(c.copyWith(
              seq: c.seq + 1, autoAdmissionBlocked: () => c.lifecycle)) ==
          WriteOutcome.committed;
    });
  }

  void dispose() {
    _tick?.cancel();
    _events?.cancel();
  }
}
