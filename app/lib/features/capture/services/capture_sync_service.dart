import 'budget_alert_commits.dart';
import 'package:flutter/foundation.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/observability/diagnostics.dart';
import '../../../core/privacy/consent_authority.dart';
import '../../../core/utils/install_id.dart';
import '../../../data/db/ownership_guard.dart';
import '../../../data/repositories/drift_dedup_store.dart';
import '../../../data/repositories/drift_smart_inbox_repository.dart';
import '../../../data/repositories/drift_suspected_duplicate_repository.dart';
import '../../../data/repositories/drift_transaction_repository.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import '../../../domain/entities/account_entity.dart';
import '../../../domain/entities/captured_message.dart';
import '../../../domain/entities/suspected_duplicate_entity.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/repositories/account_repository.dart';
import '../../../domain/usecases/add_transaction_usecase.dart';
import '../../../domain/usecases/user_settings_usecases.dart';
import '../../../domain/usecases/ingest_captured_message_usecase.dart';
import '../../../engine/privacy/sms_sanitizer.dart';
import '../../../engine/parser/capture_money.dart';
import '../../../engine/parser/merchant_sanity.dart';
import 'capture_backend_client.dart';
import 'capture_device_registration_service.dart';
import 'native_capture_bridge.dart';
import 'local_notification_service.dart';

class CaptureSyncResult {
  const CaptureSyncResult({
    required this.importedPayloadIds,
    required this.ackedPayloadIds,
    required this.needsReviewTransactionIds,
    this.committedTransactions = const [],
  });

  /// Newly committed rows only; receipt/ACK-only deliveries contribute none.
  /// The budget checker applies expense, status and budget-scope eligibility.
  final List<TransactionEntity> committedTransactions;
  final Set<String> importedPayloadIds;
  final Set<String> ackedPayloadIds;
  final List<String> needsReviewTransactionIds;
}

class _RecoveryDeclined implements Exception {
  const _RecoveryDeclined();
}

class CaptureSyncService {
  CaptureSyncService({
    required DriftUserSettingsRepository settingsRepository,
    required DriftTransactionRepository transactionRepository,
    required DriftDedupStore dedupStore,
    required DriftSmartInboxRepository smartInboxRepository,
    required DriftSuspectedDuplicateRepository suspectedDuplicateRepository,
    required CaptureDeviceRegistrationService registrationService,
    required OwnershipGuard ownershipGuard,
    required String? Function() currentUserId,
    AccountRepository? accountRepository,
    CaptureBackendClient? client,
    bool? backendConfigured,
    Future<String> Function()? loadInstallId,
    // MALI-026 (B8-2.10 §12): the money-authority mode. Defaults to legacy, so
    // v29 capture ingestion is unchanged; only canonical mode makes a
    // numeric-only (no exact amount_text) capture unconditionally pending.
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
    // `local_auto_confirm_v2` on-device recovery of a backend-rejected capture.
    // All three are injected (no use case is built here). The recovery callback
    // MUST be strictly on-device (`onDeviceOnly: true`): no AI, discovery or
    // enrichment. Absent callback or flag off/throwing => today's behaviour.
    Future<CapturedMessageResult> Function(CapturedMessage message)?
        recoverLocally,
    Future<SharedCapturedMessage?> Function(String payloadId)?
        lookupNativeCapture,
    bool Function()? isLocalAutoConfirmV2,
    // A-12-min R2: the one native upload gate, consulted before ANY replay.
    Future<CaptureUploadAuthorization> Function(String payloadId)?
        authorizeUpload,
  })  : _authorizeUpload = authorizeUpload,
        _recoverLocally = recoverLocally,
        _lookupNativeCapture = lookupNativeCapture,
        _isLocalAutoConfirmV2 = isLocalAutoConfirmV2,
        _settingsRepository = settingsRepository,
        _transactionRepository = transactionRepository,
        _dedupStore = dedupStore,
        _smartInboxRepository = smartInboxRepository,
        _suspectedDuplicateRepository = suspectedDuplicateRepository,
        _registrationService = registrationService,
        _ownershipGuard = ownershipGuard,
        _currentUserId = currentUserId,
        _accountRepository = accountRepository,
        _client = client,
        _backendConfigured = backendConfigured,
        _loadInstallId = loadInstallId,
        _coordinator = coordinator;

