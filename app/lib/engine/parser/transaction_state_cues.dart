import 'normalizer.dart';

/// DATA-01 — a bank message reporting a transaction that did NOT complete
/// (declined / failed / rejected / cancelled / voided / expired / insufficient
/// funds / limit).
///
/// Such a message moved no money and must never become a confirmed payment,
/// transfer or credit. The rule:
///
/// 1. A cue counts only as a whole token (Arabic: one و/ف/ب/ال clitic, never
///    the purpose prefix ل: `لرفض`, `لاسترداد` are instructions).
/// 2. A cue is not a status when it is part of a name — right after a merchant
///    introducer (`at`, `from`, `to`, `لدى`, `من`, `عند`, `في`, `إلى`; not
///    "due to"), optionally followed by one [merchantNameWords] word ("at The
///    Failed Co", `لدى شركة مرفوض`) — when it qualifies a plural generic noun
///    ("Declined transactions incur no fee", `العمليات المرفوضة`), or when its
///    sentence is a question ("Unauthorized transaction? Call us").
/// 3. A cue preceded in its clause (sentence, or after a comma or colon) by a
///    hypothetical, future or instructional marker ("will be", "if", "call
///    us", `سيتم`, `للاعتراض`) is not a status. A credit word was not done when
///    it is preceded by a negation (`not`, `لم`), directly followed by a
///    declined cue, a marker or a negation ("Refund failed", "Refund will be
///    processed"), or followed later in its sentence by a declined status
///    ("Refund of SAR 99 failed") — unless that cue only describes a
///    transaction noun ("Refund for failed transaction", `العملية المرفوضة`).
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
    'فشل استرداد', 'فشل الاسترداد', 'لم يتم خصم', 'لم يتم الخصم', 'لم تنفذ',
    'تم الإلغاء', 'غير مصرح', 'انتهت صلاحية العملية',
    // English
    'declined', 'rejected', 'unsuccessful', 'not successful', 'failed',
    'denied', 'not approved', 'cancelled', 'canceled',
    'was not completed', 'could not be completed', 'not processed',
    'could not be processed',
    'insufficient funds', 'insufficient balance',
    'limit exceeded', 'exceeded limit', 'exceeds limit', 'exceeds the limit',
    'exceeded the limit', 'exceeds your limit', 'exceeded your limit',
    'exceeds your credit limit', 'exceeded your credit limit',
    'void', 'voided', 'not authorised', 'not authorized', 'unauthorised',
    'unauthorized', 'unable to process', 'unable to complete',
    'transaction error', 'timed out', 'expired', 'not completed',
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
    'at', 'from', 'لدى', 'من', 'عند', 'في', 'to', 'إلى',
  ];

  /// One of these may sit between the introducer and the cue ("at The Failed
  /// Co", `لدى شركة مرفوض`).
  static const List<String> merchantNameWords = [
    'the', 'شركة', 'مؤسسة', 'متجر', 'مطعم', 'محل',
  ];

  /// Earlier in the same clause, these make a cue hypothetical, future or
  /// an instruction ("can be rejected by calling us", `للاعتراض على …`).
  static const List<String> hypotheticalMarkers = [
    'will be', 'can be', 'may be', 'might be', 'would be', 'could be',
    'should be', 'if', 'unless', 'report',
    'سيتم', 'سوف', 'قد يتم', 'يمكن أن', 'يمكنك', 'إذا', 'لو', 'في حال',
    'اعتراض', 'إبلاغ',
    'call us', 'contact us', 'اتصل بنا', 'تواصل معنا',
  ];

  /// Earlier in the same clause, these make a credit word not done.
  static const List<String> negationMarkers = ['not', 'لم', 'لا', 'لن'];

  /// A declined cue next to one of these (English: right after it; Arabic:
  /// right before it) describes a transaction ("failed transaction",
  /// `العملية المرفوضة`) rather than stating that a refund failed.
  static const List<String> transactionNouns = [
    'transaction', 'purchase', 'payment', 'txn', 'transfer', 'operation',
    'عملية', 'العملية', 'معاملة', 'المعاملة', 'حوالة', 'الحوالة',
  ];

  /// Plural generic nouns: a cue next to one of these is advice about
  /// transactions in general, never the status of this one.
  static const List<String> genericNouns = [
    'transactions', 'purchases', 'payments', 'transfers', 'operations',
    'attempts', 'عمليات', 'العمليات', 'معاملات', 'المعاملات',
  ];

  /// True when [rawText] reports a transaction that did not complete.
  static bool isNotCompleted(String rawText) {
    final text = foldForCues(rawText);
    int? creditAt;
    var undone = false;
    for (final m in _creditAction.allMatches(text)) {
      final why = _notStatus(text, m);
      if (why == _Skip.name) continue;
      if (why == _Skip.hypothetical ||
          _negation.hasMatch(_clause(text, m.start)) ||
          _undoneNext.hasMatch(text.substring(m.end)) ||
          _failsLater(text, m)) {
        undone = true;
        continue;
      }
      creditAt = m.start;
      break;
    }
    int? declinedAt;
    for (final m in _declined.allMatches(text)) {
      if (_notStatus(text, m) == null) {
        declinedAt = m.start;
        break;
      }
    }
    if (declinedAt != null) return creditAt == null || declinedAt < creditAt;
    return creditAt == null && undone && _declined.hasMatch(text);
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

  /// Why the cue match [m] does not state this message's status, or null when
  /// it does.
  static _Skip? _notStatus(String text, Match m) {
    final sentence = text.substring(_lastBoundary(text, m.start, _boundary),
        m.start);
    if (_afterIntroducer.hasMatch(sentence) ||
        _genericNext.hasMatch(text.substring(m.end)) ||
        _genericBefore.hasMatch(sentence) ||
        _sentenceEnd(text, m.end).question) {
      return _Skip.name;
    }
    return _hypothetical.hasMatch(_clause(text, m.start))
        ? _Skip.hypothetical
        : null;
  }

  /// A declined status later in [credit]'s sentence that does not merely
  /// describe a transaction noun ("Refund of SAR 99 failed").
  static bool _failsLater(String text, Match credit) {
    final end = _sentenceEnd(text, credit.end).at;
    for (final d in _declined.allMatches(text, credit.end)) {
      if (d.start >= end) break;
      if (_notStatus(text, d) == null &&
          !_nounNext.hasMatch(text.substring(d.end)) &&
          !_nounBefore.hasMatch(text.substring(0, d.start))) {
        return true;
      }
    }
    return false;
  }

  static String _clause(String text, int end) =>
      text.substring(_lastBoundary(text, end, _clauseBoundary), end);

  /// A sentence ends at a line break, `! ? ؟ ; ؛`, or a period not followed
  /// by a digit (so `250.00` is not a boundary). A clause also ends at a
  /// comma or colon that is not between digits.
  static int _lastBoundary(String text, int end, RegExp boundary) {
    var start = 0;
    for (final b in boundary.allMatches(text.substring(0, end))) {
      start = b.end;
    }
    return start;
  }

  static ({int at, bool question}) _sentenceEnd(String text, int from) {
    final b = _boundary.firstMatch(text.substring(from));
    if (b == null) return (at: text.length, question: false);
    return (at: from + b.start, question: b[0] == '?' || b[0] == '؟');
  }

  static final RegExp _boundary = RegExp(r'[\n!?؟;؛]|\.(?![0-9])');
  static final RegExp _clauseBoundary = RegExp(r'[\n!?؟;؛]|[.,،:](?![0-9])');
  static final RegExp _declined = _tokenPattern(declined, lam: false);
  static final RegExp _creditAction = _tokenPattern(creditAction, lam: false);
  static final RegExp _hypothetical =
      _tokenPattern(hypotheticalMarkers, lam: true);
  static final RegExp _negation = _tokenPattern(negationMarkers, lam: false);
  static final RegExp _afterIntroducer = RegExp(
      '(?<![a-z$_arabicLetter])(?<!due )(?<!owing )'
      '(?:${_alternation(merchantIntroducers)})'
      r'[\s:]*'
      '(?:(?:${_alternation(merchantNameWords)}) )?\$');
  // "Refund failed", "refund was declined", "refund will be processed",
  // `الاسترداد مرفوض`.
  static final RegExp _undoneNext = RegExp(
      r'^ (?:was |has been |is |been |تم )?(?:'
      '${_alternation([...declined, ...hypotheticalMarkers, ...negationMarkers])}'
      ')(?![a-z$_arabicLetter])');
  // A noun right after an English cue / right before an Arabic cue.
  static final RegExp _genericNext = _nounAfter(genericNouns);
  static final RegExp _genericBefore = _nounPreceding(genericNouns);
  static final RegExp _nounNext =
      _nounAfter([...transactionNouns, ...genericNouns]);
  static final RegExp _nounBefore =
      _nounPreceding([...transactionNouns, ...genericNouns]);

  static bool _isLatin(String w) => RegExp('[a-z]').hasMatch(w);
  static RegExp _nounAfter(List<String> nouns) => RegExp(
      '^ (?:${_alternation(nouns.where(_isLatin).toList())})'
      '(?![a-z$_arabicLetter])');
  static RegExp _nounPreceding(List<String> nouns) => RegExp(
      '(?<![a-z$_arabicLetter])(?:و|ف|ب)?'
      '(?:${_alternation(nouns.where((w) => !_isLatin(w)).toList())}) \$');

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

/// Why a cue match is not this message's status: part of a name, a generic
/// advice or a question ([name]); or hypothetical / instructional.
enum _Skip { name, hypothetical }
