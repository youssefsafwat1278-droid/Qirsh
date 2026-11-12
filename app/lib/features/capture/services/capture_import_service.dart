import '../../../domain/entities/transaction_entity.dart';
import 'budget_alert_commits.dart';
import 'package:flutter/foundation.dart';

import '../../../data/db/ownership_guard.dart';
import '../../../domain/entities/smart_inbox_item_entity.dart';
import '../../../domain/capture/validated_capture.dart';
import '../../../domain/entities/captured_message.dart';
import '../../../domain/usecases/add_transaction_usecase.dart';
import '../../../domain/usecases/ingest_captured_message_usecase.dart';
import '../../../engine/parser/parser_engine.dart';
import 'capture_backend_client.dart';
import 'capture_import_ports.dart';
import 'capture_receipts.dart';
import 'capture_retry_ledger.dart';
import 'capture_sync_service.dart';
import 'native_capture_bridge.dart';
import 'shared_capture_handoff_service.dart';

enum CaptureImportPath {
  /// A receipt or a transaction with the capture id already existed: the item
  /// was only consumed (native removal + server ACK), never imported again.
  alreadyImported,

  /// Imported from a server result that passed ValidatedCapture v1.
  server,

  /// Imported by the local deterministic parser on the raw text (Q5).
  local,
}

class CaptureImportItem {
  const CaptureImportItem({
    required this.id,
    required this.path,
    this.message,
    this.local,
    this.reviewTransactionId,
    this.committedTransactions = const [],
  });

  /// Newly committed rows only; receipt/ACK-only deliveries contribute none.
  /// The budget checker applies expense, status and budget-scope eligibility.
  final List<TransactionEntity> committedTransactions;
  final String id;
  final CaptureImportPath path;
  final SharedCapturedMessage? message;

  /// The local parse result ([CaptureImportPath.local] only).
  final CapturedMessageResult? local;

  /// A server-imported transaction the user should review.
  final String? reviewTransactionId;
}

class CaptureImportReport {
  const CaptureImportReport({
    this.imported = const [],
    this.skippedForeignOwner = 0,
    this.skippedAwaiting = 0,
    this.guardFailed = false,
    this.barrierHeld = false,
    this.readFailed = false,
  });

  /// The native queue could not be READ: nothing was written or acknowledged.
  final bool readFailed;

  final List<CaptureImportItem> imported;

  /// Items whose owner is not the replica's / the session's: left in the queue.
  final int skippedForeignOwner;

  /// Items left in the queue to retry: server or upload not available yet, or
  /// a local failure.
  final int skippedAwaiting;

  /// The session uid, replica owner or admission did not agree: nothing ran.
  final bool guardFailed;

  /// A rebootstrap barrier is held: nothing ran.
  final bool barrierHeld;
}

/// CAP-5 — the one iOS capture import, bound to the ACCOUNT SCOPE (the active
/// replica). Replaces the relay import + native drain split behind the
/// `capture_import_v3` flag.
///
/// - Consumption rule (§4.2): an item is imported only when
///   `capture.owner_uid == replica_meta.owner_uid == session.uid`. Any other
///   item is skipped and left in the queue.
/// - Receipt-or-transaction check before any import (I-3, I-5): consume without
///   re-importing.
/// - A server result that is `processed` and passes ValidatedCapture v1 against
///   the device's own text is imported (tx.id = capture_id). Anything else
///   (rejected, retryable, unresolved, no usable result, 409, a locally bound
///   item) takes the local deterministic parser on the raw text (Q5): valid is
///   a confirmed transaction + outbox, invalid is Smart Inbox. There is NO AI
///   call from here: [ingestLocal] is on-device only by construction (I-4).
/// - Native removal and the server ACK happen only after the local import
///   transaction (receipt included) committed.
class CaptureImportService {
  CaptureImportService({
    required CaptureImportQueue queue,
    required CaptureServerPort server,
    required CaptureSyncService captureSyncService,
    required CaptureReceipts receipts,
    required Future<CapturedMessageResult> Function(
      CapturedMessage message,
      CaptureCommit? capture,
    ) ingestLocal,
    required String? Function() sessionUid,
    required Future<String?> Function() replicaOwnerUid,
    required OwnershipGuard ownershipGuard,
    Future<bool> Function()? aiPrimarySelected,
    // Bounds automatic retries (backoff, attempt cap, then Smart Inbox).
    // Absent => an item that cannot be finished is retried on every run.
    CaptureRetryLedger? retryLedger,
  })  : _aiPrimarySelected = aiPrimarySelected,
        _retryLedger = retryLedger,
        _queue = queue,
        _server = server,
        _sync = captureSyncService,
        _receipts = receipts,
        _ingestLocal = ingestLocal,
        _sessionUid = sessionUid,
        _replicaOwnerUid = replicaOwnerUid,
        _guard = ownershipGuard;

