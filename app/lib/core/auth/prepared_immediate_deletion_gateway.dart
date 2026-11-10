import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../privacy/cloud_egress_gate.dart';
import '../session/account_scope.dart';
import '../session/admission_authority.dart';
import '../session/app_session.dart';
import 'immediate_account_deletion.dart';
import 'immediate_deletion_receipt_store.dart';

/// Operation-bound immediate-deletion adapter. This is deliberately not
/// AccountDeletionGateway. It is consumed by GatewayDeletionFlow (provider/UI
/// registration lives there); no sign-out or polling belongs here. Original
/// local removal is a separate, one-use evidence consumer. SDK wiring is trusted: the public host proof cannot expose its private
/// issuer client for an independent object-identity check. Activation must qualify
/// that wiring separately. Custody remains foreground-isolate scoped, not CAS.
final class PreparedImmediateDeletionGateway {
  PreparedImmediateDeletionGateway({
    required AppSession session,
    required AccountScopeHost host,
    required SupabaseClient client,
    required ImmediateDeletionReceiptStore store,
    required http.Client transport,
    required Uri functionUrl,
    CloudEgressGate? gate,
    Duration requestTimeout = kAccountControlTtl,
    String? apiKey,
    bool retainReceiptUntilLocalRemoval = false,
  })  : _retain = retainReceiptUntilLocalRemoval,
        _session = session,
        _host = host,
        _client = client,
        _store = store,
        _transport = transport,
        _functionUrl = functionUrl,
        _gate = gate ?? CloudEgressGate.instance,
        _requestTimeout = requestTimeout,
        _apiKey = apiKey;

  final AppSession _session;
  final AccountScopeHost _host;
  final SupabaseClient _client;
  final ImmediateDeletionReceiptStore _store;
  final http.Client _transport;
  final Uri _functionUrl;
  final CloudEgressGate _gate;
  final Duration _requestTimeout;
  final String? _apiKey;

  /// True: a completed receipt keeps its secret until the ORIGINAL local
  /// removal is confirmed, so a failed removal can be retried (or resumed after
  /// a restart) with fresh evidence from a status call. False: the legacy
  /// behaviour, where the secret is erased as soon as completion is persisted.
  final bool _retain;
  final Set<Future<void>> _pending = {};
  final List<(Object, StackTrace)> _unexpected = [];

  /// Capture happens before any await. Missing authority is never recaptured.
  Future<PreparedDeletionOperation?> prepare({bool Function()? restrict}) =>
      _prepare(mode: _Mode.fresh, restrict: restrict);

  /// Explicitly selects the captured admitted owner's existing pending custody.
  /// Signed-out recovery remains the existing Recovery.restore API, unchanged.
  Future<PreparedDeletionOperation?> resumePending(
          {bool Function()? restrict}) =>
      _prepare(mode: _Mode.resume, restrict: restrict);

  /// Captures the current admitted owner's COMPLETED receipt whose original
  /// local removal is not yet confirmed. It can only re-verify completion by
  /// the read-only status call and then feed [removeOriginalLocalReplica]; it
  /// never authorizes a request. Null for any other owner or when nothing is
  /// retained.
  Future<PreparedDeletionOperation?> resumeLocalCleanup(
          {bool Function()? restrict}) =>
      _prepare(mode: _Mode.cleanup, restrict: restrict);

