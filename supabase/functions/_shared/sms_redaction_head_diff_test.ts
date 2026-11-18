// FU11 privacy diff: the beneficiary rule now keeps the words after the name
// (tense, status, amount, date) instead of everything to the end of the
// sentence. This test proves that change never lets a number through that the
// previous redaction (commit 4d54d258, frozen in fixtures/) removed, over the
// shared redaction fixture and every parser case table. A digit run the new
// output has more often than the old one is allowed only when it is
//   - the user's own partial suffix: at most four digits right after «حسابك»,
//     «بطاقتك», "your account" … (optionally star-masked, optionally with
//     "ending" / «المنتهية» between), or
//   - (round 4, MASK-0) the card of a purchase: at most four digits right
//     after "card" / «بطاقة» in a text that reads as a purchase, when the
//     card is not the destination ("to card", «إلى بطاقة»), or
//   - part of an amount (a currency word or code next to it), or
//   - part of a date or time (`/` or `:` between digits, or a day before a
//     month name).
// A third party's account, card, IBAN or phone digits never qualify.
import { assertEquals } from 'jsr:@std/assert@1';
import * as previous from './fixtures/sms_redaction_4d54d258.ts';
import * as older from './fixtures/sms_redaction_5dae2e2d.ts';
import { redactPii, redactThirdPartyNames } from './sms_redaction.ts';

const root = new URL('../../../', import.meta.url);
const caseFiles = [
  ...[...Deno.readDirSync(new URL('tools/parser_diff/cases/', root))]
    .filter((e) => e.name.endsWith('.json'))
    .map((e) => `tools/parser_diff/cases/${e.name}`),
  ...[...Deno.readDirSync(new URL('supabase/functions/process-ios-sms/', root))]
    .filter((e) => /_cases\.json$|^pre_round_not_completed\.json$/.test(e.name))
    .map((e) => `supabase/functions/process-ios-sms/${e.name}`),
  'supabase/functions/_shared/fixtures/sms_redaction_cases.json',
  'supabase/functions/_shared/fixtures/sms_leak_labelled_cases.json',
];

function collectTexts(): string[] {
  const texts = new Set<string>();
  const walk = (v: unknown, key: string) => {
    if (typeof v === 'string') {
      if (key === 'text' || key === 'raw' || key === 'texts') texts.add(v);
    } else if (Array.isArray(v)) v.forEach((x) => walk(x, key));
    else if (v && typeof v === 'object') {
      for (const [k, x] of Object.entries(v)) walk(x, k);
    }
  };
  for (const f of caseFiles) walk(JSON.parse(Deno.readTextFileSync(new URL(f, root))), '');
  return [...texts];
}

const D = '[0-9٠-٩۰-۹]';
const OWN = `(?:حسابك|حسابكم|لحسابك|بطاقتك|بطاقتكم|لبطاقتك|محفظتك|your(?:[ \\t]+(?:account|card|wallet))?(?:[ \\t]+(?:no\\.?|number))?)(?:[ \\t]+(?:ending|المنتهية)(?:[ \\t]+(?:in|with|بـ))?)?`;
const PURCHASE = /purchase|\bpos\b|refund|شراء|استرداد/iu;
const PURCHASE_CARD = new RegExp(
  `(?<!(?:\\bto|إلى|الى)[ \\t]+(?:the[ \\t]+)?)(?<![\\p{L}\\p{M}])(?:card|بطاقة|البطاقة)[ \\t]+[*xX•#]*(${D}{1,4})(?!${D})`,
  'giu',
);
const CURRENCY = `(?:sar|egp|aed|usd|eur|gbp|kwd|qar|bhd|omr|jod|le|sr|riyals?|pounds?|dirhams?|dinars?|dollars?|ريال|جنيه|جم|درهم|دينار|دولار|يورو|ر\\.س)`;
const MONTH = `(?:يناير|فبراير|مارس|أبريل|ابريل|مايو|يونيو|يوليو|أغسطس|اغسطس|سبتمبر|أكتوبر|اكتوبر|نوفمبر|ديسمبر|jan\\w*|feb\\w*|mar\\w*|apr\\w*|may|jun\\w*|jul\\w*|aug\\w*|sep\\w*|oct\\w*|nov\\w*|dec\\w*)`;
const NUMBER = `${D}+(?:[.,٫٬]${D}+)*`;
const ALLOWED = [
  // own partial suffix
  new RegExp(`${OWN}[ \\t]+[*xX•#]*(${D}{1,4})(?!${D})`, 'giu'),
  // amount: currency before or after the figure
  new RegExp(`(?<![0-9A-Za-z٠-٩۰-۹])${CURRENCY}[ \\t]*(${NUMBER})`, 'giu'),
  new RegExp(`(${NUMBER})[ \\t]*${CURRENCY}(?![\\p{L}\\p{M}])`, 'giu'),
  // date or time
  new RegExp(`(${D}+(?:[/:]${D}+)+)`, 'gu'),
  new RegExp(`(${D}{1,2})[ \\t]+${MONTH}(?![\\p{L}\\p{M}])`, 'giu'),
];

