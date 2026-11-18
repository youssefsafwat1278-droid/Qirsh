import currencyRules from '../process-ios-sms/parser_rules.json' with { type: 'json' };

const CURRENCY_MINOR_UNITS: Readonly<Record<string, number>> = {
  JPY: 0,
  EGP: 2,
  SAR: 2,
  AED: 2,
  USD: 2,
  EUR: 2,
  GBP: 2,
  QAR: 2,
  KWD: 3,
  BHD: 3,
  OMR: 3,
  JOD: 3,
};

export interface CanonicalMoneyTextOptions {
  allowNegative?: boolean;
}

/**
 * Validates a lexical decimal without parsing it through Number. Grouping is
 * accepted only in unambiguous 3-digit groups and is removed in the canonical
 * result. Fractional digits are preserved exactly; excess currency scale is
 * rejected rather than rounded.
 */
export function canonicalMoneyText(
  token: string,
  currency?: string,
  options: CanonicalMoneyTextOptions = {},
): string | null {
  if (!token || token.length > 256) return null;
  const match = /^(-?)(?:(0|[1-9][0-9]*)|([1-9][0-9]{0,2}(?:,[0-9]{3})+))(?:\.([0-9]+))?$/.exec(token);
  if (!match || (match[1] && !options.allowNegative)) return null;

  const fraction = match[4];
  const scale = currency ? CURRENCY_MINOR_UNITS[currency.trim().toUpperCase()] : undefined;
  if (scale != null && (fraction?.length ?? 0) > scale) return null;

  const integer = (match[2] ?? match[3]).replaceAll(',', '');
  const isZero = integer === '0' && (!fraction || /^0+$/.test(fraction));
  const sign = match[1] && !isZero ? '-' : '';
  return `${sign}${integer}${fraction == null ? '' : `.${fraction}`}`;
}

/**
 * Accepts exact model text solely from its lexical syntax and currency scale.
 * The legacy JSON number is deliberately ignored: callers derive that
 * compatibility value from the returned canonical text, never the reverse.
 */
export function modelMoneyText(
  parsed: Record<string, unknown>,
  _amountField = 'amount',
  textField = 'amount_text',
  currencyField = 'currency',
  options: CanonicalMoneyTextOptions = {},
): string | null {
  const token = parsed[textField];
  const currency = parsed[currencyField];
  if (typeof token !== 'string' || typeof currency !== 'string') return null;

  return canonicalMoneyText(token, currency, options);
}

/**
 * Revalidates exact fields already stored as strings. A valid exact string is
 * authoritative and regenerates its legacy numeric compatibility field. An
 * invalid exact string is omitted while its historical numeric field is kept.
 */
export function withValidatedExactMoneyText(parsed: Record<string, unknown>): Record<string, unknown> {
  const next = { ...parsed };
  const specs: Array<{
    amountField: string;
    textField: string;
    currencyField: string;
    allowNegative: boolean;
  }> = [
    { amountField: 'amount', textField: 'amount_text', currencyField: 'currency', allowNegative: false },
    {
      amountField: 'balance_after',
      textField: 'balance_after_text',
      currencyField: 'currency',
      allowNegative: true,
    },
    {
      amountField: 'foreign_amount',
      textField: 'foreign_amount_text',
      currencyField: 'foreign_currency',
      allowNegative: false,
    },
  ];

  for (const spec of specs) {
    const token = next[spec.textField];
    if (token == null) continue;
    const currency = next[spec.currencyField];
    const canonical = typeof token === 'string' && typeof currency === 'string'
      ? canonicalMoneyText(token, currency, { allowNegative: spec.allowNegative })
      : null;
    if (canonical == null) {
      delete next[spec.textField];
    } else {
      next[spec.textField] = canonical;
      next[spec.amountField] = Number(canonical);
    }
  }
  return next;
}

