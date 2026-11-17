// Deterministic, side-effect-free gate for an AI parse candidate (server twin of
// app/lib/engine/ai/ai_candidate_validator.dart). It never reads anything that
// resembles an AI confidence. The two implementations are pinned to each other
// by _shared/fixtures/ai_candidate_cases.json (run by BOTH test suites).
//
// Known, spec-mandated differences from the app (NOT covered by the shared
// fixtures, see ai_candidate_validator_test.ts):
//  - server additionally requires the AI currency to be on CURRENCY_CODES;
//  - server additionally rejects an AI `direction` field that contradicts the
//    message wording (the app only checks the normalized type);
//  - server additionally requires amount and amount_text to agree;
//  - amount_text must be ASCII-canonical (the app's parser also accepts
//    Arabic-Indic digits);
//  - the amount and amount_text must each be a whole numeric token of the
//    text (not part of a date, time, card/account number or larger number).
import { canonicalMoneyText } from './money_text.ts';
import rules from '../process-ios-sms/parser_rules.json' with { type: 'json' };

export const CURRENCY_CODES = ['SAR', 'AED', 'EGP', 'QAR', 'OMR', 'KWD', 'BHD', 'JOD', 'USD', 'EUR', 'GBP', 'JPY'];

export interface AiCandidate {
  amount?: number;
  amount_text?: string;
  currency?: string;
  merchant?: string;
  type?: string;
  direction?: string;
  category?: string;
  last4?: string;
  occurred_at?: string;
}

export interface LocalCandidate {
  amount: number;
  amount_text?: string;
  currency: string;
  direction?: string;
  merchant?: string;
}

export type AiCandidateValidation =
  | { accepted: false; reason: string }
  | {
    accepted: true;
    currency: string;
    /** Canonical exact amount text. */
    amountText: string;
    /** AI merchant when grounded, else the local one (or null). */
    merchant: string | null;
    /** AI date (ISO) when inside the plausibility window, else null. */
    occurredAt: string | null;
  };

const MAX_AGE_MS = 31 * 24 * 60 * 60 * 1000;
const MAX_FUTURE_MS = 24 * 60 * 60 * 1000;

// ── Direction wording (port of app DirectionSignal) ──────────────────────────
export type WordDirection = 'credit' | 'debit' | 'unknown';

