// Gemini-first phase 4: the shape memory on the AI-primary path. A message of
// an active template of the same bank sender is read without Gemini, through
// every check a model answer gets; anything else (another wording, an unknown
// merchant, a reading the checks refuse) goes to Gemini as before. 1 in 50
// matches is still read by Gemini, whose answer wins and drops a template it
// disagrees with. Synthetic messages; the model is stubbed (no network).
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { type ParseOutcome, parseSms } from './parse.ts';
import { handleProcessIosSms } from './index.ts';
import { fakeCapture } from './capture_rpc_fake.ts';
import {
  type AnalysisMemoryReader,
  buildShape,
  type MerchantMemory,
  type ShapeTemplate,
} from '../_shared/sms_shape_memory.ts';

const MSG = 'Purchase of EGP 250.00 at SAOOD MARKET with card ending 1234 on 18/11/2026 20:15. Available balance EGP 1,000.00';
const NEXT = 'Purchase of EGP 75.50 at KASHIERFast with card ending 1234 on 19/11/2026 08:02. Available balance EGP 924.50';
const SAOOD_ANSWER = {
  is_transaction: true, message_type: 'transaction', status: 'completed', amount: 250, amount_text: '250.00',
  currency: 'EGP', type: 'payment', direction: 'debit', category: 'groceries', merchant: 'SAOOD MARKET',
  counterparty_kind: 'merchant', last4: '1234',
};
const NEXT_ANSWER = { ...SAOOD_ANSWER, amount: 75.5, amount_text: '75.50', merchant: 'KASHIERFast', category: 'shopping' };

const TEMPLATE: ShapeTemplate = {
  hash: 'a'.repeat(64),
  skeleton: buildShape(MSG, { amountText: '250.00', merchant: 'SAOOD MARKET', last4: '1234' })!,
  reading: { currency: 'EGP', type: 'payment', direction: 'debit', counterparty_kind: 'merchant' },
};

function memory(
  templates: ShapeTemplate[],
  merchants: Record<string, MerchantMemory> = { KASHIERFAST: { category: 'shopping', displayName: null, lookupState: 'none' } },
): AnalysisMemoryReader {
  return {
    templates: (key) => Promise.resolve(key === 'CIB' ? templates : []),
    merchant: (key) => Promise.resolve(merchants[key] ?? null),
  };
}

async function analyse(text: string, answer: Record<string, unknown>, opts: {
  memory?: AnalysisMemoryReader;
  random?: () => number;
  sender?: string;
} = {}): Promise<{ outcome: ParseOutcome; calls: number }> {
  const original = globalThis.fetch;
  const previousKey = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  let calls = 0;
  globalThis.fetch = (() => {
    calls++;
    const body = JSON.stringify({ candidates: [{ content: { parts: [{ text: JSON.stringify(answer) }] } }] });
    return Promise.resolve(new Response(body));
  }) as typeof fetch;
  try {
    const outcome = await parseSms({
      text, rawText: text, sender: opts.sender ?? 'CIB', receivedAt: '2026-11-19T18:40:00Z', tzOffsetMinutes: 120,
      locale: 'en', allowAi: true, aiPrimary: true, memory: opts.memory, random: opts.random ?? (() => 0.5),
    });
    return { outcome, calls };
  } finally {
    globalThis.fetch = original;
    if (previousKey == null) Deno.env.delete('GEMINI_API_KEY');
    else Deno.env.set('GEMINI_API_KEY', previousKey);
  }
}

/** What a capture records: the fields the device imports. */
function recorded(o: ParseOutcome) {
  const p = o.parsed;
  return { accepted: o.accepted, amount: p.amount, amount_text: p.amount_text, currency: p.currency, type: p.type,
    direction: p.direction, merchant: p.merchant, category: p.category, counterpartyKind: p.counterpartyKind,
    last4: p.last4, occurredAt: p.occurredAt, reasonCode: p.reasonCode };
}

Deno.test('a Gemini read teaches the shape (no figure or merchant in it) and the merchant code', async () => {
  const { outcome, calls } = await analyse(MSG, SAOOD_ANSWER, { memory: memory([]) });
  assertEquals(calls, 1);
  assert(outcome.accepted);
  assertEquals(outcome.memory?.merchant, { codeKey: 'SAOOD MARKET', category: 'groceries' });
  assertEquals(outcome.memory?.shape?.senderKey, 'CIB');
  assertEquals(outcome.memory?.shape?.skeleton, TEMPLATE.skeleton);
  assertEquals(outcome.memory?.shape?.reading, TEMPLATE.reading);
});

