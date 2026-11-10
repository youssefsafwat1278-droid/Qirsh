import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../privacy/cloud_egress_gate.dart';
import 'immediate_deletion_receipt_store.dart';

/// DRAFT - NOT WIRED. Client side of the owner-approved "delete account is
/// permanent and immediate" decision. The server function it talks to
/// (`delete-account-immediate`) is itself an undeployed draft.
///
/// Outcome states. [ImmediateDeletionCompleted] is produced ONLY from an HTTP
/// 200 whose body says `completed`: the server's own receipt. Every error,
/// timeout, transport failure, empty/malformed body or unknown status is an
/// [ImmediateDeletionFailed]; none is ever mapped to success.
sealed class ImmediateDeletionResult {
  const ImmediateDeletionResult(this.receiptSecret);

  /// The client-generated receipt capability. Keep it (securely) and pass the
  /// SAME value on every retry or status poll: it is how a lost response is
  /// recovered without authorising afresh.
  final String receiptSecret;
}

/// The server durably accepted the request; work has not been reported yet.
final class ImmediateDeletionAccepted extends ImmediateDeletionResult {
  const ImmediateDeletionAccepted(super.receiptSecret);
}

/// Accepted and running (or waiting to retry). The UI must say so honestly.
final class ImmediateDeletionInProgress extends ImmediateDeletionResult {
  const ImmediateDeletionInProgress(super.receiptSecret);
}

/// The server confirmed the whole deletion finished. Only now may the app show
/// "deleted" and return to the auth screen.
final class ImmediateDeletionCompleted extends ImmediateDeletionResult {
  const ImmediateDeletionCompleted(super.receiptSecret);
}

final class ImmediateDeletionFailed extends ImmediateDeletionResult {
  const ImmediateDeletionFailed(
    super.receiptSecret, {
    required this.retryable,
    required this.code,
    this.lookupReceipt = false,
  });

  /// True when repeating the same request (same [receiptSecret]) may succeed.
  final bool retryable;

  /// A short enumerated code (never server text).
  final String code;

  /// True when the server MAY have accepted the request (timeout, lost
  /// response, acceptance_unknown): poll `status` or repeat the same request
  /// with the same secret; do not start a fresh authorisation.
  final bool lookupReceipt;

  @override
  String toString() =>
      'ImmediateDeletionFailed(code: $code, retryable: $retryable, lookupReceipt: $lookupReceipt)';
}

final RegExp _receiptSecretRe = RegExp(r'^[A-Za-z0-9_-]{43,128}$');
final RegExp _codeRe = RegExp(r'^[a-z][a-z0-9_]{0,39}$');

