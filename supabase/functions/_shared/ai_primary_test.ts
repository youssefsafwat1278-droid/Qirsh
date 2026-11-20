import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  AI_ATTEMPT_TIMEOUT_MS,
  AI_TOTAL_BUDGET_MS,
  checkPrimaryAmount,
  runPrimaryAi,
  TRANSACTION_SCHEMA,
} from './ai_primary.ts';

const qnb = 'QNB: Purchase of EGP 250.00 at CARREFOUR. Available balance EGP 4750.00.';
const candidate = { is_transaction: true, amount: 250, amount_text: '250.00',
  currency: 'EGP', type: 'payment', direction: 'debit', category: 'groceries' };
const modelReply = (value: unknown) =>
  new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: JSON.stringify(value) }] } }] }));

Deno.test('QNB: AI repairs an extracted balance and checks consent before its next call', async () => {
  const requests: string[] = [];
  let consentChecks = 0;
  const reply = await runPrimaryAi({
    key: 'test', model: 'gemini-3.8-flash', prompt: qnb,
    beforeAttempt: () => Promise.resolve(++consentChecks > 0),
    validate: (value) => checkPrimaryAmount(value, qnb),
    sleep: () => Promise.resolve(),
    fetcher: (_url, init) => {
      requests.push(String(init?.body));
      return Promise.resolve(modelReply(requests.length === 1
        ? { ...candidate, amount: 4750, amount_text: '4750.00' } : candidate));
    },
  });
  assertEquals(reply, { ok: true, value: candidate, attempts: 2 });
  assertEquals(consentChecks, 2);
  assertEquals(requests[1].includes('transaction_amount_not_balance'), true);
});

Deno.test('transient AI failure stops before re-sending after consent changes', async () => {
  let checks = 0;
  let calls = 0;
  const reply = await runPrimaryAi({
    key: 'test', model: 'gemini-3.8-flash', prompt: qnb,
    beforeAttempt: () => Promise.resolve(++checks === 1),
    validate: () => null, sleep: () => Promise.resolve(),
    fetcher: () => { calls++; return Promise.resolve(new Response('', { status: 503 })); },
  });
  assertEquals(reply, { ok: false, reason: 'denied', attempts: 1 });
  assertEquals(calls, 1);
});

Deno.test('a balance before the purchase does not reject the actual transaction amount', () => {
  const sms = 'Available balance EGP 4750.00. Purchase EGP 250.00 at CARREFOUR.';
  assertEquals(checkPrimaryAmount(candidate, sms), null);
  assertEquals(checkPrimaryAmount(
    { ...candidate, amount: 4750, amount_text: '4750.00' }, sms),
    'transaction_amount_not_balance');
});

Deno.test('a transaction equal to its remaining balance is still supported', () => {
  assertEquals(checkPrimaryAmount(candidate,
    'Available balance EGP 250.00. Purchase EGP 250.00 at CARREFOUR.'), null);
});

Deno.test('transient provider failures make at most three paid attempts', async () => {
  let calls = 0;
  const reply = await runPrimaryAi({
    key: 'test', model: 'gemini-3.8-flash', prompt: qnb,
    beforeAttempt: () => Promise.resolve(true),
    validate: () => null, sleep: () => Promise.resolve(),
    fetcher: () => { calls++; return Promise.resolve(new Response('', { status: 503 })); },
  });
  assertEquals(reply, { ok: false, reason: 'unavailable', attempts: 3 });
  assertEquals(calls, 3);
});

Deno.test('a permanent provider rejection is not retried', async () => {
  let calls = 0;
  const reply = await runPrimaryAi({
    key: 'test', model: 'gemini-3.8-flash', prompt: qnb,
    beforeAttempt: () => Promise.resolve(true),
    validate: () => null, sleep: () => Promise.resolve(),
    fetcher: () => { calls++; return Promise.resolve(new Response('', { status: 400 })); },
  });
  assertEquals(reply, { ok: false, reason: 'unavailable', attempts: 1 });
  assertEquals(calls, 1);
});

// V1-022: the global AI budget is reserved after the consent check and before
// each provider request, repair retries included; a refusal sends nothing.
Deno.test('global budget: one reservation per provider request, repairs included', async () => {
  const order: string[] = [];
  const reply = await runPrimaryAi({
    key: 'test', model: 'gemini-3.8-flash', prompt: qnb,
    beforeAttempt: () => (order.push('consent'), Promise.resolve(true)),
    reserveAttempt: () => (order.push('budget'), Promise.resolve(true)),
    validate: (value) => checkPrimaryAmount(value, qnb),
    sleep: () => Promise.resolve(),
    fetcher: () => {
      order.push('provider');
      return Promise.resolve(modelReply(order.filter((o) => o === 'provider').length === 1
        ? { ...candidate, amount: 4750, amount_text: '4750.00' } : candidate));
    },
  });
  assertEquals(reply, { ok: true, value: candidate, attempts: 2 });
  assertEquals(order, ['consent', 'budget', 'provider', 'consent', 'budget', 'provider']);
});

Deno.test('global budget refused: the provider is never called', async () => {
  let calls = 0;
  const reply = await runPrimaryAi({
    key: 'test', model: 'gemini-3.8-flash', prompt: qnb,
    beforeAttempt: () => Promise.resolve(true),
    reserveAttempt: () => Promise.resolve(false),
    validate: () => null, sleep: () => Promise.resolve(),
    fetcher: () => { calls++; return Promise.resolve(modelReply(candidate)); },
  });
  assertEquals(reply, { ok: false, reason: 'budget', attempts: 0 });
  assertEquals(calls, 0);
});

