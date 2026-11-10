import { assert, assertEquals, assertNotEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { deterministicParse, isResolved, parseSms } from './parse.ts';

const RECEIVED = '2026-09-07T19:30:00.000Z';

Deno.test('AI primary: literal bank clock wins over an AI timestamp mislabeled UTC', async () => {
  const text = 'IPN transfer sent with amount of EGP 1.00 from 1938 on 09/11 at 06:45 PM. Ref# abc123.';
  const stub = stubGemini({ is_transaction: true, amount: 1, amount_text: '1.00',
    currency: 'EGP', type: 'transfer', direction: 'debit', category: 'transfers',
    occurredAt: '2026-11-09T18:45:00Z' });
  try {
    const r = await parseSms({ text, rawText: text, sender: 'BANK',
      receivedAt: '2026-11-09T16:45:48Z', tzOffsetMinutes: 120,
      locale: 'en', allowAi: true, aiPrimary: true });
    assertEquals(r.accepted, true);
    assertEquals(r.parsed.parserSource, 'ai');
    assertEquals(r.parsed.occurredAt, '2026-11-09T16:45:00.000Z');
    assertEquals(r.parsed.comparisonTimestampSource, 'sms_body');
  } finally { stub.restore(); }
});

Deno.test('AI primary: local midnight uses the SMS date across the UTC day boundary', async () => {
  const text = 'IPN transfer sent with amount of EGP 1.00 on 10/11 at 12:05 AM.';
  const stub = stubGemini({ is_transaction: true, amount: 1, amount_text: '1.00',
    currency: 'EGP', type: 'transfer', direction: 'debit', category: 'transfers',
    occurredAt: '2026-11-10T00:05:00' });
  try {
    const r = await parseSms({ text, rawText: text, sender: 'BANK',
      receivedAt: '2026-11-09T22:05:48Z', tzOffsetMinutes: 120,
      locale: 'en', allowAi: true, aiPrimary: true });
    assertEquals(r.accepted, true);
    assertEquals(r.parsed.occurredAt, '2026-11-09T22:05:00.000Z');
  } finally { stub.restore(); }
});

const RESOLVED_SMS = 'Purchase of EGP 250.00 at CARREFOUR with card ending 1234 on 2026-09-07';
const IGNORED_SMS = 'Your OTP is 123456 for EGP 10.00 purchase';
// Clean card/ATM SMS: amount+currency+direction, NO merchant -> RESOLVED (merchant optional)
const CLEAN_SMS = [
  'Debited SAR 50.00 from card ending 1234',
  'ATM withdrawal of SAR 500.00 card 1234',
  'تم خصم 50.00 ر.س من بطاقتك 1234',
];
// amount+currency, direction unknown, no merchant -> unresolved, HYBRID
const HYBRID_SMS = 'EGP 99.50 ZARA online';
// direction unknown, no merchant -> unresolved, HYBRID
const HYBRID_NO_DIR_SMS = 'Your card 1234 was used for EGP 99.50';
// no amount/currency -> unresolved, AI-only ($ is not a deterministic currency)
const AI_ONLY_SMS = 'Purchase $20.00 at SHOP';

type Stub = { calls: number; restore: () => void };

function stubGemini(candidate: Record<string, unknown> | null, status = 200): Stub {
  const original = globalThis.fetch;
  const previousKey = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  const stub: Stub = {
    calls: 0,
    restore: () => {
      globalThis.fetch = original;
      if (previousKey == null) Deno.env.delete('GEMINI_API_KEY');
      else Deno.env.set('GEMINI_API_KEY', previousKey);
    },
  };
  globalThis.fetch = (() => {
    stub.calls++;
    const body = candidate == null
      ? {}
      : { candidates: [{ content: { parts: [{ text: JSON.stringify(candidate) }] } }] };
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  }) as typeof fetch;
  return stub;
}

async function run(text: string, allowAi: boolean, candidate: Record<string, unknown> | null) {
  const stub = stubGemini(candidate);
  try {
    const outcome = await parseSms({
      text,
      rawText: text,
      sender: 'BANK',
      receivedAt: RECEIVED,
      tzOffsetMinutes: 180,
      locale: 'en',
      allowAi,
    });
    return { ...outcome, calls: stub.calls };
  } finally {
    stub.restore();
  }
}

const GOOD_AI = {
  amount: 20,
  amount_text: '20.00',
  currency: 'USD',
  merchant: 'SHOP',
  type: 'payment',
  direction: 'debit',
};

Deno.test('deterministic fixtures have the intended shape', () => {
  assert(isResolved(deterministicParse(RESOLVED_SMS, RECEIVED, 180)));
  assert(!isResolved(deterministicParse(HYBRID_SMS, RECEIVED, 180)));
  assert(!isResolved(deterministicParse(HYBRID_NO_DIR_SMS, RECEIVED, 180)));
  const aiOnly = deterministicParse(AI_ONLY_SMS, RECEIVED, 180);
  assertEquals([aiOnly.amount, aiOnly.currency], [undefined, undefined]);
});

Deno.test('RESOLVED => consult AI; reject mismatched AI and keep local', async () => {
  const r = await run(RESOLVED_SMS, true, GOOD_AI);
  assertEquals(r.calls, 1);
  assertEquals(r.accepted, true);
  assertEquals(r.parsed.parserSource, 'deterministic');
  assertEquals(r.parsed.amount, 250);
});

Deno.test('clean card/ATM SMS (no merchant) => RESOLVED: consult AI only with consent', async () => {
  for (const text of CLEAN_SMS) {
    for (const allowAi of [true, false]) {
      const r = await run(text, allowAi, GOOD_AI);
      assertEquals(r.calls, allowAi ? 1 : 0, text);
      assertEquals(r.accepted, true, text);
      assertEquals(r.parsed.parserSource, 'deterministic');
      assertEquals(r.parsed.direction, 'debit');
      assertEquals(r.parsed.merchant, undefined);
    }
  }
});

Deno.test('direction unknown => still UNRESOLVED: goes to AI when allowed, rejected otherwise', async () => {
  const withAi = await run(HYBRID_NO_DIR_SMS, true, GOOD_AI);
  assertEquals(withAi.calls, 1);
  const noAi = await run(HYBRID_NO_DIR_SMS, false, GOOD_AI);
  assertEquals([noAi.calls, noAi.accepted], [0, false]);
});

Deno.test('IGNORED => zero AI calls + rejected, even with AI allowed and a transaction-shaped AI answer', async () => {
  const r = await run(IGNORED_SMS, true, { amount: 10, amount_text: '10.00', currency: 'EGP', type: 'payment' });
  assertEquals(r.calls, 0);
  assertEquals(r.accepted, false);
  assertEquals(r.parsed.amount, undefined);
  assertEquals(r.parsed.confidence, 0);
});

Deno.test('UNRESOLVED + AI allowed => exactly ONE AI call', async () => {
  for (const text of [HYBRID_SMS, HYBRID_NO_DIR_SMS, AI_ONLY_SMS]) {
    const r = await run(text, true, GOOD_AI);
    assertEquals(r.calls, 1, text);
  }
});

Deno.test('UNRESOLVED + AI not allowed => zero AI calls + rejected', async () => {
  for (const text of [HYBRID_SMS, HYBRID_NO_DIR_SMS, AI_ONLY_SMS]) {
    const r = await run(text, false, GOOD_AI);
    assertEquals(r.calls, 0, text);
    assertEquals(r.accepted, false, text);
  }
});

Deno.test('AI-only validator PASS => accepted; FAIL => rejected', async () => {
  const pass = await run(AI_ONLY_SMS, true, GOOD_AI);
  assertEquals(pass.accepted, true);
  assertEquals(pass.parsed.amount, 20);
  assertEquals(pass.parsed.amount_text, '20.00');
  assertEquals(pass.parsed.currency, 'USD');
  assertEquals(pass.parsed.parserSource, 'ai_hybrid');

  const ungroundedAmount = await run(AI_ONLY_SMS, true, { ...GOOD_AI, amount: 21, amount_text: '21.00' });
  assertEquals(ungroundedAmount.accepted, false);
  const ungroundedCurrency = await run(AI_ONLY_SMS, true, { ...GOOD_AI, currency: 'SAR' });
  assertEquals(ungroundedCurrency.accepted, false);
  const noAmountText = await run(AI_ONLY_SMS, true, { amount: 20, currency: 'USD' });
  assertEquals(noAmountText.accepted, false);
  const contradicts = await run('Deposit $20.00 from SHOP', true, { ...GOOD_AI, type: 'payment' });
  assertEquals(contradicts.accepted, false);
});

Deno.test('AI unavailable / not a transaction / HTTP failure => rejected, still one call', async () => {
  const none = await run(AI_ONLY_SMS, true, { is_transaction: false });
  assertEquals([none.calls, none.accepted], [1, false]);
  const stub = stubGemini({ amount: 20 }, 500);
  try {
    const r = await parseSms({
      text: AI_ONLY_SMS,
      rawText: AI_ONLY_SMS,
      sender: '',
      receivedAt: RECEIVED,
      tzOffsetMinutes: null,
      locale: '',
      allowAi: true,
    });
    assertEquals([stub.calls, r.accepted], [1, false]);
  } finally {
    stub.restore();
  }
});

Deno.test('AI confidence (0.01 vs 0.99, top-level or absent) never changes the outcome', async () => {
  for (const text of [HYBRID_SMS, AI_ONLY_SMS]) {
    const cand = text === AI_ONLY_SMS
      ? GOOD_AI
      : { amount: 99.5, amount_text: '99.50', currency: 'EGP', merchant: 'ZARA', direction: 'debit' };
    const low = await run(text, true, { ...cand, confidence: 0.01 });
    const high = await run(text, true, { ...cand, confidence: 0.99 });
    const none = await run(text, true, cand);
    assertEquals(low.accepted, true);
    assertEquals(low.parsed, high.parsed);
    assertEquals(low.parsed, none.parsed);
  }
  // A failing candidate stays failing at confidence 0.99.
  const bad = await run(AI_ONLY_SMS, true, { ...GOOD_AI, amount: 21, amount_text: '21.00', confidence: 0.99 });
  assertEquals(bad.accepted, false);
});

Deno.test('contradictory AI amount/currency never replace deterministic values', async () => {
  for (
    const cand of [
      { amount: 77, amount_text: '77.00', currency: 'EGP', merchant: 'ZARA' },
      { amount: 99.5, amount_text: '99.50', currency: 'SAR', merchant: 'ZARA' },
    ]
  ) {
    const r = await run(HYBRID_SMS, true, cand);
    assertEquals(r.accepted, false);
    assertEquals(r.parsed.amount, 99.5);
    assertEquals(r.parsed.currency, 'EGP');
    assertEquals(r.parsed.parserSource, 'deterministic');
  }
});

Deno.test('contradictory AI merchant never replaces a deterministic merchant', async () => {
  // An ungrounded AI merchant must not replace the local merchant.
  const text = 'Transaction of EGP 60.00 at CARREFOUR';
  const det = deterministicParse(text, RECEIVED, 180);
  assertEquals(det.merchant, 'CARREFOUR');
  assertEquals(det.direction, 'unknown');
  const r = await run(text, true, {
    amount: 60,
    amount_text: '60.00',
    currency: 'EGP',
    merchant: 'AMAZON',
    type: 'payment',
    direction: 'debit',
  });
  assertEquals(r.calls, 1);
  assertEquals(r.accepted, true);
  assertEquals(r.parsed.merchant, 'CARREFOUR');
});

Deno.test('hybrid fills ONLY missing grounded fields', async () => {
  // merchant: grounded fills; ungrounded is dropped (not a rejection).
  const grounded = await run(HYBRID_SMS, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    merchant: 'ZARA',
    direction: 'debit',
  });
  assertEquals(grounded.accepted, true);
  assertEquals(grounded.parsed.merchant, 'ZARA');
  assertEquals(grounded.parsed.amount, 99.5);
  assertEquals(grounded.parsed.direction, 'debit'); // filled: deterministic had none
  const ungrounded = await run(HYBRID_SMS, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    merchant: 'AMAZON',
    direction: 'debit',
  });
  assertEquals(ungrounded.accepted, true);
  assertEquals(ungrounded.parsed.merchant, undefined);

  // direction: filled only when deterministic had none, and never against the wording.
  const dirFill = await run(HYBRID_NO_DIR_SMS, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    merchant: 'ZARA',
    direction: 'debit',
    type: 'payment',
  });
  assertEquals(dirFill.accepted, true);
  assertEquals(dirFill.parsed.direction, 'debit');
  assertEquals(dirFill.parsed.merchant, undefined); // ZARA not in this text
  assertEquals(dirFill.parsed.last4, '1234'); // deterministic, untouched
  // last4: grounded fills, ungrounded dropped.
  const last4Text = 'EGP 99.50 ZARA online ref 4321';
  const l4 = await run(last4Text, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    merchant: 'ZARA',
    last4: '4321',
    direction: 'debit',
  });
  assertEquals(l4.parsed.last4, '4321');
  const l4bad = await run(last4Text, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    merchant: 'ZARA',
    last4: '9999',
    direction: 'debit',
  });
  assertEquals(l4bad.parsed.last4, undefined);

  // A hybrid candidate with no resolvable direction is NOT accepted.
  const noDir = await run(HYBRID_SMS, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    merchant: 'ZARA',
  });
  assertEquals(noDir.accepted, false);
  const transferOnly = await run(HYBRID_SMS, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    type: 'transfer',
  });
  assertEquals(transferOnly.accepted, false);
});

