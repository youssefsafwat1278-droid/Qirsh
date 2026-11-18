// Deterministic, side-effect-free gate for an AI parse candidate (server twin of
// app/lib/engine/ai/ai_candidate_validator.dart). It never reads anything that
// resembles an AI confidence. The two implementations are pinned to each other
// by _shared/fixtures/ai_candidate_cases.json (run by BOTH test suites).
//
// Known, spec-mandated differences from the app (NOT covered by the shared
// fixtures, see ai_candidate_validator_test.ts):
//  - server additionally requires the AI currency to be on CURRENCY_CODES
//    (the parser currency table limited to persistable codes);
//  - server additionally rejects an AI `direction` field that contradicts the
//    message wording (the app only checks the normalized type);
//  - server additionally requires amount and amount_text to agree;
//  - amount_text must be ASCII-canonical (the app's parser also accepts
//    Arabic-Indic digits);
//  - the amount and amount_text must each be a whole numeric token of the
//    text (not part of a date, time, card/account number or larger number).
import { canonicalMoneyText } from './money_text.ts';
import rules from '../process-ios-sms/parser_rules.json' with { type: 'json' };

// Round 3 closure: the parser's currency table (parser_rules.json
// currencyTable), limited to the codes persisted Money can hold
// (CURRENCY_MINOR_UNITS). App twin: AiCandidateValidator.currencyCodes /
// kCaptureCurrencyCodes. Drift test: _shared/ai_currency_table_drift_test.ts.
const CURRENCY_TABLE = rules.currencyTable as { core: string[]; iso: string[]; localForms: string[][] };
/// ISO-4217 minor units of the currencies recognised in message text — equal
/// to the app's DETECTION registry `kDetectionCurrencyScale`
/// (app/lib/domain/finance/currency_scale.dart), not its ISO-wide storage table.
export const CURRENCY_SCALE: Readonly<Record<string, number>> = {
  KWD: 3, BHD: 3, OMR: 3, JOD: 3, TND: 3, LYD: 3, IQD: 3,
  JPY: 0, KRW: 0, ISK: 0, CLP: 0, VND: 0, XAF: 0, XOF: 0,
  UGX: 0, RWF: 0, DJF: 0, GNF: 0, PYG: 0, KMF: 0,
  SAR: 2, AED: 2, EGP: 2, QAR: 2, ILS: 2, LBP: 2, SYP: 2,
  MAD: 2, MRU: 2, DZD: 2, SDG: 2, YER: 2, SOS: 2, TRY: 2,
  USD: 2, EUR: 2, GBP: 2, INR: 2, PKR: 2, BDT: 2, PHP: 2,
  IDR: 2, MYR: 2, SGD: 2, NGN: 2, KES: 2, ZAR: 2, ETB: 2,
  GHS: 2, TZS: 2,
};
export const CURRENCY_CODES: readonly string[] = CURRENCY_TABLE.iso.filter((c) => c in CURRENCY_SCALE);

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
    /** Where the currency came from (4.4: account_context is recorded). */
    currencySource: 'message' | 'local' | 'account_context';
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

// Closure round (parser meaning, §5): the clause structure decides first —
// the earliest debit/credit flow phrase (messageMeaning.debitFlow/creditFlow),
// as DirectionSignal.flowOf / message_meaning.flowOf. "SAR 500 deposited to
// beneficiary Ali from your account" is a debit, "Purchase … at Refund Mart"
// carries no flow and falls back to the word families. Mirrored here (not
// imported) because message_meaning.ts imports this module.
const MEANING = rules.messageMeaning as Record<string, string[]>;
const flowEsc = (w: string) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const flowPattern = (words: string[]) =>
  new RegExp(`(?<![a-zء-ي])[وفب]?(?:${[...words].sort((a, b) => b.length - a.length).map(flowEsc).join('|')})(?![a-z])`);
const DEBIT_FLOW_RE = flowPattern(MEANING.debitFlow);
const CREDIT_FLOW_RE = flowPattern(MEANING.creditFlow);

