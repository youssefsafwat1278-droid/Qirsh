// Round 5 (review X, X-M1/X-M2/X-M4/X-M5): the reviewer's wordings on both
// server paths (rule parse + model, AI-primary) with a stubbed model answering
// the true figure in the right and in the flipped direction. The model's
// direction is recorded only where the rule parser reads the same one
// (localDirection); conflicting cues are not clearly completed; an
// own-account move never reaches the model. Device twin:
// app/test/engine/parser/completion_certainty_test.dart. Synthetic messages.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { localDirection, messageMeaning, parseSms } from './parse.ts';

const DIRECTION: Array<[string, 'credit' | 'debit', number]> = [
  ['Your payroll of SAR 8,500.00 has been posted to account *5678', 'credit', 8500],
  ['Payroll SAR 12,000.00 to account *5678 from Test Corp', 'credit', 12000],
  ['أودع مبلغ 2,000 ريال في حسابك *5678', 'credit', 2000],
  ['Bonus SAR 2,000.00 to account *5678 from Test Corp', 'credit', 2000],
  ['مكافأة 2,000 ريال لحسابك *5678', 'credit', 2000],
  ['Dividend SAR 300.00 to your account *5678', 'credit', 300],
  ['Rent SAR 3,000.00 from Test Tenant arrived in account *5678', 'credit', 3000],
  ['Cashback of SAR 18.40 has been added to your card *4521', 'credit', 18.4],
  ['Annual card fee SAR 250.00 applied to card *4521', 'debit', 250],
  ['You were billed SAR 199.00 by Test Telecom on card *4521', 'debit', 199],
  ['المبلغ المخصوم 75.00 ريال, بطاقة 4521,', 'debit', 75],
  ['سُدد مبلغ 300 ريال لـ Test Electricity من حساب *5678', 'debit', 300],
  ['ATM cash SAR 500.00 card *4521 at Olaya branch', 'debit', 500],
  ['Gym membership SAR 199.00 renewed on card *4521', 'debit', 199],
  ['Debit SAR 45.00 card *4521 Test Diner', 'debit', 45],
  ['Debit transaction: SAR 1,150.00 via SADAD to MOI Traffic Violations', 'debit', 1150],
  ['Credit transaction: SAR 4,000.00 from Test Corp Payroll', 'credit', 4000],
  ['Transaction alert: SAR 5,000.00 debit on account *5678', 'debit', 5000],
  ['Refund for your purchase at Noon: SAR 150.00 returned to card *4521', 'credit', 150],
  ['Standing order of SAR 1,000.00 to Ali executed today', 'debit', 1000],
  ['سداد فاتورة 300 ريال ببطاقتك الائتمانية 4521', 'debit', 300],
  // Review Y (N-M1): the direction the wording states.
  ['Your account *5678 was topped up with SAR 1,800.00 by Test Corp', 'credit', 1800],
  ['قُيّد مبلغ 2,000 ريال لحسابك *5678 من شركة الاختبار', 'credit', 2000],
  ['SAR 500.00 added to your account *5678', 'credit', 500],
  ['Your account *5678 has been topped up with SAR 500.00', 'credit', 500],
  ['قُيّد لحسابك *5678 مبلغ 2,000 ريال', 'credit', 2000],
  ['تم قيد مبلغ 2,000 ريال لحسابك *5678', 'credit', 2000],
  ['SAR 300.00 posted to your account *5678 from Ali', 'credit', 300],
  ['Recharge balance SAR 100 for mobile via card *4521 successful', 'debit', 100],
  ['Balance recharge of SAR 100.00 completed using card *4521', 'debit', 100],
  // Narrow check Z (N-M1b): "added to your card" adds to what is owed.
  ['Installment of SAR 250.00 added to your card *4521', 'debit', 250],
];

// Review Y (N-M2): received person-to-person transfers never reach the model.
const PERSON_TRANSFER: Array<[string, number]> = [
  ['You got SAR 750.00 from Ali via Test Pay', 750],
  ['قيد مبلغ 2,000 ريال لحسابك *5678 من علي', 2000],
  ['You received SAR 300.00 from Sara Ahmed via Test Pay', 300],
  // Narrow check Z (N-M2b).
  ['وصلك 250 ريال من نورة أحمد', 250],
  ['استلمت 400 ريال من محمد العتيبي', 400],
  ['Ali Hassan sent you SAR 120.00', 120],
  ['Your wallet was topped up with SAR 95.00 by Ali Hassan', 95],
];

