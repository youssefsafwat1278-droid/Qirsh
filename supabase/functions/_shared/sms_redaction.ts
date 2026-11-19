/// The PII floor every path that sends SMS text off-device must apply.
///
/// This exists because three server functions each carried their own copy of
/// `reSanitize`, and two of them — `process-ios-sms` and `bank-discovery`,
/// both of which forward the text to Gemini — were missing the IBAN and OTP
/// rules that `parse-sms` and the Dart client sanitizer have. A full Saudi
/// IBAN therefore reached the model untouched: the digits-only account rule
/// cannot match it, because there is no word boundary between `SA` and the
/// digits that follow.
///
/// Callers may add rules on top (beneficiary stripping, bank-specific account
/// cues); they may not subtract. Keep in lockstep with
/// `app/lib/engine/privacy/sms_sanitizer.dart` and
/// `app/ios/BankMessageShortcuts/BankMessageShortcuts.swift`.

/// Every digit shape this market actually sends: Latin, Arabic-Indic
/// (U+0660-0669) and extended Arabic-Indic (U+06F0-06F9).
///
/// The patterns below used ASCII `\d`, so a card, IBAN or account number
/// written in Arabic-Indic digits was forwarded to the model untouched. The
/// digits are matched in place rather than normalised away: the proof layer
/// compares model output against spans of the very string that was sent.
const D = '[0-9\u0660-\u0669\u06F0-\u06F9]';

/// `\b` is defined over [A-Za-z0-9_] alone and does not treat U+0660 as a word
/// character, so against an Arabic-Indic run it puts a "boundary" mid-digits
/// and matches a fragment. These are that assertion widened; on ASCII input
/// they are exactly equivalent to `\b`.
const NB = '(?<![0-9\u0660-\u0669\u06F0-\u06F9A-Za-z_])';
const NB_END = '(?![0-9\u0660-\u0669\u06F0-\u06F9A-Za-z_])';

/// ISO 13616. Alphanumeric, so the digits-only account rule can never catch
/// it. The country code is matched case-insensitively, because
/// `sa0380000000608010167519` is the same identifier as the upper-case form
/// and used to pass straight through.
///
/// Deliberately NOT global: this one is for `.test()` in fail-closed checks,
/// and a /g regex carries `lastIndex` between calls, so it would alternate
/// true/false on the same input.
export const IBAN_DETECT_PATTERN = new RegExp(
  `${NB}[A-Za-z]{2}${D}{2}[A-Za-z0-9\u0660-\u0669\u06F0-\u06F9]{11,30}${NB_END}`,
);

/// CUE-ANCHORED on purpose. A bare 4-8 digit run is far more often an amount
/// than a passcode, so redacting by shape alone would destroy the value the
/// proof layer exists to establish. The cue is kept so the message stays
/// classifiable as an OTP.
// Not exported: /g carries `lastIndex`, so it is safe with `.replace()` here
// and unsafe with `.test()` anywhere else.
const OTP_PATTERN = new RegExp(
  `((?:otp|one[- ]?time(?:\\s+password)?|verification\\s+code|رمز\\s+التحقق|كود\\s+التحقق|رمز\\s+الدخول)(?:\\s+(?:is|هو))?\\s*:?\\s*)${D}{4,8}`,
  'gi',
);

/// Round 4 (real-model run): a one-time code must never leave the device,
/// whatever the cue wording and on whichever side of the code the cue sits.
/// Still cue-anchored: a figure next to a currency, a decimal or grouped
/// figure, a date or time, and a card or account suffix are never a code, so
/// an amount of the same length survives ("is 482913 SAR").
const OTP_CURRENCY =
  'sar|egp|aed|usd|eur|gbp|kwd|qar|bhd|omr|jod|le|sr|riyals?|pounds?|dirhams?|dinars?|dollars?|ريال|جنيه|جم|درهم|دينار|دولار|يورو|ر\\.س';
// A purchase's approval, reference or promo code is not a one-time code.
const OTP_NOT_A_CODE =
  'approval|auth|authorization|authorisation|reference|transaction|receipt|pickup|promo|discount|coupon|voucher|order|branch|swift|bank|area|postal';
const OTP_CUE = `(?:otp|one[- ]?time[ \\t]+(?:password|passcode|pin|code)|pin|tac|mtoken|token|secure[ \\t]+code` +
  // "Your authorization code is …" is a verification code; "Authorization code
  // 771234" after a purchase is the approval.
  `|(?<=your[ \\t])(?:authorization|authorisation|auth|approval)[ \\t]+code` +
  `|(?:verification|security|activation|confirmation|authentication|access|login|secret)[ \\t]+code` +
  `|passcode|password|(?<!(?:${OTP_NOT_A_CODE})[ \\t])code|كلمة[ \\t]+المرور(?:[ \\t]+لمرة[ \\t]+واحدة)?|كلمة[ \\t]+السر` +
  `|(?:رمز|كود)[ \\t]+(?:التحقق|الدخول|التفعيل|الأمان|الامان|التأكيد|التاكيد)|الرمز[ \\t]+السري|رمز[ \\t]+سري|الرقم[ \\t]+السري` +
  `|رمزك|الرمز|رمز|كودك|الكود|كود)`;
const OTP_NUMBER = `(?<![0-9\u0660-\u0669\u06F0-\u06F9*•#]|${D}[.,\u066B\u066C/:\\-]|(?<![\\p{L}\\p{M}])(?:${OTP_CURRENCY})[ \\t]{0,3}` +
  `|(?<![\\p{L}\\p{M}])(?:card|account|acct|ending|بطاقة|البطاقة|حساب|الحساب)[ \\t]{1,3})` +
  // Four to eight digits, also written "482-913" or "4 8 2 9 1 3". A currency
  // after it makes it an amount, unless another figure follows the currency
  // ("code is 482913 SAR 250.00").
  `(?:${D}{4,8}|${D}{3}[\\- ]${D}{3}|${D}(?:[ ]${D}){3,7})` +
  `(?!${D}|[.,\u066B\u066C/:\\-]${D}|[ \\t]*(?:${OTP_CURRENCY})(?![\\p{L}\\p{M}])(?![ \\t]*${D}))`;
/// Words that may sit between the cue and the code («كلمة المرور المؤقتة 4829»,
/// «الرقم السري لمرة واحدة 482913», «الرمز التالي 482913»).
const OTP_QUALIFIER =
  `(?:[ \\t]+(?:المؤقتة|المؤقت|مؤقتة|مؤقت|لمرة[ \\t]+واحدة|التالي|التالية|الخاص[ \\t]+بك|الخاصة[ \\t]+بك|الجديد|الجديدة|below|following)(?![\\p{L}\\p{M}]))*`;
/// Each rule keeps its group 1 and masks the code after it. `cue` rules carry
/// the cue word in group 2; a `weak` rule has no verification wording at all.
const OTP_RULES: [RegExp, 'cue' | 'weak' | 'strong'][] = [
  // First, so the wording decides: a code is what a message says not to
  // share: "… 482913. Do not share it."
  [
    new RegExp(
      `()${OTP_NUMBER}(?=[ \\t]*[.,،;]?\\s*(?:(?:please|الرجاء|يرجى)[ \\t]+)?(?:do[ \\t]+not[ \\t]+share|don['’]?t[ \\t]+share|never[ \\t]+share|لا[ \\t]+تشارك|عدم[ \\t]+مشارك|لا[ \\t]+تفصح))`,
      'giu',
    ),
    'strong',
  ],
  // A code alone on its line, the next line saying what to use it for:
  // "482913\nUse this to log in …".
  [
    new RegExp(
      `((?:^|(?<=\n))[ \t]*)${OTP_NUMBER}(?=[ \t]*[.:]?[ \t]*\n[ \t]*(?:use|enter|استخدم|أدخل|ادخل)(?![\p{L}\p{M}]))`,
      'giu',
    ),
    'strong',
  ],
  // "Never share this: 482913", «لا تشارك هذا الرمز: 482913».
  [
    new RegExp(
      `((?<![\\p{L}\\p{M}])(?:never[ \\t]+share|do[ \\t]+not[ \\t]+share|don['’]?t[ \\t]+share|لا[ \\t]+تشارك[\\p{L}\\p{M}]*)(?:[ \\t]+(?:this|it|the[ \\t]+code|هذا[ \\t]+الرمز|الرمز))?[ \\t]*[:\\-]?[ \\t]*)${OTP_NUMBER}`,
      'giu',
    ),
    'strong',
  ],
  // The cue, an optional "is" / «هو» / "no.", then the code.
  [
    new RegExp(
      `((?<![\\p{L}\\p{M}])(${OTP_CUE})(?![\\p{L}\\p{M}])${OTP_QUALIFIER}(?:[ \\t]*(?:is|are|was|no\\.?|number|هو|هي|رقم)(?![\\p{L}\\p{M}]))?[ \\t]*[:#=\\-]?[ \\t]*)${OTP_NUMBER}`,
      'giu',
    ),
    'cue',
  ],
  // The cue earlier in the sentence, the code right after "is" / «هو».
  [
    new RegExp(
      `((?<![\\p{L}\\p{M}])(${OTP_CUE})(?![\\p{L}\\p{M}])(?:[^\\n.!?؟]|\\.(?=${D})){0,80}?(?<![\\p{L}\\p{M}])(?:is|are|هو|هي)(?![\\p{L}\\p{M}])[ \\t]*:?[ \\t]*)${OTP_NUMBER}`,
      'giu',
    ),
    'cue',
  ],
  // The code first: "482913 is your verification code", «482913 هو رمز التحقق».
  [
    new RegExp(
      `()${OTP_NUMBER}(?=[ \\t]+(?:is|هو|هي)[ \\t]+(?:(?:your|the)[ \\t]+)?(?:[\\p{L}\\p{M}]+[ \\t]+){0,3}?(${OTP_CUE})(?![\\p{L}\\p{M}]))`,
      'giu',
    ),
    'cue',
  ],
  // "Use 482913 to confirm …", «استخدم 482913».
  [
    new RegExp(
      `((?<![\\p{L}\\p{M}])(?:use|enter|type|استخدم|أدخل|ادخل)(?![\\p{L}\\p{M}])[ \\t]+(?:(?:the|this)[ \\t]+)?)${OTP_NUMBER}`,
      'giu',
    ),
    'weak',
  ],
];

/// The bare cues: they also introduce a promo, pickup or receipt code.
const OTP_BARE_CUE = /^(?:code|رمزك|الرمز|رمز|كودك|الكود|كود)$/iu;
const OTP_SENTENCE_END = new RegExp(`[\\n!?؟]|\\.(?!${D})`, 'gu');
const OTP_MONEY = new RegExp(`(?<![\\p{L}\\p{M}])(?:${OTP_CURRENCY})(?![\\p{L}\\p{M}])`, 'iu');

