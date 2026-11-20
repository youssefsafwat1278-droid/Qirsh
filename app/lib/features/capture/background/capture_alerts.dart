import '../../../data/db/app_database.dart';
import '../../../domain/entities/engagement_entities.dart';
import '../../../domain/usecases/ingest_captured_message_usecase.dart';
import '../services/capture_import_service.dart';
import '../../../domain/capture/analysis_outcome.dart';
import '../../../domain/capture/analysis_reason.dart';
import '../../../domain/entities/smart_inbox_item_entity.dart';
import '../../../engine/parser/parser_engine.dart';
import '../services/capture_notification_content.dart';
import '../services/outcome_notification_content.dart';
import '../services/capture_notify_v2.dart';
import '../services/legacy_capture_drain.dart';
import '../services/local_notification_service.dart';
import '../services/native_capture_bridge.dart';

/// The local notification of a freshly ingested capture. Shared by the
/// foreground shell and the headless cold-start drain, so both raise exactly
/// the same alerts for the same outcome.
///
/// Gemini-first phase 2: one notification stating the outcome (saved / not
/// added / needs your confirmation); none for a clearly non-financial message
/// (OTP, advert, balance-only notice). The caller withdraws this capture's
/// earlier "awaiting analysis" notice ([cancelAwaitingNotices]).
Future<void> showCapturedMessageNotification(
  CapturedMessageResult result,
  NotificationPreferences preferences,
) async {
  final lang = LocalNotificationService.instance.notificationLanguage;
  final transaction = result.addTransactionResult.transaction;
  Future<void> light(CaptureNotificationContent content) =>
      LocalNotificationService.instance.showLightCaptureNotification(
        title: content.title,
        body: content.body,
        preferences: preferences,
        stableId: result.notificationStableId,
      );
  switch (result.disposition) {
    case CapturedMessageDisposition.ignored:
      return;
    case CapturedMessageDisposition.notifyOnly:
      await light(buildOutcomeNotice(
          state: AnalysisOutcomeState.saved, tx: transaction, lang: lang));
    case CapturedMessageDisposition.requestConfirmation:
      if (transaction == null) return;
      final content = buildOutcomeNotice(
          state: AnalysisOutcomeState.needsConfirmation,
          tx: transaction,
          lang: lang);
      await LocalNotificationService.instance.showReviewNotification(
        transactionId: transaction.id,
        title: content.title,
        body: content.body,
        preferences: preferences,
      );
    case CapturedMessageDisposition.suspiciousDuplicate:
      await light(buildOutcomeNotice(
          state: AnalysisOutcomeState.notAdded,
          reasonCode: AnalysisReason.duplicate,
          tx: transaction,
          lang: lang));
    case CapturedMessageDisposition.unprocessable:
      final reason = result.addTransactionResult.reviewReason;
      final unanalysed = reason == SmartInboxReviewReason.analysisUnavailable ||
          reason == SmartInboxReviewReason.processingFailed;
      final code = AnalysisReason.of(reviewReason: reason);
      if (!unanalysed && AnalysisOutcome.isSilent(code)) return;
      await light(buildOutcomeNotice(
          state: unanalysed
              ? AnalysisOutcomeState.needsConfirmation
              : AnalysisOutcome.forCode(code),
          reasonCode: code,
          unanalysed: unanalysed,
          lang: lang));
  }
}

/// The stable notification id of a capture's outcome on the import path: its
/// "awaiting analysis" notice and a device outcome notice share it, so the
/// outcome replaces the wait.
String outcomeNotificationStableId(String payloadId) => 'outcome:$payloadId';

/// Withdraws the local "awaiting analysis" notices of captures whose outcome
/// is now shown elsewhere (the drain's own notification, or the server push).
Future<void> cancelAwaitingNotices(Iterable<String?> payloadIds,
    {Future<void> Function(String stableId)? cancel}) async {
  final sink = cancel ?? LocalNotificationService.instance.cancelCaptureLight;
  for (final id in payloadIds) {
    if (id == null || id.trim().isEmpty) continue;
    await sink(outcomeNotificationStableId(id.trim()));
  }
}

/// Posts one capture outcome notice (light capture channel, the user's
/// capture-notification setting applies). Injected in tests.
typedef OutcomeNoticeSink = Future<void> Function(
    String stableId, CaptureNotificationContent content,
    {String? transactionId, bool generic});

OutcomeNoticeSink _localNotice(NotificationPreferences preferences) =>
    (stableId, content, {transactionId, generic = false}) =>
        LocalNotificationService.instance.showLightCaptureNotification(
          title: content.title,
          body: content.body,
          preferences: preferences,
          stableId: stableId,
          genericContent: generic,
          transactionId: transactionId,
        );

/// The native item's failure reason when the App Intent showed its own
/// "awaiting analysis" banner (`awaitingNotifiedReason` in
/// BankMessageShortcuts.swift).
const String awaitingNotifiedByIntent = 'ai_primary_awaiting_notified';

