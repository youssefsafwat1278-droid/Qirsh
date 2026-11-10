/// Notification action identifiers. Twins of QirshNotificationCategories in
/// ios/BankMessageShortcuts/BankMessageShortcuts.swift (pinned by a test).
const kUnrecognizedCaptureCategory = 'QIRSH_UNRECOGNIZED_CAPTURE';
const kActionAddManually = 'qirsh.add_manually';
const kActionEnableSmartAnalysis = 'qirsh.enable_smart_analysis';

const _smartInboxMarkerPrefix = 'smart_inbox:';

/// Both APNs worker names and local NotificationType names share destinations.
String? notificationSectionRoute(String? type) => switch (type) {
      'budget_alert' ||
      'budget_warning' ||
      'budget_over' ||
      'budgetWarning' ||
      'budgetOver' =>
        '/budgets',
      'goal_milestone' || 'goalMilestone' => '/goals',
      'gamification_alert' ||
      'achievement' ||
      'achievements' =>
        '/achievements',
      'bill_reminder' || 'subscriptionReminder' => '/subscriptions',
      'weekly_report' || 'weeklyReport' => '/reports',
      'daily_reminder' ||
      'streak_reminder' ||
      'dailyReminder' =>
        '/transactions',
      'marketing' => '/dashboard',
      _ => null,
    };

/// Route for a tapped capture banner. Pure. [payloadTransactionId] is the
/// transaction id (or `smart_inbox:<itemId>` / `rejected:` marker) recorded for
/// the route's payload; it is only consulted when the route itself carries no
/// usable transaction id.
///
/// A `smart_inbox:` marker is the permanent payload marker of an unprocessable
/// capture, NOT a transaction: it must never become `/transaction/...`.
String captureRouteFor({
  String? type,
  String? transactionId,
  String? payloadTransactionId,
  String? confirmedTransactionId,
}) {
  final section = notificationSectionRoute(type);
  if (section != null) return section;
  // The local ledger is newer than the notification delivered in the past.
  // Only a verified confirmed row can override the old review destination.
  if (confirmedTransactionId != null &&
      confirmedTransactionId.isNotEmpty &&
      !confirmedTransactionId.startsWith(_smartInboxMarkerPrefix) &&
      !confirmedTransactionId.startsWith('rejected:')) {
    return '/transaction/$confirmedTransactionId';
  }
  if (type == 'needs_review' || type == 'suspicious_duplicate') {
    return '/smart-inbox';
  }
  for (final id in [transactionId, payloadTransactionId]) {
    if (id == null || id.isEmpty) continue;
    if (id.startsWith(_smartInboxMarkerPrefix)) return '/smart-inbox';
    if (id.startsWith('rejected:')) continue;
    return '/transaction/$id';
  }
  // Successful capture notifications can arrive before their local import.
  // Absence of a row is not evidence that the transaction needs review.
  return type == 'new_transaction' ? '/transactions' : '/smart-inbox';
}

/// The Smart Inbox item id behind a `smart_inbox:<itemId>` payload marker.
String? smartInboxItemIdFromMarker(String? marker) {
  if (marker == null || !marker.startsWith(_smartInboxMarkerPrefix)) {
    return null;
  }
  final id = marker.substring(_smartInboxMarkerPrefix.length);
  return id.isEmpty ? null : id;
}

/// Runs a banner action button. UI and data access are injected so the
/// dispatch is unit-testable. Never receives or logs the raw message text.
Future<void> handleCaptureNotificationAction({
  required String action,
  required String? smartInboxMarker,
  required void Function() showSmartInbox,
  required Future<bool> Function() openManualSheet,
  required Future<void> Function(String itemId) resolveItem,
  required Future<bool> Function() isSmartAnalysisGranted,
  required Future<bool> Function() openConsentSheet,
  required void Function() openPrivacy,
}) async {
  switch (action) {
    case kActionAddManually:
      showSmartInbox();
      final saved = await openManualSheet();
      final itemId = smartInboxItemIdFromMarker(smartInboxMarker);
      if (saved && itemId != null) await resolveItem(itemId);
    case kActionEnableSmartAnalysis:
      if (await isSmartAnalysisGranted()) {
        openPrivacy();
      } else {
        await openConsentSheet();
      }
  }
}
