class SmartInboxItemEntity {
  const SmartInboxItemEntity({
    required this.id,
    required this.type,
    required this.title,
    required this.status,
    required this.createdAt,
    this.transactionId,
    this.payloadId,
    this.body,
    this.confidence,
  });

  final String id;
  final String? transactionId;
  final String? payloadId;
  final String type;
  final String title;
  final String? body;
  final String status;
  final double? confidence;
  final DateTime createdAt;
}

/// Why a capture was parked in Smart Inbox, stored as `review_reason` in the
/// local row's metadata. Absent means "unsupported / not a transaction".
abstract final class SmartInboxReviewReason {
  /// The analysis could not run or complete (network, provider, rate limit,
  /// retries spent). A TEMPORARY condition — the row reads "awaiting analysis"
  /// and offers the retry action.
  static const String analysisUnavailable = 'analysis_unavailable';

  /// Local processing of this capture kept failing; it was parked for manual
  /// review.
  static const String processingFailed = 'processing_failed';
}