// A flow phrase followed by points/miles moves rewards, not money ("credited
// points 45"); نقاط البيع (point of sale) is not skipped. Same rule as
// message_meaning.firstMoneyFlow / DirectionSignal._firstMoneyFlow (parser
// follow-up 2); ai_direction_flow_test.ts checks directionOfFlow === flowOf.
const POINTS_AFTER = /^\s*(?:(?:reward|loyalty|bonus)\s+)?(?:points|miles)(?![a-z])|^\s*(?:ال)?نقاط(?!\s*البيع)|^\s*نقطة/;

function firstMoneyFlow(re: RegExp, lower: string): RegExpExecArray | null {
  for (const m of lower.matchAll(new RegExp(re.source, re.flags + 'g'))) {
    if (!POINTS_AFTER.test(lower.slice(m.index! + m[0].length))) return m as RegExpExecArray;
  }
  return null;
}

export function directionOfFlow(text: string): WordDirection {
  const lower = text.toLowerCase();
  const d = firstMoneyFlow(DEBIT_FLOW_RE, lower);
  let c = firstMoneyFlow(CREDIT_FLOW_RE, lower);
  if (c && !d && c[0] === 'received') {
    const sentence = lower.split(/[\n!?؟;؛]|\.(?![0-9])/).find((x) => x.includes('received')) ?? '';
    const before = sentence.slice(0, sentence.indexOf('received'));
    if (/(?<![a-z])payment(?![a-z])/.test(before) && !/(?<![a-z])from(?![a-z])/.test(sentence)) c = null;
  }
  if (!d && !c) return 'unknown';
  if (!c) return 'debit';
  if (!d) return 'credit';
  const credit = c.index < d.index || (c.index === d.index && c.index + c[0].length >= d.index + d[0].length);
  if (credit && MEANING.sourceOfFunds.some((w) => lower.includes(w)) &&
    !MEANING.ownDestination.some((w) => lower.includes(w))) return 'debit';
  return credit ? 'credit' : 'debit';
}

// A bare "إلى حسابك" with no verb never decides (DirectionSignal.detect).
const CREDIT_VERB_FLOW_RE = flowPattern(MEANING.creditFlow.filter((w) => w !== 'إلى حسابك' && w !== 'الى حسابك'));

/**
 * [clause] (default: the whole text) is where the flow is read: the
 * sentence(s) that carry the booked amount, so a cashback or footer sentence
 * never decides the purchase's direction. The word families still read the
 * whole text when the clause has no flow phrase.
 */