Deno.test('informational confidence: formula over final fields, AI-filled direction not counted', async () => {
  const r = await run(HYBRID_NO_DIR_SMS, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    direction: 'debit',
    type: 'payment',
  });
  assertEquals(r.parsed.direction, 'debit');
  // 0.55 money + 0.05 last4; no merchant; direction was AI-filled so +0 .
  assertEquals(Math.round((r.parsed.confidence ?? 0) * 100), 60);
});

Deno.test('AI date outside the window is dropped, inside is kept', async () => {
  const inside = await run(AI_ONLY_SMS, true, { ...GOOD_AI, occurredAt: '2026-09-06T10:00:00Z' });
  assertEquals(inside.parsed.comparisonTimestampSource, 'sms_body');
  const outside = await run(AI_ONLY_SMS, true, { ...GOOD_AI, occurredAt: '2026-01-01T10:00:00Z' });
  assertEquals(outside.accepted, true);
  assertEquals(outside.parsed.comparisonTimestampSource, 'received_at');
  assertNotEquals(outside.parsed.comparisonTimestamp, '2026-01-01T10:00:00.000Z');
});

Deno.test('resolved unknown sender: validated AI type and category override local', async () => {
  const text = 'Purchase of EGP 56.78 at Orange - Home Internet with card ending 5398';
  const stub = stubGemini({ amount: 56.78, amount_text: '56.78', currency: 'EGP',
    merchant: 'Orange - Home Internet', type: 'payment', direction: 'debit', category: 'bills' });
  try {
    let gates = 0;
    const result = await parseSms({ text, rawText: text, sender: '', receivedAt: RECEIVED,
      tzOffsetMinutes: null, locale: 'en', allowAi: true,
      beforeAi: () => { gates++; return Promise.resolve(true); } });
    assertEquals([stub.calls, gates], [1, 1]);
    assertEquals(result.accepted, true);
    assertEquals(result.parsed.category, 'bills');
    assertEquals(result.parsed.type, 'payment');
    assertEquals(result.parsed.parserSource, 'ai_hybrid');
  } finally { stub.restore(); }
});