  final Future<bool> Function()? _aiPrimarySelected;
  final CaptureRetryLedger? _retryLedger;
  final CaptureImportQueue _queue;
  final CaptureServerPort _server;
  final CaptureSyncService _sync;
  final CaptureReceipts _receipts;
  final Future<CapturedMessageResult> Function(
    CapturedMessage message,
    CaptureCommit? capture,
  ) _ingestLocal;
  final String? Function() _sessionUid;
  final Future<String?> Function() _replicaOwnerUid;
  final OwnershipGuard _guard;

  /// The admission this run is bound to (single-flight, so one at a time).
  AdmissionToken? _token;

  /// The only way the service parses text: on device (no AI, no discovery, no
  /// enrichment), with binary local acceptance so a valid parse is CONFIRMED and
  /// an invalid one reaches Smart Inbox (Q5, I-4).
  static Future<CapturedMessageResult> Function(
    CapturedMessage message,
    CaptureCommit? capture,
  ) localIngest(IngestCapturedMessageUseCase ingest) =>
      (message, capture) => ingest.fromCapturedMessage(
            message,
            onDeviceOnly: true,
            forceLocalAutoConfirm: true,
            capture: capture,
          );

  Future<CaptureImportReport>? _inFlight;

  /// WP-8 (diagnostics): the outcome counts of the latest finished run of this
  /// service, in memory only. Counts and enum codes; no ids, no content.
  CaptureImportReport? lastReport;

  // §4.10 quiescence barrier.
  bool _barrier = false;
  final Set<String> _deferredNativeRemovals = {};
  final Set<String> _deferredServerAcks = {};

  /// Single-flight: a resume and a push tap arriving together share one run.
  Future<CaptureImportReport> run() {
    if (_barrier) {
      return Future.value(const CaptureImportReport(barrierHeld: true));
    }
    final pending = _inFlight;
    if (pending != null) return pending;
    final run = _runOnce().then((report) => lastReport = report).whenComplete(
          () => _inFlight = null,
        );
    _inFlight = run;
    return run;
  }

  // ── §4.10 quiescence barrier hook (WP-7 rebootstrap) ───────────────────────

  /// Stops the service for this replica and waits for the open import, if any,
  /// to finish its local transaction. While held: no new import starts, and the
  /// post-commit native removals and server ACKs of anything still finishing are
  /// DEFERRED (see [deferredCaptureIds]). Idempotent.
  Future<void> acquireBarrier() async {
    _barrier = true;
    final running = _inFlight;
    if (running != null) {
      try {
        await running;
      } catch (_) {}
    }
  }

  /// Ids whose local result committed but whose native removal / server ACK is
  /// deferred. A barrier holder checks these against the receipts it recovered.
  Set<String> get deferredCaptureIds =>
      {..._deferredNativeRemovals, ..._deferredServerAcks};

  /// Lifts the barrier and replays the deferred removals and ACKs, each guarded
  /// by its receipt (a capture whose receipt is not in this replica is left in
  /// the queue and imported again by a normal run). Idempotent.
  Future<void> releaseBarrier() async {
    _barrier = false;
    final native = _deferredNativeRemovals.toList();
    final server = _deferredServerAcks.toList();
    _deferredNativeRemovals.clear();
    _deferredServerAcks.clear();
    for (final id in native) {
      if (await _receipts.hasReceiptOrTransaction(id)) {
        await _queue.acknowledge(id);
      }
    }
    final committed = <String>[];
    for (final id in server) {
      if (await _receipts.hasReceiptOrTransaction(id)) committed.add(id);
    }
    if (committed.isNotEmpty) {
      try {
        await _server.acknowledge(committed);
      } catch (_) {}
    }
  }

  // ── the run ────────────────────────────────────────────────────────────────

  Future<String?> _owner() async {
    final session = _sessionUid();
    final replica = await _replicaOwnerUid();
    if (session == null || replica == null || session != replica) return null;
    return session;
  }

  Future<bool> _stillOwner(String owner) async {
    final token = _token;
    return token != null &&
        token.ownerUid == owner &&
        await _owner() == owner &&
        await _guard.isCurrent(token);
  }

