// Follow-up 6 (round 4): the server's FINAL effect for each money-correctness
// class — the stored capture state and the class of the push — through the
// real handler (handleProcessIosSms) on the capture_* RPC model, with the
// model's answer stubbed as "a completed transaction" (what a model would say
// for the figure). Both analysis modes: the rule parse consulting the model,
// and AI-primary. Synthetic messages only. The harness is that of
// handler_outcome_test.ts.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { handleProcessIosSms } from './index.ts';
import { fakeCapture } from './capture_rpc_fake.ts';

// The capture_* RPCs are modelled by capture_rpc_fake.ts (SQL proofs: supabase/tests/
// capture_state_machine_p1.sql). `captures` = stored processed_captures rows,
// `state.inserts` = claims that created/re-claimed a lease.
function fakeSupabase(opts: { aiConsent?: boolean; duplicateOf?: string; apnsToken?: string } = {}) {
  // H1: an ownerless (build-50) upload is only eligible for an install with proven single-owner history.
  const OWNER = '00000000-0000-0000-0000-00000000a001';
  const fake = fakeCapture({
    device: { user_id: OWNER, consent_owner_uid: OWNER, ai: opts.aiConsent ?? true, apns_token: opts.apnsToken ?? null },
    duplicateOf: opts.duplicateOf,
  });
  return {
    state: {
      get inserts() {
        return fake.state.claims;
      },
    },
    captures: fake.state.rows,
    client: fake.client,
  };
}

function stubGemini(candidate: Record<string, unknown> | null) {
  const original = globalThis.fetch;
  const previousKey = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  const stub = {
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
    return Promise.resolve(new Response(JSON.stringify(body)));
  }) as typeof fetch;
  return stub;
}

function request(body: Record<string, unknown>): Request {
  return new Request('https://example.test/process-ios-sms', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    // build 50 always sends receivedAt; the server ignores it for ownership (H1)
    body: JSON.stringify({
      schema_version: 1,
      installId: 'i',
      deviceSecret: 's',
      receivedAt: new Date().toISOString(),
      ...body,
    }),
  });
}

const deps = (fake: ReturnType<typeof fakeSupabase>) => ({
  createServiceClient: (() => fake.client) as never,
  verifyDevice: (() => Promise.resolve({ ok: true, installIdHash: 'h', userId: null })) as never,
});

async function call(
  fake: ReturnType<typeof fakeSupabase>,
  body: Record<string, unknown>,
  candidate: Record<string, unknown> | null = null,
) {
  const stub = stubGemini(candidate);
  try {
    const res = await handleProcessIosSms(request(body), deps(fake));
    return { status: res.status, json: await res.json(), calls: stub.calls };
  } finally {
    stub.restore();
  }
}


type Held = {
  name: string; text: string; amount: number; outcome: 'declined' | 'excluded' | 'review'; reason?: string;
  // Round 5 (owner decision): a pending message reaches the model; its answer is never accepted.
  pending?: true;
};
type Kept = {
  name: string; text: string; amount: number; type: 'payment' | 'refund'; direction: 'debit' | 'credit';
  // Round 5 (owner decision): not clearly completed (a doubt word anywhere, or
  // a transfer the server decides on its own reading): kept for review on
  // both modes, whatever the model answers.
  r5?: true;
};