Deno.test('resolved capture cannot bypass a revoked dispatch gate', async () => {
  const stub = stubGemini(GOOD_AI);
  try {
    const result = await parseSms({ text: RESOLVED_SMS, rawText: RESOLVED_SMS,
      sender: 'unknown', receivedAt: RECEIVED, tzOffsetMinutes: null, locale: 'en',
      allowAi: true, beforeAi: () => Promise.resolve(false) });
    assertEquals(stub.calls, 0);
    assertEquals(result.aiDenied, true);
    assertEquals(result.accepted, false);
  } finally { stub.restore(); }
});

Deno.test('AI unavailable preserves a resolved local capture', async () => {
  const result = await run(RESOLVED_SMS, true, null);
  assertEquals(result.calls, 1);
  assertEquals(result.accepted, true);
  assertEquals(result.parsed.parserSource, 'deterministic');
});

Deno.test('validated AI replaces a specific local category and type', async () => {
  const text = 'ATM withdrawal of EGP 56.78 at CARREFOUR';
  const local = deterministicParse(text, RECEIVED, null);
  assertEquals([local.type, local.category], ['payment', 'groceries']);
  const result = await run(text, true, { amount: 56.78, amount_text: '56.78',
    currency: 'EGP', type: 'withdrawal', direction: 'debit', category: 'cash' });
  assertEquals(result.accepted, true);
  assertEquals([result.parsed.type, result.parsed.category], ['withdrawal', 'cash']);
});