  Future<PreparedDeletionOperation?> _prepare({
    required _Mode mode,
    bool Function()? restrict,
  }) {
    final resume = mode != _Mode.fresh;
    final original = _capture(restrict);
    return _own(() async {
      if (original == null) {
        return null;
      }
      try {
        final record = await _store.serialized(() async {
          if (!original.current) {
            throw const _BindingLost();
          }
          return _store.load(original.binding.owner!);
        });
        if (!original.current) {
          return null;
        }
        if (mode == _Mode.cleanup) {
          if (!_retain ||
              record == null ||
              record.phase != ImmediateDeletionPhase.completed ||
              record.receiptSecret == null) {
            return null;
          }
        } else if (record?.phase == ImmediateDeletionPhase.completed ||
            (resume ? record == null : record != null)) {
          return null;
        }
        final operation = PreparedDeletionOperation._(
          this,
          original,
          record?.operationId ?? generateReceiptSecret(),
          record?.receiptSecret,
          resume,
          cleanup: mode == _Mode.cleanup,
        );
        final observed = _OperationReceiptStore(_store, operation);
        operation._observed = observed;
        operation._recovery = ImmediateAccountDeletionRecovery(
          store: observed,
          transport: _transport,
          functionUrl: _functionUrl,
          gate: _gate,
          requestTimeout: _requestTimeout,
          apiKey: _apiKey,
          retireOnComplete: !_retain,
          captureBinding: () async => original.binding,
          isBindingCurrent: (binding) =>
              identical(binding, original.binding) && original.current,
          newOperationId: () => operation._operationId,
          newReceipt: () => operation._secret ??= generateReceiptSecret(),
        );
        return original.current ? operation : null;
      } catch (_) {
        return null;
      }
    });
  }

  _OriginalBinding? _capture(bool Function()? restrict) {
    try {
      final admission = _session.captureDatabaseHostAdmission();
      final origin = _session.captureCallbackOrigin();
      final scope = _host.current;
      final sdk = _client.auth.currentSession;
      if (admission == null ||
          origin == null ||
          scope == null ||
          sdk == null ||
          scope.isLocalRead ||
          scope.uid != admission.uid ||
          origin.uid != admission.uid ||
          sdk.user.id != admission.uid ||
          sdk.isExpired ||
          sdk.accessToken.isEmpty ||
          !identical(scope.database, admission.database) ||
          scope.generation != admission.scopeGeneration) {
        return null;
      }
      final original = _OriginalBinding(
        admission,
        origin,
        _host,
        scope,
        _client,
        _gate,
        _gate.epoch,
        ImmediateDeletionBinding(
            owner: admission.uid,
            lifecycle: origin.epoch,
            bearerToken: sdk.accessToken),
        restrict,
      );
      return original.current ? original : null;
    } catch (_) {
      return null;
    }
  }

  /// Challenge/recent-auth acquisition is an external prerequisite, not proof
  /// manufactured by this adapter. Only this handle's first request can use it.
  Future<PreparedDeletionOutcome> request(
    PreparedDeletionOperation operation, {
    required String challengeId,
    required String challengeResponse,
  }) =>
      _enqueue(operation, () async {
        if (operation._attempted || operation._resumed) {
          return const PreparedDeletionUnconfirmed._(
              PreparedDeletionUnconfirmedReason.operationClosed);
        }
        operation._attempted = true;
        return _exchange(
            operation,
            () => operation._recovery.request(
                challengeId: challengeId,
                challengeResponse: challengeResponse),
            rejectable: true);
      });