export function directionOfWording(text: string, clause: string = text): WordDirection {
  const flow = directionOfFlow(clause);
  const bareDestination = flow === 'credit' && !firstMoneyFlow(DEBIT_FLOW_RE, clause.toLowerCase()) &&
    !firstMoneyFlow(CREDIT_VERB_FLOW_RE, clause.toLowerCase());
  if (flow !== 'unknown' && !bareDestination) return flow;
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
export function directionContradictsWording(
  text: string,
  type?: string,
  direction?: string,
  amountText?: string,
  merchant?: string | null,
): boolean {
  // A merchant name is masked first, as the parser masks it for the type
  // ("Purchase … at Salary Store" is a purchase).
  const name = (merchant ?? '').trim();
  if (name.length >= 3) text = text.replace(new RegExp(flowEsc(name), 'gi'), ' ');
  const wording = directionOfWording(text, amountClause(text, amountText));
  return contradicts(wording, directionOfType(type)) || contradicts(wording, asDirection(direction));
}

// ── Charged total (closure round, follow-up 6 (5)) ───────────────────────────
// A message that states a base amount with a tip, fee, VAT or tax AND the
// total charged: the total is what left the account and is counted once
// (a same-currency fee is never a second row). App twin:
// AiCandidateValidator.chargedTotal; shared fixtures pin both.
const TOTAL_COMPONENT =
  /(?<![a-z])(?:tips?|gratuity|service charge|fees?|vat|tax)(?![a-z])|بقشيش|إكرامية|اكرامية|ضريبة|رسوم|عمولة/i;
const CHARGED_TOTAL = new RegExp(
  '(?:(?<![a-z])(?:grand total|total(?: amount)?(?: charged| paid| debited| deducted)?)' +
    '|الإجمالي|الاجمالي|إجمالي المبلغ|اجمالي المبلغ|المبلغ الإجمالي|المبلغ الاجمالي|المجموع)' +
    '\\s*(?:of|is|:|=)?\\s*(?:[a-z]{3}\\s?)?([0-9][0-9,]*(?:\\.[0-9]+)?)',
  'i',
);

/** The stated charged total when the message also names a tip/fee/VAT/tax component; else null. */
export function chargedTotal(text: string): number | null {
  const t = normalizeCurrencyTokens(text.replace(ARABIC_INDIC_DIGIT, (d) => String(d.charCodeAt(0) - 0x0660)));
  if (!TOTAL_COMPONENT.test(t)) return null;
  const m = CHARGED_TOTAL.exec(t);
  if (!m) return null;
  const canonical = canonicalMoneyText(m[1]);
  return canonical == null ? null : Number(canonical);
}

/**
 * The first sentence that names [amountText] as a whole figure (the event; a
 * later equal figure such as "Credited points 45" is not); the whole text
 * when none (or no amount).
 */
function amountClause(text: string, amountText?: string): string {
  if (!amountText) return text;
  return text.split(/[\n!?؟;؛]|\.(?![0-9])/).find((s) => amountTextGrounded(amountText, s)) ?? text;
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

/** A currencyTable local form ("SR1,250", "₦5,000") next to a figure, as its ISO code. */
const LOCAL_FORMS = CURRENCY_TABLE.localForms.map(([form, code]) => {
  const f = form.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return [new RegExp(`(?<![A-Za-z])${f}(?=\\s?[0-9])|(?<=[0-9]\\s?)${f}(?![A-Za-z])`, 'g'), code] as const;
});

/**
 * A core parser code counts in any case as a whole word (unchanged); any other
 * table code only in capitals right next to a figure ("NGN 5,000"), so words
 * such as "ALL" or "TOP" are never a currency (ParserEngine._hasCurrency).
 */
export function currencyGrounded(iso: string, text: string): boolean {
  if (!iso) return false;
  let normalized = normalizeCurrencyTokens(text);
  for (const [re, code] of LOCAL_FORMS) normalized = normalized.replace(re, code);
  const code = CURRENCY_TABLE.core.includes(iso)
    ? new RegExp(`(?<![A-Za-z])${iso}(?![A-Za-z])`, 'i')
    : new RegExp(`(?<![A-Za-z])${iso}(?=\\s?[0-9])|(?<=[0-9]\\s?)${iso}(?![A-Za-z])`);
  if (code.test(normalized)) return true;
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
// between the label and the figure ("Outstanding amount settled SAR 1,200"),
// with no other number in between (QR-02: not a verb after the figure,
// "Available limit SAR 5,000 debited SAR 50"). Mirrors
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
export function movementActsOnFigure(l: string, labelAt: number, start: number): boolean {
  let cs = 0;
  for (const m of l.matchAll(CLAUSE_CUT)) {
    const me = m.index! + m[0].length;
    if (me <= start) cs = me;
  }
  if (labelAt < cs) labelAt = cs;
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
    return movementActsOnFigure(lower, offset, numAt) ? m : ' ';
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
// V1-086 / RR-03 — words that report a completed card or account movement
// but are not money words (they were removed from moneyKeywords in round 10
// because, in the DETERMINISTIC parser, they turned credits into payments).
// Here they only decide whether an account-notice line elsewhere in the
// message may be set aside; they never type or record anything.
const COMPLETION_WORDS = ['authorised', 'authorized', 'approved', 'posted', 'direct debit', 'standing order', 'payroll'];
const SENTENCE_CUT = /[\n!?؟;؛]|\.(?![0-9])/;

/**
 * V1-086 — [text] without the account-notice sentences ("Credit limit: SAR
 * 20,000", "Your e-statement is available", "Card activated") that are
 * unrelated to the amount the answer names. Only when the sentence holding
 * [amountText] itself names a completed movement (a money word or a
 * completion word), and only sentences that hold a notice word and no ignore
 * word, non-transaction marker or OTP code. Everything else is unchanged, so
 * an advert, an OTP or a notice whose own sentence carries the amount is
 * still "not a transaction". Mirrors AiCandidateValidator.withoutUnrelatedNotices.
 */
export function withoutUnrelatedNotices(text: string, amountText: string | null): string {
  if (amountText == null) return text;
  const ascii = text.replace(ARABIC_INDIC_DIGIT, (d) => String(d.charCodeAt(0) - 0x0660));
  const sentences = ascii.split(SENTENCE_CUT);
  const holds = (s: string) => amountTextGrounded(amountText, s);
  const own = sentences.filter(holds);
  const completed = (s: string) => {
    const lower = s.toLowerCase();
    return hasMoneyWord(lower) || COMPLETION_WORDS.some((w) => containsIgnoreWord(lower, w));
  };
  if (own.length === 0 || !own.some(completed)) return text;
  const kept = sentences.filter((s) => {
    if (holds(s)) return true;
    const lower = s.toLowerCase();
    const notice = NOTICE_KEYWORDS.some((w) => containsIgnoreWord(lower, w));
    const marker = [...(rules.ignoreKeywords as string[]), ...NON_TRANSACTION_KEYWORDS]
      .some((w) => containsIgnoreWord(lower, w)) || OTP_CODE.test(lower);
    return !notice || marker;
  });
  return kept.join('\n');
}

export function validateAiCandidate(input: {
  candidate: AiCandidate;
  sanitizedText: string;
  receivedAt: string;
  local: LocalCandidate | null;
  /**
   * 4.4 — the currency of the one existing account the device matched this
   * message to (sent only when that match is confident). Used only when the
   * text names no currency at all and the answer gives exactly it.
   */
  accountCurrency?: string | null;
}): AiCandidateValidation {
  const { candidate: c, sanitizedText: text, local } = input;
  const reject = (reason: string): AiCandidateValidation => ({ accepted: false, reason });

  // LR-06 — an OTP or an advert / account notice is never a transaction,
  // whatever the model says. V1-086: a notice line unrelated to the amount
  // (a footer next to a completed movement) does not count.
  const scoped = withoutUnrelatedNotices(
    text,
    typeof c.amount_text === 'string' ? canonicalMoneyText(c.amount_text) : null,
  );
  if (isNonTransactionText(scoped, merchantGrounded(c.merchant, text) ? c.merchant : null)) {
    return reject('not_a_transaction');
  }
  if (!amountGrounded(c.amount, text)) return reject('amount_not_grounded');
  // OR-03 — a limit, balance or minimum-due figure is never the amount.
  const ascii = text.replace(ARABIC_INDIC_DIGIT, (d) => String(d.charCodeAt(0) - 0x0660));
  if (!amountGrounded(c.amount, maskAccountFigures(ascii))) return reject('amount_is_account_figure');
  const total = chargedTotal(text);
  if (total != null && Math.abs((c.amount as number) - total) >= 0.005) return reject('amount_not_charged_total');
  const amount = c.amount as number;
  const currency = (c.currency ?? '').trim().toUpperCase();
  let currencySource: 'message' | 'local' | 'account_context' = local ? 'local' : 'message';
  if (local) {
    if (!(Math.abs(amount - local.amount) < 0.01)) return reject('amount_mismatch_local');
    if (currency !== local.currency.trim().toUpperCase()) return reject('currency_mismatch_local');
  } else {
    if (!CURRENCY_CODES.includes(currency)) return reject('currency_not_whitelisted');
    if (!currencyGrounded(currency, text)) {
      // 4.4: never an AI guess — only the matched account's own currency, and
      // only when the text names no currency that could contradict it.
      const account = (input.accountCurrency ?? '').trim().toUpperCase();
      const named = CURRENCY_CODES.some((code) => currencyGrounded(code, text));
      if (!account || named || currency !== account) return reject('currency_not_grounded');
      currencySource = 'account_context';
    }
  }

  if (typeof c.amount_text !== 'string') return reject('amount_text_missing');
  const amountText = canonicalMoneyText(c.amount_text, currency);
  if (amountText == null) return reject('amount_text_not_canonical');
  if ((amountText.split('.')[1]?.length ?? 0) > (CURRENCY_SCALE[currency] ?? Infinity)) {
    return reject('amount_text_not_canonical');
  }
  if (!(Math.abs(Number(amountText) - amount) < 0.01)) return reject('amount_text_mismatch');
  if (!amountTextGrounded(amountText, text)) return reject('amount_text_not_grounded');

  if (directionContradictsWording(text, c.type, c.direction, amountText,
    merchantGrounded(c.merchant, text) ? c.merchant : null)) return reject('direction_contradiction');
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
    currencySource,
    amountText,
    merchant,
    occurredAt: inWindow(c.occurred_at, input.receivedAt),
  };
}