Deno.test('a message of an active template is read without Gemini, exactly as Gemini reads it', async () => {
  const fromTemplate = await analyse(NEXT, NEXT_ANSWER, { memory: memory([TEMPLATE]) });
  assertEquals(fromTemplate.calls, 0);
  assertEquals(fromTemplate.outcome.parsed.analysisSource, 'template');
  assertEquals(fromTemplate.outcome.aiInvoked, false);
  assertEquals(fromTemplate.outcome.memory, { templateHit: TEMPLATE.hash });
  const fromModel = await analyse(NEXT, NEXT_ANSWER);
  assertEquals(fromModel.calls, 1);
  assertEquals(recorded(fromTemplate.outcome), recorded(fromModel.outcome));
  assertEquals(fromTemplate.outcome.parsed.amount_text, '75.50');
  assertEquals(fromTemplate.outcome.parsed.merchant, 'KASHIERFast');
});

Deno.test('templates are per bank sender', async () => {
  const { calls, outcome } = await analyse(NEXT, NEXT_ANSWER, { memory: memory([TEMPLATE]), sender: 'NBE' });
  assertEquals(calls, 1);
  assertEquals(outcome.parsed.analysisSource, undefined);
});

Deno.test('a merchant the memory does not know (or knows with conflicting categories) goes to Gemini', async () => {
  const unknown = await analyse(NEXT, NEXT_ANSWER, { memory: memory([TEMPLATE], {}) });
  assertEquals(unknown.calls, 1);
  const conflict = await analyse(NEXT, NEXT_ANSWER, {
    memory: memory([TEMPLATE], { KASHIERFAST: { category: null, displayName: null, lookupState: 'none' } }),
  });
  assertEquals(conflict.calls, 1);
});

Deno.test('a slightly different wording never uses the template, and its outcome is unchanged', async () => {
  const variants = [
    NEXT.replace('08:02.', '08:02 is pending.'),
    NEXT.replace('08:02.', '08:02 was declined.'),
    NEXT.replace('08:02.', '08:02 was reversed.'),
    `${NEXT}. Enjoy 10% cashback on your next purchase now`,
    NEXT.replace('KASHIERFast', 'KASHIERFast pending'),
  ];
  for (const text of variants) {
    const withMemory = await analyse(text, NEXT_ANSWER, { memory: memory([TEMPLATE]) });
    const without = await analyse(text, NEXT_ANSWER);
    assertEquals(withMemory.outcome.parsed.analysisSource, undefined, text);
    assertEquals(withMemory.calls, without.calls, text);
    assertEquals(recorded(withMemory.outcome), recorded(without.outcome), text);
  }
});

Deno.test('the direction check applies to a template reading: a contradicted one goes to Gemini', async () => {
  const credit: ShapeTemplate = { ...TEMPLATE, reading: { ...TEMPLATE.reading, type: 'income', direction: 'credit' } };
  const text = NEXT.replace('Purchase of', 'Your account was debited');
  const shaped: ShapeTemplate = {
    ...credit,
    skeleton: buildShape(text, { amountText: '75.50', merchant: 'KASHIERFast', last4: '1234' })!,
  };
  const { calls, outcome } = await analyse(text, NEXT_ANSWER, { memory: memory([shaped]) });
  assertEquals(calls, 1);
  assertEquals(outcome.parsed.analysisSource, undefined);
  assertEquals(outcome.parsed.direction, 'debit');
});

Deno.test('the amount check applies to a template reading: the balance is never the amount', async () => {
  // A (wrong) template whose {A} slot is the balance figure.
  const text = 'Purchase at KASHIERFast with card ending 1234. Available balance EGP 924.50';
  const wrong: ShapeTemplate = {
    ...TEMPLATE,
    skeleton: buildShape(text, { amountText: '924.50', merchant: 'KASHIERFast', last4: '1234' })!,
  };
  const { calls, outcome } = await analyse(text, { is_transaction: false, message_type: 'balance_or_limit_notice',
    status: 'unknown', reason_code: 'balance_only', amount: 0, amount_text: '', currency: '', type: 'unknown',
    direction: 'unknown' }, { memory: memory([wrong]) });
  assertEquals(calls, 1);
  assert(!outcome.accepted);
});

Deno.test('1 in 50 matches is checked by Gemini: agreement keeps the template', async () => {
  const { calls, outcome } = await analyse(NEXT, NEXT_ANSWER, { memory: memory([TEMPLATE]), random: () => 0 });
  assertEquals(calls, 1);
  assertEquals(outcome.memory?.checked, TEMPLATE.hash);
  assertEquals(outcome.memory?.drop, undefined);
  assertEquals(outcome.parsed.analysisSource, undefined);
});

