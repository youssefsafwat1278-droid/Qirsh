import 'dart:ui' show Locale;

import '../../../domain/capture/analysis_outcome.dart';
import '../../../domain/capture/analysis_reason.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../l10n/app_localizations.dart';
import '../analysis_reason_text.dart';
import 'capture_notification_content.dart';

/// Gemini-first phase 2: the one notification of a captured bank message,
/// stating its outcome in the reader's language — «سُجّل مصروف 250 EGP» with
/// the merchant and category, «لم تُضَف» / «تحتاج تأكيدك» with the app's
/// reason sentence, or «بانتظار التحليل». Never the SMS, never a person's
/// name, never the model's text. Twin of `analysisOutcomeAlert`
/// (supabase/functions/_shared/capture_push.ts).
CaptureNotificationContent buildOutcomeNotice({
  required AnalysisOutcomeState state,
  String? reasonCode,
  bool unanalysed = false,
  TransactionEntity? tx,
  CaptureProposal? proposal,
  String lang = 'ar',
}) {
  final l10n = lookupAppL10n(Locale(lang == 'en' ? 'en' : 'ar'));
  final amount = tx != null
      ? '${fmtCaptureMoney(tx.amountMoney)} ${tx.currency}'
      : proposal != null
          ? '${proposal.amountText} ${proposal.currency}'
          : null;
  String withAmount(String heading) =>
      amount == null ? heading : '$heading · $amount';
  switch (state) {
    case AnalysisOutcomeState.saved:
      if (tx == null || amount == null) {
        return CaptureNotificationContent(
            title: l10n.outcomeSavedTitle, body: l10n.outcomeSavedGeneric);
      }
      final friend = _isFriendTransfer(tx);
      final merchant = friend ? null : tx.rawMerchant?.trim();
      final category = captureCategoryLabel(tx.categoryId, lang: lang);
      final body = [
        if (merchant != null && merchant.isNotEmpty) merchant,
        if (category != null) category,
      ].join(' · ');
      return CaptureNotificationContent(
        title: l10n.outcomeSavedLine(_kind(l10n, tx, friend), amount),
        body: body.isEmpty ? l10n.outcomeSavedGeneric : body,
      );
    case AnalysisOutcomeState.notAdded:
      return CaptureNotificationContent(
        title: withAmount(l10n.outcomeNotAddedTitle),
        body: analysisReasonText(l10n, reasonCode ?? AnalysisReason.unclear),
      );
    case AnalysisOutcomeState.needsConfirmation:
      return CaptureNotificationContent(
        title: withAmount(l10n.outcomeNeedsConfirmationTitle),
        body: unanalysed || (reasonCode == null && tx == null)
            ? l10n.outcomeCouldNotAnalyse
            : reasonCode != null
                ? analysisReasonText(l10n, reasonCode)
                : l10n.outcomeTapToConfirm,
      );
    case AnalysisOutcomeState.awaiting:
      return CaptureNotificationContent(
          title: l10n.outcomeAwaitingTitle, body: l10n.outcomeAwaitingBody);
  }
}

/// A transfer to or from a person: no own-account pair, and no merchant but
/// at most the payment channel (the same reading as [personTransferTitle]).
bool _isFriendTransfer(TransactionEntity tx) {
  if (tx.type != TransactionTypeEntity.transfer || tx.transferGroupId != null) {
    return false;
  }
  final merchant = tx.rawMerchant?.trim() ?? '';
  return merchant.isEmpty || merchant.toLowerCase() == 'instapay';
}

String _kind(AppL10n l10n, TransactionEntity tx, bool friend) {
  final credit = tx.direction == TransactionDirectionEntity.credit;
  return switch (tx.type) {
    TransactionTypeEntity.refund => l10n.outcomeKindRefund,
    TransactionTypeEntity.withdrawal => l10n.outcomeKindWithdrawal,
    TransactionTypeEntity.transfer => friend
        ? (credit
            ? l10n.outcomeKindTransferFromFriend
            : l10n.outcomeKindTransferToFriend)
        : (credit ? l10n.outcomeKindTransferIn : l10n.outcomeKindTransferOut),
    TransactionTypeEntity.income => l10n.outcomeKindIncome,
    _ => credit ? l10n.outcomeKindIncome : l10n.outcomeKindExpense,
  };
}
