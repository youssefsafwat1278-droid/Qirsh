import { assertEquals, assertNotEquals, assertRejects } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { sha256Hex } from './capture_auth.ts';
import {
  apiError,
  claimIdempotency,
  consentError,
  correlationId,
  fetchWithTimeout,
  isAbortError,
  MAX_RETRY_AFTER_SECONDS,
  payloadHash,
  readJsonBody,
  resolveVerifiedIdentity,
  schemaError,
  type VerifiedIdentity,
} from './ai_endpoint.ts';

const CID = 'test-correlation-id';

// ── Typed error envelope ────────────────────────────────────────────────────

Deno.test('apiError maps codes to statuses and emits only safe fields', async () => {
  const res = apiError('rate_limited', { correlationId: CID, retryAfterSeconds: 42 });
  assertEquals(res.status, 429);
  assertEquals(res.headers.get('Retry-After'), '42');
  const body = await res.json();
  assertEquals(body, {
    error: 'rate_limited',
    retryable: true,
    correlation_id: CID,
    retry_after_seconds: 42,
  });
});

Deno.test('apiError bounds retry-after and defaults retryability', async () => {
  const res = apiError('upstream_timeout', {
    correlationId: CID,
    retryAfterSeconds: 999999,
  });
  assertEquals(res.status, 504);
  const body = await res.json();
  assertEquals(body.retry_after_seconds, MAX_RETRY_AFTER_SECONDS);
  assertEquals(body.retryable, true);
});

Deno.test('apiError never leaks a message for auth/consent codes', async () => {
  for (const code of ['authentication_required', 'consent_required', 'invalid_device_credential'] as const) {
    const res = apiError(code, { correlationId: CID });
    const body = await res.json();
    assertEquals(Object.keys(body).sort(), ['correlation_id', 'error', 'retryable']);
    assertEquals(body.retryable, false);
  }
});

// ── Bounded body + schema ───────────────────────────────────────────────────

Deno.test('readJsonBody rejects oversize via content-length without reading', async () => {
  const req = new Request('http://x', {
    method: 'POST',
    headers: { 'content-length': '5000' },
    body: 'x'.repeat(10),
  });
  const out = await readJsonBody(req, 100);
  assertEquals(out.ok, false);
  if (!out.ok) assertEquals(out.code, 'payload_too_large');
});

Deno.test('readJsonBody rejects oversize actual body and non-objects', async () => {
  const big = await readJsonBody(new Request('http://x', { method: 'POST', body: '"' + 'a'.repeat(200) + '"' }), 50);
  assertEquals(big.ok, false);
  const arr = await readJsonBody(new Request('http://x', { method: 'POST', body: '[1,2,3]' }), 1000);
  assertEquals(arr.ok, false);
  if (!arr.ok) assertEquals(arr.code, 'invalid_payload');
  const bad = await readJsonBody(new Request('http://x', { method: 'POST', body: 'not json' }), 1000);
  assertEquals(bad.ok, false);
});

Deno.test('readJsonBody accepts a plain object within bounds', async () => {
  const out = await readJsonBody(new Request('http://x', { method: 'POST', body: '{"a":1}' }), 1000);
  assertEquals(out.ok, true);
  if (out.ok) assertEquals(out.body, { a: 1 });
});

Deno.test('schemaError allows absent (v1) and rejects unsupported versions', async () => {
  assertEquals(schemaError({}, CID), null);
  assertEquals(schemaError({ schema_version: 1 }, CID), null);
  const res = schemaError({ schema_version: 99 }, CID);
  assertEquals(res?.status, 400);
  assertEquals((await res!.json()).supported_schema_version, 1);
});

// ── Verified identity (mocked supabase) ─────────────────────────────────────

