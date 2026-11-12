import '../models/transaction_type.dart';

/// Sanitizes a raw bank SMS before sending to any off-device AI service.
///
/// The sanitized string is for AI consumption ONLY. The raw SMS is always
/// stored locally and fed to the rule-based parser unchanged.
///
/// Strip order matters — phone patterns must run before the broad
/// account-number pattern so phone digits are not double-redacted.
///
/// Transfer vs purchase distinction (owner decision 2026-06-16):
/// - [TransactionType.payment] / POS: merchant name is kept. AI needs it to
///   categorize the transaction (merchant = business entity, not PII).
/// - [TransactionType.transfer] / unknown: beneficiary content after إلى: / To:
///   is STRIPPED. The beneficiary is a real person's name — third-party PII
///   that must never leave the device.
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

  // ── Account numbers ───────────────────────────────────────────────────────
  // Any 10–20 consecutive digits that were NOT already replaced by the phone
  // or card patterns above. Amounts are ≤ 9 digits without a currency context;
  // real account numbers are 10+.
  static final _accountNumber = RegExp('$_nb$_dc{10,20}$_nbEnd');

  // ── Beneficiary / transfer recipient ─────────────────────────────────────
  // Captures everything after إلى: / الى: / To: to end of line.
  // Applied only when stripping is required (see [sanitize]).
  static final _beneficiaryAr = RegExp(
    r'(إلى|الى)\s*:?\s*.+',
    caseSensitive: false,
  );
  static final _beneficiaryEn = RegExp(
    r'\bTo\s*:\s*.+',
    caseSensitive: false,
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
    'accounts', 'acct', 'ac', 'card', 'cards', 'wallet', 'mobile', 'phone',
    'number', 'no', 'on', 'at', 'in', 'into', 'via', 'using', 'with', 'for',
    'of', 'to', 'from', 'by', 'ref', 'reference', 'rrn', 'amount', 'amt',
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
  ];

  static final String _nameToken =
      "(?!(?:${nameStopwords.join('|')})(?![\\p{L}\\p{M}*'’\\-]|\\.[\\p{L}\\p{M}]))"
      "[\\p{L}\\p{M}*][\\p{L}\\p{M}*.'’\\-]*";
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
    r'((?<![\p{L}\p{M}])(?:from|to|by|beneficiary(?:[ \t]+name)?|'
    r'sender(?:[ \t]+name)?|remitter(?:[ \t]+name)?|'
    r'recipient(?:[ \t]+name)?|payer(?:[ \t]+name)?|on[ \t]+behalf[ \t]+of|'
    r'in[ \t]+favou?r[ \t]+of|mrs|mr|ms|dr|من[ \t]+قبل|اسم[ \t]+المستفيد|'
    r'اسم[ \t]+المرسل|المستفيد|المرسل|المحول|لصالح|باسم|بواسطة|من|إلى|الى|'
    r'الي)'
    '\\.?(?![\\p{L}\\p{M}])$_cueSep)($_name)',
    caseSensitive: false,
    unicode: true,
  );

  static final _transferContext = RegExp(
    r'transfer|remit|received|credited|deposit|\bipn\b|instapay|beneficiary|'
    r'\bsent\b|حوال|تحويل|حول|وارد|استلام|استلمت|إيداع|ايداع|أودع|اودع|'
    r'مستفيد|المرسل|انستا|لصالح',
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
  static RegExp get beneficiaryArPattern => _beneficiaryAr;
  static RegExp get beneficiaryEnPattern => _beneficiaryEn;
  static RegExp get greetingPattern => _greeting;
  static RegExp get emailPattern => _email;
  static RegExp get referencePattern => _reference;
  static RegExp get salutationPattern => _salutation;
  static RegExp get counterpartyPattern => _counterparty;

  /// Returns a sanitized copy of [rawSms] safe for sending to an AI service.
  ///
  /// [detectedType] is the type detected by the rule-based parser before
  /// falling through to AI, or null if the parser produced no result:
  ///
  /// - `payment` → keep `إلى:` / `To:` content (it is a business merchant name,
  ///   not a person; AI needs it for categorization).
  /// - `transfer`, `income`, or `null` (unknown) → strip beneficiary / sender
  ///   names entirely. Better to over-redact an unknown message than leak a
  ///   third party's identity.
  /// - `withdrawal` → nothing extra to strip (ATM, no counterparty name).
  static String sanitize(String rawSms, {TransactionType? detectedType}) {
    var text = rawSms;

    // 0. E-mail addresses (before the phone rule can split a local part)
    text = text.replaceAll(_email, '[EMAIL]');

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

    // 5. Long digit sequences not already replaced (account substrings)
    text = text.replaceAll(_accountNumber, '[ACCOUNT]');

    // 5a. Shorter reference numbers, cue-anchored (10+ digits are already
    // [ACCOUNT] above)
    text = text.replaceAllMapped(_reference, (m) => '${m.group(1)!}[REF]');

    // 5b. Personal names: salutations always; counterparties only when the
    // text reads as a transfer/credit and not as a purchase. Text-based, not
    // [detectedType]-based, so the server's copy of this rule agrees. Runs
    // before step 7 so a multi-word name after عزيزي is masked in full.
    text = text.replaceAllMapped(_salutation, (m) => '${m.group(1)!}[NAME]');
    if (isCounterpartyContext(text)) {
      text =
          text.replaceAllMapped(_counterparty, (m) => '${m.group(1)!}[NAME]');
    }

    // 6. Beneficiary / recipient names for non-purchase types
    final stripBeneficiary = detectedType == null ||
        detectedType == TransactionType.transfer ||
        detectedType == TransactionType.income;

    if (stripBeneficiary) {
      text = text.replaceAllMapped(
          _beneficiaryAr, (m) => '${m.group(1)!}: [REDACTED]');
      text = text.replaceAll(_beneficiaryEn, 'To: [REDACTED]');
    }

    // 7. Arabic greetings that include a personal name
    text = text.replaceAll(_greeting, '[REDACTED]');

    return text.trim();
  }
}