  static final DateTime _payloadMarkerTime =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  final DriftUserSettingsRepository _settingsRepository;
  final DriftTransactionRepository _transactionRepository;
  final DriftDedupStore _dedupStore;
  final DriftSmartInboxRepository _smartInboxRepository;
  final DriftSuspectedDuplicateRepository _suspectedDuplicateRepository;
  final CaptureDeviceRegistrationService _registrationService;
  final OwnershipGuard _ownershipGuard;
  final String? Function() _currentUserId;
  final AccountRepository? _accountRepository;
  final CaptureBackendClient? _client;
  final bool? _backendConfigured;
  final Future<String> Function()? _loadInstallId;
  final PlanningCutoverCoordinator _coordinator;
  final Future<CapturedMessageResult> Function(CapturedMessage message)?
      _recoverLocally;
  final Future<SharedCapturedMessage?> Function(String payloadId)?
      _lookupNativeCapture;
  final bool Function()? _isLocalAutoConfirmV2;
  final Future<CaptureUploadAuthorization> Function(String payloadId)?
      _authorizeUpload;

  // مزامنة واحدة في الرحلة الواحدة: الاستئناف (resume) وضغطة الإشعار يصلان
  // في نفس اللحظة تقريبًا، وبدون هذا القفل يجلب الاثنان نفس صفوف الـ relay
  // قبل أن يُسجَّل أيّ منهما كمستورد — فتُستورد العملية مرّتين.
  Future<CaptureSyncResult>? _inFlightSync;

  // MALI-029 (pull batching) — a currency→account map prefetched ONCE per sync
  // run instead of reloading the whole accounts table for every captured row
  // (`getAll()` was O(captures) full-table scans). Populated at the start of
  // _syncOnce and cleared when it finishes; sync() is single-flight, so there is
  // no concurrent run to share it. First-match-per-currency mirrors the previous
  // linear-scan behavior; a create-on-miss updates the map so later rows in the
  // same batch reuse the new account.
  Map<String, AccountEntity>? _currencyAccountCache;
  // Running total of accounts during a sync run, so a create-on-miss keeps the
  // exact isDefault (`total == 0`) and sortOrder (`total`) the per-row getAll()
  // path produced.
  int _currencyAccountTotal = 0;

  Future<CaptureSyncResult> sync() {
    final pending = _inFlightSync;
    if (pending != null) return pending;
    final run = _syncOnce().whenComplete(() {
      _inFlightSync = null;
      _currencyAccountCache = null;
    });
    _inFlightSync = run;
    return run;
  }

  Future<CaptureSyncResult> _syncOnce() async {
    // Bind the complete fetch/import/ack run to one account admission. The auth
    // UID is checked as well as the secure admission generation so an A fetch can
    // never resume against B (including A→B→A/same-UID re-login races).
    final admissionToken = await _ownershipGuard.capture();
    late final String? admittedUserId;
    try {
      admittedUserId = _currentUserId();
    } catch (_) {
      throw const StaleOwnershipException();
    }

    Future<void> requireCurrentAdmission() async {
      try {
        if (_currentUserId() != admittedUserId ||
            admissionToken.ownerUid != admittedUserId ||
            !await _ownershipGuard.isCurrent(admissionToken)) {
          throw const StaleOwnershipException();
        }
      } on StaleOwnershipException {
        rethrow;
      } catch (_) {
        throw const StaleOwnershipException();
      }
    }

    await requireCurrentAdmission();
    final settings = await _settingsRepository.getSettings();
    final backendConfigured = _backendConfigured ?? SupabaseConfig.isConfigured;
    if (!settings.cloudProcessingEnabled ||
        !backendConfigured ||
        ConsentAuthority.egressFrozen) {
      return const CaptureSyncResult(
        importedPayloadIds: {},
        ackedPayloadIds: {},
        needsReviewTransactionIds: [],
      );
    }

    await _registrationService.syncBackendState();
    // A-12-min R5: the legacy device-credential `sync-captures` (and its ACK)
    // runs only with a uid-bound ack for THIS user at Cloud ON. A failed link
    // never falls through to a projection that may still belong to another user.
    final secret = await _registrationService.isLinkedForCloud()
        ? await _registrationService.readDeviceSecret()
        : null;
    if (secret == null || secret.isEmpty) {
      return const CaptureSyncResult(
        importedPayloadIds: {},
        ackedPayloadIds: {},
        needsReviewTransactionIds: [],
      );
    }

    final client = _client ??
        CaptureBackendClient(
          supabaseUrl: SupabaseConfig.url,
          anonKey: SupabaseConfig.anonKey,
        );
    final installId = await (_loadInstallId ?? InstallId.get)();
    await requireCurrentAdmission();
    final captures = await client.syncCaptures(
      installId: installId,
      deviceSecret: secret,
    );
    Diag.log('[CaptureImport]', 'relay_fetched count=${captures.length}');

    // MALI-029 — prefetch accounts once (first-match-per-currency), reused for
    // every capture in this batch instead of a full accounts reload per row.
    _currencyAccountCache = await _buildCurrencyAccountCache();

    final imported = <String>{};
    final committedTransactions = <TransactionEntity>[];
    final needsReviewTransactionIds = <String>[];
    for (final capture in captures) {
      if (capture.payloadId.isEmpty) continue;
      // A ledger restore can preserve the transaction without the local
      // receipt. Repair that receipt under the same admission instead of
      // inserting the existing ID and blocking every newer relay result.
      final alreadyImported = await _dedupStore.runAtomically(() async {
        await requireCurrentAdmission();
        final found = await reconcileImportedPayload(capture.payloadId);
        await requireCurrentAdmission();
        return found;
      });
      if (alreadyImported) {
        imported.add(capture.payloadId);
        continue;
      }
      String? needsReviewTransactionId;
      try {
        needsReviewTransactionId = await _importCapture(
            capture, requireCurrentAdmission,
            onCommitted: committedTransactions.addAll);
      } catch (error) {
        // Release diagnostics contain no payload IDs, SMS, money or SQL.
        Diag.log('[CaptureImport]', 'relay_commit_failed class=${error.runtimeType}');
        rethrow;
      }
      if (needsReviewTransactionId != null) {
        needsReviewTransactionIds.add(needsReviewTransactionId);
      }
      imported.add(capture.payloadId);
    }

    if (imported.isNotEmpty) {
      // Native/relay deletion is a separate side-effect boundary. A stale run
      // leaves every capture server-side for the authoritative admission.
      await requireCurrentAdmission();
      await client.syncCaptures(
        installId: installId,
        deviceSecret: secret,
        ackPayloadIds: imported.toList(),
      );
    }

    return CaptureSyncResult(
      committedTransactions: committedTransactions,
      importedPayloadIds: imported,
      ackedPayloadIds: imported,
      needsReviewTransactionIds: needsReviewTransactionIds,
    );
  }

