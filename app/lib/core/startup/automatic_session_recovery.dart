import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../features/capture/services/capture_device_registration_service.dart';
import '../../features/capture/services/native_capture_bridge.dart';
import '../auth/auth_coordinator.dart';
import '../auth/auth_diagnostics.dart';
import '../auth/session_record.dart';
import '../privacy/cloud_egress_gate.dart';
import '../session/app_session.dart';

/// Automatic Session Recovery (ASR, design v7.2 §8–§11): a user whose access
/// token expired while the refresh credential is still valid returns from local
/// read to normal mode without signing in again — only while Cloud/consent
/// permit, with native expiry evidence, and never past a foreign restriction.
///
/// Conservative rule (§9): owned transitions may continue; any foreign
/// restriction stops progress towards publication. Installation and adoption
/// happen only in the foreground with full re-confirmation. Every unknown
/// denies: the user then stays in local read and signs in as today.

enum AsrOutcome {
  /// Not attempted (not eligible, already running, not foreground).
  skipped,

  /// Eligible but stopped before withdrawal; local read is unchanged.
  stayedLocalRead,

  /// Installed, adopted and published writable; normal mode.
  recovered,

  /// Failure after local-read withdrawal: sign-in screen, data preserved (c).
  signInRequired,
}

/// §11.3: continuation and cleanup ownership are separate.
class AsrAuthority {
  /// Cleared synchronously by an explicit attempt or by leaving the foreground
  /// (B5); never set again, so the op cannot continue after a resume.
  bool mayContinue = true;
  bool ownsCleanup = true;
}

/// Native evidence (§7.4/§7.6), injectable for tests.
abstract class AsrNativePort {
  Future<RecoveryEvidenceSnapshot?> inspect(String owner);
  Future<bool> confirm(int expectedCounter);
  Future<CloudEgressEnableResult?> mintLiveOn(
      String owner, RecoveryEvidenceSnapshot snapshot, int sessionLifecycle);
}

class BridgeAsrNativePort implements AsrNativePort {
  const BridgeAsrNativePort();
  @override
  Future<RecoveryEvidenceSnapshot?> inspect(String owner) =>
      NativeCaptureBridge.inspectRecoveryEvidence(ownerUid: owner);
  @override
  Future<bool> confirm(int expectedCounter) =>
      NativeCaptureBridge.confirmRecoveryEvidence(expectedCounter);
  @override
  Future<CloudEgressEnableResult?> mintLiveOn(String owner,
      RecoveryEvidenceSnapshot snapshot, int sessionLifecycle) async {
    final og = snapshot.ownerGeneration;
    final oe = snapshot.ownerEpoch;
    final tg = snapshot.transitionGeneration;
    final rv = snapshot.reservedVersion;
    final counter = snapshot.mutationCounter;
    if (og == null ||
        oe == null ||
        tg == null ||
        rv == null ||
        counter == null) {
      return null;
    }
    try {
      return await NativeCaptureBridge.mintExpiryEvidenceForLiveOn(
        ownerUid: owner,
        ownerGeneration: og,
        ownerEpoch: oe,
        transitionGeneration: tg,
        reservedVersion: rv,
        sessionLifecycle: sessionLifecycle,
        expectedCounter: counter,
      );
    } catch (_) {
      return null;
    }
  }
}

/// The native expiry evidence ASR acts under, with the counter its own
/// receipts advanced native to (§7.4: only own receipts advance it).
class AsrEvidence {
  AsrEvidence(this.evidence, this.counter);

  /// Null for a session-only recovery (Cloud OFF): there is no Cloud lifetime
  /// to succeed, only the native counter that every native write advances.
  final NativeExpiryEvidence? evidence;
  int counter;

  /// Owner decision (2026-10-29): recovers the session only. No successor
  /// (SE1–SE5) is published and Cloud stays exactly as it is (OFF).
  bool get sessionOnly => evidence == null;
}

/// SE2/SE3's receipt, opaque to the orchestrator.
class AsrPreparedSuccessor {
  AsrPreparedSuccessor({
    required this.successorGeneration,
    required this.ownerEpoch,
    required this.pendingOpId,
    this.handle,
  });
  final int successorGeneration;
  final int ownerEpoch;
  final String pendingOpId;
  final Object? handle;
}

/// The capture lane (E2 Dart, E4, §7.5 SE2–SE5), injectable.
abstract class AsrCapturePort {
  /// E2 Dart: both Dart layers present, agreeing, ON for [owner].
  Future<bool> dartEgressOn(String owner);

  /// Session-only E2 Dart: both layers agree on OFF or both confirm absence
  /// for an owner who never enabled Cloud. The secure read preserves status;
  /// partial absence, ON, DISABLING, disagreement and unreadability deny.
  /// Native must independently verify OFF before any token exchange.
  Future<bool> dartEgressOff(String owner);

  /// E4: saved consent accepted (local-read scope database, SELECT).
  Future<bool> consentAccepted(String owner);

