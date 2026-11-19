// Follow-up 3 (independent review S of 7577f347, SM-01..SM-09 and the
// held-out classes): the server side of
// app/test/engine/parser/follow_up3_money_correctness_test.dart. Synthetic
// messages only. Deterministic parse with AI off; a processed capture whose
// meaning is not "record" is rejected by index.ts, so it is not recorded here.
import { assert, assertEquals, assertNotEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { deterministicParse, isDeclinedText, isResolved, messageMeaning, parseSms } from './parse.ts';
import { clauseScope, flowOf, withoutNoticeTails } from './message_meaning.ts';
import cases from './follow_up3_cases.json' with { type: 'json' };
import preRound from './pre_round_not_completed.json' with { type: 'json' };

const RECEIVED = '2026-11-17T10:00:00.000Z';
const outcome = (text: string) =>
  parseSms({ text, rawText: text, sender: 'AlRajhi', receivedAt: RECEIVED, tzOffsetMinutes: 180, locale: 'en',
    allowAi: false });

async function server(text: string) {
  const o = await outcome(text);
  const p = o.parsed;
  const meaning = o.meaning ?? messageMeaning(text);
  const recorded = !!(o.accepted && p.amount && p.currency) && meaning.disposition === 'record';
  return { recorded, credit: p.direction === 'credit', amount: p.amount, currency: p.currency };
}

type Case = { id: string; kind: string; text: string; amount?: number; currency?: string; server?: string; pin?: string };

for (const c of cases.cases as Case[]) {
  Deno.test(`${c.id} [${c.kind}${c.server ? ` server=${c.server}` : ''}] ${c.text}`, async () => {
    const o = await server(c.text);
    if (c.server === 'record') {
      // An OPEN defect (characterization, not acceptance): as at 5dae2e2d.
      assert(o.recorded, c.pin);
      return;
    }
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

// SM-01: nothing that 5dae2e2d read as not completed is ever recorded.
Deno.test('pre-round not-completed texts are never recorded', async () => {
  for (const text of preRound.texts as string[]) {
    assertEquals((await server(text)).recorded, false, text);
    // Nor accepted from an AI answer: the capture never reaches the AI, or
    // its meaning is not "record" (index.ts then rejects any AI result).
    let ai = false;
    await parseSms({ text, rawText: text, sender: 'AlRajhi', receivedAt: RECEIVED, tzOffsetMinutes: 180,
      locale: 'en', allowAi: true, beforeAi: () => { ai = true; return Promise.resolve(false); } });
    assert(!ai || messageMeaning(text).disposition !== 'record', text);
  }
});

Deno.test("another event's status sentence next to a movement is review", () => {
  for (const text of [
    'Purchase of SAR 120.00 at Jarir with card *4521. Previous transaction declined.',
    'Purchase SAR 60.00 at Kudu card *4521 approved. Your earlier attempt was declined.',
  ]) {
    const m = messageMeaning(text);
    assertEquals([m.kind, m.disposition], ['uncertain', 'review'], text);
    assertEquals(isResolved(deterministicParse(text, RECEIVED, 180)), false, text);
  }
});

// SM-03: points or miles credited next to a purchase do not make it a credit,
// and the server does not reject the correct debit.
Deno.test('a purchase that credits points or miles is a debit', async () => {
  for (const text of [
    'Purchase SAR 450.00 at Extra card *4521, 45 points credited to your account',
    'POS SAR 120.00 at Jarir card *4521 - 12 miles credited to your account',
    'شراء 300 ريال لدى جرير بطاقة 4521 وتمت إضافة 30 نقطة إلى حسابك',
  ]) {
    assertNotEquals(flowOf(text), 'credit', text);
    const o = await server(text);
    assertEquals([o.recorded, o.credit], [true, false], text);
  }
});

// SM-02: no entry point throws (fuzz over numbers, commas, dates, card
// suffixes, Arabic-Indic digits and truncation).
Deno.test('no entry point throws (fuzz)', async () => {
  const leads = [
    'SAR 50.00 deducted from your card',
    'Card *4521 charged SAR 35.00 at Kudu on',
    'Amount charged: SAR 12.50, card',
    'Billed AED 99.00 to card',
    'المبلغ المخصوم 75.00 ريال, بطاقة',
    'USD 20.00 at Steam, equivalent SAR 75.10',
    'Purchase of USD 20.00 at Steam card *4521, charged as SAR 75.10',
    'تم خصم 50.00 ريال من بطاقتك',
  ];
  const tails = [
    ' *4521, Jarir, 17/11/2026', ' 4521, 17/11/2026, 21:40', ' 4521,,, 1,2,3,', ' ٤٥٢١، ١٧/١١/٢٠٢٦، ٢١:٤٠',
    ' 1,000,000.00, 0,5, ,5', ' ٣٥٫٠٠, ١٬٢٥٠٫٠٠,', ', balance SAR 940.00,', ' (SAR 1,', ' 12.,', '',
  ];
  const texts: string[] = [];
  for (const l of leads) {
    for (const t of tails) {
      const full = l + t;
      texts.push(full);
      for (let cut = 1; cut < full.length; cut += 7) texts.push(full.slice(0, cut));
    }
  }
  for (const text of texts) {
    try {
      await outcome(text);
      messageMeaning(text);
      isDeclinedText(text);
      deterministicParse(text, RECEIVED, 180);
      flowOf(text);
      withoutNoticeTails(text);
      clauseScope(text, { hasStatusCue: () => false, namesOtherEvent: () => false });
    } catch (e) {
      throw new Error(`threw ${e} on: ${text}`);
    }
  }
});

// SM-04: a notice tail never hides a completed movement; the server does not
// drop it.
Deno.test('a notice tail never hides a completed movement', async () => {
  assert((await server('Purchase SAR 230.00 at Jarir with card *4521, eligible for installments')).recorded);
  // Round 5 (owner decision): a tail with a hedge ("till", «مستحق») makes the
  // movement not clearly completed: a visible review row, never dropped.
  for (const text of [
    'Purchase SAR 120.00 at Jarir card *4521, offer valid till 30 Nov',
    'يرجى العلم بأنه تم خصم 500 ريال لقسط مستحق',
  ]) {
    assertEquals(messageMeaning(text).disposition, 'review', text);
    assertEquals((await server(text)).recorded, false, text);
  }
  for (const text of [
    'Your card bill of SAR 1,200.00 is due on 25 Nov',
    'Earn 5 points on every SAR 10 spent with your card',
  ]) assertEquals(messageMeaning(text).disposition, 'no_movement', text);
});

// SM-05/06: a balance total, a cashback line or a previous purchase is not a
// second movement; two purchases stay in review.
Deno.test('side figures are not second movements; two purchases are review', () => {
  assertEquals(messageMeaning('Purchase SAR 80.00 at Danube card *4521. Cashback SAR 4.00 credited').kind,
    'completed_movement');
  // Round 5: a reference to an earlier operation is a doubt (review).
  assertEquals(messageMeaning('Purchase SAR 120.00 at Jarir card *4521. Previous purchase SAR 80.00 at Panda').kind,
    'uncertain');
  assertEquals(messageMeaning('Purchase SAR 80.00 at Danube card *4521. Purchase SAR 45.00 at Kudu card *4521').kind,
    'multiple_events');
});

// SM-09: no super-linear parse time; the input is bounded.
Deno.test('long inputs parse well inside the request budget', async () => {
  for (const text of [
    'Avl. Bal. '.repeat(2000),
    'SAR 1.00 '.repeat(2500),
    'Purchase SAR 45.00 at Kudu card *4521, '.repeat(600),
    '٤٥٢١, '.repeat(4000),
    'a.'.repeat(10000),
  ]) {
    const t0 = performance.now();
    await outcome(text);
    messageMeaning(text);
    const ms = performance.now() - t0;
    assert(ms < 1500, `${text.length} chars took ${ms.toFixed(0)} ms`);
  }
  const filler = 'Dear valued customer, '.repeat(200);
  assertEquals((await server(`${filler}Purchase of SAR 100.00 at SHOPX declined`)).recorded, false);
});