  Future<bool> isPayloadImported(String payloadId) async {
    final txId = await transactionIdForPayload(payloadId);
    if (txId == null) return false;
    // Older builds could commit this marker without preserving the capture.
    // It must not authorize native deletion until the deterministic review row
    // has also committed. A relay redelivery can then repair the legacy state;
    // if the relay expired, the native queue falls through to local ingestion.
    if (txId.startsWith('rejected:')) {
      return _smartInboxRepository.hasUnprocessableCapture(payloadId);
    }
    return true;
  }

  /// Retries a native payload whose extension may have been killed in-flight.
  /// False means cloud retry is disabled, so the caller may use local fallback.
  Future<bool> retryPendingSend(SharedCapturedMessage message) async {
    if (message.status != 'pendingSend' || message.id == null) return false;
    final settings = await _settingsRepository.getSettings();
    final configured = _backendConfigured ?? SupabaseConfig.isConfigured;
    if (!settings.cloudProcessingEnabled ||
        !configured ||
        ConsentAuthority.egressFrozen) {
      return false;
    }
    // A-12-min R2: native `authorizeUpload == allowed` is required for EVERY
    // upload, this replay included. localOnly (Cloud OFF / no mirror at capture
    // time, or a claimed item) is refused for good; waiting is retried later.
    // Only the iOS native v3 queue has this gate; a platform without it (no
    // `pendingSend` there) keeps its previous Cloud-ON behaviour.
    final gate = _authorizeUpload ??
        (NativeCaptureBridge.hasNativeQueue
            ? NativeCaptureBridge.authorizeCaptureUpload
            : null);
    final auth = gate != null
        ? await gate(message.id!)
        : CaptureUploadAuthorization(CaptureUploadDecision.allowed,
            ownerUid: _currentUserId(),
            allowAi: settings.aiConsentGranted,
            ownerGeneration: 0);
    if (auth.decision == CaptureUploadDecision.waiting) {
      throw const CaptureBackendException('upload_waiting');
    }
    if (!auth.allowed) return false;
    // C.1: an ownerless replay is impossible. The stamped owner and the owner
    // generation it was stamped under always travel together.
    final ownerUid = auth.ownerUid;
    final ownerGeneration = auth.ownerGeneration;
    if (ownerUid == null || ownerUid.isEmpty || ownerGeneration == null) {
      return false;
    }
    if (!await _registrationService.isLinkedForCloud()) return false;
    final secret = await _registrationService.readDeviceSecret();
    if (secret == null || secret.isEmpty) return false;
    final preferences = await LoadNotificationPreferencesUseCase(_settingsRepository).call();
    final client = _client ??
        CaptureBackendClient(
          supabaseUrl: SupabaseConfig.url,
          anonKey: SupabaseConfig.anonKey,
          notificationDetails: !preferences.hideLockScreenContent,
        );
    try {
      await client.processIosSms(
        installId: await (_loadInstallId ?? InstallId.get)(),
        deviceSecret: secret,
        payloadId: message.id!,
        // The server persists this value verbatim (processed_captures.parsed.
        // rawMessage) for every message regardless of outcome, so it must never
        // carry card/phone/account numbers or third-party beneficiary names —
        // sanitize on-device first, same discipline as SmsSanitizer's other
        // call sites (add_transaction_usecase.dart, bank_discovery_service.dart).
        smsText: SmsSanitizer.sanitize(message.text),
        sender: message.sender,
        receivedAt: message.receivedAt ?? DateTime.now().toUtc(),
        locale: settings.language,
        // The owner's consent mirror, never the install-level flag.
        allowAi: auth.allowAi,
        ownerUid: ownerUid,
        ownerGeneration: ownerGeneration,
        schemaV2: auth.contractV2,
      );
    } on CaptureBackendException catch (e) {
      // §4.8 / G1: a 409 (`capture_owner_mismatch`, `capture_owner_conflict`,
      // `capture_id_conflict`, `capture_expired`) is TERMINAL for the upload:
      // the caller parses on-device with no AI, and it is never retried.
      if (e.reason.endsWith('_409')) return false;
      rethrow;
    }
    return true;
  }