/// Gemini-first phase 2: "awaiting analysis" for captures whose analysis
/// could not run on this pass (network or provider down). Once per capture,
/// never for a message the device's own filter reads as an OTP or advert.
Future<void> alertAwaitingAnalysis(
  AppDatabase database,
  List<SharedCapturedMessage> awaiting,
  NotificationPreferences preferences, {
  OutcomeNoticeSink? show,
  String? lang,
}) async {
  final state = CaptureNotificationState(database);
  final notice = show ?? _localNotice(preferences);
  final language =
      lang ?? LocalNotificationService.instance.notificationLanguage;
  for (final message in awaiting) {
    final id = message.id?.trim();
    if (id == null || id.isEmpty) continue;
    // The App Intent already said so when it queued it offline.
    if (message.failureReason?.trim() == awaitingNotifiedByIntent) continue;
    if (ParserEngine.isIgnoredMessage(message.text, senderId: message.sender)) {
      continue;
    }
    final key = 'awaiting:$id';
    if (await state.stateOf(key) != null) continue;
    // Nothing financial in it: shown as given, details hidden or not.
    await notice(outcomeNotificationStableId(id),
        buildOutcomeNotice(state: AnalysisOutcomeState.awaiting, lang: language),
        generic: true);
    await state.mark(key, CaptureAlertState.app);
  }
}

/// Gemini-first phase 2: the outcome notifications the device owns for
/// captures imported from a server result (iOS v3 import). The server's push
/// is the notification when it went out and states the same outcome; the
/// device notifies when no push went out, when its own import ended
/// differently (the stale push is withdrawn first), and for a capture parked
/// unanalysed after 24 hours. Once per capture ([CaptureNotificationState]).
Future<void> alertServerOutcomes(
  AppDatabase database,
  List<CaptureImportItem> imported,
  NotificationPreferences preferences, {
  Future<bool> Function(String payloadId, {bool includePush})? withdraw,
  OutcomeNoticeSink? show,
  Future<void> Function(String stableId)? cancel,
  String? lang,
}) async {
  final state = CaptureNotificationState(database);
  final language =
      lang ?? LocalNotificationService.instance.notificationLanguage;
  final notice = show ?? _localNotice(preferences);
  final withdrawAlert =
      withdraw ?? NativeCaptureBridge.withdrawDeliveredCaptureAlert;
  for (final item in imported) {
    final outcome = item.outcome;
    if (item.path == CaptureImportPath.alreadyImported) continue;
    // An older server contract, or a local import: the existing paths own
    // the notification; only the wait notice goes.
    if (outcome == null || (outcome.serverState == null && !outcome.unanalysed)) {
      await cancelAwaitingNotices([item.id], cancel: cancel);
      continue;
    }
    if (!outcome.deviceNotifies) {
      // The server's push (or nothing, for a silent message) is the outcome:
      // a "awaiting analysis" notice (the device's or the App Intent's) must
      // not stay beside it.
      await cancelAwaitingNotices([item.id], cancel: cancel);
      await withdrawAlert(item.id);
      continue;
    }
    if (await state.stateOf(item.id) != null) continue;
    await withdrawAlert(item.id, includePush: outcome.serverPushStale);
    final content = buildOutcomeNotice(
      state: outcome.state,
      reasonCode: outcome.reasonCode,
      unanalysed: outcome.unanalysed,
      tx: item.committedTransactions.isEmpty
          ? null
          : item.committedTransactions.first,
      proposal: outcome.proposal,
      lang: language,
    );
    // Same id as its "awaiting analysis" notice: this one replaces it.
    await notice(outcomeNotificationStableId(item.id), content,
        transactionId: outcome.transactionId);
    await state.mark(item.id, CaptureAlertState.app);
  }
}

/// CAP-7 (`capture_notify_v2`): the alerts for one v3 import run.
Future<void> alertImportedV2(
  AppDatabase database,
  List<CaptureImportItem> imported,
  NotificationPreferences preferences,
) async {
  final lang = LocalNotificationService.instance.notificationLanguage;
  final notifications = LocalNotificationService.instance;
  String two(int n) => n.toString().padLeft(2, '0');
  final now = DateTime.now();
  await CaptureNotifyV2(
    state: CaptureNotificationState(database),
    showIndividual: (local) =>
        showCapturedMessageNotification(local, preferences),
    showSummary: (count) {
      final content = buildCaptureSummaryContent(count, lang: lang);
      return notifications.showLightCaptureNotification(
        title: content.title,
        body: content.body,
        preferences: preferences,
        stableId: 'summary-${now.year}-${two(now.month)}-${two(now.day)}',
        genericContent: true,
      );
    },
    withdrawNativeAlert: NativeCaptureBridge.withdrawDeliveredCaptureAlert,
    showCorrection: (transactionId) {
      final content = buildCaptureCorrectionContent(lang: lang);
      return notifications.showLightCaptureNotification(
        title: content.title,
        body: content.body,
        preferences: preferences,
        stableId: 'corrected-$transactionId',
        genericContent: true,
        transactionId: transactionId,
      );
    },
  ).alertForImport(imported);
}

/// Gemini-first phase 2, the legacy drain (Android; iOS without the v3
/// import): "awaiting analysis" for first-time deferrals, one "record it"
/// notice for each capture parked after 24 hours, and the wait notice
/// withdrawn once a capture's own notification was shown.
Future<void> alertLegacyDrainOutcomes(
  AppDatabase database,
  LegacyDrainReport report,
  NotificationPreferences preferences,
) async {
  await alertAwaitingAnalysis(database, report.awaiting, preferences);
  await cancelAwaitingNotices(report.ingested.map((i) => i.message.id));
  await alertServerOutcomes(
    database,
    [
      for (final m in report.parked)
        if (m.id != null && m.id!.trim().isNotEmpty)
          CaptureImportItem(
            id: m.id!.trim(),
            path: CaptureImportPath.server,
            message: m,
            outcome: const DeviceCaptureOutcome(
                state: AnalysisOutcomeState.needsConfirmation,
                unanalysed: true),
          ),
    ],
    preferences,
  );
}