  /// SE2 + SE3 after SE1. Null when refused (what was written is undone or
  /// left behind the barrier).
  Future<AsrPreparedSuccessor?> prepare(AsrAdoptionContext ctx);

  /// SE4: `confirmed`, `notExecuted`, or `unknown`.
  Future<String> finish(AsrPreparedSuccessor p);

  /// SE5: exact Dart pending clearance + freeze release.
  Future<bool> clearDart(AsrPreparedSuccessor p);

  /// Compensation (before SE4), or exact retirement of G' ([finished]).
  /// True only when settled (native restricted/retired AND the Dart pending
  /// cleared, read back). Never throws.
  Future<bool> compensate(AsrPreparedSuccessor p, {required bool finished});

  /// §7.5.2 restart: the successor of a durable `finalizing` record; null
  /// when no pending of the owner is left. Throws when it cannot be read.
  Future<AsrPreparedSuccessor?> recover(String owner, SuccessorRecord s);

  /// §7.5.2 restart with no pending left: exact retirement of G'.
  Future<bool> retireOrphan(String owner, SuccessorRecord s);

  /// §7.5.2 restart, `dispatched`: `confirmed` / `notExecuted` / `unknown`.
  Future<String> inspect(AsrPreparedSuccessor p);

  /// The ordinary post-adoption capture reconciliation (`refresh()`).
  Future<void> reconcile(String owner);
}

/// The adoption a host performs for one ASR op.
class AsrAdoptionContext {
  AsrAdoptionContext({
    required this.owner,
    required this.receipt,
    required this.evidence,
    required this.authority,
    required this.mayProceed,
  });
  final String owner;
  final RefreshReceipt receipt;
  final AsrEvidence evidence;
  final AsrAuthority authority;

  /// P_adopt (§9.7): rechecked at its start and after every await.
  final bool Function() mayProceed;

  /// SE1's receipt (set by the host's successor publication).
  int? successorGeneration;
  int? successorOwnerEpoch;

  /// Set once SE2/SE3 succeeded.
  AsrPreparedSuccessor? prepared;

  /// Set by the host once the writable status was published.
  bool published = false;

  /// Called by the host after SE1 and before writable publication: SE2/SE3
  /// and P_publish. False aborts.
  late Future<bool> Function() beforePublication;
}

enum AsrAdoptResult { notWithdrawn, published, failedAfterWithdrawal }

/// What ASR needs from the session (AppSession in production).
abstract class AsrSessionHost {
  /// E9: the app is in the foreground (`resumed`).
  bool get resumed;

  /// An accepted refresh can finish adoption while iOS is foreground-inactive
  /// (for example Face ID or a view-controller transition). Never background.
  bool get foreground => resumed;

  /// The owner the active, verified local-read scope belongs to, or null.
  String? get localReadOwner;

  /// E3–E11 (status-preserving, read-only). Null when eligible.
  Future<String?> eligibilityDenial(String owner);

  /// The synchronous process-state part (P_admit/P_send/P_adopt).
  String? processDenial(String owner, {required bool adopting});

  /// Withdraws local read and admits [ctx.owner] writable (§9.7/§9.8).
  Future<AsrAdoptResult> adopt(AsrAdoptionContext ctx);

  /// §11.4 step 2 after withdrawal. Never throws.
  Future<void> failAfterWithdrawal(String owner);
}

class AutomaticSessionRecovery {
  AutomaticSessionRecovery({
    required this.coordinator,
    required this.gate,
    required this.host,
    required this.capture,
    this.native = const BridgeAsrNativePort(),
    this.foregroundDeadline = const Duration(seconds: 5),
    this.presentationDeadline = const Duration(seconds: 30),
  });

  final AuthCoordinator coordinator;
  final CloudEgressGate gate;
  final AsrSessionHost host;
  final AsrCapturePort capture;
  final AsrNativePort native;
  final Duration foregroundDeadline;
  final Duration presentationDeadline;

  static const Duration installMinimum = Duration(seconds: 120);
  static const Duration publishMinimum = Duration(seconds: 30);

  /// The process instance (wired by bootstrap; null in tests and builds
  /// without Supabase).
  static AutomaticSessionRecovery? active;

  /// Presentation only. Holds one branded loader across local-read withdrawal,
  /// writable-scope publication and final recovery settlement. It grants no
  /// session, database or Cloud authority.
  static final ValueNotifier<bool> restoringSession = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> recoveryTimedOut = ValueNotifier<bool>(false);
  static AutomaticSessionRecovery? _presenting;
  Timer? _presentationTimer;

  void _finishPresentation() {
    _presentationTimer?.cancel();
    _presentationTimer = null;
    if (!identical(_presenting, this)) return;
    _presenting = null;
    restoringSession.value = false;
  }

  Future<AsrOutcome>? _running;
  AsrAuthority? _authority;

  /// Diagnostic only: an allowlisted constant, never an identifier.
  @visibleForTesting
  String? lastStop;