// Phone report: every InstaPay transfer showed its HOUR ("01", "10", "12") as
// the merchant, because "(?:at|@)\s+(...)" captured "01" from "at 01:43 AM".
Deno.test('IPN/InstaPay transfers name InstaPay, never the time, as merchant', () => {
  const texts = [
    'IPN transfer sent with amount of EGP 1.00 from 1938 on 28/10 at 01:43 AM. Ref# 22762b03. For more details call 16607',
    'IPN transfer sent with amount of EGP 100.00 from 1938 on 05/10 at 10:37 AM. Ref# 1a2b3c4d',
    'Your account was credited by EGP 2000 on 14-06 23:10 IPN REF# 998877',
    'تم تحويل مبلغ 1.00 جنيه عبر انستاباي يوم 04/10 الساعة 12:42',
  ];
  for (const text of texts) {
    assertEquals(deterministicParse(text, RECEIVED, 180).merchant, 'InstaPay', text);
  }
});

Deno.test('a time, date or reference after "at" is never a merchant', () => {
  for (const text of [
    'Debited EGP 50.00 from card ending 1234 at 01:43 AM',
    'Purchase of EGP 50.00 at 10:37 with card ending 1234',
    'Purchase of EGP 50.00 at 28/10 with card ending 1234',
  ]) {
    assertEquals(deterministicParse(text, RECEIVED, 180).merchant, undefined, text);
  }
  // A real merchant after "at" still parses, and "at" inside a word does not.
  assertEquals(deterministicParse(RESOLVED_SMS, RECEIVED, 180).merchant, 'CARREFOUR');
  assertNotEquals(
    deterministicParse('Purchase of EGP 50.00 combat 12 with card ending 1234', RECEIVED, 180).merchant,
    '12',
  );
});