  /// Fetches one fresh re-authentication challenge for this exact operation. It
  /// writes no receipt and starts no deletion; only an operation that has not
  /// yet sent a request (and is not a resumed one) can ask. A challenge that
  /// arrives after the original binding was lost is discarded.
  Future<PreparedChallengeOutcome> challenge(
      PreparedDeletionOperation operation, {bool? emailOnly}) {
    if (!identical(operation._issuer, this)) {
      return Future.value(const PreparedChallengeUnavailable._());
    }
    final prior = operation._tail;
    final result = _own<PreparedChallengeOutcome>(() async {
      await prior;
      if (operation._closed ||
          operation._attempted ||
          operation._resumed ||
          !operation._original.current) {
        return const PreparedChallengeUnavailable._();
      }
      final issued = await operation._recovery.challenge(emailOnly: emailOnly);
      if (operation._closed ||
          operation._attempted ||
          !operation._original.current) {
        return const PreparedChallengeUnavailable._();
      }
      return switch (issued) {
        ImmediateChallengeIssued() => PreparedChallengeIssued._(
            challengeId: issued.challengeId,
            nonce: issued.nonce,
            expiresAtMs: issued.expiresAtMs,
            method: issued.method),
        ImmediateChallengeRefused() => PreparedChallengeRefused._(issued.reason),
        ImmediateChallengeFailed() => PreparedChallengeFailed._(
            retryable: issued.retryable, code: issued.code),
      };
    });
    operation._tail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  /// No challenge, new operation or authorization POST is created by recovery.
  Future<PreparedDeletionOutcome> recover(
          PreparedDeletionOperation operation) =>
      _enqueue(operation, () async {
        if (!operation._attempted && !operation._resumed) {
          return const PreparedDeletionUnconfirmed._(
              PreparedDeletionUnconfirmedReason.operationClosed);
        }
        return _exchange(operation, () async {
          final owner = operation._original.binding.owner!;
          final handle = operation._cleanup
              ? await operation._recovery
                  .restoreCompletedAwaitingCleanup(owner: owner)
              : await operation._recovery.restore(owner: owner);
          if (handle == null) {
            return const ImmediateDeletionFailed('',
                retryable: false, code: 'operation_closed');
          }
          return operation._recovery.recover(handle);
        });
      });

  Future<PreparedDeletionOutcome> _enqueue(PreparedDeletionOperation operation,
      Future<PreparedDeletionOutcome> Function() action) {
    if (!identical(operation._issuer, this)) {
      return Future.value(const PreparedDeletionUnconfirmed._(
          PreparedDeletionUnconfirmedReason.foreignOperation));
    }
    // Own queued work before invoking it. Never place network in session drains.
    final prior = operation._tail;
    final result = _own(() async {
      await prior;
      if (operation._closed) {
        return const PreparedDeletionUnconfirmed._(
            PreparedDeletionUnconfirmedReason.operationClosed);
      }
      if (!operation._original.current) {
        return const PreparedDeletionUnconfirmed._(
            PreparedDeletionUnconfirmedReason.staleContext);
      }
      return action();
    });
    operation._tail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  /// Server codes returned BEFORE anything can commit: authorization precedes
  /// acceptance and SQL acceptance refuses before inserting a job. Everything
  /// else (challenge_replayed, idempotency_conflict, acceptance_unknown,
  /// store/authorization unavailable, 5xx, timeouts, network, malformed bodies)
  /// may follow an accepted request and stays unconfirmed.
  static const Set<String> _definitiveRejections = {
    'unauthenticated',
    'invalid_request',
    'challenge_invalid',
    'challenge_expired',
    'apple_subject_mismatch',
    'admin_self_delete_blocked',
  };

  Future<PreparedDeletionOutcome> _exchange(PreparedDeletionOperation operation,
      Future<ImmediateDeletionResult> Function() invoke,
      {bool rejectable = false}) async {
    final observation = _ExchangeObservation();
    operation._observed._active = observation;
    try {
      // Recovery owns the shared store lock. An outer serialized call self-waits.
      final result = await invoke();
      if (!operation._original.current) {
        observation.lost = true;
      }
      if (operation._closed) {
        return const PreparedDeletionUnconfirmed._(
            PreparedDeletionUnconfirmedReason.operationClosed);
      }
      if (observation.mismatch) {
        return const PreparedDeletionUnconfirmed._(
            PreparedDeletionUnconfirmedReason.receiptChanged);
      }
      if (observation.lost) {
        return const PreparedDeletionUnconfirmed._(
            PreparedDeletionUnconfirmedReason.staleContext);
      }
      if (result is ImmediateDeletionCompleted &&
          observation.completedVerified &&
          operation._secret != null &&
          result.receiptSecret.isNotEmpty &&
          result.receiptSecret == operation._secret) {
        operation._closed = true;
        final evidence = PreparedDeletionRemoteCompletion._(operation);
        operation._remoteCompletion = evidence;
        return evidence;
      }
      if (rejectable &&
          result is ImmediateDeletionFailed &&
          !result.lookupReceipt &&
          _definitiveRejections.contains(result.code)) {
        return await _abandonRejected(operation, result.code);
      }
      if (result is ImmediateDeletionAccepted) {
        return const PreparedDeletionPending._(
            PreparedDeletionPendingKind.accepted);
      }
      if (result is ImmediateDeletionInProgress) {
        return const PreparedDeletionPending._(
            PreparedDeletionPendingKind.inProgress);
      }
      return PreparedDeletionUnconfirmed._(result is ImmediateDeletionFailed &&
              result.code == 'receipt_store_unavailable'
          ? PreparedDeletionUnconfirmedReason.receiptStoreUnavailable
          : PreparedDeletionUnconfirmedReason.protocolUnconfirmed);
    } finally {
      operation._observed._active = null;
    }
  }

  /// Abandons the receipt of an operation the server definitively refused, so a
  /// new operation may start. Only the exact record this operation wrote, still
  /// bound to its owner and still current, is removed (under the store lock).
  Future<PreparedDeletionOutcome> _abandonRejected(
      PreparedDeletionOperation operation, String code) async {
    final owner = operation._original.binding.owner!;
    try {
      final outcome = await _store.serialized(() async {
        if (!operation._original.current) {
          return const PreparedDeletionUnconfirmed._(
              PreparedDeletionUnconfirmedReason.staleContext);
        }
        final record = await _store.load(owner);
        if (!operation._original.current) {
          return const PreparedDeletionUnconfirmed._(
              PreparedDeletionUnconfirmedReason.staleContext);
        }
        if (record == null ||
            record.owner != owner ||
            record.operationId != operation._operationId ||
            record.receiptSecret != operation._secret ||
            record.phase != ImmediateDeletionPhase.mayHaveBeenSent) {
          return const PreparedDeletionUnconfirmed._(
              PreparedDeletionUnconfirmedReason.receiptChanged);
        }
        await _store.deleteVerified(owner);
        return PreparedDeletionRejected._(code);
      });
      if (outcome is PreparedDeletionRejected) {
        operation._closed = true;
      }
      return outcome;
    } catch (_) {
      return const PreparedDeletionUnconfirmed._(
          PreparedDeletionUnconfirmedReason.receiptStoreUnavailable);
    }
  }

  /// Erases the secret of a completed receipt, but only that exact operation's
  /// and only after its original local removal was confirmed. Best effort: a
  /// leftover completed receipt is harmless (it only ever allows a read-only
  /// status call).
  Future<void> _retire(PreparedDeletionOperation operation) async {
    if (!_retain) return;
    final owner = operation._original.binding.owner!;
    try {
      await _store.serialized(() async {
        final record = await _store.load(owner);
        if (record == null ||
            record.owner != owner ||
            record.operationId != operation._operationId ||
            record.phase != ImmediateDeletionPhase.completed ||
            record.receiptSecret == null ||
            record.receiptSecret != operation._secret) {
          return;
        }
        await _store.writeVerified(ImmediateDeletionReceipt(
            owner: owner,
            operationId: record.operationId,
            receiptSecret: null,
            phase: ImmediateDeletionPhase.completed));
      });
    } catch (_) {}
  }

  /// Consume exactly this gateway's issued completion for its original scope.
  /// The result says only what this local operation actually confirmed.
  Future<PreparedLocalRemovalOutcome> removeOriginalLocalReplica(
      PreparedDeletionRemoteCompletion evidence) {
    final operation = evidence.operation;
    if (!identical(operation._issuer, this) ||
        !identical(operation._remoteCompletion, evidence) ||
        operation._localConsumed) {
      return Future.value(PreparedLocalRemovalOutcome.operationUnavailable);
    }
    // Burn before the retained restriction predicate can reenter this gateway.
    operation._localConsumed = true;
    if (!operation._original.current) {
      return Future.value(PreparedLocalRemovalOutcome.staleBeforeAcceptance);
    }
    final accepted = _session.removePreparedOriginalLocalReplica(
        originalAdmission: operation._original.admission,
        originalOrigin: operation._original.origin);
    return _own(() async {
      try {
        final outcome = await accepted;
        if (outcome ==
            PreparedOriginalLocalRemovalOutcome.originalLocalRemovalConfirmed) {
          await _retire(operation);
        }
        return switch (outcome) {
          PreparedOriginalLocalRemovalOutcome.staleBeforeAcceptance =>
            PreparedLocalRemovalOutcome.staleBeforeAcceptance,
          PreparedOriginalLocalRemovalOutcome.operationUnavailable =>
            PreparedLocalRemovalOutcome.operationUnavailable,
          PreparedOriginalLocalRemovalOutcome.localRemovalIncomplete =>
            PreparedLocalRemovalOutcome.localRemovalIncomplete,
          PreparedOriginalLocalRemovalOutcome.originalLocalRemovalConfirmed =>
            PreparedLocalRemovalOutcome.originalLocalRemovalConfirmed,
        };
      } catch (_) {
        return PreparedLocalRemovalOutcome.localRemovalIncomplete;
      }
    });
  }

  /// Close delivery, not server execution or custody of an already-started call.
  void close(PreparedDeletionOperation operation) {
    if (!identical(operation._issuer, this)) {
      return;
    }
    operation._closed = true;
  }

  Future<T> _own<T>(Future<T> Function() start) {
    final terminal = Completer<void>();
    _pending.add(terminal.future);
    late Future<T> result;
    try {
      result = start();
    } catch (error, stack) {
      result = Future<T>.error(error, stack);
    }
    unawaited(result.then<void>((_) {
      _pending.remove(terminal.future);
      terminal.complete();
    }, onError: (Object error, StackTrace stack) {
      _unexpected.add((error, stack));
      _pending.remove(terminal.future);
      terminal.complete();
    }));
    return result;
  }

  /// Observes actual queued/running settlement. It sends and cancels nothing.
  Future<void> waitPendingWork() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
    if (_unexpected.isNotEmpty) {
      Error.throwWithStackTrace(_unexpected.first.$1, _unexpected.first.$2);
    }
  }
}

enum _Mode { fresh, resume, cleanup }

final class PreparedDeletionOperation {
  PreparedDeletionOperation._(this._issuer, this._original, this._operationId,
      this._secret, this._resumed,
      {bool cleanup = false})
      : _cleanup = cleanup;
  final PreparedImmediateDeletionGateway _issuer;
  final _OriginalBinding _original;
  final String _operationId;
  String? _secret;
  final bool _resumed;

