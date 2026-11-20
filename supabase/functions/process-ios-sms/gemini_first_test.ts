// Gemini-first analysis, phase 1: person transfers reach the model (masked),
// the model decides direction unless it contradicts an explicit cue, and every
// capture that is not recorded carries a closed reason code. End to end
// through the real handler on the capture_* RPC fake; the model is stubbed
// (no network). Synthetic messages only.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { handleProcessIosSms } from './index.ts';
import { withoutAdvertTail } from './parse.ts';
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

// ── Gemini-first phase 2 ─────────────────────────────────────────────────────

const answer = (amount: string, type: string, direction: string, extra: Record<string, unknown> = {}) => ({
  is_transaction: true, amount: Number(amount.replace(/,/g, '')), amount_text: amount, currency: 'EGP', type, direction,
  category: type === 'transfer' ? 'transfers' : type === 'income' ? 'income' : 'shopping',
  counterparty_kind: type === 'transfer' ? 'person' : 'merchant', ...extra,
});

Deno.test('phase 2 (B): the Egyptian short form «جم» grounds EGP', async () => {
  const r = await handle('شراء بمبلغ 118.00 جم لدى CARREFOUR', answer('118.00', 'payment', 'debit', { merchant: 'CARREFOUR' }));
  assertEquals(r.stored?.state, 'processed');
  assertEquals([r.stored!.parsed!.amount, r.stored!.parsed!.currency], [118, 'EGP']);
});

Deno.test('phase 2 (C): completed transfers that name no other side reach the model', async () => {
  const cases: [string, Record<string, unknown>][] = [
    ['تم تحويل 500 جنيه لرقم 01012345678 رسوم الخدمة 1 جنيه رصيدك الحالي 300 جنيه', answer('500', 'transfer', 'debit')],
    ['An instant transfer of EGP 2,000.00 has been executed from your account ending ****1234',
      answer('2,000.00', 'transfer', 'debit', { counterparty_kind: 'unknown' })],
    ['تم استلام تحويل بمبلغ 5000 جنيه من شركة النور للتجارة', answer('5000', 'income', 'credit', { counterparty_kind: 'merchant' })],
  ];
  for (const [text, model] of cases) {
    const r = await handle(text, model);
    assertEquals(r.prompts.length, 1, text);
    assertEquals(r.stored?.state, 'processed', text);
    assertEquals(r.stored!.parsed!.direction, model.direction, text);
  }
});

Deno.test('phase 2 (C): a transfer between the user\'s own accounts stays local', async () => {
  const r = await handle('تم تحويل 1000 جنيه من حسابك ****1234 إلى حسابك ****5678', answer('1000', 'transfer', 'debit'));
  assertEquals(r.prompts.length, 0);
});

Deno.test('phase 2 (C): a cancelled purchase or ATM debit is a reversal the model reads', async () => {
  const cases: [string, Record<string, unknown>][] = [
    ['تم الغاء الشراء بمبلغ 250 جنيه على بطاقتك المنتهية 1234 لدى NOON',
      answer('250', 'refund', 'credit', { merchant: 'NOON' })],
    ['تم إلغاء خصم مبلغ 1000 جنيه من ماكينة الصراف الآلي', answer('1000', 'refund', 'credit')],
  ];
  for (const [text, model] of cases) {
    const r = await handle(text, model);
    assertEquals(r.prompts.length, 1, text);
    assertEquals(r.stored?.state, 'processed', text);
    assertEquals([r.stored!.parsed!.direction, r.stored!.parsed!.type], ['credit', 'refund'], text);
  }
  // The model may still say it moved no money: kept with its reason.
  const declined = await handle('تم إلغاء خصم مبلغ 1000 جنيه من ماكينة الصراف الآلي', {
    is_transaction: false, reason_code: 'declined',
  });
  assertEquals([declined.stored?.state, declined.stored!.parsed!.reasonCode], ['rejected', 'declined']);
  // A debit answer is not a reversal's reading: held for confirmation.
  const debit = await handle('تم الغاء الشراء بمبلغ 250 جنيه على بطاقتك المنتهية 1234 لدى NOON',
    answer('250', 'payment', 'debit', { merchant: 'NOON' }));
  assertEquals(debit.stored?.parsed?.reasonCode, 'direction_conflict');
});