// Phone report: "12:02 AM" showed as 12:02 PM, because the meridiem was ignored
// and a date with no time defaulted to noon. Times are local (UTC+3 here).
Deno.test('AM/PM and Arabic ص/م set the right hour; a bare date keeps the received time', () => {
  const at = (text: string, receivedAt = '2026-10-29T09:30:00.000Z') =>
    deterministicParse(text, receivedAt, 180).comparisonTimestamp;
  const cases: Array<[string, string]> = [
    ['IPN transfer sent with amount of EGP 1.00 from 1938 on 29/10 at 12:02 AM. Ref# 1a', '2026-10-28T21:02:00.000Z'],
    ['IPN transfer sent with amount of EGP 1.00 from 1938 on 28/10 at 01:43 AM. Ref# 1a', '2026-10-27T22:43:00.000Z'],
    ['IPN transfer sent with amount of EGP 1.00 from 1938 on 28/10 at 01:43 PM. Ref# 1a', '2026-10-28T10:43:00.000Z'],
    ['IPN transfer sent with amount of EGP 1.00 from 1938 on 28/10 at 12:15 PM. Ref# 1a', '2026-10-28T09:15:00.000Z'],
    ['Purchase EGP 10.00 at SHELL on 28/10 at 9:05 p.m. card 1234', '2026-10-28T18:05:00.000Z'],
    ['تم خصم 89.00 جنيه لدى STARBUCKS يوم 28/10 الساعة 09:15 م', '2026-10-28T18:15:00.000Z'],
    ['تم خصم 89.00 جنيه لدى STARBUCKS يوم 28/10 الساعة 09:15 ص', '2026-10-28T06:15:00.000Z'],
    ['تم خصم 89.00 جنيه لدى STARBUCKS يوم 28/10 الساعة 12:30 صباحا', '2026-10-27T21:30:00.000Z'],
    ['تم خصم 89.00 جنيه لدى STARBUCKS يوم 28/10 الساعة 07:30 مساءً', '2026-10-28T16:30:00.000Z'],
    // 24-hour times and a following Arabic word ("من") are left as written.
    ['تم تحويل 5.00 جنيه يوم 28/10 الساعة 13:29 من حسابك', '2026-10-28T10:29:00.000Z'],
    ['Debit transaction EGP 312.75 at PHARMACY by card 5512 on 27/10/2026 18:04', '2026-10-27T15:04:00.000Z'],
    ['Purchase EGP 20.00 on 2026-10-28 11:40 PM card 1234', '2026-10-28T20:40:00.000Z'],
    ['Purchase EGP 55.00 at COSTA COFFEE at 11:50 PM card 1177', '2026-10-29T20:50:00.000Z'],
  ];
  for (const [text, expected] of cases) assertEquals(at(text), expected, text);
  // A date without a time: the received time on the received day, noon otherwise.
  assertEquals(at('Your account was credited with salary EGP 18,500.00 on 29/10/2026'), '2026-10-29T09:30:00.000Z');
  assertEquals(at('Your account was credited with salary EGP 18,500.00 on 25/10/2026'), '2026-10-25T09:00:00.000Z');
});
