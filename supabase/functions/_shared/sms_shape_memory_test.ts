// Gemini-first phase 4: shape skeletons, exact matching and the merchant-code
// gate of the shared analysis memory. Synthetic messages only.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  buildShape,
  matchShape,
  merchantCodeEligible,
  merchantCodeKey,
  observeShape,
  senderKey,
} from './sms_shape_memory.ts';
import { lookupQuery, lookUpMerchantOnce, plausibleDisplayName } from './merchant_lookup.ts';

const MSG = 'Purchase of EGP 250.00 at SAOOD MARKET with card ending 1234 on 18/11/2026 20:15. Available balance EGP 1,000.00';
const READ = { amountText: '250.00', merchant: 'SAOOD MARKET', last4: '1234' };
const SKELETON =
  'Purchase of EGP {A} at {M} with card ending {L} on {N}/{N}/{N} {N}:{N}. Available balance EGP {N}';

Deno.test('a skeleton keeps the wording and holds no amount, merchant, card digits or other figure', () => {
  const skeleton = buildShape(MSG, READ);
  assertEquals(skeleton, SKELETON);
  assert(!/[0-9]/.test(skeleton!) && !skeleton!.includes('SAOOD'));
});

Deno.test('no skeleton when the reading cannot be placed exactly once, or a person is masked', () => {
  // The amount equals the balance: which figure is the amount is not certain.
  assertEquals(buildShape('Purchase of EGP 250.00 at SAOOD MARKET. Balance EGP 250.00', READ), null);
  // The merchant twice, or inside a word.
  assertEquals(buildShape('SAOOD MARKET: EGP 250.00 at SAOOD MARKET', { amountText: '250.00', merchant: 'SAOOD MARKET' }), null);
  assertEquals(buildShape('EGP 250.00 at XSAOOD MARKET', { amountText: '250.00', merchant: 'SAOOD MARKET' }), null);
  // The card digits not in the text.
  assertEquals(buildShape('EGP 250.00 at SAOOD MARKET', { amountText: '250.00', last4: '9999' }), null);
  // A masked person anywhere.
  assertEquals(buildShape('Dear [NAME], EGP 250.00 paid at SAOOD MARKET', { amountText: '250.00' }), null);
});

Deno.test('the same shape with other values matches and gives the new values', () => {
  const next = 'Purchase of EGP 1,075.50 at KASHIERFast with card ending 9876 on 19/11/2026 08:02. Available balance EGP 3.10';
  assertEquals(matchShape(SKELETON, next), { amountText: '1075.50', merchant: 'KASHIERFast', last4: '9876' });
  // Arabic-Indic digits and extra spaces fold to the same shape.
  const arabicDigits = 'Purchase of EGP ٢٥٠.٠٠ at  SAOOD MARKET with card ending ١٢٣٤ on 18/11/2026 20:15. Available balance EGP 1,000.00';
  assertEquals(matchShape(SKELETON, arabicDigits)?.amountText, '250.00');
});

Deno.test('a slightly different wording never matches (pending, declined, reversed, advert tail, case)', () => {
  const variants = [
    'Purchase of EGP 250.00 at SAOOD MARKET with card ending 1234 on 18/11/2026 20:15 is pending. Available balance EGP 1,000.00',
    'Purchase of EGP 250.00 at SAOOD MARKET with card ending 1234 on 18/11/2026 20:15 was declined. Available balance EGP 1,000.00',
    'Purchase of EGP 250.00 at SAOOD MARKET with card ending 1234 on 18/11/2026 20:15 reversed. Available balance EGP 1,000.00',
    `${MSG}. Enjoy 10% cashback on your next purchase`,
    MSG.replace('Purchase of', 'purchase of'),
    MSG.replace('EGP 250.00', 'USD 250.00'),
    // A status word swallowed by the merchant slot.
    MSG.replace('SAOOD MARKET', 'SAOOD MARKET pending'),
    MSG.replace('SAOOD MARKET', 'SAOOD MARKET reversal'),
    MSG.replace('SAOOD MARKET', '[NAME]'),
    MSG.replace('SAOOD MARKET', 'SAOOD [CARD]'),
  ];
  for (const text of variants) assertEquals(matchShape(SKELETON, text), null, text);
});

Deno.test('a merchant code enters the shared memory only as a plain business code', () => {
  for (const ok of ['SAOOD MARKET', 'PAYMOB RAF SPECIALIT', 'KASHIERFast', 'كارفور']) {
    assert(merchantCodeEligible(ok), ok);
  }
  for (const bad of ['[NAME]', 'IPN', 'InstaPay', 'Vodafone Cash', '01012345678', 'a', '1234', 'ali@example.com',
    'SHOP pending', undefined, 42]) {
    assert(!merchantCodeEligible(bad), String(bad));
  }
  assertEquals(merchantCodeKey(' Saood  Market 12 '), 'SAOOD MARKET');
});

Deno.test('a template belongs to a bank sender, never to a phone number or an empty sender', () => {
  assertEquals(senderKey(' cib '), 'CIB');
  assertEquals(senderKey('NBE-ALERT'), 'NBE-ALERT');
  assertEquals(senderKey('+201012345678'), null);
  assertEquals(senderKey(''), null);
  assertEquals(senderKey(null), null);
});