Deno.test('a check where Gemini disagrees: Gemini wins and the template is dropped', async () => {
  const disagree = { ...NEXT_ANSWER, category: 'restaurants' };
  const { calls, outcome } = await analyse(NEXT, disagree, { memory: memory([TEMPLATE]), random: () => 0 });
  assertEquals(calls, 1);
  assertEquals(outcome.parsed.category, 'restaurants');
  assertEquals(outcome.memory?.drop, TEMPLATE.hash);
  // Gemini's not-a-transaction answer also wins.
  const notMoney = await analyse(NEXT, { ...NEXT_ANSWER, is_transaction: false, message_type: 'other_non_transaction',
    status: 'unknown', reason_code: 'not_financial' }, { memory: memory([TEMPLATE]), random: () => 0 });
  assert(!notMoney.outcome.accepted);
  assertEquals(notMoney.outcome.memory?.drop, TEMPLATE.hash);
});

Deno.test('never a shape: a masked person, a transfer, a phone-number sender', async () => {
  const person = 'You received EGP 500.00 from [NAME] via IPN on 18/11/2026';
  const read = await analyse(person, { ...SAOOD_ANSWER, amount: 500, amount_text: '500.00', type: 'transfer',
    direction: 'credit', category: 'transfers', counterparty_kind: 'person', merchant: undefined }, { memory: memory([]) });
  assertEquals(read.outcome.memory?.shape, undefined);
  assertEquals(read.outcome.memory?.merchant, undefined);
  const phone = await analyse(MSG, SAOOD_ANSWER, { memory: memory([]), sender: '+201012345678' });
  assertEquals(phone.outcome.memory?.shape, undefined);
});

Deno.test('a memory that cannot be read calls Gemini as before', async () => {
  const broken: AnalysisMemoryReader = {
    templates: () => Promise.reject(new Error('down')),
    merchant: () => Promise.reject(new Error('down')),
  };
  const { calls, outcome } = await analyse(NEXT, NEXT_ANSWER, { memory: broken });
  assertEquals(calls, 1);
  assert(outcome.accepted);
});

Deno.test('handler: a known display name is shown, the code stays the merchant, no lookup without Cloud', async () => {
  const OWNER = '00000000-0000-0000-0000-00000000a004';
  const fake = fakeCapture({ device: { user_id: OWNER, consent_owner_uid: OWNER, cloud: false, ai: true } });
  const fetched: string[] = [];
  const client = {
    ...fake.client,
    from: (table: string) => {
      if (table !== 'merchant_code_memory') return fake.client.from(table);
      const q = {
        select: () => q, eq: () => q,
        maybeSingle: () => Promise.resolve({ data: { category_key: 'groceries', category_state: 'agreed',
          display_name: 'Saood Market', lookup_state: 'done' }, error: null }),
      };
      return q;
    },
  };
  const original = globalThis.fetch;
  const previousKey = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  globalThis.fetch = ((url: unknown) => {
    fetched.push(String(url));
    const body = JSON.stringify({ candidates: [{ content: { parts: [{ text: JSON.stringify(SAOOD_ANSWER) }] } }] });
    return Promise.resolve(new Response(body));
  }) as typeof fetch;
  try {
    const response = await handleProcessIosSms(
      new Request('https://example.test/process-ios-sms', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          schema_version: 1, installId: 'i', deviceSecret: 's', receivedAt: '2026-11-18T18:40:00Z',
          tzOffsetMinutes: 120, payloadId: 'p4', sanitizedText: MSG, sender: 'CIB', allowAi: true,
          analysis_mode: 'ai_primary_v1', locale: 'en', notificationDetails: true, ownerUid: OWNER,
        }),
      }),
      {
        createServiceClient: (() => client) as never,
        verifyDevice: (() => Promise.resolve({ ok: true, installIdHash: 'h', userId: OWNER })) as never,
      },
    );
    assertEquals(response.status, 200);
    await new Promise((resolve) => setTimeout(resolve, 20));
  } finally {
    globalThis.fetch = original;
    if (previousKey == null) Deno.env.delete('GEMINI_API_KEY');
    else Deno.env.set('GEMINI_API_KEY', previousKey);
  }
  const row = fake.state.rows.get('p4') as { status: string; parsed: Record<string, unknown>; notification: Record<string, unknown> };
  assertEquals(row.status, 'processed');
  assertEquals(row.parsed.merchant, 'SAOOD MARKET');
  assertEquals(row.parsed.merchantDisplay, 'Saood Market');
  assert(JSON.stringify(row.notification).includes('Saood Market'));
  assert(!fetched.some((u) => u.includes('places')));
  // Smart Analysis without Cloud: no Cloud data read.
  assert(!fake.state.tablesTouched.has('user_merchant_rules'));
});
