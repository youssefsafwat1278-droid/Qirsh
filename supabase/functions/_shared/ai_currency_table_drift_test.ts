import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { CURRENCY_CODES, CURRENCY_SCALE, currencyGrounded, validateAiCandidate } from './ai_candidate_validator.ts';

import rules from '../process-ios-sms/parser_rules.json' with { type: 'json' };

// Closure round, follow-up 6 (3): the AI validators take the parser's
// currency table, limited to the codes persisted Money can hold. The app twin
// (AiCandidateValidator.currencyCodes, kCaptureCurrencyCodes) is pinned to the
// same rule by app/test/engine/ai/ai_currency_codes_test.dart.

const table = rules.currencyTable as { core: string[]; iso: string[] };

Deno.test('CURRENCY_CODES is the parser currency table limited to persistable codes', () => {
  assertEquals([...CURRENCY_CODES], table.iso.filter((c) => c in CURRENCY_SCALE));
  for (const legacy of ['SAR', 'AED', 'EGP', 'QAR', 'OMR', 'KWD', 'BHD', 'JOD', 'USD', 'EUR', 'GBP', 'JPY']) {
    assert(CURRENCY_CODES.includes(legacy), legacy);
  }
  for (const code of Object.keys(CURRENCY_SCALE)) assert(table.iso.includes(code), `${code} not in table`);
});

Deno.test('CURRENCY_SCALE equals the app kDetectionCurrencyScale', async () => {
  const dart = await Deno.readTextFile(
    new URL('../../../app/lib/domain/finance/currency_scale.dart', import.meta.url),
  );
  // The detection registry, not the ISO-wide storage table kCurrencyScale.
  const start = dart.indexOf('kDetectionCurrencyScale = {');
  assert(start >= 0, 'kDetectionCurrencyScale literal not found');
  const body = dart.slice(start, dart.indexOf('};', start));
  const app: Record<string, number> = {};
  for (const m of body.matchAll(/'([A-Z]{3})': ([0-9])/g)) app[m[1]] = Number(m[2]);
  assertEquals(Object.keys(app).length > 40, true);
  assertEquals({ ...CURRENCY_SCALE }, app);
});

Deno.test('a table currency beyond the legacy twelve is accepted when written next to the figure', () => {
  const out = validateAiCandidate({
    candidate: { amount: 5000, amount_text: '5,000.00', currency: 'NGN', type: 'payment', direction: 'debit' },
    sanitizedText: 'NGN 5,000.00 debited from your card at SHOP',
    receivedAt: '2026-06-16T12:00:00Z',
    local: null,
  });
  assertEquals(out.accepted, true, JSON.stringify(out));
});

Deno.test('a non-core code counts only in capitals next to a figure; local forms count', () => {
  assertEquals(currencyGrounded('NGN', 'NGN 5,000.00 paid'), true);
  assertEquals(currencyGrounded('NGN', '₦5,000.00 paid'), true);
  assertEquals(currencyGrounded('NGN', 'ngn 5,000.00 paid'), false);
  assertEquals(currencyGrounded('TZS', 'TZS account notice'), false);
  assertEquals(currencyGrounded('SAR', 'sar 5.00'), true);
});

Deno.test('an amount_text beyond the currency scale is not canonical', () => {
  const out = validateAiCandidate({
    candidate: { amount: 5000.505, amount_text: '5000.505', currency: 'NGN', type: 'payment', direction: 'debit' },
    sanitizedText: 'NGN 5000.505 debited from your card at SHOP',
    receivedAt: '2026-06-16T12:00:00Z',
    local: null,
  });
  assertEquals(out, { accepted: false, reason: 'amount_text_not_canonical' });
});
