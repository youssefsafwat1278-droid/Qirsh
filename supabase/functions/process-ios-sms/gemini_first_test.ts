// Gemini-first analysis, phase 1: person transfers reach the model (masked),
// the model decides direction unless it contradicts an explicit cue, and every
// capture that is not recorded carries a closed reason code. End to end
// through the real handler on the capture_* RPC fake; the model is stubbed
// (no network). Synthetic messages only.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { handleProcessIosSms } from './index.ts';
import { fakeCapture } from './capture_rpc_fake.ts';
import {
  channelDisplayName,
  channelIn,
  confirmationReasonCode,
  meaningReasonCode,
  verdictReasonCode,
} from '../_shared/analysis_reasons.ts';
import { transactionPushAlert } from '../_shared/capture_push.ts';

const OWNER = '00000000-0000-0000-0000-00000000a001';

function stubModel(answer: Record<string, unknown>) {
  const original = globalThis.fetch;
  const previousKey = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  const stub = {
    prompts: [] as string[],
    restore: () => {
      globalThis.fetch = original;
      if (previousKey == null) Deno.env.delete('GEMINI_API_KEY');
      else Deno.env.set('GEMINI_API_KEY', previousKey);
    },
  };
  globalThis.fetch = ((_url: unknown, init?: RequestInit) => {
    stub.prompts.push(String(init?.body ?? ''));
    const text = JSON.stringify(answer);
    return Promise.resolve(new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text }] } }] })));
  }) as typeof fetch;
  return stub;
}

async function handle(text: string, answer: Record<string, unknown>, id = crypto.randomUUID()) {
  const fake = fakeCapture({ device: { user_id: OWNER, consent_owner_uid: OWNER, ai: true, apns_token: null } });
  const stub = stubModel(answer);
  let body: Record<string, unknown> = {};
  try {
    const response = await handleProcessIosSms(
      new Request('https://example.test/process-ios-sms', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          schema_version: 1, installId: 'i', deviceSecret: 's', receivedAt: '2026-11-18T18:40:00Z',
          tzOffsetMinutes: 120, payloadId: id, sanitizedText: text, sender: 'CIB', allowAi: true,
          analysis_mode: 'ai_primary_v1', locale: 'ar', notificationDetails: true,
        }),
      }),
      {
        createServiceClient: (() => fake.client) as never,
        verifyDevice: (() => Promise.resolve({ ok: true, installIdHash: 'h', userId: null })) as never,
      },
    );
    body = await response.json();
  } finally {
    stub.restore();
  }
  const stored = fake.state.rows.get(id) as
    | { state: string; status?: string; parsed?: Record<string, unknown>; notification?: unknown }
    | undefined;
  return { stored, prompts: stub.prompts, body };
}

const transferAnswer = (amount: string, direction: string, extra: Record<string, unknown> = {}) => ({
  is_transaction: true, amount: Number(amount), amount_text: amount, currency: 'EGP', type: 'transfer',
  direction, category: 'transfers', counterparty_kind: 'person', ...extra,
});

Deno.test('IPN example: an outgoing person transfer is recorded as a 754 EGP debit via InstaPay, no name', async () => {
  const text = 'IPN transfer sent with amount of EGP 754.00 from 1938 on 18/11 at 08:36 PM. Ref# [REF]';
  // The model even names someone as merchant: never recorded for a person.
  const r = await handle(text, transferAnswer('754.00', 'debit', { merchant: 'Ahmed' }));
  assertEquals(r.prompts.length, 1, 'the transfer reaches the model');
  assertEquals(r.stored?.state, 'processed');
  const p = r.stored!.parsed!;
  assertEquals([p.direction, p.amount, p.currency, p.type], ['debit', 754, 'EGP', 'transfer']);
  assertEquals(p.merchant, 'InstaPay');
  assertEquals(p.counterpartyKind, 'person');
  assertEquals(p.reasonCode, undefined);
  assert(!JSON.stringify(r.body).includes('Ahmed'), 'no name in the response');
});