Deno.test('phase 2 (C): an insufficient-balance notice is declined and a deposit advert is promo, not unclear', async () => {
  const balance = await handle('رصيدك لا يسمح بإتمام عملية سحب 500 جنيه', { is_transaction: false });
  assertEquals(balance.stored!.parsed!.reasonCode, 'declined');
  for (const text of ['Open a new term deposit today and earn 22% interest. Visit any branch',
    'افتح وديعة جديدة بعائد 20% سنويا واستمتع بأعلى عائد']) {
    const advert = await handle(text, { is_transaction: false });
    assertEquals(advert.stored?.state, 'rejected', text);
    assertEquals(advert.stored!.parsed!.reasonCode, 'promo', text);
  }
});

Deno.test('phase 2 (C): an advert tail does not overrule the transaction clause', async () => {
  for (const text of ['Deposit of EGP 3000 on 18/11. Enjoy 10% discount on purchases with your card',
    'إيداع 3000 جنيه. خصم 20% عند الدفع ببطاقتك في المطاعم',
    'EGP 3000 deposit on 18/11. Withdraw cash for free from any ATM this month']) {
    const r = await handle(text, answer('3000', 'income', 'credit', { counterparty_kind: 'unknown' }));
    assertEquals(r.stored?.state, 'processed', text);
    assertEquals(r.stored!.parsed!.direction, 'credit', text);
  }
  // The transaction clause's own cue still decides: a debit read as a credit is held.
  const held = await handle('تم خصم 3000 جنيه من حسابك. احصل على خصم 20% عند الدفع ببطاقتك',
    answer('3000', 'income', 'credit', { counterparty_kind: 'unknown' }));
  assertEquals(held.stored!.parsed!.reasonCode, 'direction_conflict');
});

Deno.test('phase 2 (F): wallet names are payment channels, Arabic and English', () => {
  for (const [text, name] of [
    ['Vodafone Cash: you sent EGP 300 to 01012345678', 'Vodafone Cash'],
    ['تم تحويل 300 جنيه من محفظة فودافون كاش إلى 01012345678', 'Vodafone Cash'],
    ['Orange Cash transfer of EGP 150 received', 'Orange Cash'],
    ['تم استلام 150 جنيه على أورنج كاش من 01212345678', 'Orange Cash'],
    ['e& money: EGP 90 sent to 01112345678', 'e& money'],
    ['Etisalat Cash transfer EGP 90', 'e& money'],
    ['تم تحويل 90 جنيه عبر اتصالات كاش', 'e& money'],
  ] as const) assertEquals(channelIn(text), name, text);
  assertEquals(channelDisplayName('فودافون كاش'), 'Vodafone Cash');
  assertEquals(channelIn('Vodafone bill paid EGP 120'), undefined);
});

Deno.test('phase 2 (F): a wallet person-to-person transfer keeps the wallet as its channel', async () => {
  const cases: [string, string, string][] = [
    ['تم تحويل 300 جنيه من محفظة فودافون كاش إلى 01012345678 بنجاح', 'debit', 'Vodafone Cash'],
    ['You have received EGP 150.00 on your Orange Cash wallet from 01212345678', 'credit', 'Orange Cash'],
    ['e& money: you sent EGP 90.00 to 01112345678 successfully', 'debit', 'e& money'],
  ];
  for (const [text, direction, channel] of cases) {
    const amount = text.match(/[0-9]+(?:\.[0-9]+)?(?= ?جنيه)|(?<=EGP )[0-9.]+/)![0];
    const r = await handle(text, answer(amount, 'transfer', direction, { merchant: 'Someone' }));
    assertEquals(r.prompts.length, 1, text);
    assertEquals(r.stored?.state, 'processed', text);
    const p = r.stored!.parsed!;
    assertEquals([p.type, p.direction, p.counterpartyKind, p.merchant], ['transfer', direction, 'person', channel], text);
  }
});

Deno.test('phase 2 (F): a wallet cash withdrawal at an agent is not a person transfer', async () => {
  const text = 'تم سحب 500 جنيه من محفظة فودافون كاش لدى وكيل رقم 12345';
  const r = await handle(text, answer('500', 'withdrawal', 'debit', { category: 'cash', counterparty_kind: 'merchant' }));
  assertEquals(r.stored?.state, 'processed');
  const p = r.stored!.parsed!;
  assertEquals([p.type, p.direction, p.counterpartyKind], ['withdrawal', 'debit', 'merchant']);
  // The prompt tells the model so.
  assert(r.prompts[0].includes('cash-in at an agent'), 'prompt names the agent rule');
});

