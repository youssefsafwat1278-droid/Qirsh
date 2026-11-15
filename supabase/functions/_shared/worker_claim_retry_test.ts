import { assertEquals, assertRejects } from 'jsr:@std/assert@1';
import { retryWorkerClaim } from './worker_claim_retry.ts';

const futureJwt = { code: 'PGRST303', message: 'JWT issued at future' };

Deno.test('a future-issued service JWT has one delayed retry after the gateway rejected the claim', async () => {
  let calls = 0;
  const delays: number[] = [];
  const result = await retryWorkerClaim(async () => ++calls === 1
    ? { data: null, error: futureJwt }
    : { data: ['claimed'], error: null }, async (ms) => {
      delays.push(ms);
    });
  assertEquals(result, { data: ['claimed'], error: null });
  assertEquals([calls, delays], [2, [2000]]);
});

Deno.test('persistent clock skew stops after two claim attempts', async () => {
  let calls = 0;
  await retryWorkerClaim(async () => {
    calls++;
    return { data: null, error: futureJwt };
  }, async () => {});
  assertEquals(calls, 2);
});

Deno.test('expired credentials and uncertain transport outcomes are never replayed', async () => {
  let expiredCalls = 0;
  await retryWorkerClaim(async () => {
    expiredCalls++;
    return { data: null, error: { code: 'PGRST303', message: 'JWT expired' } };
  }, async () => {});
  assertEquals(expiredCalls, 1);

  let uncertainCalls = 0;
  await assertRejects(() => retryWorkerClaim(async () => {
    uncertainCalls++;
    throw new Error('transport status unknown');
  }, async () => {}));
  assertEquals(uncertainCalls, 1);
});
