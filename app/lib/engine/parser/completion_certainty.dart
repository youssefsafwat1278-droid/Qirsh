import 'message_meaning.dart';
import 'transaction_state_cues.dart';

/// Round 5 (owner decision): when the device's own reading may record a
/// message.
///
/// A message is recorded on its own reading only when it is **clearly
/// completed**: it has a completed-event form ([hasCompletedForm]) and no
/// doubt anywhere outside a security-advice clause ([doubtOf]: a negation, a
/// hedge, a modal or future, a pending or requested state, a question or a
/// call to act, a cancellation or failure, a late-payment warning, a
/// reference to an earlier operation). Every other money message is **uncertain**: the
/// model decides it when the user allowed AI (never for a transfer:
/// [isTransfer]), otherwise it is a visible review row. A model answer of
/// "completed" is never accepted for a text with a doubt: the text
/// contradicts it.
///
/// The patterns are families, not wordings: an unlisted wording that a
/// family does not catch, or a harmless word that it does, sends the message
/// to review (never to a wrong record) as long as the wording has no
/// completed-event form or carries any doubt word. Equal to
/// `completionCertainty` in `supabase/functions/process-ios-sms/parser_rules.json`
/// (drift test `completion_certainty_test.dart`).
class CompletionCertainty {
  const CompletionCertainty._();