  Future<void> _requireOwner(String owner) async {
    if (!await _stillOwner(owner)) throw const StaleOwnershipException();
  }

  Future<CaptureImportReport> _runOnce() async {
    _token = await _guard.capture();
    final owner = await _owner();
    if (owner == null || !await _stillOwner(owner)) {
      return const CaptureImportReport(guardFailed: true);
    }

    final fetch = await _server.fetchResults();
    final results = Map<String, ProcessedCaptureDto>.of(fetch.results);
    var serverStatus = fetch.status;

    final imported = <CaptureImportItem>[];
    var foreign = 0;
    var awaiting = 0;
    final items = <SharedCapturedMessage>[];
    final List<SharedCapturedMessage> queued;
    try {
      queued = await _queue.peek();
    } on NativeCaptureReadException {
      // An unreadable queue is an error, not an empty one: no import, no
      // removal, no ACK. The next run retries.
      return const CaptureImportReport(readFailed: true);
    }
    for (final m in queued) {
      final id = m.id?.trim();
      if (id == null || id.isEmpty) continue;
      // Triple equality: an item stamped to anyone else (or unstamped) waits.
      if (m.ownerUid != owner) {
        foreign++;
        continue;
      }
      items.add(m);
    }
    items.sort((a, b) {
      final x = a.receivedAt, y = b.receivedAt;
      if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
      return x.compareTo(y);
    });

    final handled = <String>{};
    final acks = <String>{};
    var guardFailed = false;
    _uploadRateLimited = false;
    for (final item in items) {
      if (_barrier) break;
      final id = item.id!.trim();
      // The item could not be finished on this pass: count it. True when its
      // bounded retries are spent and it was parked in Smart Inbox instead.
      Future<bool> deferred(CaptureFailureKind kind) async {
        if (!await _parkAfterBoundedRetries(owner, item, id, kind)) {
          return false;
        }
        handled.add(id);
        if (results.containsKey(id)) acks.add(id);
        imported.add(CaptureImportItem(
            id: id, path: CaptureImportPath.server, message: item));
        return true;
      }

      try {
        if (!await _stillOwner(owner)) throw const StaleOwnershipException();
        // Backing off after an earlier failed pass: nothing is re-sent or
        // re-parsed until the wait elapses. A result that committed meanwhile
        // (receipt) is still consumed below.
        if (!(await _retryLedger?.isDue(id) ?? true) &&
            !await _receipts.hasReceiptOrTransaction(id)) {
          awaiting++;
          continue;
        }
        final done = await _handleItem(
          owner: owner,
          item: item,
          id: id,
          results: results,
          fetchStatus: serverStatus,
          acks: acks,
          onRefetch: (f) => serverStatus = f.status,
        );
        if (done == null) {
          if (!await deferred(CaptureFailureKind.temporary)) awaiting++;
        } else {
          handled.add(id);
          imported.add(done);
          await _retryLedger?.clear(id);
        }
      } on StaleOwnershipException {
        guardFailed = true;
        break;
      } catch (e) {
        // The item stays in the queue; its retries are bounded by the ledger.
        if (kDebugMode) {
          debugPrint('[CaptureImport] item failed: ${e.runtimeType}');
        }
        try {
          if (!await deferred(CaptureRetryLedger.classify(e))) awaiting++;
        } on StaleOwnershipException {
          guardFailed = true;
          break;
        } catch (_) {
          awaiting++;
        }
      }
    }

    // Server results with no device copy are never imported (the device copy is
    // the ownership proof, Q6); one whose receipt exists only needs its ACK.
    for (final id in results.keys) {
      if (handled.contains(id) || _barrier) continue;
      if (await _receipts.hasReceiptOrTransaction(id)) acks.add(id);
    }

    if (acks.isNotEmpty) {
      if (_barrier) {
        _deferredServerAcks.addAll(acks);
      } else if (await _stillOwner(owner)) {
        try {
          await _server.acknowledge(acks.toList());
        } catch (_) {
          // The local results are durable; the receipts make the next ACK a no-op.
        }
      }
    }

    return CaptureImportReport(
      imported: imported,
      skippedForeignOwner: foreign,
      skippedAwaiting: awaiting,
      guardFailed: guardFailed,
      barrierHeld: _barrier,
    );
  }

  /// A 429 was seen on this run: no further upload is attempted on it.
  bool _uploadRateLimited = false;
  final Set<String> _rateLimitedIds = {};

