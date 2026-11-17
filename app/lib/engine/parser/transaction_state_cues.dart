import 'normalizer.dart';

/// DATA-01 — a bank message announcing a purchase that did NOT complete
/// (declined / failed / rejected / insufficient funds / limit exceeded).
///
/// Such a message is not a money movement and must never become a confirmed
/// transaction. A refund or reversal OF a declined/failed operation IS a money
/// movement, so the message's own credit action wins over the declined cue.
///
/// Cue vocabulary follows `proof/evidence.dart` `StateCueKind.declined`, but
/// scoped to phrases and whole tokens: the bare stems `رفض`, `فشل`, `لم يتم`
/// and `failed` occur in ordinary purchase messages (`لرفض العملية اتصل بنا`,
/// `إذا لم يتم التعرف على العملية`), where they report nothing about state.
///
/// Mirrored by `supabase/functions/process-ios-sms` (`declinedKeywords` /
/// `declinedExemptKeywords` in its `parser_rules.json`).
class TransactionStateCues {
  const TransactionStateCues._();

  static const List<String> declined = [
    // Arabic
    'مرفوضة', 'مرفوض', 'تم رفض', 'رفضت', 'تم الرفض',
    'فشلت', 'فاشلة', 'فشل العملية', 'فشل عملية', 'فشل الدفع', 'فشل السحب',
    'غير ناجحة', 'غير ناجح', 'لم تنجح', 'لم تتم بنجاح',
    'لم يتم تنفيذ العملية', 'لم يتم تنفيذ عملية', 'تعذر إتمام', 'تعذر اتمام',
    'تعذر تنفيذ',
    'رصيد غير كاف', 'رصيد غير كافي', 'رصيدك غير كاف', 'رصيدك غير كافي',
    'الرصيد غير كاف', 'الرصيد غير كافي', 'عدم كفاية الرصيد',
    'تجاوز الحد', 'تجاوزت الحد', 'تجاوز حد', 'تخطي الحد',
    // English
    'declined', 'rejected', 'unsuccessful', 'not successful', 'failed',
    'was not completed', 'could not be completed', 'not processed',
    'insufficient funds', 'insufficient balance',
    'limit exceeded', 'exceeded limit', 'exceeds limit', 'exceeds the limit',
    'exceeded the limit', 'exceeds your limit', 'exceeded your limit',
    'exceeds your credit limit', 'exceeded your credit limit',
  ];

  /// The message's own action returns money: it stays a real credit even when
  /// it names the declined/failed operation it reverses.
  static const List<String> creditAction = [
    'استرداد', 'استرجاع', 'مسترد', 'مستردة', 'رد مبلغ', 'إعادة مبلغ',
    'اعادة مبلغ', 'عكس عملية', 'عكس العملية', 'عكس قيد',
    'refund', 'refunded', 'reversal', 'reversed', 'credited',
  ];

  /// True when [rawText] reports a transaction that did not complete.
  static bool isNotCompleted(String rawText) {
    final text = Normalizer.normalize(rawText)
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
    return _declined.hasMatch(text) && !_creditAction.hasMatch(text);
  }

  static final RegExp _declined = _tokenPattern(declined);
  static final RegExp _creditAction = _tokenPattern(creditAction);

  /// Whole-token match. An Arabic cue may carry one attached clitic prefix
  /// (و ف ب ل ال وال بال فال لل) but never sits inside a longer word; a Latin
  /// cue is bounded by non-letters.
  static RegExp _tokenPattern(List<String> cues) {
    const arabicLetter = r'ء-ي';
    final alternation = cues.map(RegExp.escape).join('|');
    return RegExp(
      '(?<![a-z$arabicLetter])(?:وال|بال|فال|لل|ال|و|ف|ب|ل)?'
      '(?:$alternation)'
      '(?![a-z$arabicLetter])',
    );
  }
}