  /// Diagnostic only (Beta 1): the last informative stop with its detail, all
  /// allowlisted constants (never an identifier or token), shown on the local
  /// read screen so a tester can report why recovery did not happen.
  static final ValueNotifier<String?> diagnostic = ValueNotifier<String?>(null);
  String? _detail;

  bool get running => _running != null;

  /// §11.3: an explicit attempt clears continuation; cleanup ownership stays.
  void yieldToExplicitAttempt() {
    recoveryTimedOut.value = false;
    _retry?.cancel();
    _retry = null;
    _authority?.mayContinue = false;
  }

  /// Completes once no ASR run is in flight (§11.3 `asr.quiesced()`).
  Future<void> quiesced() async {
    final r = _running;
    if (r != null) await r.then((_) {}, onError: (Object _) {});
  }

  /// Single-flight entry for every trigger (§8).
  Future<AsrOutcome> run() {
    if (_running != null) return Future.value(AsrOutcome.skipped);
    // Ordinary resume checks without a local-read owner must not move the
    // current page or show a loader. Once started, retain the loader through
    // adoption even after the local-read scope has been withdrawn.
    final present = host.localReadOwner != null;
    final run = _run().whenComplete(() {
      _running = null;
      _finishPresentation();
    });
    _running = run;
    if (present) {
      recoveryTimedOut.value = false;
      _presenting = this;
      restoringSession.value = true;
      // End only the loading presentation. Keep custody, holds and cleanup
      // with the original operation until its I/O actually settles.
      _presentationTimer = Timer(presentationDeadline, () {
        _authority?.mayContinue = false;
        coordinator.cancelActive('presentation_timeout');
        AuthDiagnostics.add('asr_presentation_timeout');
        recoveryTimedOut.value = true;
        _finishPresentation();
      });
    }
    return run;
  }

  AsrOutcome _stop(String why, [AsrOutcome o = AsrOutcome.stayedLocalRead]) {
    lastStop = why;
    if (why != 'background') {
      diagnostic.value = _detail == null ? why : '$why:$_detail';
      AuthDiagnostics.add('asr_stop ${diagnostic.value}');
    }
    _detail = null;
    return o;
  }

  /// Which E1 predicate failed (constants only).
  static String _recordDetail(SessionRecord? c, String owner, bool barred) {
    if (c == null) return 'none';
    if (c.isTombstone) return 'tombstone';
    if (c.owner != owner) return 'owner';
    if (c.credential != CredentialState.live) {
      return 'credential_${c.credential.name}';
    }
    if (c.adoption != null) return 'adoption_${c.adoption!.state.name}';
    if (c.autoAdmissionBlocked == c.lifecycle) return 'auto_blocked';
    final op = c.refreshOp;
    if (op != null && !_recordEligible(c, owner)) {
      return 'op_${op.state.name}_${c.tokenDispatches?.count ?? 0}';
    }
    return barred ? 'barred' : 'other';
  }

  Future<AsrOutcome> _run() async {
    // ── P_elig (§9.2) ──────────────────────────────────────────────────────
    if (!host.resumed) return _stop('background', AsrOutcome.skipped);
    // Phase 4c B2: an adoption whose finalizing write is unresolved is
    // decided from the durable record first.
    if (_unresolvedAdoption != null && !await _resolveUnsettledAdoption()) {
      return _stop('adoption_unresolved', AsrOutcome.skipped);
    }
    // B2: an unsettled successor (an unanswered or failed settlement) is
    // reconciled, in order, before anything else.
    final unsettled = unsettledFinalizationOwner;
    if (unsettled != null) {
      await reconcileSuccessorFinalization(unsettled);
      return _stop('finalization', AsrOutcome.skipped);
    }
    final owner = host.localReadOwner;
    if (owner == null) return _stop('no_local_read', AsrOutcome.skipped);
    if (coordinator.store.indeterminate && !await coordinator.store.resolve()) {
      return _stop('indeterminate', AsrOutcome.skipped);
    }
    final c0 = coordinator.store.committed;
    if (!_recordEligible(c0, owner) || coordinator.committedBarred) {
      _detail = _recordDetail(c0, owner, coordinator.committedBarred);
      return _stop('record', AsrOutcome.skipped);
    }
    final lifecycle = c0!.lifecycle;
    if (coordinator.explicitExclusion != null ||
        coordinator.asrExclusion != null ||
        coordinator.refreshing) {
      return _stop('exclusion', AsrOutcome.skipped);
    }
    final denial = await host.eligibilityDenial(owner);
    if (denial != null) {
      _detail = denial;
      return _stop('elig', AsrOutcome.skipped);
    }
    // Owner decisions (2026-10-29, L2 2026-11-14): unless Cloud is verified
    // ON the session alone is recovered (no Cloud consent is needed: nothing
    // but the token exchange leaves the device). That includes the states
    // between ON and OFF (DISABLING, pending enable, an unreadable record),
    // which otherwise signed the user out once the session expired. Cloud
    // capture stays exactly as restrictive as the gate already keeps it.
    final bool sessionOnly;
    if (await capture.dartEgressOn(owner)) {
      if (!await capture.consentAccepted(owner)) {
        _detail = 'on_no_consent';
        return _stop('cloud', AsrOutcome.skipped);
      }
      sessionOnly = false;
    } else {
      sessionOnly = true;
    }
    if (host.processDenial(owner, adopting: false) != null ||
        !_recordEligible(coordinator.store.committed, owner) ||
        coordinator.committedBarred ||
        coordinator.store.committed!.lifecycle != lifecycle) {
      return _stop('process', AsrOutcome.skipped);
    }
    final evidence = sessionOnly
        ? await _sessionOnlyEvidence(owner)
        : await _evidence(owner, lifecycle);
    if (evidence == null) return _stop('native_evidence', AsrOutcome.skipped);
    if (recoveryTimedOut.value) return _stop('presentation_timeout');

    final authority = AsrAuthority();
    _authority = authority;
    try {
      return await _recover(owner, evidence, authority);
    } finally {
      if (identical(_authority, authority)) _authority = null;
    }
  }