  Future<String?> transactionIdForPayload(String payloadId) {
    return _dedupStore.transactionIdFor(
      _payloadHash(payloadId),
      _payloadMarkerTime,
    );
  }

  /// Public so the native-queue drain can flag a payload it imported first;
  /// the next backend sync then skips (and acks) the same capture instead of
  /// importing it a second time.
  Future<void> markPayloadImported({
    required String payloadId,
    required String transactionId,
  }) {
    return _dedupStore.mark(
      _payloadHash(payloadId),
      transactionId: transactionId,
      occurredAt: _payloadMarkerTime,
    );
  }

  /// The identity and atomic-commit contract for ingesting [payloadId] on the
  /// native path: transaction id == payloadId, and the receipt commits in the
  /// same SQLite transaction as the transaction and its outbox row (I-3/I-5).
  CaptureCommit captureCommitFor(String payloadId) => CaptureCommit(
        captureId: payloadId,
        runAtomically: _dedupStore.runAtomically,
        writeReceipt: (transactionId) => markPayloadImported(
          payloadId: payloadId,
          transactionId: transactionId,
        ),
      );

  /// Pre-ingest guard for the native drain. True when [payloadId] already has a
  /// durable local result — a receipt, or a transaction whose id IS the
  /// payload id (the relay or an earlier drain created it) — so it must not be
  /// ingested again. A transaction without its receipt gets the receipt here.
  Future<bool> reconcileImportedPayload(String payloadId) async {
    if (await isPayloadImported(payloadId)) return true;
    if (await _transactionRepository.getById(payloadId) == null) return false;
    await markPayloadImported(payloadId: payloadId, transactionId: payloadId);
    return true;
  }

  /// Converts an otherwise lossy native capture into a durable Smart Inbox
  /// review item and records the permanent payload marker in one transaction.
  /// A re-delivery after commit-before-native-ack sees the marker (and the same
  /// deterministic review id), so it cannot create a second logical item.
  ///
  /// Ownership is checked inside the database transaction both before and
  /// after the writes. A generation change throws, rolling the transaction
  /// back; the caller must then leave the native lease unacknowledged.
  Future<String> persistUnprocessableCapture(
    SharedCapturedMessage message, {
    required Future<bool> Function() isOwnerCurrent,
  }) async {
    final payloadId = message.id?.trim();
    if (payloadId == null || payloadId.isEmpty) {
      throw StateError('unprocessable_capture_missing_payload_id');
    }
    return _dedupStore.runAtomically(() async {
      Future<void> requireOwner() async {
        if (!await isOwnerCurrent()) throw const StaleOwnershipException();
      }

      await requireOwner();
      final itemId = await _saveUnprocessableCaptureAndMarker(
        payloadId: payloadId,
        rawMessage: message.text,
        source: message.source.name,
        senderId: message.sender,
        receivedAt: message.receivedAt,
        requireCurrentAdmission: requireOwner,
      );
      await requireOwner();
      return itemId;
    });
  }

  /// Writes the deterministic Smart Inbox row and permanent payload marker.
  /// The caller owns the surrounding database transaction.
  Future<String> _saveUnprocessableCaptureAndMarker({
    required String payloadId,
    required String rawMessage,
    required String source,
    String? senderId,
    DateTime? receivedAt,
    Future<void> Function()? requireCurrentAdmission,
  }) async {
    await requireCurrentAdmission?.call();
    final itemId = await _smartInboxRepository.saveUnprocessableCapture(
      payloadId: payloadId,
      rawMessage: rawMessage,
      source: source,
      senderId: senderId,
      receivedAt: receivedAt,
      lang: LocalNotificationService.instance.notificationLanguage,
    );
    await requireCurrentAdmission?.call();
    await markPayloadImported(
      payloadId: payloadId,
      transactionId: 'smart_inbox:$itemId',
    );
    return itemId;
  }