/// 32 CSPRNG bytes as unpadded base64url (43 characters). Pass `random` only in
/// tests; the default is [Random.secure].
String generateReceiptSecret({Random? random}) {
  final r = random ?? Random.secure();
  final bytes = List<int>.generate(32, (_) => r.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Why the server refused to issue a re-authentication challenge. None of these
/// is a deletion outcome: nothing was requested and nothing was deleted.
enum ImmediateChallengeRefusal {
  /// `admin_self_delete_blocked`: admin rights must be removed first (D7).
  adminBlocked,

  /// `challenge_rate_limited`: too many unconsumed challenges; wait.
  rateLimited,

  /// `already_pending`: a deletion job already exists server-side. Use status,
  /// never a new request.
  alreadyPending,
}

/// Result of `{action: "challenge"}`.
sealed class ImmediateChallengeResult {
  const ImmediateChallengeResult();
}

enum DeletionProofMethod { apple, google, email }

final class ImmediateChallengeIssued extends ImmediateChallengeResult {
  const ImmediateChallengeIssued({
    required this.challengeId,
    required this.nonce,
    required this.expiresAtMs,
    this.method = DeletionProofMethod.apple,
  });
  final String challengeId;

  /// Raw nonce, returned once. Never log or persist it.
  final String nonce;
  final int expiresAtMs;
  final DeletionProofMethod method;
  @override
  String toString() => 'ImmediateChallengeIssued';
}

final class ImmediateChallengeRefused extends ImmediateChallengeResult {
  const ImmediateChallengeRefused(this.reason);
  final ImmediateChallengeRefusal reason;
  @override
  String toString() => 'ImmediateChallengeRefused(${reason.name})';
}

final class ImmediateChallengeFailed extends ImmediateChallengeResult {
  const ImmediateChallengeFailed({required this.retryable, required this.code});
  final bool retryable;
  final String code;
  @override
  String toString() =>
      'ImmediateChallengeFailed(code: $code, retryable: $retryable)';
}

final RegExp _challengeTokenRe = RegExp(r'^[A-Za-z0-9_-]{16,256}$');

ImmediateChallengeResult _interpretChallenge(http.Response r) {
  final status = r.statusCode;
  Map<String, dynamic>? json;
  try {
    final decoded = jsonDecode(r.body);
    if (decoded is Map<String, dynamic>) json = decoded;
  } catch (_) {
    json = null;
  }
  final label = json?['status'];
  final rawCode = json?['code'];
  final code = rawCode is String && _codeRe.hasMatch(rawCode) ? rawCode : null;
  if (code == 'admin_self_delete_blocked') {
    return const ImmediateChallengeRefused(
        ImmediateChallengeRefusal.adminBlocked);
  }
  if (code == 'challenge_rate_limited') {
    return const ImmediateChallengeRefused(
        ImmediateChallengeRefusal.rateLimited);
  }
  if (code == 'already_pending' ||
      ((status == 200 || status == 202) &&
          (label == 'accepted' || label == 'in_progress'))) {
    return const ImmediateChallengeRefused(
        ImmediateChallengeRefusal.alreadyPending);
  }
  if (status == 200 && label == 'challenge') {
    final id = json?['challenge_id'];
    final nonce = json?['nonce'];
    final expires = json?['expires_at_ms'];
    final method = switch (json?['proof_method']) {
      null || 'apple' => DeletionProofMethod.apple,
      'google' => DeletionProofMethod.google,
      'email' => DeletionProofMethod.email,
      _ => null,
    };
    if (id is String &&
        _challengeTokenRe.hasMatch(id) &&
        nonce is String &&
        _challengeTokenRe.hasMatch(nonce) &&
        expires is num &&
        expires > 0 && method != null) {
      return ImmediateChallengeIssued(
          challengeId: id, nonce: nonce, expiresAtMs: expires.toInt(), method: method);
    }
    return const ImmediateChallengeFailed(
        retryable: true, code: 'invalid_response');
  }
  if (status == 429) {
    return const ImmediateChallengeRefused(
        ImmediateChallengeRefusal.rateLimited);
  }
  if (status == 401) {
    return const ImmediateChallengeFailed(
        retryable: false, code: 'unauthenticated');
  }
  final retryable = status >= 500 || status == 408;
  return ImmediateChallengeFailed(
      retryable: retryable,
      code: code ?? (retryable ? 'server_error' : 'rejected'));
}

class ImmediateAccountDeletionClient {
  ImmediateAccountDeletionClient({
    required this.httpClient,
    required this.functionUrl,
    required this.accessToken,
    this.requestTimeout = const Duration(seconds: 45),
    this.apiKey,
  });

  final http.Client httpClient;
  final Uri functionUrl;
  final Future<String?> Function() accessToken;
  final Duration requestTimeout;

  /// Optional Supabase anon key header some gateways require.
  final String? apiKey;

  Future<ImmediateDeletionResult> request({
    required String challengeId,
    required String challengeResponse,
    required String receiptSecret,
  }) {
    if (!_receiptSecretRe.hasMatch(receiptSecret) ||
        challengeId.isEmpty ||
        challengeResponse.isEmpty) {
      return Future.value(ImmediateDeletionFailed(receiptSecret,
          retryable: false, code: 'invalid_request'));
    }
    return _send(receiptSecret, <String, Object>{
      'challenge_id': challengeId,
      'challenge_response': challengeResponse,
      'receipt_secret': receiptSecret,
    });
  }

  /// Asks the server for a fresh single-use re-authentication challenge. Sends
  /// no deletion request and starts no work; an issued challenge is only the
  /// nonce the Apple re-authentication must be bound to.
  Future<ImmediateChallengeResult> challenge() async {
    final String? token;
    try {
      token = await accessToken();
    } catch (_) {
      return const ImmediateChallengeFailed(
          retryable: true, code: 'session_unavailable');
    }
    if (token == null || token.isEmpty) {
      return const ImmediateChallengeFailed(
          retryable: false, code: 'unauthenticated');
    }
    return _sendChallenge(token, jsonEncode(<String, Object>{'action': 'challenge'}));
  }

  Future<ImmediateChallengeResult> _sendChallenge(
      String token, String serializedBody) async {
    final http.Response response;
    try {
      response = await httpClient
          .post(
            functionUrl,
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              if (apiKey != null) 'apikey': apiKey!,
            },
            body: serializedBody,
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      return const ImmediateChallengeFailed(retryable: true, code: 'timeout');
    } catch (_) {
      return const ImmediateChallengeFailed(retryable: true, code: 'network');
    }
    return _interpretChallenge(response);
  }

  /// Read-only poll by receipt. Never starts or accelerates work.
  Future<ImmediateDeletionResult> status({required String receiptSecret}) {
    if (!_receiptSecretRe.hasMatch(receiptSecret)) {
      return Future.value(ImmediateDeletionFailed(receiptSecret,
          retryable: false, code: 'invalid_request'));
    }
    return _send(receiptSecret, <String, Object>{
      'action': 'status',
      'receipt_secret': receiptSecret,
    }, statusOnly: true);
  }

  Future<ImmediateDeletionResult> _send(
      String secret, Map<String, Object> body, {
      bool statusOnly = false, String? capturedToken, bool useCapturedToken = false,
      String? serializedBody,
  }) async {
    String? token;
    if (!statusOnly) {
      try {
        token = useCapturedToken ? capturedToken : await accessToken();
      } catch (_) {
        return ImmediateDeletionFailed(secret,
            retryable: true, code: 'session_unavailable');
      }
      if (token == null || token.isEmpty) {
        return ImmediateDeletionFailed(secret,
            retryable: false, code: 'unauthenticated');
      }
    }
    final http.Response response;
    try {
      response = await httpClient
          .post(
            functionUrl,
            headers: <String, String>{
              if (!statusOnly) 'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              if (apiKey != null) 'apikey': apiKey!,
            },
            body: serializedBody ?? jsonEncode(body),
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      return ImmediateDeletionFailed(secret,
          retryable: true, code: 'timeout', lookupReceipt: true);
    } catch (_) {
      // The request may or may not have reached the server.
      return ImmediateDeletionFailed(secret,
          retryable: true, code: 'network', lookupReceipt: true);
    }
    return _interpret(secret, response);
  }

  ImmediateDeletionResult _interpret(String secret, http.Response r) {
    final status = r.statusCode;
    final retryableByStatus = status >= 500 || status == 408 || status == 429;
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(r.body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      json = null;
    }
    final label = json?['status'];

    if (status == 200 || status == 202) {
      switch (label) {
        case 'completed':
          // Completion is only ever a 200 from the server's receipt.
          if (status == 200) return ImmediateDeletionCompleted(secret);
          break;
        case 'accepted':
          return ImmediateDeletionAccepted(secret);
        case 'in_progress':
          return ImmediateDeletionInProgress(secret);
      }
      return ImmediateDeletionFailed(secret,
          retryable: true, code: 'invalid_response', lookupReceipt: true);
    }

    if (label == 'unknown') {
      return ImmediateDeletionFailed(secret, retryable: false, code: 'unknown');
    }
    if (label == 'unavailable') {
      return ImmediateDeletionFailed(secret,
          retryable: true, code: 'unavailable');
    }
    if (label == 'error') {
      final rawCode = json?['code'];
      final code =
          rawCode is String && _codeRe.hasMatch(rawCode) ? rawCode : null;
      final rawRetry = json?['retryable'];
      final retryable = rawRetry is bool ? rawRetry : retryableByStatus;
      return ImmediateDeletionFailed(
        secret,
        retryable: code == null ? retryableByStatus : retryable,
        code: code ?? (retryableByStatus ? 'server_error' : 'rejected'),
        lookupReceipt: json?['recovery'] == 'lookup_receipt',
      );
    }
    if (status == 401) {
      return ImmediateDeletionFailed(secret,
          retryable: false, code: 'unauthenticated');
    }
    if (retryableByStatus) {
      return ImmediateDeletionFailed(secret,
          retryable: true, code: 'server_error');
    }
    return ImmediateDeletionFailed(secret, retryable: false, code: 'rejected');
  }
}

/// Injected coherent session snapshot, captured once without refreshing. The
/// production provider is deliberately not activated by this draft.
class ImmediateDeletionBinding {
  const ImmediateDeletionBinding({required this.owner, required this.lifecycle, this.bearerToken});
  final String? owner;
  final int lifecycle;
  final String? bearerToken;
  @override
  String toString() => 'ImmediateDeletionBinding';
}

/// No receipt/token getters: restored handles authorize only this pending
/// operation and this captured lifecycle, through the issuing facade.
class ImmediateDeletionRecoveryHandle {
  ImmediateDeletionRecoveryHandle._(this._issuer, this._owner, this._operationId,
      this._binding, this._epoch,
      {this.awaitingLocalCleanup = false});
  final Object _issuer;
  final String _owner;
  final String _operationId;
  final ImmediateDeletionBinding _binding;
  final int _epoch;

  /// True for a handle on a COMPLETED receipt whose secret was retained until
  /// the original local removal is confirmed. It can only re-verify completion.
  final bool awaitingLocalCleanup;
  bool _closed = false;
  @override
  String toString() => 'ImmediateDeletionRecoveryHandle';
}

/// Durable foreground recovery above the raw HTTP client. No automatic polling,
/// local erasure, finalization, consent enable, or production wiring.
class ImmediateAccountDeletionRecovery {
  ImmediateAccountDeletionRecovery({
    required this.store,
    required http.Client transport,
    required Uri functionUrl,
    required this.captureBinding,
    required this.isBindingCurrent,
    CloudEgressGate? gate,
    String Function()? newReceipt,
    String Function()? newOperationId,
    Duration requestTimeout = kAccountControlTtl,
    String? apiKey,
    this.retireOnComplete = true,
  }) : gate = gate ?? CloudEgressGate.instance,
       _newReceipt = newReceipt ?? generateReceiptSecret,
       _newOperationId = newOperationId ?? generateReceiptSecret {
    final configuredBound = this.gate.accountControlTtl;
    final bound = configuredBound < kAccountControlTtl ? configuredBound : kAccountControlTtl;
    final timeout = requestTimeout < bound ? requestTimeout : bound;
    _client = ImmediateAccountDeletionClient(
      httpClient: GatedHttpClient(transport), functionUrl: functionUrl,
      accessToken: () async => throw StateError('coherent_binding_required'),
      requestTimeout: timeout, apiKey: apiKey,
    );
  }

  final ImmediateDeletionReceiptStore store;

  /// True (default): the receipt secret is erased right after completion is
  /// persisted. False: the completed receipt keeps its secret so a later status
  /// call can produce fresh completion evidence; the caller retires it once the
  /// original local removal is confirmed.
  final bool retireOnComplete;
  final CloudEgressGate gate;
  final Future<ImmediateDeletionBinding> Function() captureBinding;
  final bool Function(ImmediateDeletionBinding) isBindingCurrent;
  final String Function() _newReceipt;
  final String Function() _newOperationId;
  late final ImmediateAccountDeletionClient _client;

  bool _current(ImmediateDeletionBinding binding, int epoch) {
    try {
      return identical(gate, CloudEgressGate.instance) && gate.epoch == epoch &&
          isBindingCurrent(binding);
    } catch (_) { return false; }
  }

  ImmediateDeletionFailed _failure(String code, [String secret = '']) =>
      ImmediateDeletionFailed(secret, retryable: true, code: code,
          lookupReceipt: secret.isNotEmpty);

  /// Startup restoration itself has no egress. Invoking recover is explicit.
  /// Signed out: the caller must choose one known owner's receipt. Another
  /// active account can never open it, even if its receipt is known.
  Future<ImmediateDeletionRecoveryHandle?> restore({required String owner}) async {
    try {
      final epoch = gate.epoch;
      final binding = await captureBinding();
      if (!_current(binding, epoch) ||
          (binding.owner != null && binding.owner != owner)) {
        return null;
      }
      return await store.serialized(() async {
        final receipt = await store.load(owner);
        if (!_current(binding, epoch) || receipt == null ||
            receipt.phase == ImmediateDeletionPhase.completed) {
          return null;
        }
        return ImmediateDeletionRecoveryHandle._(this, owner, receipt.operationId, binding, epoch);
      });
    } catch (_) { return null; }
  }

  /// Like [restore], but for a COMPLETED receipt that still holds its secret
  /// (local removal not yet confirmed). Only [recover] on it may follow, and it
  /// only ever sends the read-only status call.
  Future<ImmediateDeletionRecoveryHandle?> restoreCompletedAwaitingCleanup(
      {required String owner}) async {
    try {
      final epoch = gate.epoch;
      final binding = await captureBinding();
      if (!_current(binding, epoch) ||
          (binding.owner != null && binding.owner != owner)) {
        return null;
      }
      return await store.serialized(() async {
        final receipt = await store.load(owner);
        if (!_current(binding, epoch) ||
            receipt == null ||
            receipt.phase != ImmediateDeletionPhase.completed ||
            receipt.receiptSecret == null) {
          return null;
        }
        return ImmediateDeletionRecoveryHandle._(
            this, owner, receipt.operationId, binding, epoch,
            awaitingLocalCleanup: true);
      });
    } catch (_) {
      return null;
    }
  }

  /// Challenge issuance for the captured, still-current binding. Not a deletion
  /// request: it touches no receipt and never retries.
  Future<ImmediateChallengeResult> challenge({bool? emailOnly}) async {
    final epoch = gate.epoch;
    ImmediateDeletionBinding binding;
    try {
      binding = await captureBinding();
    } catch (_) {
      return const ImmediateChallengeFailed(
          retryable: true, code: 'session_unavailable');
    }
    final owner = binding.owner;
    final token = binding.bearerToken;
    if (owner == null ||
        owner.isEmpty ||
        token == null ||
        token.isEmpty ||
        !_current(binding, epoch)) {
      return const ImmediateChallengeFailed(
          retryable: true, code: 'stale_context');
    }
    final serialized = jsonEncode(<String, Object>{
      'action': 'challenge',
      if (emailOnly != null) ...{'proof_version': 2, 'email_only': emailOnly},
    });
    ImmediateChallengeResult result;
    try {
      result = await gate.runImmediateDeletion(
        action: ImmediateDeletionAction.challenge,
        owner: owner,
        activeOwner: owner,
        epoch: epoch,
        isCurrent: () => _current(binding, epoch),
        functionUrl: _client.functionUrl,
        serializedBody: serialized,
        bearerToken: token,
        timeout: _client.requestTimeout,
        exchange: () => _client._sendChallenge(token, serialized),
      );
    } catch (_) {
      return const ImmediateChallengeFailed(
          retryable: true, code: 'exchange_unconfirmed');
    }
    if (!_current(binding, epoch)) {
      return const ImmediateChallengeFailed(
          retryable: true, code: 'stale_context');
    }
    return result;
  }

  Future<ImmediateDeletionResult> request({
    required String challengeId, required String challengeResponse,
    String? receiptSecret,
  }) async {
    final epoch = gate.epoch;
    ImmediateDeletionBinding binding;
    try { binding = await captureBinding(); }
    catch (_) { return _failure('session_unavailable', receiptSecret ?? ''); }
    final owner = binding.owner;
    if (owner == null || owner.isEmpty || !_current(binding, epoch)) {
      return _failure('stale_context', receiptSecret ?? '');
    }
    String secret = receiptSecret ?? '';
    try {
      return await store.serialized(() async {
        var record = await store.load(owner);
        if (!_current(binding, epoch)) return _failure('stale_context', secret);
        if (record != null) {
          if (record.phase == ImmediateDeletionPhase.completed) {
            if (receiptSecret != null) return _failure('operation_closed', receiptSecret);
            return const ImmediateDeletionCompleted('');
          }
          secret = record.receiptSecret!;
          if (receiptSecret != null && receiptSecret != secret) {
            return _failure('receipt_conflict', receiptSecret);
          }
          // Any existing operation, even a created record restored after a
          // crash, recovers by receipt only; no reauthorization or rotation.
          return _exchange(record, binding, epoch, statusOnly: true);
        }
        if (receiptSecret != null) return _failure('receipt_conflict', receiptSecret);
        if (binding.bearerToken == null || binding.bearerToken!.isEmpty ||
            challengeId.isEmpty || challengeResponse.isEmpty) {
          return _failure('invalid_request', secret);
        }
        secret = receiptSecret ?? _newReceipt();
        if (!_receiptSecretRe.hasMatch(secret)) return _failure('invalid_request', secret);
        record = ImmediateDeletionReceipt(owner: owner, operationId: _newOperationId(),
            receiptSecret: secret, phase: ImmediateDeletionPhase.created);
        await store.writeVerified(record);
        if (!_current(binding, epoch)) return _failure('stale_context', secret);
        final intent = ImmediateDeletionReceipt(owner: owner, operationId: record.operationId,
            receiptSecret: secret, phase: ImmediateDeletionPhase.mayHaveBeenSent);
        await store.writeVerified(intent);
        if (!_current(binding, epoch)) return _failure('stale_context', secret);
        return _exchange(intent, binding, epoch, statusOnly: false,
            challengeId: challengeId, challengeResponse: challengeResponse);
      });
    } catch (_) { return _failure('receipt_store_unavailable', secret); }
  }

  Future<ImmediateDeletionResult> recover(ImmediateDeletionRecoveryHandle handle) async {
    if (!identical(handle._issuer, this) || handle._closed ||
        !_current(handle._binding, handle._epoch)) {
      return _failure('stale_context');
    }
    String secret = '';
    try {
      return await store.serialized(() async {
        final record = await store.load(handle._owner);
        if (!_current(handle._binding, handle._epoch)) return _failure('stale_context');
        if (record == null || record.operationId != handle._operationId ||
            (record.phase == ImmediateDeletionPhase.completed) !=
                handle.awaitingLocalCleanup ||
            record.receiptSecret == null) {
          handle._closed = true;
          return _failure('operation_closed');
        }
        secret = record.receiptSecret!;
        final result = await _exchange(record, handle._binding, handle._epoch, statusOnly: true);
        if (result is ImmediateDeletionCompleted) handle._closed = true;
        return result;
      });
    } catch (_) { return _failure('receipt_store_unavailable', secret); }
  }

  /// Compatibility poll for the current active owner only. Signed-out recovery
  /// requires an explicitly restored opaque handle, never a borrowed identity.
  Future<ImmediateDeletionResult> status({required String receiptSecret}) async {
    final epoch = gate.epoch;
    try {
      final binding = await captureBinding();
      if (!_current(binding, epoch)) return _failure('stale_context', receiptSecret);
      if (binding.owner == null) return _failure('recovery_required', receiptSecret);
      return await store.serialized(() async {
        final record = await store.load(binding.owner!);
        if (!_current(binding, epoch)) return _failure('stale_context', receiptSecret);
        if (record == null || record.phase == ImmediateDeletionPhase.completed) {
          return _failure('operation_closed', receiptSecret);
        }
        if (record.receiptSecret != receiptSecret) return _failure('receipt_conflict', receiptSecret);
        return _exchange(record, binding, epoch, statusOnly: true);
      });
    } catch (_) { return _failure('receipt_store_unavailable', receiptSecret); }
  }

  Future<ImmediateDeletionResult> _exchange(
      ImmediateDeletionReceipt record, ImmediateDeletionBinding binding, int epoch,
      {required bool statusOnly, String? challengeId, String? challengeResponse}) async {
    final secret = record.receiptSecret!;
    if (!_current(binding, epoch)) return _failure('stale_context', secret);
    final body = <String, Object>{
      if (statusOnly) 'action': 'status',
      if (!statusOnly) 'challenge_id': challengeId!,
      if (!statusOnly) 'challenge_response': challengeResponse!,
      'receipt_secret': secret,
    };
    final serialized = jsonEncode(body);
    ImmediateDeletionResult result;
    try {
      result = await gate.runImmediateDeletion(
        action: statusOnly ? ImmediateDeletionAction.status : ImmediateDeletionAction.request,
        owner: record.owner, activeOwner: binding.owner, epoch: epoch,
        isCurrent: () => _current(binding, epoch), functionUrl: _client.functionUrl,
        serializedBody: serialized, bearerToken: statusOnly ? null : binding.bearerToken,
        timeout: _client.requestTimeout,
        exchange: () => _client._send(secret, body, statusOnly: statusOnly,
            useCapturedToken: true, capturedToken: binding.bearerToken, serializedBody: serialized),
      );
    } catch (_) { return _failure('exchange_unconfirmed', secret); }
    if (!_current(binding, epoch)) return _failure('stale_context', secret);
    if (result is ImmediateDeletionCompleted) {
      final completed = ImmediateDeletionReceipt(owner: record.owner, operationId: record.operationId,
          receiptSecret: secret, phase: ImmediateDeletionPhase.completed);
      // Publication/retirement only after a confirmed completion write.
      await store.writeVerified(completed);
      if (retireOnComplete) {
        try {
          await store.writeVerified(ImmediateDeletionReceipt(owner: record.owner,
              operationId: record.operationId, receiptSecret: null, phase: ImmediateDeletionPhase.completed));
        } catch (_) { /* Confirmed closed tombstone survives; no active authority. */ }
      }
      if (!_current(binding, epoch)) return _failure('stale_context');
    }
    return result;
  }
}

/// What a database error raised by the account-deletion fence means to a
/// writer (outbox push, direct DML, RPC). PROPOSED mapping, see DECISIONS.md:
/// `outbox_failure.dart` does not use it yet.
enum AccountFenceErrorKind {
  /// Not a fence error; classify with the existing rules.
  none(consumesAttempt: true),

  /// SQLSTATE 55P03: a deletion transaction or sibling writer holds the
  /// account gate. Whole mutation rolled back. Retry shortly; no retry attempt
  /// is consumed.
  contention(consumesAttempt: false),

  /// SQLSTATE QD001: an accepted deletion is pending. Stop writing for this
  /// account; never treat as success; the app is about to be signed out.
  deletionPending(consumesAttempt: false),

  /// SQLSTATE QD002: the Auth user no longer exists (stale JWT after deletion).
  accountGone(consumesAttempt: false);

  const AccountFenceErrorKind({required this.consumesAttempt});

  final bool consumesAttempt;

  /// No fence outcome is ever a successful write.
  bool get isSuccess => false;
}

AccountFenceErrorKind classifyAccountFenceError(Object error) {
  if (error is! PostgrestException) return AccountFenceErrorKind.none;
  switch (error.code) {
    case '55P03':
      return AccountFenceErrorKind.contention;
    case 'QD001':
      return AccountFenceErrorKind.deletionPending;
    case 'QD002':
      return AccountFenceErrorKind.accountGone;
    default:
      return AccountFenceErrorKind.none;
  }
}
