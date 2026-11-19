import '../../domain/capture/analysis_reason.dart';
import '../../domain/entities/smart_inbox_item_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../l10n/app_localizations.dart';

/// The app's own sentence for a not-recorded reason code (Gemini-first
/// phase 1). Never the model's free text.
String analysisReasonText(AppL10n l10n, String code) => switch (code) {
      AnalysisReason.otp => l10n.inboxReasonOtp,
      AnalysisReason.promo => l10n.inboxReasonPromo,
      AnalysisReason.declined => l10n.inboxReasonDeclined,
      AnalysisReason.pending => l10n.inboxReasonPending,
      AnalysisReason.balanceOnly => l10n.inboxReasonBalanceOnly,
      AnalysisReason.paymentReminder => l10n.inboxReasonPaymentReminder,
      AnalysisReason.ownAccount => l10n.inboxReasonOwnAccount,
      AnalysisReason.notFinancial => l10n.inboxReasonNotFinancial,
      AnalysisReason.duplicate => l10n.inboxReasonDuplicate,
      AnalysisReason.amountMismatch => l10n.inboxReasonAmountMismatch,
      AnalysisReason.directionConflict => l10n.inboxReasonDirectionConflict,
      _ => l10n.inboxReasonUnclear,
    };

/// The reason code that explains [item], or null (stored title stays).
String? inboxReasonCode(SmartInboxItemEntity item) => AnalysisReason.of(
    reasonCode: item.reasonCode, reviewReason: item.reviewReason);

/// The title a Smart Inbox card shows: the reason in the reader's language
/// when one is known, else the stored title.
String inboxItemTitle(AppL10n l10n, SmartInboxItemEntity item) {
  final code = inboxReasonCode(item);
  return code == null ? item.title : analysisReasonText(l10n, code);
}

/// Whether the "re-analyse with AI" action can change [item]'s outcome.
bool inboxCanReanalyse(SmartInboxItemEntity item) =>
    AnalysisReason.canReanalyse(
        code: inboxReasonCode(item), aiAnalysed: item.aiAnalysed);

/// A transfer to or from a person (Gemini-first phase 1) is shown as
/// "Transfer to/from a friend": its category is transfers, it is not one leg
/// of a move between the user's own accounts, and its merchant is empty or
/// only the payment channel (a person is never named). Null otherwise.
String? personTransferTitle(
    AppL10n l10n, TransactionEntity tx, String? categoryKey) {
  if (categoryKey != 'transfers' || tx.transferGroupId != null) return null;
  final merchant = tx.rawMerchant?.trim() ?? '';
  if (merchant.isNotEmpty && merchant.toLowerCase() != 'instapay') return null;
  return switch (tx.direction) {
    TransactionDirectionEntity.debit => l10n.txnTransferToFriend,
    TransactionDirectionEntity.credit => l10n.txnTransferFromFriend,
    _ => null,
  };
}