  /// A backend `rejected` capture is an explicitly submitted capture that the
  /// parser could not turn into a transaction. The backend status vocabulary
  /// has no `ignored` state: its other terminal statuses are `processed`,
  /// `needs_review`, and `duplicate`. Therefore rejection is recoverable review
  /// work, while intentional OTP/promo drops remain the local ingest service's
  /// `ignored` disposition.
  Future<void> _persistBackendUnprocessableCapture(
    ProcessedCaptureDto capture,
    Future<void> Function() requireCurrentAdmission,
    List<TransactionEntity> committed,
  ) async {
    final parsed = capture.parsed;
    if (parsed['parserSource'] == 'ai_ignored') {
      await requireCurrentAdmission();
      await markPayloadImported(payloadId: capture.payloadId, transactionId: 'ignored');
      return;
    }
    final sanitizedText = capture.sanitizedText;
    final rawMessage = sanitizedText != null && sanitizedText.isNotEmpty
        ? sanitizedText
        : SmsSanitizer.sanitize(
            _string(parsed['rawMessage']) ??
                'Backend capture ${capture.payloadId} could not be parsed',
          );
    final settings = await _settingsRepository.getSettings();
    if (!(settings.cloudProcessingEnabled && settings.aiConsentGranted) &&
        parsed['parserSource'] != 'ai_pending' &&
        (capture.status == 'rejected' || capture.status == 'needs_review') &&
        await _recoverRejectedLocally(
          capture,
          committed: committed,
          serverText: rawMessage,
          requireCurrentAdmission: requireCurrentAdmission,
        )) {
      return;
    }
    await _saveUnprocessableCaptureAndMarker(
      payloadId: capture.payloadId,
      rawMessage: rawMessage,
      source: 'backend_${capture.status}',
      senderId: _string(parsed['senderId']),
      receivedAt: _date(parsed['comparisonTimestamp']) ?? capture.createdAt,
      requireCurrentAdmission: requireCurrentAdmission,
    );
  }

  bool _localRecoveryEnabled() {
    final read = _isLocalAutoConfirmV2;
    if (read == null || _recoverLocally == null) return false;
    try {
      return read() == true;
    } catch (_) {
      return false;
    }
  }

  /// One strictly on-device retry of a backend-rejected capture with the app's
  /// richer parser. Prefers the native raw text (same payloadId) over the
  /// server-sanitized text. Returns true only when a confirmed local
  /// transaction was written and the payload marker points at it; every other
  /// outcome (invalid, ignored, duplicate, pending, exception) rolls back any
  /// write the ingest made and returns false so the Smart Inbox path runs.
  /// A [StaleOwnershipException] propagates (caller's transaction rolls back).
  Future<bool> _recoverRejectedLocally(
    ProcessedCaptureDto capture, {
    required List<TransactionEntity> committed,
    required String serverText,
    required Future<void> Function() requireCurrentAdmission,
  }) async {
    if (!_localRecoveryEnabled()) return false;
    try {
      SharedCapturedMessage? native;
      try {
        final candidate = await _lookupNativeCapture?.call(capture.payloadId);
        if (candidate != null &&
            candidate.id?.trim() == capture.payloadId &&
            candidate.text.trim().isNotEmpty) {
          native = candidate;
        }
      } catch (_) {
        native = null;
      }
      final parsed = capture.parsed;
      final message = CapturedMessage(
        text: native?.text ?? serverText,
        senderId: native?.sender ?? _string(parsed['senderId']),
        source: native?.source ?? CapturedMessageSource.unknown,
        receivedAt: native?.receivedAt ??
            _date(parsed['comparisonTimestamp']) ??
            capture.createdAt,
      );
      await requireCurrentAdmission();
      // Nested (savepoint) transaction: a declined result rolls back whatever
      // the ingest wrote (e.g. a suspected-duplicate row) without touching the
      // outer transaction; the outer one still owns the marker write.
      final recovered = <TransactionEntity>[];
      final transactionId = await _dedupStore.runAtomically(() async {
        final result = await _recoverLocally!(message);
        final transaction = result.addTransactionResult.transaction;
        if (result.disposition == CapturedMessageDisposition.notifyOnly &&
            result.addTransactionResult.outcome ==
                AddTransactionOutcome.added &&
            transaction != null) {
          recovered.addAll(newlyAddedTransactions(result.addTransactionResult));
          return transaction.id;
        }
        throw const _RecoveryDeclined();
      });
      await requireCurrentAdmission();
      await markPayloadImported(
        payloadId: capture.payloadId,
        transactionId: transactionId,
      );
      committed.addAll(recovered);
      if (kDebugMode) {
        debugPrint(
          '[Capture] backend rejected recovered on-device '
          'source=${native != null ? 'native_raw' : 'server_sanitized'}',
        );
      }
      return true;
    } on StaleOwnershipException {
      rethrow;
    } catch (_) {
      // Includes _RecoveryDeclined: fall back to the Smart Inbox item.
      return false;
    }
  }

