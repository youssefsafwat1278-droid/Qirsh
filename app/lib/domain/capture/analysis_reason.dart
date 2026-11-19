// Gemini-first analysis, phase 1: why a bank message was not recorded, as the
// closed code the server returns (`parsed.reasonCode`,
// supabase/functions/_shared/analysis_reasons.ts), and the model's reading of
// a capture held for a one-tap confirmation (`parsed.proposal`). The app
// words every code itself; free text from the model is never shown.

import '../entities/smart_inbox_item_entity.dart';

abstract final class AnalysisReason {
  static const String otp = 'otp';
  static const String promo = 'promo';
  static const String declined = 'declined';
  static const String pending = 'pending';
  static const String balanceOnly = 'balance_only';
  static const String paymentReminder = 'payment_reminder';
  static const String ownAccount = 'own_account';
  static const String notFinancial = 'not_financial';
  static const String unclear = 'unclear';
  static const String duplicate = 'duplicate';
  static const String amountMismatch = 'amount_mismatch';
  static const String directionConflict = 'direction_conflict';

  static const List<String> all = [
    otp, promo, declined, pending, balanceOnly, paymentReminder, ownAccount,
    notFinancial, unclear, duplicate, amountMismatch, directionConflict,
  ];

  /// Codes for which a new analysis cannot record the message: the item is
  /// settled (or confirmed by the user), never re-analysed.
  static const Set<String> _settled = {
    otp, promo, declined, pending, balanceOnly, paymentReminder, ownAccount,
    notFinancial, duplicate, amountMismatch, directionConflict,
  };

  /// The device's own (or an older server's) review reason as a code. Twin
  /// of `meaningReasonCode` in `_shared/analysis_reasons.ts`.
  static const Map<String, String> _byReviewReason = {
    'otp_code': otp,
    'offer': promo,
    'declined_or_failed': declined,
    'cheque_returned': declined,
    'transaction_not_completed': declined,
    'pending': pending,
    'scheduled_or_expected': pending,
    'bill_due': paymentReminder,
    'summary': balanceOnly,
    'no_event_amount': notFinancial,
    'own_accounts': ownAccount,
    'card_repayment': ownAccount,
    'direction_contradiction': directionConflict,
    'amount_mismatch': amountMismatch,
  };

  /// A valid code, or null.
  static String? parse(Object? value) =>
      value is String && all.contains(value) ? value : null;

  /// The code that explains a Smart Inbox item: the server's code, else the
  /// stored review reason mapped to one. Null when no reason is known (the
  /// generic "unsupported" wording) or the analysis did not run
  /// ([SmartInboxReviewReason.analysisUnavailable] /
  /// [SmartInboxReviewReason.processingFailed]).
  static String? of({String? reasonCode, String? reviewReason}) {
    final code = parse(reasonCode);
    if (code != null) return code;
    if (reviewReason == null ||
        reviewReason == SmartInboxReviewReason.analysisUnavailable ||
        reviewReason == SmartInboxReviewReason.processingFailed) {
      return null;
    }
    return parse(reviewReason) ?? _byReviewReason[reviewReason] ?? unclear;
  }

  /// Whether a new AI analysis can change this item's outcome: it was never
  /// analysed by the model (captured offline, with AI off, or the analysis
  /// failed), and its reason does not already settle it.
  static bool canReanalyse({required String? code, required bool aiAnalysed}) {
    if (aiAnalysed) return false;
    return code == null || !_settled.contains(code);
  }
}

/// The model's reading of a capture held for confirmation. Holds no person
/// name: the server only ever sends a payment channel or a grounded merchant.
class CaptureProposal {
  const CaptureProposal({
    required this.amountText,
    required this.currency,
    required this.isDebit,
    this.category,
    this.merchant,
    this.counterpartyKind,
  });

  final String amountText;
  final String currency;
  final bool isDebit;
  final String? category;
  final String? merchant;
  final String? counterpartyKind;

  /// A well-formed proposal from the server's `parsed.proposal`, or null.
  static CaptureProposal? fromJson(Object? value) {
    if (value is! Map) return null;
    final amountText = value['amount_text'];
    final currency = value['currency'];
    final direction = value['direction'];
    if (amountText is! String ||
        !RegExp(r'^[0-9]+(?:\.[0-9]+)?$').hasMatch(amountText) ||
        (double.tryParse(amountText) ?? 0) <= 0 ||
        currency is! String ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(currency) ||
        (direction != 'debit' && direction != 'credit')) {
      return null;
    }
    String? text(Object? v) =>
        v is String && v.trim().isNotEmpty && v.length <= 80 ? v.trim() : null;
    return CaptureProposal(
      amountText: amountText,
      currency: currency,
      isDebit: direction == 'debit',
      category: text(value['category']),
      merchant: text(value['merchant']),
      counterpartyKind: text(value['counterpartyKind']),
    );
  }

  Map<String, Object?> toJson() => {
        'amount_text': amountText,
        'currency': currency,
        'direction': isDebit ? 'debit' : 'credit',
        if (category != null) 'category': category,
        if (merchant != null) 'merchant': merchant,
        if (counterpartyKind != null) 'counterpartyKind': counterpartyKind,
      };
}

/// What a server result tells the Smart Inbox about a capture it did not
/// record: the reason code, whether the model analysed it, and a proposal.
class ServerReviewInfo {
  const ServerReviewInfo({this.reasonCode, this.aiAnalysed = false, this.proposal});

  final String? reasonCode;
  final bool aiAnalysed;
  final CaptureProposal? proposal;

  static ServerReviewInfo? fromParsed(Map<String, dynamic>? parsed) {
    if (parsed == null) return null;
    final source = parsed['parserSource'];
    return ServerReviewInfo(
      reasonCode: AnalysisReason.parse(parsed['reasonCode']),
      aiAnalysed: source == 'ai' || source == 'ai_hybrid' ||
          (source == 'ai_ignored' && parsed['reasonCode'] != null),
      proposal: CaptureProposal.fromJson(parsed['proposal']),
    );
  }
}
