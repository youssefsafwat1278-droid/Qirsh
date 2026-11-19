// Follow-up 4 (independent re-review S at 7dd6efa8: NEW-1, NEW-2, NEW-3,
// SM-06, SM-07 and the held-out classes): the server side of
// app/test/engine/parser/follow_up4_money_correctness_test.dart. Synthetic
// messages only. Deterministic parse with AI off; a processed capture whose
// meaning is not "record" is rejected by index.ts, so it is not recorded here.
import { assert, assertEquals, assertNotEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { messageMeaning, parseSms } from './parse.ts';
import { flowOf } from './message_meaning.ts';
import cases from './follow_up4_cases.json' with { type: 'json' };

const RECEIVED = '2026-11-17T10:00:00.000Z';
const outcome = (text: string) =>
  parseSms({ text, rawText: text, sender: 'AlRajhi', receivedAt: RECEIVED, tzOffsetMinutes: 180, locale: 'en',
    allowAi: false });

async function server(text: string) {
  const o = await outcome(text);
  const p = o.parsed;
  const meaning = o.meaning ?? messageMeaning(text);
  const recorded = !!(o.accepted && p.amount && p.currency) && meaning.disposition === 'record';
  return { recorded, credit: p.direction === 'credit', amount: p.amount, currency: p.currency, meaning };
}

type Case = { id: string; kind: string; text: string; amount?: number; currency?: string; server?: string };

for (const c of cases.cases as Case[]) {
  const label = c.text.length > 120 ? `${c.text.slice(0, 120)}…` : c.text;
  Deno.test(`${c.id} [${c.kind}${c.server ? ` server=${c.server}` : ''}] ${label}`, async () => {
    const o = await server(c.text);
    if (c.kind === 'n' || c.kind === 'r' || c.server === 'review') {
      assertEquals(o.recorded, false);
      return;
    }
    assert(o.recorded, 'recorded');
    assertEquals(o.credit, c.kind === 'c');
    assert(Math.abs((o.amount ?? NaN) - c.amount!) < 0.005, `amount ${o.amount}`);
    assertEquals(o.currency, c.currency);
  });
}

// NEW-1: direction comes from the primary clause; a later reward or cashback
// credit with a smaller or no figure is a side event.
Deno.test('a purchase with a reward credit clause is a debit', () => {
  for (const text of [
    'Purchase SAR 45.00 at Noon card *4521, cashback SAR 2.00 credited to your account',
    'Purchase SAR 45.00 at Noon card *4521, Qitaf credited to your account',
    'شراء 45 ريال لدى نون بطاقة 4521، تم إيداع استرداد نقدي 2 ريال',
  ]) {
    assertNotEquals(flowOf(text.toLowerCase()), 'credit', text);
  }
});

// NEW-2: a completed primary clause is never no_movement because of a tail.
Deno.test('a completed purchase with a reward or reminder tail is recorded', () => {
  for (const text of [
    'Purchase SAR 230.00 at Jarir with card *4521 and earn rewards',
    'Purchase SAR 230.00 at Jarir with card *4521, total spent this month SAR 3,200',
  ]) {
    assertEquals(messageMeaning(text).kind, 'completed_movement', text);
  }
  // Round 5 (owner decision): a reminder tail is a doubt: review, never a notice.
  assertEquals(messageMeaning('خصم 99 ريال اشتراك شاهد من بطاقتك 4521، تذكير بالتجديد').kind, 'uncertain');
});

// NEW-3: a text over the bound is read in part, so it is never recorded —
// also when normalizing the bounded text changes its length (Arabic).
Deno.test('a text over the bound with a status in the unread middle is review', async () => {
  const pad = Array(20).fill('Dear valued customer, thank you for banking with us.').join(' ');
  for (const head of ['Purchase SAR 45.00 at Jarir card *4521.', 'شراء 45 ريال لدى جرير بطاقة 4521.']) {
    const text = `${head} ${pad} Transaction declined. ${pad} Thank you.`;
    assert(text.length > 2000);
    const o = await server(text);
    assertEquals([o.recorded, o.meaning.kind, o.meaning.reason], [false, 'uncertain', 'over_length'], head);
  }
  assert((await server('Purchase SAR 45.00 at Jarir card *4521')).recorded);
});

// SM-07: device and server agree on G000 (tip total) and T79.
Deno.test('a tip with a second figure is review; an unauthorised one is not completed', () => {
  const tip = messageMeaning('Purchase SAR 85.00 at Test Cafe, tip SAR 15.00, total SAR 100.00');
  assertEquals([tip.kind, tip.reason], ['uncertain', 'tip_component']);
  const t79 = messageMeaning('Transaction unauthorised: SAR 100.00 at CAFE ONE');
  assertEquals([t79.kind, t79.reason], ['not_completed', 'declined_or_failed']);
});
