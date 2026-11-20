import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { handleProcessIosSms } from './index.ts';
import { fakeCapture } from './capture_rpc_fake.ts';

// Device-scoped consent contract of process-ios-sms. The gate itself now runs
// inside the capture_claim RPC (one FOR SHARE snapshot, migration 0111; proofs in
// supabase/tests/capture_state_machine_p1.sql); these tests pin how the handler
// maps its decisions and that a refusal stops everything downstream.

const UNRESOLVED = 'Purchase $20.00 at SHOP';
const GOOD_AI = {
  amount: 20,
  amount_text: '20.00',
  currency: 'USD',
  merchant: 'SHOP',
  type: 'payment',
  direction: 'debit',
};

type Device = NonNullable<Parameters<typeof fakeCapture>[0]>['device'];

const A1 = '00000000-0000-0000-0000-00000000a001';

function run(device: Device, body: Record<string, unknown> = {}) {
  // H1: an ownerless (build-50) upload is only eligible for an install with proven single-owner history.
  return runWith(fakeCapture({ device: { user_id: A1, consent_owner_uid: A1, ...device } }), body);
}

async function runWith(fake: ReturnType<typeof fakeCapture>, body: Record<string, unknown> = {}) {
  let fetchCalls = 0;
  const originalFetch = globalThis.fetch;
  const previousKey = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  globalThis.fetch = (() => {
    fetchCalls++;
    return Promise.resolve(
      new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: JSON.stringify(GOOD_AI) }] } }] })),
    );
  }) as typeof fetch;
  try {
    const response = await handleProcessIosSms(
      new Request('https://example.test/process-ios-sms', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          schema_version: 1,
          installId: 'install-1',
          deviceSecret: 'secret-1',
          payloadId: 'payload-1',
          sanitizedText: UNRESOLVED,
          receivedAt: new Date().toISOString(), // build 50 sends it; ownership never depends on it (H1)
          allowAi: true,
          ...body,
        }),
      }),
      {
        createServiceClient: (() => fake.client) as never,
        verifyDevice: (() =>
          Promise.resolve({
            ok: true,
            installIdHash: 'verified-install-hash',
            userId: fake.state.device.user_id,
          })) as never,
      },
    );
    return { response, body: await response.json(), fake, fetchCalls };
  } finally {
    globalThis.fetch = originalFetch;
    if (previousKey == null) Deno.env.delete('GEMINI_API_KEY');
    else Deno.env.set('GEMINI_API_KEY', previousKey);
  }
}

Deno.test('neither Cloud nor smart-analysis consent is a typed refusal before parse, storage and AI', async () => {
  const r = await run({ cloud: false, ai: false });
  assertEquals([r.response.status, r.body.error], [403, 'consent_required']);
  assertEquals(r.fake.state.rows.size, 0);
  assertEquals(r.fetchCalls, 0);
  assertEquals(r.fake.state.budgetCalls, 0);
});

// Gemini-first phase 3 (20261120120000): smart analysis no longer needs Cloud.
Deno.test('Cloud OFF with smart-analysis consent is analysed, under the quota and the global AI ceiling', async () => {
  const r = await run({ cloud: false, ai: true });
  assertEquals(r.response.status, 200);
  assertEquals([r.fetchCalls, r.body.capture.status], [1, 'processed']);
  assertEquals(r.fake.state.dispatches, 1);
  assertEquals(r.fake.state.budgetCalls, 1); // consume_ai_global_budget before the provider
  assertEquals(r.fake.state.rateLimitBumps, 1); // the per-install daily quota
});

Deno.test('Cloud OFF: the global AI ceiling still refuses the provider call', async () => {
  const fake = fakeCapture({
    device: { user_id: A1, consent_owner_uid: A1, cloud: false, ai: true },
    budget: 'ceiling',
    budgetLimit: 0,
  });
  const r = await runWith(fake);
  assertEquals(r.fetchCalls, 0);
  assertEquals(fake.state.dispatches, 1);
  assertEquals(fake.state.budgetCalls, 1);
});

Deno.test('Cloud OFF: the per-install daily quota still applies', async () => {
  const fake = fakeCapture({ device: { user_id: A1, consent_owner_uid: A1, cloud: false, ai: true } });
  fake.state.rateLimited = true;
  const r = await runWith(fake);
  assertEquals([r.response.status, r.body.error], [429, 'rate_limit_exceeded']);
  assertEquals(r.fetchCalls, 0);
  assertEquals(fake.state.budgetCalls, 0);
});

Deno.test('revoked device is refused even when both consent flags remain true', async () => {
  const r = await run({ cloud: true, ai: true, revoked: true });
  assertEquals([r.response.status, r.body.error], [401, 'credential_revoked']);
  assertEquals(r.fake.state.rows.size, 0);
  assertEquals(r.fetchCalls, 0);
});

Deno.test('legacy: consent that does not belong to the linked user fails closed', async () => {
  const r = await run({ user_id: 'u-a', consent_owner_uid: 'u-b', cloud: true, ai: true });
  assertEquals([r.response.status, r.body.error], [403, 'consent_required']);
  assertEquals(r.fake.state.rows.size, 0);
});

Deno.test('AI requires AI consent and the caller request', async () => {
  const aiOff = await run({ cloud: true, ai: false });
  assertEquals([aiOff.fetchCalls, aiOff.body.capture.status], [0, 'rejected']);
  const notRequested = await run({ cloud: true, ai: true }, { allowAi: false });
  assertEquals([notRequested.fetchCalls, notRequested.body.capture.status], [0, 'rejected']);
  const allowed = await run({ cloud: true, ai: true });
  assertEquals([allowed.fetchCalls, allowed.body.capture.status], [1, 'processed']);
  assertEquals(allowed.fake.state.dispatches, 1);
});

Deno.test('stale replay after revocation stops before parse, storage and APNs', async () => {
  const first = await run({ cloud: true, ai: true, apns_token: 'tok' });
  assertEquals(first.response.status, 200);
  const fake = first.fake;
  fake.state.device.revoked = true;
  const calls = fake.state.claims;
  const original = globalThis.fetch;
  let fetches = 0;
  globalThis.fetch = (() => {
    fetches++;
    throw new Error('network/APNs/AI must not run');
  }) as typeof fetch;
  try {
    const response = await handleProcessIosSms(
      new Request('https://example.test/process-ios-sms', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          schema_version: 1,
          installId: 'install-1',
          deviceSecret: 'secret-1',
          payloadId: 'payload-1',
          sanitizedText: UNRESOLVED,
          receivedAt: new Date().toISOString(), // build 50 sends it; ownership never depends on it (H1)
        }),
      }),
      {
        createServiceClient: (() => fake.client) as never,
        verifyDevice: (() => Promise.resolve({ ok: true, installIdHash: 'h', userId: null })) as never,
      },
    );
    assertEquals(response.status, 401);
    assertEquals((await response.json()).error, 'credential_revoked');
  } finally {
    globalThis.fetch = original;
  }
  assertEquals(fetches, 0);
  assertEquals(fake.state.claims, calls);
});
