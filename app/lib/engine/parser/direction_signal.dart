import '../models/transaction_type.dart';

/// Money-movement direction derived **independently** from explicit wording in
/// the message. It is used as a grounding cross-check against the classified
/// [TransactionType]: when the words say money came in but the type says it went
/// out (or vice-versa), the transaction must never auto-confirm.
enum TxnDirection {
  /// Money in (deposit, salary, incoming transfer, refund).
  credit,

  /// Money out (purchase, withdrawal, payment).
  debit,

  /// The text is not decisive on its own (both or neither family of words).
  unknown,
}

class DirectionSignal {
  const DirectionSignal._();

  // Words that clearly mean "money in". Intentionally avoids the bare tokens
  // "credit"/"debit" because they appear in "credit card" / "debit card".
  static const List<String> _creditWords = [
    'إيداع',
    'ايداع',
    'أُضيف',
    'أضيف',
    'اضيف',
    'إضافة',
    'اضافة',
    'تم إضافة',
    'تم اضافة',
    'تم استلام',
    'استلمت',
    'استلام',
    'مبلغ وارد',
    'حوالة واردة',
    // OR-04 (O-own P59/P60): an incoming transfer named as such ("تحويل
    // وارد", "Instant transfer in: SAR …"), as `creditKeywords` on the
    // server. Not a bare "transfer in" ("transfer initiated").
    'تحويل وارد',
    'transfer in:',
    // PR-01 / PR-08: incoming money worded with the money words added in
    // OR-01 (payroll, a posting to your account) or with no listed credit
    // word ("أودع", "قيد … لحسابك", "topped up", "You got", "وصلك"). Mirrored
    // in `creditKeywords` (process-ios-sms/parser_rules.json).
    'payroll',
    'wages',
    'cashback',
    'posted to your account',
    'posted to account',
    'into your account',
    'into account',
    'added to your account',
    'landed in your account',
    'arrived in account',
    'arrived in your account',
    'topped up',
    'you got',
    'sent to you',
    'أودع',
    'لحسابك',
    'وصلك',
    'راتب',
    'deposit',
    'salary',
    'credited',
    'received',
    'incoming',
    // ── refund / reversal ────────────────────────────────────────────────
    // `TransactionType.refund` is declared direction-unambiguous (incoming) by
    // the D2 polarity map, but this list could not recognise a single refund
    // message, so all 31 refund rows in the rev-4 baseline resolved to
    // `direction_ambiguous` and none could auto-commit. The architecture
    // asserted a polarity the lexicon was unable to detect.
    //
    // Admitted forms are unambiguous refund/reversal language ONLY. Matching
    // is substring-based, so a short token is a liability: bare `رد` is
    // deliberately ABSENT because it occurs inside `وارد` (incoming), `ترد`
    // and `يرد`, and bare `عكس` is ABSENT because it occurs inside `بالعكس`,
    // `عكسية` and `انعكاس`. Both would manufacture false INCOMING polarity on
    // ordinary text. The refund senses are reached through longer forms and
    // phrases instead.
    'استرداد',
    'مسترد',
    'مستردة',
    'رد مبلغ',
    'ردّ مبلغ',
    'إعادة مبلغ',
    'اعادة مبلغ',
    'عكس قيد',
    'عكس العملية',
    'refund',
    'refunded',
    'reversal',
    'reversed',
  ];

  // Words that clearly mean "money out".
  static const List<String> _debitWords = [
    'خصم',
    'خُصم',
    'تم الخصم',
    'شراء',
    'مشتريات',
    'دفع',
    'مدفوعات',
    'سحب',
    'مبلغ صادر',
    'صادر',
    'purchase',
    'payment',
    'paid',
    'debited',
    'withdrawn',
    'withdrawal',
    'deducted',
    'spent',
    'نقاط بيع',
  ];

  /// The direction strongly implied by the raw message text.
  /// Returns [TxnDirection.unknown] when both or neither family appears.
  /// The credit/debit vocabularies, exposed READ-ONLY so the proof evidence
  /// layer can reuse the SAME words this class matches on instead of keeping a
  /// second copy. Two lists would be two definitions of "what means money in",
  /// and they would drift.
  ///
  /// Additive only: `detect`/`ofType`/`contradicts` are unchanged.
  static List<String> get creditWords => _creditWords;
  static List<String> get debitWords => _debitWords;

  /// PR-08 — [text] names money both in and out (a word of each family).
  static bool isMixed(String text) {
    final lower = text.toLowerCase();
    return _creditWords.any(lower.contains) && _debitWords.any(lower.contains);
  }

  static TxnDirection detect(String text) {
    final lower = text.toLowerCase();
    final hasCredit = _creditWords.any(lower.contains);
    final hasDebit = _debitWords.any(lower.contains);
    if (hasCredit && !hasDebit) return TxnDirection.credit;
    if (hasDebit && !hasCredit) return TxnDirection.debit;
    return TxnDirection.unknown;
  }

  /// The direction implied by a classified [TransactionType], or
  /// [TxnDirection.unknown] when the type is inherently ambiguous (transfer).
  static TxnDirection ofType(TransactionType type) {
    switch (type) {
      case TransactionType.income:
      case TransactionType.refund:
        return TxnDirection.credit;
      case TransactionType.payment:
      case TransactionType.withdrawal:
      case TransactionType.creditCardPayment:
      case TransactionType.governmentPayment:
        return TxnDirection.debit;
      case TransactionType.transfer:
      case TransactionType.unknown:
        return TxnDirection.unknown;
    }
  }

  /// True only when the text direction and the type direction are **both known
  /// and opposite**. A contradicting transaction must be routed to pending.
  static bool contradicts(String text, TransactionType type) {
    final textDir = detect(text);
    final typeDir = ofType(type);
    if (textDir == TxnDirection.unknown || typeDir == TxnDirection.unknown) {
      return false;
    }
    return textDir != typeDir;
  }
}