  static const Map<String, String> doubtPatterns = {
    'negated':
        r"(?<![a-z])(?:not|never|no longer|yet to|still to|unable to|failed to|cannot|unpaid|unconfirmed|unsuccessful|unsettled|unapproved|unprocessed|uncleared|incomplete)(?![a-z])|[a-z]n't(?![a-z])|(?<![ء-ي])(?:و|ف)?(?:لم|لن)(?![ء-ي])|(?<![ء-ي])(?:ما|لا) (?:زال|زالت|يزال|تزال)(?![ء-ي])|(?<![ء-ي])(?:مازال|مازالت|لازال|لازالت)(?![ء-ي])|(?<![ء-ي])(?:غير|عدم) (?:ال)?(?:مكتمل|مكتمله|موكد|موكده|معتمد|معتمده|مدفوع|مدفوعه|ناجح|ناجحه|مسدد|مسدده|منفذ|منفذه|مقبول|مقبوله|اكتمال|اتمام|تنفيذ|قبول|نجاح|سداد|دفع|خصم|ايداع|تاكيد)(?![ء-ي])",
    'hedged':
        r"(?<![a-z])(?:may|might|could|must|should|would|will|shall|ought to|has to|have to|need to|needs to|going to|about to|to be|possibly|probably|perhaps|presumably|apparently|likely|unlikely|seems?|appears? to|expected|expect|expecting|supposed to|estimated|tentative[a-z]*|provisional[a-z]*|temporar[a-z]*|scheduled|schedule|upcoming|tomorrow|later|soon|next|within|until|till|deadline|due|expir[a-z]*|can be|cannot be|before [0-9]|on or before|in [0-9]+ (?:business )?(?:days?|hours?))(?![a-z])|[a-z]'ll(?![a-z])|(?<![ء-ي])(?:و|ف)?(?:سوف|سيتم|ستتم|سيكون|ستكون|سنقوم|سيقوم|ستقوم|سيخصم|سيضاف|ستضاف|سيودع|سينفذ|ستنفذ|سيصلك|ستصلك|ستحصل|سيحصل|ستستلم|ستتلقي|سيقيد|ستقيد|سيرد|سيعاد|ستعاد|سيحول|ستحول|ربما|يمكن|يجب|ينبغي|يحتمل|محتمل|المحتمل|متوقع|متوقعه|المتوقع|المتوقعه|يتوقع|يفترض|المفترض|مقرر|المقرر|مجدول|مجدوله|المجدول|المجدوله|القادم|القادمه|غدا|لاحقا|قريبا|موعد|مستحق|مستحقه|المستحق|المستحقه|يستحق|تستحق)(?![ء-ي])|(?<![ء-ي])(?<!من )خلال(?![ء-ي])|(?<![ء-ي])قد (?:يكون|تكون|يتم|تتم)(?![ء-ي])",
    'pending':
        r"(?<![a-z])(?:pending|await[a-z]*|waiting|waits|wait for|on hold|held|hold|in progress|under process[a-z]*|under review|under verification|under investigation|under collection|under clearing|being processed|being reviewed|being verified|processing|outstanding|requires?|required|request[a-z]*|needs? your|subject to|upon|pre-?auth[a-z]*|reserved|blocked|initiated|queued|submitted|remind[a-z]*)(?![a-z])|(?<![ء-ي])(?:و|ف|ب|ال)?(?:معلق|معلقه|تعليق|انتظار|ينتظر|تنتظر|لحين|حين|حتي|ريثما|بحاجه|يتطلب|تتطلب|يحتاج|تحتاج|طلب|طلبك|طلبكم|مطلوب|مطلوبه|تذكير|نذكركم|نذكرك)(?![ء-ي])|(?<![ء-ي])(?<!حساب )(?<!حسابك )(?:و|ف)?(?:جاري|جار)(?![ء-ي])|(?<![ء-ي])قيد (?:ال)?(?:انتظار|معالجه|تحصيل|تنفيذ|مراجعه|موافقه|تحقق|دراسه|اجراء)(?![ء-ي])",
    'question':
        r"[^.!?؟\n]*(?:[0-9٠-٩]|paid|pay|charg|debit|credit|transfer|purchase|refund|approv|confirm|authori|سداد|دفع|خصم|تحويل|شراء|استرداد|تاكيد|موافقه|تم)[^.!?؟\n]*[?؟]|(?<![a-z])(?:reply|respond|press|tap|click) (?:with|y|yes|n|no|here|on|to|the|link|[0-9])(?![a-z])|(?<![a-z])(?:to|please) (?:confirm|approve|authori[sz]e|verify|accept)(?![a-z])|(?<![ء-ي])(?:و|ف|ل)?(?:ارسل|اضغط|للتاكيد|للموافقه|لتاكيد|للقبول|لقبول)(?![ء-ي])",
    'cancelled':
        r"(?<![a-z])(?:cancel[a-z]*|revers[a-z]*|declin[a-z]*|reject[a-z]*|fail[a-z]*|unsuccessful|suspend[a-z]*|attempt[a-z]*|void[a-z]*|refus[a-z]*|denied|insufficient|invalid|error|stopped|bounced|chargeback|disput[a-z]*|recall[a-z]*|undone)(?![a-z])|(?<![ء-ي])(?:و|ف|ب|ال|وال|بال)?(?:الغاء|ملغي|ملغيه|ملغاه|الغيت|الغي|عكس|معكوس|معكوسه|مرفوض|مرفوضه|رفض|رفضت|فشل|فشلت|تعذر|تعذرت|يتعذر|محاوله|ايقاف|موقوف|موقوفه|اعتراض)(?![ء-ي])",
    'late':
        r"(?<![a-z])(?:late|overdue|penalt[a-z]*|missed|delinquen[a-z]*|arrears)(?![a-z])|(?<![ء-ي])(?:ال)?(?:متاخر|متاخره|تاخير|تاخر|غرامه|غرامات)(?![ء-ي])",
    'reference':
        r"(?<![a-z])(?:previous|prior|earlier|last) (?:purchase|transaction|payment|salary|deposit|withdrawal|operation)s?(?![a-z])|(?<![ء-ي])(?:اخر|اخري) (?:عمليه|عمليات|حركه)(?![ء-ي])|(?<![ء-ي])(?:العمليه|الحركه) السابقه(?![ء-ي])",
  };

