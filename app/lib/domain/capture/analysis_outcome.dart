// Gemini-first phase 2: every captured bank message ends in one visible
// outcome. A financial one gets exactly one notification; a clearly
// non-financial one (OTP, advert, balance-only notice, nothing about money)
// gets none and is seen only in the analysis log. Twin of `analysisStateOf`
// in supabase/functions/_shared/capture_push.ts.

import '../entities/smart_inbox_item_entity.dart';
import 'analysis_reason.dart';

enum AnalysisOutcomeState {
  /// Recorded in the ledger.
  saved,

  /// Not recorded, for a settled reason; the user may record it anyway.
  notAdded,

  /// Held for one decision of the user.
  needsConfirmation,

  /// Kept on the device; analysed automatically when the network or the
  /// provider is back.
  awaiting,
}

abstract final class AnalysisOutcome {
  /// Reason codes with no notification.
  static const Set<String> silentCodes = {
    AnalysisReason.otp,
    AnalysisReason.promo,
    AnalysisReason.notFinancial,
    AnalysisReason.balanceOnly,
  };

  /// Settled financial reasons: "not added because …".
  static const Set<String> notAddedCodes = {
    AnalysisReason.declined,
    AnalysisReason.pending,
    AnalysisReason.duplicate,
    AnalysisReason.paymentReminder,
    AnalysisReason.ownAccount,
  };

  /// A capture still unresolved this long after it arrived is handed to the
  /// user to record (owner decision, phase 2).
  static const Duration unresolvedLimit = Duration(hours: 24);

  static bool isSilent(String? code) => code != null && silentCodes.contains(code);

  /// The outcome of a capture that was not recorded, by its reason code (null:
  /// no reason known, it needs the user).
  static AnalysisOutcomeState forCode(String? code) =>
      code != null && (notAddedCodes.contains(code) || silentCodes.contains(code))
          ? AnalysisOutcomeState.notAdded
          : AnalysisOutcomeState.needsConfirmation;

  /// Whether [item] is a capture whose analysis never ran (provider or
  /// network down past [unresolvedLimit], or local processing kept failing):
  /// the user is asked to record it.
  static bool unanalysed(SmartInboxItemEntity item) =>
      item.reasonCode == null &&
      (item.reviewReason == SmartInboxReviewReason.analysisUnavailable ||
          item.reviewReason == SmartInboxReviewReason.processingFailed);

  /// The outcome of a capture held in the Smart Inbox.
  static AnalysisOutcomeState forInboxItem(SmartInboxItemEntity item) =>
      unanalysed(item)
          ? AnalysisOutcomeState.needsConfirmation
          : forCode(AnalysisReason.of(
              reasonCode: item.reasonCode, reviewReason: item.reviewReason));
}

/// What the device decided for one imported capture, and what the server
/// already told the user about it. Decides whether the device must notify.
class DeviceCaptureOutcome {
  const DeviceCaptureOutcome({
    required this.state,
    this.reasonCode,
    this.transactionId,
    this.proposal,
    this.serverState,
    this.serverPushed,
    this.unanalysed = false,
  });

  final AnalysisOutcomeState state;

  /// Why it was not recorded (null when saved or unknown).
  final String? reasonCode;
  final String? transactionId;
  final CaptureProposal? proposal;

  /// The outcome the server's push stated (`notification.analysisState`);
  /// null for a server build that states none (the server then owns the
  /// notification as before, and the device stays silent).
  final AnalysisOutcomeState? serverState;

  /// `notification.pushed`: false when no push went out; null while unknown.
  final bool? serverPushed;

  /// Parked by the device with no analysis (the 24-hour rule): no push was
  /// ever sent for it, so the device notifies whatever the server build.
  final bool unanalysed;

  bool get silent =>
      state == AnalysisOutcomeState.notAdded && AnalysisOutcome.isSilent(reasonCode);

  /// Whether the server's push is the notification for this outcome.
  bool get serverOwnsNotification => serverState == state && serverPushed != false;

  /// Whether a push stating another outcome may be on screen (replace it).
  bool get serverPushStale =>
      serverState != null && serverState != state && serverPushed != false;

  /// Whether the device must post this outcome's notification itself.
  bool get deviceNotifies =>
      !silent && (unanalysed || (serverState != null && !serverOwnsNotification));

  /// The server's stored notification read as an outcome (phase 2 fields).
  static ({AnalysisOutcomeState? state, bool? pushed}) serverNotice(
      Map<String, dynamic>? notification) {
    final state = switch (notification?['analysisState']) {
      'saved' => AnalysisOutcomeState.saved,
      'not_added' => AnalysisOutcomeState.notAdded,
      'needs_confirmation' => AnalysisOutcomeState.needsConfirmation,
      _ => null,
    };
    final pushed = notification?['pushed'];
    return (state: state, pushed: pushed is bool ? pushed : null);
  }
}