  /// E1 (§9.2).
  static bool _recordEligible(SessionRecord? c, String owner) {
    if (c == null ||
        c.isTombstone ||
        c.owner != owner ||
        c.credential != CredentialState.live ||
        c.adoption != null ||
        c.autoAdmissionBlocked == c.lifecycle) {
      return false;
    }
    final op = c.refreshOp;
    return op == null ||
        op.state == RefreshOpState.reserved ||
        op.state == RefreshOpState.retryable ||
        (op.state == RefreshOpState.dispatchMarked &&
            (c.tokenDispatches?.count ?? 0) < 3);
  }

  /// E2 native (§7.6): E2-a expiry evidence of this lifecycle, or E2-b the
  /// conditional retirement of a still-ON lifetime (after every other
  /// predicate passed). Nothing is ever manufactured for an ordinary OFF.
  Future<AsrEvidence?> _evidence(String owner, int lifecycle) async {
    final snap = await native.inspect(owner);
    final counter = snap?.mutationCounter;
    if (snap == null || counter == null) return null;
    switch (snap.kind) {
      case RecoveryEvidenceKind.expiryEvidence:
        final e = snap.expiryEvidence;
        if (e == null ||
            e.sessionLifecycle != lifecycle ||
            e.ownerGeneration != snap.ownerGeneration ||
            e.ownerEpoch != snap.ownerEpoch) {
          return null;
        }
        return AsrEvidence(e, counter);
      case RecoveryEvidenceKind.liveOn:
        final minted = await native.mintLiveOn(owner, snap, lifecycle);
        final e = minted?.expiryEvidence;
        final next = minted?.mutationCounter;
        if (minted == null ||
            minted.status != CloudEgressTransitionStatus.done ||
            e == null ||
            next == null ||
            e.sessionLifecycle != lifecycle) {
          return null;
        }
        return AsrEvidence(e, next);
      case RecoveryEvidenceKind.none:
        return null;
    }
  }

  /// Session-only E2 native (L2, 2026-11-14): native must confirm the active
  /// owner and that no removal barrier is present; the Cloud state itself
  /// (OFF, ON, DISABLING, pending, disagreeing layers) no longer denies the
  /// session-only exchange. Expiry evidence is never consumed here. The
  /// counter is confirmed before admit, send, install and publication, so any
  /// native write meanwhile stops the op.
  Future<AsrEvidence?> _sessionOnlyEvidence(String owner) async {
    final snap = await native.inspect(owner);
    final counter = snap?.mutationCounter;
    if (snap == null || counter == null || !snap.ownerVerified) {
      _detail = snap == null
          ? 'unavailable'
          : '${snap.kind.name}/${snap.state ?? '-'}/'
              '${snap.ownerGeneration == null ? 'no_owner' : 'owner'}';
      return null;
    }
    return AsrEvidence(null, counter);
  }