  /// CAP-5: imports one server-processed capture in ONE local transaction
  /// (transaction id = payload id, ledger outbox row and receipt included).
  /// The caller has already decided the result is importable: `rejected` and
  /// `needs_review` results never reach here (they take the local parser).
  /// Returns the transaction id when the user should review it.
  Future<String?> importServerCapture(
    ProcessedCaptureDto capture,
    Future<void> Function() requireCurrentAdmission, {
    void Function(List<TransactionEntity>)? onCommitted,
  }) =>
      _importCapture(capture, requireCurrentAdmission,
          onCommitted: onCommitted);

  Future<String?> _importCapture(
    ProcessedCaptureDto capture,
    Future<void> Function() requireCurrentAdmission, {
    void Function(List<TransactionEntity>)? onCommitted,
  }) async {
    final committed = <TransactionEntity>[];
    // One capture's account/review/transaction/dedup writes share a transaction.
    // The closing admission check is still inside that transaction, so an owner
    // change during any repository await rolls the complete capture back.
    final imported = await _dedupStore.runAtomically(() async {
      await requireCurrentAdmission();
      final result = await _importCaptureAtomically(
        capture,
        requireCurrentAdmission,
        committed,
      );
      await requireCurrentAdmission();
      return result;
    });
    onCommitted?.call(committed);
    return imported;
  }

