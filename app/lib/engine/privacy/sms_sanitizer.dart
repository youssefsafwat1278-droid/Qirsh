import '../models/transaction_type.dart';

/// Sanitizes a raw bank SMS before sending to any off-device AI service.
///
/// The sanitized string is for AI consumption ONLY. The raw SMS is always
/// stored locally and fed to the rule-based parser unchanged.
///
/// Strip order matters — phone patterns must run before the broad
/// account-number pattern so phone digits are not double-redacted.
///
/// Transfer vs purchase distinction (owner decision 2026-06-16; round 4:
/// decided from the TEXT, never from a parser type, so the device, the
/// Shortcut and the server agree):
/// - a message that reads as a purchase, refund, bill or card payment: the
///   counterparty is a merchant and is kept (a business is not PII; the AI
///   and the saved category rules need it);
/// - anything else: the beneficiary after إلى: / To: is STRIPPED, unless its
///   name carries a business marker. A person's name, account or card number
///   and account/card suffix never leave the device.
///
/// Personal names (F4, 2026-11): names after a salutation (Dear / عزيزي /
/// السيد …) and after a counterparty cue (from / to / received from /
/// credited by / من / لصالح / Beneficiary …) are masked as `[NAME]`, keeping
/// the cue. Counterparty cues apply only when the TEXT reads as a transfer or
/// credit and not as a purchase/refund/bill ([isCounterpartyContext]), so
/// "Purchase from AMAZON" / «شراء من كارفور» keep their merchant. The server
/// (`supabase/functions/_shared/sms_redaction.ts`) applies the same rules;
/// `sms_redaction_cases.json` pins both to identical output.
class SmsSanitizer {
  SmsSanitizer._();

  // ── Digit classes ────────────────────────────────────────────────────────
  // Saudi and Egyptian banks send Arabic-Indic digits as well as Latin ones —
  // that is the entire reason `Normalizer.normalizeDigits` exists. But the
  // parser normalises a COPY, while this sanitizer runs on the string that
  // actually leaves the device, and every pattern below used ASCII `\d`. A
  // card, IBAN or account number written in the digits half this market uses
  // was therefore transmitted unredacted.
  //
  // They are matched in place rather than normalised first: the proof layer
  // compares model output against spans of the very string that was sent, and
  // `sanitization_edit_map.dart` records where each character went, so
  // rewriting characters here would move those spans out from under both.
  static const String _dc = r'[0-9٠-٩۰-۹]';

  // `\b` is defined over [A-Za-z0-9_] alone. It does not treat U+0660 as a word
  // character, so against an Arabic-Indic run it places a "boundary" in the
  // middle of the digits and matches a fragment. These two lookarounds are the
  // same assertion widened to cover the digits above; on ASCII input they are
  // exactly equivalent to `\b`.
  static const String _wordish = r'0-9٠-٩۰-۹A-Za-z_';
  static const String _nb = '(?<![$_wordish])';
  static const String _nbEnd = '(?![$_wordish])';

  // ── Card numbers ─────────────────────────────────────────────────────────
  // Full 16-digit cards with optional separators. Does NOT match *1234 masked
  // forms (starts with *) — those are intentionally kept (not PII).
  static final _cardNumber = RegExp(
    '$_nb$_dc{4}[\\s\\-]?$_dc{4}[\\s\\-]?$_dc{4}[\\s\\-]?$_dc{4}$_nbEnd',
  );

  // ── Phone numbers ─────────────────────────────────────────────────────────
  // Saudi mobile: 05XXXXXXXX (10 digits starting with 05)
  // The leading 0 and 5 may themselves be Arabic-Indic, so they are classes
  // rather than literals.
  static final _saudiPhone =
      RegExp('$_nb[0٠۰][5٥۵]$_dc{8}$_nbEnd');
  // Egyptian mobile: 01[0125]XXXXXXXX
  static final _egyptPhone = RegExp('$_nb[0٠۰][1١۱]'
      '[0125٠١٢٥۰۱۲۵]$_dc{8}$_nbEnd');
  // International: +CC followed by 7–14 digits
  static final _intlPhone = RegExp('\\+$_dc{7,15}$_nbEnd');

  // ── IBAN ─────────────────────────────────────────────────────────────────
  // ISO 13616: two country letters, two check digits, then up to 30
  // alphanumerics. The account pattern below is digits-only and therefore
  // CANNOT match an IBAN — `SA0380000000608010167519` passed through
  // untouched before this existed, which is a full account identifier sent to
  // a third party. Runs BEFORE the digit rule so the more specific form wins.
  //
  // The country code is matched case-insensitively: `RegExp` defaults to
  // case-sensitive, so `sa0380000000608010167519` — the same identifier, typed
  // in lower case — used to pass straight through.
  static final _iban = RegExp(
    '$_nb[A-Za-z]{2}$_dc{2}[A-Za-z0-9٠-٩۰-۹]{11,30}$_nbEnd',
  );

  // ── One-time passcodes ───────────────────────────────────────────────────
  // CUE-ANCHORED on purpose. A bare 4-6 digit run is far more often an amount
  // or a card suffix than a passcode, so redacting by shape alone would
  // destroy the very value the proof layer exists to establish. Only digits
  // that FOLLOW an explicit OTP cue are removed, and the cue itself is kept so
  // the message stays classifiable as an OTP.
  static final _otp = RegExp(
    r'((?:otp|one[- ]?time(?:\s+password)?|verification\s+code|'
    r'رمز\s+التحقق|كود\s+التحقق|رمز\s+الدخول)'
    '(?:\\s+(?:is|هو))?\\s*:?\\s*)$_dc{4,8}',
    caseSensitive: false,
  );

  // Round 4 (real-model run): a one-time code must never leave the device,
  // whatever the cue wording and on whichever side of the code the cue sits.
  // Still cue-anchored: a figure next to a currency, a decimal or grouped
  // figure, a date or time, and a card or account suffix are never a code, so
  // an amount of the same length survives ("is 482913 SAR"). Server twin:
  // OTP_PATTERNS, in the same order.
  static const String _otpCurrency =
      r'sar|egp|aed|usd|eur|gbp|kwd|qar|bhd|omr|jod|le|sr|riyals?|pounds?|dirhams?|dinars?|dollars?|ريال|جنيه|جم|درهم|دينار|دولار|يورو|ر\.س';
  static const String _otpCue =
      r'(?:otp|one[- ]?time[ \t]+(?:password|passcode|pin|code)'
      r'|(?:verification|security|activation|confirmation|authentication|access|login|secret)[ \t]+code'
      // A purchase's approval, reference or promo code is not a one-time code.
      r'|passcode|password|(?<!(?:approval|auth|authorization|authorisation|reference|transaction|receipt|pickup|promo|discount|coupon|voucher|order|branch|swift|bank|area|postal)[ \t])code|كلمة[ \t]+المرور(?:[ \t]+لمرة[ \t]+واحدة)?|كلمة[ \t]+السر'
      r'|(?:رمز|كود)[ \t]+(?:التحقق|الدخول|التفعيل|الأمان|الامان|التأكيد|التاكيد)|الرمز[ \t]+السري|رمز[ \t]+سري|الرقم[ \t]+السري'
      r'|رمزك|الرمز|رمز|كودك|الكود|كود)';
  static const String _otpNumber =
      '(?<![0-9٠-٩۰-۹*•#]|$_dc[.,٫٬/:\\-]|(?<![\\p{L}\\p{M}])(?:$_otpCurrency)[ \\t]{0,3}'
      r'|(?<![\p{L}\p{M}])(?:card|account|acct|ending|بطاقة|البطاقة|حساب|الحساب)[ \t]{1,3})'
      '$_dc{4,8}(?!$_dc|[.,٫٬/:\\-]$_dc|[ \\t]*(?:$_otpCurrency)(?![\\p{L}\\p{M}]))';
  static RegExp _otpRule(String source) =>
      RegExp(source, caseSensitive: false, unicode: true);

