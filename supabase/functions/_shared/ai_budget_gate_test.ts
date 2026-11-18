import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { reserveAiBudget } from './ai_budget_gate.ts';

const client = (reply: { data: unknown; error: unknown } | Error) => ({
  rpc: () => reply instanceof Error ? Promise.reject(reply) : Promise.resolve(reply),
});

Deno.test('budget gate: an allowed reservation lets the call go ahead', async () => {
  assertEquals(
    await reserveAiBudget(client({ data: { allowed: true, reason: 'ok', used: 1, limit: 3000 }, error: null }), 'gemini'),
    { allowed: true, reason: 'ok' },
  );
});

Deno.test('budget gate: ceiling and disabled refuse the call', async () => {
  for (const reason of ['ceiling', 'disabled', 'unknown_bucket']) {
    assertEquals(
      await reserveAiBudget(client({ data: { allowed: false, reason, used: 3, limit: 3 }, error: null }), 'gemini'),
      { allowed: false, reason },
    );
  }
});

Deno.test('budget gate: guard not yet migrated behaves as before (call goes ahead)', async () => {
  for (const code of ['PGRST202', '42883']) {
    assertEquals(
      await reserveAiBudget(client({ data: null, error: { code, message: 'function does not exist' } }), 'places'),
      { allowed: true, reason: 'guard_absent' },
    );
  }
});

Deno.test('budget gate: any other failure fails closed', async () => {
  const cases: Array<{ data: unknown; error: unknown } | Error> = [
    { data: null, error: { code: '57014', message: 'statement timeout' } },
    { data: null, error: { message: 'no code' } },
    new Error('network'),
    { data: { allowed: 'yes' }, error: null },
  ];
  for (const reply of cases) {
    assertEquals((await reserveAiBudget(client(reply), 'gemini')).allowed, false);
  }
});