  /// A re-verification of an already COMPLETED receipt; see resumeLocalCleanup.
  final bool _cleanup;
  bool _attempted = false;
  bool _closed = false;
  PreparedDeletionRemoteCompletion? _remoteCompletion;
  bool _localConsumed = false;
  Future<void> _tail = Future<void>.value();
  late _OperationReceiptStore _observed;
  late ImmediateAccountDeletionRecovery _recovery;
  bool get isLocalCleanup => _cleanup;
  @override
  String toString() => 'PreparedDeletionOperation';
}

sealed class PreparedChallengeOutcome {
  const PreparedChallengeOutcome._();
}

final class PreparedChallengeIssued extends PreparedChallengeOutcome {
  const PreparedChallengeIssued._(
      {required this.challengeId,
      required this.nonce,
      required this.expiresAtMs,
      required this.method})
      : super._();
  final String challengeId;
  final String nonce;
  final int expiresAtMs;
  final DeletionProofMethod method;
  @override
  String toString() => 'PreparedChallengeIssued';
}

final class PreparedChallengeRefused extends PreparedChallengeOutcome {
  const PreparedChallengeRefused._(this.reason) : super._();
  final ImmediateChallengeRefusal reason;
}

final class PreparedChallengeFailed extends PreparedChallengeOutcome {
  const PreparedChallengeFailed._({required this.retryable, required this.code})
      : super._();
  final bool retryable;
  final String code;
}

/// Stale binding, closed/foreign/resumed operation: no challenge was usable.
final class PreparedChallengeUnavailable extends PreparedChallengeOutcome {
  const PreparedChallengeUnavailable._() : super._();
}

enum PreparedLocalRemovalOutcome {
  staleBeforeAcceptance,
  operationUnavailable,
  localRemovalIncomplete,
  originalLocalRemovalConfirmed,
}

sealed class PreparedDeletionOutcome {
  const PreparedDeletionOutcome._();
}

enum PreparedDeletionPendingKind { accepted, inProgress }

final class PreparedDeletionPending extends PreparedDeletionOutcome {
  const PreparedDeletionPending._(this.kind) : super._();
  final PreparedDeletionPendingKind kind;
}

enum PreparedDeletionUnconfirmedReason {
  staleContext,
  foreignOperation,
  operationClosed,
  receiptChanged,
  receiptStoreUnavailable,
  protocolUnconfirmed,
}

final class PreparedDeletionUnconfirmed extends PreparedDeletionOutcome {
  const PreparedDeletionUnconfirmed._(this.reason) : super._();
  final PreparedDeletionUnconfirmedReason reason;
}

/// The server definitively refused the request before anything could commit,
/// and this operation's receipt was abandoned: a new operation may start.
final class PreparedDeletionRejected extends PreparedDeletionOutcome {
  const PreparedDeletionRejected._(this.code) : super._();
  final String code;
}

/// Remote protocol evidence for the original operation ONLY. This grants no
/// local erasure, auth mutation, navigation or user-visible deletion success.
final class PreparedDeletionRemoteCompletion extends PreparedDeletionOutcome {
  const PreparedDeletionRemoteCompletion._(this.operation) : super._();
  final PreparedDeletionOperation operation;
}

final class _OriginalBinding {
  _OriginalBinding(this.admission, this.origin, this.host, this.scope,
      this.client, this.gate, this.egressEpoch, this.binding, this.restrict);
  final DatabaseHostAdmission admission;
  final AdmissionAuthority origin;
  final AccountScopeHost host;
  final AccountScope scope;
  final SupabaseClient client;
  final CloudEgressGate gate;
  final int egressEpoch;
  final ImmediateDeletionBinding binding;
  final bool Function()? restrict;
  bool _lost = false;
  bool get current {
    if (_lost) {
      return false;
    }
    try {
      // Restrictive caller code can reenter. Concrete binding checks must run
      // after it, with no further caller callback before session acceptance.
      final allowed = restrict?.call() ?? true;
      final sdk = client.auth.currentSession;
      if (!allowed ||
          !admission.isCurrent ||
          !origin.isCurrent ||
          !identical(host.current, scope) ||
          !identical(scope.database, admission.database) ||
          scope.generation != admission.scopeGeneration ||
          scope.isLocalRead ||
          !scope.database.admitsSecondary ||
          sdk == null ||
          sdk.isExpired ||
          sdk.user.id != binding.owner ||
          sdk.accessToken != binding.bearerToken ||
          !identical(gate, CloudEgressGate.instance) ||
          gate.epoch != egressEpoch) {
        _lost = true;
      }
    } catch (_) {
      _lost = true;
    }
    return !_lost;
  }
}

final class _BindingLost implements Exception {
  const _BindingLost();
}

final class _ExchangeObservation {
  bool mismatch = false;
  bool lost = false;
  bool completedVerified = false;
}

/// Transparent, restrictive observer of the unchanged recovery's own lock and
/// verified persistence. No positive completion witness is derived from loads.
final class _OperationReceiptStore extends ImmediateDeletionReceiptStore {
  _OperationReceiptStore(this.base, this.operation)
      : super(authority: base.authority);
  final ImmediateDeletionReceiptStore base;
  final PreparedDeletionOperation operation;
  _ExchangeObservation? _active;
  @override
  Future<T> serialized<T>(Future<T> Function() body) => base.serialized(body);