Deno.test('person transfer: the name is masked before the model and never stored', async () => {
  const text = 'IPN transfer sent with amount of EGP 754.00 from 1938 on 18/11 at 08:36 PM to Ahmed Mohamed Ali. ' +
    'Ref# 123456789';
  const r = await handle(text, transferAnswer('754.00', 'debit'));
  assertEquals(r.prompts.length, 1);
  for (const leaked of ['Ahmed', 'Mohamed', 'Ali.', '123456789']) {
    assert(!r.prompts[0].includes(leaked), `the model never receives ${leaked}`);
  }
  assertEquals(r.stored?.state, 'processed');
  const p = r.stored!.parsed!;
  assertEquals([p.direction, p.amount, p.merchant, p.counterpartyKind], ['debit', 754, 'InstaPay', 'person']);
  const shown = JSON.stringify({ parsed: { ...p, rawMessage: undefined }, notification: r.stored!.notification });
  assert(!/Ahmed|Mohamed/.test(shown), 'no name in the stored result or its alert');
  assert(JSON.stringify(r.stored!.notification).includes('تحويل لصديق'), 'the alert says a transfer to a friend');
});

Deno.test('incoming person transfer: recorded as a credit from a friend via InstaPay', async () => {
  const text = 'IPN transfer received with amount of EGP 500.00 from Mona Hassan on 18/11 at 08:36 PM. Ref# 99887766';
  const r = await handle(text, transferAnswer('500.00', 'credit'));
  assertEquals(r.prompts.length, 1);
  assert(!r.prompts[0].includes('Mona'));
  assertEquals(r.stored?.state, 'processed');
  const p = r.stored!.parsed!;
  assertEquals([p.direction, p.amount, p.currency, p.merchant, p.counterpartyKind], ['credit', 500, 'EGP', 'InstaPay', 'person']);
  assert(JSON.stringify(r.stored!.notification).includes('تحويل من صديق'));
});

Deno.test('Arabic person transfer: the name is masked before the model', async () => {
  const text = 'تم تحويل 754 جنيه إلى أحمد محمد علي عبر انستاباي';
  const r = await handle(text, transferAnswer('754', 'debit'));
  for (const prompt of r.prompts) assert(!/أحمد|محمد|علي/.test(prompt), 'no Arabic name reaches the model');
  if (r.stored?.state === 'processed') assertEquals(r.stored.parsed!.merchant, 'InstaPay');
});

Deno.test('model contradicts an explicit cue: held for confirmation (direction_conflict), never recorded', async () => {
  const text = 'تم خصم 120.00 جنيه من حسابك لدى متجر النور';
  const r = await handle(text, {
    is_transaction: true, amount: 120, amount_text: '120.00', currency: 'EGP', type: 'income', direction: 'credit',
    category: 'income', counterparty_kind: 'merchant',
  });
  assertEquals(r.stored?.state, 'rejected');
  const p = r.stored!.parsed!;
  assertEquals(p.reasonCode, 'direction_conflict');
  assertEquals(p.parserSource, 'ai', 'not "awaiting analysis"');
  assertEquals(p.amount, undefined, 'nothing recorded');
  const proposal = p.proposal as Record<string, unknown>;
  assertEquals([proposal.amount, proposal.currency, proposal.direction], [120, 'EGP', 'credit']);
});

Deno.test('a person transfer against its own flow ("to Ali" read as income): direction_conflict', async () => {
  for (const text of ['Transfer SAR 148 to Fadi Nasser yesterday', 'تم تحويل 151 ريال إلى هاني عادل أمس']) {
    const amount = text.includes('148') ? '148' : '151';
    const r = await handle(text, { ...transferAnswer(amount, 'credit'), currency: 'SAR' });
    assertEquals(r.prompts.length, 1, text);
    assertEquals(r.stored?.state, 'rejected', text);
    assertEquals(r.stored!.parsed!.reasonCode, 'direction_conflict', text);
  }
  const received = await handle('Instant transfer in: SAR 750.00 from Ali', { ...transferAnswer('750.00', 'credit'), currency: 'SAR' });
  assertEquals([received.stored?.state, received.stored!.parsed!.direction], ['processed', 'credit']);
});

Deno.test('a transfer naming neither another side nor a channel stays local (may be the user\'s own move)', async () => {
  const r = await handle('تم تحويل مبلغ 500 ريال لحسابك في بنك آخر', transferAnswer('500', 'debit'));
  assertEquals(r.prompts.length, 0, 'never reaches the model');
});