  /// Each rule keeps its group 1 and masks the code after it. `cue` rules
  /// carry the cue word in group 2; a `weak` rule has no verification wording
  /// at all. Server twin: OTP_RULES, in the same order.
  static final List<(RegExp, String)> otpRules = [
    // First, so the wording decides: a code is what a message says not to
    // share.
    (
      _otpRule('()$_otpNumber'
          r"(?=[ \t]*[.,،;]?[ \t]*(?:(?:please|الرجاء|يرجى)[ \t]+)?(?:do[ \t]+not[ \t]+share|don['’]?t[ \t]+share|never[ \t]+share|لا[ \t]+تشارك|عدم[ \t]+مشارك|لا[ \t]+تفصح))"),
      'strong'
    ),
    // The cue, an optional "is" / «هو» / "no.", then the code.
    (
      _otpRule('((?<![\\p{L}\\p{M}])($_otpCue)(?![\\p{L}\\p{M}])'
          r'(?:[ \t]*(?:is|are|was|no\.?|number|هو|هي|رقم)(?![\p{L}\p{M}]))?[ \t]*[:#=\-]?[ \t]*)'
          '$_otpNumber'),
      'cue'
    ),
    // The cue earlier in the sentence, the code right after "is" / «هو».
    (
      _otpRule('((?<![\\p{L}\\p{M}])($_otpCue)(?![\\p{L}\\p{M}])'
          '(?:[^\\n.!?؟]|\\.(?=$_dc)){0,80}?'
          r'(?<![\p{L}\p{M}])(?:is|are|هو|هي)(?![\p{L}\p{M}])[ \t]*:?[ \t]*)'
          '$_otpNumber'),
      'cue'
    ),
    // The code first: "482913 is your verification code".
    (
      _otpRule('()$_otpNumber'
          r'(?=[ \t]+(?:is|هو|هي)[ \t]+(?:(?:your|the)[ \t]+)?(?:[\p{L}\p{M}]+[ \t]+){0,3}?'
          '($_otpCue)(?![\\p{L}\\p{M}]))'),
      'cue'
    ),
    // "Use 482913 to confirm …", «استخدم 482913».
    (
      _otpRule(
          r'((?<![\p{L}\p{M}])(?:use|enter|type|استخدم|أدخل|ادخل)(?![\p{L}\p{M}])[ \t]+(?:(?:the|this)[ \t]+)?)'
          '$_otpNumber'),
      'weak'
    ),
  ];

  // The bare cues: they also introduce a promo, pickup or receipt code.
  static final _otpBareCue = RegExp(r'^(?:code|رمزك|الرمز|رمز|كودك|الكود|كود)$',
      caseSensitive: false, unicode: true);
  static final _otpSentenceEnd = RegExp('[\\n!?؟]|\\.(?!$_dc)', unicode: true);
  static final _otpMoney = RegExp(
      '(?<![\\p{L}\\p{M}])(?:$_otpCurrency)(?![\\p{L}\\p{M}])',
      caseSensitive: false,
      unicode: true);

  /// The replacement for a match of an [otpRules] entry in [text]: group 1
  /// and the placeholder. Under verification wording the placeholder is
  /// `[OTP]`. Under a bare cue ("code 4829", "Use 4829 …") it is `[OTP]` too,
  /// unless an earlier sentence of the message already states an amount: that
  /// is a promo, pickup or receipt code after a movement, written `[REF]` so
  /// no server reads the movement as an OTP notice. Server twin:
  /// codePlaceholder.
  static String codeReplacement(String text, Match m, String mode) {
    final prefix = m.group(1)!;
    if (mode == 'strong' ||
        (mode == 'cue' && !_otpBareCue.hasMatch(m.group(2) ?? ''))) {
      return '$prefix[OTP]';
    }
    final before = text.substring(0, m.start);
    var end = 0;
    for (final s in _otpSentenceEnd.allMatches(before)) {
      end = s.end;
    }
    final earlier = before.substring(0, end);
    return _digit.hasMatch(earlier) && _otpMoney.hasMatch(earlier)
        ? '$prefix[REF]'
        : '$prefix[OTP]';
  }

  // ── Account numbers ───────────────────────────────────────────────────────
  // Any 10–20 consecutive digits that were NOT already replaced by the phone
  // or card patterns above. Amounts are ≤ 9 digits without a currency context;
  // real account numbers are 10+.
  static final _accountNumber = RegExp('$_nb$_dc{10,20}$_nbEnd');

  // An IBAN written in groups ("SA88 1234 5678 9012 3456 9898"). The unspaced
  // rule cannot see it and the card rule used to eat the middle 16 digits,
  // leaving the country, check digits and last group behind. Every group
  // after the check digits holds a digit. Runs before the card rule
  // (PRIV-0). Server twin: SPACED_IBAN_PATTERN.
  static final _spacedIban = RegExp(
    '$_nb[A-Za-z]{2}$_dc{2}(?:[ \\-](?=[A-Za-z0-9٠-٩۰-۹]{0,3}$_dc)[A-Za-z0-9٠-٩۰-۹]{4}){3,7}'
    '(?:[ \\-](?=[A-Za-z0-9٠-٩۰-۹]{0,3}$_dc)[A-Za-z0-9٠-٩۰-۹]{1,3})?$_nbEnd',
  );

  // A number of 5 to 9 digits right after an account label ("account
  // 60181590", «حساب ٦٠١٨١٥٩٠», "a/c no. 1234567") is an account number,
  // even though it is shorter than the generic rule. A partial suffix of 4
  // digits or fewer stays, and a figure followed by a currency or a decimal
  // part is an amount and stays (PRIV-0). Server twin:
  // LABELLED_ACCOUNT_PATTERN.
  static final _labelledAccount = RegExp(
    r'((?<![\p{L}\p{M}])(?:account|acct|acc|a\/c|ac|حساب|الحساب|لحساب|للحساب|بحساب|حسابك|لحسابك|حسابكم|حسابي)'
    r'(?![\p{L}\p{M}])\.?(?:[ \t]+(?:no|number|num|رقم)(?![\p{L}\p{M}])\.?)?[ \t]*[:#]?[ \t]*)'
    '[*xX•#]*$_dc{5,9}(?!$_dc|[.,٫٬]$_dc|[ \\t]*(?:sar|egp|aed|usd|eur|gbp|kwd|qar|bhd|omr|jod|le|sr|riyals?|pounds?|dirhams?|dinars?|dollars?|ريال|جنيه|جم|درهم|دينار|دولار|يورو|ر\\.س)(?![\\p{L}\\p{M}])(?![ \\t]*$_dc))',
    caseSensitive: false,
    unicode: true,
  );

  // ── Beneficiary / transfer recipient ─────────────────────────────────────
  // The name after إلى: / الى: / To: (and the account or card object before
  // it), never a tense, status, amount, currency or date word, an amount, a
  // date or the next sentence (SM-07 / Vso4: «إلى حساب 7788 سينفذ غدا» keeps
  // «سينفذ غدا», so the model still reads the tense). Server twin:
  // BENEFICIARY_AR / BENEFICIARY_EN in _shared/sms_redaction.ts.
  // Applied only when stripping is required (see [sanitize]).
  static final String _beneficiaryToken =
      "(?!(?:${nameStopwords.where((w) => !beneficiaryObjectWords.contains(w)).join('|')})"
      "(?![\\p{L}\\p{M}*'’\\-]|\\.[\\p{L}\\p{M}]))"
      "[\\p{L}\\p{M}][\\p{L}\\p{M}*'’\\-]*(?:\\.[\\p{L}\\p{M}][\\p{L}\\p{M}*'’\\-]*)*"
      '(?:(?<=(?<![\\p{L}\\p{M}])(?:\\p{L}|mrs|mr|ms|dr))\\.)?';
  // A name already masked as [NAME] is part of the run, so the beneficiary
  // still reads [REDACTED] as before.
  // The third party's account, card or IBAN number is part of the run too
  // (Western or Arabic-Indic digits, star-masked or not, a placeholder, an
  // IBAN-like token), so «إلى حساب 7788 سينفذ غدا» → «إلى: [REDACTED] سينفذ غدا».
  // A figure followed by a currency or a decimal part is an amount, and one
  // with `/` or `:` is a date or time: those end the run and are kept.
  static const List<String> _currencyAfter = [
    'sar', 'egp', 'aed', 'usd', 'eur', 'gbp', 'kwd', 'qar', 'bhd', 'omr',
    'jod', 'le', 'sr', 'riyals?', 'pounds?', 'dirhams?', 'dinars?',
    'dollars?', 'ريال', 'جنيه', 'جم', 'درهم', 'دينار', 'دولار', 'يورو',
    r'ر\.س',
  ];
  static final String _beneficiaryId =
      '(?:\\[(?:ACCOUNT|IBAN|CARD|PHONE|REF)\\]'
      '|[A-Z]{2}$_dc{2}(?:[ ]?[0-9A-Z]{4})*(?:[ ]?[0-9A-Z]{1,3})?'
      '|[*xX•#]*$_dc+(?:-$_dc+)*)'
      '(?![0-9A-Za-z]|[.,٫٬/:]$_dc|$_dc'
      '|[ \\t]*(?:${_currencyAfter.join('|')})(?![\\p{L}\\p{M}])(?![ \\t]*$_dc))';
  static final String _beneficiaryPart =
      '(?:$_beneficiaryId|$_beneficiaryToken)';
  static final String _beneficiaryRun =
      '(?:\\[NAME\\]|$_beneficiaryPart)(?:[ \\t]+$_beneficiaryPart)*';
  static final _beneficiaryAr = RegExp(
    '(إلى|الى)\\s*:?\\s*$_beneficiaryRun',
    caseSensitive: false,
    unicode: true,
  );
  static final _beneficiaryEn = RegExp(
    '\\bTo(?:[ \\t]+name)?\\s*:\\s*$_beneficiaryRun',
    caseSensitive: false,
    unicode: true,
  );