Deno.test('global budget exhausted mid-repair: no further provider request', async () => {
  let calls = 0;
  let reservations = 0;
  const reply = await runPrimaryAi({
    key: 'test', model: 'gemini-3.8-flash', prompt: qnb,
    beforeAttempt: () => Promise.resolve(true),
    reserveAttempt: () => Promise.resolve(++reservations === 1),
    validate: (value) => checkPrimaryAmount(value, qnb), sleep: () => Promise.resolve(),
    fetcher: () => { calls++; return Promise.resolve(modelReply({ ...candidate, amount: 4750, amount_text: '4750.00' })); },
  });
  assertEquals(reply, { ok: false, reason: 'budget', attempts: 1 });
  assertEquals(calls, 1);
});

// Gemini-first phase 2 (class E): the schema requires what the validator reads.
Deno.test('schema: a transaction must carry amount, amount_text, currency, type and direction', () => {
  assertEquals(TRANSACTION_SCHEMA.type, 'object');
  for (const k of ['is_transaction', 'message_type', 'status', 'amount', 'amount_text', 'currency', 'type', 'direction']) {
    assertEquals(TRANSACTION_SCHEMA.required.includes(k), true, k);
  }
  for (const k of TRANSACTION_SCHEMA.required) assertEquals(k in TRANSACTION_SCHEMA.properties, true, k);
  // A non-transaction can still answer: type and direction have "unknown".
  for (const k of ['type', 'direction']) {
    assertEquals((TRANSACTION_SCHEMA.properties[k] as { enum: string[] }).enum.includes('unknown'), true, k);
  }
});

const timeout = () => Promise.reject(new DOMException('timed out', 'TimeoutError'));

Deno.test('a timeout is retried once, then the message stays retryable (unavailable)', async () => {
  let calls = 0;
  const reply = await runPrimaryAi({
    key: 'test', model: 'gemini-3.8-flash', prompt: qnb,
    beforeAttempt: () => Promise.resolve(true),
    validate: () => null, sleep: () => Promise.resolve(),
    fetcher: () => { calls++; return timeout(); },
  });
  assertEquals(reply, { ok: false, reason: 'unavailable', attempts: 2 });
  assertEquals(calls, 2);
});

Deno.test('one timeout then an answer: accepted on the retry', async () => {
  let calls = 0;
  const reply = await runPrimaryAi({
    key: 'test', model: 'gemini-3.8-flash', prompt: qnb,
    beforeAttempt: () => Promise.resolve(true),
    validate: () => null, sleep: () => Promise.resolve(),
    fetcher: () => (++calls === 1 ? timeout() : Promise.resolve(modelReply(candidate))),
  });
  assertEquals(reply, { ok: true, value: candidate, attempts: 2 });
});

Deno.test('each request waits up to the attempt timeout, clamped to the time left', async () => {
  // The fake clock jumps by the request's own limit, as if it ran out.
  let clock = 0;
  const limits: number[] = [];
  const realTimeout = AbortSignal.timeout;
  AbortSignal.timeout = (ms: number) => { limits.push(ms); clock += ms; return realTimeout.call(AbortSignal, ms); };
  try {
    const reply = await runPrimaryAi({
      key: 'test', model: 'gemini-3.8-flash', prompt: qnb, now: () => clock,
      beforeAttempt: () => Promise.resolve(true),
      validate: () => null, sleep: () => Promise.resolve(),
      fetcher: () => timeout(),
    });
    assertEquals(reply.ok, false);
  } finally {
    AbortSignal.timeout = realTimeout;
  }
  assertEquals(limits, [AI_ATTEMPT_TIMEOUT_MS, AI_TOTAL_BUDGET_MS - AI_ATTEMPT_TIMEOUT_MS]);
  // Within the app's 45 s parse-sms wait and the 60 s process-ios-sms lease.
  assertEquals(AI_TOTAL_BUDGET_MS < 45000 && AI_ATTEMPT_TIMEOUT_MS > 11800, true);
});

Deno.test('no request starts with too little time left', async () => {
  let clock = 0;
  let calls = 0;
  const reply = await runPrimaryAi({
    key: 'test', model: 'gemini-3.8-flash', prompt: qnb, now: () => clock,
    beforeAttempt: () => Promise.resolve(true),
    validate: () => null, sleep: () => Promise.resolve(),
    // A slow 503 that uses up the budget.
    fetcher: () => { calls++; clock += 35000; return Promise.resolve(new Response('', { status: 503 })); },
  });
  assertEquals(reply, { ok: false, reason: 'unavailable', attempts: 1 });
  assertEquals(calls, 1);
});

Deno.test('repair turns keep the low thinking level', async () => {
  const bodies: Record<string, unknown>[] = [];
  await runPrimaryAi({
    key: 'test', model: 'gemini-3.8-flash', prompt: qnb,
    beforeAttempt: () => Promise.resolve(true),
    validate: (value) => checkPrimaryAmount(value, qnb), sleep: () => Promise.resolve(),
    fetcher: (_u, init) => {
      bodies.push(JSON.parse(String(init?.body)));
      return Promise.resolve(modelReply(bodies.length === 1 ? { ...candidate, amount: 4750, amount_text: '4750.00' } : candidate));
    },
  });
  assertEquals(bodies.length, 2);
  for (const b of bodies) {
    assertEquals((b.generationConfig as { thinkingConfig: unknown }).thinkingConfig, { thinkingLevel: 'low' });
  }
});
