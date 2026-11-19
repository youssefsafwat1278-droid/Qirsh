// Round 5 (coordinator follow-up): the user's own card or wallet is not part
// of the merchant. Shared table: merchant_instrument_cases.json (Dart twin
// app/test/engine/parser/merchant_instrument_test.dart).
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { deterministicParse } from './parse.ts';
import table from './merchant_instrument_cases.json' with { type: 'json' };

for (const c of table.cases as Array<{ text: string; merchant?: string; server?: string | null }>) {
  Deno.test(`merchant without the payment instrument: ${c.text}`, () => {
    const want = 'server' in c ? c.server : c.merchant;
    const got = deterministicParse(c.text, '2026-06-01T10:00:00Z', 180).merchant;
    assertEquals(got ?? null, want ?? null);
  });
}
