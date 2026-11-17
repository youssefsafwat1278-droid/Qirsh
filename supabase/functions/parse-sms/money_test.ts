import { assert, assertEquals, assertNotEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { amountFromText, groundedModelAmount, withValidatedModelAmountText } from './money.ts';

Deno.test('parse-sms fallback validates currency scale without rounding exact text', () => {
  assertEquals(amountFromText('debited JPY 19'), { amount: 19, amount_text: '19', currency: 'JPY' });
  assertEquals(amountFromText('debited JPY 19.0'), { amount: 19, currency: 'JPY' });
  assertEquals(amountFromText('debited EGP 19.99'), { amount: 19.99, amount_text: '19.99', currency: 'EGP' });
  assertEquals(amountFromText('debited USD 19.99'), { amount: 19.99, amount_text: '19.99', currency: 'USD' });
  assertEquals(amountFromText('debited KWD 1.005'), { amount: 1.005, amount_text: '1.005', currency: 'KWD' });

  const overScale = amountFromText('debited EGP 1.005');
  assertEquals(overScale?.amount, 1.005);
  assertEquals(overScale?.amount_text, undefined);
});

Deno.test('parse-sms fallback preserves IEEE-754-damaged lexical identity independently', () => {
  const token = '9007199254740993';
  const parsed = amountFromText(`debited USD ${token}`);
  assert(parsed);
  assertEquals(parsed.amount, Number(token));
  assertEquals(parsed.amount_text, token);
  assertNotEquals(parsed.amount.toString(), token);
});

Deno.test('parse-sms model amount_text beyond IEEE-754 precision is authoritative and byte-preserved', () => {
  const token = '9007199254740993';
  const response = withValidatedModelAmountText({
    amount: 1,
    amount_text: token,
    currency: 'USD',
  });
  assertEquals(response.amount, Number(token));
  assertEquals(response.amount_text, token);
  assertNotEquals((response.amount as number).toString(), token);
});

Deno.test('parse-sms numeric disagreement does not reject valid model amount_text', () => {
  const response = withValidatedModelAmountText({
    amount: 20,
    amount_text: '19.99',
    currency: 'USD',
  });
  assertEquals(response, { amount: 19.99, amount_text: '19.99', currency: 'USD' });

  const textOnly = withValidatedModelAmountText({ amount_text: '12.34', currency: 'EGP' });
  assertEquals(textOnly, { amount: 12.34, amount_text: '12.34', currency: 'EGP' });
});

Deno.test('parse-sms invalid model amount_text is omitted and legacy numeric is retained', () => {
  const oldNumericOnly = withValidatedModelAmountText({ amount: 19.99, currency: 'EGP' });
  assertEquals(oldNumericOnly.amount, 19.99);
  assertEquals(Object.hasOwn(oldNumericOnly, 'amount_text'), false);

  const overScale = withValidatedModelAmountText({ amount: 1.005, amount_text: '1.005', currency: 'EGP' });
  assertEquals(overScale.amount, 1.005);
  assertEquals(Object.hasOwn(overScale, 'amount_text'), false);

  const exponent = withValidatedModelAmountText({ amount: 1000, amount_text: '1e3', currency: 'USD' });
  assertEquals(exponent.amount, 1000);
  assertEquals(Object.hasOwn(exponent, 'amount_text'), false);
});

Deno.test('parse-sms fallback rejects ambiguous grouping for exact text but retains legacy numeric', () => {
  const parsed = amountFromText('debited USD 1,2');
  assertEquals(parsed?.amount, 12);
  assertEquals(parsed?.amount_text, undefined);
});

// V1-060: the v1 (non-primary) path returned the model's amount without checking
// it against the message. The amount must be a whole numeric token of the
// sanitized text, as in validateAiCandidate and the app's GroundingCheck.
Deno.test('parse-sms drops a model amount that is not in the message', () => {
  const text = 'Purchase of SAR 47.50 at CAFE ONE card ending 1234 balance SAR 8,120.00';
  for (const [amount, amount_text] of [[470, '470'], [1234, '1234'], [120, '120.00'], [8, '8']] as const) {
    const r = groundedModelAmount({ amount, amount_text, currency: 'SAR', type: 'payment' }, text);
    assertEquals([r.amount, r.amount_text], [undefined, undefined], String(amount));
    assertEquals(r.type, 'payment');
  }
  // Legacy numeric-only response, ungrounded: dropped too.
  assertEquals(groundedModelAmount({ amount: 99, currency: 'SAR' }, text).amount, undefined);
  const ok = groundedModelAmount({ amount: 47.5, amount_text: '47.50', currency: 'SAR' }, text);
  assertEquals([ok.amount, ok.amount_text], [47.5, '47.50']);
  const grouped = groundedModelAmount({ amount: 8120, amount_text: '8120.00', currency: 'SAR' }, text);
  assertEquals([grouped.amount, grouped.amount_text], [8120, '8120.00']);
});

// V1-057 on the server: the Arabic comma between digits groups thousands.
Deno.test('parse-sms grounding reads the Arabic comma as a thousands separator', () => {
  for (const text of ['شراء 1،250.00 SAR', 'شراء بمبلغ ١،٢٥٠٫٠٠ ريال']) {
    assertEquals(groundedModelAmount({ amount: 1250, amount_text: '1250.00', currency: 'SAR' }, text).amount, 1250, text);
    assertEquals(groundedModelAmount({ amount: 250, amount_text: '250.00', currency: 'SAR' }, text).amount, undefined, text);
  }
});
