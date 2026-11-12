import 'package:flutter/foundation.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/observability/diagnostics.dart';
import '../../../core/privacy/consent_authority.dart';
import '../../../data/db/ownership_guard.dart';
import '../../../domain/entities/captured_message.dart';
import '../../../domain/entities/smart_inbox_item_entity.dart';
import '../../../domain/entities/supporting_entities.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/errors/repo_exceptions.dart';
import '../../../domain/usecases/add_transaction_usecase.dart';
import '../../../domain/usecases/ingest_captured_message_usecase.dart';
import '../../../engine/parser/parser_engine.dart';
import 'budget_alert_commits.dart';
import 'capture_backend_client.dart';
import 'capture_notification_authority.dart';
import 'capture_retry_ledger.dart';
import 'capture_sync_service.dart';
import 'legacy_capture_drain_policy.dart';
import 'native_capture_ai_fallback.dart';
import 'native_capture_bridge.dart';
import 'shared_capture_handoff_service.dart';

/// One message the drain ingested on this run (parsed, by rule or by AI).
class LegacyDrainItem {
  const LegacyDrainItem(this.message, this.result);

  final SharedCapturedMessage message;
  final CapturedMessageResult result;
}

/// What one run of [LegacyCaptureDrain] did. Counts and local objects only.
class LegacyDrainReport {
  /// The relay pull needs re-authentication: nothing else ran.
  bool authRequiredBeforeDrain = false;

  /// A message hit an auth failure: the loop stopped, the rest stays queued.
  bool authRequired = false;

  /// The native queue could not be READ. Nothing was written or acknowledged.
  bool readFailed = false;

  /// The run stopped early (owner changed, or the host went away).
  bool stopped = false;

  /// Items returned by the native queue on this run.
  int queued = 0;

  CaptureSyncResult? backendSync;
  final List<LegacyDrainItem> ingested = [];
  final List<TransactionEntity> budgetCommits = [];
  bool smartInboxChanged = false;
}

/// The legacy native-queue drain (Android always; iOS unless
/// `capture_import_v3` is on), extracted from `AppShell._consumeSharedInput` so
/// the per-message loop can be executed in tests against a mocked native
/// channel and a fake network. AppShell is thin glue around [run]: it supplies
/// the notification / metrics callbacks and reacts to the [LegacyDrainReport].
///
/// Invariants (unchanged by the extraction):
///  - peek is non-destructive; a message is acknowledged only after its local
///    result committed (transaction, review row, suspected duplicate, or an
///    intentional deterministic ignore);
///  - tx.id == payloadId and the receipt commits in the same SQLite
///    transaction;
///  - consent is read fresh for every message;
///  - the whole run is bound to one account admission.
class LegacyCaptureDrain {
  LegacyCaptureDrain({
    required CaptureSyncService captureSync,
    required IngestCapturedMessageUseCase ingest,
    required Future<UserSettingsEntity> Function() loadSettings,
    required CaptureRetryLedger retryLedger,
    required bool Function(String key) flag,
    OwnershipGuard? ownershipGuard,
    Future<List<SharedCapturedMessage>> Function()? peek,
    Future<bool> Function(String payloadId)? acknowledge,
    bool Function()? uploadsNatively,
    bool Function()? aiAvailable,
  })  : _captureSync = captureSync,
        _aiAvailable = aiAvailable ?? (() => SupabaseConfig.isConfigured),
        _ingest = ingest,
        _loadSettings = loadSettings,
        _retryLedger = retryLedger,
        _flag = flag,
        _ownershipGuard = ownershipGuard ?? OwnershipGuard(),
        _peek = peek ?? NativeCaptureBridge.peekPendingSharedMessages,
        _acknowledge = acknowledge ?? NativeCaptureBridge.acknowledgeSharedMessage,
        _uploadsNatively =
            uploadsNatively ?? (() => NativeCaptureBridge.hasNativeQueue);

  final CaptureSyncService _captureSync;
  final IngestCapturedMessageUseCase _ingest;
  final Future<UserSettingsEntity> Function() _loadSettings;
  final CaptureRetryLedger _retryLedger;
  final bool Function(String key) _flag;
  final OwnershipGuard _ownershipGuard;
  final Future<List<SharedCapturedMessage>> Function() _peek;
  final Future<bool> Function(String payloadId) _acknowledge;
  final bool Function() _uploadsNatively;

