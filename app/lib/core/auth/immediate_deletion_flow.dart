import 'dart:convert';

import 'apple_deletion_reauth.dart';
import 'immediate_account_deletion.dart';
import 'prepared_immediate_deletion_gateway.dart';

/// What the Delete Account screen may honestly say. Only [DeletionFlowCompleted]
/// is a finished deletion: it needs operation-bound remote completion AND a
/// confirmed removal of the original local replica. Everything else is either
/// work still pending, an unknown outcome, or a refusal; none of them touches
/// local data.
sealed class DeletionFlowResult {
  const DeletionFlowResult();
}

final class DeletionFlowCompleted extends DeletionFlowResult {
  const DeletionFlowCompleted();
}

/// The server finished deleting the account but removal of the local replica on
/// this device did not confirm. The remote deletion is NOT in doubt; the local
/// cleanup is.
final class DeletionFlowLocalCleanupPending extends DeletionFlowResult {
  const DeletionFlowLocalCleanupPending();
}

/// Accepted, in progress or already pending server-side. Not deleted yet.
final class DeletionFlowPending extends DeletionFlowResult {
  const DeletionFlowPending();
}

/// The outcome could not be confirmed. [canCheckStatus] says whether a
/// read-only status check on the same operation can still resolve it.
final class DeletionFlowUnconfirmed extends DeletionFlowResult {
  const DeletionFlowUnconfirmed({required this.canCheckStatus});
  final bool canCheckStatus;
}

/// Nothing was deleted. Raised only before a deletion request was sent.
final class DeletionFlowFailed extends DeletionFlowResult {
  const DeletionFlowFailed({required this.retryable});
  final bool retryable;
}

/// The server refused the confirmation before anything could commit (invalid
/// or expired challenge/Apple proof, ...). Nothing was deleted and the failed
/// operation was abandoned: a fresh attempt is allowed.
final class DeletionFlowRejected extends DeletionFlowResult {
  const DeletionFlowRejected();
}

final class DeletionFlowAdminBlocked extends DeletionFlowResult {
  const DeletionFlowAdminBlocked();
}

final class DeletionFlowRateLimited extends DeletionFlowResult {
  const DeletionFlowRateLimited();
}

/// The person dismissed the Apple sheet. No request was sent.
final class DeletionFlowCancelled extends DeletionFlowResult {
  const DeletionFlowCancelled();
}

/// One captured deletion operation.
abstract interface class DeletionFlowSession {
  /// challenge -> Apple re-authentication -> request, then (only on verified
  /// remote completion) original-owner local removal.
  Future<DeletionFlowResult> confirm();

  /// Read-only status check of an operation that already sent (or restored) a
  /// request. Never starts a new deletion.
  Future<DeletionFlowResult> checkStatus();

  /// After remote completion whose original local removal did not confirm:
  /// re-verifies completion by a read-only status call (fresh evidence; the
  /// one-use evidence of the first attempt is never reused) and retries the
  /// ORIGINAL owner's local removal. Never sends a request or challenge.
  Future<DeletionFlowResult> retryLocalCleanup();

  /// Releases a session the person abandoned before confirming.
  void close();
}

abstract interface class ImmediateDeletionFlow {
  /// Captures a NEW operation for the current admitted account, or null.
  Future<DeletionFlowSession?> begin();

  /// Captures the current account's EXISTING pending operation, or null.
  Future<DeletionFlowSession?> resume();

  /// Captures the current account's completed-but-not-locally-removed
  /// operation (see [DeletionFlowSession.retryLocalCleanup]), or null.
  Future<DeletionFlowSession?> resumeLocalCleanup();
}

/// App-start recovery: status-only. Runs only for the CURRENT admitted owner's
/// own receipt, sends no request or challenge, and returns the outcome of the
/// status check (and, if completed, of the original local removal), or null
/// when there is nothing to recover. Any non-completed result is silent.
Future<DeletionFlowResult?> recoverImmediateDeletionAtStart(
    ImmediateDeletionFlow flow) async {
  try {
    final pending = await flow.resume();
    if (pending != null) return await pending.checkStatus();
    final cleanup = await flow.resumeLocalCleanup();
    if (cleanup != null) return await cleanup.retryLocalCleanup();
  } catch (_) {}
  return null;
}

/// Fail-closed flow for builds/scopes that cannot reach the backend.
class UnavailableDeletionFlow implements ImmediateDeletionFlow {
  const UnavailableDeletionFlow();
  @override
  Future<DeletionFlowSession?> begin() async => null;
  @override
  Future<DeletionFlowSession?> resume() async => null;
  @override
  Future<DeletionFlowSession?> resumeLocalCleanup() async => null;
}

abstract interface class EmailProofDeletionSession
    implements DeletionFlowSession {
  Future<DeletionFlowResult> confirmWithEmailProof(
      Future<String?> Function() readCode);
}

class GatewayDeletionFlow implements ImmediateDeletionFlow {
  GatewayDeletionFlow(
      {required PreparedImmediateDeletionGateway gateway,
      required AppleDeletionReauth apple,
      this.emailOnly,
      this.googleProof})
      : _gateway = gateway,
        _apple = apple;
  final PreparedImmediateDeletionGateway _gateway;
  final AppleDeletionReauth _apple;
  final bool? emailOnly;
  final Future<AppleReauthResult> Function(String nonce)? googleProof;

  @override
  Future<DeletionFlowSession?> begin() async {
    final op = await _gateway.prepare();
    return op == null ? null : _GatewaySession(this, op, false);
  }

  @override
  Future<DeletionFlowSession?> resume() async {
    final op = await _gateway.resumePending();
    return op == null ? null : _GatewaySession(this, op, true);
  }

