// Round 3 (owner brief 4.1): meaning before amount, on the server. Mirrors
// app/lib/engine/parser/message_meaning.dart and ParserEngine.clauseScope /
// meaningOf over the same word lists (parser_rules.json → messageMeaning;
// Dart drift test transaction_state_cues_drift_test.dart).
//
// A sentence that carries an unlabelled amount is an event sentence. When the
// message has one, a sentence whose only figures are labelled (a balance, a
// limit, an amount due, a fee) and a sentence with no amount that carries a
// footer cue (security advice, an advert, an account notice, a reminder or
// offer, another attempt's status) is a footer: its words never decide the
// event's status or direction. A message holding an OTP code keeps every
// sentence.
import rules from './parser_rules.json' with { type: 'json' };
import { extractCaptureAmount } from './money.ts';
import {
  containsIgnoreWord,
  hasMoneyWord,
  isPurchaseCode,
  maskAccountFigures,
  NON_TRANSACTION_KEYWORDS,
  NOTICE_KEYWORDS,
  OTP_CODE,
} from '../_shared/ai_candidate_validator.ts';
import { isRewardFlow } from '../_shared/money_text.ts';

export type MessageKind =
  | 'completed_movement'
  | 'not_completed'
  | 'no_movement_notice'
  | 'own_account_transfer'
  | 'cash_deposit'
  | 'multiple_events'
  | 'otp'
  | 'undetermined'
  /** Follow-up 3: the text does not settle whether the movement completed. */
  | 'uncertain';

export type MessageDisposition = 'record' | 'review' | 'no_movement' | 'ignore';

export type MessageMeaning = {
  kind: MessageKind;
  disposition: MessageDisposition;
  /** Machine-readable reason (footer_set_aside, bill_due, own_accounts, …). */
  reason: string;
  /** Direction of the transaction clause's own verbs and prepositions. */
  direction: 'debit' | 'credit' | 'unknown';
  footerCount: number;
  eventCount: number;
  /** The message names no currency: the caller must not invent one (4.4). */
  currencyAbsent: boolean;
};

export function dispositionOf(kind: MessageKind): MessageDisposition {
  if (kind === 'completed_movement' || kind === 'undetermined') return 'record';
  if (kind === 'no_movement_notice') return 'no_movement';
  if (kind === 'otp') return 'ignore';
  return 'review';
}

const M = rules.messageMeaning as Record<string, string[]>;
export const OTHER_EVENT_MARKERS = M.otherEventMarkers;
export const DUE_MARKERS = M.dueMarkers;
export const FUTURE_MARKERS = M.futureMarkers;
export const OFFER_MARKERS = M.offerMarkers;
export const SUMMARY_MARKERS = M.summaryMarkers;
export const DONE_VERBS = M.doneVerbs;
export const OWN_ACCOUNT_MARKERS = M.ownAccountMarkers;
export const OWN_ACCOUNT_STRONG = M.ownAccountStrong;
export const CASH_DEPOSIT_MARKERS = M.cashDepositMarkers;
export const PENDING_WORDS = M.pendingWords;
export const TENSE_MARKERS = M.tenseMarkers;
export const SOURCE_OF_FUNDS = M.sourceOfFunds;
export const OWN_DESTINATION = M.ownDestination;
export const EXPLICIT_OWN_TRANSFER = M.explicitOwnTransfer;
export const DEBIT_FLOW = M.debitFlow;
export const CREDIT_FLOW = M.creditFlow;
export const ABBREVIATIONS = M.abbreviations;
export const FUTURE_TENSE = M.futureTense;
export const REWARD_MARKERS = M.rewardMarkers;
export const OTHER_EVENT_NOUNS = M.otherEventNouns;
export const NOTICE_OPENERS = M.noticeOpeners;
export const MOVEMENT_LEADS = M.movementLeads;