  Future<String?> _importCaptureAtomically(
    ProcessedCaptureDto capture,
    Future<void> Function() requireCurrentAdmission,
    List<TransactionEntity> committed,
  ) async {
    final parsed = capture.parsed;
    // `rejected` is the backend's explicit unprocessable outcome. Never infer
    // an intentional drop from missing parsed fields: the native/local ingest
    // path alone produces the separate `ignored` OTP/promo disposition.
    if (capture.status == 'rejected') {
      await _persistBackendUnprocessableCapture(
          capture, requireCurrentAdmission, committed);
      return null;
    }
    // Under local_auto_confirm_v2 a server `needs_review` capture is not a
    // confirmation stage: it gets the same on-device recovery as `rejected`
    // (valid => confirmed, otherwise Smart Inbox), never a pending row.
    if (capture.status == 'needs_review' && _localRecoveryEnabled()) {
      await _persistBackendUnprocessableCapture(
          capture, requireCurrentAdmission, committed);
      return null;
    }
    var duplicateOf = _string(parsed['possibleDuplicateOfTransactionId']);
    final duplicatePayloadId = _string(parsed['possibleDuplicateOfPayloadId']);
    if (duplicateOf == null && duplicatePayloadId != null) {
      duplicateOf = await _dedupStore.transactionIdFor(
        _payloadHash(duplicatePayloadId),
        _payloadMarkerTime,
      );
    }
    if (capture.status == 'duplicate' && duplicateOf != null) {
      final duplicateCurrency =
          (_string(parsed['currency']) ?? 'SAR').trim().toUpperCase();
      final duplicateAmountText = _string(parsed['amount_text']);
      final duplicateNumericAmount = _num(parsed['amount']);
      late final Money duplicateAmountMoney;
      if (duplicateAmountText != null) {
        try {
          duplicateAmountMoney =
              parseCaptureMoney(duplicateAmountText, duplicateCurrency);
        } on Exception {
          // LEGACY_LOSSY compatibility for an already-decoded duplicate DTO.
          duplicateAmountMoney = legacyLossyNumberToMoney(
            duplicateNumericAmount ?? 0,
            duplicateCurrency,
          );
        }
      } else {
        // LEGACY_LOSSY compatibility for an old duplicate DTO without text.
        duplicateAmountMoney = legacyLossyNumberToMoney(
          duplicateNumericAmount ?? 0,
          duplicateCurrency,
        );
      }
      await requireCurrentAdmission();
      await _suspectedDuplicateRepository.save(
        SuspectedDuplicateEntity(
          id: capture.payloadId,
          rawMessage:
              _string(parsed['rawMessage']) ?? capture.sanitizedText ?? '',
          senderId: _string(parsed['senderId']),
          existingTransactionId: duplicateOf,
          amountMoney: duplicateAmountMoney,
          currency: duplicateCurrency,
          rawMerchant: MerchantSanity.forMessage(
            _string(parsed['merchant']),
            _string(parsed['rawMessage']) ?? capture.sanitizedText ?? '',
          ),
          occurredAt: _date(parsed['occurredAt']) ??
              capture.createdAt ??
              DateTime.now().toUtc(),
          createdAt: DateTime.now().toUtc(),
          cardLast4: _string(parsed['last4']),
          comparisonTimestamp: _date(parsed['comparisonTimestamp']),
          comparisonTimestampSource:
              _comparisonSource(_string(parsed['comparisonTimestampSource'])),
          duplicateReason: 'backend_suspicious_duplicate',
        ),
      );
      await requireCurrentAdmission();
      await markPayloadImported(
        payloadId: capture.payloadId,
        transactionId: duplicateOf,
      );
      return null;
    }

    final amount = _num(parsed['amount']);
    final amountText = _string(parsed['amount_text']);
    final currency = _string(parsed['currency']);
    if ((amount == null && amountText == null) || currency == null) {
      await _persistBackendUnprocessableCapture(
          capture, requireCurrentAdmission, committed);
      return null;
    }

    final now = DateTime.now().toUtc();
    final normalizedCurrency = currency.trim().toUpperCase();
    late final Money amountMoney;
    var legacyLossyReview = false;
    if (amountText != null) {
      try {
        amountMoney = parseCaptureMoney(amountText, normalizedCurrency);
      } on Exception {
        if (amount == null) {
          await _persistBackendUnprocessableCapture(
              capture, requireCurrentAdmission, committed);
          return null;
        }
        // LEGACY_LOSSY capture fallback (pending review).
        amountMoney = legacyLossyNumberToMoney(amount, normalizedCurrency);
        legacyLossyReview = true;
      }
    } else {
      // LEGACY_LOSSY deployed-backend compatibility: no amount_text yet.
      amountMoney = legacyLossyNumberToMoney(amount!, normalizedCurrency);
      legacyLossyReview = true;
    }
    // MALI-026 (B8-2.10 §12/§13): route ingestion through the explicit ingress
    // resolver. In canonical mode a numeric-only / non-exact capture can NEVER
    // auto-confirm into canonical authority — it is forced to pending review.
    // Legacy (v29) is unchanged: exact text confirms, numeric-only reviews.
    final requiresReview = resolveAiCaptureIngress(
          hasExactText: !legacyLossyReview,
          canonicalMode: _coordinator.state() == PlanningCutoverState.canonical,
        ) ==
        AiCaptureIngress.legacyPendingReview;
    final account = await _accountForCurrency(
      normalizedCurrency,
      requireCurrentAdmission,
    );
    final occurredAt = _date(parsed['occurredAt']) ??
        _date(parsed['comparisonTimestamp']) ??
        capture.createdAt ??
        now;
    final comparisonTimestamp =
        _date(parsed['comparisonTimestamp']) ?? occurredAt;
    final source = _comparisonSource(
      _string(parsed['comparisonTimestampSource']),
    );
    final rawMessage = _string(parsed['rawMessage']) ??
        capture.sanitizedText ??
        'Backend processed capture ${capture.payloadId}';
    final direction = _direction(_string(parsed['direction']));
    var type = _type(_string(parsed['type']));
    // نفس محاسبة التحويلات في AddTransactionUseCase: النقل بين حساباتك محايد،
    // أما الصادر لخارجها فمصروف والوارد دخل — وإلا تُستبعد من الإجماليات خطأً.
    if (type == TransactionTypeEntity.transfer &&
        !AddTransactionUseCase.looksLikeInternalTransfer(rawMessage)) {
      if (direction == TransactionDirectionEntity.debit) {
        type = TransactionTypeEntity.payment;
      } else if (direction == TransactionDirectionEntity.credit) {
        type = TransactionTypeEntity.income;
      }
    }
    final transaction = TransactionEntity(
      // The payload id IS the transaction's identity. The outbox push uses the
      // local id as client_request_id, and the server's direct-write (Phase 5)
      // stores the same payloadId there — so this import's push UPDATES the
      // server row the edge function already wrote instead of duplicating it.
      // isPayloadImported() above guarantees this id is never inserted twice.
      id: capture.payloadId,
      amountMoney: amountMoney,
      currency: normalizedCurrency,
      accountId: account?.id,
      type: type,
      source: const {'ai', 'ai_hybrid'}.contains(_string(parsed['parserSource']))
          ? TransactionSourceEntity.aiParsed
          : TransactionSourceEntity.bank,
      occurredAt: occurredAt,
      rawMessage: rawMessage,
      parseConfidence: _num(parsed['confidence']) ?? 0.8,
      // capture بحالة duplicate تصل هنا فقط عندما تعذّر ربطها بعمليتها
      // الأصلية محليًا (سجل الربط فُقد أو الأصل على جهاز آخر) — لا تُعتمد
      // أبدًا كمؤكَّدة، وإلا حُسب المبلغ مرّتين بصمت رغم إشعار "مشابهة".
      status: requiresReview ||
              capture.status == 'needs_review' ||
              capture.status == 'duplicate'
          ? TransactionStatus.pending
          : TransactionStatus.confirmed,
      createdAt: now,
      updatedAt: now,
      rawMerchant: MerchantSanity.forMessage(
        _string(parsed['merchant']),
        rawMessage,
      ),
      cardLast4: _string(parsed['last4']),
      direction: direction,
      transactionTimeFromSms:
          source == ComparisonTimestampSource.smsBody ? occurredAt : null,
      smsReceivedAt: source == ComparisonTimestampSource.receivedAt
          ? comparisonTimestamp
          : null,
      comparisonTimestamp: comparisonTimestamp,
      comparisonTimestampSource: source,
      duplicateStatus:
          _string(parsed['duplicateStatus']) == 'suspicious_duplicate'
              ? DuplicateStatus.suspiciousDuplicate
              : DuplicateStatus.normal,
      possibleDuplicateOfTransactionId:
          _string(parsed['possibleDuplicateOfTransactionId']),
      duplicateReason: _string(parsed['duplicateReason']),
    );
    // Atomic import (MALI-012): the surrounding per-capture transaction includes
    // any account creation, the transaction/outbox row, and its dedup marker.
    await requireCurrentAdmission();
    final saved = await _transactionRepository.saveTransaction(
      transaction: transaction,
      categoryKey: _string(parsed['category']),
    );
    await requireCurrentAdmission();
    await markPayloadImported(
      payloadId: capture.payloadId,
      transactionId: saved.id,
    );
    committed.add(saved);
    return legacyLossyReview ||
            capture.status == 'needs_review' ||
            capture.status == 'duplicate'
        ? saved.id
        : null;
  }

