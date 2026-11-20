import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';

// V1-022 call-site pins. parse-sms starts its server on import, so its wiring
// is pinned from source; the gate and the per-attempt hook are exercised in
// _shared/ai_budget_gate_test.ts and _shared/ai_primary_test.ts.
const src = Deno.readTextFileSync(new URL('./index.ts', import.meta.url));
const at = (needle: string) => {
  const i = src.indexOf(needle);
  assert(i >= 0, `missing: ${needle}`);
  return i;
};

Deno.test('parse-sms reserves the gemini budget for every attempt of the primary path', () => {
  assert(/const reserveAttempt = async \(\) => \(await reserveAiBudget\(supabase, 'gemini'\)\)\.allowed;/.test(src));
  assert(/runPrimaryAi\(\{[\s\S]*?reserveAttempt \}\);/.test(src));
  assert(at("if (result.reason === 'budget') return budgetRefused();") <
    at("if (result.reason === 'denied')"));
});

Deno.test('parse-sms reserves the budget before the legacy request, after consent, quota and replay', () => {
  const reserve = at('if (!(await reserveAttempt())) return await budgetRefused();');
  assert(reserve < at('const geminiRes = await fetchWithTimeout('));
  assert(at("consentError(identity.identity, 'smart', cid)") < reserve);
  assert(at("bumpCaptureEndpointRateLimit(") < reserve);
  assert(at('const claim = await claimIdempotency(') < at('const reserveAttempt'));
});

Deno.test('parse-sms budget refusal is the retryable error old clients already handle', () => {
  const block = src.slice(at('const budgetRefused = async'), at('const reserveAttempt'));
  assertEquals((block.match(/apiError\('upstream_unavailable', \{ correlationId: cid, retryable: true \}\)/g) ?? []).length, 1);
  assert(!block.includes('fallbackParse'), 'a refusal never substitutes a local result');
});