/**
 * Follow-up 3 (SM-09): the longest text the parser reads (ten concatenated
 * SMS parts are about 1,600 characters). Of a longer text the parser reads
 * its first and last MAX_TEXT_LENGTH / 2 characters as separate lines, so a
 * status at either end still decides it. Mirrors ParserEngine.bounded.
 */
export const MAX_TEXT_LENGTH = 2000;
export function bounded(text: string): string {
  if (text.length <= MAX_TEXT_LENGTH) return text;
  const half = MAX_TEXT_LENGTH / 2;
  return `${text.slice(0, half)}\n${text.slice(text.length - half)}`;
}

const esc = (w: string) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const wordPatterns = new Map<string, RegExp>();
/** A Latin phrase as whole words, an Arabic one by substring. */
export function hasAnyWord(lower: string, words: string[]): boolean {
  return words.some((w) => {
    if (!/[a-z]/.test(w)) return lower.includes(w);
    let re = wordPatterns.get(w);
    if (!re) {
      re = new RegExp(`(?<![a-z])${esc(w)}(?![a-z])`);
      wordPatterns.set(w, re);
    }
    return re.test(lower);
  });
}

const flowPattern = (words: string[]) =>
  new RegExp(`(?<![a-zء-ي])[وفب]?(?:${[...words].sort((a, b) => b.length - a.length).map(esc).join('|')})(?![a-z])`);
const DEBIT_FLOW_RE = flowPattern(DEBIT_FLOW);
const CREDIT_FLOW_RE = flowPattern(CREDIT_FLOW);

export const hasDebitFlow = (text: string) => firstMoneyFlow(DEBIT_FLOW_RE, text.toLowerCase()) !== null;
export const hasCreditFlow = (text: string) => firstMoneyFlow(CREDIT_FLOW_RE, text.toLowerCase()) !== null;

/**
 * The direction of the earliest flow phrase (a longer phrase wins at the same
 * position). "Payment … received" with no payer acknowledges the user's own
 * payment: not decisive. Mirrors DirectionSignal.flowOf.
 */
/**
 * The first flow phrase that moves money: "credited points 45" and "…, 45
 * points credited to your account" move points (isRewardFlow). Mirrors
 * DirectionSignal._firstMoneyFlow.
 */
function firstMoneyFlow(re: RegExp, lower: string): RegExpExecArray | null {
  const all = new RegExp(re.source, re.flags.includes('g') ? re.flags : re.flags + 'g');
  for (const m of lower.matchAll(all)) {
    if (!isRewardFlow(lower, m.index!, m.index! + m[0].length)) return m as RegExpExecArray;
  }
  return null;
}

export function flowOf(text: string): 'debit' | 'credit' | 'unknown' {
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
  // "SAR 500 credited to Ali from your account": money left the user's own
  // account and no clause names it as the destination.
  if (credit && SOURCE_OF_FUNDS.some((w) => lower.includes(w)) && !OWN_DESTINATION.some((w) => lower.includes(w))) {
    return 'debit';
  }
  return credit ? 'credit' : 'debit';
}

// Fee, tax, reference and code figures are not the amount that moved
// (ParserEngine._classifyAmountCandidate: feeWords, referenceWords).
const OTHER_FIGURE = new RegExp(
  '(?<![a-zء-ي])(?:fees?|vat|tax|commission|charges?|ref|reference|auth|authorization|code|otp|points|' +
    'رسوم|الرسوم|ضريبة|الضريبة|عمولة|مرجع|رمز|كود)(?![a-z])[^0-9\n]{0,12}[0-9][0-9,]*(?:\\.[0-9]+)?' +
    '|[0-9][0-9,]*(?:\\.[0-9]+)? ?(?:sar|aed|egp|qar|omr|kwd|bhd|jod|usd|eur|gbp|jpy)? ?(?:fees?|vat|tax|commission)(?![a-z])',
  'gi',
);
// A currency next to a figure: a core code (any case) or a currencyTable ISO
// code in capitals (ParserEngine._hasCurrency).
const CURRENCY_TABLE = rules.currencyTable as { core: string[]; iso: string[]; localForms: string[][] };
const CORE_CODES = CURRENCY_TABLE.core.join('|');
const EXTENDED_CODES = CURRENCY_TABLE.iso.filter((c) => !CURRENCY_TABLE.core.includes(c)).join('|');
const CORE_FIGURE = new RegExp(`(?<![a-z])(?:${CORE_CODES}) ?[0-9]|[0-9] ?(?:${CORE_CODES})(?![a-z])`, 'i');
const EXTENDED_FIGURE = new RegExp(`(?<![A-Za-z])(?:${EXTENDED_CODES}) ?[0-9]|[0-9] ?(?:${EXTENDED_CODES})(?![A-Za-z])`);
export const hasCurrencyFigure = (s: string) => CORE_FIGURE.test(s) || EXTENDED_FIGURE.test(s);
const CURRENCY_FIGURE = { test: hasCurrencyFigure };

