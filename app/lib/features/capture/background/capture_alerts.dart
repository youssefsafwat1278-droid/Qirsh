import '../../../data/db/app_database.dart';
import '../../../domain/entities/engagement_entities.dart';
import '../../../domain/usecases/ingest_captured_message_usecase.dart';
import '../services/capture_import_service.dart';
import '../services/capture_notification_content.dart';
import '../services/capture_notify_v2.dart';
import '../services/local_notification_service.dart';
import '../services/native_capture_bridge.dart';

/// The local notification of a freshly ingested capture. Shared by the
/// foreground shell and the headless cold-start drain, so both raise exactly
/// the same alerts for the same outcome.
Future<void> showCapturedMessageNotification(
  CapturedMessageResult result,
  NotificationPreferences preferences,
) async {
  switch (result.disposition) {
    case CapturedMessageDisposition.ignored:
      return;
    case CapturedMessageDisposition.notifyOnly:
      final content = buildConfirmedCaptureContent(
          result.addTransactionResult.transaction,
          lang: LocalNotificationService.instance.notificationLanguage);
      await LocalNotificationService.instance.showLightCaptureNotification(
        title: content.title,
        body: content.body,
        preferences: preferences,
        stableId: result.notificationStableId,
      );
    case CapturedMessageDisposition.requestConfirmation:
      final transaction = result.addTransactionResult.transaction;
      if (transaction == null) return;
      final content = buildReviewCaptureContent(
          result.addTransactionResult.transaction,
          lang: LocalNotificationService.instance.notificationLanguage);
      await LocalNotificationService.instance.showReviewNotification(
        transactionId: transaction.id,
        title: content.title,
        body: content.body,
        preferences: preferences,
      );
    case CapturedMessageDisposition.suspiciousDuplicate:
      final content = buildDuplicateCaptureContent(
          result.addTransactionResult.transaction,
          lang: LocalNotificationService.instance.notificationLanguage);
      await LocalNotificationService.instance.showLightCaptureNotification(
        title: content.title,
        body: content.body,
        preferences: preferences,
        stableId: result.notificationStableId,
      );
    case CapturedMessageDisposition.unprocessable:
      final unsupported = buildUnsupportedCaptureContent(
          lang: LocalNotificationService.instance.notificationLanguage);
      await LocalNotificationService.instance.showLightCaptureNotification(
        title: unsupported.title,
        body: unsupported.body,
        preferences: preferences,
        stableId: result.notificationStableId,
      );
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
