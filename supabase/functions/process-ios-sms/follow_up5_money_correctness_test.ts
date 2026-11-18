// Follow-up 5 (held-out sibling families a-f and reviewer S3): the server
// side of app/test/engine/parser/follow_up5_money_correctness_test.dart. Synthetic
// messages only. Deterministic parse with AI off; a processed capture whose
// meaning is not "record" is rejected by index.ts, so it is not recorded here.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { messageMeaning, parseSms } from './parse.ts';
import { isRefundPending, merchantFigureCount, partsTotal } from './message_meaning.ts';
import cases from './follow_up5_cases.json' with { type: 'json' };

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

// (a) a refund or reversal is completed only when a clause states the credit
// happened.
Deno.test('a requested or reviewed refund with no completed credit is pending', () => {
  for (const text of [
    'Refund of SAR 120.00 initiated. It will be credited within 5 days.',
    'Your refund request of EGP 300.00 has been submitted. Expected in 7 days.',
    'تم استلام طلب استرجاع مبلغ 150 ريال وهو قيد المراجعة',
  ]) {
    assert(isRefundPending(text.toLowerCase()), text);
    const m = messageMeaning(text);
    assertEquals([m.kind, m.reason], ['not_completed', 'pending'], text);
  }
  assertEquals(isRefundPending('refund of sar 120.00 credited to your account'), false);
});

// (b) setting up or scheduling is not execution.
Deno.test('a scheduled standing order is a notice; an executed one is not', () => {
  const m = messageMeaning('Standing order of SAR 500.00 to Ali will be executed on 01/12');
  assertEquals([m.kind, m.reason], ['no_movement_notice', 'scheduled_or_expected']);
  assertEquals(messageMeaning('أمر دائم بمبلغ 2000 ريال إلى المالك نُفذ من حسابك *5678').reason === 'scheduled_or_expected', false);
  // No future or scheduling cue (the verb redacted away): read as before.
  assertEquals(messageMeaning('أمر مستديم 2000 ريال إلى: [REDACTED] من حسابك').reason === 'scheduled_or_expected', false);
});

// (c) money between two named own-account types is an own-account move.
Deno.test('a transfer between named account types is own-account', () => {
  assertEquals(messageMeaning('SAR 1,000.00 transferred from your Savings account to your Current account').kind,
    'own_account_transfer');
});

// (d) two merchant figures in one sentence are two events.
Deno.test('two purchases in one sentence count two merchant figures', () => {
  assertEquals(merchantFigureCount('purchases: sar 30.00 at kudu and sar 55.00 at panda'), 2);
});

// (e) a total with its parts is the total, never a part.
Deno.test('a total stated with its parts', () => {
  assertEquals(partsTotal('dinner aed 260.00 + 10% service aed 26.00, total aed 286.00'), 286);
  assertEquals(partsTotal('purchase sar 100.00, fee sar 0.00, available balance sar 5,000.00'), null);
});

// S3: a bill paid WITH a credit card is a purchase, not a card repayment.
Deno.test('a bill paid with a credit card is recorded', async () => {
  const o = await server('سداد فاتورة الاتصالات 230 ريال ببطاقتك الائتمانية 4521');
  assertEquals([o.recorded, o.credit, o.amount], [true, false, 230]);
});
