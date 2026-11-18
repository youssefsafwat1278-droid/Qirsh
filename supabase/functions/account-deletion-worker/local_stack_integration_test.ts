// Decision 3.4 (deletion is final) — the account-deletion saga against a REAL
// local Supabase stack: real migrations, Auth, PostgREST, Storage and the real
// coordinator, adapter, challenge port, email proof, storage erasure, worker
// handler and inline handler. Only Apple is stubbed (the synthetic users sign in
// with email, so no Apple material exists) and one Storage/claim failure is
// injected on purpose for the retry scenarios.
//
// SKIPPED unless LOCAL_SUPABASE_URL points at loopback and
// LOCAL_SUPABASE_SERVICE_ROLE_KEY, LOCAL_SUPABASE_ANON_KEY and LOCAL_MAILPIT_URL
// are set (local-stack gate: docs/releases/version-1/evidence/closure/data.md).
// Synthetic accounts only; every account it creates is deleted by the scenario.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { buildAccountDeletionCoordinator } from '../_shared/account_deletion_adapter.ts';
import { createAlternateDeletionProof } from '../_shared/account_deletion_alternate_proof.ts';
import { createChallengePort } from '../_shared/account_deletion_wiring.ts';
import { createMaterialSealer } from '../_shared/material_sealer.ts';
import { ERASURE_BUCKETS, type StorageLike } from '../_shared/storage_erasure.ts';
import { retryWorkerClaim } from '../_shared/worker_claim_retry.ts';
import { createDeleteAccountHandler } from '../delete-account-immediate/handler.ts';
import { createWorkerHandler } from './handler.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const url = env('LOCAL_SUPABASE_URL');
const host = url ? new URL(url).hostname : '';
const live = (host === '127.0.0.1' || host === 'localhost') && env('LOCAL_SUPABASE_SERVICE_ROLE_KEY') !== '' &&
  env('LOCAL_SUPABASE_ANON_KEY') !== '' && env('LOCAL_MAILPIT_URL') !== '';
const ignore = !live;

const serviceKey = env('LOCAL_SUPABASE_SERVICE_ROLE_KEY');
const anonKey = env('LOCAL_SUPABASE_ANON_KEY');
const mailpit = env('LOCAL_MAILPIT_URL');

const admin = () => createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

type Synthetic = { uid: string; email: string; password: string; token: string };

const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
const randomSecret = () => b64url(crypto.getRandomValues(new Uint8Array(32)));

async function createSynthetic(label: string): Promise<Synthetic> {
  const email = `del-${label}-${crypto.randomUUID().slice(0, 8)}@example.test`;
  const password = randomSecret();
  const db = admin();
  const created = await db.auth.admin.createUser({ email, password, email_confirm: true });
  if (created.error || !created.data.user) throw new Error(`createUser: ${created.error?.message}`);
  return { uid: created.data.user.id, email, password, token: await signIn(email, password) };
}