/// The placeholder for a masked code. Under verification wording it is
/// `[OTP]`. Under a bare cue ("code 4829", "Use 4829 …") it is `[OTP]` too,
/// unless an earlier sentence of the message already states an amount: that
/// is a promo, pickup or receipt code after a movement, written `[REF]` so no
/// server reads the movement as an OTP notice. The digits are masked either
/// way.
function codePlaceholder(text: string, index: number, mode: 'cue' | 'weak' | 'strong', cue?: string): string {
  if (mode === 'strong' || (mode === 'cue' && !OTP_BARE_CUE.test(cue ?? ''))) return '[OTP]';
  const prefix = text.slice(0, index);
  let end = 0;
  for (const m of prefix.matchAll(OTP_SENTENCE_END)) end = m.index! + m[0].length;
  const earlier = prefix.slice(0, end);
  return new RegExp(D, 'u').test(earlier) && OTP_MONEY.test(earlier) ? '[REF]' : '[OTP]';
}

const CARD_PATTERN = new RegExp(
  `${NB}${D}{4}[\\s-]?${D}{4}[\\s-]?${D}{4}[\\s-]?${D}{4}${NB_END}`,
  'g',
);
// The leading 0 and 5 may themselves be Arabic-Indic, so they are classes.
const SAUDI_PHONE_PATTERN = new RegExp(
  `${NB}[0\u0660\u06F0][5\u0665\u06F5]${D}{8}${NB_END}`,
  'g',
);
const EGYPT_PHONE_PATTERN = new RegExp(
  `${NB}[0\u0660\u06F0][1\u0661\u06F1][0125\u0660\u0661\u0662\u0665\u06F0\u06F1\u06F2\u06F5]${D}{8}${NB_END}`,
  'g',
);
const INTL_PHONE_PATTERN = new RegExp(`\\+${D}{7,15}${NB_END}`, 'g');
/// R4P-07: the same numbers written in groups ("055 123 4567", "055-123-4567",
/// "+966 55 123 4567"). Run before the unspaced rules.
const SPACED_PHONE_PATTERNS = [
  new RegExp(`${NB}[0\u0660\u06F0][5\u0665\u06F5]${D}[ \\-]${D}{3}[ \\-]${D}{4}${NB_END}`, 'g'),
  new RegExp(
    `${NB}[0\u0660\u06F0][1\u0661\u06F1][0125\u0660\u0661\u0662\u0665\u06F0\u06F1\u06F2\u06F5][ \\-]${D}{4}[ \\-]${D}{4}${NB_END}`,
    'g',
  ),
  new RegExp(`\\+${D}{1,3}(?:[ \\-]${D}{1,4}){2,4}${NB_END}`, 'g'),
];
const IBAN_PATTERN = new RegExp(IBAN_DETECT_PATTERN.source, 'g');
const ACCOUNT_PATTERN = new RegExp(`${NB}${D}{10,20}${NB_END}`, 'g');

/// An IBAN written in groups ("SA88 1234 5678 9012 3456 9898"). The unspaced
/// rule cannot see it and the card rule used to eat the middle 16 digits,
/// leaving the country, check digits and last group behind. Every group after
/// the check digits holds a digit, so ordinary words are never taken. Runs
/// before the card rule (PRIV-0).
const SPACED_IBAN_PATTERN = new RegExp(
  `${NB}[A-Za-z]{2}${D}{2}(?:[ \\-](?=[A-Za-z0-9\u0660-\u0669\u06F0-\u06F9]{0,3}${D})[A-Za-z0-9\u0660-\u0669\u06F0-\u06F9]{4}){3,7}` +
    `(?:[ \\-](?=[A-Za-z0-9\u0660-\u0669\u06F0-\u06F9]{0,3}${D})[A-Za-z0-9\u0660-\u0669\u06F0-\u06F9]{1,3})?${NB_END}`,
  'g',
);

/// A number of 5 to 9 digits right after an account label ("account
/// 60181590", «حساب ٦٠١٨١٥٩٠», "a/c no. 1234567") is an account number, the
/// third party's or the user's own, even though it is shorter than the
/// generic 10-digit rule. A partial suffix of 4 digits or fewer («حسابك
/// ***1234») stays, and a figure followed by a currency or a decimal part is
/// an amount and stays (PRIV-0).
const LABELLED_ACCOUNT_PATTERN = new RegExp(
  `((?<![\\p{L}\\p{M}])(?:account|acct|acc|a\\/c|ac|حساب|الحساب|لحساب|للحساب|بحساب|حسابك|لحسابك|حسابكم|حسابي)` +
    `(?![\\p{L}\\p{M}])\\.?(?:[ \\t]+(?:no|number|num|رقم)(?![\\p{L}\\p{M}])\\.?)?[ \\t]*[:#]?[ \\t]*)` +
    `[*xX•#]*${D}{5,9}(?!${D}|[.,\u066B\u066C]${D}|[ \\t]*(?:sar|egp|aed|usd|eur|gbp|kwd|qar|bhd|omr|jod|le|sr|riyals?|pounds?|dirhams?|dinars?|dollars?|ريال|جنيه|جم|درهم|دينار|دولار|يورو|ر\\.س)(?![\\p{L}\\p{M}])(?![ \\t]*${D}))`,
  'giu',
);