/** The currencyTable local forms ("SR1,250.00", "L.E 50") as ISO codes, only next to a figure. */
const LOCAL_FORMS = CURRENCY_TABLE.localForms.map(([form, code]) => {
  const f = esc(form);
  return [new RegExp(`(?<![A-Za-z])${f}(?=\\s?[0-9])|(?<=[0-9]\\s?)${f}(?![A-Za-z])`, 'g'), code] as const;
});
export function applyLocalForms(text: string): string {
  for (const [re, code] of LOCAL_FORMS) {
    text = text.replace(re, (m, offset: number, all: string) => {
      const before = offset > 0 && /[0-9]/.test(all[offset - 1]) ? ' ' : '';
      const after = /[0-9]/.test(all[offset + m.length] ?? '') ? ' ' : '';
      return `${before}${code}${after}`;
    });
  }
  return text;
}

type Role = 'event' | 'figure' | 'text';
// A sentence that opens with a balance or limit label ("رصيدك بعد الخصم
// 5,000 ريال", "Available limit SAR 9,000") states an account figure, as the
// device's balance/limit candidates do (ParserEngine._classifyAmountCandidate).
const LABEL_OPENING =
  /^(?:your |ur )?(?:available |avl\.? |current |remaining |new |daily |monthly )*(?:credit |card |purchase |withdrawal )?(?:balance|bal\b|limit)|^(?:و)?(?:رصيدك|الرصيد|رصيد|الحد|حد |المتاح|المتبقي)/i;

// A percentage ("خصم 50%", "5% cashback") is never an amount that moved.
const PERCENTAGE = /[0-9][0-9.,]*\s?[%٪]/g;

function roleOf(sentence: string): Role {
  const s = sentence.trim().replace(PERCENTAGE, ' ');
  if (!s) return 'text';
  if (LABEL_OPENING.test(s)) return CURRENCY_FIGURE.test(s) ? 'figure' : 'text';
  const masked = maskAccountFigures(s).replace(OTHER_FIGURE, ' ');
  const { amount } = captureAmount(masked);
  if (amount && amount > 0) return 'event';
  return CURRENCY_FIGURE.test(s) ? 'figure' : 'text';
}

/** Sentence spans: a line break, `! ? ؟ ; ؛`, or a period that is neither a decimal point nor the end of an abbreviation. */
function sentences(text: string): Array<{ start: number; end: number; next: number }> {
  const out: Array<{ start: number; end: number; next: number }> = [];
  let from = 0;
  for (const m of text.matchAll(/[\n!?؟;؛]|\.(?![0-9])/g)) {
    if (m[0] === '.') {
      // Only the few characters before the dot can hold an abbreviation.
      const word = /([a-z/]+)$/.exec(text.slice(Math.max(from, m.index! - 12), m.index!).toLowerCase())?.[1];
      if (word && ABBREVIATIONS.includes(word)) continue;
    }
    out.push({ start: from, end: m.index!, next: m.index! + m[0].length });
    from = m.index! + m[0].length;
  }
  out.push({ start: from, end: text.length, next: text.length });
  return out;
}