  /// Records one unfinished pass for [id]. When the bounded automatic retries
  /// are spent, the full native message is parked in Smart Inbox (row and
  /// receipt in one transaction) and only then removed from the native queue:
  /// a visible, user-retryable end state instead of an endless silent retry.
  Future<bool> _parkAfterBoundedRetries(
    String owner,
    SharedCapturedMessage item,
    String id,
    CaptureFailureKind kind,
  ) async {
    final ledger = _retryLedger;
    if (ledger == null) return false;
    final decision = await ledger.recordFailure(id, kind,
        rateLimited: _rateLimitedIds.remove(id));
    if (!decision.exhausted) return false;
    await _sync.persistUnprocessableCapture(
      item,
      isOwnerCurrent: () => _stillOwner(owner),
      reviewReason: decision.kind == CaptureFailureKind.permanent
          ? SmartInboxReviewReason.processingFailed
          : SmartInboxReviewReason.analysisUnavailable,
    );
    await _removeNative(owner, id);
    await ledger.clear(id);
    return true;
  }

  /// Returns null when the item must wait (stays queued, nothing consumed).
  Future<CaptureImportItem?> _handleItem({
    required String owner,
    required SharedCapturedMessage item,
    required String id,
    required Map<String, ProcessedCaptureDto> results,
    required CaptureFetchStatus fetchStatus,
    required Set<String> acks,
    required void Function(CaptureServerFetch) onRefetch,
  }) async {
    if (await _receipts.hasReceiptOrTransaction(id)) {
      await _removeNative(owner, id);
      if (results.containsKey(id)) acks.add(id);
      return CaptureImportItem(
        id: id,
        path: CaptureImportPath.alreadyImported,
        message: item,
      );
    }

    final aiPrimary = item.localOnly != true &&
        (await _aiPrimarySelected?.call() ?? false);
    var local = item.localOnly == true ||
        fetchStatus == CaptureFetchStatus.notConfigured ||
        fetchStatus == CaptureFetchStatus.refused;

    // AI-primary and the server lists no result for an item that was never in
    // `pendingSend`: a Share Extension `pending` item, or an App Intent
    // `.waiting` item (stored as `sent`), which the server may never have
    // received. It is sent with its OWN payload id through the same gate — the
    // server claim is idempotent, so nothing is analysed twice.
    final neverSeen = aiPrimary &&
        !local &&
        item.status != 'pendingSend' &&
        fetchStatus == CaptureFetchStatus.ok &&
        !results.containsKey(id) &&
        item.failureReason?.trim() != 'http(409)';
    if (!local && (item.status == 'pendingSend' || neverSeen)) {
      if (_uploadRateLimited) {
        _rateLimitedIds.add(id);
        return null;
      }
      switch (await _server.retryUpload(item)) {
        case CaptureUploadStatus.sent:
          final refetch = await _server.fetchResults();
          onRefetch(refetch);
          results.addAll(refetch.results);
          // Accepted but not listed yet: the lease may still be open.
          if (!results.containsKey(id)) return null;
        case CaptureUploadStatus.notAllowed:
        case CaptureUploadStatus.conflict:
          local = true;
        case CaptureUploadStatus.rateLimited:
          _uploadRateLimited = true;
          _rateLimitedIds.add(id);
          return null;
        case CaptureUploadStatus.unavailable:
          return null;
      }
    }

    final result = results[id];
    if (aiPrimary) {
      if (result?.parsed['parserSource'] == 'ai_ignored') {
        // Only the device's deterministic OTP/promo filter may drop a capture.
        // A model "not a transaction" verdict keeps the full native message in
        // Smart Inbox (row + receipt, one transaction) before it is removed.
        if (!ParserEngine.isIgnoredMessage(item.text, senderId: item.sender)) {
          await _sync.persistUnprocessableCapture(item,
              isOwnerCurrent: () => _stillOwner(owner));
        }
        await _removeNative(owner, id);
        acks.add(id);
        return CaptureImportItem(id: id, path: CaptureImportPath.server,
            message: item, committedTransactions: const []);
      }
      if (result != null && _isProcessed(result) && _validates(result, item)) {
        return _importFromServer(owner, item, id, result, acks);
      }
      if (result?.state == 'processing' || result?.state == 'retryable' ||
          fetchStatus == CaptureFetchStatus.unavailable) {
        return null;
      }
      if (result == null && item.status == 'pendingSend' && !local) return null;
      // The capture may not leave the device (gate refused, cloud not
      // configured) or the server refused it for good: with no server result
      // it is resolved by the deterministic parser, never parked unparsed.
      if (result == null && local) {
        return _importLocally(owner, item, id, false, acks);
      }
      // No guessed financial transaction: retain the full native message in
      // Smart Inbox atomically before acknowledging the native receipt.
      await _sync.persistUnprocessableCapture(item,
          isOwnerCurrent: () => _stillOwner(owner));
      await _removeNative(owner, id);
      if (result != null) acks.add(id);
      return CaptureImportItem(id: id, path: CaptureImportPath.server,
          message: item, committedTransactions: const []);
    }
    if (!local) {
      if (result == null) {
        // Consumed / expired / never stored. If the fetch itself failed we know
        // nothing yet (and the capture reached the server): wait.
        local = !(fetchStatus == CaptureFetchStatus.unavailable &&
            (item.failureReason?.trim().isEmpty ?? true));
        if (!local) return null;
      } else if (_isProcessed(result) && _validates(result, item)) {
        return _importFromServer(owner, item, id, result, acks);
      } else {
        local = true;
      }
    }
    return _importLocally(owner, item, id, results.containsKey(id), acks);
  }