function digitRuns(s: string): string[] {
  return s.match(new RegExp(`${D}+`, 'gu')) ?? [];
}

/** Digit runs of `out` that sit inside an allowed span. */
function allowedRuns(out: string): string[] {
  const runs: string[] = [];
  for (const re of ALLOWED) for (const m of out.matchAll(re)) runs.push(...digitRuns(m[1]));
  if (PURCHASE.test(out)) for (const m of out.matchAll(PURCHASE_CARD)) runs.push(...digitRuns(m[1]));
  return runs;
}

function newlyEmitted(before: string, after: string): string[] {
  const left = new Map<string, number>();
  for (const r of digitRuns(before)) left.set(r, (left.get(r) ?? 0) + 1);
  const extra: string[] = [];
  for (const r of digitRuns(after)) {
    const n = left.get(r) ?? 0;
    if (n > 0) left.set(r, n - 1);
    else extra.push(r);
  }
  return extra;
}

type Redaction = { redactPii(t: string): string; redactThirdPartyNames(t: string): string };
for (
  const [commit, base] of [['4d54d258', previous], ['5dae2e2d', older]] as [string, Redaction][]
) {
Deno.test(`FU11: the new redaction emits no number the ${commit} redaction removed, except own suffix, amounts and dates`, () => {
  const texts = collectTexts();
  const leaks: string[] = [];
  let changed = 0;
  for (const t of texts) {
    const before = base.redactThirdPartyNames(base.redactPii(t)).trim();
    const after = redactThirdPartyNames(redactPii(t)).trim();
    if (before !== after) changed++;
    const allowed = allowedRuns(after);
    for (const r of newlyEmitted(before, after)) {
      const i = allowed.indexOf(r);
      if (i >= 0) allowed.splice(i, 1);
      else leaks.push(`${r} in ${JSON.stringify(after)}`);
    }
  }
  // The corpus is large and does exercise the change.
  if (texts.length < 1000 || changed < 20) throw new Error(`corpus too small: ${texts.length} texts, ${changed} changed`);
  assertEquals(leaks, []);
});
}

// Round 4: a tagged third-party name or number of the labelled set that an
// older redaction removed is never emitted again, and every tag is gone now.
Deno.test('round 4: no tagged secret the 5dae2e2d or 4d54d258 redaction removed is emitted now', () => {
  const rows: { id: string; raw: string; secrets: string[] }[] = JSON.parse(
    Deno.readTextFileSync(new URL('./fixtures/sms_leak_labelled_cases.json', import.meta.url)),
  );
  const back: string[] = [];
  let closed = 0;
  for (const r of rows) {
    const now = redactThirdPartyNames(redactPii(r.raw)).trim();
    for (const s of r.secrets) {
      if (now.includes(s)) back.push(`${r.id}: "${s}" in ${JSON.stringify(now)}`);
      else if (older.redactThirdPartyNames(older.redactPii(r.raw)).includes(s)) closed++;
    }
  }
  assertEquals(back, []);
  // The set does exercise leaks the older redaction had.
  if (closed < 40) throw new Error(`only ${closed} tagged secrets leaked at 5dae2e2d`);
});

Deno.test('FU11: the diff check itself catches a third-party number that slips through', () => {
  // A redaction that kept the number after the name would be flagged.
  const before = 'أمر مستديم بمبلغ 1,500 ريال إلى: [REDACTED]';
  for (const after of [
    'أمر مستديم بمبلغ 1,500 ريال إلى: [REDACTED] 7788 سينفذ غدا',
    'أمر مستديم بمبلغ 1,500 ريال إلى: [REDACTED] ٧٧٨٨ سينفذ غدا',
    'أمر مستديم بمبلغ 1,500 ريال إلى: [REDACTED] SA03 8000 سينفذ غدا',
    'أمر مستديم بمبلغ 1,500 ريال إلى حسابك 12345678',
    'أمر مستديم بمبلغ 1,500 ريال إلى: [REDACTED] سينفذ غدا من حساب 556677',
    // Round 4: a card that is the destination, and a card in a transfer.
    'شراء بمبلغ 1,500 ريال إلى بطاقة 7788',
    'أمر مستديم بمبلغ 1,500 ريال إلى: [REDACTED] بطاقة 7788',
  ]) {
    const allowed = allowedRuns(after);
    const leaked = newlyEmitted(before, after).filter((r) => {
      const i = allowed.indexOf(r);
      if (i >= 0) allowed.splice(i, 1);
      return i < 0;
    });
    if (leaked.length === 0) throw new Error(`not caught: ${after}`);
  }
});
