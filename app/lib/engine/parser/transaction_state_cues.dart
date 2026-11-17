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
///    introducer (`at`, `from`, `to`, `via`, `merchant:`, `لدى`, `من`, `عند`,
///    `في`, `إلى`; not "due to"), optionally followed by one
///    [merchantNameWords] word ("at The Failed Co", `لدى شركة مرفوض`), but not
///    a feminine Arabic cue after an Arabic name word (`من متجر مرفوضة` agrees
///    with the operation, `شركة مرفوضة` cannot be told apart: a status) — when
///    it qualifies a plural generic noun ("Declined transactions incur no
///    fee", `العمليات المرفوضة`), or when the question mark ends its own
///    clause ("Unauthorized transaction? Call us"; not "…declined, need
///    help?"). A declined cue right after a negation ("not declined", `لم
///    يتم رفض`) is not a status.
/// 3. A cue preceded in its clause (sentence, or after a comma, a colon or a
///    spaced dash: "Transaction Report - …") by a hypothetical, future or
///    instructional marker ("will be", "if", "call us", `سيتم`, `للاعتراض`)
///    is not a status — except a declined cue whose clause has only
///    [futureMarkers] and names an amount ("Payment of SAR 100 will be
///    declined due to insufficient funds"). A credit word was not done when
///    it is preceded by a negation (`not`, `لم`), directly followed by a
///    declined cue, a marker or a negation ("Refund failed", "Refund will be
///    processed"), or followed later in its sentence by a declined status
///    ("Refund of SAR 99 failed") — unless that cue only describes a
///    transaction noun ("Refund for failed transaction", `العملية المرفوضة`).
/// 4. Not completed = a declined status exists, wherever a done credit sits:
///    "…declined. Amount credited back", and also "Refund for failed
///    transaction" — a refund of a declined original returns money that was
///    never recorded, so it is ambiguous (review, no total change).
///    A credit that is only promised or negated, in a message that names a
///    declined operation anywhere ("Refund will be processed for failed
///    transaction"), is not completed either: no money has moved yet.
/// 5. A plural generic noun followed by a colon or a count is a status
///    header, not advice ("Declined transactions: 1. Purchase of …",
///    `العمليات المرفوضة: ١`).
/// 6. A reversed purchase ("Purchase of SAR 100 at X reversed", `تم عكس عملية
///    الشراء`) in a message with no declined cue is ambiguous: the original
///    purchase may or may not have been recorded. It goes to review (counted
///    here as not completed) and changes no total. A reversal or refund that
///    names no purchase ("Reversal of SAR 100 credited to your account",
///    `تم استرجاع مبلغ 100 ريال`) stays a credit. "POS reversal", "Transaction
///    reversed" and `تم خصم … وتم استرجاعه` name a debit too.
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
    // Not (yet) completed: failed transfer / cash / bill payment, pending,
    // held, blocked (V1-RES3).
    'لم ينجح', 'لم يتم تحويل', 'تعذر تحويل', 'تعذر صرف', 'لم يتم صرف',
    'تعذر السحب', 'تعذر سداد', 'لم يتم سداد', 'لم يتم السداد', 'معلقة', 'معلق',
    'قيد المعالجة', 'قيد الانتظار', 'تم حجز', 'مبلغ محجوز', 'تم إيقاف',
    'موقوفة', 'سيتم تنفيذ',
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
    'pending', 'on hold', 'hold of', 'authorization hold', 'hold released',
    'pre-authorization', 'pre-authorisation', 'preauthorization',
    'preauthorisation', 'pre-auth', 'blocked', 'stopped',
    'could not be dispensed', 'not dispensed', 'could not be sent',
    'could not be paid', 'will be processed',
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
    'at', 'from', 'لدى', 'من', 'عند', 'في', 'to', 'إلى', 'merchant', 'via',
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

  /// The future-only [hypotheticalMarkers]: a declined cue after one of these
  /// in a clause that names an amount is this transaction's own status
  /// ("Payment of SAR 100 will be declined"), not advice.
  static const List<String> futureMarkers = ['will be', 'سيتم', 'سوف'];

  /// Earlier in the same clause, these make a credit word not done.
  static const List<String> negationMarkers = ['not', 'لم', 'لا', 'لن'];

  /// A declined cue next to one of these (English: right after it; Arabic:
  /// right before it) describes a transaction ("failed transaction",
  /// `العملية المرفوضة`) rather than stating that a refund failed.
  static const List<String> transactionNouns = [
    'transaction', 'purchase', 'payment', 'txn', 'transfer', 'operation',
    'عملية', 'العملية', 'معاملة', 'المعاملة', 'حوالة', 'الحوالة',
  ];

  /// Plural generic nouns (and "use", as in "For unauthorized use call …"):
  /// a cue next to one of these is advice about transactions in general,
  /// never the status of this one — unless it is a status header (rule 5).
  static const List<String> genericNouns = [
    'transactions', 'purchases', 'payments', 'transfers', 'operations',
    'attempts', 'use', 'عمليات', 'العمليات', 'معاملات', 'المعاملات',
  ];

  /// Rule 6: a reversal word in a message naming a [purchaseNouns] word.
  static const List<String> reversalWords = [
    'reversal', 'reversed', 'عكس', 'معكوس', 'معكوسة',
    'تم استرجاعه', 'تم استرجاعها', 'تم استرداده', 'تم استردادها',
  ];

  /// The debit operations a reversal word can apply to (rule 6).
  static const List<String> purchaseNouns = [
    'purchase', 'payment', 'شراء', 'pos', 'خصم', 'transaction', 'txn',
  ];

  /// True when [rawText] reports a transaction that did not complete.
  static bool isNotCompleted(String rawText) {
    final text = foldForCues(rawText);
    int? creditAt;
    var undone = false;
    for (final m in _creditAction.allMatches(text)) {
      final done = _creditDone(text, m);
      if (done == null) continue;
      if (!done) {
        undone = true;
        continue;
      }
      creditAt = m.start;
      break;
    }
    if (_declined.allMatches(text).any((m) => _isDeclinedStatus(text, m))) {
      return true;
    }
    if (!_declined.hasMatch(text) &&
        _purchase.hasMatch(text) &&
        _reversal.allMatches(text).any((m) => _creditDone(text, m) == true)) {
      return true;
    }
    return creditAt == null && undone && _declined.hasMatch(text);
  }

  /// Whether the declined cue [m] states this message's status (rules 2, 3).
  static bool _isDeclinedStatus(String text, Match m) {
    final sentence =
        text.substring(_lastBoundary(text, m.start, _boundary), m.start);
    if (_negatedBefore.hasMatch(sentence)) return false;
    final why = _notStatus(text, m);
    if (why == null) return true;
    if (why == _Skip.name) return false;
    final clause = _clause(text, m.start);
    return _future.hasMatch(clause) &&
        !_notFuture.hasMatch(clause) &&
        RegExp('[0-9]').hasMatch(clause);
  }

  /// Whether the credit word [m] reports money returned: null when it is not
  /// a status at all, false when it is promised, negated or failed.
  static bool? _creditDone(String text, Match m) {
    final why = _notStatus(text, m);
    if (why == _Skip.name) return null;
    return !(why == _Skip.hypothetical ||
        _negation.hasMatch(_clause(text, m.start)) ||
        _undoneNext.hasMatch(text.substring(m.end)) ||
        _failsLater(text, m));
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
    final after = text.substring(m.end);
    final genericAfter = _genericNext.firstMatch(after);
    final generic = genericAfter != null
        ? !_header.hasMatch(after.substring(genericAfter.end))
        : _genericBefore.hasMatch(sentence) && !_header.hasMatch(after);
    final named = _afterIntroducer.firstMatch(sentence);
    final nameWord = named?.group(1);
    // A feminine Arabic cue after a name word agrees with the operation
    // (`عملية شراء … من متجر مرفوضة`) or cannot be told apart: a status.
    final feminineAfterName = nameWord != null &&
        !_isLatin(nameWord) &&
        text.substring(m.start, m.end).endsWith('ه');
    final end = _sentenceEnd(text, m.end);
    final ownQuestion = end.question &&
        !_clauseBoundary.hasMatch(text.substring(m.end, end.at));
    if ((named != null && !feminineAfterName) || generic || ownQuestion) {
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
      if (_isDeclinedStatus(text, d) &&
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
  static final RegExp _clauseBoundary =
      RegExp(r'[\n!?؟;؛]|[.,،:](?![0-9])| [-–—](?= )');
  static final RegExp _declined = _tokenPattern(declined, lam: false);
  static final RegExp _creditAction = _tokenPattern(creditAction, lam: false);
  static final RegExp _reversal = _tokenPattern(reversalWords, lam: false);
  static final RegExp _purchase = _tokenPattern(purchaseNouns, lam: false);
  // Right after a generic noun phrase: a colon or a count (rule 5).
  static final RegExp _header = RegExp(r'^ ?(?::|\(?[0-9٠-٩])');
  static final RegExp _hypothetical =
      _tokenPattern(hypotheticalMarkers, lam: true);
  static final RegExp _negation = _tokenPattern(negationMarkers, lam: false);
  static final RegExp _future = _tokenPattern(futureMarkers, lam: true);
  static final RegExp _notFuture = _tokenPattern(
      hypotheticalMarkers.where((c) => !futureMarkers.contains(c)).toList(),
      lam: true);
  // "not declined", "has not been rejected", `لم يتم رفض`.
  static final RegExp _negatedBefore = RegExp(
      '(?<![a-z$_arabicLetter])(?:${_alternation(negationMarkers)})'
      r'(?: يتم| تتم| been)? \(?$');
  static final RegExp _afterIntroducer = RegExp(
      '(?<![a-z$_arabicLetter])(?<!due )(?<!owing )'
      '(?:${_alternation(merchantIntroducers)})'
      r'[\s:]*'
      '(?:(${_alternation(merchantNameWords)}) )?\$');
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