  Future<AsrOutcome> _recover(
      String owner, AsrEvidence evidence, AsrAuthority authority) async {
    // The op starts after our own evidence writes (§9.1 causeLogPosition).
    final start = gate.causePosition;
    var installed = false;
    var accepted = false;
    bool liveSync() =>
        authority.mayContinue &&
        (accepted ? host.foreground : host.resumed) &&
        host.processDenial(owner, adopting: installed) == null &&
        !gate.foreignCauseSince(start,
            kind: RefreshOpKind.asr, authority: authority);

    // ── refresh (§9.3–§9.5), or a receipt-only continuation (§9.9) ─────────
    RefreshReceipt? receipt;
    final c = coordinator.store.committed!;
    if (c.admission == AdmissionDisposition.requiresAdoption &&
        coordinator.committedRemaining() >= installMinimum) {
      receipt = coordinator.continuationReceipt(owner);
      if (receipt == null) return _stop('continuation');
    } else {
      final out = await coordinator.runRefresh(RefreshOpSpec(
        kind: RefreshOpKind.asr,
        deadline: foregroundDeadline,
        install: false,
        preAdmit: () => native.confirm(evidence.counter),
        admitPredicate: liveSync,
        preSend: () => native.confirm(evidence.counter),
        sendPredicate: liveSync,
        acceptPredicate: () => authority.mayContinue && host.resumed,
      ));
      if (out.kind != RefreshOutcomeKind.committed || out.receipt == null) {
        return _stop('refresh:${out.reason}');
      }
      if (out.noInstall) return _stop('custody_only');
      receipt = out.receipt;
    }
    final r = receipt!;
    accepted = true;

    // ── P_install (§9.6; foreground only) ─────────────────────────────────
    if (!liveSync() || !await native.confirm(evidence.counter)) {
      return _stop('install_predicate');
    }
    if (await host.eligibilityDenial(owner) != null) {
      return _stop('install_elig');
    }
    final install = await coordinator.installForAsr(r,
        predicate: () =>
            liveSync() && coordinator.committedRemaining() >= installMinimum);
    if (install == null) return _stop('install_refused');
    installed = true;

    // From here every exit releases the exclusion and the hold (§11.1).
    var released = false;
    Future<void> release() async {
      if (released) return;
      released = true;
      coordinator.releaseAsrExclusion(r.opId);
      await gate.endTransitionHold(install.hold);
    }

    /// §4.6(2) safe local read, else terminal denial; then release.
    Future<AsrOutcome> stayLocalRead(String why) async {
      if (!coordinator.safeLocalRead(r) || host.localReadOwner != owner) {
        gate.terminalDeny();
      }
      await release();
      return _stop(why);
    }

    try {
      if (!install.installed) return await stayLocalRead('install_failed');

      // ── AdoptionPending (§11.4) ──────────────────────────────────────────
      if (!liveSync() ||
          !await coordinator.writeAdoption(r, AdoptionState.pending)) {
        return await stayLocalRead('pending_unconfirmed');
      }
      final ctx = AsrAdoptionContext(
        owner: owner,
        receipt: r,
        evidence: evidence,
        authority: authority,
        mayProceed: () =>
            liveSync() &&
            coordinator.store.committed?.lifecycle == r.lifecycle &&
            !coordinator.removalSince(r.intentSeq),
      );
      ctx.beforePublication = () => _beforePublication(ctx);

      AsrAdoptResult adopted;
      try {
        adopted = await host.adopt(ctx);
      } catch (_) {
        adopted = AsrAdoptResult.failedAfterWithdrawal;
      }
      if (adopted == AsrAdoptResult.notWithdrawn &&
          host.localReadOwner == owner) {
        // Nothing withdrawn: the record bars every automatic route (failed),
        // and local read stays; the user signs in to continue.
        await _compensate(ctx);
        await coordinator.writeAdoption(r, AdoptionState.failed);
        return await stayLocalRead('adopt_not_withdrawn');
      }
      if (adopted != AsrAdoptResult.published) {
        return await _failAfterWithdrawal(ctx, release);
      }

      if (evidence.sessionOnly) {
        // Session-only: no successor, so `finalizing` carries none and is
        // completed at once (a restart completes it the same way).
        if (!await coordinator.writeFinalizing(r)) {
          switch (await coordinator.checkAdoption(r, AdoptionState.finalizing)) {
            case AdoptionCheck.confirmed:
              break;
            case AdoptionCheck.notInState:
              return await _failAfterWithdrawal(ctx, release);
            case AdoptionCheck.unresolved:
              _unresolvedAdoption = ctx;
              released = true;
              await gate.endTransitionHold(install.hold);
              return _stop('adoption_unresolved');
          }
        }
        coordinator.releaseAsrExclusion(r.opId);
        // Identity, writable scope and ordinary admission are now verified.
        // Remaining durable cleanup must not keep the usable home hidden.
        _finishPresentation();
        await coordinator.completeAdoption(r);
        await release();
        return _stop('recovered', AsrOutcome.recovered);
      }

      // ── AdoptionFinalizing{awaiting} (§7.5.1): `admission: ordinary` ─────
      final p = ctx.prepared!;
      final finalized = await coordinator.writeFinalizing(r,
          successor: SuccessorRecord(
              generation: p.successorGeneration,
              evidenceId: evidence.evidence!.evidenceId,
              pendingOpId: p.pendingOpId,
              finish: FinishState.awaiting));
      // B2: an unknown write is resolved before branching (never on the
      // stale in-memory `pending`). Phase 4c: an unresolvable one selects no
      // branch — the successor stays restrictive (pending barrier and freeze
      // kept, nothing compensated, finished or signed out) and the exclusion
      // stays held until [_resolveUnsettledAdoption] reads the durable state.
      if (!finalized) {
        switch (await coordinator.checkAdoption(r, AdoptionState.finalizing)) {
          case AdoptionCheck.confirmed:
            break;
          case AdoptionCheck.notInState:
            return await _failAfterWithdrawal(ctx, release);
          case AdoptionCheck.unresolved:
            _unresolvedAdoption = ctx;
            released = true;
            await gate.endTransitionHold(install.hold);
            return _stop('adoption_unresolved');
        }
      }
      // Ordinary admission is established: the exclusion ends here (§4.6(1)).
      coordinator.releaseAsrExclusion(r.opId);
      // Cloud successor settlement can wait on native I/O after the recovered
      // account is already usable. Keep its cleanup/fences, release only UI.
      _finishPresentation();
      await _finalize(ctx, p);
      await release();
      return _stop('recovered', AsrOutcome.recovered);
    } finally {
      await release();
    }
  }

