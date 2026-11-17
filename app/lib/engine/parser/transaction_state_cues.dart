import 'normalizer.dart';

/// DATA-01 — a bank message reporting a transaction that did NOT complete
/// (declined / failed / rejected / cancelled / insufficient funds / limit).
///
/// Such a message moved no money and must never become a confirmed payment,
/// transfer or credit. The rule, in four lines:
///
/// 1. A cue counts only as a whole token (Arabic: one و/ف/ب/ال clitic, never
///    the purpose prefix ل: `لرفض`, `لاسترداد` are instructions).
/// 2. A cue right after a merchant introducer (`at`, `from`, `لدى`, `من`,
///    `عند`, `في`) is part of a name ("at Failed Ventures"), not a status.
/// 3. A cue preceded in its own sentence by a hypothetical, future or
///    instructional marker ("will be", "if", "report", `سيتم`, `للاعتراض`) is
///    not a status. A credit word preceded by a negation (`not`, `لم`), or
///    directly followed by a declined cue, a marker or a negation ("Refund
///    failed", "Refund will be processed"), was not done.
/// 4. Not completed = a declined status exists and no done credit comes
///    BEFORE it. "Refund for failed transaction" stays a credit; "…declined.
///    Amount credited back" and "…declined. It will be refunded" do not.
///    A credit that is only promised or negated, in a message that names a
///    declined operation anywhere ("Refund will be processed for failed
///    transaction"), is not completed either: no money has moved yet.
///
/// Matching folds tashkeel, tatweel, hamza forms, ة/ه and ى/ي on both sides.
/// Mirrored by `supabase/functions/process-ios-sms/parse.ts`; the lists below
/// must equal the ones in its `parser_rules.json` (drift test:
/// `test/engine/parser/transaction_state_cues_drift_test.dart`).
class TransactionStateCues {
  const TransactionStateCues._();

  static const List<String> declined = [
    // Arabic
    'مرفوضة', 'مرفوض', 'تم رفض', 'رفضت', 'تم الرفض', 'رفض عملية', 'رفض العملية',
    'فشلت', 'فاشلة', 'فشل العملية', 'فشل عملية', 'فشل الدفع', 'فشل السحب',
    'غير ناجحة', 'غير ناجح', 'لم تنجح', 'لم تتم بنجاح',
    'لم تتم العملية', 'العملية لم تتم', 'لم تكتمل',
    'غير مقبولة', 'غير مقبول', 'ملغاة', 'ملغية',
    'تم إلغاء العملية', 'تم إلغاء عملية',
    'لم يتم تنفيذ العملية', 'لم يتم تنفيذ عملية', 'تعذر إتمام', 'تعذر تنفيذ',
    'رصيد غير كاف', 'رصيد غير كافي', 'رصيدك غير كاف', 'رصيدك غير كافي',
    'الرصيد غير كاف', 'الرصيد غير كافي', 'عدم كفاية الرصيد',
    'لعدم كفاية الرصيد',
    'تجاوز الحد', 'تجاوزت الحد', 'تجاوز حد', 'تخطي الحد',
    // English
    'declined', 'rejected', 'unsuccessful', 'not successful', 'failed',
    'denied', 'not approved', 'cancelled', 'canceled',
    'was not completed', 'could not be completed', 'not processed',
    'could not be processed',
    'insufficient funds', 'insufficient balance',
    'limit exceeded', 'exceeded limit', 'exceeds limit', 'exceeds the limit',
    'exceeded the limit', 'exceeds your limit', 'exceeded your limit',
    'exceeds your credit limit', 'exceeded your credit limit',
  ];

  /// The message's own action returns money (a refund/reversal of the
  /// declined operation it names).
  static const List<String> creditAction = [
    'استرداد', 'استرجاع', 'مسترد', 'مستردة', 'رد مبلغ', 'إعادة مبلغ',
    'عكس عملية', 'عكس العملية', 'عكس قيد',
    'refund', 'refunded', 'reversal', 'reversed', 'credited',
  ];

  /// The word right before a cue that makes the cue part of a merchant name.
  static const List<String> merchantIntroducers = [
    'at', 'from', 'لدى', 'من', 'عند', 'في',
  ];