  static const String adviceClause =
      r"(?<![a-z])(?:if (?:you|this|it)(?: transaction)? (?:did not|didn't|do not|don't|was not|wasn't|is not|isn't|were not|have not|haven't|are not|aren't)|if not (?:you|done|made|authori[sz]ed)|not you|not by you|not done by you|not made by you|(?:do not|don't|never) (?:share|disclose|give)|in case (?:you|this)|failure to report)(?![a-z])|(?<![ء-ي])(?:اذا|ان|في حال|لو) (?:لم|كنت لم|عدم)(?![ء-ي])|(?<![ء-ي])(?:لم تقم|ليست انت|لست انت|لا تشارك|لا تشاركوا|لا تفصح|عدم مشاركه|عدم الافصاح)(?![ء-ي])";

  static const List<String> completedFormWords = [
    'used',
    'incoming',
    'outgoing',
    'inward',
    'outward',
    'خصم',
    'ايداع',
    'سداد',
    'استلام',
    'وارده',
    'صادره',
    'refund',
    'payment',
    'استرداد',
    'استرجاع',
    'مرتجع',
    'دفع',
    // Round 5 (coordinator item 4): bank formats evidenced by the golden
    // real-world fixtures (bank_sms_golden_fixtures.dart) — STC Bank «عملية
    // انترنت» and «إضافة أموال», Bank Aljazira «الشراء عبر الإنترنت», Dubai
    // Bank «تأكيد السداد», ADIB "Trx. of". No other leads.
    'عمليه انترنت',
    'اضافه اموال',
    'الشراء عبر الانترنت',
    'تاكيد السداد',
    'trx. of',
  ];

  static const String transferPattern =
      r"(?<![a-z])(?:transfer[a-z]*|remittance|ipn|instapay|wire|sent to|received from|credited by|debited by)(?![a-z])|(?<![ء-ي])(?:و|ف|ب|ل|ال|وال|بال)?(?:تحويل|تحويلات|حواله|حوالات|حولت|محول|محوله|انستاباي)(?![ء-ي])|(?<![a-z])you (?:have )?(?:got|received) (?:[a-z]{3} ?)?[0-9][0-9.,]*(?: ?[a-z]{3})? from (?!(?:your|the|a|an) |account|card|[^\n.,]*?(?<![a-z])(?:corp|corporation|company|co|ltd|limited|llc|inc|est|trading|group|bank|holding|ministry|university|school|hospital|clinic|payroll|salary|store|mart|shop|market)(?![a-z]))(?:[a-z]|\[name\])|(?<![a-z])topped up (?:with )?(?:[a-z]{3} ?)?[0-9][0-9.,]*(?: ?[a-z]{3})? by (?!(?:your|the|a|an) |account|card|[^\n.,]*?(?<![a-z])(?:corp|corporation|company|co|ltd|limited|llc|inc|est|trading|group|bank|holding|ministry|university|school|hospital|clinic|payroll|salary|store|mart|shop|market)(?![a-z]))(?:[a-z]|\[name\])|(?:(?<![a-z])(?:(?!(?:your|the|we|you|has|have|corp|corporation|company|co|ltd|limited|llc|inc|est|trading|group|bank|holding|ministry|university|school|hospital|clinic|payroll|salary|store|mart|shop|market)(?![a-z]))[a-z]+ ){1,3}|\[name\] )sent you (?:[a-z]{3} ?)?[0-9]|(?:لحسابك|وصلك|استلمت)(?:[^\n.]|\.(?=[0-9]))*? من (?!حساب|بطاق|[^\n.,،]*?(?<![ء-ي])(?:ال)?(?:شركه|مؤسسه|مجموعه|بنك|مصرف|متجر|مطعم|محل|وزاره|هيئه|جامعه|مدرسه|مستشفي|عياده|راتب)(?![ء-ي]))(?:[ء-ي]|\[(?:name|redacted)\])";