  static String _payloadHash(String payloadId) => 'capture_payload:$payloadId';

  /// Prefetches the current accounts once per sync run into a first-match-per-
  /// currency map (mirroring the previous linear scan) and records the total for
  /// create-on-miss bookkeeping.
  Future<Map<String, AccountEntity>> _buildCurrencyAccountCache() async {
    final repository = _accountRepository;
    if (repository == null) {
      _currencyAccountTotal = 0;
      return {};
    }
    final accounts = await repository.getAll();
    _currencyAccountTotal = accounts.length;
    final cache = <String, AccountEntity>{};
    for (final account in accounts) {
      cache.putIfAbsent(account.currency.trim().toUpperCase(), () => account);
    }
    return cache;
  }

  Future<AccountEntity> _createAccountForCurrency(
    AccountRepository repository,
    String normalized, {
    required bool isDefault,
    required int sortOrder,
    required Future<void> Function() requireCurrentAdmission,
  }) async {
    final now = DateTime.now().toUtc();
    await requireCurrentAdmission();
    return repository.create(
      AccountEntity(
        id: '',
        name: 'حساب $normalized',
        currency: normalized,
        type: AccountType.bank,
        isDefault: isDefault,
        sortOrder: sortOrder,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<AccountEntity?> _accountForCurrency(
    String currency,
    Future<void> Function() requireCurrentAdmission,
  ) async {
    final normalized = currency.trim().toUpperCase();
    if (normalized.isEmpty) return null;
    final repository = _accountRepository;
    if (repository == null) return null;

    // Fast path: the run-scoped cache (one getAll() for the whole batch).
    final cache = _currencyAccountCache;
    if (cache != null) {
      final hit = cache[normalized];
      if (hit != null) return hit;
      final created = await _createAccountForCurrency(
        repository,
        normalized,
        isDefault: _currencyAccountTotal == 0,
        sortOrder: _currencyAccountTotal,
        requireCurrentAdmission: requireCurrentAdmission,
      );
      _currencyAccountTotal++;
      cache[normalized] = created;
      return created;
    }

    // Fallback (no active sync run): the original per-call behavior.
    final accounts = await repository.getAll();
    for (final account in accounts) {
      if (account.currency.trim().toUpperCase() == normalized) {
        return account;
      }
    }
    return _createAccountForCurrency(
      repository,
      normalized,
      isDefault: accounts.isEmpty,
      sortOrder: accounts.length,
      requireCurrentAdmission: requireCurrentAdmission,
    );
  }

  static String? _string(Object? value) {
    if (value is! String) return null;
    final clean = value.trim();
    return clean.isEmpty ? null : clean;
  }

  static double? _num(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static DateTime? _date(Object? value) {
    if (value is! String) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  static TransactionTypeEntity _type(String? value) {
    return switch (value) {
      'payment' => TransactionTypeEntity.payment,
      'withdrawal' => TransactionTypeEntity.withdrawal,
      'transfer' => TransactionTypeEntity.transfer,
      'refund' => TransactionTypeEntity.refund,
      'income' => TransactionTypeEntity.income,
      _ => TransactionTypeEntity.unknown,
    };
  }

  static TransactionDirectionEntity _direction(String? value) {
    return switch (value) {
      'credit' => TransactionDirectionEntity.credit,
      'debit' => TransactionDirectionEntity.debit,
      _ => TransactionDirectionEntity.unknown,
    };
  }

  static ComparisonTimestampSource _comparisonSource(String? value) {
    return value == 'sms_body'
        ? ComparisonTimestampSource.smsBody
        : ComparisonTimestampSource.receivedAt;
  }
}