// deno-lint-ignore no-explicit-any
function fakeSupabase(opts: { device?: any; settings?: any; user?: any }): any {
  const build = (table: string) => {
    const builder: Record<string, unknown> = {};
    builder.select = () => builder;
    builder.eq = () => builder;
    builder.update = () => builder;
    builder.maybeSingle = () =>
      Promise.resolve(
        table === 'capture_devices'
          ? (opts.device ?? { data: null, error: null })
          : table === 'user_settings'
          ? (opts.settings ?? { data: null, error: null })
          : { data: null, error: null },
      );
    // Awaitable for `await ...update().eq()`.
    builder.then = (resolve: (v: unknown) => void) => resolve({ data: null, error: null });
    return builder;
  };
  return {
    from: (table: string) => build(table),
    auth: { getUser: () => Promise.resolve(opts.user ?? { data: { user: null }, error: null }) },
  };
}

function req(auth?: string): Request {
  return new Request('http://x', {
    method: 'POST',
    headers: auth ? { Authorization: auth } : {},
  });
}

Deno.test('a verified device secret yields a device identity with its consent', async () => {
  const secretHash = await sha256Hex('the-secret');
  const supabase = fakeSupabase({
    device: {
      data: {
        device_secret_hash: secretHash,
        user_id: 'user-9',
        revoked_at: null,
        ai_consent_granted: true,
        cloud_processing_enabled: false,
      },
      error: null,
    },
  });
  const out = await resolveVerifiedIdentity(
    req(),
    supabase,
    { install_id: 'install-1', device_secret: 'the-secret' },
    CID,
  );
  assertEquals(out.ok, true);
  if (out.ok) {
    assertEquals(out.identity.kind, 'device');
    assertEquals(out.identity.userId, 'user-9');
    assertEquals(out.identity.aiConsent, true);
    assertEquals(out.identity.cloudConsent, false);
    assertEquals(out.identity.ownerKey.startsWith('d:'), true);
  }
});

Deno.test('a wrong device secret is invalid_device_credential (no fall-through)', async () => {
  const supabase = fakeSupabase({
    device: {
      data: { device_secret_hash: await sha256Hex('real'), revoked_at: null },
      error: null,
    },
  });
  const out = await resolveVerifiedIdentity(
    req('Bearer some-jwt'),
    supabase,
    { install_id: 'install-1', device_secret: 'WRONG' },
    CID,
  );
  assertEquals(out.ok, false);
  if (!out.ok) assertEquals(out.response.status, 401);
});

Deno.test('a revoked device is credential_revoked', async () => {
  const supabase = fakeSupabase({
    device: {
      data: {
        device_secret_hash: await sha256Hex('s'),
        revoked_at: '2026-08-01T00:00:00Z',
      },
      error: null,
    },
  });
  const out = await resolveVerifiedIdentity(req(), supabase, { install_id: 'i', device_secret: 's' }, CID);
  assertEquals(out.ok, false);
  if (!out.ok) assertEquals((await out.response.json()).error, 'credential_revoked');
});

Deno.test('install_id alone (no secret, no user) is authentication_required', async () => {
  const supabase = fakeSupabase({});
  const out = await resolveVerifiedIdentity(req(), supabase, { install_id: 'install-1' }, CID);
  assertEquals(out.ok, false);
  if (!out.ok) assertEquals((await out.response.json()).error, 'authentication_required');
});

Deno.test('a real user JWT yields a user identity with user_settings consent', async () => {
  const supabase = fakeSupabase({
    user: { data: { user: { id: 'user-77' } }, error: null },
    settings: {
      data: { ai_consent_granted: true, cloud_processing_enabled: true, consent_version: 1 },
      error: null,
    },
  });
  const out = await resolveVerifiedIdentity(req('Bearer real-user-jwt'), supabase, {}, CID);
  assertEquals(out.ok, true);
  if (out.ok) {
    assertEquals(out.identity.kind, 'user');
    assertEquals(out.identity.ownerKey, 'u:user-77');
    assertEquals(out.identity.cloudConsent, true);
  }
});

Deno.test('JWT consent is refused when user_settings stores both grants false', async () => {
  const supabase = fakeSupabase({
    user: { data: { user: { id: 'user-77' } }, error: null },
    settings: {
      data: { ai_consent_granted: false, cloud_processing_enabled: false },
      error: null,
    },
  });
  const out = await resolveVerifiedIdentity(req('Bearer real-user-jwt'), supabase, {}, CID);
  assertEquals(out.ok, true);
  if (out.ok) {
    assertEquals(out.identity.aiConsent, false);
    assertEquals(out.identity.cloudConsent, false);
    assertEquals(consentError(out.identity, 'ai', CID)?.status, 403);
    assertEquals(consentError(out.identity, 'cloud', CID)?.status, 403);
  }
});