  /// Review Y (N-M1): the direction the wording states when no money word
  /// names one ("topped up with", «قيد … لحسابك», "recharge … via card").
  /// Only the local direction a model answer must agree with
  /// ([DirectionSignal.localOf]) reads it. Server twin: `statedDirection` in
  /// process-ios-sms/completion_certainty.ts.
  static const String statedCreditPattern =
      r"(?<![a-z])(?:added to your (?:account|wallet)|topped up with|(?:has been|was|been) topped up|you got (?:[a-z]{3} ?)?[0-9]|sent you (?:[a-z]{3} ?)?[0-9]|posted to (?:your )?account[^\n.]*? from )|(?<![ء-ي])(?:تم )?(?:قيد|اضيف|اضيفت)(?![ء-ي])(?:[^\n.]|\.(?=[0-9]))*?لحسابك";
  static const String statedDebitPattern =
      r"(?<![a-z])recharge[a-z]*(?![a-z])[^\n]*?(?<![a-z])(?:via|using|with|by) (?:your )?card";

  /// Narrow check Z (N-M1b): an installment, fee or charge noun. With a
  /// stated credit wording it is a conflicting cue
  /// ([ParserEngine.conflictingCues]): "added to" what is owed.
  static const String statedCreditDebtPattern =
      r"(?<![a-z])(?:installments?|instalments?|fees?|charges?|interest charged)(?![a-z])|(?<![ء-ي])(?:ال)?(?:قسط|اقساط)(?![ء-ي])";

  /// Gemini-first phase 1: a transfer's own flow ("sent", "to <someone>",
  /// «إلى …» / "received", "from <someone>", «واردة», «من …»), not the
  /// user's own account or card. Server twin: `transferFlowDirection` in
  /// process-ios-sms/completion_certainty.ts.
  static const String transferCreditPattern =
      r"(?<![a-z])(?:received|incoming|transfer(?:red)? in|sent (?:to )?you)(?![a-z])|(?<![a-z])from (?!your?(?![a-z])|(?:the )?(?:account|card|acct)(?![a-z])|[0-9]|\*+ ?[0-9]|\[(?:account|card)\])\S|(?<![ء-ي])(?:وارده?|استلام|استلمت)(?![ء-ي])|(?<![ء-ي])من(?: ?: ?| )(?!حساب|بطاق|خلال|رصيد|قبل|[0-9٠-٩]|\*+ ?[0-9]|\[(?:account|card)\])\S";
  static const String transferDebitPattern =
      r"(?<![a-z])(?:sent(?! (?:to )?you(?![a-z]))|outgoing|transfer(?:red)? out)(?![a-z])|(?<![a-z])to (?!your?(?![a-z])|(?:the )?(?:account|card|acct)(?![a-z])|\*+ ?[0-9]|\[(?:account|card)\])\S|(?<![ء-ي])(?:صادره?|ارسلت)(?![ء-ي])|(?<![ء-ي])(?:الي|لصالح)(?: ?: ?| )(?!حساب|بطاق|\[(?:account|card)\])\S";

