import { assert, assertEquals } from 'jsr:@std/assert@1';
import { handleRegisterPushToken } from './index.ts';

type Device = { apns_token: string | null; apns_environment: string | null };

// In-memory capture_devices row with real compare-and-swap semantics for
// `.update(...).eq('apns_token', x)` / `.is('apns_token', null)`.
function fake(device: Device, opts: {
  rateLimited?: boolean;
  beforeUpdate?: (d: Device) => void;
  busyWrites?: number;
} = {}) {
  const state = { device, updates: 0, rateBumps: 0 };
  const client = {
    rpc: () => {
      state.rateBumps++;
      return Promise.resolve({ data: opts.rateLimited === true, error: null });
    },
    from: (_table: string) => {
      let patch: Record<string, unknown> | null = null;
      const conds: Array<[string, unknown]> = [];
      const b = {
        select: (_cols?: string) => b,
        update: (p: Record<string, unknown>) => {
          patch = p;
          return b;
        },
        eq: (c: string, v: unknown) => (conds.push([c, v]), b),
        is: (c: string, v: unknown) => (conds.push([c, v]), b),
        maybeSingle: () => Promise.resolve({ data: { ...state.device }, error: null }),
        then: (resolve: (v: unknown) => unknown) => {
          if (patch == null) return Promise.resolve({ data: [{ ...state.device }], error: null }).then(resolve);
          if ((opts.busyWrites ?? 0) > 0) {
            opts.busyWrites!--;
            return Promise.resolve({ data: null, error: { code: '55P03' } }).then(resolve);
          }
          opts.beforeUpdate?.(state.device);
          opts.beforeUpdate = undefined;
          const ok = conds.every(([c, v]) => c === 'install_id_hash' || (state.device as Record<string, unknown>)[c] === v);
          if (ok) {
            state.updates++;
            state.device.apns_token = patch.apns_token as string;
            state.device.apns_environment = patch.apns_environment as string;
          }
          return Promise.resolve({ data: ok ? [{ install_id_hash: 'h' }] : [], error: null }).then(resolve);
        },
      };
      return b;
    },
  };
  return { state, client };
}

async function call(f: ReturnType<typeof fake>, body: Record<string, unknown> = {}) {
  const res = await handleRegisterPushToken(
    new Request('https://x.test/register-push-token', {
      method: 'POST',
      body: JSON.stringify({ installId: 'i', deviceSecret: 's', apnsToken: 'new', apnsEnvironment: 'sandbox', ...body }),
    }),
    {
      createServiceClient: (() => f.client) as never,
      verifyDevice: (() => Promise.resolve({ ok: true, installIdHash: 'h', userId: null })) as never,
    },
  );
  return { status: res.status, json: await res.json() };
}

Deno.test('first registration (no stored token) swaps null -> token', async () => {
  const f = fake({ apns_token: null, apns_environment: null });
  const r = await call(f);
  assertEquals([r.status, r.json], [200, { ok: true }]);
  assertEquals(f.state.device.apns_token, 'new');
});

Deno.test('same token and environment is an idempotent success that spends no rate budget', async () => {
  const f = fake({ apns_token: 'new', apns_environment: 'sandbox' });
  const r = await call(f);
  assertEquals(r.json, { ok: true, unchanged: true });
  assertEquals([f.state.updates, f.state.rateBumps], [0, 0]);
});

Deno.test('rotation swaps old -> new only against the token that was read', async () => {
  const f = fake({ apns_token: 'old', apns_environment: 'production' });
  const r = await call(f);
  assertEquals(r.status, 200);
  assertEquals(f.state.device, { apns_token: 'new', apns_environment: 'sandbox' });
});

Deno.test('registration recovers after a rolled-back account_busy write', async () => {
  const f = fake({ apns_token: 'old', apns_environment: 'production' }, { busyWrites: 1 });
  const r = await call(f);
  assertEquals([r.status, r.json], [200, { ok: true }]);
  assertEquals(f.state.device.apns_token, 'new');
  assertEquals([f.state.updates, f.state.rateBumps], [1, 1]);
});

Deno.test('continued account_busy tells the caller to retry and preserves the token', async () => {
  const f = fake({ apns_token: 'old', apns_environment: 'production' }, { busyWrites: 2 });
  const r = await call(f);
  assertEquals([r.status, r.json.error], [503, 'token_update_busy']);
  assertEquals(f.state.device.apns_token, 'old');
  assertEquals([f.state.updates, f.state.rateBumps], [0, 1]);
});

Deno.test('a concurrent change between read and write loses the CAS, re-reads and retries once', async () => {
  const f = fake({ apns_token: 'old', apns_environment: 'production' }, {
    beforeUpdate: (d) => {
      d.apns_token = 'raced'; // another registration landed after our read
    },
  });
  const r = await call(f);
  assertEquals(r.status, 200);
  assertEquals(f.state.device.apns_token, 'new');
  assertEquals(f.state.rateBumps, 1); // one budget charge for the request, not per attempt
});

Deno.test('the racing registration is the same token: lost CAS resolves as unchanged, nothing overwritten', async () => {
  const f = fake({ apns_token: 'old', apns_environment: 'production' }, {
    beforeUpdate: (d) => {
      d.apns_token = 'new';
      d.apns_environment = 'sandbox';
    },
  });
  const r = await call(f);
  assertEquals(r.json, { ok: true, unchanged: true });
  assertEquals(f.state.updates, 0);
});

Deno.test('rate limit applies to real changes only', async () => {
  const f = fake({ apns_token: 'old', apns_environment: 'sandbox' }, { rateLimited: true });
  const r = await call(f);
  assertEquals([r.status, r.json.error], [429, 'rate_limit_exceeded']);
  assertEquals(f.state.device.apns_token, 'old');
});

Deno.test('persistent contention returns 409 token_update_conflict and never writes a stale value', async () => {
  const f = fake({ apns_token: 'old', apns_environment: 'sandbox' });
  let n = 0;
  const original = f.client.from;
  f.client.from = ((t: string) => {
    const b = original(t) as Record<string, (...a: unknown[]) => unknown>;
    const upd = b.update;
    b.update = (p: unknown) => {
      f.state.device.apns_token = `raced-${n++}`; // every attempt loses
      return upd(p);
    };
    return b;
  }) as never;
  const r = await call(f);
  assertEquals([r.status, r.json.error], [409, 'token_update_conflict']);
  assert(f.state.device.apns_token!.startsWith('raced-'));
});

Deno.test('missing token or bad environment is rejected before any lookup', async () => {
  const f = fake({ apns_token: null, apns_environment: null });
  assertEquals((await call(f, { apnsToken: '' })).status, 400);
  assertEquals((await call(f, { apnsEnvironment: 'staging' })).status, 400);
});