  // The user's own account or card after the cue stays («إلى حسابك ***1234»),
  // but only as a partial suffix: an unmasked number of five or more digits
  // after it is still masked as [ACCOUNT] (10+ digits already are). Server
  // twin: OWN_DESTINATION_NUMBER.
  static final _ownDestinationNumber = RegExp(
    '((?:إلى|الى|\\bto)\\s*:?\\s*(?:your|حسابك|حسابكم|لحسابك|بطاقتك|بطاقتكم|محفظتك)'
    '(?:[ \\t]+(?:account|card|wallet|رقم|no\\.?|number))?[ \\t]+)[*xX•#]*$_dc{5,}'
    '(?![.,٫٬/:]?$_dc|[ \\t]*(?:${_currencyAfter.join('|')})(?![\\p{L}\\p{M}])(?![ \\t]*$_dc))',
    caseSensitive: false,
    unicode: true,
  );

  // Any other number left in the beneficiary's sentence (from إلى / الى /
  // To: to the end of the sentence, the span the rule used to remove whole)
  // is masked as [ACCOUNT], unless it is an amount (a currency next to it, or
  // a grouped or decimal figure), a date or time, a day before a month name,
  // or the user's own partial suffix (at most four digits after «حسابك»,
  // "your account" …). Server twin: NUMBER_IN_BENEFICIARY_SENTENCE.
  static const List<String> _month = [
    'يناير', 'فبراير', 'مارس', 'أبريل', 'ابريل', 'مايو', 'يونيو', 'يوليو',
    'أغسطس', 'اغسطس', 'سبتمبر', 'أكتوبر', 'اكتوبر', 'نوفمبر', 'ديسمبر',
    'jan(?:uary)?', 'feb(?:ruary)?', 'mar(?:ch)?', 'apr(?:il)?', 'may',
    'june?', 'july?', 'aug(?:ust)?', 'sep(?:t|tember)?', 'oct(?:ober)?',
    'nov(?:ember)?', 'dec(?:ember)?',
  ];
  static const String _ownWord =
      r'(?:your|حسابك|حسابكم|لحسابك|بطاقتك|بطاقتكم|محفظتك)'
      r'(?:[ \t]+(?:account|card|wallet|رقم|no\.?|number))?';
  static final String _currencyWord =
      '(?:${_currencyAfter.join('|')})(?![\\p{L}\\p{M}])';
  static final _numberInBeneficiarySentence = RegExp(
    '(?<![A-Za-z0-9٠-٩۰-۹*•#]|$_dc[.,٫٬/:\\-])'
    '(?![*xX•#]*$_dc{1,4}(?!$_dc|-$_dc)(?<=$_ownWord[ \\t]+[*xX•#]*$_dc+))'
    '(?!$_dc{1,2}[ \\t]+(?:${_month.join('|')})(?![\\p{L}\\p{M}]))'
    '(?<!(?<![\\p{L}\\p{M}])$_currencyWord[ \\t]*)'
    '(?:[A-Z]{2}(?=$_dc))?[*xX•#]*$_dc+(?:-$_dc+)*'
    '(?![0-9A-Za-z٠-٩۰-۹]|[.,٫٬/:\\-]$_dc|[ \\t]*$_currencyWord(?![ \\t]*$_dc))'
    '(?<=(?:إلى|الى|\\bTo(?:[ \\t]+name)?\\s*:)(?:(?!$_sentenceEnd).)*)',
    caseSensitive: false,
    unicode: true,
  );

  // ── Arabic greetings with personal names ─────────────────────────────────
  // "عزيزي أحمد" / "عزيزتي سارة" — name follows the greeting word.
  // Does NOT match "عميلنا العزيز" (no personal name after it).
  static final _greeting = RegExp(
    r'(عزيزي|عزيزتي)\s+\S+',
    caseSensitive: false,
  );