const IGNORE_WORDS = [...(rules.ignoreKeywords as string[]), ...NON_TRANSACTION_KEYWORDS];

/** A footer cue in a sentence with no amount (a sentence with a status cue is never a footer: clauseScope). */
function footerCue(s: string): boolean {
  return IGNORE_WORDS.some((w) => containsIgnoreWord(s, w)) ||
    hasAnyWord(s, REWARD_MARKERS) ||
    NOTICE_KEYWORDS.some((w) => containsIgnoreWord(s, w)) ||
    hasAnyWord(s, DUE_MARKERS) || hasAnyWord(s, OFFER_MARKERS) || hasAnyWord(s, SUMMARY_MARKERS);
}

export type ClauseScope = {
  text: string;
  core: string;
  eventSentences: string[];
  footerCount: number;
  /** The event sentences kept in core (a cashback credit or another operation's figure is set aside). */
  coreEvents: string[];
};

/** Status-cue readers from parse.ts (TransactionStateCues). */
export type CueDeps = {
  /** A declined/not-completed cue or a reversal word (TransactionStateCues.hasStatusCue). */
  hasStatusCue: (s: string) => boolean;
  /** The sentence names another operation (TransactionStateCues.namesOtherEvent). */
  namesOtherEvent: (s: string) => boolean;
};

/** A cashback or reward credit, or another operation's figure. Mirrors ParserEngine._isSideEvent. */
function isSideEvent(lower: string, deps: CueDeps): boolean {
  return hasAnyWord(lower, REWARD_MARKERS) || hasAnyWord(lower, ['cashback', 'cash back', 'استرداد نقدي', 'كاش باك']) ||
    deps.namesOtherEvent(lower);
}

/** [text] is already normalized (parse.ts normalize). Mirrors ParserEngine.clauseScope. */
export function clauseScope(text: string, deps: CueDeps): ClauseScope {
  text = bounded(text);
  const pieces = sentences(text);
  const roles = pieces.map((p) => roleOf(text.slice(p.start, p.end)));
  const eventSentences = pieces.filter((_, i) => roles[i] === 'event').map((p) => text.slice(p.start, p.end));
  if (eventSentences.length === 0 || OTP_CODE.test(text.toLowerCase())) {
    return { text, core: text, eventSentences, footerCount: 0, coreEvents: eventSentences };
  }
  // An event sentence that names no movement (a due bill, a scheduled
  // payment) is a footer when another event sentence names one.
  const notices = pieces.map((p, i) =>
    roles[i] === 'event' && noMovementReason(text.slice(p.start, p.end).toLowerCase()) !== null
  );
  // A bare field line ("مبلغ:SAR 100.00") details the line above it, whose
  // words keep deciding the message: that header line is never a footer.
  const field = pieces.map((p) => isFieldLine(text.slice(p.start, p.end)));
  // Whether each piece sits on the line just above a field line.
  const aboveField = pieces.map(() => false);
  for (let k = pieces.length - 2; k >= 0; k--) {
    aboveField[k] = text.slice(pieces[k].end, pieces[k].next) === '\n' ? field[k + 1] : aboveField[k + 1];
  }
  // Follow-up 3 (SM-01): a sentence with a status cue is never a footer.
  const cue = pieces.map((p) => deps.hasStatusCue(text.slice(p.start, p.end)));
  // Follow-up 3 (SM-06): a cashback/reward credit or another operation's
  // figure is a side event: a footer next to the transaction's own sentence.
  const side = pieces.map((p, i) =>
    roles[i] === 'event' && !notices[i] && !field[i] && !cue[i] &&
    isSideEvent(text.slice(p.start, p.end).toLowerCase(), deps)
  );
  const anyMovement = roles.some((r, i) => r === 'event' && !notices[i] && !field[i] && !side[i]);
  // An advert or OTP sentence is set aside only next to an event sentence that
  // names a movement in its own words (a money word, a done verb, a flow).
  const namedMovement = pieces.some((p, i) =>
    roles[i] === 'event' && !notices[i] && !field[i] && !side[i] &&
    namesMovement(text.slice(p.start, p.end).toLowerCase())
  );
  let core = '';
  const coreEvents: string[] = [];
  let footerCount = 0;
  pieces.forEach((p, i) => {
    const s = text.slice(p.start, p.end);
    const lower = s.toLowerCase();
    const header = !field[i] && aboveField[i];
    const footer = !header && !cue[i] && (roles[i] === 'figure' || (anyMovement && (notices[i] || side[i])) ||
      (roles[i] === 'text' && footerCue(lower) &&
        (namedMovement || !IGNORE_WORDS.some((w) => containsIgnoreWord(lower, w)))));
    if (footer && s.trim()) footerCount++;
    if (!footer) {
      core += s;
      if (roles[i] === 'event') coreEvents.push(s);
    }
    core += text.slice(p.end, p.next);
  });
  return { text, core, eventSentences, footerCount, coreEvents };
}