// Parser follow-up 3 (SM-03): reward points or miles are not money. A flow
// phrase ("credited", "added to your account", `تمت إضافة`) moves rewards when
// a reward unit follows it (a count may come first: "credited 45 points",
// `إضافة 30 نقطة`) or sits in its own clause before it ("…, 45 points
// credited to your account"); `نقاط البيع` (point of sale) is not one.
// Shared by process-ios-sms/message_meaning.ts (firstMoneyFlow) and the AI
// candidate validator; mirrors DirectionSignal.isRewardFlow.
const REWARD_UNITS =
  '(?:(?:reward|loyalty|bonus|cashback)\\s+)?(?:points|miles)(?![a-z])|(?:ال)?نقاط(?!\\s*البيع)|نقطة|نقطه|أميال|اميال';
const REWARD_AFTER = new RegExp(`^\\s*(?:[0-9][0-9,.]*\\s*)?(?:${REWARD_UNITS})`);
const REWARD_UNIT = new RegExp(`(?<![a-z])(?:${REWARD_UNITS})`);
const REWARD_CLAUSE_CUT = /[\n,،:;!?؟؛]|\.(?![0-9])| [-–—] /g;

/**
 * Whether the flow phrase at [start, end) of [lower] moves reward points or
 * miles, or is a side credit (sideCreditClause).
 */
export function isRewardFlow(lower: string, start: number, end: number): boolean {
  if (REWARD_AFTER.test(lower.slice(end))) return true;
  let from = 0;
  for (const c of lower.slice(0, start).matchAll(REWARD_CLAUSE_CUT)) from = c.index! + c[0].length;
  return REWARD_UNIT.test(lower.slice(from, start)) || sideCreditClause(lower, start, end) !== null;
}

// Follow-up 4 (NEW-1): the message's direction and amount come from its
// primary clause, the one that carries the first currency figure (the
// transaction amount). A flow phrase in a later clause that names a reward,
// cashback, bonus or loyalty credit, and whose own figure (if it has one) is
// smaller than the primary figure, is a side event: it never sets the
// direction. A message whose only event is a cashback or redemption credit has
// no earlier primary figure, so its credit stands. Mirrors
// DirectionSignal.sideCreditClause.
const SIDE_CLAUSE_CUT = /[\n,،;!?؟؛]|\.(?![0-9])| [-–—] | and (?=[a-z])/g;
const SIDE_REWARD = new RegExp(
  '(?<![a-z])(?:cash ?back|rewards?|bonus|qitaf|loyalty|points|miles)(?![a-z])' +
    '|استرداد نقدي|كاش ?باك|مكافأة|المكافأة|مكافآت|المكافآت|مكافاة|المكافاة|قطاف' +
    '|(?:ال)?نقاط(?!\\s*البيع)|نقطة|نقطه|أميال|اميال',
);
const CODES = [...(currencyRules.currencyTable.iso as string[]).map((c) => c.toLowerCase()), 'sr', 'ر\\.س'].join('|');
const NUM = '[0-9٠-٩][0-9٠-٩,٬]*(?:[.٫][0-9٠-٩]+)?';
const CURRENCY_FIGURE = new RegExp(
  `(?<![a-z])(?:${CODES})\\s?(${NUM})|(${NUM})\\s?(?:${CODES}|ريال|جنيه|درهم|دينار)(?![a-z])`,
);
function figureValue(m: RegExpExecArray): number {
  const raw = (m[1] ?? m[2]).replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x660));
  const v = Number(raw.replace(/[,٬]/g, '').replace('٫', '.'));
  return Number.isFinite(v) ? v : Infinity;
}

/** The side-credit clause [from, to) around the flow at [start, end) of [lower], or null. */
export function sideCreditClause(lower: string, start: number, end: number): [number, number] | null {
  let from = 0;
  for (const c of lower.slice(0, start).matchAll(SIDE_CLAUSE_CUT)) from = c.index! + c[0].length;
  const next = new RegExp(SIDE_CLAUSE_CUT.source).exec(lower.slice(end));
  const to = next ? end + next.index : lower.length;
  const clause = lower.slice(from, to);
  if (!SIDE_REWARD.test(clause)) return null;
  const primary = CURRENCY_FIGURE.exec(lower);
  if (!primary || primary.index >= from) return null;
  const own = CURRENCY_FIGURE.exec(clause);
  if (own && !(figureValue(own) < figureValue(primary))) return null;
  return [from, to];
}

/** Whether [lower] names a reward, cashback, bonus or loyalty credit. */
export const namesReward = (lower: string) => SIDE_REWARD.test(lower);
