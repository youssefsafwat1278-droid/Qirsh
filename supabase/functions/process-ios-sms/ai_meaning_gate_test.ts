import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { handleProcessIosSms } from './index.ts';
import { fakeCapture } from './capture_rpc_fake.ts';

// Closure round, follow-up 6 (4): the parser's message meaning overrules a
// model answer. A clear notice, or a review kind (ATM cash deposit, several
// movements), never becomes processed money because the model returned a
// grounded transaction. Synthetic messages only.

const OWNER = '00000000-0000-0000-0000-00000000a001';

async function run(text: string, candidate: Record<string, unknown>, mode?: string) {
  const fake = fakeCapture({ device: { user_id: OWNER, consent_owner_uid: OWNER, ai: true } });
  const original = globalThis.fetch;
  const previousKey = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  globalThis.fetch = (() =>
    Promise.resolve(new Response(JSON.stringify({
      candidates: [{ content: { parts: [{ text: JSON.stringify(candidate) }] } }],
    })))) as typeof fetch;
  try {
    const res = await handleProcessIosSms(new Request('https://example.test/process-ios-sms', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        schema_version: 1, installId: 'i', deviceSecret: 's', receivedAt: new Date().toISOString(),
        payloadId: 'p1', sanitizedText: text, allowAi: true,
        ...(mode ? { analysis_mode: mode } : {}),
      }),
    }), {
      createServiceClient: (() => fake.client) as never,
      verifyDevice: (() => Promise.resolve({ ok: true, installIdHash: 'h', userId: null })) as never,
    });
    return { json: await res.json(), row: fake.state.rows.get('p1')! };
  } finally {
    globalThis.fetch = original;
    if (previousKey == null) Deno.env.delete('GEMINI_API_KEY');
    else Deno.env.set('GEMINI_API_KEY', previousKey);
  }
}

const answer = (amount: number, type: string, direction: string) => ({
  is_transaction: true, amount, amount_text: amount.toFixed(2), currency: 'SAR',
  type, direction, category: 'other', message_type: 'transaction', status: 'completed',
});

const held: Array<[string, string, ReturnType<typeof answer>]> = [
  ['Cash deposit SAR 1,500.00 to account *5678 via ATM', 'cash_deposit', answer(1500, 'income', 'credit')],
  ['Purchase SAR 120.00 at SHOP. Cashback SAR 12.00 credited to your card', 'multiple_amounts',
    answer(120, 'payment', 'debit')],
  ['Your bill of SAR 230.00 is due on 25/06. Pay now to avoid late fees.', 'bill_due',
    answer(230, 'payment', 'debit')],
  ['Your salary of SAR 9,000.00 is expected on 27/06', 'scheduled_or_expected', answer(9000, 'income', 'credit')],
];

for (const mode of ['ai_primary_v1', undefined]) {
  for (const [text, reason, candidate] of held) {
    Deno.test(`${mode ?? 'legacy'}: a model transaction for "${reason}" is not processed money`, async () => {
      const r = await run(text, candidate, mode);
      assertEquals(r.row.status, 'rejected', text);
      assertEquals(r.json.capture.status, 'rejected', text);
      // AI-primary always reaches the gate, which stores the meaning's reason;
      // the legacy path rejects a clear notice before any AI request.
      const stored = (r.row.parsed as { reviewReason?: string }).reviewReason;
      if (mode) assertEquals(stored, reason, text);
      else assertEquals(stored === undefined || stored === reason, true, text);
    });
  }
  Deno.test(`${mode ?? 'legacy'}: a completed purchase with an OTP footer is still processed`, async () => {
    const r = await run('Purchase of SAR 80.00 at SHOP with card *1234. Never share your OTP with anyone.',
      { ...answer(80, 'payment', 'debit'), merchant: 'SHOP' }, mode);
    assertEquals(r.row.status, 'processed');
  });
}