const CONFLICTING: Array<[string, number]> = [
  ['Purchase SAR 150.00 at Noon card *4521 completed. Merchant confirmation received', 150],
  ['POS Refund SAR 64.50 HYPERPANDA card *4521', 64.5],
  ['تم إيداع 50 ريال استرداد نقدي لبطاقتك 4521 عن عملية شراء بمبلغ 500 ريال', 50],
  ['Purchase SAR 20.00 at Jarir card *4521, cashback SAR 50.00 credited', 20],
  // Narrow check Z (N-M1b): a debt noun with a stated credit wording.
  ['Fee SAR 25.00 added to your account *5678', 25],
  ['قسط 500 ريال أضيف لحسابك *5678', 500],
];

const OWN_ACCOUNT: Array<[string, number]> = [
  ['Your STC Pay wallet was topped up with SAR 100 from Al Rajhi card *4521', 100],
  ['تم تحويل 300 ريال من بطاقتك الائتمانية إلى حسابك الجاري', 300],
];

/** The figure of [amount] as the text writes it, without separators. */
function amountText(text: string, amount: number): string {
  for (const m of text.matchAll(/[0-9][0-9,]*(?:\.[0-9]+)?/g)) {
    const t = m[0].replaceAll(',', '');
    if (Math.abs(Number(t) - amount) < 0.005) return t;
  }
  return String(amount);
}

async function withModel(
  direction: string, amount: number, text: string, run: () => Promise<void>,
): Promise<number> {
  const original = globalThis.fetch;
  const key = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  let calls = 0;
  const answer = {
    is_transaction: true, amount, amount_text: amountText(text, amount), currency: 'SAR',
    type: direction === 'credit' ? 'refund' : 'payment', direction, category: 'other',
  };
  globalThis.fetch = (() => {
    calls++;
    return Promise.resolve(new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: JSON.stringify(answer) }] } }] })));
  }) as typeof fetch;
  try {
    await run();
  } finally {
    globalThis.fetch = original;
    if (key == null) Deno.env.delete('GEMINI_API_KEY');
    else Deno.env.set('GEMINI_API_KEY', key);
  }
  return calls;
}

const parse = (text: string, aiPrimary: boolean) =>
  parseSms({ text, rawText: text, sender: 'SNB', receivedAt: '2026-11-17T09:45:00Z', tzOffsetMinutes: 180,
    locale: 'en', allowAi: true, aiPrimary });

for (const [text, direction, amount] of DIRECTION) {
  Deno.test(`X-M1: the model's direction must be the rule parser's — ${text}`, async () => {
    assertEquals(localDirection(text), direction);
    const flipped = direction === 'credit' ? 'debit' : 'credit';
    for (const primary of [false, true]) {
      await withModel(flipped, amount, text, async () => {
        const o = await parse(text, primary);
        assertEquals([o.accepted, o.parsed.reviewReason], [false, 'direction_contradiction'], `primary ${primary}`);
      });
      await withModel(direction, amount, text, async () => {
        const o = await parse(text, primary);
        assertEquals([o.accepted, o.parsed.direction, o.parsed.amount], [true, direction, amount], `primary ${primary}`);
      });
    }
  });
}

for (const [text, amount] of CONFLICTING) {
  Deno.test(`X-M4: conflicting cues are not clearly completed — ${text}`, async () => {
    assertEquals(messageMeaning(text).reason, 'conflicting_cues');
    assertEquals(localDirection(text), 'unknown');
    for (const primary of [false, true]) {
      for (const direction of ['credit', 'debit']) {
        await withModel(direction, amount, text, async () => {
          assertEquals((await parse(text, primary)).accepted, false, `primary ${primary} ${direction}`);
        });
      }
    }
  });
}

for (const [text, amount] of PERSON_TRANSFER) {
  Deno.test(`N-M2: a person-to-person transfer never reaches the model — ${text}`, async () => {
    for (const primary of [false, true]) {
      const calls = await withModel('debit', amount, text, async () => {
        const o = await parse(text, primary);
        assertEquals(o.accepted && o.parsed.direction === 'debit', false);
      });
      assertEquals(calls, 0);
    }
  });
}

for (const [text, amount] of OWN_ACCOUNT) {
  Deno.test(`X-M5: an own-account move never reaches the model — ${text}`, async () => {
    for (const primary of [false, true]) {
      const calls = await withModel('debit', amount, text, async () => {
        assertEquals((await parse(text, primary)).accepted, false);
      });
      assertEquals(calls, 0);
    }
  });
}