Deno.test('phase 2 (E): a message whose model requests time out stays retryable, nothing recorded', async () => {
  const fake = fakeCapture({ device: { user_id: OWNER, consent_owner_uid: OWNER, ai: true, apns_token: null } });
  const original = globalThis.fetch;
  const previousKey = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  let calls = 0;
  globalThis.fetch = (() => {
    calls++;
    return Promise.reject(new DOMException('timed out', 'TimeoutError'));
  }) as typeof fetch;
  const id = crypto.randomUUID();
  try {
    await handleProcessIosSms(
      new Request('https://example.test/process-ios-sms', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          schema_version: 1, installId: 'i', deviceSecret: 's', receivedAt: '2026-11-18T18:40:00Z',
          tzOffsetMinutes: 120, payloadId: id, sanitizedText: 'شراء بمبلغ 118.00 جم لدى CARREFOUR', sender: 'CIB',
          allowAi: true, analysis_mode: 'ai_primary_v1', locale: 'ar',
        }),
      }),
      {
        createServiceClient: (() => fake.client) as never,
        verifyDevice: (() => Promise.resolve({ ok: true, installIdHash: 'h', userId: null })) as never,
      },
    );
  } finally {
    globalThis.fetch = original;
    if (previousKey == null) Deno.env.delete('GEMINI_API_KEY');
    else Deno.env.set('GEMINI_API_KEY', previousKey);
  }
  // One request and at most one retry after a timeout, never three.
  assertEquals(calls, 2);
  const row = fake.state.rows.get(id) as { state: string; failure_reason?: string; parsed?: unknown };
  assertEquals([row.state, row.failure_reason], ['retryable', 'ai_unavailable']);
});

Deno.test('phase 2 (D): "charged" answers the model gives as debits are recorded by the server', async () => {
  const cases: [string, Record<string, unknown>][] = [
    ['Your card ending 1234 was charged for EGP 118.00 at SALARY CAFE on 12/05/2026',
      answer('118.00', 'payment', 'debit', { merchant: 'SALARY CAFE' })],
    ['Your account was charged by EGP 1105 on 18/11 at 08:36 PM. IPN REF# 123456', answer('1105', 'transfer', 'debit')],
  ];
  for (const [text, model] of cases) {
    const r = await handle(text, model);
    assertEquals(r.stored?.state, 'processed', text);
    assertEquals(r.stored!.parsed!.direction, 'debit', text);
  }
});

Deno.test('phase 2 (C): an advert tail is set aside, a completed-event sentence never is', () => {
  const advert = 'Deposit of EGP 3000 on 18/11. Enjoy 10% discount on purchases with your card';
  assertEquals(withoutAdvertTail(advert).trimEnd(), 'Deposit of EGP 3000 on 18/11.');
  assertEquals(withoutAdvertTail(advert).length, advert.length);
  for (const text of ['Transfer of EGP 50 from your card. Credited to the beneficiary now',
    'تحويل 50 جنيه. تم الخصم من حسابك الآن',
    'شراء 384 ريال لدى جرير بطاقة *4521. العملية قيد الانتظار.',
    'Purchase SAR 50 at Jarir. Transaction pending now']) assertEquals(withoutAdvertTail(text), text, text);
});

Deno.test('phase 2 (C): an outgoing transfer answered as a credit is held, not recorded', async () => {
  for (const text of ['Transfer SAR 500.00 to account 1234567890. Ref 778123',
    'An instant transfer of EGP 2,000.00 has been executed from your account ending ****1234',
    'تم تحويل 500 جنيه لرقم 01012345678 رسوم الخدمة 1 جنيه']) {
    const amount = text.match(/[0-9][0-9,]*(?:\.[0-9]+)?(?= ?جنيه)|(?<=(?:SAR|EGP) )[0-9.,]+/)![0];
    const r = await handle(text, answer(amount, 'transfer', 'credit'));
    assert(r.prompts.length >= 1, text);
    // Held for review (with its own reason), never recorded as money in.
    assertEquals(r.stored?.state, 'rejected', text);
  }
  // An incoming transfer to the user's account stays the model's.
  const incoming = await handle('تم تحويل 500 جنيه إلى حسابك من أحمد', answer('500', 'transfer', 'credit'));
  assertEquals(incoming.stored?.state, 'processed');
});