async function signIn(email: string, password: string): Promise<string> {
  const res = await fetch(`${url}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: anonKey, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`signIn ${res.status}`);
  return body.access_token as string;
}

const asUser = (token: string) =>
  createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });

/** What a signed-in client leaves behind: synced rows, a cloud backup, a profile photo. */
async function seedAccountData(u: Synthetic) {
  const c = asUser(u.token);
  const tx = await c.from('user_transactions').insert({
    user_id: u.uid,
    client_request_id: `seed-${crypto.randomUUID()}`,
    amount: 12.5,
    currency: 'SAR',
    direction: 'debit',
    merchant: 'Synthetic shop',
    occurred_at: new Date().toISOString(),
    source: 'manual',
  });
  if (tx.error) throw new Error(`seed user_transactions: ${tx.error.message}`);
  const bytes = new TextEncoder().encode('synthetic');
  for (
    const [bucket, path] of [
      ['backups', `${u.uid}/g/gen1.enc`],
      ['backups', `${u.uid}/backup.enc`],
      ['profile-photos', `${u.uid}/avatar`],
    ] as const
  ) {
    const up = await c.storage.from(bucket).upload(path, bytes, {
      upsert: true,
      contentType: bucket === 'profile-photos' ? 'image/jpeg' : 'application/octet-stream',
    });
    if (up.error) throw new Error(`seed ${bucket}: ${up.error.message}`);
  }
}

async function snapshot(uid: string) {
  const db = admin();
  const count = async (table: string, column = 'user_id') => {
    const r = await db.from(table).select('*', { count: 'exact', head: true }).eq(column, uid);
    if (r.error) throw new Error(`${table}: ${r.error.message}`);
    return r.count ?? 0;
  };
  const objects: { backups: number; 'profile-photos': number } = { backups: 0, 'profile-photos': 0 };
  for (const bucket of ERASURE_BUCKETS) {
    let n = 0;
    for (const prefix of [uid, `${uid}/g`]) {
      const l = await db.storage.from(bucket).list(prefix, { limit: 100 });
      if (l.error) throw new Error(`list ${bucket}: ${l.error.message}`);
      n += (l.data ?? []).filter((o) => o.id).length;
    }
    objects[bucket] = n;
  }
  const authUser = await db.auth.admin.getUserById(uid);
  return {
    auth: authUser.data?.user ? 1 : 0,
    profiles: await count('profiles', 'id'),
    user_transactions: await count('user_transactions'),
    ...objects,
  };
}

/** The 6-digit reauthentication code GoTrue mailed to [email] (local Mailpit). */
async function mailedCode(email: string): Promise<string> {
  for (let i = 0; i < 40; i++) {
    const list = await (await fetch(`${mailpit}/api/v1/search?query=${encodeURIComponent(`to:${email}`)}`)).json();
    const id = list.messages?.[0]?.ID;
    if (id) {
      const msg = await (await fetch(`${mailpit}/api/v1/message/${id}`)).json();
      const m = /\b(\d{6})\b/.exec(`${msg.Text ?? ''} ${msg.HTML ?? ''}`);
      if (m) return m[1];
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error('no reauthentication email');
}

type Faults = { storageRemoveFailures?: number; claimJwtFutureOnce?: boolean };

async function harness(faults: Faults = {}) {
  const db = admin();
  let claimFaulted = false;
  type RpcResult = { data: unknown; error: { code?: string; message?: string } | null };
  const rawRpc = async (fn: string, args: Record<string, unknown>): Promise<RpcResult> => {
    if (fn === 'account_deletion_claim_lease' && faults.claimJwtFutureOnce && !claimFaulted) {
      claimFaulted = true;
      return { data: null, error: { code: 'PGRST303', message: 'JWT issued at future' } };
    }
    return await db.rpc(fn, args);
  };
  // Exactly the runtime's wiring (account_deletion_runtime.ts): the scheduled
  // worker retries a claim rejected for clock skew.
  const workerRpc = {
    rpc: (fn: string, args: Record<string, unknown>) =>
      fn === 'account_deletion_claim_lease'
        ? retryWorkerClaim(() => rawRpc(fn, args), () => Promise.resolve())
        : rawRpc(fn, args),
  };
  const rpc = { rpc: rawRpc };
  let removeFailures = faults.storageRemoveFailures ?? 0;
  const storage: StorageLike = {
    from(bucket: string) {
      const real = db.storage.from(bucket);
      return {
        list: (path, opts) => real.list(path, opts),
        remove: (paths) => {
          if (removeFailures > 0) {
            removeFailures--;
            return Promise.resolve({ data: null, error: { message: 'injected storage outage' } });
          }
          return real.remove(paths);
        },
      };
    },
  };
  const getUser = async (jwt: string) => {
    const { data, error } = await db.auth.getUser(jwt);
    return error || !data?.user ? null : { id: data.user.id };
  };
  const sealer = await createMaterialSealer(btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))));
  const build = (r: typeof rpc) =>
    buildAccountDeletionCoordinator({
      rpc: r,
      identity: { getUser },
      // Email users only: no Apple material is ever created or revoked.
      apple: {
        authorize: () => Promise.resolve({ status: 'not_configured' }),
        revoke: () => Promise.resolve('failed'),
      } as never,
      alternateProof: createAlternateDeletionProof({
        rpc: r,
        now: Date.now,
        verifyGoogle: () => Promise.resolve(null),
      }),
      sealer,
      storage,
      authAdmin: {
        deleteUser: async (uid) => {
          const { error } = await db.auth.admin.deleteUser(uid);
          return { error: error ? { status: error.status, code: error.code, message: error.message } : null };
        },
      },
      config: {
        database: true,
        storage_admin: true,
        auth_admin: true,
        intent_verification: true,
        apple_signing: true,
        token_encryption: true,
      },
    }, { options: { retryBaseMs: 1, retryMaxMs: 1 } });
  const coordinator = build(rpc);
  const workerCoordinator = build(workerRpc);
  const challenge = createChallengePort({
    rpc,
    getUser,
    isAdmin: () => Promise.resolve(false),
    sendEmailCode: async (bearer) => {
      const res = await fetch(`${url}/auth/v1/reauthenticate`, {
        headers: { apikey: anonKey, authorization: `Bearer ${bearer}` },
      });
      await res.body?.cancel();
      if (!res.ok) throw new Error(`reauthenticate ${res.status}`);
    },
  });
  const inline = createDeleteAccountHandler({ coordinator, workerId: 'inline-test', challenge });
  const worker = createWorkerHandler({
    coordinator: () => workerCoordinator,
    workerSecret: 'local-worker-secret',
    workerId: 'worker-test',
  });
  const post = (h: (r: Request) => Promise<Response>, body: unknown, bearer: string) =>
    h(
      new Request('http://local/fn', {
        method: 'POST',
        headers: { authorization: `Bearer ${bearer}`, 'content-type': 'application/json' },
        body: JSON.stringify(body),
      }),
    );
  return {
    coordinator,
    claimFaulted: () => claimFaulted,
    /** Challenge + emailed code, exactly as the app sends them. */
    async proof(u: Synthetic) {
      const res = await post(inline, { action: 'challenge', proof_version: 2, email_only: true }, u.token);
      const body = await res.json();
      assertEquals(body.status, 'challenge', JSON.stringify(body));
      assertEquals(body.proof_method, 'email');
      return {
        challengeId: body.challenge_id as string,
        challengeResponse: JSON.stringify({ proof: 'email', code: await mailedCode(u.email) }),
      };
    },
    inlineRequest: async (u: Synthetic, p: { challengeId: string; challengeResponse: string }, receipt: string) =>
      (await post(inline, {
        challenge_id: p.challengeId,
        challenge_response: p.challengeResponse,
        receipt_secret: receipt,
      }, u.token)).json(),
    status: async (receipt: string) => (await post(inline, { action: 'status', receipt_secret: receipt }, '')).json(),
    runWorker: async () => (await post(worker, {}, 'local-worker-secret')).json(),
  };
}

const ALL_GONE = { auth: 0, profiles: 0, user_transactions: 0, backups: 0, 'profile-photos': 0 };

async function expectNoComeback(u: Synthetic) {
  // The deleted user's still-unexpired token can no longer write anything back.
  const c = asUser(u.token);
  const tx = await c.from('user_transactions').insert({
    user_id: u.uid,
    client_request_id: `late-${crypto.randomUUID()}`,
    amount: 1,
    currency: 'SAR',
    direction: 'debit',
    occurred_at: new Date().toISOString(),
    source: 'manual',
  });
  assert(tx.error !== null, 'a late sync push from the deleted account must be refused');
  const up = await c.storage.from('backups').upload(`${u.uid}/late.enc`, new Uint8Array([1]), { upsert: true });
  assert(up.error !== null, 'a late backup upload from the deleted account must be refused');
  const photo = await c.storage.from('profile-photos').upload(`${u.uid}/avatar`, new Uint8Array([1]), {
    upsert: true,
    contentType: 'image/jpeg',
  });
  assert(photo.error !== null, 'a late profile-photo upload from the deleted account must be refused');
  assertEquals(await snapshot(u.uid), ALL_GONE);
}

const log = (label: string, v: unknown) => console.log(`${label}: ${JSON.stringify(v)}`);

Deno.test({
  name: 'D1 inline deletion completes: account data, cloud backups and profile photo are gone',
  ignore,
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const h = await harness();
    const u = await createSynthetic('d1');
    await seedAccountData(u);
    const before = await snapshot(u.uid);
    log('D1 before', before);
    assertEquals(before, { auth: 1, profiles: 1, user_transactions: 1, backups: 2, 'profile-photos': 1 });

    const receipt = randomSecret();
    const res = await h.inlineRequest(u, await h.proof(u), receipt);
    log('D1 inline response', res);
    assertEquals(res.status, 'completed');
    assertEquals((await h.status(receipt)).status, 'completed');
    const after = await snapshot(u.uid);
    log('D1 after', after);
    assertEquals(after, ALL_GONE);
    await expectNoComeback(u);
  },
});

Deno.test({
  name: 'D2 an accepted deletion whose inline run never happened is finished by the worker alone',
  ignore,
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const h = await harness();
    const u = await createSynthetic('d2');
    await seedAccountData(u);
    const p = await h.proof(u);
    const receipt = randomSecret();
    // Acceptance only (the inline drive crashed / timed out right after it).
    const accepted = await h.coordinator.requestDeletion({ bearerToken: u.token, receiptSecret: receipt, ...p });
    assertEquals(accepted.status, 'accepted');
    assertEquals((await h.status(receipt)).status !== 'completed', true);
    log('D2 before worker', await snapshot(u.uid));

    const run = await h.runWorker();
    log('D2 worker run', run);
    assertEquals(run.status, 'ok');
    assertEquals(run.completed, 1);
    assertEquals((await h.status(receipt)).status, 'completed');
    const after = await snapshot(u.uid);
    log('D2 after', after);
    assertEquals(after, ALL_GONE);
    await expectNoComeback(u);
  },
});

Deno.test({
  name: 'D3 a storage failure schedules a retry; the worker resumes and finishes, claim clock-skew retried',
  ignore,
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const h = await harness({ storageRemoveFailures: 1, claimJwtFutureOnce: true });
    const u = await createSynthetic('d3');
    await seedAccountData(u);
    const receipt = randomSecret();
    // Inline run hits the injected Storage outage: honest in-progress, not done.
    const res = await h.inlineRequest(u, await h.proof(u), receipt);
    log('D3 inline response', res);
    assertEquals(res.status, 'in_progress');
    const mid = await snapshot(u.uid);
    log('D3 after failed inline run', mid);
    assertEquals(mid.auth, 1, 'nothing past the failed step ran');

    // The worker's first claim is refused for clock skew and retried once.
    const run = await h.runWorker();
    log('D3 worker run', run);
    assertEquals(run.status, 'ok');
    assertEquals(run.completed, 1);
    assertEquals(h.claimFaulted(), true, 'the clock-skew claim refusal was injected and retried');
    assertEquals((await h.status(receipt)).status, 'completed');
    const after = await snapshot(u.uid);
    log('D3 after', after);
    assertEquals(after, ALL_GONE);
    await expectNoComeback(u);
  },
});

Deno.test({
  name: 'D4 a later sign-up with the same email is a new, empty account',
  ignore,
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const h = await harness();
    const u = await createSynthetic('d4');
    await seedAccountData(u);
    const res = await h.inlineRequest(u, await h.proof(u), randomSecret());
    assertEquals(res.status, 'completed');
    const db: SupabaseClient = admin();
    const again = await db.auth.admin.createUser({ email: u.email, password: u.password, email_confirm: true });
    assert(!again.error && again.data.user);
    const uid2 = again.data.user.id;
    assert(uid2 !== u.uid, 'a new identity');
    const s2 = await snapshot(uid2);
    log('D4 new account', s2);
    assertEquals({ ...s2, auth: 0, profiles: 0 }, ALL_GONE, 'nothing of the deleted account is attached');
    await db.auth.admin.deleteUser(uid2);
  },
});