  /// SE2/SE3 then P_publish (§9.8), between SE1 and writable publication.
  Future<bool> _beforePublication(AsrAdoptionContext ctx) async {
    if (!ctx.mayProceed()) return false;
    // Session-only: no SE2/SE3; P_publish alone.
    if (!ctx.evidence.sessionOnly) {
      if (ctx.successorGeneration == null || ctx.successorOwnerEpoch == null) {
        return false;
      }
      final prepared = await capture.prepare(ctx);
      if (prepared == null) return false;
      ctx.prepared = prepared;
    }
    return ctx.mayProceed() &&
        await native.confirm(ctx.evidence.counter) &&
        ctx.mayProceed() &&
        coordinator.sdkDigest == ctx.receipt.digest &&
        coordinator.committedRemaining() >= publishMinimum;
  }

  Future<void> _compensate(AsrAdoptionContext ctx) async {
    final p = ctx.prepared;
    // Before `finalizing` no successor receipt is durable: an unsettled
    // compensation leaves the pending barrier/freeze, which keep denying.
    if (p != null) await capture.compensate(p, finished: false);
  }

  /// §7.5.1 after a confirmed `finalizing{awaiting}`. Failures here never sign
  /// the user out: they leave Cloud capture restrictive/pending-enable. B2: the
  /// record leaves `finalizing` only once the successor is settled; otherwise it
  /// stays (generic capture reconciliation blocked) for the ordered
  /// reconciliation of [reconcileSuccessorFinalization].
  Future<void> _finalize(AsrAdoptionContext ctx, AsrPreparedSuccessor p) async {
    final r = ctx.receipt;
    Future<void> settle({required bool finished}) async {
      if (await capture.compensate(p, finished: finished)) {
        await coordinator.completeAdoption(r);
      }
    }

    if (!ctx.mayProceed() ||
        !await coordinator.writeFinish(r, FinishState.dispatched)) {
      return settle(finished: false);
    }
    // v7.2: synchronous recheck with no await before the SE4 channel call.
    if (!ctx.mayProceed()) return settle(finished: false);
    final finish = await capture.finish(p);
    if (finish == 'notExecuted') return settle(finished: false);
    if (finish != 'confirmed') return settle(finished: true);
    if (!await coordinator.writeFinish(r, FinishState.confirmed) ||
        !ctx.authority.ownsCleanup ||
        !ctx.mayProceed() ||
        !await capture.clearDart(p)) {
      // A loss after a confirmed finish retires G' (§7.5.1).
      return settle(finished: true);
    }
    // B2: a loss during the awaited clearance retires G' as well.
    if (!ctx.authority.ownsCleanup || !ctx.mayProceed()) {
      return settle(finished: true);
    }
    if (await coordinator.completeAdoption(r)) {
      await capture.reconcile(ctx.owner);
    }
  }

  /// §11.4 failure after withdrawal, bound to cleanup ownership.
  Future<AsrOutcome> _failAfterWithdrawal(
      AsrAdoptionContext ctx, Future<void> Function() release) async {
    if (ctx.authority.ownsCleanup &&
        coordinator.store.committed?.lifecycle == ctx.receipt.lifecycle) {
      // 1. synchronously, before anything else.
      gate.terminalDeny();
      try {
        // 2. compensation, signed-out scope, AdoptionFailed.
        await _compensate(ctx);
        await host.failAfterWithdrawal(ctx.owner);
        await coordinator.writeAdoption(ctx.receipt, AdoptionState.failed);
      } catch (_) {
        // The terminal denial of step 1 still holds when the hold is released.
      }
    }
    // 3. release exclusion and hold.
    await release();
    return _stop('failed_after_withdrawal', AsrOutcome.signInRequired);
  }

  /// Phase 4c B2: the adoption whose `finalizing` write is unresolved; it
  /// keeps its exclusion until decided.
  AsrAdoptionContext? _unresolvedAdoption;

  /// Whether an adoption still awaits its durable decision.
  bool get adoptionUnresolved => _unresolvedAdoption != null;

