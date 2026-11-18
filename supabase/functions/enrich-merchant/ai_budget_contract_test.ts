import { assert } from 'https://deno.land/std@0.224.0/assert/mod.ts';

// V1-022 call-site pins for enrich-merchant (it starts its server on import).
const src = Deno.readTextFileSync(new URL('./index.ts', import.meta.url));
const at = (needle: string) => {
  const i = src.indexOf(needle);
  assert(i >= 0, `missing: ${needle}`);
  return i;
};

Deno.test('enrich-merchant reserves the places budget before the paid request, after consent and quota', () => {
  const reserve = at("if (!(await reserveAiBudget(supabase, 'places')).allowed) {");
  assert(reserve < at('const placesRes = await fetchWithTimeout(PLACES_URL'));
  assert(at("consentError(identity.identity, 'cloud', cid)") < reserve);
  assert(at('bumpCaptureEndpointRateLimit(') < reserve);
  assert(at('const claim = await claimIdempotency(') < reserve);
});

Deno.test('enrich-merchant budget refusal returns before any catalogue write', () => {
  const reserve = at("if (!(await reserveAiBudget(supabase, 'places')).allowed) {");
  const block = src.slice(reserve, at('// ── Google Places Text Search'));
  assert(block.includes("return apiError('upstream_unavailable', { correlationId: cid, retryable: true });"));
  assert(!block.includes('merchant_keywords') && !block.includes('bestEffortCategoryForMerchant'));
});
