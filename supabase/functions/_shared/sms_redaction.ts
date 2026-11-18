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
  `((?<![\\p{L}\\p{M}])(?:account|acct|a\\/c|ac|حساب|الحساب|لحساب|للحساب|بحساب|حسابك|لحسابك|حسابكم|حسابي)` +
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
  return text
    .replace(EMAIL_PATTERN, '[EMAIL]')
    .replace(SPACED_IBAN_PATTERN, '[IBAN]')
    .replace(CARD_PATTERN, '[CARD]')
    .replace(SAUDI_PHONE_PATTERN, '[PHONE]')
    .replace(EGYPT_PHONE_PATTERN, '[PHONE]')
    .replace(INTL_PHONE_PATTERN, '[PHONE]')
    .replace(IBAN_PATTERN, '[IBAN]')
    .replace(OTP_PATTERN, '$1[OTP]')
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
// A one-letter stopword before ". Name" is an initial («A. Ali Hassan»).
const NAME_TOKEN = `(?!(?:${NAME_STOPWORDS.join('|')})(?![\\p{L}\\p{M}*'’\\-]|\\.[\\p{L}\\p{M}]|(?<=(?<![\\p{L}\\p{M}])\\p{L})\\.[ \\t]+\\p{L}))` +
  // A lone star before digits is a masked number, not a masked name.
  `(?!\\*+${D})[\\p{L}\\p{M}*](?:[\\p{L}\\p{M}*'’\\-]|(?!${SENTENCE_END})\\.)*(?![\\p{L}\\p{M}*'’\\-]|${D})`;
const NAME = `${NAME_TOKEN}(?:[ \\t]+${NAME_TOKEN}){0,5}`;

// The beneficiary after «إلى»/«الى»/"To:": the letter tokens of the name (and
// the account or card object before it), never a tense, status, amount,
// currency or date word, an amount, a date or the next sentence (Vso4:
// «إلى حساب 7788 سينفذ غدا» keeps «سينفذ غدا»). An initial or title keeps its
// period so the rest of the name is still masked.
const BENEFICIARY_STOP = NAME_STOPWORDS.filter((w) => !BENEFICIARY_OBJECT_WORDS.has(w));
const BENEFICIARY_TOKEN = `(?!(?:${BENEFICIARY_STOP.join('|')})(?![\\p{L}\\p{M}*'’\\-]|\\.[\\p{L}\\p{M}]))` +
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
const BENEFICIARY_PART = `(?:${BENEFICIARY_ID}|${BENEFICIARY_TOKEN})`;
const BENEFICIARY_RUN = `(?:\\[NAME\\]|${BENEFICIARY_PART})(?:[ \\t]+${BENEFICIARY_PART})*`;
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
const NUMBER_IN_BENEFICIARY_SENTENCE = new RegExp(
  `(?<![A-Za-z0-9\u0660-\u0669\u06F0-\u06F9*•#]|${D}[.,\u066B\u066C/:\\-])` +
    `(?![*xX•#]*${D}{1,4}(?!${D}|-${D})(?<=${OWN_WORD}[ \\t]+[*xX•#]*${D}+))` +
    `(?!${D}{1,2}[ \\t]+(?:${MONTH.join('|')})(?![\\p{L}\\p{M}]))` +
    `(?<!(?<![\\p{L}\\p{M}])${CURRENCY_WORD}[ \\t]*)` +
    `(?:[A-Z]{2}(?=${D}))?[*xX•#]*${D}+(?:-${D}+)*` +
    `(?![0-9A-Za-z\u0660-\u0669\u06F0-\u06F9]|[.,\u066B\u066C/:\\-]${D}|[ \\t]*${CURRENCY_WORD}(?![ \\t]*${D}))` +
    `(?<=(?:إلى|الى|\\bTo(?:[ \\t]+name)?\\s*:)(?:(?!${SENTENCE_END}).)*)`,
  'giu',
);
const CUE_SEP = `(?:[ \\t]*:[ \\t]*|[ \\t]+)`;