  /// Decides [_unresolvedAdoption] from the durable record: `finalizing`
  /// releases the exclusion and leaves the successor to the ordered
  /// reconciliation (never an automatic finish of `awaiting`); anything else is
  /// the failure after withdrawal. False while still unreadable.
  Future<bool> _resolveUnsettledAdoption() async {
    final ctx = _unresolvedAdoption!;
    final r = ctx.receipt;
    switch (await coordinator.checkAdoption(r, AdoptionState.finalizing)) {
      case AdoptionCheck.unresolved:
        return false;
      case AdoptionCheck.confirmed:
        _unresolvedAdoption = null;
        coordinator.releaseAsrExclusion(r.opId);
        return true;
      case AdoptionCheck.notInState:
        _unresolvedAdoption = null;
        await _failAfterWithdrawal(
            ctx, () async => coordinator.releaseAsrExclusion(r.opId));
        return true;
    }
  }

  Future<bool>? _reconciling;

  /// The owner whose committed record is still `finalizing` (B2), or null.
  String? get unsettledFinalizationOwner {
    final c = coordinator.store.committed;
    return c?.adoption?.state == AdoptionState.finalizing ? c!.owner : null;
  }

  /// §7.5.2: a record loaded in `finalizing` is reconciled before any generic
  /// capture reconciliation. Never an automatic finish for `awaiting`. True
  /// when nothing is left unsettled; false keeps the record `finalizing` (and
  /// generic capture reconciliation blocked) for a later attempt. One at a
  /// time.
  Future<bool> reconcileSuccessorFinalization(String owner) =>
      _reconciling ??= _reconcileFinalization(owner)
          .whenComplete(() => _reconciling = null);

  Future<bool> _reconcileFinalization(String owner) async {
    final c = coordinator.store.committed;
    final a = c?.adoption;
    if (c == null || a == null || c.owner != owner) return true;
    if (a.state != AdoptionState.finalizing) return true;
    final r = RefreshReceipt(
      opId: a.opId,
      lifecycle: c.lifecycle,
      seq: c.seq,
      digest: c.digest,
      predecessorDigest: c.digest,
      sdkBaseline: coordinator.sdkBaseline,
      owner: owner,
      intentSeq: coordinator.intentSeq,
    );
    final s = a.successor;
    if (s == null) return coordinator.completeAdoption(r);
    final AsrPreparedSuccessor? p;
    try {
      p = await capture.recover(owner, s);
    } catch (_) {
      // Unreadable (§7.5.2): before dispatch the native barrier still denies;
      // once the finish may have run, G' is retired exactly — never left ON
      // with Dart disagreeing. Completion waits for a readable state.
      if (s.finish != FinishState.awaiting) {
        await capture.retireOrphan(owner, s);
      }
      return false;
    }
    // Phase 4c B2: a record still `finalizing` here means the op that
    // dispatched the finish did not complete — possibly because a loss made
    // retiring G' mandatory, which the record cannot tell apart. So a finish
    // that may have run is ALWAYS retired, never cleared to ON, however native
    // reports it now: a retirement a loss required stays required across
    // retries and restarts.
    if (p == null) {
      // No pending left: exactly G' is retired first.
      return await capture.retireOrphan(owner, s) &&
          await coordinator.completeAdoption(r);
    }
    final bool settled;
    switch (s.finish) {
      case FinishState.awaiting:
        settled = await capture.compensate(p, finished: false);
      case FinishState.dispatched:
        settled = await capture.inspect(p) == 'notExecuted'
            ? await capture.compensate(p, finished: false)
            : await capture.compensate(p, finished: true);
      case FinishState.confirmed:
        settled = await capture.compensate(p, finished: true);
    }
    return settled && await coordinator.completeAdoption(r);
  }

  // ── triggers (§8) ────────────────────────────────────────────────────────

  static const List<Duration> backoff = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 60),
  ];
  Timer? _retry;
  int _attempt = 0;

  /// A trigger (cold start after the first frame, resume): runs now and, while
  /// the user stays in local read after an eligible attempt, retries on the
  /// backoff while resumed.
  void trigger() {
    _retry?.cancel();
    _retry = null;
    unawaited(run().then(_afterRun, onError: (Object _) {}));
  }

  void _afterRun(AsrOutcome outcome) {
    final transientSkip = outcome == AsrOutcome.skipped &&
        host.localReadOwner != null &&
        const {'native_evidence', 'cloud', 'elig', 'indeterminate'}.contains(lastStop);
    if ((outcome != AsrOutcome.stayedLocalRead && !transientSkip &&
            unsettledFinalizationOwner == null &&
            _unresolvedAdoption == null) ||
        !host.resumed) {
      _attempt = 0;
      return;
    }
    final delay = backoff[_attempt.clamp(0, backoff.length - 1)];
    _attempt++;
    _retry = Timer(delay, () {
      _retry = null;
      if (host.resumed) trigger();
    });
  }

  /// Leaving the foreground (inactive, hidden, paused, detached) cancels any
  /// pending retry and latches loss for the running op synchronously (B5): it
  /// cancels the exchange before acceptance (decision (a)) and the op can never
  /// continue, even when the app resumes before its next check. The op keeps
  /// cleanup ownership.
  void onBackground() {
    _retry?.cancel();
    _retry = null;
    final authority = _authority;
    if (authority == null) return;
    authority.mayContinue = false;
    coordinator.cancelActive('background');
  }

  void dispose() {
    _retry?.cancel();
    _retry = null;
    _finishPresentation();
  }
}