/** [lower] names a money movement in its own words. Mirrors ParserEngine._namesMovement. */
function namesMovement(lower: string): boolean {
  return hasMoneyWord(lower) || [...lower.matchAll(DONE_VERB)].length > 0 || hasDebitFlow(lower) || hasCreditFlow(lower);
}

/** [value] up to its first sentence end, unless the period ends an abbreviation. Mirrors ParserEngine.cutAtSentenceEnd. */
export function cutAtSentenceEnd(value: string): string {
  for (const m of value.matchAll(/([A-Za-z/]*)\.\s+\S/g)) {
    if (ABBREVIATIONS.includes(m[1].toLowerCase())) continue;
    return value.slice(0, m.index! + m[1].length).trim();
  }
  return value;
}

const FIELD_LINE = /^[^\d:\n]{1,30}:\s*(?:[a-z\u0600-\u06ff.]{1,6}\s?)?[0-9][0-9.,]*\s*(?:[a-z\u0600-\u06ff.]{1,6})?$/i;

/** A bare field line: a short label, a colon and only an amount. Mirrors ParserEngine.isFieldLine. */
export function isFieldLine(sentence: string): boolean {
  return FIELD_LINE.test(sentence.trim());
}

const DONE_VERB = new RegExp(`(?<![a-zء-ي])(?:${DONE_VERBS.map(esc).join('|')})(?![a-zء-ي])`, 'g');

/** Why an event sentence names an amount but no movement that happened, or null. Mirrors ParserEngine._noMovementReason. */
export function noMovementReason(s: string): string | null {
  // A courtesy opener ("Please note", يرجى العلم) is not a request.
  for (const w of NOTICE_OPENERS) s = s.replaceAll(w, ' ');
  let reason: string | null = null;
  if (hasAnyWord(s, SUMMARY_MARKERS)) return 'summary';
  else if (hasAnyWord(s, DUE_MARKERS)) reason = 'bill_due';
  else if (hasAnyWord(s, FUTURE_MARKERS)) reason = 'scheduled_or_expected';
  else if (hasAnyWord(s, OFFER_MARKERS)) reason = 'offer';
  if (reason == null) {
    // Every done verb sits in a future clause ("will be charged").
    const done = [...s.matchAll(DONE_VERB)];
    return done.length > 0 && done.every((m) => hasAnyWord(s.slice(clauseCut(s, m.index!), m.index!), FUTURE_TENSE))
      ? 'scheduled_or_expected'
      : null;
  }
  // Follow-up 3 (SM-04): the clause that carries the figure states a
  // completed movement with no notice word of its own: the tail does not undo it.
  if (s.split(FIGURE_CLAUSE_CUT).some(statesMovement)) return null;
  for (const m of s.matchAll(DONE_VERB)) {
    const clause = s.slice(clauseCut(s, m.index!), m.index!);
    if (!hasAnyWord(clause, TENSE_MARKERS)) return null;
  }
  return reason;
}