/// Salutations — a name follows by definition, in any kind of message.
/// English greetings only at the start of the text or of a sentence, so a
/// merchant such as "DEAR DIARY CAFE" after "Purchase at" is not one.
const SALUTATION_PATTERN = new RegExp(
  `((?:(?<![\\p{L}\\p{M}])(?:عزيزي|عزيزتي|السيدة|السيد|الأستاذة|الاستاذة|الأستاذ|الاستاذ)` +
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
    `|من[ \\t]+قبل|اسم[ \\t]+المستفيد|اسم[ \\t]+المرسل|المستفيد|مستفيد|المرسل|المحول|لصالح|باسم|بواسطة|من|إلى|الى|الي)` +
    `\\.?(?![\\p{L}\\p{M}])${CUE_SEP})(${NAME})`,
  'giu',
);

const TRANSFER_CONTEXT =
  /transfer|remit|received|credited|deposit|\bipn\b|instapay|beneficiary|\bsent\b|standing\s+order|حوال|تحويل|حول|وارد|استلام|استلمت|إيداع|ايداع|أودع|اودع|مستفيد|المرسل|انستا|لصالح|أمر\s+(?:مستديم|دائم)|امر\s+(?:مستديم|دائم)/iu;
const PURCHASE_CONTEXT =
  /purchase|\bpos\b|point of sale|paid at|spent|refund|revers|e-?commerce|\bbill|merchant|شراء|مشتريات|نقاط البيع|نقطة بيع|نقاط بيع|استرداد|مسترد|مرتجع|إرجاع|ارجاع|فاتور|سداد|تاجر/iu;

/// True when a `from` / `to` / `من` / `إلى` counterparty is a person rather
/// than a merchant: the message reads as a transfer or credit, and NOT as a
/// purchase, refund or bill payment. Decided from the text alone so the device
/// and the server reach the same answer without sharing a parser.
export function isCounterpartyContext(text: string): boolean {
  return TRANSFER_CONTEXT.test(text) && !PURCHASE_CONTEXT.test(text);
}

/// Masks personal names with `[NAME]`, keeping the cue. Salutations always;
/// counterparties only in a transfer/credit context.
export function redactPersonNames(text: string): string {
  const greeted = text.replace(SALUTATION_PATTERN, '$1[NAME]');
  return isCounterpartyContext(greeted) ? greeted.replace(COUNTERPARTY_PATTERN, '$1[NAME]') : greeted;
}

/// Third-party names: personal names (see [redactPersonNames]), the transfer
/// beneficiary after إلى:/الى:/To:, and the personal name after an Arabic
/// greeting.
///
/// Separate from [redactPii] because it is not a digit pattern and because
/// `parse-sms` applied it while `process-ios-sms` and `bank-discovery` did not
/// — a live wire probe against the deployed functions showed
/// "حوالة الى: سارة الاسمري" surviving into `processed_captures.sanitized_text`
/// in full. The shipping clients strip it before sending, so this is the
/// defence-in-depth layer rather than the only one, but a third party never
/// consented to anything here and is not the app's user to trade away.
///
/// Note the asymmetry with the Dart sanitizer, which KEEPS this content for a
/// detected `payment` because a merchant is a business, not a person. The
/// server cannot make that distinction: it redacts before parsing, so it has no
/// type to condition on. Stripping unconditionally is the same choice
/// `parse-sms` has always made — over-redact rather than leak a person.
export function redactThirdPartyNames(text: string): string {
  return redactPersonNames(text)
    // The name only, never the words after it (SM-07, Vso4).
    .replace(BENEFICIARY_AR, '$1: [REDACTED]')
    .replace(BENEFICIARY_EN, 'To: [REDACTED]')
    .replace(OWN_DESTINATION_NUMBER, '$1[ACCOUNT]')
    .replace(NUMBER_IN_BENEFICIARY_SENTENCE, '[ACCOUNT]')
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