/// Production host: AppSession, the process lifecycle and the bound client.
class AppSessionAsrHost implements AsrSessionHost {
  AppSessionAsrHost(this.session, this.client);
  final AppSession session;
  final supabase.SupabaseClient client;

  @override
  bool get resumed =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  @override
  bool get foreground => resumed ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.inactive;
  @override
  String? get localReadOwner => session.asrLocalReadOwner;
  @override
  Future<String?> eligibilityDenial(String owner) =>
      session.asrEligibilityDenial(owner);
  @override
  String? processDenial(String owner, {required bool adopting}) =>
      session.asrProcessDenial(owner, adopting: adopting);
  @override
  Future<AsrAdoptResult> adopt(AsrAdoptionContext ctx) =>
      session.asrAdopt(ctx, client);
  @override
  Future<void> failAfterWithdrawal(String owner) async {
    try {
      await session.asrFailAfterWithdrawal(owner);
    } catch (_) {}
  }
}

/// Production capture lane: the registration service's successor enable.
class RegistrationAsrCapture implements AsrCapturePort {
  RegistrationAsrCapture(this._registration, this.gate, this.session,
      {required Future<bool> Function() consentAccepted})
      : _consentAccepted = consentAccepted;

  /// The registration service of the CURRENT scope (the writable one once
  /// adoption opened it).
  final CaptureDeviceRegistrationService? Function() _registration;
  final CloudEgressGate gate;
  final AppSession session;
  final Future<bool> Function() _consentAccepted;

  CaptureDeviceRegistrationService get registration {
    final r = _registration();
    if (r == null) throw StateError('no_registration');
    return r;
  }

  @override
  Future<bool> dartEgressOn(String owner) async {
    try {
      final seen = await gate.store.readDartOwnerLayers(owner);
      return !seen.uncertain &&
          seen.records.length == 2 &&
          seen.records.every((r) =>
              r.state == EgressState.on &&
              r.ownerUid == owner &&
              r.transitionGeneration ==
                  seen.records.first.transitionGeneration &&
              r.reservedVersion == seen.records.first.reservedVersion);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> dartEgressOff(String owner) =>
      gate.dartLayersVerifiedOff(owner, allowAbsent: true);

  @override
  Future<bool> consentAccepted(String owner) async {
    try {
      return await _consentAccepted();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<AsrPreparedSuccessor?> prepare(AsrAdoptionContext ctx) async {
    final g = ctx.successorGeneration;
    final e = ctx.successorOwnerEpoch;
    final registration = _registration();
    if (g == null || e == null || registration == null) return null;
    final s = await registration.prepareExpirySuccessor(
      owner: ctx.owner,
      evidenceId: ctx.evidence.evidence!.evidenceId,
      successorGeneration: g,
      ownerEpoch: e,
      counter: ctx.evidence.counter,
      mayProceed: ctx.mayProceed,
      causeAuthority: ctx.authority,
    );
    if (s == null) return null;
    ctx.evidence.counter = s.counter;
    // Later fences of this lifetime name the successor's transition.
    if (!session.asrRebindNativeLifetime(ctx.owner, s.binding)) {
      await registration.compensateExpirySuccessor(s, finished: false);
      return null;
    }
    return _wrap(s);
  }

  static AsrPreparedSuccessor _wrap(ExpirySuccessor s) => AsrPreparedSuccessor(
      successorGeneration: s.successorGeneration,
      ownerEpoch: s.ownerEpoch,
      pendingOpId: s.binding.operationId,
      handle: s);

  @override
  Future<String> finish(AsrPreparedSuccessor p) =>
      registration.finishExpirySuccessor(p.handle! as ExpirySuccessor);
  @override
  Future<bool> clearDart(AsrPreparedSuccessor p) =>
      registration.clearExpirySuccessor(p.handle! as ExpirySuccessor);
  @override
  Future<bool> compensate(AsrPreparedSuccessor p,
      {required bool finished}) async {
    try {
      return await registration.compensateExpirySuccessor(
          p.handle! as ExpirySuccessor,
          finished: finished);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<AsrPreparedSuccessor?> recover(String owner, SuccessorRecord s) async {
    final found = await registration.recoverExpirySuccessor(
        owner: owner,
        successorGeneration: s.generation,
        pendingOpId: s.pendingOpId);
    return found == null ? null : _wrap(found);
  }

  @override
  Future<bool> retireOrphan(String owner, SuccessorRecord s) =>
      registration.retireOrphanSuccessor(
          owner: owner,
          successorGeneration: s.generation,
          pendingOpId: s.pendingOpId);

  @override
  Future<String> inspect(AsrPreparedSuccessor p) =>
      registration.inspectExpirySuccessor(p.handle! as ExpirySuccessor);
  @override
  Future<void> reconcile(String owner) async {
    try {
      await gate.refresh();
    } catch (_) {}
  }
}