  /// Whether an in-app AI client exists at all (the backend is configured).
  final bool Function() _aiAvailable;

  bool _flagOn(String key) {
    try {
      return _flag(key);
    } catch (_) {
      return false;
    }
  }

  /// Runs one drain. [isActive] false stops the run (the host was disposed);
  /// [onAcknowledged] is called once per natively acknowledged capture;
  /// [showLocalReview] shows the local notification of a freshly ingested
  /// capture when the local path owns it.
  Future<LegacyDrainReport> run({
    bool Function()? isActive,
    Future<void> Function(SharedCapturedMessage message)? onAcknowledged,
    Future<void> Function(LegacyDrainItem item)? showLocalReview,
  }) async {
    final report = LegacyDrainReport();
    bool active() => isActive?.call() ?? true;
    // Bind the whole drain to the current account admission. Sign-out rotates
    // this generation before wiping local/native state, so stale work cannot
    // persist or acknowledge a capture under the next account.
    final admissionToken = await _ownershipGuard.capture();
    Future<bool> isOwnerCurrent() => _ownershipGuard.isCurrent(admissionToken);

    CaptureSyncResult? backendSync;
    // The relay pull failed: nothing is known about server results, so a
    // server-analysed `sent` item must wait rather than be parked over them.
    var relayFetchFailed = false;
    try {
      backendSync = await _captureSync.sync();
    } on AuthRepoException {
      report.authRequiredBeforeDrain = true;
      return report;
    } catch (error) {
      relayFetchFailed = true;
      if (kDebugMode) {
        debugPrint('[Capture] backend sync skipped: $error');
      }
    }
    report.backendSync = backendSync;
    // Per-item lease (MALI-012): peek does NOT delete the native queue.
    // Each message is acknowledged (removed) individually only after its
    // local import committed — a kill anywhere in this loop re-delivers
    // exactly the unprocessed remainder on the next drain.
    final List<SharedCapturedMessage> messages;
    try {
      messages = await _peek();
    } on NativeCaptureReadException {
      // The queue could not be read: nothing is known, so nothing is written,
      // acknowledged or overwritten. The next drain (resume / poll) retries.
      report.readFailed = true;
      return report;
    }
    report.queued = messages.length;
    if (!active()) {
      report.stopped = true;
      return report;
    }
    if (kDebugMode) {
      debugPrint('[Capture] consumeSharedInput: ${messages.length} messages');
    }

    // A 429 on this drain: no further upload is attempted on it.
    var uploadRateLimited = false;
    // The in-app AI was unreachable (or rate limited) on this drain: the
    // remaining AI items are not sent either; they wait for their backoff.
    var aiUnavailable = false;
    var aiRateLimited = false;

    // Positive per-item acknowledgement: removes the leased message from
    // the native queue only after it was fully handled locally.
    Future<bool> ackMessage(SharedCapturedMessage message) async {
      final id = message.id;
      if (id == null || id.isEmpty) return false;
      if (!await isOwnerCurrent()) throw const StaleOwnershipException();
      final acked = await _acknowledge(id);
      // R9: one count per acknowledged capture (counts only, no content).
      if (acked) {
        await _retryLedger.clear(id);
        await onAcknowledged?.call(message);
      }
      return acked;
    }

    final handoff = SharedCaptureHandoffService(
      captureSyncService: _captureSync,
      isOwnerCurrent: isOwnerCurrent,
      acknowledge: (payloadId) async {
        final acked = await _acknowledge(payloadId);
        if (acked) await _retryLedger.clear(payloadId);
        return acked;
      },
    );

    // This pass could not finish [message]: record it. Retries back off and
    // are bounded; once spent, the full message is parked in Smart Inbox
    // (row + receipt in one transaction, then the native ack) where the user
    // can retry it — never an endless silent retry.
    Future<void> recordUnfinished(
      SharedCapturedMessage message,
      CaptureFailureKind kind, {
      bool rateLimited = false,
    }) async {
      final id = message.id?.trim();
      if (id == null || id.isEmpty) return;
      final decision =
          await _retryLedger.recordFailure(id, kind, rateLimited: rateLimited);
      // Counts and enum names only: no id, text, sender or amount.
      Diag.log(
          '[Capture]',
          'unfinished kind=${kind.name} attempts=${decision.attempts} '
              'exhausted=${decision.exhausted}');
      if (!decision.exhausted) return;
      await _captureSync.persistUnprocessableCapture(
        message,
        isOwnerCurrent: isOwnerCurrent,
        reviewReason: decision.kind == CaptureFailureKind.permanent
            ? SmartInboxReviewReason.processingFailed
            : SmartInboxReviewReason.analysisUnavailable,
      );
      await ackMessage(message);
      report.smartInboxChanged = true;
    }

    // The relay returned a result for this capture WITHOUT any text (see
    // CaptureSyncResult.deferredPayloadIds). The native copy is the only place
    // the message exists, so the local record is written from it, and only
    // then is the copy acknowledged; the next relay run ACKs the server row.
    Future<void> resolveDeferred(
      SharedCapturedMessage message,
      String payloadId,
      String reason,
    ) async {
      if (reason == CaptureSyncResult.deferredAiIgnored &&
          ParserEngine.isIgnoredMessage(message.text,
              senderId: message.sender)) {
        // The device's own deterministic OTP/promo filter agrees: an
        // intentional drop, recorded so the server row can be acknowledged.
        if (!await isOwnerCurrent()) throw const StaleOwnershipException();
        await _captureSync.markPayloadImported(
            payloadId: payloadId, transactionId: 'ignored');
      } else {
        await _captureSync.persistUnprocessableCapture(
          message,
          isOwnerCurrent: isOwnerCurrent,
          reviewReason: reason == CaptureSyncResult.deferredNoText
              ? SmartInboxReviewReason.analysisUnavailable
              : null,
        );
        report.smartInboxChanged = true;
      }
      await ackMessage(message);
    }

    for (final message in messages) {
      // كل رسالة في try مستقلة، والطابور الأصلي لا يُمسح دفعة واحدة بعد
      // الآن (MALI-012): الرسالة تُحذف من الطابور فقط بعد اكتمال معالجتها
      // (ack)، والفاشلة تبقى في الطابور كما هي وتُعاد محاولتها في السحب
      // التالي — لا فقدان للدفعة عند انهيار/انتهاء جلسة في المنتصف.
      if (!active()) {
        report.stopped = true;
        break;
      }
      try {
        if (!await isOwnerCurrent()) throw const StaleOwnershipException();
        // The payload id is the transaction id and the receipt key (I-5).
        final payloadId = message.id?.trim();
        final hasId = payloadId != null && payloadId.isNotEmpty;
        if (hasId) {
          final alreadySynced =
              backendSync?.importedPayloadIds.contains(message.id) ?? false;
          // Receipt OR a transaction already holding this id: never ingest
          // twice (the relay path or an earlier drain may have won). Checked
          // first, so a committed result is acknowledged without any upload.
          final alreadyImported = alreadySynced ||
              await _captureSync.reconcileImportedPayload(payloadId);
          if (alreadyImported) {
            if (kDebugMode) {
              debugPrint('[Capture] skip already imported backend payload');
            }
            await ackMessage(message);
            continue;
          }
          // The server answered without any text: resolve it from this copy.
          final deferral = backendSync?.deferredPayloadIds[payloadId];
          if (deferral != null) {
            await resolveDeferred(message, payloadId, deferral);
            continue;
          }
        }
        // Backing off after an earlier unfinished pass: nothing is re-sent
        // or re-parsed until the wait elapses. The checks above still ran, so
        // a result that committed meanwhile was acknowledged.
        if (hasId && !await _retryLedger.isDue(payloadId)) continue;
        if (kDebugMode) {
          debugPrint(
            '[Capture] processing: source=${message.source} '
            'senderSet=${message.sender != null} '
            'receivedAt=${message.receivedAt?.toIso8601String()} '
            'textLength=${message.text.length}',
          );
        }
        final captured = CapturedMessage(
          text: message.text,
          senderId: message.sender,
          source: message.source,
          // MALI-068n §11 — pass the resolved native time through as-is (null
          // when unknown). Do NOT stamp `now` here; AddTransactionUseCase
          // prefers the SMS-parsed date and owns the single documented
          // last-resort fallback.
          receivedAt: message.receivedAt,
        );
        // The durable native copy is the local recovery path. Consent is read
        // fresh for THIS message, on THIS pass: a consent revoked since an
        // earlier failed attempt never re-sends its SMS to the server or to
        // AI. A `localOnly` item is never AI-selected.
        final settings = await _loadSettings();
        final aiSelected = settings.cloudProcessingEnabled &&
            settings.aiConsentGranted &&
            message.localOnly != true;
        final aiAllowed = ConsentAuthority.decide(
          EgressClass.aiProcessing,
          settings,
        );
        var route = legacyDrainRoute(
          aiSelected: aiSelected,
          status: message.status,
          hasPayloadId: hasId,
          failureReason: message.failureReason,
          mayUseAiFallback: nativeCaptureMayUseAiFallback(
            status: message.status,
            failureReason: message.failureReason,
            flagEnabled: _flagOn('capture_ai_fallback_enabled'),
            aiAllowed: aiAllowed && message.localOnly != true,
          ),
          uploadsNatively: _uploadsNatively(),
          // Android: the operator kill switch (default ON), a configured
          // backend and the user's current consent, all three.
          inAppAiEnabled: _flagOn('android_capture_ai_enabled') &&
              _aiAvailable() &&
              aiAllowed,
          relayResultUnknown: relayFetchFailed ||
              (backendSync?.failedPayloadIds.contains(payloadId) ?? false),
        );
        if (route == LegacyDrainRoute.wait) {
          // The server still owns the analysis and its result is not readable
          // yet. Counted, so the wait is bounded and ends in Smart Inbox
          // rather than lasting forever.
          await recordUnfinished(message, CaptureFailureKind.temporary);
          continue;
        }
        if (route == LegacyDrainRoute.upload) {
          // A 429 earlier on this drain: this item's upload is not sent either.
          if (uploadRateLimited) {
            throw const CaptureBackendException('process_ios_sms_failed_429');
          }
          // A frozen egress gate is a transient state, not a refusal.
          if (ConsentAuthority.egressFrozen) {
            throw const CaptureBackendException('egress_frozen');
          }
          final sent = await _captureSync.retryPendingSend(message, true);
          if (sent) {
            backendSync = await _captureSync.sync();
            report.backendSync = backendSync;
            if (backendSync.importedPayloadIds.contains(payloadId) ||
                await _captureSync.isPayloadImported(payloadId!)) {
              await ackMessage(message);
              continue;
            }
            final deferral = backendSync.deferredPayloadIds[payloadId];
            if (deferral != null) {
              await resolveDeferred(message, payloadId, deferral);
              continue;
            }
            throw const CaptureBackendException(
                'backend_capture_not_observable');
          }
          // The capture may not leave the device (the native gate said
          // localOnly, the device is not linked) or the server refused it for
          // good (409): it is resolved here, deterministically, never by AI.
          route = LegacyDrainRoute.ingestOnDevice;
        }
        if (route == LegacyDrainRoute.ingestWithAi) {
          if (ParserEngine.isIgnoredMessage(message.text,
              senderId: message.sender)) {
            // The deterministic OTP/promo filter decides first: such a message
            // is never sent to AI, whatever its sender.
            route = LegacyDrainRoute.ingestOnDevice;
          } else if (aiUnavailable && hasId) {
            await recordUnfinished(message, CaptureFailureKind.temporary,
                rateLimited: aiRateLimited);
            continue;
          }
        }
        final result = await _ingest.fromCapturedMessage(
          captured,
          // Only the AI route may leave the device; consent is checked again,
          // fresh, inside the use case immediately before the request.
          onDeviceOnly: route != LegacyDrainRoute.ingestWithAi,
          // Binary local acceptance (valid => transaction, otherwise Smart
          // Inbox) wherever the on-device parser replaces a refused analysis.
          forceLocalAutoConfirm: route == LegacyDrainRoute.ingestOnDevice,
          // tx.id = payloadId, receipt in the same transaction. No payload
          // id (null/blank) keeps random ids and the post-hoc receipt.
          capture: hasId ? _captureSync.captureCommitFor(payloadId) : null,
        );
        final aiFailure = result.addTransactionResult.aiFailureReason;
        if (route == LegacyDrainRoute.ingestWithAi &&
            hasId &&
            result.addTransactionResult.outcome ==
                AddTransactionOutcome.notTransaction &&
            isTemporaryAiFailure(aiFailure)) {
          // Offline / provider down / rate limited: nothing was written. The
          // capture STAYS in the native queue and is retried with backoff; only
          // a spent retry budget parks it in Smart Inbox.
          aiUnavailable = true;
          aiRateLimited = aiFailure!.startsWith('http_429');
          await recordUnfinished(
            message,
            CaptureFailureKind.temporary,
            rateLimited: aiRateLimited,
          );
          continue;
        }
        report.budgetCommits
            .addAll(newlyAddedTransactions(result.addTransactionResult));
        if (kDebugMode) {
          debugPrint(
            '[Capture] disposition=${result.disposition} '
            'hasTransaction=${result.transactionId != null}',
          );
        }
        // The one ack boundary: transaction/review/duplicate outcomes get a
        // permanent payload marker; unprocessable captures first become a
        // deterministic Smart Inbox row containing the raw SMS. Only an
        // intentional ignored message may acknowledge without a durable row.
        final handoffOutcome = await handoff.complete(
          message: message,
          disposition: result.disposition,
          transactionId: result.transactionId,
          // A temporary AI failure reads "awaiting analysis", not
          // "unsupported", and keeps the retry action.
          reviewReason: isTemporaryAiFailure(aiFailure)
              ? SmartInboxReviewReason.analysisUnavailable
              : null,
        );
        if (handoffOutcome == SharedCaptureHandoffOutcome.acknowledged) {
          await onAcknowledged?.call(message);
        }
        if (result.disposition == CapturedMessageDisposition.unprocessable) {
          report.smartInboxChanged = true;
        }
        final item = LegacyDrainItem(message, result);
        report.ingested.add(item);
        // MALI-061n §12 — one authority per capture. Reached only for a
        // freshly-imported payload (the already-imported branch acks + skips
        // above) whose owner is valid (a stale owner throws AuthRepoException
        // above). The native App Intent / APNs preview owns it when
        // status=='sent'; a lost APNs response leaves status != 'sent', so the
        // local path still fires — losing the response never suppresses both.
        if (CaptureNotificationAuthority.shouldShowLocalReview(
          status: message.status,
          alreadyImported: false,
          ownerValid: true,
        )) {
          if (!await isOwnerCurrent()) {
            throw const StaleOwnershipException();
          }
          await showLocalReview?.call(item);
        }
      } on AuthRepoException {
        // Every remaining message would fail identically until re-auth —
        // stop draining. Nothing was deleted from the native queue (peek,
        // not consume), so this message AND the whole remainder stay leased
        // and are retried after the centralized recovery re-auths.
        report.authRequired = true;
        break;
      } on StaleOwnershipException {
        // The account admission changed while this drain was in flight.
        // Persist/marker transactions roll back and no native ack occurs;
        // stop so the new admission can make its own ownership decision.
        report.stopped = true;
        break;
      } catch (error) {
        // Not acked — the message stays in the native queue. Its retries are
        // bounded and backed off (a 429 stops further uploads on this drain).
        if (kDebugMode) {
          debugPrint('[Capture] message processing failed ($error)');
        }
        final rateLimited = CaptureRetryLedger.isRateLimited(error);
        if (rateLimited) uploadRateLimited = true;
        try {
          await recordUnfinished(
            message,
            CaptureRetryLedger.classify(error),
            rateLimited: rateLimited,
          );
        } on StaleOwnershipException {
          report.stopped = true;
          break;
        } catch (_) {
          // Parking failed too (e.g. the database): the item stays queued.
        }
      }
    }
    return report;
  }
}
