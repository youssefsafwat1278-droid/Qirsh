import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { handleProcessIosSms } from './index.ts';
import { fakeCapture } from './capture_rpc_fake.ts';

// V1-022: the project-wide AI budget (consume_ai_global_budget) is reserved
// before every Gemini request this function makes. Synthetic messages only.

const OWNER = '00000000-0000-0000-0000-00000000a001';
const TEXT = 'Purchase of EGP 250.00 at CARREFOUR with card ending 1234 on 2026-09-07';
const GOOD = {
  is_transaction: true, amount: 250, amount_text: '250.00', currency: 'EGP',
  merchant: 'CARREFOUR', type: 'payment', direction: 'debit', category: 'groceries',
};
const BAD = { ...GOOD, amount: 9999, amount_text: '9999' };

async function run(
  budget: 'allow' | 'ceiling' | 'absent' | 'error',
  candidate: Record<string, unknown>,
  extra: Record<string, unknown> = { analysis_mode: 'ai_primary_v1' },
  budgetLimit = 0,
) {
  const fake = fakeCapture({
    device: { user_id: OWNER, consent_owner_uid: OWNER, ai: true },
    budget,
    budgetLimit,
  });
  const original = globalThis.fetch;
  const previousKey = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  let calls = 0;
  globalThis.fetch = (() => {
    calls++;
    return Promise.resolve(new Response(JSON.stringify({
      candidates: [{ content: { parts: [{ text: JSON.stringify(candidate) }] } }],
    })));
  }) as typeof fetch;
  try {
    const res = await handleProcessIosSms(new Request('https://example.test/process-ios-sms', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        schema_version: 1, installId: 'i', deviceSecret: 's', receivedAt: new Date().toISOString(),
        payloadId: 'p1', sanitizedText: TEXT, allowAi: true, ...extra,
      }),
    }), {
      createServiceClient: (() => fake.client) as never,
      verifyDevice: (() => Promise.resolve({ ok: true, installIdHash: 'h', userId: null })) as never,
    });
    return { status: res.status, json: await res.json(), calls, fake, row: fake.state.rows.get('p1')! };
  } finally {
    globalThis.fetch = original;
    if (previousKey == null) Deno.env.delete('GEMINI_API_KEY');
    else Deno.env.set('GEMINI_API_KEY', previousKey);
  }
}

Deno.test('budget available: one reservation per provider request, result unchanged', async () => {
  const r = await run('allow', GOOD);
  assertEquals(r.calls, 1);
  assertEquals(r.fake.state.budgetCalls, 1);
  assertEquals(r.row.state, 'processed');
  assertEquals(r.json.capture.status, 'processed');
});

Deno.test('budget available: repair retries each reserve a unit', async () => {
  const r = await run('allow', BAD);
  assertEquals(r.calls, 3);
  assertEquals(r.fake.state.budgetCalls, 3);
  assertEquals(r.row.state, 'rejected');
});

Deno.test('budget exhausted: no model call, the capture stays a retryable pending review item', async () => {
  const r = await run('ceiling', GOOD);
  assertEquals(r.calls, 0);
  assertEquals(r.row.state, 'retryable');
  assertEquals(r.row.failure_reason, 'ai_unavailable');
  // The build-147 response shape of a provider outage: rejected status, a
  // pending AI parse with no amount, the silent "received" notification.
  assertEquals(r.status, 200);
  assertEquals(r.json.capture.status, 'rejected');
  assertEquals(r.json.capture.parsed.parserSource, 'ai_pending');
  assertEquals(r.json.capture.parsed.amount, undefined);
  assertEquals(r.json.capture.parsed.aiModel, undefined);
  assertEquals(r.json.capture.notification.type, 'received');
  assertEquals(r.json.pushSent, false);
});

Deno.test('budget exhausted between repair attempts: no further call, still retryable', async () => {
  const r = await run('ceiling', BAD, { analysis_mode: 'ai_primary_v1' }, 1);
  assertEquals(r.calls, 1);
  assertEquals(r.row.state, 'retryable');
  assertEquals(r.json.capture.parsed.amount, undefined);
});

Deno.test('budget RPC failing for another reason fails closed (no call, retryable)', async () => {
  const r = await run('error', GOOD);
  assertEquals(r.calls, 0);
  assertEquals(r.row.state, 'retryable');
});

Deno.test('budget exhausted on the legacy (non-primary) path: never auto-saved from the local reading', async () => {
  const r = await run('ceiling', GOOD, {});
  assertEquals(r.calls, 0);
  assertEquals(r.row.state, 'retryable');
  assertEquals(r.json.capture.status, 'rejected');
});

Deno.test('guard not migrated yet (function absent): behaves exactly as before', async () => {
  const r = await run('absent', GOOD);
  assertEquals(r.calls, 1);
  assertEquals(r.row.state, 'processed');
  assertEquals(r.json.capture.status, 'processed');
  assertEquals(r.json.capture.parsed.amount, 250);
});