// Nothing is processed for these, whatever the model answers; the push never
// says the message was queued for recording.
const HELD: Held[] = [
  { name: 'awaiting merchant confirmation', outcome: 'declined', amount: 45, pending: true,
    text: 'Purchase SAR 45.00 at Jarir card *4521. Awaiting merchant confirmation' },
  { name: 'awaiting merchant confirmation (ar)', outcome: 'declined', amount: 45,
    text: 'شراء 45 ريال لدى جرير بطاقة *4521. بانتظار تأكيد التاجر' },
  { name: 'attempted purchase', outcome: 'declined', amount: 45, text: 'Attempted purchase SAR 45.00 at Jarir card *4521' },
  { name: 'attempted purchase (ar)', outcome: 'declined', amount: 45, text: 'محاولة شراء 45 ريال لدى جرير بطاقة *4521' },
  { name: 'a tip total awaiting authorization', outcome: 'declined', amount: 115, pending: true,
    text: 'Purchase SAR 115.00 at Cafe Lumen incl. tip SAR 15.00 card *4521, awaiting authorization' },
  { name: 'a total that will be charged tomorrow', outcome: 'excluded', amount: 230,
    text: 'Bill SAR 200.00, VAT SAR 30.00, total SAR 230.00 will be charged tomorrow' },
  { name: 'a total that will be charged tomorrow (ar)', outcome: 'excluded', amount: 230,
    text: 'فاتورة 200 ريال، ضريبة 30 ريال، الإجمالي 230 ريال سيتم خصمه غدا' },
  { name: 'a future cashback', outcome: 'excluded', amount: 500, text: 'You will receive SAR 500.00 cashback on 01/12' },
  { name: 'a future cashback (ar)', outcome: 'excluded', amount: 500, text: 'سوف تستلم 500 ريال استرداد نقدي بتاريخ 01/12' },
  { name: 'a refund request that is pending', outcome: 'declined', amount: 150, pending: true,
    text: 'Your refund request of SAR 150.00 from Noon is pending' },
  { name: 'a reversed bill with a VAT total (ar, prefix)', outcome: 'review', reason: 'total_with_parts', amount: 230,
    text: 'عملية معكوسة: فاتورة 200 ريال، ضريبة 30 ريال، الإجمالي 230 ريال' },
  { name: 'a reversed bill with a service-fee total (ar, suffix)', outcome: 'review', reason: 'total_with_parts',
    amount: 230, text: 'فاتورة 200 ريال، رسوم خدمة 30 ريال، الإجمالي 230 ريال. تم عكس العملية' },
  { name: 'own named accounts', outcome: 'review', reason: 'own_accounts', amount: 500,
    text: 'SAR 500.00 transferred from your current account to your savings account' },
  { name: 'own named accounts (ar)', outcome: 'review', reason: 'own_accounts', amount: 500,
    text: 'تم تحويل 500 ريال من حسابك الجاري إلى حسابك الادخاري' },
  // (The push class reads the other operation's status: "declined" — still "not recorded".)
  { name: 'a completed purchase next to another declined one', outcome: 'declined', reason: 'other_event_status',
    amount: 45, text: 'Purchase SAR 45.00 at Jarir card *4521 completed. Previous transaction declined.' },
  { name: 'a bare operation on the card (ar)', outcome: 'review', reason: 'unspecified_operation', amount: 500,
    text: 'عملية بمبلغ 500 ريال على بطاقتك *4521' },
  { name: 'a bare transaction on the card', outcome: 'review', reason: 'unspecified_operation', amount: 500,
    text: 'A transaction of SAR 500.00 on your card *4521' },
];

// A completed movement is processed with the right money on both modes.
const KEPT: Kept[] = [
  { name: 'a purchase with a standing-order footer', r5: true, amount: 45, type: 'payment', direction: 'debit',
    text: 'Purchase SAR 45.00 at Jarir card *4521. Standing orders will be executed on the due date' },
  { name: 'a purchase with a standing-order footer (ar)', r5: true, amount: 45, type: 'payment', direction: 'debit',
    text: 'شراء 45 ريال لدى جرير بطاقة *4521. سيتم تنفيذ الأوامر المستديمة في تاريخ الاستحقاق' },
  { name: 'a purchase with a refund-request footer', r5: true, amount: 45, type: 'payment', direction: 'debit',
    text: 'Purchase SAR 45.00 at Jarir card *4521. Refund requests will be processed within 7 days' },
  { name: 'a bill payment with a reminder tail (ar)', r5: true, amount: 300, type: 'payment', direction: 'debit',
    text: 'دفع فاتورة 300 ريال من حسابك *4521، تذكير: موعد السداد القادم 1/12' },
  { name: 'a card use with a month-to-date total tail (ar)', amount: 120, type: 'payment', direction: 'debit',
    text: 'استخدمت بطاقتك *4521 بمبلغ 120 ريال لدى بنده، مجموع مصروفاتك هذا الشهر 3,200 ريال' },
  { name: 'a transfer executed as per your request', r5: true, amount: 750, type: 'payment', direction: 'debit',
    text: 'As per your request SAR 750.00 has been transferred to Sara as scheduled' },
  { name: 'an expected refund that has been credited', r5: true, amount: 150, type: 'refund', direction: 'credit',
    text: 'Your expected refund of SAR 150.00 from Noon has been credited to your card *4521' },
  { name: 'a pending refund that has been credited (ar)', r5: true, amount: 150, type: 'refund', direction: 'credit',
    text: 'تم إيداع مبلغ الاسترداد المعلق 150 ريال في حسابك *4521' },
  { name: 'an Arabic refund that names the purchase', amount: 150, type: 'refund', direction: 'credit',
    text: 'استرجاع عملية شراء بمبلغ 150 ريال من نون بطاقة *4521' },
  { name: 'a third-party transfer naming two account types', r5: true, amount: 500, type: 'payment', direction: 'debit',
    text: 'SAR 500.00 transferred from your current account to savings account of Ali' },
  { name: 'a bill, its VAT and the total paid', amount: 230, type: 'payment', direction: 'debit',
    text: 'Bill SAR 200.00, VAT SAR 30.00, total SAR 230.00 paid from account *4521' },
  { name: 'a bill, its VAT and the total paid (ar)', amount: 230, type: 'payment', direction: 'debit',
    text: 'فاتورة 200 ريال، ضريبة 30 ريال، الإجمالي 230 ريال تم دفعه' },
  { name: 'a late-payment fee charged to the credit card', r5: true, amount: 100, type: 'payment', direction: 'debit',
    text: 'Late payment fee of SAR 100.00 charged to your credit card *4521' },
  { name: 'a late-payment fee charged to the credit card (ar)', r5: true, amount: 100, type: 'payment', direction: 'debit',
    text: 'تم خصم رسوم تأخير سداد بطاقتك الائتمانية *4521 بمبلغ 100 ريال' },
  { name: 'a refund of a cancelled transaction that has been credited', r5: true, amount: 150, type: 'refund', direction: 'credit',
    text: 'Refund of SAR 150.00 for the cancelled transaction has been credited to your card *4521' },
  { name: 'a refund of a cancelled transaction that has been credited (ar)', r5: true, amount: 150, type: 'refund',
    direction: 'credit', text: 'تم إيداع مبلغ الاسترداد 150 ريال للعملية الملغاة في بطاقتك *4521' },
];