Deno.test('amount not in the text: held for confirmation (amount_mismatch)', async () => {
  const text = 'Purchase of EGP 45.00 at Test Mart card *4521 on 18/11 at 08:36 PM';
  const r = await handle(text, {
    is_transaction: true, amount: 54, amount_text: '54.00', currency: 'EGP', type: 'payment', direction: 'debit',
    category: 'shopping', merchant: 'Test Mart', counterparty_kind: 'merchant',
  });
  assertEquals(r.stored?.state, 'rejected');
  const p = r.stored!.parsed!;
  assertEquals(p.reasonCode, 'amount_mismatch');
  assertEquals(p.parserSource, 'ai');
  const proposal = p.proposal as Record<string, unknown>;
  assertEquals([proposal.amount, proposal.currency, proposal.direction, proposal.merchant], [54, 'EGP', 'debit', 'Test Mart']);
});

Deno.test('no explicit cue: the model reading is accepted', async () => {
  const text = 'IPN EGP 300.00 18/11 08:36 PM Ref# [REF]';
  const r = await handle(text, transferAnswer('300.00', 'credit'));
  assertEquals(r.stored?.state, 'processed');
  assertEquals([r.stored!.parsed!.direction, r.stored!.parsed!.merchant], ['credit', 'InstaPay']);
});

Deno.test('a model "not a transaction" verdict carries its reason code', async () => {
  const limit = await handle('Your card ending 4521 limit is EGP 20,000.00 as of 18/11', {
    is_transaction: false, message_type: 'balance_or_limit_notice',
  });
  assertEquals(limit.prompts.length, 1, 'the model decided');
  assertEquals(limit.stored?.state, 'rejected');
  assertEquals(limit.stored!.parsed!.reasonCode, 'balance_only');
  const coded = await handle('Dear customer, EGP 300.00 regarding your account on 18/11', {
    is_transaction: false, reason_code: 'not_financial', message_type: 'ambiguous',
  });
  assertEquals(coded.prompts.length, 1);
  assertEquals(coded.stored!.parsed!.reasonCode, 'not_financial', "the model's own code wins");
  // A notice the parser holds before any model request also carries one.
  const bill = await handle('Your EGP 300.00 bill for mobile line is due on 25/11. Pay via the app', {
    is_transaction: true,
  });
  assertEquals(bill.prompts.length, 0);
  assertEquals(bill.stored!.parsed!.reasonCode, 'payment_reminder');
});

Deno.test('reason codes: closed mappings', () => {
  assertEquals(verdictReasonCode({ reason_code: 'balance_only' }), 'balance_only');
  assertEquals(verdictReasonCode({ reason_code: 'free text', message_type: 'otp_or_security' }), 'otp');
  assertEquals(verdictReasonCode({ message_type: 'declined_or_failed' }), 'declined');
  assertEquals(verdictReasonCode({}), 'unclear');
  assertEquals(meaningReasonCode('bill_due'), 'payment_reminder');
  assertEquals(meaningReasonCode('direction_contradiction'), 'direction_conflict');
  assertEquals(meaningReasonCode('cash_deposit'), 'unclear');
  assertEquals(confirmationReasonCode('amount_text_not_grounded'), 'amount_mismatch');
  assertEquals(confirmationReasonCode('direction_contradiction'), 'direction_conflict');
  assertEquals(confirmationReasonCode('category_required'), null);
  assertEquals(channelIn('IPN transfer sent'), 'InstaPay');
  assertEquals(channelIn('تحويل عبر انستاباي'), 'InstaPay');
  assertEquals(channelIn('Purchase at Test Mart'), undefined);
  assertEquals(channelDisplayName('IPN'), 'InstaPay');
  assertEquals(channelDisplayName('Test Mart'), 'Test Mart');
});

Deno.test('push alert: a person transfer is "to/from a friend" and names no one', () => {
  const base = { amount: 754, currency: 'EGP', type: 'transfer', merchant: 'InstaPay', counterpartyKind: 'person' };
  assertEquals(transactionPushAlert({ ...base, direction: 'debit' }, 'en')!.title, 'Transfer to a friend · 754.00 EGP');
  assertEquals(transactionPushAlert({ ...base, direction: 'credit' }, 'ar')!.title, 'تحويل من صديق · 754.00 EGP');
  // Without a person counterparty the old wording stays.
  assertEquals(transactionPushAlert({ ...base, counterpartyKind: undefined, direction: 'debit' }, 'en')!.title,
    'Transfer sent · 754.00 EGP');
});
