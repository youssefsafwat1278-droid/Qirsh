// Round 5 (owner decision): when the parser's own reading may record a
// message. Mirrors app/lib/engine/parser/completion_certainty.dart over the
// same patterns (parser_rules.json → completionCertainty; Dart drift test).
//
// A message is recorded on its own reading only when it is clearly
// completed: a completed-event form and no doubt anywhere outside a
// security-advice clause. Every other money message is uncertain: the model
// decides it when AI is allowed (never for a transfer), otherwise it is kept
// for review. A model answer of "completed" is never accepted for a text with
// a doubt.
import rules from './parser_rules.json' with { type: 'json' };
import { DONE_VERBS, MOVEMENT_LEADS } from './message_meaning.ts';

const C = rules.completionCertainty as {
  doubtPatterns: Record<string, string>;
  adviceClause: string;
  completedFormWords: string[];
  transferPattern: string;
  statedCreditPattern: string;
  statedDebitPattern: string;
};

// Same as TransactionStateCues.foldForCues / parse.ts foldForCues (kept here
// to avoid an import cycle with parse.ts).
function fold(input: string): string {
  return input
    .replace(/[ً-ٰ]/g, '')
    .replace(/ـ/g, '')
    .split(/[\r\n]+/).map((line) => line.replace(/[ \t]+/g, ' ').trim()).filter((l) => l.length > 0).join('\n')
    .toLowerCase()
    .replace(/[^\S\n]+/g, ' ')
    .replace(/[أإآٱ]/g, 'ا')
    .replace(/ؤ/g, 'و')
    .replace(/ئ/g, 'ي')
    .replace(/ى/g, 'ي')
    .replace(/ة/g, 'ه');
}

const DOUBT = Object.entries(C.doubtPatterns).map(([k, v]) => [k, new RegExp(v)] as const);
const ADVICE = new RegExp(C.adviceClause);
const TRANSFER = new RegExp(C.transferPattern);
const STATED_CREDIT = new RegExp(C.statedCreditPattern);
const STATED_DEBIT = new RegExp(C.statedDebitPattern);
const CLAUSE_END = /[\n!?؟;؛]|[.,،](?![0-9])| [-–—] /g;
const FORM_WORD = new RegExp(
  `(?<![a-zء-ي])(?:و|ف)?(?:${
    [...DONE_VERBS, ...MOVEMENT_LEADS, ...C.completedFormWords]
      .map((w) => fold(w).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')
  })(?![a-zء-ي])`,
);

/** [text] folded, with every security-advice clause (and its end mark) replaced by a line break. */
export function readable(text: string): string {
  const t = fold(text).replace(/’/g, "'");
  let out = '';
  let start = 0;
  for (const m of t.matchAll(CLAUSE_END)) {
    const end = m.index! + m[0].length;
    const clause = t.slice(start, end);
    out += ADVICE.test(clause) ? '\n' : clause;
    start = end;
  }
  const rest = t.slice(start);
  return out + (ADVICE.test(rest) ? '\n' : rest);
}

/** The first doubt family found in [text] outside security advice, or null. */
export function doubtOf(text: string): string | null {
  const t = readable(text);
  for (const [k, re] of DOUBT) if (re.test(t)) return k;
  return null;
}

/** The text states a completed event (a done verb, a movement lead, a completed-transfer form). */
export function hasCompletedForm(text: string): boolean {
  return FORM_WORD.test(readable(text));
}

/** A transfer to or from a person or between accounts: decided locally, never sent to the model. */
export function isTransfer(text: string): boolean {
  return TRANSFER.test(fold(text));
}

/**
 * Review Y (N-M1): the direction the wording states when no money word names
 * one ("topped up with", «قيد … لحسابك», "recharge … via card"), or unknown.
 * Only the local direction a model answer must agree with reads it.
 */
export function statedDirection(text: string): 'credit' | 'debit' | 'unknown' {
  const t = fold(text);
  const credit = STATED_CREDIT.test(t), debit = STATED_DEBIT.test(t);
  return credit === debit ? 'unknown' : credit ? 'credit' : 'debit';
}

/**
 * Why a reading that would record [text] is uncertain instead, or null when it
 * is clearly completed. A plain transfer notice that states its flow is
 * completed; one whose direction only a purpose word suggests is not.
 */
export function uncertaintyOf(text: string, hasFlow: boolean): string | null {
  if (doubtOf(text) != null) return 'not_clearly_completed';
  if (!hasFlow && !hasCompletedForm(text)) return 'no_completed_form';
  return null;
}
