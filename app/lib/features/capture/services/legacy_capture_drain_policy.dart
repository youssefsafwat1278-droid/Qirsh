/// What the legacy native drain ([LegacyCaptureDrain]) does with one queued
/// capture once its receipt check found nothing imported.
enum LegacyDrainRoute {
  /// Leave it queued: the server still owns the analysis and its result
  /// cannot be read right now. Nothing is parsed, written or acknowledged.
  wait,

  /// Send the capture to the server with its OWN payload id, through the native
  /// upload gate. The server claim is idempotent: a capture it already holds is
  /// replayed, one it never received is analysed once.
  upload,

  /// AI is not selected: the shipped on-device ingest (no egress).
  ingest,

  /// On-device deterministic parse with binary acceptance and NO egress: a
  /// valid parse is a transaction, anything else is a Smart Inbox row.
  ingestOnDevice,

  /// The consented in-app AI request (sanitized text, gated HTTP client). A
  /// temporary failure leaves the capture queued under the retry ledger.
  ingestWithAi,
}

/// The routing rule, as a pure function so every branch is unit-tested.
///
/// - [aiSelected]: Cloud AND AI consent, read fresh for this message, and the
///   item is not `localOnly`. False always means on-device only.
/// - [uploadsNatively]: this platform has a native upload pipeline (the iOS App
///   Intent). Android has none.
/// - [inAppAiEnabled]: the in-app AI request is permitted for a platform
///   without that pipeline: the operator kill switch is on, the backend is
///   configured and `ConsentAuthority` allows `aiProcessing` right now.
/// - [mayUseAiFallback]: the shipped iOS rule (`nativeCaptureMayUseAiFallback`).
/// - [relayResultUnknown]: the relay pull failed, or this item's server result
///   could not be imported, on this drain.
LegacyDrainRoute legacyDrainRoute({
  required bool aiSelected,
  required String? status,
  required bool hasPayloadId,
  required String? failureReason,
  required bool mayUseAiFallback,
  required bool uploadsNatively,
  required bool inAppAiEnabled,
  required bool relayResultUnknown,
}) {
  if (!aiSelected) return LegacyDrainRoute.ingest;
  // No native upload pipeline (Android): nothing else ever analyses this
  // capture. AI when the user's settings and the kill switch allow it,
  // otherwise the deterministic parser.
  if (!uploadsNatively) {
    return inAppAiEnabled
        ? LegacyDrainRoute.ingestWithAi
        : LegacyDrainRoute.ingestOnDevice;
  }
  if (mayUseAiFallback) return LegacyDrainRoute.ingestWithAi;
  // Without a payload id nothing can be made idempotent on the server.
  if (!hasPayloadId) return LegacyDrainRoute.ingest;
  final reason = failureReason?.trim() ?? '';
  // The server already refused this capture for good at capture time.
  if (reason == 'http(409)') return LegacyDrainRoute.ingestOnDevice;
  // A `sent` capture the server analysed: while its result cannot be read,
  // doing anything else would later discard that result on the server ACK.
  if (relayResultUnknown && status == 'sent' && reason.isEmpty) {
    return LegacyDrainRoute.wait;
  }
  // Everything else has no readable server result: a `pendingSend` whose
  // upload may have been lost, a Share Extension `pending` item, an App Intent
  // `.waiting` item (stored as `sent`), a capture whose upload failed.
  return LegacyDrainRoute.upload;
}