  /// Earlier in the same sentence, these make a cue hypothetical, future or
  /// an instruction ("can be rejected by calling us", `للاعتراض على …`).
  static const List<String> hypotheticalMarkers = [
    'will be', 'can be', 'may be', 'might be', 'would be', 'could be',
    'should be', 'if', 'unless', 'report',
    'سيتم', 'سوف', 'قد يتم', 'يمكن أن', 'يمكنك', 'إذا', 'لو', 'في حال',
    'اعتراض', 'إبلاغ',
  ];

  /// Earlier in the same sentence, these make a credit word not done.
  static const List<String> negationMarkers = ['not', 'لم', 'لا', 'لن'];

  /// True when [rawText] reports a transaction that did not complete.
  static bool isNotCompleted(String rawText) {
    final text = foldForCues(rawText);
    final credit = _firstStatus(_creditAction, text, negatable: true);
    final declinedAt = _firstStatus(_declined, text, negatable: false).at;
    if (declinedAt != null) {
      return credit.at == null || declinedAt < credit.at!;
    }
    return credit.at == null && credit.undone && _declined.hasMatch(text);
  }

  /// The cue-matching form: [Normalizer.normalize] (tashkeel, tatweel,
  /// digits), lower case, single spaces (line breaks kept: they end a
  /// sentence) and folded Arabic letter variants.
  static String foldForCues(String input) => Normalizer.normalize(input)
      .toLowerCase()
      .replaceAll(RegExp(r'[^\S\n]+'), ' ')
      .replaceAll(RegExp('[أإآٱ]'), 'ا')
      .replaceAll('ؤ', 'و')
      .replaceAll('ئ', 'ي')
      .replaceAll('ى', 'ي')
      .replaceAll('ة', 'ه');

  /// Index of the first cue match that states this message's status, and
  /// whether a match was skipped as hypothetical, future or negated.
  static ({int? at, bool undone}) _firstStatus(RegExp cues, String text,
      {required bool negatable}) {
    var undone = false;
    for (final m in cues.allMatches(text)) {
      final sentence = text.substring(_sentenceStart(text, m.start), m.start);
      if (_afterIntroducer.hasMatch(sentence)) continue;
      if (_hypothetical.hasMatch(sentence) ||
          (negatable &&
              (_negation.hasMatch(sentence) ||
                  _undoneNext.hasMatch(text.substring(m.end))))) {
        undone = true;
        continue;
      }
      return (at: m.start, undone: undone);
    }
    return (at: null, undone: undone);
  }

  /// A sentence ends at a line break, `! ? ؟ ; ؛`, or a period not followed
  /// by a digit (so `250.00` is not a boundary).
  static int _sentenceStart(String text, int end) {
    var start = 0;
    for (final b in _boundary.allMatches(text.substring(0, end))) {
      start = b.end;
    }
    return start;
  }

  static final RegExp _boundary = RegExp(r'[\n!?؟;؛]|\.(?![0-9])');
  static final RegExp _declined = _tokenPattern(declined, lam: false);
  static final RegExp _creditAction = _tokenPattern(creditAction, lam: false);
  static final RegExp _hypothetical =
      _tokenPattern(hypotheticalMarkers, lam: true);
  static final RegExp _negation = _tokenPattern(negationMarkers, lam: false);
  static final RegExp _afterIntroducer = RegExp(
      '(?<![a-z$_arabicLetter])(?:${_alternation(merchantIntroducers)})'
      r'[\s:]*$');
  // "Refund failed", "refund was declined", "refund will be processed",
  // `الاسترداد مرفوض`.
  static final RegExp _undoneNext = RegExp(
      r'^ (?:was |has been |is |been |تم )?(?:'
      '${_alternation([...declined, ...hypotheticalMarkers, ...negationMarkers])}'
      ')(?![a-z$_arabicLetter])');

  static const _arabicLetter = r'ء-ي';
  static String _alternation(List<String> cues) =>
      cues.map((c) => RegExp.escape(foldForCues(c))).join('|');

  /// Whole-token match. An Arabic cue may carry one attached clitic (و ف ب ال
  /// and their combinations; ل and لل only when [lam]) but never sits inside
  /// a longer word; a Latin cue is bounded by non-letters.
  static RegExp _tokenPattern(List<String> cues, {required bool lam}) {
    final clitics = lam ? 'وال|بال|فال|لل|ال|و|ف|ب|ل' : 'وال|بال|فال|ال|و|ف|ب';
    return RegExp(
      '(?<![a-z$_arabicLetter])(?:$clitics)?'
      '(?:${_alternation(cues)})'
      '(?![a-z$_arabicLetter])',
    );
  }
}