Deno.test('a signed-in user with no settings row fails consent closed', async () => {
  const supabase = fakeSupabase({
    user: { data: { user: { id: 'user-77' } }, error: null },
    settings: { data: null, error: null },
  });
  const out = await resolveVerifiedIdentity(req('Bearer real-user-jwt'), supabase, {}, CID);
  assertEquals(out.ok, true);
  if (out.ok) {
    assertEquals(out.identity.aiConsent, false);
    assertEquals(out.identity.cloudConsent, false);
  }
});

Deno.test('JWT settings lookup error fails both consent flags closed', async () => {
  const supabase = fakeSupabase({
    user: { data: { user: { id: 'user-77' } }, error: null },
    settings: {
      data: { ai_consent_granted: true, cloud_processing_enabled: true },
      error: { message: 'lookup failed' },
    },
  });
  const out = await resolveVerifiedIdentity(req('Bearer real-user-jwt'), supabase, {}, CID);
  assertEquals(out.ok, true);
  if (out.ok) {
    assertEquals(out.identity.aiConsent, false);
    assertEquals(out.identity.cloudConsent, false);
    assertEquals(consentError(out.identity, 'ai', CID)?.status, 403);
    assertEquals(consentError(out.identity, 'cloud', CID)?.status, 403);
  }
});

Deno.test('JWT AI path also requires the cloud-processing master gate', async () => {
  const supabase = fakeSupabase({
    user: { data: { user: { id: 'user-77' } }, error: null },
    settings: {
      data: { ai_consent_granted: true, cloud_processing_enabled: false },
      error: null,
    },
  });
  const out = await resolveVerifiedIdentity(req('Bearer real-user-jwt'), supabase, {}, CID);
  assertEquals(out.ok, true);
  if (out.ok) assertEquals(consentError(out.identity, 'ai', CID)?.status, 403);
});

// 0109 — server user_settings consent is a conservative denial: NULL/FALSE
// deny, and TRUE counts only with consent_version > 0.
for (
  const [name, row] of [
    ['NULL grants (the new default)', { ai_consent_granted: null, cloud_processing_enabled: null, consent_version: 0 }],
    ['an unproven TRUE (consent_version 0)', { ai_consent_granted: true, cloud_processing_enabled: true, consent_version: 0 }],
    ['TRUE with a NULL consent_version', { ai_consent_granted: true, cloud_processing_enabled: true, consent_version: null }],
  ] as const
) {
  Deno.test(`JWT consent is denied for ${name}`, async () => {
    const supabase = fakeSupabase({
      user: { data: { user: { id: 'user-77' } }, error: null },
      settings: { data: row, error: null },
    });
    const out = await resolveVerifiedIdentity(req('Bearer real-user-jwt'), supabase, {}, CID);
    assertEquals(out.ok, true);
    if (out.ok) {
      assertEquals(out.identity.aiConsent, false);
      assertEquals(out.identity.cloudConsent, false);
      assertEquals(consentError(out.identity, 'ai', CID)?.status, 403);
      assertEquals(consentError(out.identity, 'cloud', CID)?.status, 403);
    }
  });
}

Deno.test('JWT consent is accepted for TRUE with consent_version > 0', async () => {
  const supabase = fakeSupabase({
    user: { data: { user: { id: 'user-77' } }, error: null },
    settings: {
      data: { ai_consent_granted: true, cloud_processing_enabled: true, consent_version: 2 },
      error: null,
    },
  });
  const out = await resolveVerifiedIdentity(req('Bearer real-user-jwt'), supabase, {}, CID);
  assertEquals(out.ok, true);
  if (out.ok) {
    assertEquals(consentError(out.identity, 'ai', CID), null);
    assertEquals(consentError(out.identity, 'cloud', CID), null);
  }
});