  static final Map<String, RegExp> _doubt = {
    for (final e in doubtPatterns.entries) e.key: RegExp(e.value),
  };
  static final RegExp _advice = RegExp(adviceClause);
  static final RegExp _transfer = RegExp(transferPattern);
  static final RegExp _statedCredit = RegExp(statedCreditPattern);
  static final RegExp _statedDebit = RegExp(statedDebitPattern);
  static final RegExp _statedCreditDebt = RegExp(statedCreditDebtPattern);
  static final RegExp _transferCredit = RegExp(transferCreditPattern);
  static final RegExp _transferDebit = RegExp(transferDebitPattern);
  static final RegExp _clauseEnd = RegExp(r'[\n!?؟;؛]|[.,،](?![0-9])| [-–—] ');
  static final RegExp _formWord = RegExp('(?<![a-zء-ي])(?:و|ف)?(?:${[
    ...MessageMeaning.doneVerbs,
    ...MessageMeaning.movementLeads,
    ...completedFormWords,
  ].map((w) => RegExp.escape(TransactionStateCues.foldForCues(w))).join('|')})(?![a-zء-ي])');

  /// [text] folded ([TransactionStateCues.foldForCues]), with every
  /// security-advice clause (and its end mark) replaced by a line break.
  static String readable(String text) {
    final t = TransactionStateCues.foldForCues(text).replaceAll('’', "'");
    final out = StringBuffer();
    var start = 0;
    for (final m in _clauseEnd.allMatches(t)) {
      final clause = t.substring(start, m.end);
      out.write(_advice.hasMatch(clause) ? '\n' : clause);
      start = m.end;
    }
    final rest = t.substring(start);
    out.write(_advice.hasMatch(rest) ? '\n' : rest);
    return out.toString();
  }

  /// The first doubt family found in [text] outside security advice, or null
  /// when there is none.
  static String? doubtOf(String text) {
    final t = readable(text);
    for (final e in _doubt.entries) {
      if (e.value.hasMatch(t)) return e.key;
    }
    return null;
  }

  /// The text states a completed event: a done verb, a movement lead or a
  /// completed-transfer form (or the caller found a clause flow).
  static bool hasCompletedForm(String text) =>
      _formWord.hasMatch(readable(text));

  /// A transfer to or from a person or between accounts.
  static bool isTransfer(String text) =>
      _transfer.hasMatch(TransactionStateCues.foldForCues(text));

  /// Review Y (N-M1): the direction [statedCreditPattern] /
  /// [statedDebitPattern] read in [text], or null.
  static bool? statedCredit(String text) {
    final t = TransactionStateCues.foldForCues(text);
    final credit = _statedCredit.hasMatch(t), debit = _statedDebit.hasMatch(t);
    return credit == debit ? null : credit;
  }

  /// Gemini-first phase 1: the direction a transfer's own flow states
  /// ([transferCreditPattern] / [transferDebitPattern]), or null.
  static bool? transferFlowCredit(String text) {
    final t = TransactionStateCues.foldForCues(text);
    final credit = _transferCredit.hasMatch(t), debit = _transferDebit.hasMatch(t);
    return credit == debit ? null : credit;
  }

  /// Gemini-first phase 1: a transfer the model reads (after masking): its
  /// own flow names the other side ([transferFlowCredit]) or it names a
  /// payment channel (IPN / InstaPay, `CHANNEL_ALIASES` in
  /// `_shared/analysis_reasons.ts`). One naming neither may be the user's own
  /// move: read locally. Server twin: `transferForModel` in
  /// process-ios-sms/parse.ts.
  static bool transferForModel(String text) =>
      transferFlowCredit(text) != null || _paymentChannel.hasMatch(text);

  static final RegExp _paymentChannel = RegExp(
      r'\bipn\b|insta ?pay|إنستا ?باي|انستا ?باي',
      caseSensitive: false);

  /// Narrow check Z (N-M1b): a stated credit wording next to an installment,
  /// fee or charge noun ("Installment … added to your account").
  static bool statedCreditWithDebt(String text) =>
      statedCredit(text) == true &&
      _statedCreditDebt.hasMatch(TransactionStateCues.foldForCues(text));

  /// Why a meaning that would record [text] is uncertain instead, or null
  /// when the text is clearly completed. [hasFlow]: the clause's own verbs
  /// give a direction (a plain transfer notice that states its flow,
  /// «حوالة واردة 500 ريال من …», "SAR 500 transferred to …", is completed;
  /// one whose direction only a purpose word suggests is not).
  static String? uncertaintyOf(String text, {required bool hasFlow}) {
    if (doubtOf(text) != null) return 'not_clearly_completed';
    if (!hasFlow && !hasCompletedForm(text)) {
      return 'no_completed_form';
    }
    return null;
  }
}