  @override
  Future<DeletionFlowSession?> resumeLocalCleanup() async {
    final op = await _gateway.resumeLocalCleanup();
    return op == null ? null : _GatewaySession(this, op, true);
  }
}

final class _GatewaySession implements EmailProofDeletionSession {
  _GatewaySession(this._flow, this._op, this._requested);
  final GatewayDeletionFlow _flow;
  PreparedImmediateDeletionGateway get _gateway => _flow._gateway;
  final PreparedDeletionOperation _op;

  /// True once a deletion request was (or may have been) sent, or restored.
  bool _requested;
  bool _busy = false;
  bool _cleanupUsed = false;

  @override
  Future<DeletionFlowResult> confirm() => _confirm(null);

  @override
  Future<DeletionFlowResult> confirmWithEmailProof(
          Future<String?> Function() readCode) =>
      _confirm(readCode);

  Future<DeletionFlowResult> _confirm(
      Future<String?> Function()? readCode) async {
    if (_requested) return checkStatus();
    if (_busy) return const DeletionFlowFailed(retryable: true);
    _busy = true;
    try {
      final challenge =
          await _gateway.challenge(_op, emailOnly: _flow.emailOnly);
      switch (challenge) {
        case PreparedChallengeUnavailable():
          return const DeletionFlowFailed(retryable: false);
        case PreparedChallengeFailed(:final retryable):
          return DeletionFlowFailed(retryable: retryable);
        case PreparedChallengeRefused(:final reason):
          return switch (reason) {
            ImmediateChallengeRefusal.adminBlocked =>
              const DeletionFlowAdminBlocked(),
            ImmediateChallengeRefusal.rateLimited =>
              const DeletionFlowRateLimited(),
            ImmediateChallengeRefusal.alreadyPending =>
              const DeletionFlowPending(),
          };
        case PreparedChallengeIssued():
          final reauth = await switch (challenge.method) {
            DeletionProofMethod.apple =>
              _flow._apple.reauthenticate(nonce: challenge.nonce),
            DeletionProofMethod.google =>
              _flow.googleProof?.call(challenge.nonce) ??
                  Future.value(const AppleReauthFailed()),
            DeletionProofMethod.email => _emailProof(readCode),
          };
          switch (reauth) {
            case AppleReauthCancelled():
              _gateway.close(_op);
              return const DeletionFlowCancelled();
            case AppleReauthFailed():
              return const DeletionFlowFailed(retryable: true);
            case AppleReauthGranted():
              _requested = true;
              return await _settle(await _gateway.request(_op,
                  challengeId: challenge.challengeId,
                  challengeResponse: reauth.challengeResponse));
          }
      }
    } finally {
      _busy = false;
    }
  }

  Future<AppleReauthResult> _emailProof(
      Future<String?> Function()? readCode) async {
    if (readCode == null) return const AppleReauthFailed();
    final code = await readCode();
    return code == null
        ? const AppleReauthCancelled()
        : AppleReauthGranted(jsonEncode({'proof': 'email', 'code': code}));
  }

  @override
  Future<DeletionFlowResult> checkStatus() async {
    if (_busy) return const DeletionFlowUnconfirmed(canCheckStatus: true);
    _busy = true;
    try {
      return await _settle(await _gateway.recover(_op));
    } finally {
      _busy = false;
    }
  }

  @override
  Future<DeletionFlowResult> retryLocalCleanup() async {
    if (_busy) return const DeletionFlowLocalCleanupPending();
    _busy = true;
    try {
      var op = _op;
      if (!op.isLocalCleanup || _cleanupUsed) {
        // Any earlier operation's evidence is spent; capture the retained
        // completed receipt of the CURRENT owner as a fresh operation.
        final fresh = await _gateway.resumeLocalCleanup();
        if (fresh == null) return const DeletionFlowLocalCleanupPending();
        op = fresh;
      }
      _cleanupUsed = true;
      final outcome = await _gateway.recover(op);
      return outcome is PreparedDeletionRemoteCompletion
          ? await _settle(outcome)
          : const DeletionFlowLocalCleanupPending();
    } finally {
      _busy = false;
    }
  }

  @override
  void close() => _gateway.close(_op);

  Future<DeletionFlowResult> _settle(PreparedDeletionOutcome outcome) async {
    switch (outcome) {
      case PreparedDeletionRemoteCompletion():
        // The exact evidence, once; local removal is bound to the ORIGINAL
        // owner, so an account switched in the meantime is never touched.
        final local = await _gateway.removeOriginalLocalReplica(outcome);
        return local ==
                PreparedLocalRemovalOutcome.originalLocalRemovalConfirmed
            ? const DeletionFlowCompleted()
            : const DeletionFlowLocalCleanupPending();
      case PreparedDeletionRejected(:final code):
        return code == 'admin_self_delete_blocked'
            ? const DeletionFlowAdminBlocked()
            : const DeletionFlowRejected();
      case PreparedDeletionPending():
        return const DeletionFlowPending();
      case PreparedDeletionUnconfirmed(:final reason):
        return DeletionFlowUnconfirmed(
            canCheckStatus: switch (reason) {
          PreparedDeletionUnconfirmedReason.protocolUnconfirmed ||
          PreparedDeletionUnconfirmedReason.receiptStoreUnavailable ||
          PreparedDeletionUnconfirmedReason.receiptChanged =>
            true,
          PreparedDeletionUnconfirmedReason.staleContext ||
          PreparedDeletionUnconfirmedReason.foreignOperation ||
          PreparedDeletionUnconfirmedReason.operationClosed =>
            false,
        });
    }
  }
}