const FIGURE_CLAUSE_CUT = /[,،:]| [-–—] /;
const FIGURE_CLAUSE_CUTS = /[,،:]| [-–—] /g;
// A currency next to a figure, any case (ParserEngine._amountWithCurrency).
const ANY_FIGURE = new RegExp(
  `(?<![a-z])(?:${CORE_CODES}|${EXTENDED_CODES}) ?[0-9]|[0-9] ?(?:${CORE_CODES}|${EXTENDED_CODES})(?![a-z])`,
  'i',
);

const FIGURE_AMOUNTS = new RegExp(
  `(?<![a-z])(?:${CORE_CODES}|${EXTENDED_CODES}) ?([0-9][0-9,]*(?:\\.[0-9]+)?)|([0-9][0-9,]*(?:\\.[0-9]+)?) ?(?:${CORE_CODES}|${EXTENDED_CODES})(?![a-z])`,
  'gi',
);

function hasNoticeWord(lower: string): boolean {
  return hasAnyWord(lower, SUMMARY_MARKERS) || hasAnyWord(lower, DUE_MARKERS) ||
    hasAnyWord(lower, FUTURE_MARKERS) || hasAnyWord(lower, OFFER_MARKERS);
}

/** A clause with a figure that states a completed movement and no notice or tense word. Mirrors ParserEngine._statesMovement. */
function statesMovement(clause: string): boolean {
  return ANY_FIGURE.test(clause) && !hasNoticeWord(clause) && !hasAnyWord(clause, TENSE_MARKERS) &&
    (hasAnyWord(clause, MOVEMENT_LEADS) || new RegExp(DONE_VERB.source).test(clause));
}

/**
 * Follow-up 3 (SM-04): [core] without the notice tails (an offer, due, future
 * or summary clause with no figure) of a sentence whose figure clause states a
 * completed movement. Mirrors ParserEngine.withoutNoticeTails.
 */
export function withoutNoticeTails(core: string): string {
  let out = '';
  for (const p of sentences(core)) {
    const s = core.slice(p.start, p.end);
    const clauses = s.split(FIGURE_CLAUSE_CUT);
    const lower = clauses.map((c) => c.toLowerCase());
    if (lower.some(statesMovement)) {
      const cuts = [...s.matchAll(FIGURE_CLAUSE_CUTS)];
      clauses.forEach((c, k) => {
        const tail = !ANY_FIGURE.test(lower[k]) && hasNoticeWord(lower[k]);
        out += tail ? ' '.repeat(c.length) : c;
        if (k < cuts.length) out += cuts[k][0];
      });
    } else {
      out += s;
    }
    out += core.slice(p.end, p.next);
  }
  return out;
}

function clauseCut(s: string, end: number): number {
  let cut = 0;
  for (const c of s.matchAll(/[,،:]|\.(?![0-9])/g)) if (c.index! + c[0].length <= end) cut = c.index! + c[0].length;
  return cut;
}

/** Mirrors ParserEngine._isOwnAccountMove. */
export function isOwnAccountMove(core: string): boolean {
  if (hasAnyWord(core, OWN_ACCOUNT_STRONG)) return true;
  // "from your account *1234 to your account *5678": out of and into the user's own accounts.
  const both = (hasDebitFlow(core) && hasCreditFlow(core)) ||
    (SOURCE_OF_FUNDS.some((w) => core.includes(w)) && OWN_DESTINATION.some((w) => core.includes(w)));
  if (!both) return false;
  // (On the server a masked reference may arrive redacted: "[NAME]1111".)
  const refs = new Set([...core.matchAll(/(?:\*+\s?|\[(?:name|card|account)\])([0-9]{4})/gi)].map((m) => m[1]));
  return refs.size >= 2 || hasAnyWord(core, OWN_ACCOUNT_MARKERS);
}