// ── Consent gate ────────────────────────────────────────────────────────────

Deno.test('consentError blocks the missing kind and passes the granted one', () => {
  const base: VerifiedIdentity = {
    kind: 'device',
    ownerKey: 'd:x',
    userId: null,
    installIdHash: 'x',
    aiConsent: false,
    cloudConsent: true,
  };
  assertEquals(consentError(base, 'cloud', CID), null);
  const blocked = consentError(base, 'ai', CID);
  assertEquals(blocked?.status, 403);
});

Deno.test('AI consent cannot bypass the cloud-processing master gate', () => {
  const cloudOff: VerifiedIdentity = {
    kind: 'device',
    ownerKey: 'd:x',
    userId: null,
    installIdHash: 'x',
    aiConsent: true,
    cloudConsent: false,
  };
  assertEquals(consentError(cloudOff, 'ai', CID)?.status, 403);
});

// Gemini-first phase 3: smart analysis (parse-sms) needs the AI consent only.
Deno.test("'smart' needs the AI consent and nothing else; Cloud alone never opens it", () => {
  const identity = (aiConsent: boolean, cloudConsent: boolean): VerifiedIdentity => ({
    kind: 'device',
    ownerKey: 'd:x',
    userId: null,
    installIdHash: 'x',
    aiConsent,
    cloudConsent,
  });
  assertEquals(consentError(identity(true, false), 'smart', CID), null);
  assertEquals(consentError(identity(true, true), 'smart', CID), null);
  assertEquals(consentError(identity(false, true), 'smart', CID)?.status, 403);
  assertEquals(consentError(identity(false, false), 'smart', CID)?.status, 403);
});

Deno.test('correlationId is opaque and unique', () => {
  const a = correlationId();
  const b = correlationId();
  assertEquals(a === b, false);
  assertEquals(a.length > 0, true);
});

// ── Idempotency + upstream helpers ──────────────────────────────────────────

Deno.test('payloadHash is deterministic and payload-sensitive', async () => {
  const a = await payloadHash(['owner', 'parse-sms', 'ACME 512.34']);
  const b = await payloadHash(['owner', 'parse-sms', 'ACME 512.34']);
  const c = await payloadHash(['owner', 'parse-sms', 'ACME 999.99']);
  assertEquals(a, b);
  assertNotEquals(a, c);
});

// deno-lint-ignore no-explicit-any
function rpcSupabase(rows: unknown, error: unknown = null): any {
  return { rpc: () => Promise.resolve({ data: rows, error }) };
}

Deno.test('claimIdempotency maps every RPC outcome', async () => {
  assertEquals(
    (await claimIdempotency(
      rpcSupabase([{ outcome: 'claimed', status: 'in_progress', result: {} }]),
      'o',
      'e',
      'r',
      'h',
    )).outcome,
    'claimed',
  );
  assertEquals(
    (await claimIdempotency(
      rpcSupabase([{ outcome: 'mismatch', status: 'in_progress', result: {} }]),
      'o',
      'e',
      'r',
      'h',
    )).outcome,
    'mismatch',
  );
  const exists = await claimIdempotency(
    rpcSupabase([{ outcome: 'exists', status: 'succeeded', result: { category: 'cafes' } }]),
    'o',
    'e',
    'r',
    'h',
  );
  assertEquals(exists.outcome, 'exists');
  if (exists.outcome === 'exists') assertEquals(exists.result.category, 'cafes');
  assertEquals(
    (await claimIdempotency(rpcSupabase(null, { message: 'boom' }), 'o', 'e', 'r', 'h')).outcome,
    'error',
  );
});

Deno.test('fetchWithTimeout aborts a hung upstream', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = ((_url: string | URL | Request, init?: RequestInit) =>
    new Promise((_, reject) => {
      init?.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
    })) as typeof fetch;
  try {
    const err = await assertRejects(() => fetchWithTimeout('http://example.test', {}, 10));
    assertEquals(isAbortError(err), true);
  } finally {
    globalThis.fetch = original;
  }
});