const CREDIT_WORDS = [
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
  'راتب',
  'deposit',
  'salary',
  'credited',
  'received',
  'incoming',
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
const DEBIT_WORDS = [
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

export function directionOfWording(text: string): WordDirection {
  const lower = text.toLowerCase();
  const hasCredit = CREDIT_WORDS.some((w) => lower.includes(w));
  const hasDebit = DEBIT_WORDS.some((w) => lower.includes(w));
  if (hasCredit && !hasDebit) return 'credit';
  if (hasDebit && !hasCredit) return 'debit';
  return 'unknown';
}

export function directionOfType(type: string | undefined): WordDirection {
  switch (type) {
    case 'income':
    case 'refund':
      return 'credit';
    case 'payment':
    case 'withdrawal':
      return 'debit';
    default:
      return 'unknown';
  }
}

function asDirection(value: string | undefined): WordDirection {
  return value === 'credit' || value === 'debit' ? value : 'unknown';
}

function contradicts(wording: WordDirection, other: WordDirection): boolean {
  return wording !== 'unknown' && other !== 'unknown' && wording !== other;
}

/** True when an AI direction/type would contradict the message's own wording. */
export function directionContradictsWording(text: string, type?: string, direction?: string): boolean {
  const wording = directionOfWording(text);
  return contradicts(wording, directionOfType(type)) || contradicts(wording, asDirection(direction));
}

// ── Amount grounding (port of app GroundingCheck) ────────────────────────────
const ARABIC_INDIC_DIGIT = /[٠-٩]/g;

// A numeric token is a maximal digit run with digit-flanked group/decimal
// separators (ASCII or Arabic), so a longer number never yields a sub-token.
const NUMERIC_TOKEN = /[0-9٠-٩]+(?:[,٬،.٫][0-9٠-٩]+)*/g;

// Digits that belong to a date/time/identifier rather than an amount.
const DATE_TIME_SEP_BEFORE = /[0-9٠-٩][-/:]$/;
const DATE_TIME_SEP_AFTER = /^[-/:][0-9٠-٩]/;
const LAST4_PREFIX =
  /(?:[*•xX]|(?:ending|ends|acct|account|a\/c|card|بطاقة|حساب|رقم|تنتهي|منتهية)(?:\s+(?:in|with|no\.?|number|#|بـ|ب))?[\s:#.-]*)$/i;

function canonicalTokenText(token: string): string | null {
  const ascii = token
    .replace(ARABIC_INDIC_DIGIT, (d) => String(d.charCodeAt(0) - 0x0660))
    .replaceAll('٬', ',')
    .replaceAll('،', ',') // Arabic comma between digits (V1-057)
    .replaceAll('٫', '.');
  return canonicalMoneyText(ascii);
}

/** Canonical text of every standalone numeric token that may be an amount. */
export function amountTokens(text: string): string[] {
  const out: string[] = [];
  for (const m of text.matchAll(NUMERIC_TOKEN)) {
    const before = text.slice(0, m.index);
    const after = text.slice(m.index + m[0].length);
    if (DATE_TIME_SEP_BEFORE.test(before) || DATE_TIME_SEP_AFTER.test(after)) continue;
    if (LAST4_PREFIX.test(before)) continue;
    const canonical = canonicalTokenText(m[0]);
    if (canonical != null) out.push(canonical);
  }
  return out;
}

export function amountGrounded(amount: unknown, text: string): boolean {
  if (typeof amount !== 'number' || !Number.isFinite(amount) || amount <= 0) return false;
  return amountTokens(text).some((t) => Math.abs(Number(t) - amount) < 0.005);
}

/** True when the (canonical) amount_text is a whole numeric token of the text. */
export function amountTextGrounded(amountText: string, text: string): boolean {
  return amountTokens(text).includes(amountText);
}

// ── Currency grounding (port of app Normalizer.normalizeCurrencyTokens) ──────
const CURRENCY_TOKEN_RULES: Array<[RegExp, string]> = [
  [/ر\.س\.?/gi, 'SAR'],
  [/ر\.ع\.?/gi, 'OMR'],
  [/ر\.ق\.?/gi, 'QAR'],
  [/د\.إ\.?/gi, 'AED'],
  [/د\.ك\.?/gi, 'KWD'],
  [/د\.ب\.?/gi, 'BHD'],
  [/ج\.م\.?/gi, 'EGP'],
  [/﷼/g, 'SAR'],
  [/ريال\s+سعودي/g, 'SAR'],
  [/ريال\s+قطري/g, 'QAR'],
  [/ريال\s+عماني/g, 'OMR'],
  [/درهم\s+إماراتي|درهم\s+اماراتي|درهم/g, 'AED'],
  [/جنيه\s+مصري|جنيه/g, 'EGP'],
  [/دينار\s+كويتي/g, 'KWD'],
  [/دينار\s+بحريني/g, 'BHD'],
  [/دولار\s+أمريكي|دولار\s+امريكي|دولار/g, 'USD'],
  [/ريال/g, 'SAR'],
];

const EXTRA_ALIASES: Record<string, string[]> = {
  USD: ['$'],
  EUR: ['€'],
  GBP: ['£'],
  JOD: ['دينار أردني', 'دينار اردني'],
};

export function normalizeCurrencyTokens(input: string): string {
  let out = input;
  for (const [re, to] of CURRENCY_TOKEN_RULES) out = out.replace(re, to);
  return out;
}

function currencyGrounded(iso: string, text: string): boolean {
  if (!iso) return false;
  const code = new RegExp(`(?<![A-Za-z])${iso}(?![A-Za-z])`, 'i');
  if (code.test(normalizeCurrencyTokens(text))) return true;
  return (EXTRA_ALIASES[iso] ?? []).some((a) => text.includes(a));
}

// ── Text grounding for merchant / last4 ──────────────────────────────────────
function collapse(value: string): string {
  return value.toLowerCase().replace(/\s+/g, ' ').trim();
}

/// A placeholder the sanitizer wrote (`[NAME]`, `[CARD]` …) is grounded in the
/// text by construction but is never a merchant.
export const REDACTION_PLACEHOLDER = /\[(?:CARD|PHONE|ACCOUNT|IBAN|OTP|REDACTED|NAME|REF|EMAIL)\]/i;

export function merchantGrounded(merchant: string | undefined | null, text: string): boolean {
  if (typeof merchant !== 'string') return false;
  if (REDACTION_PLACEHOLDER.test(merchant)) return false;
  const needle = collapse(merchant);
  return needle.length > 0 && collapse(text).includes(needle);
}

export function last4Grounded(last4: string | undefined | null, text: string): boolean {
  return typeof last4 === 'string' && /^[0-9]{4}$/.test(last4) && text.includes(last4);
}

function inWindow(iso: string | undefined, receivedAt: string): string | null {
  if (typeof iso !== 'string' || !iso.trim()) return null;
  const clean = iso.trim();
  const zoned = /(?:z|[+-]\d{2}:?\d{2})$/i.test(clean) ? clean : `${clean}Z`;
  const at = new Date(zoned).getTime();
  const ref = new Date(receivedAt).getTime();
  if (Number.isNaN(at) || Number.isNaN(ref)) return null;
  const delta = at - ref;
  return delta >= -MAX_AGE_MS && delta <= MAX_FUTURE_MS ? new Date(at).toISOString() : null;
}

// ── Not a money movement (LR-04 / LR-06; port of app ParserEngine) ─────────
// A Latin ignore word counts only as a whole word with an optional
// plural/inflection ending ("offers", "promotional"), so "Hotpot" is not an
// OTP; Arabic phrases and URL prefixes match by substring
// (ParserEngine.containsIgnoreWord).
const IGNORE_SUFFIX = '(?:s|es|al|ed|ing)?';
const ignoreWordPatterns = new Map<string, RegExp>();
export function containsIgnoreWord(lower: string, keyword: string): boolean {
  const k = keyword.toLowerCase();
  if (!/[a-z]/.test(k) || k.includes('://')) return lower.includes(k);
  let re = ignoreWordPatterns.get(k);
  if (!re) {
    re = new RegExp(`(?<![a-z])${k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}${IGNORE_SUFFIX}(?![a-z])`);
    ignoreWordPatterns.set(k, re);
  }
  return re.test(lower);
}

/**
 * [lower] without the merchant span (up to the first card mask, sentence or
 * clause end): an ignore word inside it is part of a name ("Offer Mart"), not
 * an advert. Mirrors ParserEngine.outsideMerchant.
 */
export function outsideMerchant(lower: string, merchant: string | undefined | null): string {
  if (typeof merchant !== 'string') return lower;
  const span = merchant.toLowerCase().split(/[*;!?\n،,]|\.(?=\s|$)/)[0].trim();
  if (!span) return lower;
  const at = new RegExp(`(?<![a-z\u0621-\u064a])${span.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`).exec(lower)?.index;
  return at == null ? lower : lower.slice(0, at) + ' ' + lower.slice(at + span.length);
}

// An OTP message carries its code ("OTP is 123456", "Use 482913 as OTP",
// "Enter code 482913", "رمز التحقق: 4821"); a security footer on a purchase
// ("Never share your OTP") does not. Mirrors ParserEngine._otpCode.
const CODE_PURPOSE = '(?:for (?:the |your |an? )?(?:purchase|payment|online|transaction|' +
  'sar|usd|aed|egp|eur|gbp)|to (?:pay|confirm|approve|complete|verify|authori[sz]e))';
export const OTP_CODE = new RegExp(
  '(?:otp|one time password|verification code|security code|passcode|' +
    'رمز الدخول|رمز التحقق|كود التحقق)' +
    '(?:[^\n]{0,40}?(?:\\bis\\b|هو))?\\s*:?\\s*[0-9]{4,8}(?![0-9])' +
    '|(?<![0-9*x#.,])[0-9]{4,8} (?:is|هو) [^\n0-9]{0,25}' +
    '(?:otp|one time password|verification code|security code|passcode|' +
    'رمز|كود|code to (?:confirm|approve|complete|verify|authori[sz]e))' +
    '|(?:otp|one time password|verification code|security code|passcode|' +
    'رمز الدخول|رمز التحقق|كود التحقق)(?:[^\n.!?]|\\.(?=[0-9])){0,60}?:\\s*' +
    '[0-9]{4,8}(?![0-9.,])' +
    '|(?<![0-9*x#.,])[0-9]{4,8} as (?:the |your |an? )?' +
    '(?:otp|one time password|verification code|security code|passcode|code)' +
    '|(?:enter|use|input) (?:the |your )?(?:otp|passcode)\\s*:?\\s*' +
    '[0-9]{4,8}(?![0-9])' +
    // NR-06: "Enter code 482913 to approve …", not "Use code 482913 for your
    // next order" / "Enter code 482913 at the counter".
    '|(?:enter|use|input) (?:the |your )?code\\s*:?\\s*[0-9]{4,8}[^\n.]{0,20}? to ' +
    '(?:pay|confirm|approve|complete|verify|authori[sz]e)' +
    // OR-05: a purchase code named as such, with no "OTP".
    '|(?<![0-9*x#.,])[0-9]{4,8} is (?:your|the) (?:[a-z]+ ){0,2}code ' + CODE_PURPOSE +
    '|code(?: is)?\\s*:?\\s*[0-9]{4,8}(?![0-9])[:,]?\\s*' +
    '(?:' + CODE_PURPOSE + '|confirm (?:the |your )?(?:payment|purchase|transaction))' +
    '|code\\s*:?\\s*[0-9]{4,8}\\.?\\s+(?:valid|expires)' +
    '|(?:الرمز|رمزك|رمز|الكود|كود)\\s*:?\\s*[0-9]{4,8}\\s+ل',
);

// PR-05: a code that authorises a payment (OTP_CODE), unless it is only
// mentioned after a completed transaction sentence ("Purchase SAR 250.00 at
// SHOPX. Pickup code 4829. Valid until 18:00"): a sentence before the code
// with an amount and a money word. Mirrors ParserEngine.isPurchaseCode.
export function isPurchaseCode(lower: string): boolean {
  const m = OTP_CODE.exec(lower);
  if (!m) return false;
  const prefix = lower.slice(0, m.index);
  const cuts = [...prefix.matchAll(/[\n!?؟]|\.(?![0-9])/g)];
  if (cuts.length === 0) return true;
  const last = cuts[cuts.length - 1];
  const done = prefix.slice(0, last.index! + last[0].length);
  return !(/[0-9]/.test(done) && hasMoneyWord(done));
}

// OR-03: a figure introduced by a limit, balance, remaining, outstanding or
// minimum-due label (English and Arabic) is never the transaction amount
// (mirrors the balance / limit labels of ParserEngine._classifyAmountCandidate).
// The label may be followed by up to 32 characters that do not introduce an
// amount or name a movement ("Available Credit Limit: SAR 9,000.00", "حد البطاقة 20,000 ريال").
export const LABELLED_FIGURE = new RegExp(
  '(?<![a-z\u0621-\u064a])[وبل]?(?:credit limit|card limit|limit|available limit|payment due|' +
    'available balance|available|balance|avl bal|bal\\.?|remaining|outstanding|' +
    'minimum due|minimum payment|minimum amount|min\\.? due|amount due|due amount|total due|' +
    'الحد|حد الائتمان|حد ائتماني|حد البطاقة|حد الشراء|حد السحب|حد التحويل|حد العمليات|موعد سداد|' +
    'الرصيد|رصيد|المتبقي|المستحق|المتاح)(?![a-z])' +
    '(?:(?!مبلغ|بقيمة|amount|amt|debited|credited|deducted|paid|transfer|خصم|تحويل|إيداع|ايداع)[^0-9\n|;]){0,32}[0-9][0-9,]*(?:\\.[0-9]+)?',
  'gi',
);

// PR-03: a labelled figure is the transaction amount when a completed
// movement in the same clause acts on it: a verb before the label ("تم سداد
// المبلغ المستحق 500", "Debited from your balance SAR 75"), an English verb
// between the label and the figure ("Outstanding amount settled SAR 1,200")
// or right after the figure ("Minimum payment SAR 115.00 has been paid"),
// with no other number in between. Mirrors
// ParserEngine.movementActsOnFigure.
const CLAUSE_CUT = /[\n;!?؟؛،]|, |\.(?![0-9])/g;
const MOVEMENT_LATIN = [
  'paid', 'settled', 'received', 'debited', 'deducted', 'charged',
  'transferred', 'credited', 'withdrawn', 'collected', 'recharged',
  'recharge', 'top up', 'topped up',
];
const MOVEMENT_ARABIC = [
  'سداد', 'سدد', 'خصم', 'خُصم', 'شراء', 'شحن', 'دفع', 'تحويل', 'قيد',
  'إيداع', 'ايداع', 'استلام', 'سحب',
];
function latinVerb(s: string): boolean {
  return MOVEMENT_LATIN.some((v) => new RegExp(`(?<![a-z])${v}(?![a-z])`).test(s));
}
export function movementActsOnFigure(l: string, labelAt: number, start: number, end: number): boolean {
  let cs = 0;
  let ce = l.length;
  for (const m of l.matchAll(CLAUSE_CUT)) {
    const ms = m.index!, me = ms + m[0].length;
    if (me <= start) cs = me;
    if (ms >= end && ce === l.length) ce = ms;
  }
  if (labelAt < cs) labelAt = cs;
  if (latinVerb(l.slice(end, ce).split(/[0-9]/)[0])) return true;
  const head = l.slice(cs, start);
  const lastDigit = head.search(/[0-9][^0-9]*$/);
  const free = lastDigit < 0 ? cs : cs + lastDigit + 1;
  if (labelAt >= free && latinVerb(l.slice(labelAt, start))) return true;
  // "after <Arabic verb>" ("رصيدك بعد إيداع 1,000"), not "موعد سداد".
  if (labelAt >= free) {
    const mid = l.slice(labelAt, start);
    if (MOVEMENT_ARABIC.some((v) => mid.includes(`بعد ${v}`))) return true;
  }
  if (labelAt <= free) return false;
  const before = l.slice(free, labelAt);
  return latinVerb(before) || MOVEMENT_ARABIC.some((v) => before.includes(v));
}

/** [text] with every labelled account figure (LABELLED_FIGURE) that no
 * completed movement acts on (movementActsOnFigure) blanked out. */
export function maskAccountFigures(text: string): string {
  const lower = text.toLowerCase();
  return text.replace(LABELLED_FIGURE, (m: string, offset: number) => {
    const numAt = offset + m.search(/[0-9][0-9,]*(?:\.[0-9]+)?$/);
    return movementActsOnFigure(lower, offset, numAt, offset + m.length) ? m : ' ';
  });
}

export const NON_TRANSACTION_KEYWORDS = rules.nonTransactionKeywords as string[];
export const NOTICE_KEYWORDS = rules.noticeKeywords as string[];
const MONEY_KEYWORDS = (rules.moneyKeywords as string[]).map((w) =>
  /[a-z]/.test(w)
    ? ((lower: string) => new RegExp(`(?<![a-z])${w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![a-z])`).test(lower))
    : ((lower: string) => lower.includes(w))
);

/**
 * NR-01: [lower] names a money movement anywhere (a moneyKeywords word: Latin
 * as a whole word, Arabic by substring). Mirrors ParserEngine.hasMoneyWord.
 */
export function hasMoneyWord(lower: string): boolean {
  // Without tashkeel ("قُيّد مبلغ", "سُحب"), as the device's Normalizer.
  const plain = lower.replace(/[\u064B-\u0670\u065F]/g, '');
  return MONEY_KEYWORDS.some((matches) => matches(plain));
}

/**
 * The message is not a money movement: an OTP code, or an ignore word or
 * account notice (ignoreKeywords, nonTransactionKeywords, noticeKeywords) outside [merchant]
 * in a message that names no money movement anywhere (NR-02: "Available
 * credit limit" on a purchase does not count). Mirrors
 * ParserEngine.isNonTransactionText.
 */
export function isNonTransactionText(text: string, merchant?: string | null): boolean {
  const lower = text.replace(ARABIC_INDIC_DIGIT, (d) => String(d.charCodeAt(0) - 0x0660)).toLowerCase();
  if (OTP_CODE.test(lower)) return true;
  const outside = outsideMerchant(lower, merchant);
  return [...(rules.ignoreKeywords as string[]), ...NON_TRANSACTION_KEYWORDS, ...NOTICE_KEYWORDS]
    .some((w) => containsIgnoreWord(outside, w)) && !hasMoneyWord(lower);
}
export function validateAiCandidate(input: {
  candidate: AiCandidate;
  sanitizedText: string;
  receivedAt: string;
  local: LocalCandidate | null;
}): AiCandidateValidation {
  const { candidate: c, sanitizedText: text, local } = input;
  const reject = (reason: string): AiCandidateValidation => ({ accepted: false, reason });

  // LR-06 — an OTP or an advert / account notice is never a transaction,
  // whatever the model says.
  if (isNonTransactionText(text, merchantGrounded(c.merchant, text) ? c.merchant : null)) {
    return reject('not_a_transaction');
  }
  if (!amountGrounded(c.amount, text)) return reject('amount_not_grounded');
  // OR-03 — a limit, balance or minimum-due figure is never the amount.
  const ascii = text.replace(ARABIC_INDIC_DIGIT, (d) => String(d.charCodeAt(0) - 0x0660));
  if (!amountGrounded(c.amount, maskAccountFigures(ascii))) return reject('amount_is_account_figure');
  const amount = c.amount as number;
  const currency = (c.currency ?? '').trim().toUpperCase();
  if (local) {
    if (!(Math.abs(amount - local.amount) < 0.01)) return reject('amount_mismatch_local');
    if (currency !== local.currency.trim().toUpperCase()) return reject('currency_mismatch_local');
  } else {
    if (!CURRENCY_CODES.includes(currency)) return reject('currency_not_whitelisted');
    if (!currencyGrounded(currency, text)) return reject('currency_not_grounded');
  }

  if (typeof c.amount_text !== 'string') return reject('amount_text_missing');
  const amountText = canonicalMoneyText(c.amount_text, currency);
  if (amountText == null) return reject('amount_text_not_canonical');
  if (!(Math.abs(Number(amountText) - amount) < 0.01)) return reject('amount_text_mismatch');
  if (!amountTextGrounded(amountText, text)) return reject('amount_text_not_grounded');

  if (directionContradictsWording(text, c.type, c.direction)) return reject('direction_contradiction');
  // Direction is required (ValidatedCapture v1): resolved as process-ios-sms does,
  // from the deterministic direction, else the AI direction, else the AI type.
  if (
    asDirection(local?.direction) === 'unknown' && asDirection(c.direction) === 'unknown' &&
    directionOfType(c.type) === 'unknown'
  ) return reject('direction_unresolved');

  const merchant = merchantGrounded(c.merchant, text) ? (c.merchant as string) : (local?.merchant ?? null);
  return {
    accepted: true,
    currency,
    amountText,
    merchant,
    occurredAt: inWindow(c.occurred_at, input.receivedAt),
  };
}
