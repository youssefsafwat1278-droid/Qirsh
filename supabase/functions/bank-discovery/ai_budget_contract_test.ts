import { assert } from 'https://deno.land/std@0.224.0/assert/mod.ts';

// V1-022 call-site pins for bank-discovery (it starts its server on import;
// the gate itself is exercised in _shared/ai_budget_gate_test.ts).
const src = Deno.readTextFileSync(new URL('./index.ts', import.meta.url));
const at = (needle: string) => {
  const i = src.indexOf(needle);
  assert(i >= 0, `missing: ${needle}`);
  return i;
};
const RESERVE = "if (!(await reserveAiBudget(supabase, 'gemini')).allowed) {";

Deno.test('bank-discovery reserves the gemini budget before the paid request, after consent and quota', () => {
  const reserve = at(RESERVE);
  assert(reserve < at('const geminiRes = await fetchWithTimeout('));
  assert(at("consentError(identity.identity, 'ai', cid)") < reserve);
  assert(at('bumpCaptureEndpointRateLimit(') < reserve);
  assert(at("safeLog({ event: 'bank_discovery_ai_unconfigured'") < reserve);
});

Deno.test('bank-discovery budget refusal is the retryable error clients already get', () => {
  const block = src.slice(at(RESERVE), at('const geminiRes = await fetchWithTimeout('));
  assert(block.includes("return apiError('upstream_unavailable', { correlationId: cid, retryable: true });"));
});
