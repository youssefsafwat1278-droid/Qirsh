import { assert, assertEquals } from 'jsr:@std/assert@1';
import { handleContribution } from './index.ts';
import type { VerifiedIdentity } from '../_shared/ai_endpoint.ts';

const userIdentity: VerifiedIdentity = {
  kind: 'user',
  ownerKey: 'u:11111111-1111-1111-1111-111111111111',
  userId: '11111111-1111-1111-1111-111111111111',
  installIdHash: null,
  aiConsent: true,
  cloudConsent: true,
};

function harness(identity: Partial<VerifiedIdentity> | null = {}, rpcError: unknown = null) {
  const calls: Array<{ fn: string; args: unknown }> = [];
  let identityBody: unknown = 'unset';
  const deps = {
    createServiceClient: () =>
      ({
        rpc: (fn: string, args: unknown) => {
          calls.push({ fn, args });
          return Promise.resolve({ data: null, error: rpcError });
        },
      }) as never,
    resolveIdentity: (_req: Request, _s: unknown, body: Record<string, unknown>) => {
      identityBody = body;
      if (identity === null) {
        return Promise.resolve({
          ok: false as const,
          response: new Response('{"error":"authentication_required"}', { status: 401 }),
        });
      }
      return Promise.resolve({ ok: true as const, identity: { ...userIdentity, ...identity } });
    },
    bumpRateLimit: () => Promise.resolve(false),
  };
  return { deps: deps as never, calls, identityBody: () => identityBody };
}

function post(body: unknown): Request {
  return new Request('http://x/merchant-category-contribution', {
    method: 'POST',
    headers: { authorization: 'Bearer user-jwt', 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

const good = { merchant_key: 'HALA BOUTIQUE', category_key: 'shopping' };

Deno.test('a valid pair from a consenting user is stored under that user id', async () => {
  const h = harness();
  const res = await handleContribution(post(good), h.deps);
  assertEquals(res.status, 200);
  assertEquals(h.calls, [{
    fn: 'submit_merchant_category_contribution',
    args: { p_user_id: userIdentity.userId, p_merchant_key: 'HALA BOUTIQUE', p_category_key: 'shopping' },
  }]);
  // The device-secret path is never offered the request body.
  assertEquals(h.identityBody(), {});
});

Deno.test('AI consent off: refused, nothing stored', async () => {
  const h = harness({ aiConsent: false });
  const res = await handleContribution(post(good), h.deps);
  assertEquals(res.status, 403);
  assertEquals(h.calls.length, 0);
});

Deno.test('Cloud consent off: refused, nothing stored', async () => {
  const h = harness({ cloudConsent: false });
  const res = await handleContribution(post(good), h.deps);
  assertEquals(res.status, 403);
  assertEquals(h.calls.length, 0);
});

Deno.test('no user JWT: refused, nothing stored', async () => {
  const h = harness(null);
  assertEquals((await handleContribution(post(good), h.deps)).status, 401);
  const d = harness({ kind: 'device', userId: null });
  assertEquals((await handleContribution(post(good), d.deps)).status, 401);
  assertEquals(h.calls.length + d.calls.length, 0);
});

Deno.test('any key beyond merchant_key + category_key is refused', async () => {
  for (
    const body of [
      { ...good, amount: 12 },
      { ...good, install_id: 'abc' },
      { merchant_key: 'HALA BOUTIQUE' },
      { ...good, raw_message: 'x' },
    ]
  ) {
    const h = harness();
    assertEquals((await handleContribution(post(body), h.deps)).status, 400, JSON.stringify(body));
    assertEquals(h.calls.length, 0);
  }
});

Deno.test('identifiers, digits, people-shaped categories are refused', async () => {
  for (
    const body of [
      { merchant_key: 'CAFE ٠٥٥١٢٣٤٥٦٧', category_key: 'cafes' },
      { merchant_key: 'CAFE 12', category_key: 'cafes' },
      { merchant_key: 'NAME@MAIL.COM', category_key: 'shopping' },
      { merchant_key: 'hala boutique', category_key: 'shopping' },
      { merchant_key: 'AB', category_key: 'shopping' },
      { merchant_key: 'HALA BOUTIQUE', category_key: 'transfers' },
      { merchant_key: 'HALA BOUTIQUE', category_key: 'income' },
    ]
  ) {
    const h = harness();
    assertEquals((await handleContribution(post(body), h.deps)).status, 400, JSON.stringify(body));
    assertEquals(h.calls.length, 0);
  }
});

Deno.test('a database validation refusal maps to invalid_payload', async () => {
  const h = harness({}, { code: 'P0422' });
  const res = await handleContribution(post(good), h.deps);
  assertEquals(res.status, 400);
  assert((await res.json()).error === 'invalid_payload');
});

const withdrawBody = { merchant_key: 'HALA BOUTIQUE', action: 'withdraw' };

Deno.test("withdraw removes this user's vote via the withdraw rpc", async () => {
  const h = harness();
  const res = await handleContribution(post(withdrawBody), h.deps);
  assertEquals(res.status, 200);
  assertEquals(h.calls, [{
    fn: 'withdraw_merchant_category_contribution',
    args: { p_user_id: userIdentity.userId, p_merchant_key: 'HALA BOUTIQUE' },
  }]);
  assertEquals(h.identityBody(), {});
});

Deno.test('withdraw is allowed after consent was withdrawn', async () => {
  for (const consent of [{ aiConsent: false }, { cloudConsent: false }]) {
    const h = harness(consent);
    assertEquals((await handleContribution(post(withdrawBody), h.deps)).status, 200);
    assertEquals(h.calls.length, 1);
  }
});

Deno.test('withdraw still needs a signed-in user', async () => {
  const h = harness(null);
  assertEquals((await handleContribution(post(withdrawBody), h.deps)).status, 401);
  const d = harness({ kind: 'device', userId: null });
  assertEquals((await handleContribution(post(withdrawBody), d.deps)).status, 401);
  assertEquals(h.calls.length + d.calls.length, 0);
});

Deno.test('withdraw refuses other actions, extra keys and bad merchant keys', async () => {
  for (
    const body of [
      { merchant_key: 'HALA BOUTIQUE', action: 'delete_all' },
      { ...withdrawBody, category_key: 'shopping' },
      { merchant_key: 'CAFE 12', action: 'withdraw' },
      { merchant_key: 'hala boutique', action: 'withdraw' },
      { action: 'withdraw' },
    ]
  ) {
    const h = harness();
    assertEquals((await handleContribution(post(body), h.deps)).status, 400, JSON.stringify(body));
    assertEquals(h.calls.length, 0);
  }
});