  Never _mismatch() {
    _active?.mismatch =
        true; // Irrevocable, even if recovery catches sanitation.
    throw const ImmediateDeletionReceiptStoreException();
  }

  void _current() {
    if (!operation._original.current) {
      _active?.lost = true;
      throw const _BindingLost();
    }
  }

  bool _matches(ImmediateDeletionReceipt record) =>
      record.owner == operation._original.binding.owner &&
      record.operationId == operation._operationId &&
      record.receiptSecret == operation._secret;

  @override
  Future<ImmediateDeletionReceipt?> load(String owner) async {
    _current();
    if (owner != operation._original.binding.owner) {
      _mismatch();
    }
    final record = await base.load(owner);
    _current();
    if (record == null) {
      if (operation._resumed || operation._secret != null) {
        _mismatch();
      }
    } else if (!_matches(record) ||
        (record.phase == ImmediateDeletionPhase.completed) !=
            operation._cleanup) {
      _mismatch();
    }
    return record;
  }

  @override
  Future<void> writeVerified(ImmediateDeletionReceipt receipt) async {
    _current();
    if (receipt.owner != operation._original.binding.owner ||
        receipt.operationId != operation._operationId ||
        (receipt.receiptSecret != operation._secret &&
            !(receipt.phase == ImmediateDeletionPhase.completed &&
                receipt.receiptSecret == null))) {
      _mismatch();
    }
    final ImmediateDeletionReceipt? previous;
    try {
      previous = await base.load(receipt.owner);
    } catch (_) {
      // Sanitization is best effort in recovery, but an unreadable predecessor
      // cannot preserve this invocation's positive completion observation.
      _active?.mismatch = true;
      rethrow;
    }
    _current();
    final valid = switch (receipt.phase) {
      ImmediateDeletionPhase.created =>
        previous == null && receipt.receiptSecret != null,
      ImmediateDeletionPhase.mayHaveBeenSent => previous != null &&
          _matches(previous) &&
          previous.phase == ImmediateDeletionPhase.created,
      ImmediateDeletionPhase.completed => previous != null &&
          (receipt.receiptSecret == null
              ? previous.operationId == operation._operationId &&
                  previous.owner == receipt.owner &&
                  previous.receiptSecret == operation._secret &&
                  previous.phase == ImmediateDeletionPhase.completed &&
                  (_active?.completedVerified ?? false)
              : _matches(previous) &&
                  (previous.phase == ImmediateDeletionPhase.completed) ==
                      operation._cleanup),
    };
    if (!valid) {
      _mismatch();
    }
    try {
      await base.writeVerified(receipt);
    } catch (_) {
      // Recovery deliberately swallows best-effort sanitization errors. A
      // changed/unreadable record must still poison this invocation forever.
      if (receipt.phase == ImmediateDeletionPhase.completed &&
          receipt.receiptSecret == null) {
        try {
          final retained = await base.load(receipt.owner);
          if (retained == null ||
              retained.owner != receipt.owner ||
              retained.operationId != operation._operationId ||
              retained.phase != ImmediateDeletionPhase.completed ||
              (retained.receiptSecret != null &&
                  retained.receiptSecret != operation._secret)) {
            _mismatch();
          }
        } catch (_) {
          _active?.mismatch = true;
        }
      }
      rethrow;
    }
    _current();
    if (receipt.phase == ImmediateDeletionPhase.completed &&
        receipt.receiptSecret != null) {
      _active?.completedVerified = true;
    }
  }
}
