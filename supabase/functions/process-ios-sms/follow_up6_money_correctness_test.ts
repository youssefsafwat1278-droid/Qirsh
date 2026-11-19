// Follow-up 6 (round 4): the reviewer's open reproductions at a157e68e and the
// three classes of the real-model run; the server side of
// app/test/engine/parser/follow_up6_money_correctness_test.dart. Synthetic
// messages only. Each row is checked twice: the rule parse with AI off (a
// processed capture whose meaning is not "record" is rejected by index.ts),
// and the single gate every processed capture passes (meaningRejectionOf)
// against a forged model answer of "completed, at `answer`".
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { messageMeaning, parseSms } from './parse.ts';
import { gatedMeaning, meaningRejectionOf } from './meaning_gate.ts';
import { isGeneralAdvice, isUnspecifiedOperation, paidTotal, refundCredited } from './message_meaning.ts';
import cases from './follow_up6_cases.json' with { type: 'json' };

const RECEIVED = '2026-11-17T10:00:00.000Z';
const outcome = (text: string) =>
  parseSms({ text, rawText: text, sender: 'AlRajhi', receivedAt: RECEIVED, tzOffsetMinutes: 180, locale: 'en',
    allowAi: false });

async function server(text: string) {
  const o = await outcome(text);
  const p = o.parsed;
  const meaning = o.meaning ?? messageMeaning(text);
  const recorded = !!(o.accepted && p.amount && p.currency) && meaning.disposition === 'record';
  return { recorded, credit: p.direction === 'credit', amount: p.amount, currency: p.currency, type: p.type, meaning };
}

type Case = {
  id: string; kind: string; text: string; amount?: number; currency?: string; answer: number; server?: string;
  round5?: string;
};

for (const c of cases.cases as Case[]) {
  const label = c.text.length > 110 ? `${c.text.slice(0, 110)}…` : c.text;
  Deno.test(`${c.id} [${c.kind}${c.server ? ` server=${c.server}` : ''}] ${label}`, async () => {
    const o = await server(c.text);
    const gate = meaningRejectionOf(c.text, c.answer, gatedMeaning(c.text, messageMeaning(c.text), c.answer));
    if (c.round5) {
      // Round 5 (owner decision): a movement that is not clearly completed
      // (a doubt word anywhere, or no completed-event form) is a visible
      // review row, and no model answer of "completed" is accepted for it.
      assertEquals(o.recorded, false);
      assertEquals(o.meaning.disposition, 'review');
      assert(gate !== null, `gate accepted ${c.answer}`);
      return;
    }
    if (c.kind === 'n' || c.kind === 'r') {
      assertEquals(o.recorded, false);
      // No answer is accepted for it, from any model.
      assert(gate !== null, `gate accepted ${c.answer}: ${JSON.stringify(o.meaning)}`);
      if (c.kind === 'r') {
        assertEquals(o.meaning.disposition, 'review');
        assert(o.meaning.reason.length > 0);
      }
      return;
    }
    // A completed movement is never a no-movement notice (the "not recorded"
    // push) and the gate accepts the right answer.
    assert(o.meaning.disposition !== 'no_movement', JSON.stringify(o.meaning));
    if (c.kind === 't') {
      // The server has no neutral type: an explicit own-account move is left
      // unresolved (the device books it as a neutral transfer).
      assertEquals(o.recorded, false);
      return;
    }
    assertEquals(gate, null, JSON.stringify(o.meaning));
    if (c.server === 'review') {
      assertEquals(o.recorded, false);
      return;
    }
    assert(o.recorded, `recorded ${JSON.stringify(o.meaning)}`);
    assertEquals(o.credit, c.kind === 'c');
    assert(Math.abs((o.amount ?? NaN) - c.amount!) < 0.005, `amount ${o.amount}`);
    assertEquals(o.currency, c.currency);
  });
}

Deno.test('awaited and attempted operations are not completed (CUE-1)', () => {
  for (const text of [
    'Purchase SAR 45.00 at Jarir card *4521. Awaiting merchant confirmation',
    'Attempted purchase SAR 45.00 at Jarir card *4521',
    'شراء 45 ريال لدى جرير بطاقة 4521. بانتظار تأكيد التاجر',
    'محاولة شراء 45 ريال لدى جرير بطاقة 4521',
  ]) assertEquals(messageMeaning(text).kind, 'not_completed', text);
});

Deno.test('a future charge or credit is a notice, also for a bill with parts (CUE-1)', () => {
  for (const text of [
    'You will receive SAR 500.00 cashback on 01/12',
    'Bill SAR 200.00, VAT SAR 30.00, total SAR 230.00 will be charged tomorrow',
    'سوف تستلم 500 ريال استرداد نقدي بتاريخ 01/12',
  ]) assertEquals(messageMeaning(text).disposition, 'no_movement', text);
});

Deno.test('general advice about refunds or standing orders is a footer (FT-1, HOLD-1)', () => {
  assert(isGeneralAdvice('Refund requests will be processed within 7 days'));
  assert(isGeneralAdvice('الأوامر المستديمة تنفذ في تاريخ الاستحقاق'));
  assertEquals(isGeneralAdvice('A refund has been initiated and will be credited within 5 days'), false);
  assertEquals(isGeneralAdvice('Refund of SAR 99.00 will be processed'), false);
});

Deno.test('a refund whose clause states the credit happened is completed (HOLD-1)', () => {
  assert(refundCredited('your expected refund of sar 150.00 from noon has been credited to your card'));
  assertEquals(refundCredited('your expected refund of sar 150.00 will be credited within 5 days'), false);
});

Deno.test('a labelled total that was paid is the amount; never with a status word (HOLD-1, VAL-1)', () => {
  const none = () => false;
  assertEquals(paidTotal('bill sar 200.00, vat sar 30.00, total sar 230.00 paid', none)?.value, 230);
  assertEquals(paidTotal('bill sar 200.00, vat sar 30.00, total sar 230.00', none), null);
  assertEquals(paidTotal('bill sar 200.00, vat sar 30.00, total sar 230.00 will be paid tomorrow', none), null);
  assertEquals(paidTotal('bill sar 200.00, vat sar 30.00, total sar 230.00 paid', () => true), null);
});

Deno.test('a bare operation with no verb, type or merchant is unspecified (real-model run)', () => {
  assert(isUnspecifiedOperation('عملية بمبلغ 500 egp على بطاقتك *4521'));
  assertEquals(isUnspecifiedOperation('عملية شراء بمبلغ 500 egp على بطاقتك *4521'), false);
  assertEquals(isUnspecifiedOperation('transaction of egp 500.00 at carrefour on your card *4521'), false);
});
