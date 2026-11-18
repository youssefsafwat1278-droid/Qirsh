import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { type AiBudgetRpcClient, consumeGlobalAiBudget } from './ai_spend_guard.ts';

function client(reply: { data: unknown; error: unknown } | Error, calls: unknown[] = []): AiBudgetRpcClient {
  return {
    rpc(fn, args) {
      calls.push({ fn, args });
      if (reply instanceof Error) return Promise.reject(reply);
      return Promise.resolve(reply);
    },
  };
}

Deno.test('allowed reply passes through and reserves one unit in the named bucket', async () => {
  const calls: unknown[] = [];
  const d = await consumeGlobalAiBudget(
    client({ data: { allowed: true, reason: 'ok', used: 7, limit: 3000 }, error: null }, calls),
    'gemini',
  );
  assertEquals(d, { allowed: true, reason: 'ok', used: 7, limit: 3000 });
  assertEquals(calls, [{ fn: 'consume_ai_global_budget', args: { p_bucket: 'gemini', p_units: 1 } }]);
});

Deno.test('ceiling, disabled and unknown bucket are refusals with their reason', async () => {
  for (const reason of ['ceiling', 'disabled', 'unknown_bucket'] as const) {
    const d = await consumeGlobalAiBudget(
      client({ data: { allowed: false, reason, used: 3, limit: 3 }, error: null }),
      'places',
    );
    assertEquals(d, { allowed: false, reason, used: 3, limit: 3 });
  }
});

Deno.test('fails closed: RPC error, thrown error, null, malformed and unknown reasons', async () => {
  const cases: Array<{ data: unknown; error: unknown } | Error> = [
    { data: null, error: { message: 'function does not exist' } },
    new Error('network'),
    { data: null, error: null },
    { data: 'yes', error: null },
    { data: { allowed: 'true' }, error: null },
    { data: { allowed: true, reason: 'ok' }, error: null },
    { data: { allowed: true, reason: 'maybe', used: 1, limit: 2 }, error: null },
    { data: { allowed: false, reason: 'something_new' }, error: null },
  ];
  for (const reply of cases) {
    const d = await consumeGlobalAiBudget(client(reply), 'gemini');
    assertEquals(d.allowed, false, JSON.stringify(reply instanceof Error ? reply.message : reply));
    assertEquals(d.reason, 'unavailable');
  }
});

Deno.test('invalid unit counts never call the RPC and are refused', async () => {
  for (const units of [0, -1, 1.5, 101, Number.NaN]) {
    const calls: unknown[] = [];
    const d = await consumeGlobalAiBudget(
      client({ data: { allowed: true, reason: 'ok', used: 1, limit: 9 }, error: null }, calls),
      'gemini',
      units,
    );
    assertEquals(d.allowed, false);
    assertEquals(calls.length, 0);
  }
});