/** Mirrors ParserEngine._isCashDeposit. */
export function isCashDeposit(core: string): boolean {
  return hasAnyWord(core, CASH_DEPOSIT_MARKERS) ||
    (hasAnyWord(core, ['deposit', 'deposited', 'إيداع', 'ايداع']) && hasAnyWord(core, ['atm', 'صراف', 'cash']) &&
      !hasAnyWord(core, ['withdraw', 'withdrawal', 'withdrawn', 'سحب', 'transfer', 'تحويل', 'راتب', 'salary']));
}

/** Distinct amounts among event sentences that each name a movement. */
export function distinctMovementAmounts(events: string[], namesDirection: (s: string) => boolean): number {
  const amounts = new Set<string>();
  for (const s of events) {
    if (noMovementReason(s.toLowerCase()) !== null) continue;
    if (!hasMoneyWord(s.toLowerCase()) && !namesDirection(s)) continue;
    const masked = maskAccountFigures(s).replace(OTHER_FIGURE, ' ');
    const { amount } = captureAmount(masked);
    if (amount != null) amounts.add(amount.toFixed(3));
    // Follow-up 3: one sentence that both takes money out and puts money in,
    // with two different figures, states two movements.
    if (hasDebitFlow(s) && hasCreditFlow(s)) {
      for (const m of masked.matchAll(FIGURE_AMOUNTS)) {
        const v = Number((m[1] ?? m[2]).replaceAll(',', ''));
        if (v > 0) amounts.add(v.toFixed(3));
      }
    }
  }
  return amounts.size;
}

export type MeaningDeps = CueDeps & {
  /** Every status cue of a sentence belongs to another operation (TransactionStateCues.isOtherEventStatus). */
  isOtherEventStatus: (s: string) => boolean;
  /** The not-completed rule over the clause core (isDeclinedText). */
  isNotCompletedCore: (core: string) => boolean;
  /** Word-family direction of a sentence (DirectionSignal.detectWords). */
  namesDirection: (s: string) => boolean;
  /** A charged-amount pair (original + charged currency) in the text. */
  hasChargedPair: (text: string) => boolean;
};

const TRUNCATED_STATUS =
  /(?:was|is|been|status:?|transaction|txn)\s+(?:decli?n?e?|reje?c?t?e?|fail?e?|pend?i?n?|canc?e?l?l?e?|reve?r?s?e?|unsu?c?c?e?s?s?f?u?)$/;