  // ── E-mail addresses ─────────────────────────────────────────────────────
  // Runs FIRST: a local part such as `ahmed0551234567` would otherwise be
  // half-eaten by the phone rule and leave the rest behind.
  static final _email =
      RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}');

  // ── Reference numbers ────────────────────────────────────────────────────
  // CUE-ANCHORED like the OTP rule: six or more characters containing a digit
  // after `Ref`, `Reference No`, `RRN`, `رقم المرجع`, `رقم العملية` … A
  // reference ties the message to one transaction at the bank — a
  // pseudonymous identifier the parser never needs. The cue is kept (the parse
  // prompt reads "IPN REF" as a transfer signal). A run that continues into a
  // decimal is an amount and is left alone. Runs AFTER the account rule, so a
  // 10+ digit reference stays [ACCOUNT] as before; this adds the 6-9
  // character ones.
  static const String _refChar = r'[A-Za-z0-9٠-٩۰-۹\-]';
  static final _reference = RegExp(
    r'((?<![\p{L}\p{M}])(?:reference|ref|rrn|رقم[ \t]+المرجع|'
    r'الرقم[ \t]+المرجعي|المرجع|مرجع|رقم[ \t]+العملية|رقم[ \t]+الحوالة|'
    r'رقم[ \t]+المعاملة)(?![\p{L}\p{M}])'
    r'(?:[ \t]*(?:no|number|num|id)(?![\p{L}\p{M}]))?[ \t]*[.:#]*[ \t]*)'
    '(?=$_refChar*$_dc)$_refChar{6,}'
    '(?!$_refChar|[.,٫٬]$_dc)',
    caseSensitive: false,
    unicode: true,
  );

  // ── Personal names ───────────────────────────────────────────────────────
  // Masked with the TYPED placeholder `[NAME]`, keeping the cue (`from`,
  // `من`, `Dear` …) so the model still sees the message's structure. Mirrors
  // `supabase/functions/_shared/sms_redaction.ts` pattern for pattern; the
  // shared fixture `sms_redaction_cases.json` holds both to the same output.
  //
  // A name is 1-6 tokens of letters (Latin or Arabic), combining marks and
  // `* . ' ’ -` (masked names such as `AHM***` and initials such as
  // `A.HASSAN` are names too). It ends at a digit, punctuation, a line break,
  // a placeholder, or a STOPWORD — words that follow a name in real bank
  // messages (`on`, `via`, `ref`, `بمبلغ`, `في` …) and words that follow a
  // cue without being a name (`your account`, `حسابك`, `Customer`,
  // currencies, verbs). It never touches a digit, so amounts, dates, times
  // and card tails survive by construction.
  static const List<String> nameStopwords = [
    // English
    'your', 'yours', 'you', 'our', 'us', 'the', 'a', 'an', 'account',
    'accounts', 'acct', 'acc', 'ac', 'card', 'cards', 'wallet', 'mobile', 'phone',
    'number', 'no', 'on', 'at', 'in', 'into', 'via', 'using', 'with', 'for',
    'of', 'to', 'from', 'by',
    // PRIV-1: a person cue is never (the start of) the name it introduces.
    'beneficiary', 'benef', 'payee', 'sender', 'remitter', 'recipient', 'payer',
    'ref', 'reference', 'rrn', 'amount', 'amt',
    'is', 'was', 'has', 'have', 'been', 'and', 'or', 'date', 'time',
    'balance', 'bal', 'avl', 'available', 'avail', 'customer', 'customers',
    'client', 'cardholder', 'holder', 'valued', 'sir', 'madam', 'member',
    'there', 'team', 'atm', 'branch', 'bank', 'app', 'online', 'internet',
    'instapay', 'ipn', 'sarie', 'mada', 'swift', 'transfer', 'transaction',
    'trx', 'txn', 'successful', 'successfully', 'credit', 'debit',
    'credited', 'debited', 'cash', 'deposit', 'salary', 'sar', 'egp', 'aed',
    'usd', 'eur', 'gbp', 'kwd', 'qar', 'bhd', 'omr', 'jod', 'le', 'sr',
    'riyal', 'riyals', 'pound', 'pounds', 'dirham', 'dirhams', 'dinar',
    'dinars', 'dollar', 'dollars', 'transferred', 'sent', 'received', 'paid',
    'made', 'requested', 'deposited', 'withdrew', 'initiated', 'will',
    'would', 'name',
    // Arabic
    'حسابك', 'حسابكم', 'حساب', 'الحساب', 'حسابات', 'لحسابك', 'لحساب',
    'للحساب', 'بطاقتك', 'بطاقتكم', 'بطاقة', 'البطاقة', 'بطاقه', 'رصيدك',
    'رصيد', 'الرصيد', 'خلال', 'قبل', 'في', 'على', 'عن', 'إلى', 'الى', 'الي',
    'من', 'بمبلغ', 'مبلغ', 'المبلغ', 'بقيمة', 'قيمة', 'بتاريخ', 'تاريخ',
    'يوم', 'اليوم', 'الساعة', 'الساعه', 'ساعة', 'وقت', 'رقم', 'عبر',
    'بواسطة', 'محفظة', 'محفظتك', 'المحفظة', 'ريال', 'جنيه', 'جم', 'درهم',
    'دينار', 'دولار', 'يورو', 'العميل', 'عميلنا', 'عملائنا', 'عزيزي',
    'تطبيق', 'الصراف', 'صراف', 'جهاز', 'مدى', 'سريع', 'انستاباي', 'حوالة',
    'حواله', 'تحويل', 'التحويل', 'الحوالة', 'واردة', 'وارده', 'صادرة',
    'صادره', 'البنك', 'بنك', 'فرع', 'عند', 'لدى', 'و', 'تم', 'المتاح',
    'متاح', 'المرجع', 'مرجع', 'رسوم', 'عمولة', 'قام', 'حول', 'حوّل', 'أرسل',
    'ارسل', 'إرسال', 'ارسال', 'بتحويل', 'بإرسال', 'استلم', 'أودع', 'اودع',
    'سحب', 'دفع',
    // Tense and status words (SM-07 / Vso4): a name never runs into what
    // the message says happened, so «… إلى علي سينفذ غدا» keeps «سينفذ غدا».
    'shall', 'tomorrow', 'today', 'scheduled', 'executes', 'executed',
    'execution', 'pending', 'declined', 'rejected', 'failed', 'unsuccessful',
    'completed', 'approved', 'processed', 'awaiting', 'expected', 'upcoming',
    'reversed', 'cancelled', 'canceled', 'not', 'please', 'if', 'once', 'when',
    'every', 'under', 'due', 'سينفذ', 'ستنفذ', 'سيتم', 'ستتم', 'سوف', 'غدا',
    'غداً', 'مجدول', 'مجدولة', 'سيخصم', 'سيُخصم', 'سيضاف', 'سيودع', 'جاري',
    'جارٍ', 'قيد', 'معلق', 'معلقة', 'مرفوضة', 'مرفوض', 'رفض', 'فشلت', 'فشل',
    'لم', 'تمت', 'بنجاح', 'يرجى', 'الرجاء', 'إذا', 'اذا', 'مستحق', 'مستحقة',
    // Account types (own-account moves keep «from Savings to Current»).
    'savings', 'saving', 'current', 'checking', 'chequing',
    'iban', 'الآيبان', 'الايبان', 'آيبان', 'ايبان',
    // A failure reason after "due to" is never a name (L_L58).
    'insufficient', 'funds', 'limit', 'reason', 'technical', 'error',
    'request', 'lack',
    'التوفير', 'توفير', 'الادخار', 'ادخار', 'الجاري',
    // Words that open a label, a notice or a sentence without being a name.
    'payment', 'payments', 'purchase', 'refund', 'bill', 'pos', 'attn',
    'attention', 'cardholder', 'service', 'care', 'support', 'we', 'it', 'he',
    'she', 'they', 'this', 'that', 'money', 'sum', 'total', 'fee', 'fees',
    'charge', 'charges', 'loan', 'installment', 'instalment', 'invoice', 'tax',
    'vat', 'cashback', 'order', 'standing', 'incoming', 'outgoing', 'local',
    'international', 'domestic', 'instant', 'internal', 'external', 'own',
    'between', 'confirmation', 'alert', 'notification', 'notice', 'details',
    'update', 'status', 'advice', 'merchant', 'id', 'now', 'here', 'then',
    'الاسم', 'اسم', 'عناية', 'شراء', 'سداد', 'عملية', 'العملية', 'التاجر',
    'المتجر', 'الكريم', 'العزيز', 'خدمة', 'ناجح', 'ناجحة', 'داخلي', 'داخلية',
    'دولي', 'دولية', 'محلي', 'محلية', 'فوري', 'فورية', 'سريعة', 'بنكي', 'بنكية',
    'مالية', 'جديد', 'جديدة', 'صادر', 'وارد', 'إشعار', 'اشعار', 'تنبيه', 'تأكيد',
    'تفاصيل', 'لك', 'إليك', 'اليك', 'حامل', 'صاحب', 'بين',
  ];

  /// Words the beneficiary rule may consume with the name: the account or
  /// card object a name follows («إلى حساب سارة», "To: the account of …").
  /// The user's OWN account or card («إلى حسابك», "to your card") is not a
  /// third party and stays, so own-account moves and credits read the same
  /// after redaction. Every other stopword (tense, status, amount, currency,
  /// date) ends the run.
  static const Set<String> beneficiaryObjectWords = {
    'you', 'us', 'the', 'a', 'an', 'account',
    'accounts', 'acct', 'acc', 'ac', 'card', 'cards', 'wallet', 'mobile', 'phone',
    'number', 'no', 'name', 'حساب', 'الحساب', 'حسابات',
    'لحساب', 'للحساب', 'بطاقة', 'البطاقة',
    'بطاقه', 'محفظة', 'المحفظة', 'رقم',
  };

  static final String _nameToken =
      // A one-letter stopword before ". Name" is an initial («A. Ali Hassan»).
      "(?!(?:${nameStopwords.join('|')})(?![\\p{L}\\p{M}*'’\\-]|\\.[\\p{L}\\p{M}]|(?<=(?<![\\p{L}\\p{M}])\\p{L})\\.[ \\t]+\\p{L}))"
      // SM-07: a sentence-ending period is never part of a name (server twin
      // NAME_TOKEN); an initial or title keeps its period. A lone star
      // before digits is a masked number, and letters glued to digits
      // (an IBAN's «SA03») are not a name.
      "(?!\\*+$_dc)[\\p{L}\\p{M}*](?:[\\p{L}\\p{M}*'’\\-]|(?!$_sentenceEnd)\\.)*"
      "(?![\\p{L}\\p{M}*'’\\-]|$_dc)";
  static const String _sentenceEnd =
      r'(?:(?<!(?<![\p{L}\p{M}])(?:\p{L}|mrs|mr|ms|dr))\.(?=\s|$)|[\n!?؟;؛])';
  static final String _name = '$_nameToken(?:[ \\t]+$_nameToken){0,5}';
  static const String _cueSep = r'(?:[ \t]*:[ \t]*|[ \t]+)';

  // Salutations — a name follows by definition, in any kind of message.
  // English greetings only at the start of the text or of a sentence, so a
  // merchant such as "DEAR DIARY CAFE" after "Purchase at" is not one.
  static final _salutation = RegExp(
    r'((?:(?<![\p{L}\p{M}])(?:عزيزي|عزيزتي|السيدة|السيد|الأستاذة|الاستاذة|'
    r'الأستاذ|الاستاذ)|(?:^|(?<=[\n.!?؟؛;:،,]))[ \t]*(?:dear|hi|hello))'
    '(?![\\p{L}\\p{M}])$_cueSep)($_name)',
    caseSensitive: false,
    unicode: true,
  );

  // Counterparty cues. These words introduce a MERCHANT in a purchase
  // ("Purchase from AMAZON", «شراء من كارفور») and a PERSON in a transfer
  // ("Transfer received from AHMED ALI", «حوالة واردة من محمد أحمد»), so they
  // are applied only when [isCounterpartyContext] holds.
  static final _counterparty = RegExp(
    r'((?<![\p{L}\p{M}])(?:from|to(?:[ \t]+name)?|by|beneficiary(?:[ \t]+name)?|'
    r'sender(?:[ \t]+name)?|remitter(?:[ \t]+name)?|'
    r'recipient(?:[ \t]+name)?|payer(?:[ \t]+name)?|on[ \t]+behalf[ \t]+of|'
    r'in[ \t]+favou?r[ \t]+of|mrs|mr|ms|dr|من[ \t]+قبل|اسم[ \t]+المستفيد|'
    r'اسم[ \t]+المرسل|المستفيد|مستفيد|المرسل|المحول|لصالح|باسم|بواسطة|من|إلى|الى|'
    r'الي)'
    '\\.?(?![\\p{L}\\p{M}])$_cueSep)($_name)',
    caseSensitive: false,
    unicode: true,
  );

  // PRIV-1: cues that only ever introduce a person (a payee, a beneficiary,
  // a sender), so they apply in any message. Server twin: PERSON_CUE_PATTERN.
  static final _personCue = RegExp(
    r'((?<![\p{L}\p{M}])(?:beneficiary(?:[ \t]+name)?|benef|payee(?:[ \t]+name)?|sender(?:[ \t]+name)?'
    r'|remitter(?:[ \t]+name)?|recipient(?:[ \t]+name)?|payer(?:[ \t]+name)?|on[ \t]+behalf[ \t]+of|in[ \t]+favou?r[ \t]+of'
    r'|اسم[ \t]+المستفيد|اسم[ \t]+المرسل|المستفيد|مستفيد|المرسل|المحول|لصالح|باسم)'
    '\\.?(?![\\p{L}\\p{M}])$_cueSep)($_name)',
    caseSensitive: false,
    unicode: true,
  );

  // PRIV-1: a "From:" field label and "paid to" — a person unless the text
  // reads as a purchase, refund or bill. Server twin: LABEL_CUE_PATTERN.
  static final _labelCue = RegExp(
    r'((?<![\p{L}\p{M}])(?:from[ \t]*:|paid[ \t]+to(?![\p{L}\p{M}]))[ \t]*)'
    '($_name)',
    caseSensitive: false,
    unicode: true,
  );

  // PRIV-1: "To Sara Ahmed: SAR 50.00 …", "From Sara Ahmed: …", «من سارة
  // أحمد: …» — a name between the word at the start of the text or a sentence
  // and a colon. Server twin: TO_HEADING_PATTERN.
  static final _toHeading = RegExp(
    r'((?:^|(?<=[\n.!?؟;؛]))[ \t]*(?:to|from|من)[ \t]+)'
    '($_name)(?=[ \\t]*:)',
    caseSensitive: false,
    unicode: true,
  );

  // PRIV-1r: field labels that only ever introduce a person ("Attn Sara",
  // "Name: Sara Ahmed", "Customer Sara Ahmed", «الاسم: سارة», "Cardholder …"),
  // in any message. "Merchant name: …" names a business. Server twin:
  // PERSONAL_LABEL_PATTERN.
  static final _personalLabel = RegExp(
    r'((?<![\p{L}\p{M}])(?:attn|attention|(?<!merchant[ \t]|store[ \t]|shop[ \t]|bank[ \t]|company[ \t])name|customer(?:[ \t]+name)?'
    r'|card[ \t]?holder(?:[ \t]+name)?|account[ \t]+holder(?:[ \t]+name)?|عناية|الاسم|اسم|العميل|حامل[ \t]+البطاقة|صاحب[ \t]+الحساب)'
    '\\.?(?![\\p{L}\\p{M}])$_cueSep)($_name)',
    caseSensitive: false,
    unicode: true,
  );

  // SP-16: "to account of Mohammed Abdullah", «حساب باسم محمد» — the holder
  // of an account, in any message. Server twin: ACCOUNT_OF_PATTERN.
  static final _accountOf = RegExp(
    r'((?<![\p{L}\p{M}])(?:(?:account|acct|acc|a\/c|ac|card|wallet)[ \t]+of|(?:حساب|الحساب|لحساب|بطاقة|محفظة)[ \t]+باسم)(?![\p{L}\p{M}])'
    '$_cueSep)($_name)',
    caseSensitive: false,
    unicode: true,
  );

  // SP-16: a name in parentheses right after an account or card number
  // ("account *9876 (Noura)"), unless the text reads as a purchase. Server
  // twin: PAREN_NAME_PATTERN.
  static final _parenName = RegExp(
    '((?:\\[(?:ACCOUNT|CARD|IBAN|PHONE)\\]|[*xX•#]$_dc{1,9}'
    r'|(?<![\p{L}\p{M}])(?:account|acct|acc|a\/c|ac|card|wallet|حساب|الحساب|لحساب|للحساب|بطاقة|البطاقة|محفظة)[ \t]*[:#]?[ \t]*'
    '$_dc{1,9})[ \\t]*\\([ \\t]*)($_name)(?=[ \\t]*\\))',
    caseSensitive: false,
    unicode: true,
  );

  // Names with no cue, unless the text reads as a purchase: the name that
  // opens a sentence before a transfer verb aimed at the user ("Sara Ali sent
  // you SAR 500"), the Arabic verb-first forms («أرسل لك محمد أحمد», «قام محمد
  // أحمد بتحويل») and a full name right after the transfer word before the
  // amount ("Transfer Sara Ali SAR 500", «حوالة محمد أحمد 500 ريال»). The
  // Latin forms take only capitalised words ([maskCapitalisedName]). Server
  // twins: NAME_BEFORE_VERB_PATTERN, NAME_AFTER_VERB_AR_PATTERN,
  // NAME_AFTER_TRANSFER_PATTERN.
  static final _nameBeforeVerb = RegExp(
    r'((?:^|(?<=[\n.!?؟;؛:]))[ \t]*)'
    '($_name)'
    r'(?=[ \t]+(?:has[ \t]+|have[ \t]+)?(?:sent|transferred|paid|remitted)[ \t]+'
    r'(?:you(?![\p{L}\p{M}])|(?:[^.\n]|\.(?=[0-9٠-٩۰-۹])){0,30}?(?<![\p{L}\p{M}])(?:to|into)[ \t]+you))',
    caseSensitive: false,
    unicode: true,
  );
  static final _nameAfterVerbAr = RegExp(
    r'((?<![\p{L}\p{M}])(?:(?:أرسل|ارسل|حول|حوّل|أودع|اودع)ت?[ \t]+(?:لك|إليك|اليك)|قام|قامت)[ \t]+)'
    '($_name)',
    caseSensitive: false,
    unicode: true,
  );
  static final _nameAfterTransfer = RegExp(
    r'((?<![\p{L}\p{M}])(?:transfer|transferred|remittance|حوالة|حواله|تحويل)(?![\p{L}\p{M}])(?:[ \t]*[:\-][ \t]*|[ \t]+))'
    '($_nameToken(?:[ \\t]+$_nameToken){1,5})'
    '(?=[ \\t]*(?:[\\-,،]|$_dc|\$|\\n|(?:${_currencyAfter.join('|')})(?![\\p{L}\\p{M}])))',
    caseSensitive: false,
    unicode: true,
  );

  // SP-16: "Payment of SAR 99 to Omar Farooq via Mada" — the payee of a
  // payment, unless the text reads as a purchase. Capitalised words only, so
  // "payment to STC did not go through" keeps what happened. Server twin:
  // PAYMENT_TO_PATTERN.
  static final _paymentTo = RegExp(
    r'((?<![\p{L}\p{M}])(?:payment|payments|paid|pay)(?![\p{L}\p{M}])(?:[^.\n;؛!?؟]|\.(?=[0-9٠-٩۰-۹])){0,40}?(?<![\p{L}\p{M}])to[ \t]+)'
    '($_name)',
    caseSensitive: false,
    unicode: true,
  );
  // The leading words of a match that can be a name in Latin script: each
  // starts with a capital (or is Arabic, or star-masked).
  static final _capitalisedRun = RegExp(
    r'^[\p{Lu}\p{Lo}*][^ \t]*(?:[ \t]+[\p{Lu}\p{Lo}*][^ \t]*)*',
    unicode: true,
  );

  // The text reads as money moving between people. Server twin:
  // TRANSFER_WORDS.
  static final _transferContext = RegExp(
    r'transfer|remit|received|credited|deposit|\bipn\b|instapay|beneficiary|'
    r'\bsent\b|حوال|تحويل|حول|وارد|استلام|استلمت|إيداع|ايداع|أودع|اودع|'
    r'مستفيد|المرسل|انستا|لصالح|standing\s+order|أمر\s+(?:مستديم|دائم)|'
    r'امر\s+(?:مستديم|دائم)',
    caseSensitive: false,
    unicode: true,
  );
  static final _purchaseContext = RegExp(
    r'purchase|\bpos\b|point of sale|paid at|spent|refund|revers|e-?commerce|'
    r'\bbill|merchant|شراء|مشتريات|نقاط البيع|نقطة بيع|نقاط بيع|استرداد|مسترد|'
    r'مرتجع|إرجاع|ارجاع|فاتور|سداد|تاجر',
    caseSensitive: false,
    unicode: true,
  );

  /// A business, by the words a business name carries (a shop, company or
  /// service marker), never by a list of specific names. A counterparty whose
  /// name carries one is a merchant and is kept, whatever the cue. Server
  /// twin: COMPANY_MARKERS.
  static const List<String> companyMarkers = [
    'shop', 'shops', 'store', 'stores', 'bookstore', 'market', 'markets',
    'supermarket', 'hypermarket', 'mart', 'mall', 'cafe', 'café', 'coffee',
    'restaurant', 'restaurants', 'kitchen', 'bakery', 'pharmacy', 'pharmacies',
    'clinic', 'clinics', 'hospital', 'company', 'co', 'corp', 'corporation',
    'ltd', 'llc', 'inc', 'est', 'establishment', 'trading', 'group', 'holding',
    'services', 'solutions', 'hotel', 'hotels', 'station', 'petrol', 'fuel',
    'telecom', 'electricity', 'water', 'insurance', 'school', 'university',
    'academy', 'airlines', 'airways', 'pay', 'com', 'net',
    'شركة', 'شركه', 'مؤسسة', 'مؤسسه', 'مكتبة', 'مكتبه', 'متجر', 'متاجر', 'محل',
    'محلات', 'مطعم', 'مطاعم', 'مقهى', 'كافيه', 'كوفي', 'صيدلية', 'صيدليات',
    'مستشفى', 'عيادة', 'عيادات', 'فندق', 'سوبرماركت', 'هايبر', 'هايبرماركت',
    'أسواق', 'اسواق', 'سوق', 'مركز', 'محطة', 'مخبز', 'مخابز', 'بقالة', 'تموينات',
    'للتجارة', 'التجارية', 'للخدمات', 'مدرسة', 'جامعة', 'الكهرباء', 'المياه',
    'الاتصالات', 'للاتصالات', 'للتأمين',
  ];
  static final _companyMarker = RegExp(
    '(?<![\\p{L}\\p{M}])(?:${companyMarkers.join('|')})(?![\\p{L}\\p{M}])',
    caseSensitive: false,
    unicode: true,
  );

  // ── Account and card suffixes ────────────────────────────────────────────
  //
  // THE RULE is stated once, in `supabase/functions/_shared/sms_redaction.ts`
  // ("Account and card suffixes"): a number of 1-4 digits after an account,
  // card or wallet label is kept only when the text marks it as the user's
  // own; a third party's suffix and any labelled number of 5 or more digits
  // are masked. [scanSuffixes] applies it in the same order as the server.
  static const List<String> suffixLabels = [
    'account', 'acct', 'acc', r'a\/c', 'ac', 'card', 'wallet', 'mada', 'visa',
    'mastercard', r'apple[ \t]+pay',
    'حساب', 'الحساب', 'لحساب', 'للحساب', 'بحساب', 'بالحساب', 'حسابك', 'لحسابك',
    'بحسابك', 'حسابكم', 'لحسابكم', 'حسابي',
    'بطاقة', 'البطاقة', 'ببطاقة', 'بالبطاقة', 'لبطاقة', 'للبطاقة', 'بطاقه',
    'بطاقتك', 'ببطاقتك', 'لبطاقتك', 'بطاقتكم', 'بطاقتي',
    'محفظة', 'المحفظة', 'محفظتك', 'لمحفظتك', 'مدى',
  ];
  static const List<String> thirdPartyWords = [
    'beneficiary', 'benef', 'payee', 'sender', 'recipient', 'receiver',
    'remitter', 'payer',
    'المستفيد', 'مستفيد', 'المرسل', 'المستلم', 'المحول',
  ];
  static final String _suffixNumberEnd =
      '(?!$_dc|[.,٫٬/:]$_dc|[ \\t]*(?:${_currencyAfter.join('|')})(?![\\p{L}\\p{M}])(?![ \\t]*$_dc))';
  static final _labelledSuffix = RegExp(
    r'((?<![\p{L}\p{M}])(?:(?:your|my)[ \t]+)?(?:(?:debit|credit|prepaid|mada|visa|mastercard|current|savings|bank|corporate|business|personal|joint|main|primary|'
    '${thirdPartyWords.sublist(0, 8).join('|')}'
    r')[ \t]+)*'
    '(?:${suffixLabels.join('|')})'
    r'(?![\p{L}\p{M}])'
    r'(?:[ \t]+(?:ending|ends|in|with|no\.?|number|num|رقم|برقم|المنتهية|منتهية|تنتهي|بـ|ب|مدى|mada|visa|mastercard|الائتمانية|ائتمانية|الجديدة|الجديد|'
    '${thirdPartyWords.join('|')}'
    r')(?![\p{L}\p{M}]))*[ \t]*[:#]?[ \t]*)'
    '([*xX•#]*$_dc{1,9}[*•]*)$_suffixNumberEnd',
    caseSensitive: false,
    unicode: true,
  );
  static final _maskedSuffix = RegExp(
    r'(?<![A-Za-z0-9٠-٩۰-۹*•.,٫٬/:\-])()'
    '((?:[*•]+|[xX]{2,})[*xX•]*$_dc{1,9}[*•]*|$_dc{1,9}[*•]+)$_suffixNumberEnd',
    unicode: true,
  );
  static const String _l = r'[\p{L}\p{M}]';
  static const String _open = r'[ \t]*:?[ \t]*(?:(?:the|a|an)[ \t]+)?$';
  static RegExp _ci(String source) =>
      RegExp(source, caseSensitive: false, unicode: true);
  static final _thirdPartyWord =
      _ci('(?<!$_l)(?:${thirdPartyWords.join('|')})(?!$_l)');
  static final _thirdPartyBefore = _ci(
      '(?:\\[NAME\\]|\\[REDACTED\\]|(?<!$_l)(?:${thirdPartyWords.join('|')})(?!$_l))(?:[\'’]s)?$_open');
  static final _possessive = _ci(
      '(?<!$_l)(?:your|my|حسابك|لحسابك|بحسابك|حسابكم|لحسابكم|حسابي|بطاقتك|ببطاقتك|لبطاقتك|بطاقتكم|بطاقتي|محفظتك|لمحفظتك)(?!$_l)');
  static final _possessiveBefore = _ci('(?<!$_l)(?:your|my)[ \\t]+\$');
  static final _destinationBefore =
      _ci('(?<!$_l)(?:to|into|in|إلى|الى|الي|في)(?!$_l)$_open');
  static final _destinationLabel =
      RegExp('^(?:لحساب|للحساب|لبطاقة|للبطاقة)(?!$_l)', unicode: true);
  static final _creditVerbBefore = _ci(
      '(?<!$_l)(?:credited|deposited|refunded|refund|reversal|added|received|returned|arrived|posted|applied|charged|billed|[وف]?(?:إيداع|ايداع|أودع|اودع|أضيف|اضيف|إضاف|اضاف)$_l*|استرداد|استرجاع|واردة|وارده|وارد)(?!$_l)(?:[^.\\n;؛!?؟]|\\.(?=$_dc)){0,60}\$');
  static final _outgoingWords = _ci(
      '(?<!$_l)(?:transferred|sent|paid|دفع|صادرة|صادره|صادر|حولت|أرسلت|ارسلت)(?!$_l)');
  static final _incomingWords = _ci(
      'received|credited|deposit|incoming|refund|وارد|استلام|استلمت|إيداع|ايداع|أودع|اودع|أضيف|اضيف|إضافة|اضافة');
  static final _fromBefore = _ci('(?<!$_l)(?:from|من)(?!$_l)$_open');
  // A debit verb before "from" makes it the user's side even when the text
  // also credits something ("debited from account … and credited to …").
  static final _debitVerbBefore = _ci(
      '(?<!$_l)(?:debited|deducted|withdrawn|[وف]?(?:خصم|سحب)$_l*)(?!$_l)(?:[^.\\n;؛!?؟]|\\.(?=$_dc)){0,60}\$');
  static final _instrumentBefore = _ci(
      '(?<!$_l)(?:with|using|via|by|through|عبر|باستخدام|بواسطة)(?!$_l)$_open');
  static final _instrumentLabel =
      RegExp('^(?:بحساب|بالحساب)(?!$_l)', unicode: true);
  static final _cardLabel = _ci(
      '(?<!$_l)(?:card|mada|visa|mastercard|apple[ \\t]+pay|بطاقة|البطاقة|ببطاقة|بالبطاقة|لبطاقة|للبطاقة|بطاقه|مدى)(?!$_l)');
  static final _paymentWords = _ci(r'payment|\bpaid\b|\bpay\b|دفع');
  static final _maskedPerson = RegExp(r'\[NAME\]|\[REDACTED\]');
  static final _nameInParensAfter = RegExp(r'^[ \t]*\([ \t]*\[NAME\]');
  static final _digit = RegExp(_dc);

  /// Every labelled or star-masked short number in [text] with the rule's
  /// verdict, in text order. `start`/`end` bound the number (stars included).
  /// Server twin: scanSuffixes.
  static List<({int start, int end, bool card, bool own})> scanSuffixes(
      String text,
      {required bool purchase}) {
    final found = <({int start, int end, bool card, bool own})>[];
    final incoming = _incomingWords.hasMatch(text);
    final outgoing = _outgoingWords.hasMatch(text);
    final alone = !_transferContext.hasMatch(text) &&
        !_paymentWords.hasMatch(text) &&
        !_maskedPerson.hasMatch(text);
    void scan(RegExp pattern, bool labelled) {
      for (final m in pattern.allMatches(text)) {
        final phrase = m.group(1)!;
        final start = m.start + phrase.length;
        final end = m.end;
        if (found.any((f) => f.start == start)) continue;
        final before =
            text.substring(m.start - 80 < 0 ? 0 : m.start - 80, m.start);
        final card = _cardLabel.hasMatch(phrase);
        final from = _fromBefore.hasMatch(before);
        // "from" in an incoming message is the sender's side, unless a debit
        // verb governs it.
        final sender = incoming && from && !_debitVerbBefore.hasMatch(before);
        bool own;
        if (_digit.allMatches(m.group(2)!).length > 4) {
          own = false;
        } else if (_thirdPartyWord.hasMatch(phrase) ||
            _thirdPartyBefore.hasMatch(before) ||
            _nameInParensAfter.hasMatch(text.substring(end))) {
          own = false;
        } else if (_possessive.hasMatch(phrase) ||
            _possessiveBefore.hasMatch(before)) {
          own = true;
        } else if (_destinationBefore.hasMatch(before) ||
            _destinationLabel.hasMatch(phrase)) {
          own = _creditVerbBefore.hasMatch(before) && !outgoing;
        } else if (card || purchase) {
          own = !sender;
        } else {
          final instrument = labelled &&
              !incoming &&
              (_instrumentBefore.hasMatch(before) ||
                  _instrumentLabel.hasMatch(phrase));
          own = (labelled && alone) || (from ? !sender : instrument);
        }
        found.add((start: start, end: end, card: card, own: own));
      }
    }

    scan(_labelledSuffix, true);
    scan(_maskedSuffix, false);
    found.sort((a, b) => a.start.compareTo(b.start));
    return found;
  }

  /// True when the text reads as a purchase, refund or bill, or as a card
  /// payment: it names the user's own card and has no transfer word. The
  /// counterparty of such a message is a merchant (MASK-1). Server twin:
  /// isMerchantContext.
  static bool isMerchantContext(String text) =>
      _purchaseContext.hasMatch(text) ||
      (!_transferContext.hasMatch(text) &&
          scanSuffixes(text, purchase: false).any((s) => s.card && s.own));

  /// True when [text] carries a transfer or credit word.
  static bool hasTransferWord(String text) => _transferContext.hasMatch(text);

  // After the bare prepositions "to" and "by" a single lower-case Latin word
  // is a verb or a common word, not a name ("Use the code to confirm your
  // transfer", "by clicking"): a one-word name there starts with a capital, a
  // star or a non-Latin letter. Two or more words are still a name, and a
  // field label ("To:") is not bare. Server twins: BARE_PREPOSITION,
  // ORDINARY_WORD.
  static final _barePreposition = _ci(r'(?<![\p{L}\p{M}])(?:to|by)[ \t]+$');
  static final _ordinaryWord = RegExp(r'^\p{Ll}[^ \t]*$', unicode: true);

  /// The cue and `[NAME]`, or the match unchanged when the name is a
  /// business's or (after a bare preposition) an ordinary word. Server twin:
  /// maskName.
  static String maskName(Match m) => _companyMarker.hasMatch(m.group(2)!) ||
          (_barePreposition.hasMatch(m.group(1)!) &&
              _ordinaryWord.hasMatch(m.group(2)!))
      ? m.group(0)!
      : '${m.group(1)!}[NAME]';

  /// As [maskName], for the Latin forms that have no cue of their own: only
  /// the leading capitalised words are the name, and what follows them stays.
  /// Server twin: maskCapitalisedName.
  static String maskCapitalisedName(Match m) {
    final name = m.group(2)!;
    final run = _capitalisedRun.firstMatch(name)?.group(0);
    return run == null || _companyMarker.hasMatch(run)
        ? m.group(0)!
        : '${m.group(1)!}[NAME]${name.substring(run.length)}';
  }

  // MASK-0: the run after «إلى»/"To:" is a merchant, and stays, when the text
  // reads as a purchase or the run carries a business marker — unless the run
  // is an account or card object, or carries a number or a masked name (then
  // it is a person's account whatever the message says). Server twin:
  // keepsBeneficiary.
  static final _beneficiaryCue =
      _ci(r'^(?:إلى|الى|to(?:[ \t]+name)?)\s*:?\s*');
  static final _beneficiaryAccountObject = _ci(
      '(?<!$_l)(?:account|accounts|acct|acc|ac|wallet|mobile|phone|number|no|name|حساب|الحساب|حسابات|لحساب|للحساب|محفظة|المحفظة|رقم)(?!$_l)'
      '|^(?:(?:the|a|an)[ \\t]+)?(?:card|cards|بطاقة|البطاقة|بطاقه)(?!$_l)'
      '|\\[(?:NAME|ACCOUNT|IBAN|CARD|PHONE|REF)\\]|^[*xX•#]*$_dc|$_dc{5}|[A-Z]{2}$_dc{2}');
  static bool keepsBeneficiary(String match, {required bool merchantContext}) {
    final run = match.replaceFirst(_beneficiaryCue, '');
    return !_beneficiaryAccountObject.hasMatch(run) &&
        (merchantContext || _companyMarker.hasMatch(run));
  }

  /// True when [text] carries an identifier the PII floor would mask: an
  /// e-mail, a card, phone, IBAN, account or cue-anchored reference number.
  /// Used to refuse sending such a string anywhere as a "merchant".
  static bool containsIdentifier(String text) =>
      _email.hasMatch(text) ||
      _cardNumber.hasMatch(text) ||
      _saudiPhone.hasMatch(text) ||
      _egyptPhone.hasMatch(text) ||
      _intlPhone.hasMatch(text) ||
      _iban.hasMatch(text) ||
      _reference.hasMatch(text) ||
      _accountNumber.hasMatch(text);

  static final _word = RegExp(r'[\p{L}\p{M}]{2,}', unicode: true);

  /// True when redaction removes any word of [merchant] from [message]: the
  /// "merchant" a parser read there is (or contains) a person's name or
  /// another masked value, so it must not be sent anywhere as a merchant
  /// (shared learning, enrichment).
  static bool masksPartOf(String message, String merchant) {
    final kept = sanitize(message).toUpperCase();
    final original = message.toUpperCase();
    return _word.allMatches(merchant.toUpperCase()).map((m) => m.group(0)!).any(
        (word) => original.contains(word) && !kept.contains(word));
  }

  /// True when a `from` / `to` / `من` / `إلى` counterparty is a person rather
  /// than a merchant: the text reads as a transfer or credit and NOT as a
  /// purchase, refund or bill payment. Decided from the text alone (never from
  /// a parser type) so the device and the server reach the same answer.
  static bool isCounterpartyContext(String text) =>
      _transferContext.hasMatch(text) && !_purchaseContext.hasMatch(text);

  // ── Read-only pattern accessors ──────────────────────────────────────────
  // Exposed so `sanitization_edit_map.dart` can run the SAME passes in the
  // SAME order and record where every character went. Sharing the patterns is
  // what makes the edit map's output byte-identical to [sanitize] by
  // construction rather than by a second implementation that could drift.
  static RegExp get cardNumberPattern => _cardNumber;
  static RegExp get saudiPhonePattern => _saudiPhone;
  static RegExp get egyptPhonePattern => _egyptPhone;
  static RegExp get intlPhonePattern => _intlPhone;
  static RegExp get ibanPattern => _iban;
  static RegExp get otpPattern => _otp;
  static RegExp get accountNumberPattern => _accountNumber;
  static RegExp get spacedIbanPattern => _spacedIban;
  static RegExp get labelledAccountPattern => _labelledAccount;
  static RegExp get beneficiaryArPattern => _beneficiaryAr;
  static RegExp get beneficiaryEnPattern => _beneficiaryEn;
  static RegExp get ownDestinationNumberPattern => _ownDestinationNumber;
  static RegExp get numberInBeneficiarySentencePattern =>
      _numberInBeneficiarySentence;
  static RegExp get greetingPattern => _greeting;
  static RegExp get emailPattern => _email;
  static RegExp get referencePattern => _reference;
  static RegExp get salutationPattern => _salutation;
  static RegExp get counterpartyPattern => _counterparty;
  static RegExp get personCuePattern => _personCue;
  static RegExp get labelCuePattern => _labelCue;
  static RegExp get toHeadingPattern => _toHeading;
  static RegExp get personalLabelPattern => _personalLabel;
  static RegExp get accountOfPattern => _accountOf;
  static RegExp get parenNamePattern => _parenName;
  static RegExp get paymentToPattern => _paymentTo;
  static RegExp get nameBeforeVerbPattern => _nameBeforeVerb;
  static RegExp get nameAfterVerbArPattern => _nameAfterVerbAr;
  static RegExp get nameAfterTransferPattern => _nameAfterTransfer;
  static bool isPurchaseContext(String text) => _purchaseContext.hasMatch(text);

  /// Returns a sanitized copy of [rawSms] safe for sending to an AI service.
  ///
  /// [detectedType] is accepted for the callers that pass it and is NOT
  /// used: person or merchant is decided from the text alone, so the device,
  /// the Shortcut and the server give the same output (a `payment` hint used
  /// to keep «إلى حساب <name>»).
  static String sanitize(String rawSms, {TransactionType? detectedType}) {
    var text = rawSms;

    // 0. E-mail addresses (before the phone rule can split a local part)
    text = text.replaceAll(_email, '[EMAIL]');

    // 0a. IBANs written in groups (before the card rule eats their middle)
    text = text.replaceAll(_spacedIban, '[IBAN]');

    // 1. Full card numbers (before broad account pattern to avoid overlap)
    text = text.replaceAll(_cardNumber, '[CARD]');

    // 2. Phone numbers (before broad account pattern to avoid overlap)
    text = text.replaceAll(_saudiPhone, '[PHONE]');
    text = text.replaceAll(_egyptPhone, '[PHONE]');
    text = text.replaceAll(_intlPhone, '[PHONE]');

    // 3. IBANs (alphanumeric, so the digit rule below cannot catch them)
    text = text.replaceAll(_iban, '[IBAN]');

    // 4. One-time passcodes, cue-anchored so amounts are never destroyed
    text = text.replaceAllMapped(_otp, (m) => '${m.group(1)!}[OTP]');
    for (final (pattern, mode) in otpRules) {
      final current = text;
      text = text.replaceAllMapped(
          pattern, (m) => codeReplacement(current, m, mode));
    }

    // 5. Long digit sequences not already replaced (account substrings)
    text = text.replaceAll(_accountNumber, '[ACCOUNT]');
    text = text.replaceAllMapped(
        _labelledAccount, (m) => '${m.group(1)!}[ACCOUNT]');

    // 5a. Shorter reference numbers, cue-anchored (10+ digits are already
    // [ACCOUNT] above)
    text = text.replaceAllMapped(_reference, (m) => '${m.group(1)!}[REF]');

    // 5b. Personal names: salutations and person-only cues always;
    // counterparties only when the text reads as a transfer/credit; payees
    // and names with no cue unless it reads as a purchase. Text-based, never
    // [detectedType]-based, so the server and the Shortcut agree. Runs before
    // step 7 so a multi-word name after عزيزي is masked in full.
    text = text.replaceAllMapped(_salutation, (m) => '${m.group(1)!}[NAME]');
    // PRIV-1: a person cue names a person in any message.
    text = text.replaceAllMapped(_personCue, maskName);
    text = text.replaceAllMapped(_personalLabel, maskName);
    text = text.replaceAllMapped(_accountOf, maskName);
    if (!isMerchantContext(text)) {
      if (_transferContext.hasMatch(text)) {
        text = text.replaceAllMapped(_counterparty, maskName);
      } else {
        // PRIV-1: with no purchase, refund, bill or card-payment reading, a
        // "From:" label, "paid to" and a "To <Name>:" heading name a person.
        text = text.replaceAllMapped(_labelCue, maskName);
        text = text.replaceAllMapped(_toHeading, maskName);
        text = text.replaceAllMapped(_paymentTo, maskCapitalisedName);
      }
      text = text.replaceAllMapped(_parenName, maskName);
      text = text.replaceAllMapped(_nameBeforeVerb, maskCapitalisedName);
      text = text.replaceAllMapped(_nameAfterVerbAr, maskName);
      text = text.replaceAllMapped(_nameAfterTransfer, maskCapitalisedName);
    }

    // 6. The beneficiary after «إلى»/"To:" — kept only when it is a merchant
    // ([keepsBeneficiary]).
    final merchantContext = isMerchantContext(text);
    text = text.replaceAllMapped(
        _beneficiaryAr,
        (m) => keepsBeneficiary(m.group(0)!, merchantContext: merchantContext)
            ? m.group(0)!
            : '${m.group(1)!}: [REDACTED]');
    text = text.replaceAllMapped(
        _beneficiaryEn,
        (m) => keepsBeneficiary(m.group(0)!, merchantContext: merchantContext)
            ? m.group(0)!
            : 'To: [REDACTED]');
    text = text.replaceAllMapped(
        _ownDestinationNumber, (m) => '${m.group(1)!}[ACCOUNT]');

    // 6a. Account and card suffixes the text does not mark as the user's own
    // (THE RULE above).
    final purchase = _purchaseContext.hasMatch(text);
    for (final s in scanSuffixes(text, purchase: purchase).reversed) {
      if (!s.own) text = text.replaceRange(s.start, s.end, '[ACCOUNT]');
    }
    final own = {
      for (final s in scanSuffixes(text, purchase: purchase))
        if (s.own) s.start
    };
    text = text.replaceAllMapped(_numberInBeneficiarySentence,
        (m) => own.contains(m.start) ? m.group(0)! : '[ACCOUNT]');

    // 7. Arabic greetings that include a personal name
    text = text.replaceAll(_greeting, '[REDACTED]');

    return text.trim();
  }
}
