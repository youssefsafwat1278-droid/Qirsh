import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { messageMeaning } from '../process-ios-sms/parse.ts';

// Closure round, follow-up 6 (4): on the AI-primary path a message the parser
// reads as no movement, an OTP or a review kind gets `is_transaction: false`
// with no provider request. parse-sms starts its server on import, so the
// wiring is pinned from source; the meaning itself is exercised here.
const src = Deno.readTextFileSync(new URL('./index.ts', import.meta.url));
const at = (needle: string) => {
  const i = src.indexOf(needle);
  assert(i >= 0, `missing: ${needle}`);
  return i;
};

Deno.test('parse-sms: the meaning gate runs on the primary path before any provider request', () => {
  const gate = at("if (meaning.disposition !== 'record') {");
  assert(at('if (body.analysis_mode === AI_PRIMARY_MODE) {') < gate);
  assert(gate < at('const result = await runPrimaryAi({'));
  assert(at('const meaning = messageMeaning(reSanitized);') < gate);
  assert(/if \(meaning\.disposition !== 'record'\) \{\s*return finish\(\{ is_transaction: false,/.test(src));
});

Deno.test('parse-sms: held messages are what the gate holds; a completed purchase is not', () => {
  for (const text of [
    'Cash deposit SAR 1,500.00 to account *5678 via ATM',
    'Purchase SAR 120.00 at SHOP. Cashback SAR 12.00 credited to your card',
    'Your bill of SAR 230.00 is due on 25/06. Pay now to avoid late fees.',
    'Your salary of SAR 9,000.00 is expected on 27/06',
  ]) assert(messageMeaning(text).disposition !== 'record', text);
  assertEquals(messageMeaning('Purchase of SAR 80.00 at SHOP with card *1234. Never share your OTP with anyone.')
    .disposition, 'record');
});