Deno.test('a shape is observed with a per-shape device tag, never the install hash itself', async () => {
  const calls: Array<{ fn: string; args: Record<string, unknown> }> = [];
  const client = {
    from: () => ({}),
    rpc: (fn: string, args: Record<string, unknown>) => {
      calls.push({ fn, args });
      return Promise.resolve({ data: 'candidate', error: null });
    },
  };
  const reading = { currency: 'EGP', type: 'payment', direction: 'debit', counterparty_kind: 'merchant' };
  const a = await observeShape(client, { senderKey: 'CIB', skeleton: SKELETON, reading, installIdHash: 'install-a' });
  await observeShape(client, { senderKey: 'CIB', skeleton: SKELETON.replace('Purchase', 'Payment'), reading,
    installIdHash: 'install-a' });
  assertEquals(a, 'candidate');
  assertEquals(calls[0].fn, 'sms_template_observe');
  assert(/^[0-9a-f]{64}$/.test(String(calls[0].args.p_skeleton_hash)));
  assert(/^[0-9a-f]{16}$/.test(String(calls[0].args.p_source_tag)));
  assert(!JSON.stringify(calls).includes('install-a'));
  // The same device gets an unrelated tag on another shape.
  assert(calls[0].args.p_source_tag !== calls[1].args.p_source_tag);
  assertEquals(calls[0].args.p_min_reads, 3);
  assertEquals(calls[0].args.p_min_sources, 2);
});

Deno.test('a memory failure is "observed nothing", never an error', async () => {
  const client = { from: () => ({}), rpc: () => { throw new Error('missing'); } };
  const reading = { currency: 'EGP', type: 'payment', direction: 'debit', counterparty_kind: 'merchant' };
  assertEquals(await observeShape(client as never, { senderKey: 'CIB', skeleton: SKELETON, reading, installIdHash: 'h' }), null);
});

Deno.test('Places is asked for the name behind a gateway prefix, and only a plausible name is kept', () => {
  assertEquals(lookupQuery('PAYMOB RAF SPECIALIT'), 'RAF SPECIALIT');
  assertEquals(lookupQuery('KASHIERFast'), 'Fast');
  assertEquals(lookupQuery('PAYMOB'), 'PAYMOB');
  assertEquals(lookupQuery('SAOOD MARKET'), 'SAOOD MARKET');
  assertEquals(plausibleDisplayName('SAOOD MARKET', 'Saood Market'), 'Saood Market');
  assertEquals(plausibleDisplayName('PAYMOB RAF SPECIALIT', 'RAF Specialized Hospital'), 'RAF Specialized Hospital');
  assertEquals(plausibleDisplayName('SAOOD MARKET', 'Cairo Tower'), null);
  assertEquals(plausibleDisplayName('SAOOD MARKET', 'Saood Market 01012345678'), null);
  assertEquals(plausibleDisplayName('SAOOD MARKET', undefined), null);
});

function lookupClient(claim: boolean) {
  const rpcs: Array<{ fn: string; args: Record<string, unknown> }> = [];
  return {
    rpcs,
    client: {
      from: () => ({}),
      rpc: (fn: string, args: Record<string, unknown>) => {
        rpcs.push({ fn, args });
        if (fn === 'merchant_code_claim_lookup') return Promise.resolve({ data: claim ? true : null, error: null });
        if (fn === 'consume_ai_global_budget') {
          return Promise.resolve({ data: { allowed: true, reason: 'ok', used: 1, limit: 1000 }, error: null });
        }
        return Promise.resolve({ data: null, error: null });
      },
    },
  };
}

Deno.test('a merchant code is looked up once: a claimed code is never sent to Places again', async () => {
  const { client, rpcs } = lookupClient(false);
  let fetched = 0;
  const name = await lookUpMerchantOnce(client, { codeKey: 'SAOOD MARKET', code: 'SAOOD MARKET', currency: 'EGP',
    apiKey: 'k', fetcher: (() => (fetched++, Promise.resolve(new Response('{}')))) as typeof fetch });
  assertEquals(name, null);
  assertEquals(fetched, 0);
  assert(!rpcs.some((r) => r.fn === 'consume_ai_global_budget'));
});

Deno.test('a looked-up name is stored for everyone, counted against the places budget', async () => {
  const { client, rpcs } = lookupClient(true);
  const bodies: string[] = [];
  const name = await lookUpMerchantOnce(client, { codeKey: 'SAOOD MARKET', code: 'SAOOD MARKET', currency: 'EGP',
    apiKey: 'k', fetcher: ((_u: unknown, init?: RequestInit) => {
      bodies.push(String(init?.body));
      return Promise.resolve(new Response(JSON.stringify({ places: [{ displayName: { text: 'Saood Market' } }] })));
    }) as typeof fetch });
  assertEquals(name, 'Saood Market');
  assertEquals(JSON.parse(bodies[0]), { textQuery: 'SAOOD MARKET', maxResultCount: 1, regionCode: 'EG' });
  const budget = rpcs.find((r) => r.fn === 'consume_ai_global_budget');
  assertEquals(budget?.args.p_bucket, 'places');
  assertEquals(rpcs.at(-1), { fn: 'merchant_code_resolve', args: { p_code_key: 'SAOOD MARKET', p_display_name: 'Saood Market' } });
});

Deno.test('an implausible or failed lookup stores "looked up, nothing usable" (never retried)', async () => {
  const { client, rpcs } = lookupClient(true);
  const name = await lookUpMerchantOnce(client, { codeKey: 'SAOOD MARKET', code: 'SAOOD MARKET',
    apiKey: 'k', fetcher: (() => Promise.reject(new Error('down'))) as typeof fetch });
  assertEquals(name, null);
  assertEquals(rpcs.at(-1)?.args.p_display_name, '');
});

Deno.test('no key: no claim, no lookup', async () => {
  const { client, rpcs } = lookupClient(true);
  assertEquals(await lookUpMerchantOnce(client, { codeKey: 'X', code: 'SAOOD', apiKey: '' }), null);
  assertEquals(rpcs.length, 0);
});