/** The message's meaning, decided before any amount is trusted. Mirrors ParserEngine.meaningOf. */
export function meaningOf(text: string, deps: MeaningDeps): MessageMeaning {
  text = bounded(text);
  const scope = clauseScope(text, deps);
  const all = text.toLowerCase();
  const currencyAbsent = currencyIn(text) === undefined;
  const make = (kind: MessageKind, reason: string, direction: MessageMeaning['direction'] = 'unknown',
    events = scope.eventSentences.length): MessageMeaning => ({
      kind, disposition: dispositionOf(kind), reason, direction,
      footerCount: kind === 'otp' ? 0 : scope.footerCount, eventCount: events, currencyAbsent,
    });
  if ((OTP_CODE.test(all) && IGNORE_WORDS.some((w) => containsIgnoreWord(all, w))) || isPurchaseCode(all)) {
    return make('otp', 'otp_code', 'unknown', 0);
  }
  if (scope.eventSentences.length === 0) {
    // Labelled figures that a future clause acts on, or that are due, make a
    // notice when every sentence with a figure is one.
    const figures = sentences(text).map((p) => text.slice(p.start, p.end)).filter((s) => CORE_FIGURE.test(s))
      .map((s) => noMovementReason(s.toLowerCase()));
    if (figures.length > 0 && figures.every((r) => r !== null)) return make('no_movement_notice', figures[0]!);
    return make('undetermined', 'no_event_amount');
  }
  const core = scope.core.toLowerCase();
  if (deps.isNotCompletedCore(scope.core)) {
    // Follow-up 3 (SM-01): a status that an "other operation" phrase ties to
    // another transaction, next to a completed one: review, not record.
    const own = sentences(scope.core).filter((p) => !deps.isOtherEventStatus(scope.core.slice(p.start, p.end)))
      .map((p) => scope.core.slice(p.start, p.next)).join('');
    if (!deps.isNotCompletedCore(own) &&
      scope.coreEvents.some((s) => !deps.isOtherEventStatus(s) && namesMovement(s.toLowerCase()))) {
      return make('uncertain', 'other_event_status');
    }
    return make('not_completed', hasAnyWord(core, PENDING_WORDS) ? 'pending' : 'declined_or_failed');
  }
  // The whole message reads as not completed but its clause core does not.
  if (deps.isNotCompletedCore(scope.text)) return make('uncertain', 'status_disputed');
  // A status cut off mid-word after the transaction ("… was decl").
  if (TRUNCATED_STATUS.test(scope.text.trimEnd().toLowerCase())) return make('uncertain', 'truncated_status');
  // Field lines detail a header; the header's sentences say what happened.
  const stated = scope.eventSentences.filter((s) => !isFieldLine(s));
  const notices = (stated.length ? stated : scope.eventSentences).map((s) => noMovementReason(s.toLowerCase()));
  if (notices.every((r) => r !== null)) return make('no_movement_notice', notices[0]!);
  if (isOwnAccountMove(core) && !EXPLICIT_OWN_TRANSFER.some((w) => all.includes(w))) {
    return make('own_account_transfer', 'own_accounts');
  }
  if (isCashDeposit(core)) return make('cash_deposit', 'cash_deposit', 'credit');
  if (distinctMovementAmounts(scope.coreEvents, deps.namesDirection) > 1 && !deps.hasChargedPair(text)) {
    return make('multiple_events', 'multiple_amounts');
  }
  return make('completed_movement', scope.footerCount > 0 ? 'footer_set_aside' : 'single_event', flowOf(scope.core));
}

// Mirrors ParserEngine._extractCurrency: the first core code (any case) that
// does not name a merchant ("at USD Store"), else a currencyTable ISO code in
// capitals next to a figure.
const CORE_WORD = new RegExp(`(?<![A-Za-z])(?:${CORE_CODES})(?![A-Za-z])`, 'gi');
const EXTENDED_CODE = new RegExp(
  `(?<![A-Za-z])(?:${EXTENDED_CODES})(?=\\s?[0-9])|(?<=[0-9]\\s?)(?:${EXTENDED_CODES})(?![A-Za-z])`,
);
const MERCHANT_INTRODUCER = /(?:\bat|@|\bfrom|\bto|لدى|من|في)\s*$/i;
export function currencyIn(text: string): string | undefined {
  for (const m of text.matchAll(CORE_WORD)) {
    const end = m.index! + m[0].length;
    if (MERCHANT_INTRODUCER.test(text.slice(0, m.index)) && !/^\s?[0-9]/.test(text.slice(end))) continue;
    return m[0].toUpperCase();
  }
  return EXTENDED_CODE.exec(text)?.[0];
}

const EXTENDED_AMOUNT = new RegExp(
  `(?<![A-Za-z])(?:${EXTENDED_CODES})\\s?([0-9][0-9,]*(?:\\.[0-9]+)?)|([0-9][0-9,]*(?:\\.[0-9]+)?)\\s?(?:${EXTENDED_CODES})(?![A-Za-z])`,
);

/**
 * The capture amount (money.ts extractCaptureAmount over amountPatterns), or
 * else a figure next to a currencyTable ISO code in capitals ("500 NGN").
 */
export function captureAmount(masked: string, currency?: string): { amount?: number; amount_text?: string } {
  const found = extractCaptureAmount(masked, rules.amountPatterns as string[], currency);
  if (found.amount != null) return found;
  const m = EXTENDED_AMOUNT.exec(masked);
  if (!m) return found;
  return extractCaptureAmount(m[1] ?? m[2], ['^([0-9][0-9,]*(?:\\.[0-9]+)?)$'], currency);
}