  static bool _isProcessed(ProcessedCaptureDto dto) {
    if (dto.status == 'rejected' || dto.status == 'needs_review') return false;
    return (dto.state ?? 'processed') == 'processed';
  }

  /// ValidatedCapture v1 against the text the device holds.
  static bool _validates(ProcessedCaptureDto dto, SharedCapturedMessage item) {
    final p = dto.parsed;
    double? number(Object? v) =>
        v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
    String? text(Object? v) => v is String ? v : null;
    return validateCaptureCandidate(
      candidate: CaptureCandidate(
        amount: number(p['amount']),
        amountText: text(p['amount_text']),
        currency: text(p['currency']),
        direction: text(p['direction']),
        type: text(p['type']),
        merchant: text(p['merchant']),
        last4: text(p['last4']),
        occurredAt: text(p['occurredAt']),
      ),
      text: item.text,
      receivedAt: item.receivedAt ?? dto.createdAt ?? DateTime.now().toUtc(),
    ).accepted;
  }

  Future<CaptureImportItem> _importFromServer(
    String owner,
    SharedCapturedMessage item,
    String id,
    ProcessedCaptureDto dto,
    Set<String> acks,
  ) async {
    final committed = <TransactionEntity>[];
    final review = await _sync.importServerCapture(
        dto, () => _requireOwner(owner),
        onCommitted: committed.addAll);
    await _removeNative(owner, id);
    acks.add(id);
    return CaptureImportItem(
      id: id,
      path: CaptureImportPath.server,
      committedTransactions: committed,
      message: item,
      reviewTransactionId: review,
    );
  }

  Future<CaptureImportItem> _importLocally(
    String owner,
    SharedCapturedMessage item,
    String id,
    bool hasServerRow,
    Set<String> acks,
  ) async {
    final base = _sync.captureCommitFor(id);
    // The owner is re-checked INSIDE the import transaction, just before the
    // receipt commits: a change rolls the whole capture back (T-I4).
    final commit = CaptureCommit(
      captureId: id,
      runAtomically: base.runAtomically,
      writeReceipt: (transactionId) async {
        await _requireOwner(owner);
        await base.writeReceipt(transactionId);
      },
    );
    final result = await _ingestLocal(
      CapturedMessage(
        text: item.text,
        senderId: item.sender,
        source: item.source,
        receivedAt: item.receivedAt,
      ),
      commit,
    );
    final handoff = SharedCaptureHandoffService(
      captureSyncService: _sync,
      isOwnerCurrent: () => _stillOwner(owner),
      acknowledge: (payloadId) => _removeNative(owner, payloadId),
    );
    await handoff.complete(
      message: item,
      disposition: result.disposition,
      transactionId: result.transactionId,
    );
    // The local result is durable either way; a retained item is removed by the
    // next run's receipt check.
    if (hasServerRow) acks.add(id);
    return CaptureImportItem(
      id: id,
      path: CaptureImportPath.local,
      message: item,
      local: result,
      committedTransactions:
          newlyAddedTransactions(result.addTransactionResult),
    );
  }

  /// Native removal after the commit; deferred while the barrier is held.
  Future<bool> _removeNative(String owner, String id) async {
    if (_barrier) {
      _deferredNativeRemovals.add(id);
      return true;
    }
    await _requireOwner(owner);
    return _queue.acknowledge(id);
  }
}
