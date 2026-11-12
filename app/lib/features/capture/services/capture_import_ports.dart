import 'capture_backend_client.dart';
import 'native_capture_bridge.dart';

/// CAP-5 — the narrow seams [CaptureImportService] and its helpers work
/// against, so the import logic is tested with fakes and never touches a
/// platform channel or the network directly. Nothing here carries SMS content
/// into logs.

/// The native capture queue (queue v3, CAP-6a).
abstract class CaptureImportQueue {
  /// The ACTIVE owner's items; unbound and other owners' items are never
  /// returned (native consumption rule, §4.2).
  Future<List<SharedCapturedMessage>> peek();

  /// Removes one item after its local result committed. Idempotent.
  Future<bool> acknowledge(String payloadId);

  Future<CaptureOwnerRecord?> getOwner();

  /// Unbound items hinted to [uid] (count + senders + the CAS snapshot).
  Future<UnboundCaptureSummary> unboundSummary(String uid);

  Future<CaptureClaimResult> claim({
    required String uid,
    required int generation,
    required String replicaOwnerUid,
    required String sessionUid,
    required List<String> ids,
  });

  Future<CaptureClaimResult> discard({
    required String uid,
    required int generation,
    required String replicaOwnerUid,
    required String sessionUid,
    required List<String> ids,
  });

  Future<int> resolveLegacy({
    List<String> consumedIds,
    List<String> suspectedIds,
  });
}

/// [CaptureImportQueue] over the static [NativeCaptureBridge].
class NativeCaptureImportQueue implements CaptureImportQueue {
  const NativeCaptureImportQueue();

  @override
  Future<List<SharedCapturedMessage>> peek() =>
      NativeCaptureBridge.peekPendingSharedMessages();

  @override
  Future<bool> acknowledge(String payloadId) =>
      NativeCaptureBridge.acknowledgeSharedMessage(payloadId);

  @override
  Future<CaptureOwnerRecord?> getOwner() =>
      NativeCaptureBridge.getCaptureOwner();

  @override
  Future<UnboundCaptureSummary> unboundSummary(String uid) =>
      NativeCaptureBridge.unboundCaptureSummary(uid);

  @override
  Future<CaptureClaimResult> claim({
    required String uid,
    required int generation,
    required String replicaOwnerUid,
    required String sessionUid,
    required List<String> ids,
  }) =>
      NativeCaptureBridge.claimUnboundCaptures(
        uid: uid,
        generation: generation,
        replicaOwnerUid: replicaOwnerUid,
        sessionUid: sessionUid,
        ids: ids,
      );

  @override
  Future<CaptureClaimResult> discard({
    required String uid,
    required int generation,
    required String replicaOwnerUid,
    required String sessionUid,
    required List<String> ids,
  }) =>
      NativeCaptureBridge.discardUnboundCaptures(
        uid: uid,
        generation: generation,
        replicaOwnerUid: replicaOwnerUid,
        sessionUid: sessionUid,
        ids: ids,
      );

  @override
  Future<int> resolveLegacy({
    List<String> consumedIds = const [],
    List<String> suspectedIds = const [],
  }) =>
      NativeCaptureBridge.resolveLegacyCaptureItems(
        consumedIds: consumedIds,
        suspectedIds: suspectedIds,
      );
}

enum CaptureFetchStatus {
  /// Results were fetched (possibly none).
  ok,

  /// Cloud is off, the backend is not configured or the device has no secret:
  /// there is no server result to wait for.
  notConfigured,

  /// The server refused this owner (401/403/409): its results are not
  /// authoritative for this user, the device copy stays the source of truth.
  refused,

  /// Network, timeout, 429 or 5xx: nothing is known about the results.
  unavailable,
}

class CaptureServerFetch {
  const CaptureServerFetch(this.status,
      [this.results = const <String, ProcessedCaptureDto>{}]);

  final CaptureFetchStatus status;

  /// Keyed by payload id. Server rows in `consumed` / `expired` states are never
  /// listed, so an absent id means "no usable server result".
  final Map<String, ProcessedCaptureDto> results;
}

enum CaptureUploadStatus {
  /// The server accepted the replay; results are fetchable again.
  sent,

  /// The server answered 429: no further upload is attempted on this run and
  /// the retry waits at least the rate-limit floor.
  rateLimited,

  /// Cloud is off, or the capture may not leave the device: parse it locally.
  notAllowed,

  /// 409 (`capture_owner_conflict`, `capture_id_conflict`, owner mismatch):
  /// import locally, with no AI.
  conflict,

  /// In progress, retry-later, network or any other failure: try again later.
  unavailable,
}

/// Everything [CaptureImportService] needs from the server.
abstract class CaptureServerPort {
  Future<CaptureServerFetch> fetchResults();

  /// Replays a durable `pendingSend` item with its original idempotency key.
  Future<CaptureUploadStatus> retryUpload(SharedCapturedMessage message);

  /// Tombstones the results the device has committed. Idempotent.
  Future<void> acknowledge(List<String> payloadIds);
}
