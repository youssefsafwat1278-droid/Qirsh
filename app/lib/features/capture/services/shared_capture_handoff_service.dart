import '../../../data/db/ownership_guard.dart';
import '../../../domain/usecases/ingest_captured_message_usecase.dart';
import 'capture_sync_service.dart';
import 'native_capture_bridge.dart';

enum SharedCaptureHandoffOutcome { acknowledged, retained }

/// Owns the native capture acknowledgement boundary.
///
/// A message is acknowledged only after its durable local result has committed:
/// a transaction/review/duplicate marker supplied by ingest, a deliberately
/// ignored non-transaction, or a newly persisted unprocessable Smart Inbox row.
class SharedCaptureHandoffService {
  const SharedCaptureHandoffService({
    required CaptureSyncService captureSyncService,
    required Future<bool> Function() isOwnerCurrent,
    required Future<bool> Function(String payloadId) acknowledge,
  })  : _captureSyncService = captureSyncService,
        _isOwnerCurrent = isOwnerCurrent,
        _acknowledge = acknowledge;

  final CaptureSyncService _captureSyncService;
  final Future<bool> Function() _isOwnerCurrent;
  final Future<bool> Function(String payloadId) _acknowledge;

  Future<SharedCaptureHandoffOutcome> complete({
    required SharedCapturedMessage message,
    required CapturedMessageDisposition disposition,
    required String? transactionId,
    // Why an unprocessable capture is parked (labels the Smart Inbox row).
    String? reviewReason,
  }) async {
    if (!await _isOwnerCurrent()) throw const StaleOwnershipException();

    final payloadId = message.id?.trim();
    switch (disposition) {
      case CapturedMessageDisposition.unprocessable:
        // There is no transaction or suspected-duplicate record. The raw SMS
        // must first become a deterministic Smart Inbox review item; without a
        // stable payload id it cannot be made idempotent, so retain the lease.
        if (payloadId == null || payloadId.isEmpty) {
          return SharedCaptureHandoffOutcome.retained;
        }
        await _captureSyncService.persistUnprocessableCapture(
          message,
          isOwnerCurrent: _isOwnerCurrent,
          reviewReason: reviewReason,
        );
        break;
      case CapturedMessageDisposition.ignored:
        // Intentional non-transactions (OTP/promo) have no durable record by
        // design and may be dropped. A duplicate has a transaction id, so keep
        // the payload marker before acknowledging it.
        if (payloadId != null &&
            payloadId.isNotEmpty &&
            transactionId != null) {
          await _captureSyncService.markPayloadImported(
            payloadId: payloadId,
            transactionId: transactionId,
          );
        }
        break;
      case CapturedMessageDisposition.notifyOnly:
      case CapturedMessageDisposition.requestConfirmation:
      case CapturedMessageDisposition.suspiciousDuplicate:
        // These dispositions promise a committed transaction or persisted
        // suspected duplicate. Fail closed if that invariant is ever broken.
        if (transactionId == null) {
          return SharedCaptureHandoffOutcome.retained;
        }
        if (payloadId != null && payloadId.isNotEmpty) {
          await _captureSyncService.markPayloadImported(
            payloadId: payloadId,
            transactionId: transactionId,
          );
        }
        break;
    }

    if (payloadId == null || payloadId.isEmpty) {
      return SharedCaptureHandoffOutcome.retained;
    }
    if (!await _isOwnerCurrent()) throw const StaleOwnershipException();
    final acknowledged = await _acknowledge(payloadId);
    return acknowledged
        ? SharedCaptureHandoffOutcome.acknowledged
        : SharedCaptureHandoffOutcome.retained;
  }
}
