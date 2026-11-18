// Round 3 closure (owner brief 4.1, 4.2, 4.4, §5; V1-031, V1-076, V1-082,
// V1-084): the server side of app/test/engine/parser/message_meaning_test.dart.
// Synthetic messages only. Deterministic parse with AI off.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { deterministicParse, isResolved, messageMeaning, parseSms } from './parse.ts';

const RECEIVED = '2026-11-17T10:00:00.000Z';
const parse = (text: string) => deterministicParse(text, RECEIVED, 180);
const outcome = (text: string) =>
  parseSms({ text, rawText: text, sender: 'BANK', receivedAt: RECEIVED, tzOffsetMinutes: 180, locale: 'en', allowAi: false });

Deno.test('a cue applies to its own clause: footers never exclude the event', () => {
  for (const [text, amount, currency] of [
    ['Purchase completed for EGP 250; card payment due EGP 900', 250, 'EGP'],
    ['Purchase of SAR 100.00 at CAFE ONE approved. Previous attempt declined.', 100, 'SAR'],
    ['عملية شراء بمبلغ 120 ريال لدى متجر تجريبي. تذكير: موعد سداد بطاقتك 25/11', 120, 'SAR'],
  ] as const) {
    const p = parse(text);
    assert(isResolved(p), text);
    assertEquals([p.direction, p.type, p.amount, p.currency], ['debit', 'payment', amount, currency], text);
  }
});

Deno.test('clear notices and future or pending clauses are never accepted', async () => {
  for (const text of [
    'Your Test Electricity bill of SAR 300 is due on 25/11',
    'فاتورة الكهرباء بمبلغ 300 ريال مستحقة في 25/11',
    'Your salary of SAR 12,000 is expected on 27/11',
    'راتبك المتوقع 12,000 ريال في 27/11',
    'Payment of SAR 500 to Test Telecom is under processing',
    'Transfer of SAR 500 to Ali scheduled for 1 Dec',
    'Your loan instalment SAR 1,200 will be executed tomorrow',
    'دفعة قادمة: سيتم خصم 1,200 ريال في 1 ديسمبر',
    'Your refund request of SAR 50 for order 1234 has been received',
    // A status line above a bank's field lines still decides the message.
    'Payment of SAR 100.00 to Test Telecom will be processed\nمبلغ:SAR 100.00\nلدى:TEST STORE',
    // A future verb with no scheduling word; an offer.
    'Annual fee of SAR 250 will be charged on 1 Dec',
    'سيتم خصم رسوم سنوية 250 ريال في 1 ديسمبر',
    'Get 20% cashback up to SAR 50.00 on your next purchase with your card. Offer ends soon',
    'احصل على استرداد نقدي 20% حتى 50 ريال على مشترياتك القادمة. ينتهي العرض قريبا',
  ]) {
    assertEquals(isResolved(parse(text)), false, text);
    assertEquals((await outcome(text)).accepted, false, text);
  }
});

Deno.test('direction comes from the clause, not from nouns', () => {
  for (const text of [
    'SAR 500 credited to Ali from your account *5678',
    'Cashback reversal: SAR 15.00 deducted from account *5678',
    'Salary payment to employees SAR 45,000 debited from account *5678',
    'Security deposit payment SAR 1,500 to Test Rentals from account *5678',
    'تم الدفع 300 ريال لشركة الإيداع',
  ]) {
    const p = parse(text);
    assert(isResolved(p), text);
    assertEquals([p.direction, p.type], ['debit', 'payment'], text);
  }
});

Deno.test('loyalty points are not money; the merchant ends at its sentence', () => {
  const p = parse('POS purchase SAR 45.00 at Salary Store. Credited points 45');
  assertEquals([p.direction, p.type, p.merchant], ['debit', 'payment', 'Salary Store']);
});

Deno.test('undecidable movements stay unresolved (review), never recorded', () => {
  for (const [text, kind] of [
    ['Cash deposit SAR 2,000 via ATM to account *5678', 'cash_deposit'],
    ['إيداع نقدي عبر الصراف 3,000 ريال في حسابك *5678', 'cash_deposit'],
    ['SAR 1,000 debited from *1111 and deposited to *2222', 'own_account_transfer'],
    ['Transfer of SAR 2,000.00 from your account *1234 to your account *5678', 'own_account_transfer'],
    ['تحويل 2,000 ريال من حسابك *1234 إلى حسابك *5678 عبر التطبيق', 'own_account_transfer'],
    ['SAR 45.00 paid at Test Mart; cashback SAR 2 credited', 'multiple_events'],
  ] as const) {
    const p = parse(text);
    assertEquals([isResolved(p), p.direction], [false, 'unknown'], text);
    const m = messageMeaning(text);
    assertEquals([m.kind, m.disposition], [kind, 'review'], text);
  }
});

Deno.test('the meaning carries a disposition and a machine-readable reason', async () => {
  const notice = await outcome('Your Test Electricity bill of SAR 300 is due on 25/11');
  assertEquals([notice.meaning?.kind, notice.meaning?.reason, notice.meaning?.disposition],
    ['no_movement_notice', 'bill_due', 'no_movement']);
  const purchase = await outcome('Purchase completed for EGP 250; card payment due EGP 900');
  assertEquals([purchase.meaning?.kind, purchase.meaning?.reason, purchase.accepted],
    ['completed_movement', 'footer_set_aside', true]);
});

Deno.test('amount roles and table-driven currency', () => {
  const fx = parse('Purchase of USD 20.00 at TestApp. Rate 3.75. Charged SAR 75.00. Card limit SAR 8,000');
  assertEquals([fx.amount, fx.amount_text, fx.currency, fx.foreign_amount, fx.foreign_currency],
    [75, '75.00', 'SAR', 20, 'USD']);
  const sr = parse('Purchase SR1,250.00 at Test Mart card *4521');
  assertEquals([sr.amount, sr.currency], [1250, 'SAR']);
  // A code that names the merchant is not the currency; absent stays absent.
  const store = parse('Purchase 30.00 at USD Store card *4521');
  assertEquals([store.currency, isResolved(store)], [undefined, false]);
  assertEquals(messageMeaning('Purchase 30.00 at USD Store card *4521').currencyAbsent, true);
  const ngn = parse('Purchase 500 NGN at Test Kiosk card *4521');
  assertEquals([ngn.amount, ngn.currency], [500, 'NGN']);
});