/// E-mail addresses. Runs FIRST: a local part such as `ahmed0551234567`
/// would otherwise be half-eaten by the phone rule and leave the rest behind.
const EMAIL_PATTERN = /[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/g;

/// Reference / transaction numbers, CUE-ANCHORED like the OTP rule. Six or more
/// characters containing a digit after `Ref`, `Reference No`, `RRN`,
/// `رقم المرجع`, `رقم العملية` … A reference ties the message to one
/// transaction at the bank, so it is a pseudonymous identifier the parser never
/// needs. The cue is kept (the parse prompt reads "IPN REF" as a transfer
/// signal); the value is not. A run that continues into a decimal is an
/// amount, not a reference, and is left alone. Runs AFTER the account rule,
/// so a 10+ digit reference stays `[ACCOUNT]` as before; this adds the 6-9
/// character ones.
const REF_PATTERN = new RegExp(
  `((?<![\\p{L}\\p{M}])(?:reference|ref|rrn|رقم[ \\t]+المرجع|الرقم[ \\t]+المرجعي|المرجع|مرجع|رقم[ \\t]+العملية|رقم[ \\t]+الحوالة|رقم[ \\t]+المعاملة)(?![\\p{L}\\p{M}])` +
    `(?:[ \\t]*(?:no|number|num|id)(?![\\p{L}\\p{M}]))?[ \\t]*[.:#]*[ \\t]*)` +
    `(?=[A-Za-z0-9\\u0660-\\u0669\\u06F0-\\u06F9\\-]*${D})[A-Za-z0-9\\u0660-\\u0669\\u06F0-\\u06F9\\-]{6,}` +
    `(?![A-Za-z0-9\\u0660-\\u0669\\u06F0-\\u06F9\\-]|[.,\\u066B\\u066C]${D})`,
  'giu',
);

/// Redacts card numbers, phone numbers, IBANs, OTPs and account numbers.
///
/// ORDER MATTERS: the specific patterns run first, and the generic account
/// rule runs last, because it would otherwise eat the digit run inside a more
/// specific match.
export function redactPii(text: string): string {
  const coded = OTP_RULES.reduce(
    (s, [pattern, mode]) =>
      s.replace(pattern, (...m) => {
        const offset = m.findIndex((x) => typeof x === 'number');
        return `${m[1]}${codePlaceholder(s, m[offset], mode, mode === 'cue' ? m[2] : undefined)}`;
      }),
    text
      .replace(EMAIL_PATTERN, '[EMAIL]')
      .replace(SPACED_IBAN_PATTERN, '[IBAN]')
      .replace(CARD_PATTERN, '[CARD]')
      .replace(SPACED_PHONE_PATTERNS[0], '[PHONE]')
      .replace(SPACED_PHONE_PATTERNS[1], '[PHONE]')
      .replace(SPACED_PHONE_PATTERNS[2], '[PHONE]')
      .replace(SAUDI_PHONE_PATTERN, '[PHONE]')
      .replace(EGYPT_PHONE_PATTERN, '[PHONE]')
      .replace(INTL_PHONE_PATTERN, '[PHONE]')
      .replace(IBAN_PATTERN, '[IBAN]')
      .replace(OTP_PATTERN, '$1[OTP]'),
  );
  return coded
    .replace(ACCOUNT_PATTERN, '[ACCOUNT]')
    .replace(LABELLED_ACCOUNT_PATTERN, '$1[ACCOUNT]')
    .replace(REF_PATTERN, '$1[REF]');
}

// ── Personal names ──────────────────────────────────────────────────────────
//
// The rules below mask a person's name with the TYPED placeholder `[NAME]`,
// keeping the cue (`from`, `من`, `Dear` …) so the model still sees the
// structure of the message. They are mirrored, pattern for pattern, in
// `app/lib/engine/privacy/sms_sanitizer.dart`; keep the two in lockstep.
//
// A name is 1-6 tokens made of letters (Latin or Arabic), combining marks and
// `* . ' ’ -` (masked names such as `AHM***` and initials such as `A.HASSAN`
// are names too). It ends at a digit, punctuation, a line break, a redaction
// placeholder, or a STOPWORD — the words that follow a name in real bank
// messages (`on`, `via`, `ref`, `بمبلغ`, `في` …) and the words that follow a
// cue without being a name (`your account`, `حسابك`, `Customer`, currencies).
// Over-masking stays inside one line and never touches a digit, so amounts,
// dates, times and card tails survive by construction.

/// Words that are never (the start of) a person's name. Letters only; the
/// boundary check after the alternation makes each one a whole token.
const NAME_STOPWORDS = [
  // English
  'your',
  'yours',
  'you',
  'our',
  'us',
  'the',
  'a',
  'an',
  'account',
  'accounts',
  'acct',
  'acc',
  'ac',
  'card',
  'cards',
  'wallet',
  'mobile',
  'phone',
  'number',
  'no',
  'on',
  'at',
  'in',
  'into',
  'via',
  'using',
  'with',
  'for',
  'of',
  'to',
  'from',
  'by',
  // PRIV-1: a person cue is never (the start of) the name it introduces.
  'beneficiary',
  'benef',
  'payee',
  'sender',
  'remitter',
  'recipient',
  'payer',
  'ref',
  'reference',
  'rrn',
  'amount',
  'amt',
  'is',
  'was',
  'has',
  'have',
  'been',
  'and',
  'or',
  'date',
  'time',
  'balance',
  'bal',
  'avl',
  'available',
  'avail',
  'customer',
  'customers',
  'client',
  'cardholder',
  'holder',
  'valued',
  'sir',
  'madam',
  'member',
  'there',
  'team',
  'atm',
  'branch',
  'bank',
  'app',
  'online',
  'internet',
  'instapay',
  'ipn',
  'sarie',
  'mada',
  'swift',
  'transfer',
  'transaction',
  'trx',
  'txn',
  'successful',
  'successfully',
  'added',
  'credit',
  'debit',
  'credited',
  'debited',
  'cash',
  'deposit',
  'salary',
  'sar',
  'egp',
  'aed',
  'usd',
  'eur',
  'gbp',
  'kwd',
  'qar',
  'bhd',
  'omr',
  'jod',
  'le',
  'sr',
  'riyal',
  'riyals',
  'pound',
  'pounds',
  'dirham',
  'dirhams',
  'dinar',
  'dinars',
  'dollar',
  'dollars',
  'transferred',
  'sent',
  'received',
  'paid',
  'made',
  'requested',
  'deposited',
  'withdrew',
  'initiated',
  'will',
  'would',
  'name',
  // Arabic
  'حسابك',
  'حسابكم',
  'حساب',
  'الحساب',
  'حسابات',
  'لحسابك',
  'لحساب',
  'للحساب',
  'بطاقتك',
  'بطاقتكم',
  'بطاقة',
  'البطاقة',
  'بطاقه',
  'رصيدك',
  'رصيد',
  'الرصيد',
  'خلال',
  'قبل',
  'في',
  'على',
  'عن',
  'إلى',
  'الى',
  'الي',
  'من',
  'بمبلغ',
  'مبلغ',
  'المبلغ',
  'بقيمة',
  'قيمة',
  'بتاريخ',
  'تاريخ',
  'يوم',
  'اليوم',
  'الساعة',
  'الساعه',
  'ساعة',
  'وقت',
  'رقم',
  'عبر',
  'بواسطة',
  'محفظة',
  'محفظتك',
  'المحفظة',
  'ريال',
  'جنيه',
  'جم',
  'درهم',
  'دينار',
  'دولار',
  'يورو',
  'العميل',
  'عميلنا',
  'عملائنا',
  'عزيزي',
  'تطبيق',
  'الصراف',
  'صراف',
  'جهاز',
  'مدى',
  'سريع',
  'انستاباي',
  'حوالة',
  'حواله',
  'تحويل',
  'التحويل',
  'الحوالة',
  'واردة',
  'وارده',
  'صادرة',
  'صادره',
  'البنك',
  'بنك',
  'فرع',
  'عند',
  'لدى',
  'و',
  'تم',
  'المتاح',
  'متاح',
  'المرجع',
  'مرجع',
  'رسوم',
  'عمولة',
  'قام',
  'حول',
  'حوّل',
  'أرسل',
  'ارسل',
  'إرسال',
  'ارسال',
  'بتحويل',
  'بإرسال',
  'استلم',
  'أودع',
  'اودع',
  'سحب',
  'دفع',
  // Tense and status words (SM-07 / Vso4): a name never runs into what
  // the message says happened, so «… إلى علي سينفذ غدا» keeps «سينفذ غدا».
  'shall',
  'tomorrow',
  'today',
  'scheduled',
  'executes',
  'executed',
  'execution',
  'pending',
  'declined',
  'rejected',
  'failed',
  'unsuccessful',
  'completed',
  'approved',
  'processed',
  'awaiting',
  'expected',
  'upcoming',
  'reversed',
  'cancelled',
  'canceled',
  'not',
  'please',
  'if',
  'once',
  'when',
  'every',
  'under',
  'due',
  'سينفذ',
  'ستنفذ',
  'سيتم',
  'ستتم',
  'سوف',
  'غدا',
  'غداً',
  'مجدول',
  'مجدولة',
  'سيخصم',
  'سيُخصم',
  'سيضاف',
  'سيودع',
  'جاري',
  'جارٍ',
  'قيد',
  'معلق',
  'معلقة',
  'مرفوضة',
  'مرفوض',
  'رفض',
  'فشلت',
  'فشل',
  'لم',
  'تمت',
  'بنجاح',
  'كمستفيد',
  'يرجى',
  'الرجاء',
  'إذا',
  'اذا',
  'مستحق',
  'مستحقة',
  // Account types (own-account moves keep «from Savings to Current»).
  'savings',
  'saving',
  'current',
  'checking',
  'chequing',
  'iban',
  // A failure reason after "due to" is never a name (L_L58).
  'insufficient',
  'funds',
  'limit',
  'reason',
  'technical',
  'error',
  'request',
  'lack',
  'الآيبان',
  'الايبان',
  'آيبان',
  'ايبان',
  'التوفير',
  'توفير',
  'الادخار',
  'ادخار',
  'الجاري',
  // Words that open a label or a sentence without being a name.
  'payment', 'payments', 'purchase', 'refund', 'bill', 'pos', 'attn', 'attention', 'cardholder', 'merchant', 'we', 'it',
  'he', 'she', 'they', 'this', 'that', 'now', 'here', 'then',
  'الاسم', 'اسم', 'عناية', 'شراء', 'سداد', 'عملية', 'العملية', 'الجهة', 'المفوتر', 'المستفيد',
  'مستفيد', 'المرسل', 'المستلم', 'المحول', 'ناجح', 'ناجحة', 'داخلي', 'داخلية', 'دولي', 'دولية', 'محلي', 'محلية', 'فوري',
  'فورية', 'سريعة', 'بنكي', 'بنكية', 'مالية', 'جديد', 'جديدة', 'صادر', 'وارد', 'إشعار', 'اشعار', 'تنبيه', 'تأكيد',
  'تفاصيل', 'لك', 'إليك', 'اليك', 'حامل', 'صاحب', 'بين',
  // AR-02: the first word of every not-completed, pending, future, negation
  // and hypothetical cue of the parser (`parser_rules.json`: declinedKeywords,
  // stateCueAwaitedWords, stateCue*Markers, messageMeaning.*), so a name never
  // runs into what the message says happened. `sms_redaction_cue_test.ts`
  // fails when the parser gains a cue this list does not stop at.
  'are', 'attempted', 'authorization', 'being', 'blocked', 'bounced', 'call', 'can', 'cannot', 'contact', 'could',
  'denied', 'did', 'didn', 'exceeded', 'exceeds', 'expired', 'going', 'hold', 'may', 'might', 'minimum', 'pre',
  'preauthorisation', 'preauthorization', 'refused', 'remind', 'reminder', 'report', 'should', 'stopped', 'timed',
  'unable', 'unauthorised', 'unauthorized', 'unless', 'void', 'voided', 'withdrawal',
  'إبلاغ', 'اتصل', 'اعتراض', 'المتوقع', 'انتهت', 'بانتظار', 'تجاوز', 'تجاوزت', 'تخطي', 'تذكير', 'تستحق', 'تعذر', 'تعذرت',
  'تواصل', 'رفضت', 'ستتلقى', 'ستحصل', 'ستستلم', 'سيصلك', 'طلب', 'عدم', 'غير', 'فاشلة', 'قد', 'لا', 'لعدم', 'لن', 'لو',
  'متوقع', 'محاولة', 'ملغاة', 'ملغية', 'موعد', 'موقوفة', 'يستحق', 'يمكن', 'يمكنك', 'انتظار', 'التأكيد', 'الموافقة',
  'المعالجة', 'التنفيذ', 'الانتظار',
  // … and every other word of those cue phrases.
  'approval', 'attempt', 'authorised', 'authorized', 'confirmation', "didn't", 'didn’t', "couldn't", 'couldn’t',
  "wasn't", 'wasn’t', "can't", 'can’t', "won't", 'won’t', "hasn't", 'hasn’t', "isn't", 'isn’t', "doesn't", 'doesn’t',
  'dispensed', 'out', 'pre-auth', 'pre-authorisation', 'pre-authorization', 'process', 'processing', 'review',
  'reviewed', 'run',
  'أن', 'إتمام', 'إلغاء', 'إيقاف', 'استرداد', 'الإلغاء', 'الاسترداد', 'الحد', 'الخصم', 'الدفع', 'الرفض', 'السحب',
  'السداد', 'بنا', 'تتم', 'تعليق', 'تكتمل', 'تنجح', 'تنفذ', 'تنفيذ', 'حال', 'حجز', 'حد', 'خصم', 'صرف', 'صلاحية', 'كاف',
  'كافي', 'كفاية', 'محجوز', 'مصرح', 'معالجة', 'معنا', 'مقبول', 'مقبولة', 'يتم', 'ينجح',
  // Verbs and auxiliaries: what follows "to" / "by" / a name is an action.
  'were', 'be', 'does', 'do', 'done', 'must', 'went', 'go', 'goes', 'gone', 'through', 'got', 'get', 'gets', 'confirm',
  'confirmed', 'verify', 'verified', 'complete', 'proceed', 'activate', 'avoid', 'view', 'check', 'receive', 'pay',
  'use', 'visit', 'click', 'reply', 'send', 'make', 'see', 'authorise', 'authorize', 'approve', 'cancel', 'stop', 'try',
  'tried', 'arrive', 'arrived', 'reach', 'reached', 'remain', 'remains', 'returned', 'refunded', 'posted', 'booked',
  'placed', 'issued', 'released', 'held', 'settle', 'settled',
  // AR-07: date and time words survive.
  'yesterday', 'tonight', 'morning', 'evening', 'afternoon', 'noon', 'midnight', 'earlier', 'later', 'ago', 'recently',
  'currently', 'already', 'just', 'still', 'again', 'soon', 'immediately', 'instantly', 'last', 'next', 'week', 'month',
  'year', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday',
  'أمس', 'امس', 'البارحة', 'الآن', 'الان', 'صباحا', 'صباحاً', 'مساء', 'مساءً', 'ظهرا', 'ظهراً', 'ليلا', 'ليلاً', 'الماضي',
  'الماضية', 'القادم', 'القادمة', 'المقبل', 'المقبلة', 'هذا', 'هذه', 'الشهر', 'الأسبوع', 'الاسبوع', 'السنة', 'العام',
  'لاحقا', 'لاحقاً', 'سابقا', 'سابقاً', 'حاليا', 'حالياً', 'مؤخرا', 'مؤخراً', 'الأحد', 'الاحد', 'الاثنين', 'الإثنين',
  'الثلاثاء', 'الأربعاء', 'الاربعاء', 'الخميس', 'الجمعة', 'السبت',
  // Gemini-first phase 2: a mobile-wallet brand is not a person («من فودافون
  // كاش», "from Orange Cash"), and an enquiry line («للاستفسار اتصل …») is
  // not part of a beneficiary's name.
  'vodafone', 'orange', 'etisalat', 'فودافون', 'اورنج', 'أورنج', 'اتصالات', 'كاش', 'للاستفسار', 'للاستعلام', 'استفسار',
];

/// More words that are not a name, used only where there is no cue at all or
/// after a field label ("Customer service", "Transfer fee SAR 5"). They are
/// kept out of the main list because they are also (parts of) names after a
/// real cue: "from Mark Order" (R4P-04).
const LOOSE_STOPWORDS = [
  'service', 'care', 'support', 'money', 'sum', 'total', 'fee', 'fees', 'charge', 'charges', 'loan', 'installment',
  'instalment', 'invoice', 'tax', 'vat', 'cashback', 'order', 'standing', 'incoming', 'outgoing', 'local',
  'international', 'domestic', 'instant', 'internal', 'external', 'own', 'between', 'alert',
  'notification', 'notice', 'details', 'update', 'status', 'advice', 'id', 'خدمة',
];

/// Words the beneficiary rule may consume with the name: the account or card
/// object a name follows («إلى حساب سارة», "To: the account of …"). The user's
/// OWN account or card («إلى حسابك», "to your card") is not a third party and
/// stays, so own-account moves and credits read the same after redaction.
/// Every other stopword (tense, status, amount, currency, date) ends the run.
const BENEFICIARY_OBJECT_WORDS = new Set([
  'you',
  'us',
  'the',
  'a',
  'an',
  'account',
  'accounts',
  'acct',
  'acc',
  'ac',
  'card',
  'cards',
  'wallet',
  'mobile',
  'phone',
  'number',
  'no',
  'name',
  'حساب',
  'الحساب',
  'حسابات',
  'لحساب',
  'للحساب',
  'بطاقة',
  'البطاقة',
  'بطاقه',
  'محفظة',
  'المحفظة',
  'رقم',
]);

// SM-07: a period that ends a sentence (followed by a space or the end) is
// never part of a name, so redaction cannot merge two sentences ("to Ali
// completed. Previous transfer declined." keeps its second sentence). An
// initial or title keeps its period ("A. Ali", "Mr. Ali") so the name after
// it is still masked.
const SENTENCE_END = `(?:(?<!(?<![\\p{L}\\p{M}])(?:\\p{L}|mrs|mr|ms|dr))\\.(?=\\s|$)|[\\n!?؟;؛])`;
// R4P-01: after an Arabic name particle the next word is part of the name
// whatever it is («عبد العزيز», «أبو بكر», «بن سعود», «آل سعود»).
const AFTER_PARTICLE = `(?<=(?<![\\p{L}\\p{M}])(?:عبد|أبو|ابو|أبي|ابي|بن|ابن|بنت|آل|أم|ام)[ \\t]{1,3})`;
/// The veto of a name token: a stop word (with an optional Arabic «و» / «ف»
/// prefix), as a whole token. Not a veto: after a name particle; a one-letter
/// stop word before ". Name" («A. Ali Hassan») or before another name word
/// (R4P-05, a middle initial without a dot: "NOURA A ALHARBI").
const stopAt = (words: string[]) => {
  const stop = words.join('|');
  return `(?!(?!${AFTER_PARTICLE})(?:[وف](?=[\\u0621-\\u064A]{2}))?(?:${stop})(?![\\p{L}\\p{M}*'’\\-]|\\.[\\p{L}\\p{M}]` +
    `|(?<=(?<![\\p{L}\\p{M}])\\p{L})\\.[ \\t]+\\p{L}` +
    `|(?<=(?<![\\p{L}\\p{M}])\\p{L})[ \\t]+(?!(?:${stop})(?![\\p{L}\\p{M}]))\\p{L}))`;
};
const nameToken = (words: string[]) =>
  stopAt(words) +
  // A lone star before digits is a masked number, not a masked name.
  `(?!\\*+${D})[\\p{L}\\p{M}*](?:[\\p{L}\\p{M}*'’\\-]|(?!${SENTENCE_END})\\.)*(?![\\p{L}\\p{M}*'’\\-]|${D})`;
const NAME_TOKEN = nameToken(NAME_STOPWORDS);
const NAME = `${NAME_TOKEN}(?:[ \\t]+${NAME_TOKEN}){0,5}`;
const LOOSE_NAME_TOKEN = nameToken([...NAME_STOPWORDS, ...LOOSE_STOPWORDS]);
const LOOSE_NAME = `${LOOSE_NAME_TOKEN}(?:[ \\t]+${LOOSE_NAME_TOKEN}){0,5}`;

// The beneficiary after «إلى»/«الى»/"To:": the letter tokens of the name (and
// the account or card object before it), never a tense, status, amount,
// currency or date word, an amount, a date or the next sentence (Vso4:
// «إلى حساب 7788 سينفذ غدا» keeps «سينفذ غدا»). An initial or title keeps its
// period so the rest of the name is still masked.
const BENEFICIARY_STOP = NAME_STOPWORDS.filter((w) => !BENEFICIARY_OBJECT_WORDS.has(w));
const BENEFICIARY_TOKEN = `(?!(?!${AFTER_PARTICLE})(?:[وف](?=[\\u0621-\\u064A]{2}))?(?:${BENEFICIARY_STOP.join('|')})(?![\\p{L}\\p{M}*'’\\-]|\\.[\\p{L}\\p{M}]))` +
  `[\\p{L}\\p{M}][\\p{L}\\p{M}*'’\\-]*(?:\\.[\\p{L}\\p{M}][\\p{L}\\p{M}*'’\\-]*)*` +
  `(?:(?<=(?<![\\p{L}\\p{M}])(?:\\p{L}|mrs|mr|ms|dr))\\.)?`;
// A name already masked as [NAME] is part of the run, so the beneficiary
// still reads [REDACTED] as before.
// The third party's account, card or IBAN number is part of the run too
// (Western or Arabic-Indic digits, star-masked or not, a placeholder, an
// IBAN-like token), so «إلى حساب 7788 سينفذ غدا» → «إلى: [REDACTED] سينفذ غدا».
// A figure followed by a currency or a decimal part is an amount, and one
// with `/` or `:` is a date or time: those end the run and are kept.
const CURRENCY_AFTER = [
  'sar', 'egp', 'aed', 'usd', 'eur', 'gbp', 'kwd', 'qar', 'bhd', 'omr', 'jod', 'le', 'sr', 'riyals?', 'pounds?',
  'dirhams?', 'dinars?', 'dollars?', 'ريال', 'جنيه', 'جم', 'درهم', 'دينار', 'دولار', 'يورو', 'ر\\.س',
];
const BENEFICIARY_ID = `(?:\\[(?:ACCOUNT|IBAN|CARD|PHONE|REF)\\]|[A-Z]{2}${D}{2}(?:[ ]?[0-9A-Z]{4})*(?:[ ]?[0-9A-Z]{1,3})?|[*xX•#]*${D}+(?:-${D}+)*)` +
  `(?![0-9A-Za-z]|[.,\u066B\u066C/:]${D}|${D}|[ \\t]*(?:${CURRENCY_AFTER.join('|')})(?![\\p{L}\\p{M}])(?![ \\t]*${D}))`;
const BENEFICIARY_PART = `(?:\\[NAME\\]|${BENEFICIARY_ID}|${BENEFICIARY_TOKEN})`;
const BENEFICIARY_RUN = `${BENEFICIARY_PART}(?:[ \\t]+${BENEFICIARY_PART})*`;
const BENEFICIARY_AR = new RegExp(`(إلى|الى)\\s*:?\\s*${BENEFICIARY_RUN}`, 'giu');
const BENEFICIARY_EN = new RegExp(`\\bTo(?:[ \\t]+name)?\\s*:\\s*${BENEFICIARY_RUN}`, 'giu');

// The user's own account or card after the cue stays («إلى حسابك ***1234»),
// but only as a partial suffix: an unmasked number of five or more digits
// after it is still masked as [ACCOUNT] (10+ digits already are, by redactPii).
const OWN_DESTINATION_NUMBER = new RegExp(
  `((?:إلى|الى|\\bto)\\s*:?\\s*(?:your|حسابك|حسابكم|لحسابك|بطاقتك|بطاقتكم|محفظتك)` +
    `(?:[ \\t]+(?:account|card|wallet|رقم|no\\.?|number))?[ \\t]+)[*xX•#]*${D}{5,}` +
    `(?![.,\u066B\u066C/:]?${D}|[ \\t]*(?:${CURRENCY_AFTER.join('|')})(?![\\p{L}\\p{M}])(?![ \\t]*${D}))`,
  'giu',
);

// Any other number left in the beneficiary's sentence (from «إلى»/«الى»/"To:"
// to the end of the sentence, the span the rule used to remove whole) is
// masked as [ACCOUNT], unless it is an amount (a currency next to it, or a
// grouped or decimal figure), a date or time, a day before a month name, or
// the user's own partial suffix (at most four digits after «حسابك», "your
// account" …). So «إلى سارة سينفذ غدا من حسابك 12345678» never keeps the
// number, while «إلى حسابك ***1234 في 05/11» and «SAR 500.00» stay.
const MONTH = [
  'يناير', 'فبراير', 'مارس', 'أبريل', 'ابريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'اغسطس', 'سبتمبر', 'أكتوبر', 'اكتوبر',
  'نوفمبر', 'ديسمبر', 'jan(?:uary)?', 'feb(?:ruary)?', 'mar(?:ch)?', 'apr(?:il)?', 'may', 'june?', 'july?',
  'aug(?:ust)?', 'sep(?:t|tember)?', 'oct(?:ober)?', 'nov(?:ember)?', 'dec(?:ember)?',
];
const OWN_WORD = `(?:your|حسابك|حسابكم|لحسابك|بطاقتك|بطاقتكم|محفظتك)(?:[ \\t]+(?:account|card|wallet|رقم|no\\.?|number))?`;
const CURRENCY_WORD = `(?:${CURRENCY_AFTER.join('|')})(?![\\p{L}\\p{M}])`;
const DATE_WORD = `(?<![\\p{L}\\p{M}])(?:بتاريخ|تاريخ|date|dated)`;
const HOTLINE_WORD =
  `(?<![\\p{L}\\p{M}])(?:call(?:[ \\t]+us)?(?:[ \\t]+(?:on|at))?|hotline|اتصل(?:[ \\t]+على)?|للاستفسار|للاستعلام|الخط[ \\t]+الساخن)`;
const NUMBER_IN_BENEFICIARY_SENTENCE = new RegExp(
  `(?<![A-Za-z0-9\u0660-\u0669\u06F0-\u06F9*•#]|${D}[.,\u066B\u066C/:\\-])` +
    `(?![*xX•#]*${D}{1,4}(?!${D}|-${D})(?<=${OWN_WORD}[ \\t]+[*xX•#]*${D}+))` +
    `(?!${D}{1,2}[ \\t]+(?:${MONTH.join('|')})(?![\\p{L}\\p{M}]))` +
    // Gemini-first phase 2: a dashed date ("12-05-2024", "2024-05-12"), a
    // compact date right after a date word («بتاريخ 20240512») and a short
    // hotline number after a call cue («للاستفسار اتصل 19623») stay.
    `(?!${D}{1,2}-${D}{1,2}-${D}{4}(?!${D})|${D}{4}-${D}{1,2}-${D}{1,2}(?!${D}))` +
    `(?!(?<=${DATE_WORD}[ \\t]{0,3}:?[ \\t]{0,3})${D}{6,8}(?!${D}))` +
    `(?!(?<=${HOTLINE_WORD}[ \\t]{0,3}:?[ \\t]{0,3})${D}{3,5}(?!${D}))` +
    `(?<!(?<![\\p{L}\\p{M}])${CURRENCY_WORD}[ \\t]*)` +
    `(?:[A-Z]{2}(?=${D}))?[*xX•#]*${D}+(?:-${D}+)*` +
    `(?![0-9A-Za-z\u0660-\u0669\u06F0-\u06F9]|[.,\u066B\u066C/:\\-]${D}|[ \\t]*${CURRENCY_WORD}(?![ \\t]*${D}))` +
    `(?<=(?:إلى|الى|\\bTo(?:[ \\t]+name)?\\s*:)(?:(?!${SENTENCE_END}).)*)`,
  'giu',
);
const CUE_SEP = `(?:[ \\t]*:[ \\t]*|[ \\t]+)`;
// After a field label a dash separates too ("Recipient - Dana Yousef - …").
const LABEL_SEP = `(?:[ \\t]*[:\\-][ \\t]*|[ \\t]+)`;

/// Salutations — a name follows by definition, in any kind of message.
/// English greetings only at the start of the text or of a sentence, so a
/// merchant such as "DEAR DIARY CAFE" after "Purchase at" is not one.
const SALUTATION_PATTERN = new RegExp(
  `((?:(?<![\\p{L}\\p{M}])(?:عزيزي|عزيزتي|السيدة|السيد|الأستاذة|الاستاذة|الأستاذ|الاستاذ|(?:عميلنا|عميلتنا)[ \\t]+(?:العزيز|العزيزة|الكريم|الكريمة)[ \\t]*[\\/:\\-])` +
    `|(?:^|(?<=[\\n.!?؟؛;:،,]))[ \\t]*(?:dear|hi|hello))(?![\\p{L}\\p{M}])${CUE_SEP})(${NAME})`,
  'giu',
);

/// Counterparty cues. These words introduce a merchant in a purchase
/// ("Purchase from AMAZON", «شراء من كارفور») and a PERSON in a transfer
/// ("Transfer received from AHMED ALI", «حوالة واردة من محمد أحمد»), so they
/// are applied only when the message reads as a transfer/credit AND not as a
/// purchase/refund/bill — see [isCounterpartyContext].
const COUNTERPARTY_PATTERN = new RegExp(
  `((?<![\\p{L}\\p{M}])(?:from|to(?:[ \\t]+name)?|by|beneficiary(?:[ \\t]+name)?|sender(?:[ \\t]+name)?|remitter(?:[ \\t]+name)?` +
    `|recipient(?:[ \\t]+name)?|payer(?:[ \\t]+name)?|on[ \\t]+behalf[ \\t]+of|in[ \\t]+favou?r[ \\t]+of|mrs|mr|ms|dr` +
    `|من[ \\t]+قبل|اسم[ \\t]+المستفيد|اسم[ \\t]+المرسل|المستفيد|مستفيد|المرسل|المحول|لصالح|ب[اإأ]سم|بواسطة|من|إلى|الى|الي|لـ)` +
    `\\.?(?![\\p{L}\\p{M}])${CUE_SEP})(${NAME})`,
  'giu',
);

/// Gemini-first phase 2: what may follow a glued «باسم»: a letter, never a
/// pronoun ending («باسمك», «باسمه», «باسمها» …), «ة» (the name «باسمة») or the
/// plural «أسماء».
const GLUED_NAME = `(?=[\\p{L}])(?!(?:ك|كم|كن|ه|ها|هم|هما|هن|ي|ى|نا)(?![\\p{L}\\p{M}])|ة|اء|ائ)`;
/// A from/to cue, a masked or placeholder number, then a semicolon: the
/// holder's name follows. Not after a card label: «بطاقة: ***1046;ائتمانية»
/// names the card type.
const MASKED_NUMBER_SEP = `(?<![\\p{L}\\p{M}])(?:من|لـ|ل|إلى|الى|الي|from|to)[ \\t]*` +
  `(?:\\[(?:ACCOUNT|PHONE|CARD)\\]|[*xX•#]+${D}*|${D}+[*•]+)[ \\t]*[;؛][ \\t]*`;

/// PRIV-1: cues that only ever introduce a person (a payee, a beneficiary, a
/// sender), so they apply in any message, transfer word or not.
const PERSON_CUE_PATTERN = new RegExp(
  `((?:(?<![\\p{L}\\p{M}])(?<!(?<![\\p{L}\\p{M}])at[ \\t]{1,3})(?:beneficiary(?:[ \\t]+name)?|benef|payee(?:[ \\t]+name)?|sender(?:[ \\t]+name)?` +
    `|remitter(?:[ \\t]+name)?|recipient(?:[ \\t]+name)?|payer(?:[ \\t]+name)?|on[ \\t]+behalf[ \\t]+of|in[ \\t]+favou?r[ \\t]+of` +
    `|payable[ \\t]+to|(?:for[ \\t]+)?employee|اسم[ \\t]+المستفيد|اسم[ \\t]+المرسل|المستفيد|مستفيد|للمستفيد|المرسل|المستلم|للمستلم|المحول` +
    `|لصالح|ب[اإأ]سم|للسيدة|للسيد)\\.?(?![\\p{L}\\p{M}])${LABEL_SEP}` +
    // Gemini-first phase 2: the name glued to «باسم» / «بإسم» («المسجل
    // باسمسارة نبيل»), but not a pronoun ending («باسمك», «باسمه») …
    `|(?<![\\p{L}\\p{M}])ب[اإأ]سم${GLUED_NAME}` +
    // … and the holder after a masked number and a semicolon («من****;فهد
    // العتيبي», «لـ****; نورة القحطاني»).
    `|${MASKED_NUMBER_SEP}))(${NAME})`,
  'giu',
);

/// N-P1: a beneficiary notice names a person wherever the name sits: after
/// the cue and its status words ("Beneficiary added successfully: Rami
/// Fawzi", «تمت إضافة المستفيد بنجاح: رامي فوزي»), between commas ("A new
/// beneficiary, Sami Odeh, was added"), and before the role ("Sami Odeh was
/// added as a beneficiary", «تمت إضافة رامي فوزي كمستفيد»). The status words
/// stay.
const BENEFICIARY_NOTICE_PATTERN = new RegExp(
  `((?<![\\p{L}\\p{M}])(?<!(?<![\\p{L}\\p{M}])at[ \\t]{1,3})(?:beneficiary|beneficiaries|payee|المستفيد|مستفيد|للمستفيد)(?![\\p{L}\\p{M}])` +
    `(?:[ \\t]+(?:new|added|successfully|has|have|been|was|الجديد|جديد|بنجاح)(?![\\p{L}\\p{M}]))*` +
    `(?:[ \\t]*[:,،\\-][ \\t]*|[ \\t]+))(${NAME})`,
  'giu',
);
const NAME_ADDED_AS_PATTERN = new RegExp(
  `((?:(?:^|(?<=[\\n.!?؟;؛:,،]))[ \\t]*|(?<![\\p{L}\\p{M}])(?:added|إضافة|اضافة|أضفت|اضفت)[ \\t]+))(${LOOSE_NAME})` +
    `(?=[ \\t]+(?:(?:was|has[ \\t]+been|have[ \\t]+been)[ \\t]+(?:successfully[ \\t]+)?added[ \\t]+)?` +
    `(?:as[ \\t]+(?:an?[ \\t]+)?(?:new[ \\t]+)?(?:beneficiary|payee)|كمستفيد|إلى[ \\t]+(?:قائمة[ \\t]+)?المستفيدين)(?![\\p{L}\\p{M}]))`,
  'giu',
);

/// PRIV-1: a "From:" field label and "paid to" — a person unless the message
/// reads as a purchase, refund or bill (then a merchant).
const LABEL_CUE_PATTERN = new RegExp(
  `((?<![\\p{L}\\p{M}])(?:from[ \\t]*:|من[ \\t]*:|request(?:ed)?[ \\t]+from(?![\\p{L}\\p{M}])|paid[ \\t]+to(?![\\p{L}\\p{M}]))[ \\t]*)(${NAME})`,
  'giu',
);

/// PRIV-1: "To Sara Ahmed: SAR 50.00 …", "From Sara Ahmed: …", «من سارة
/// أحمد: …» — a name between the word at the start of the text or a sentence
/// and a colon.
const TO_HEADING_PATTERN = new RegExp(
  `((?:^|(?<=[\\n.!?؟;؛]))[ \\t]*(?:to|from|من)[ \\t]+)(${NAME})(?=[ \\t]*:)`,
  'giu',
);

/// PRIV-1r: field labels that only ever introduce a person ("Attn Sara",
/// "Name: Sara Ahmed", "Customer Sara Ahmed", «الاسم: سارة», «العميل سارة»,
/// "Cardholder …"), in any message. "Merchant name: …" names a business.
const PERSONAL_LABEL_PATTERN = new RegExp(
  `((?<![\\p{L}\\p{M}])(?:attn|attention|(?<!merchant[ \\t]|store[ \\t]|shop[ \\t]|bank[ \\t]|company[ \\t])name|customer(?:[ \\t]+name)?` +
    `|card[ \\t]?holder(?:[ \\t]+name)?|account[ \\t]+holder(?:[ \\t]+name)?|عناية|الاسم|اسم(?=[ \\t]*:)|العميل|العميلة|حامل[ \\t]+البطاقة|صاحب[ \\t]+الحساب)` +
    `\\.?(?![\\p{L}\\p{M}])${LABEL_SEP})(${LOOSE_NAME})`,
  'giu',
);

/// SP-16: "to account of Mohammed Abdullah", «حساب باسم محمد» — the holder of
/// an account, in any message.
const ACCOUNT_OF_PATTERN = new RegExp(
  `((?<![\\p{L}\\p{M}])(?:(?:account|acct|acc|a\\/c|ac|card|wallet)(?:[ \\t]+(?:no\\.?[ \\t]*)?(?:[*xX•#]*${D}{1,9}|\\[ACCOUNT\\]))?[ \\t]+of|(?:حساب|الحساب|لحساب|بطاقة|محفظة)[ \\t]+ب[اإأ]سم)(?![\\p{L}\\p{M}])${CUE_SEP})(${NAME})`,
  'giu',
);

/// AR-01: «من حساب هاني عادل 7788» — the holder named right after the account
/// word, in any message. («إلى حساب <name>» is the beneficiary rule's.)
const ACCOUNT_HOLDER_PATTERN = new RegExp(
  `((?<![\\p{L}\\p{M}])(?:من|في)[ \\t]+(?:حساب|الحساب)[ \\t]+)(${NAME})`,
  'giu',
);

/// AR-01: a number right after a masked name is that person's account or card
/// number, whatever its length — unless it is an amount, a date or a time.
const NUMBER_AFTER_NAME = new RegExp(
  `((?:\\[NAME\\]|\\[REDACTED\\])[ \\t]+(?:(?:رقم|no\\.?|number|account|acct|حساب)[ \\t]*[:#]?[ \\t]*)?)[*xX•#]*${D}{1,9}[*•]*` +
    `(?!${D}|[.,\u066B\u066C/:\\-]${D}|[ \\t]*(?:${CURRENCY_AFTER.join('|')})(?![\\p{L}\\p{M}]))`,
  'giu',
);

/// SP-16: a name in parentheses right after an account or card number
/// ("account *9876 (Noura)"), unless the text reads as a purchase.
const PAREN_NAME_PATTERN = new RegExp(
  `((?:\\[(?:ACCOUNT|CARD|IBAN|PHONE)\\]|[*xX•#]${D}{1,9}|(?<![\\p{L}\\p{M}])(?:account|acct|acc|a\\/c|ac|card|wallet|حساب|الحساب|لحساب|للحساب|بطاقة|البطاقة|محفظة)[ \\t]*[:#]?[ \\t]*${D}{1,9})[ \\t]*\\([ \\t]*)(${NAME})(?=[ \\t]*\\))`,
  'giu',
);

/// Names with no cue, unless the text reads as a purchase: the name that
/// opens a sentence before a transfer verb aimed at the user ("Sara Ali sent
/// you SAR 500"), the Arabic verb-first forms («أرسل لك محمد أحمد», «قام محمد
/// أحمد بتحويل») and a full name right after the transfer word before the
/// amount ("Transfer Sara Ali SAR 500", «حوالة محمد أحمد 500 ريال»). The last
/// form takes only capitalised Latin words (see [maskCapitalisedName]); the
/// others take a name in any letter case.
const NAME_BEFORE_VERB_PATTERN = new RegExp(
  `((?:^|(?<=[\\n.!?؟;؛:]))[ \\t]*)(${LOOSE_NAME})(?=[ \\t]+(?:has[ \\t]+|have[ \\t]+)?(?:sent|transferred|paid|remitted|requested)[ \\t]+` +
    `(?:you(?![\\p{L}\\p{M}])|(?:[^.\\n]|\\.(?=${D})){0,30}?(?<![\\p{L}\\p{M}])(?:to|into|from)[ \\t]+you))`,
  'giu',
);
const NAME_AFTER_VERB_AR_PATTERN = new RegExp(
  `((?<![\\p{L}\\p{M}])(?:(?:أرسل|ارسل|حول|حوّل|أودع|اودع)ت?[ \\t]+(?:لك|إليك|اليك)|قام|قامت)[ \\t]+)(${NAME})`,
  'giu',
);
const NAME_AFTER_TRANSFER_PATTERN = new RegExp(
  `((?<![\\p{L}\\p{M}])(?:transfer|transferred|remittance|حوالة|حواله|تحويل)(?![\\p{L}\\p{M}])(?:[ \\t]*[:\\-][ \\t]*|[ \\t]+))` +
    `(${LOOSE_NAME_TOKEN}(?:[ \\t]+${LOOSE_NAME_TOKEN}){1,5})` +
    `(?=[ \\t]*(?:[\\-,،]|${D}|$|\\n|(?:${CURRENCY_AFTER.join('|')})(?![\\p{L}\\p{M}])))`,
  'giu',
);

/// SP-16: "Payment of SAR 99 to Omar Farooq via Mada" — the payee of a
/// payment, unless the text reads as a purchase. Any letter case (AR-01); the
/// stop list keeps what happened ("payment to STC did not go through").
const PAYMENT_TO_PATTERN = new RegExp(
  `((?<![\\p{L}\\p{M}])(?:payment|payments|paid|pay)(?![\\p{L}\\p{M}])(?:[^.\\n;؛!?؟]|\\.(?=${D})){0,40}?(?<![\\p{L}\\p{M}])to[ \\t]+)(${NAME})`,
  'giu',
);
/// N-P2: money coming in from someone, in wording that is not a purchase:
/// the counterparty after "from" / "by" / «من» that follows an amount or an
/// incoming-money verb ("You got SAR 200.00 from …", "topped up with SAR 95.00
/// by …", «تم قيد مبلغ 300 ريال … من …»). Masked unless it carries a business
/// word ([maskPayee]); skipped where the text marks a merchant ([MERCHANT_MARK]).
const INCOMING_FROM_PATTERN = new RegExp(
  `((?:${D}|(?<![\\p{L}\\p{M}])(?:got|received|credited|deposited|added|topped[ \\t]+up|sent[ \\t]+you` +
    `|قيد|أودع|اودع|أضيف|اضيف|وصلك|استلمت|حول|حوّل|حُوّل)(?![\\p{L}\\p{M}]))` +
    `(?:[^.\\n;؛!?؟]|\\.(?=${D})){0,60}?(?<![\\p{L}\\p{M}])(?:from|by|من)[ \\t]+)(${NAME})`,
  'giu',
);
/// A merchant mark: "at <Name>", "@", «لدى», «من متجر».
const MERCHANT_MARK = /(?<![\p{L}\p{M}])(?:at|At|AT)[ \t]+(?=\p{Lu})|@|(?<![\p{L}\p{M}])(?:لدى|من[ \t]+متجر)(?![\p{L}\p{M}])/u;
/// The leading words of a match that can be a name in Latin script: each
/// starts with a capital (or is Arabic, or star-masked).
const CAPITALISED_RUN = /^[\p{Lu}\p{Lo}*][^ \t]*(?:[ \t]+[\p{Lu}\p{Lo}*][^ \t]*)*/u;

/// The text reads as money moving between people.
const TRANSFER_WORDS =
  /transfer|remit|received|credited|deposit|\bipn\b|instapay|beneficiary|\bsent\b|payable\s+to|request(?:ed)?\s+from|(?:payment|money|pay|transfer|fund)s?\s+requests?|requests?\s+(?:to\s+pay|for\s+(?:payment|money))|\brequested\b|standing\s+order|حوال|تحويل|حول|وارد|وصلك|طلب\s+(?:دفع|تحويل|مبلغ|أموال|اموال)|استلام|استلمت|إيداع|ايداع|أودع|اودع|مستفيد|المرسل|انستا|لصالح|أمر\s+(?:مستديم|دائم)|امر\s+(?:مستديم|دائم)/iu;
// "merchant" / «تاجر» alone reads as a purchase only where nothing says
// transfer («إلى محمد التاجر» is a surname in a transfer).
const PURCHASE_WORDS =
  /purchase|\bpos\b|point of sale|paid at|spent|refund|revers|e-?commerce|\bbill|شراء|انترنت|إنترنت|مشتريات|نقاط البيع|نقطة بيع|نقاط بيع|استرداد|مسترد|مرتجع|إرجاع|ارجاع|فاتور|سداد/iu;
const WEAK_PURCHASE_WORDS = /merchant|تاجر/iu;
/// A transfer or remittance by its own wording, whatever else the text says.
/// THE TRANSFER RULE: in such a text every counterparty is masked whole, with
/// no person-or-merchant judgement, and a purchase or refund word does not
/// make it a purchase (privacy wins where the reading is mixed). "credited",
/// "received" or «إيداع» alone are not here: a merchant's refund says them too.
const STRONG_TRANSFER_WORDS =
  /transfer|remit|beneficiary|\bipn\b|instapay|\bsent\b|payable\s+to|request(?:ed)?\s+from|(?:payment|money|pay|transfer|fund)s?\s+requests?|requests?\s+(?:to\s+pay|for\s+(?:payment|money))|\brequested\b|standing\s+order|حوال|تحويل|حول|مستفيد|المرسل|لصالح|وصلك|أرسل|ارسل|طلب\s+(?:دفع|تحويل|مبلغ|أموال|اموال)|انستا|أمر\s+(?:مستديم|دائم)|امر\s+(?:مستديم|دائم)/iu;
const PURCHASE_CONTEXT = {
  test: (text: string) =>
    !STRONG_TRANSFER_WORDS.test(text) &&
    (PURCHASE_WORDS.test(text) || (WEAK_PURCHASE_WORDS.test(text) && !TRANSFER_WORDS.test(text))),
};

/// A business, by the words a business name carries (a shop, company or
/// service marker), never by a list of specific names. Merchant evidence only
/// where the text has no person evidence: see THE DECISION RULE below.
const COMPANY_MARKERS = [
  'shop', 'shops', 'store', 'stores', 'bookstore', 'market', 'markets', 'supermarket', 'hypermarket', 'mart', 'mall',
  'cafe', 'café', 'coffee', 'restaurant', 'restaurants', 'kitchen', 'bakery', 'pharmacy', 'pharmacies', 'clinic',
  'clinics', 'hospital', 'company', 'co', 'corp', 'corporation', 'ltd', 'llc', 'inc', 'est', 'establishment',
  'trading', 'group', 'holding', 'services', 'solutions', 'hotel', 'hotels', 'station', 'petrol', 'fuel', 'telecom',
  'electricity', 'water', 'insurance', 'takaful', 'school', 'university', 'academy', 'airlines', 'airways', 'pay', 'com', 'net',
  'شركة', 'شركه', 'مؤسسة', 'مؤسسه', 'مكتبة', 'مكتبه', 'متجر', 'متاجر', 'محل', 'محلات', 'مطعم', 'مطاعم', 'مقهى', 'كافيه',
  'كوفي', 'صيدلية', 'صيدليات', 'مستشفى', 'عيادة', 'عيادات', 'فندق', 'سوبرماركت', 'هايبر', 'هايبرماركت', 'أسواق', 'اسواق',
  'سوق', 'مركز', 'محطة', 'مخبز', 'مخابز', 'بقالة', 'تموينات', 'للتجارة', 'التجارية', 'للخدمات', 'مدرسة', 'جامعة',
  'الكهرباء', 'المياه', 'الاتصالات', 'للاتصالات', 'للتأمين',
];
const COMPANY_MARKER = new RegExp(`(?<![\\p{L}\\p{M}])(?:${COMPANY_MARKERS.join('|')})(?![\\p{L}\\p{M}])`, 'iu');

// ── Account and card suffixes ───────────────────────────────────────────────
//
// THE RULE (requirement A). A number of 1-4 digits (star-masked or not) after
// an account, card or wallet label is kept only when the text marks it as the
// user's own. Checked in this order:
//   1. THIRD PARTY, always masked: the label carries or follows a beneficiary /
//      payee / sender / recipient word («حساب المستفيد»), follows a masked
//      name, or is followed by a name in parentheses.
//   2. OWN, kept: a possessive label ("your card", "my account", «بطاقتك»,
//      «حسابك», «حسابي» …).
//   3. A destination ("to / into / in account", «إلى / في حساب», «لحساب») is
//      third party, masked — unless a credit verb governs it in the same
//      clause ("credited to account", "refund … to card", "posted to card",
//      «إيداع في حساب») and the text has no transfer-out word (transferred,
//      sent, paid, «حولت», «دفع» …).
//   4. A CARD not caught above is the card the message is about and is kept,
//      except "from card" in an incoming message with no debit verb (the
//      sender's card).
//   5. An ACCOUNT or WALLET, or a star-masked number with no label, is kept
//      in a purchase, refund or bill (the only instrument there is the
//      user's own), except after "from" in an incoming message.
//   6. Otherwise it is kept only as the source of the movement: after "from"
//      / «من» (in an incoming message only when a debit verb governs it:
//      "debited from account … and credited to …"), or — an ACCOUNT or WALLET
//      — after "with / using / via" in a text with no incoming word, or when
//      the text has no other party at all (no transfer or payment word and
//      no masked name). Anything else is masked.
// A number of 5 or more digits after a label is never a suffix and is masked.
const SUFFIX_LABELS = [
  'account', 'acct', 'acc', 'a\\/c', 'ac', 'card', 'wallet', 'mada', 'visa', 'mastercard', 'apple[ \\t]+pay',
  'حساب', 'الحساب', 'لحساب', 'للحساب', 'بحساب', 'بالحساب', 'حسابك', 'لحسابك', 'بحسابك', 'حسابكم', 'لحسابكم', 'حسابي',
  'بطاقة', 'البطاقة', 'ببطاقة', 'بالبطاقة', 'لبطاقة', 'للبطاقة', 'بطاقه', 'بطاقتك', 'ببطاقتك', 'لبطاقتك', 'بطاقتكم', 'بطاقتي',
  'محفظة', 'المحفظة', 'محفظتك', 'لمحفظتك', 'مدى',
];
const THIRD_PARTY_WORDS = [
  'beneficiary', 'benef', 'payee', 'sender', 'recipient', 'receiver', 'remitter', 'payer',
  'المستفيد', 'مستفيد', 'المرسل', 'المستلم', 'المحول',
];
const SUFFIX_NUMBER_END = `(?!${D}|[.,٫٬/:]${D}|[ \\t]*(?:${CURRENCY_AFTER.join('|')})(?![\\p{L}\\p{M}])(?![ \\t]*${D}))`;
const LABELLED_SUFFIX = new RegExp(
  `((?<![\\p{L}\\p{M}])(?:(?:your|my)[ \\t]+)?(?:(?:debit|credit|prepaid|mada|visa|mastercard|current|savings|bank|corporate|business|personal|joint|main|primary|${
    THIRD_PARTY_WORDS.slice(0, 8).join('|')
  })[ \\t]+)*(?:${SUFFIX_LABELS.join('|')})(?![\\p{L}\\p{M}])` +
    `(?:[ \\t]+(?:ending|ends|in|with|no\\.?|number|num|رقم|برقم|المنتهية|منتهية|تنتهي|بـ|ب|مدى|mada|visa|mastercard|الائتمانية|ائتمانية|الجديدة|الجديد|${
      THIRD_PARTY_WORDS.join('|')
    })(?![\\p{L}\\p{M}]))*[ \\t]*[:#]?[ \\t]*)([*xX•#]*${D}{1,9}[*•]*)${SUFFIX_NUMBER_END}`,
  'giu',
);
const MASKED_SUFFIX = new RegExp(
  `(?<![A-Za-z0-9\u0660-\u0669\u06F0-\u06F9*•.,\u066B\u066C/:\\-])()((?:[*•]+|[xX]{2,})[*xX•]*${D}{1,9}[*•]*|${D}{1,9}[*•]+)${SUFFIX_NUMBER_END}`,
  'gu',
);
const L = '[\\p{L}\\p{M}]';
const OPEN = `[ \\t]*:?[ \\t]*(?:(?:the|a|an)[ \\t]+)?$`;
const THIRD_PARTY_WORD = new RegExp(`(?<!${L})(?:${THIRD_PARTY_WORDS.join('|')})(?!${L})`, 'iu');
const THIRD_PARTY_BEFORE = new RegExp(
  `(?:\\[NAME\\]|\\[REDACTED\\]|(?<!${L})(?:${THIRD_PARTY_WORDS.join('|')}))(?:['’]s)?${OPEN}`,
  'iu',
);
const POSSESSIVE = new RegExp(
  `(?<!${L})(?:your|my|حسابك|لحسابك|بحسابك|حسابكم|لحسابكم|حسابي|بطاقتك|ببطاقتك|لبطاقتك|بطاقتكم|بطاقتي|محفظتك|لمحفظتك)(?!${L})`,
  'iu',
);
const POSSESSIVE_BEFORE = new RegExp(`(?<!${L})(?:your|my)[ \\t]+$`, 'iu');
const DESTINATION_BEFORE = new RegExp(`(?<!${L})(?:to|into|in|إلى|الى|الي|في)(?!${L})${OPEN}`, 'iu');
const DESTINATION_LABEL = new RegExp(`^(?:لحساب|للحساب|لبطاقة|للبطاقة)(?!${L})`, 'u');
const CREDIT_VERB_BEFORE = new RegExp(
  `(?<!${L})(?:credited|deposited|refunded|refund|reversal|added|received|returned|arrived|posted|applied|charged|billed|[وف]?(?:إيداع|ايداع|أودع|اودع|أضيف|اضيف|إضاف|اضاف)${L}*|استرداد|استرجاع|واردة|وارده|وارد)(?!${L})(?:[^.\\n;؛!?؟]|\\.(?=${D})|\\.(?=[ \\t]+(?:to|into)(?!${L}))){0,60}$`,
  'iu',
);
const OUTGOING_WORDS = new RegExp(
  `(?<!${L})(?:transferred|sent|paid|دفع|صادرة|صادره|صادر|حولت|أرسلت|ارسلت)(?!${L})`,
  'iu',
);
const INCOMING_WORDS =
  /received|credited|deposit|incoming|refund|وارد|استلام|استلمت|إيداع|ايداع|أودع|اودع|أضيف|اضيف|إضافة|اضافة/iu;
// A debit verb before "from" makes it the user's side even when the text
// also credits something ("debited from account … and credited to …").
const DEBIT_VERB_BEFORE = new RegExp(
  `(?<!${L})(?:debited|deducted|withdrawn|[وف]?(?:خصم|سحب)${L}*)(?!${L})(?:[^.\\n;؛!?؟]|\\.(?=${D})){0,60}$`,
  'iu',
);
const FROM_BEFORE = new RegExp(`(?<!${L})(?:from|من)(?!${L})${OPEN}`, 'iu');
const INSTRUMENT_BEFORE = new RegExp(`(?<!${L})(?:with|using|via|by|through|عبر|باستخدام|بواسطة)(?!${L})${OPEN}`, 'iu');
const INSTRUMENT_LABEL = new RegExp(`^(?:بحساب|بالحساب)(?!${L})`, 'u');
const CARD_LABEL = new RegExp(
  `(?<!${L})(?:card|mada|visa|mastercard|apple[ \\t]+pay|بطاقة|البطاقة|ببطاقة|بالبطاقة|لبطاقة|للبطاقة|بطاقه|مدى)(?!${L})`,
  'iu',
);
const PAYMENT_WORDS = /payment|\bpaid\b|\bpay\b|دفع/iu;
const MASKED_PERSON = /\[NAME\]|\[REDACTED\]/u;
const NAME_IN_PARENS_AFTER = /^[ \t]*\([ \t]*\[NAME\]/u;

interface Suffix {
  /** Offsets of the number (stars included) in the scanned text. */
  start: number;
  end: number;
  card: boolean;
  own: boolean;
}

function digitCount(s: string): number {
  return s.match(new RegExp(D, 'g'))?.length ?? 0;
}

/** Every labelled or star-masked short number in `text`, with the rule's verdict. */
function scanSuffixes(text: string, purchase: boolean): Suffix[] {
  const found: Suffix[] = [];
  const incoming = INCOMING_WORDS.test(text);
  const outgoing = OUTGOING_WORDS.test(text);
  const alone = !TRANSFER_WORDS.test(text) && !PAYMENT_WORDS.test(text) && !MASKED_PERSON.test(text);
  const scan = (pattern: RegExp, labelled: boolean) => {
    for (const m of text.matchAll(pattern)) {
      const phrase = m[1];
      const start = m.index! + phrase.length;
      const end = start + m[2].length;
      if (found.some((f) => f.start === start)) continue;
      const before = text.slice(Math.max(0, m.index! - 80), m.index!);
      const card = CARD_LABEL.test(phrase);
      const from = FROM_BEFORE.test(before);
      // "from" in an incoming message is the sender's side, unless a debit
      // verb governs it.
      const sender = incoming && from && !DEBIT_VERB_BEFORE.test(before);
      let own: boolean;
      if (digitCount(m[2]) > 4) own = false;
      else if (
        THIRD_PARTY_WORD.test(phrase) || THIRD_PARTY_BEFORE.test(before) || NAME_IN_PARENS_AFTER.test(text.slice(end))
      ) own = false;
      else if (POSSESSIVE.test(phrase) || POSSESSIVE_BEFORE.test(before)) own = true;
      else if (DESTINATION_BEFORE.test(before) || DESTINATION_LABEL.test(phrase)) {
        // "debited from your account … and credited to account *7788": the
        // other side of a debit is a third party (R4P-07).
        own = CREDIT_VERB_BEFORE.test(before) && !outgoing && !DEBIT_VERB_BEFORE.test(before);
      } else if (card || purchase) own = !sender;
      else {
        const instrument = labelled && !incoming &&
          (INSTRUMENT_BEFORE.test(before) || INSTRUMENT_LABEL.test(phrase));
        own = (labelled && alone) || (from ? !sender : instrument);
      }
      found.push({ start, end, card, own });
    }
  };
  scan(LABELLED_SUFFIX, true);
  scan(MASKED_SUFFIX, false);
  return found.sort((a, b) => a.start - b.start);
}

/// True when the text reads as a purchase, refund or bill: its counterparty
/// is a merchant (MASK-1). An own card alone does not make "paid to X" a
/// purchase (X-P1): X then keeps only with a business word.
function isMerchantContext(text: string): boolean {
  return PURCHASE_CONTEXT.test(text);
}

/// True when a `from` / `to` / `من` / `إلى` counterparty is a person rather
/// than a merchant: the message reads as a transfer or credit, and NOT as a
/// purchase, refund or bill payment. Decided from the text alone so the device
/// and the server reach the same answer without sharing a parser.
export function isCounterpartyContext(text: string): boolean {
  return TRANSFER_WORDS.test(text) && !PURCHASE_CONTEXT.test(text);
}

// ── Person or merchant: THE DECISION RULE ──────────────────────────────────
//
// 1. A transfer or remittance (STRONG_TRANSFER_WORDS, or a credit word with no
//    purchase, refund or bill word): every counterparty is masked whole, up
//    to the next amount, date, status word, account or reference cue or
//    sentence end. No name lists, no business-word exception (R4P-02).
// 2. A purchase, refund or bill (PURCHASE_CONTEXT), or a card payment (the
//    user's own card and no transfer word): the merchant is kept.
// 3. Payment wording with neither ("Payment of SAR 85 to …", "paid to …",
//    «دفع … إلى …»): the type is unclear, so privacy wins: the payee is
//    masked unless it carries a business-form word (COMPANY_MARKERS), even a
//    one-word brand ("Careem").
// A person cue (beneficiary, sender, «المستفيد», Name:, account of …) masks in
// every message. The device reads the merchant from the raw message, so a
// saved category rule still matches there without the name leaving it.

/// After the bare prepositions "to" and "by", a single lower-case Latin word
/// followed by a determiner is a verb, not a name ("to settle your bill",
/// "by clicking the link"). A name in lower case is still masked ("to fadi
/// via Mada", "to nadir zaki"); a field label ("To:") is not bare.
const BARE_PREPOSITION = /(?<![\p{L}\p{M}])(?:to|by)[ \t]+$/iu;
const LOWER_CASE_WORD = /^\p{Ll}[^ \t]*$/u;
const DETERMINER_AFTER = /^[ \t]+(?:your|the|this|that|these|those|a|an|it|my|our|all|any)(?![\p{L}\p{M}])/iu;
function isOrdinaryWord(cue: string, name: string, after: string): boolean {
  return BARE_PREPOSITION.test(cue) && LOWER_CASE_WORD.test(name) && DETERMINER_AFTER.test(after);
}

/// The cue and `[NAME]`: a person, whatever words the name carries.
function maskPerson(whole: string, cue: string, name: string, offset: number, text: string): string {
  return isOrdinaryWord(cue, name, text.slice(offset + whole.length)) ? whole : `${cue}[NAME]`;
}

/// As [maskPerson], where the text has no transfer word (case 3 of THE
/// DECISION RULE): a name carrying a business-form word is kept.
function maskPayee(whole: string, cue: string, name: string, offset: number, text: string): string {
  return COMPANY_MARKER.test(name) ? whole : maskPerson(whole, cue, name, offset, text);
}

/// As [maskPerson], for the one Latin form with no cue and no verb: only the
/// leading capitalised words are the name, and what follows them stays.
function maskCapitalisedName(whole: string, cue: string, name: string): string {
  const run = name.match(CAPITALISED_RUN)?.[0];
  return run ? `${cue}[NAME]${name.slice(run.length)}` : whole;
}

/// Masks personal names with `[NAME]`, keeping the cue. Salutations and
/// person-only cues always; counterparties only in a transfer/credit context;
/// payees and names with no cue unless the text reads as a purchase.
export function redactPersonNames(text: string): string {
  const greeted = text.replace(SALUTATION_PATTERN, '$1[NAME]')
    // PRIV-1: a person cue names a person in any message.
    .replace(PERSON_CUE_PATTERN, maskPerson)
    .replace(BENEFICIARY_NOTICE_PATTERN, maskPerson)
    .replace(NAME_ADDED_AS_PATTERN, maskPerson)
    .replace(PERSONAL_LABEL_PATTERN, maskPerson)
    .replace(ACCOUNT_OF_PATTERN, maskPerson)
    .replace(ACCOUNT_HOLDER_PATTERN, maskPerson);
  if (isMerchantContext(greeted)) return greeted;
  // PRIV-1: with no purchase, refund, bill or card-payment reading, a "From:"
  // label, "paid to" and a "To <Name>:" heading name a person too.
  const cued = TRANSFER_WORDS.test(greeted)
    ? greeted.replace(COUNTERPARTY_PATTERN, maskPerson)
    : greeted.replace(LABEL_CUE_PATTERN, maskPayee).replace(TO_HEADING_PATTERN, maskPayee)
      .replace(PAYMENT_TO_PATTERN, maskPayee);
  // N-P2: money in from someone, where nothing marks a merchant.
  const incoming = TRANSFER_WORDS.test(greeted) || MERCHANT_MARK.test(cued)
    ? cued
    : cued.replace(INCOMING_FROM_PATTERN, maskPayee);
  return incoming.replace(PAREN_NAME_PATTERN, maskPerson)
    .replace(NAME_BEFORE_VERB_PATTERN, maskPerson)
    .replace(NAME_AFTER_VERB_AR_PATTERN, maskPerson)
    .replace(NAME_AFTER_TRANSFER_PATTERN, maskCapitalisedName);
}

// MASK-0: the run after «إلى»/"To:" is a merchant, and stays, under THE
// DECISION RULE (a purchase reading, or a business word in a text with no
// transfer word) — unless the run
// is an account or card object, starts with a number, or carries a long
// number or a masked name (then it is a person's account whatever the
// message says).
const BENEFICIARY_CUE = /^(?:إلى|الى|to(?:[ \t]+name)?)\s*:?\s*/iu;
const BENEFICIARY_ACCOUNT_OBJECT = new RegExp(
  `(?<!${L})(?:account|accounts|acct|acc|ac|wallet|mobile|phone|number|no|name|حساب|الحساب|حسابات|لحساب|للحساب|محفظة|المحفظة|رقم)(?!${L})` +
    `|^(?:(?:the|a|an)[ \\t]+)?(?:card|cards|بطاقة|البطاقة|بطاقه)(?!${L})` +
    `|\\[(?:NAME|ACCOUNT|IBAN|CARD|PHONE|REF)\\]|^[*xX•#]*${D}|${D}{5}|[A-Z]{2}${D}{2}`,
  'iu',
);
function keepsBeneficiary(match: string, merchantContext: boolean, transfer: boolean): boolean {
  const run = match.replace(BENEFICIARY_CUE, '');
  return !BENEFICIARY_ACCOUNT_OBJECT.test(run) && (merchantContext || (!transfer && COMPANY_MARKER.test(run)));
}

function replaceAt(text: string, spans: { start: number; end: number }[], replacement: string): string {
  let out = text;
  for (const s of [...spans].reverse()) out = out.slice(0, s.start) + replacement + out.slice(s.end);
  return out;
}

/// Third-party names and numbers: personal names (see [redactPersonNames]),
/// the transfer beneficiary after إلى:/الى:/To:, every account or card suffix
/// the text does not mark as the user's own (see THE RULE above), and the
/// personal name after an Arabic greeting.
///
/// Separate from [redactPii] because it is not a digit pattern and because
/// `parse-sms` applied it while `process-ios-sms` and `bank-discovery` did not
/// — a live wire probe against the deployed functions showed
/// "حوالة الى: سارة الاسمري" surviving into `processed_captures.sanitized_text`
/// in full. The shipping clients strip it before sending, so this is the
/// defence-in-depth layer rather than the only one, but a third party never
/// consented to anything here and is not the app's user to trade away.
///
/// Person or merchant is decided from the text alone, identically on the
/// device (Dart), in the Shortcut (Swift) and here: no parser type is used.
export function redactThirdPartyNames(text: string): string {
  const named = redactPersonNames(text);
  const merchantContext = isMerchantContext(named);
  const transfer = TRANSFER_WORDS.test(named);
  const keeps = (whole: string) => keepsBeneficiary(whole, merchantContext, transfer);
  const stripped = named
    // The name only, never the words after it (SM-07, Vso4).
    .replace(BENEFICIARY_AR, (whole, cue) => keeps(whole) ? whole : `${cue}: [REDACTED]`)
    .replace(BENEFICIARY_EN, (whole) => keeps(whole) ? whole : 'To: [REDACTED]')
    .replace(OWN_DESTINATION_NUMBER, '$1[ACCOUNT]')
    .replace(NUMBER_AFTER_NAME, '$1[ACCOUNT]');
  const purchase = PURCHASE_CONTEXT.test(stripped);
  const suffixed = replaceAt(stripped, scanSuffixes(stripped, purchase).filter((s) => !s.own), '[ACCOUNT]');
  const own = new Set(scanSuffixes(suffixed, purchase).filter((s) => s.own).map((s) => s.start));
  return suffixed
    .replace(NUMBER_IN_BENEFICIARY_SENTENCE, (whole, offset) => own.has(offset) ? whole : '[ACCOUNT]')
    .replace(/(عزيزي|عزيزتي)\s+\S+/gi, '[REDACTED]');
}

/// The sender ID as it may appear in an AI prompt (bank-discovery only;
/// parse-sms and process-ios-sms never put the sender in a prompt).
///
/// An ALPHANUMERIC sender ("AlRajhiBank", "NBE", "STCBANK") is the brand the
/// bank registered with the carrier: it identifies a business, not a person,
/// and for an UNKNOWN bank it is the only reliable signal the model has, so it
/// is kept (and disclosed). A sender that is a phone number or a digits-only
/// short code identifies no bank and may identify a person, so it never
/// reaches the model. Any digit runs inside an alphanumeric sender still go
/// through the PII floor.
export function redactSenderForAi(senderId: string): string {
  const s = senderId.trim();
  const phoneLike = new RegExp(`^\\+?${D}[0-9\\u0660-\\u0669\\u06F0-\\u06F9\\s\\-()]{5,}$`).test(s);
  const hasLetters = /\p{L}/u.test(s);
  if (!s || phoneLike || !hasLetters) return '[NUMERIC_SENDER]';
  return redactPii(s);
}