// The amount as the message writes it ("45.00", or «45» in the Arabic texts).
const answer = (text: string, amount: number, type: string, direction: string) => ({
  is_transaction: true, amount, amount_text: text.includes(amount.toFixed(2)) ? amount.toFixed(2) : String(amount),
  currency: 'SAR', type, direction,
  category: type === 'refund' ? 'other' : 'shopping',
});

for (const primary of [false, true]) {
  const mode = primary ? { analysis_mode: 'ai_primary_v1' } : {};
  const label = primary ? 'AI-primary' : 'rule parse + model';

  for (const [i, c] of HELD.entries()) {
    Deno.test(`held (${label}): ${c.name}`, async () => {
      const fake = fakeSupabase();
      const id = `held-${primary}-${i}`;
      const r = await call(fake, { payloadId: id, sanitizedText: c.text, allowAi: true, ...mode },
        answer(c.text, c.amount, 'payment', 'debit'));
      // The stored capture is never processed and carries no money.
      assertEquals(fake.captures.get(id)!.state, 'rejected', c.text);
      assertEquals(r.json.capture.status, 'rejected');
      // The push never says the message is on its way to being recorded.
      const n = r.json.capture.notification;
      assert(n.captureOutcome !== 'queued', JSON.stringify(n));
      assertEquals(n.type === 'new_transaction', false);
      if (!primary) assertEquals(n.captureOutcome, c.outcome, c.text);
      if (c.reason && r.json.capture.parsed.reviewReason !== undefined) {
        assertEquals(r.json.capture.parsed.reviewReason, c.reason);
      }
      // A declined, awaited or no-movement message never reaches the model.
      if (c.outcome !== 'review' && !c.reason && !c.pending) assertEquals(r.calls, 0, 'no model request');
    });
  }

  for (const [i, c] of KEPT.entries()) {
    Deno.test(`recorded (${label}): ${c.name}`, async () => {
      const fake = fakeSupabase();
      const id = `kept-${primary}-${i}`;
      const r = await call(fake, { payloadId: id, sanitizedText: c.text, allowAi: true, ...mode },
        answer(c.text, c.amount, c.type, c.direction));
      const stored = fake.captures.get(id)!;
      if (c.r5) {
        assertEquals(stored.state, 'rejected', c.text);
        const n = r.json.capture.notification;
        assert(n.captureOutcome !== 'queued' && n.type !== 'new_transaction', JSON.stringify(n));
        return;
      }
      assertEquals(stored.state, 'processed', `${c.text} ${JSON.stringify(r.json.capture.parsed)}`);
      const parsed = stored.parsed as Record<string, unknown>;
      assertEquals(parsed.amount, c.amount);
      assertEquals(parsed.currency, 'SAR');
      assertEquals(parsed.direction, c.direction);
      assertEquals(parsed.type, c.type);
      // Never the "no completed transaction" push.
      const n = r.json.capture.notification;
      assert(n.captureOutcome === undefined || n.captureOutcome === 'queued', JSON.stringify(n));
    });
  }
}

Deno.test('a completed purchase with a footer is never rejected before the model, AI off', async () => {
  for (const [i, c] of KEPT.entries()) {
    const fake = fakeSupabase();
    const r = await call(fake, { payloadId: `off-${i}`, sanitizedText: c.text, allowAi: false });
    assert(r.json.capture.notification.captureOutcome !== 'excluded', c.text);
    assert(r.json.capture.notification.captureOutcome !== 'declined', c.text);
  }
});
