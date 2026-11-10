import { assert, assertEquals, assertFalse, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  type AcceptInput,
  type AcceptOutcome,
  type AppleRevokeOutcome,
  type AuthDeleteOutcome,
  type AuthorizationResult,
  type CoordinatorOptions,
  createAccountDeletionCoordinator,
  type ConfigKey,
  type ConfigReadiness,
  type DeletionAuthorizer,
  type DeletionRequest,
  DELETION_STAGES,
  type DeletionStage,
  type DeletionSteps,
  type DeletionStore,
  type ErrorCode,
  type IdentityResult,
  type JobSnapshot,
  type JobState,
  type Lease,
  type LeaseGrant,
  type LeaseWrite,
  type LogEvent,
  type MaterialDisposition,
  type ReceiptRecord,
  type StepOutcome,
  type StorageOutcome,
} from './account_deletion_coordinator.ts';

// Deterministic unit tests for the immediate-deletion coordinator ONLY.
// No network, no database, no Supabase/Apple/Storage client. The in-memory
// store below MODELS the store contract documented in the coordinator; passing
// these tests proves orchestration order, lease fencing and redaction against
// that model. They do NOT prove SQL atomicity, lock ordering, RLS, or that any
// write ingress is actually frozen: that needs a real transactional adapter and
// isolated database concurrency tests. Nothing here is deletion or security
// release proof.

const UID_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const UID_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const UID_C = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

const LEASE_MS = 10_000;
const OPTIONS: CoordinatorOptions = {
  leaseMs: LEASE_MS,
  receiptRetentionMs: 2 * 60 * 60 * 1000,
  retryBaseMs: 1_000,
  retryMaxMs: 8_000,
};
const LATE = 60_000; // past any lease or retry delay

type Deferred<T = void> = { promise: Promise<T>; resolve: (value: T) => void };
function deferred<T = void>(): Deferred<T> {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}
const tick = () => new Promise<void>((r) => setTimeout(r, 0));

class Crash extends Error {}

// ── in-memory store (models the contract; not a proof of it) ─────────────────

type MemJob = {
  jobId: string;
  uid: string;
  seq: number;
  state: JobState;
  completed: DeletionStage[];
  started: DeletionStage | null;
  ref: string | null;
  attempts: number;
  token: string | null;
  generation: number;
  leaseUntil: number;
  notBefore: number;
  lastCode: ErrorCode | null;
};

type FaultPoint = { op: string; when: 'before' | 'after'; stage?: DeletionStage };

// Models the atomic, reference-aware custody contract of encrypted Apple material
// (see MATERIAL CUSTODY in the coordinator). One registry is shared by the fake
// store (commit) and the fake authorizer (issue/dispose), standing in for the
// single system a real adapter must serialize them in. Every method is
// synchronous, so each is atomic with respect to the others; a test can still
// interleave whole requests. It models the property; it does not prove it.
//   holds      outstanding issuances that could still commit (one per attempt)
//   committed  committed jobs that reference the material
class MaterialVault {
  holds = new Map<string, number>();
  committed = new Map<string, number>();
  destroyed = new Set<string>();
  private n = (m: Map<string, number>, ref: string) => m.get(ref) ?? 0;

  issue(ref: string) {
    this.destroyed.delete(ref); // a fresh exchange produced fresh material
    this.holds.set(ref, this.n(this.holds, ref) + 1);
  }
  /** A commit may reference only material that is held and not destroyed. */
  canCommit(ref: string) {
    return !this.destroyed.has(ref) && this.n(this.holds, ref) > 0;
  }
  /** The committing attempt's hold becomes a committed reference. */
  commit(ref: string) {
    this.holds.set(ref, this.n(this.holds, ref) - 1);
    this.committed.set(ref, this.n(this.committed, ref) + 1);
  }
  /** Releases ONE hold, then destroys only if nothing references the material. */
  dispose(ref: string): { status: 'disposed' | 'kept_referenced' } {
    if (this.n(this.holds, ref) > 0) this.holds.set(ref, this.n(this.holds, ref) - 1);
    if (this.n(this.committed, ref) > 0 || this.n(this.holds, ref) > 0) return { status: 'kept_referenced' };
    this.destroyed.add(ref);
    return { status: 'disposed' };
  }
}

class MemStore implements DeletionStore {
  jobs = new Map<string, MemJob>();
  uidJob = new Map<string, string>();
  scopes = new Map<string, { jobId: string; receiptHash: string }>();
  // expiresAtMs stays null for every non-terminal job: only completeJob starts retention.
  receipts = new Map<string, { jobId: string; expiresAtMs: number | null }>();
  frozen = new Set<string>();
  fault: FaultPoint | null = null;
  failNextAccept = false;
  // Persistent per-operation outage, and one-shot async hooks run before an op.
  down = new Set<string>();
  hooks: Record<string, () => void | Promise<void>> = {};
  private seq = 0;
  private tokens = 0;

  constructor(private clock: () => number, readonly vault: MaterialVault = new MaterialVault()) {}

  private hit(op: string, when: 'before' | 'after', stage?: DeletionStage) {
    const f = this.fault;
    if (f && f.op === op && f.when === when && (f.stage === undefined || f.stage === stage)) {
      this.fault = null;
      throw new Crash('injected crash');
    }
  }

  private async wrap<T>(op: string, stage: DeletionStage | undefined, fn: () => T): Promise<T> {
    const hook = this.hooks[op];
    if (hook) {
      delete this.hooks[op];
      await hook();
    }
    if (this.down.has(op)) throw new Crash('store outage');
    this.hit(op, 'before', stage);
    const result = fn();
    this.hit(op, 'after', stage);
    await Promise.resolve();
    return result;
  }

  private leaseOk(lease: Lease): MemJob | null {
    const job = this.jobs.get(lease.jobId);
    if (
      !job || job.token !== lease.token || job.generation !== lease.generation ||
      job.leaseUntil <= this.clock() || job.state === 'completed'
    ) return null;
    return job;
  }

  findAccepted(scopeKey: string) {
    return this.wrap('findAccepted', undefined, () => this.scopes.get(scopeKey) ?? null);
  }

  accept(i: AcceptInput): Promise<AcceptOutcome> {
    return this.wrap('accept', undefined, (): AcceptOutcome => {
      const dup = this.scopes.get(i.scopeKey);
      if (dup) {
        return dup.receiptHash === i.receiptHash
          ? { outcome: 'duplicate', jobId: dup.jobId }
          : { outcome: 'idempotency_conflict' };
      }
      if (this.clock() >= i.challengeExpiresAtMs) return { outcome: 'challenge_expired' };
      const existing = this.uidJob.get(i.uid);
      // Everything is staged first; the commit below is all-or-nothing.
      if (this.failNextAccept) {
        this.failNextAccept = false;
        throw new Error('db unavailable');
      }
      // A new job may only reference material that is held and not disposed.
      if (!existing && i.appleMaterialRef !== null && !this.vault.canCommit(i.appleMaterialRef)) throw new Error('material unavailable');
      if (existing) {
        this.scopes.set(i.scopeKey, { jobId: existing, receiptHash: i.receiptHash });
        this.receipts.set(i.receiptHash, { jobId: existing, expiresAtMs: null });
        return { outcome: 'already_pending', jobId: existing };
      }
      const jobId = `job-${++this.seq}`;
      this.jobs.set(jobId, {
        jobId,
        uid: i.uid,
        seq: this.seq,
        state: 'accepted',
        completed: i.appleMaterialRef === null ? ['apple_revoke'] : [],
        started: null,
        ref: i.appleMaterialRef,
        attempts: 0,
        token: null,
        generation: 0,
        leaseUntil: 0,
        notBefore: 0,
        lastCode: null,
      });
      this.uidJob.set(i.uid, jobId);
      if (i.appleMaterialRef !== null) this.vault.commit(i.appleMaterialRef);
      this.frozen.add(i.uid); // immutable: no method ever removes it
      this.scopes.set(i.scopeKey, { jobId, receiptHash: i.receiptHash });
      this.receipts.set(i.receiptHash, { jobId, expiresAtMs: null });
      return { outcome: 'accepted', jobId };
    });
  }

  claimLease(input: { workerId: string; leaseMs: number; jobId?: string }): Promise<LeaseGrant | null> {
    return this.wrap('claimLease', undefined, () => {
      const now = this.clock();
      const candidates = [...this.jobs.values()]
        .filter((j) =>
          (input.jobId === undefined || j.jobId === input.jobId) &&
          (j.state === 'accepted' || j.state === 'running' || j.state === 'retryable') &&
          j.leaseUntil <= now && j.notBefore <= now
        )
        .sort((a, b) => a.seq - b.seq);
      const job = candidates[0];
      if (!job) return null;
      job.generation += 1;
      job.token = `lease-${++this.tokens}`;
      job.leaseUntil = now + input.leaseMs;
      job.state = 'running';
      const snapshot: JobSnapshot = {
        jobId: job.jobId,
        uid: job.uid,
        completedSteps: [...job.completed],
        appleMaterialRef: job.ref,
        attempts: job.attempts,
      };
      return { lease: { jobId: job.jobId, token: job.token, generation: job.generation }, job: snapshot };
    });
  }

  heartbeat(lease: Lease, leaseMs: number): Promise<LeaseWrite> {
    return this.wrap('heartbeat', undefined, (): LeaseWrite => {
      const job = this.leaseOk(lease);
      if (!job) return { ok: false, reason: 'lease_lost' };
      job.leaseUntil = this.clock() + leaseMs;
      return { ok: true };
    });
  }

  beginStep(lease: Lease, stage: DeletionStage): Promise<LeaseWrite> {
    return this.wrap('beginStep', stage, (): LeaseWrite => {
      const job = this.leaseOk(lease);
      if (!job) return { ok: false, reason: 'lease_lost' };
      if (DELETION_STAGES[job.completed.length] !== stage) return { ok: false, reason: 'out_of_order' };
      job.started = stage;
      return { ok: true };
    });
  }

  completeStep(lease: Lease, stage: DeletionStage): Promise<LeaseWrite> {
    return this.wrap('completeStep', stage, (): LeaseWrite => {
      const job = this.leaseOk(lease);
      if (!job) return { ok: false, reason: 'lease_lost' };
      if (job.started !== stage || DELETION_STAGES[job.completed.length] !== stage) {
        return { ok: false, reason: 'out_of_order' };
      }
      job.completed.push(stage);
      job.started = null;
      if (stage === 'apple_revoke') job.ref = null; // temporary material destroyed with the step
      return { ok: true };
    });
  }

  recordFailure(
    lease: Lease,
    f: { stage: DeletionStage; code: ErrorCode; retryable: boolean; retryDelayMs: number },
  ): Promise<LeaseWrite> {
    return this.wrap('recordFailure', f.stage, (): LeaseWrite => {
      const job = this.leaseOk(lease);
      if (!job) return { ok: false, reason: 'lease_lost' };
      job.attempts += 1;
      job.lastCode = f.code;
      job.state = f.retryable ? 'retryable' : 'failed';
      job.notBefore = this.clock() + f.retryDelayMs;
      job.token = null;
      job.leaseUntil = 0;
      job.started = null;
      return { ok: true };
    });
  }

  completeJob(lease: Lease, retentionMs: number): Promise<LeaseWrite> {
    return this.wrap('completeJob', undefined, (): LeaseWrite => {
      const job = this.leaseOk(lease);
      if (!job) return { ok: false, reason: 'lease_lost' };
      if (job.completed.length !== DELETION_STAGES.length) return { ok: false, reason: 'incomplete_steps' };
      job.state = 'completed';
      job.token = null;
      job.leaseUntil = 0;
      for (const r of this.receipts.values()) {
        if (r.jobId === job.jobId) r.expiresAtMs = this.clock() + retentionMs;
      }
      return { ok: true };
    });
  }

  getReceipt(receiptHash: string): Promise<ReceiptRecord | null> {
    return this.wrap('getReceipt', undefined, () => {
      const r = this.receipts.get(receiptHash);
      if (!r) return null;
      const state = this.jobs.get(r.jobId)!.state;
      if (state !== 'completed') return { state }; // never expires while non-terminal
      if (r.expiresAtMs === null || this.clock() >= r.expiresAtMs) {
        this.receipts.delete(receiptHash);
        return null;
      }
      return { state: 'completed', retainedUntilMs: r.expiresAtMs };
    });
  }

  job(uid: string): MemJob {
    return this.jobs.get(this.uidJob.get(uid)!)!;
  }

  /** Everything persisted, for leak assertions. */
  dump(): string {
    return JSON.stringify({
      jobs: [...this.jobs.values()],
      scopes: [...this.scopes.entries()],
      receipts: [...this.receipts.entries()],
    });
  }
}

// ── fakes for the other ports ────────────────────────────────────────────────

type UserRows = { profile: boolean; syncState: boolean; objects: string[]; auth: boolean };
class World {
  users = new Map<string, UserRows>();
  scheduled = new Map<string, number>(); // existing 30-day schedules: must never change
  revokedRefs: string[] = [];
  addUser(uid: string, scheduledAt?: number) {
    this.users.set(uid, { profile: true, syncState: true, objects: [`${uid}/backup.enc`], auth: true });
    if (scheduledAt !== undefined) this.scheduled.set(uid, scheduledAt);
  }
  snapshot(uid: string) {
    return JSON.stringify(this.users.get(uid));
  }
}

type Key = DeletionStage;
class FakeSteps implements DeletionSteps {
  trace: Key[] = [];
  uidCalls: string[] = [];
  counts: Record<Key, number> = {
    apple_revoke: 0,
    storage_sweep: 0,
    sql_purge: 0,
    auth_delete: 0,
    terminal_storage: 0,
  };
  // An override returning undefined falls through to the default behaviour.
  overrides: Partial<Record<Key, (n: number) => Promise<unknown> | unknown>> = {};
  // One-shot gate awaited AFTER the side effect was applied (a dispatched call).
  gates: Partial<Record<Key, Deferred>> = {};

  constructor(private world: World) {}

  private async run<T>(key: Key, uid: string | null, effect: () => T): Promise<T> {
    this.trace.push(key);
    this.uidCalls.push(`${key}:${uid ?? 'ref'}`);
    const n = ++this.counts[key];
    const override = this.overrides[key];
    if (override) {
      const out = await override(n);
      if (out !== undefined) return out as T;
    }
    const result = effect();
    const gate = this.gates[key];
    if (gate) {
      delete this.gates[key];
      await gate.promise;
    }
    return result;
  }

  revokeApple(ref: string): Promise<AppleRevokeOutcome> {
    return this.run('apple_revoke', null, (): AppleRevokeOutcome => {
      this.world.revokedRefs.push(ref);
      return { status: 'revoked_verified' };
    });
  }
  sweepStorage(uid: string, phase: 'pre_sql' | 'terminal'): Promise<StorageOutcome> {
    return this.run(phase === 'terminal' ? 'terminal_storage' : 'storage_sweep', uid, (): StorageOutcome => {
      const u = this.world.users.get(uid);
      if (u) u.objects = [];
      return { status: 'empty_verified' };
    });
  }
  purgeSql(uid: string): Promise<StepOutcome> {
    return this.run('sql_purge', uid, (): StepOutcome => {
      const u = this.world.users.get(uid);
      if (u) {
        u.profile = false;
        u.syncState = false;
      }
      return { status: 'done' };
    });
  }
  deleteAuthUser(uid: string): Promise<AuthDeleteOutcome> {
    return this.run('auth_delete', uid, (): AuthDeleteOutcome => {
      const u = this.world.users.get(uid);
      if (u?.auth) {
        u.auth = false;
        return { status: 'deleted' };
      }
      return { status: 'absent_confirmed' };
    });
  }
}

class FakeAuthorizer implements DeletionAuthorizer {
  tokens = new Map<string, string>();
  challenges = new Map<string, { expiresAtMs: number; subjectOk: boolean }>(); // key `${uid}:${id}`
  spent = new Set<string>();
  singleUse = true;
  verifyCalls = 0;
  authorizeCalls: Array<Record<string, unknown>> = [];
  gate: Deferred | null = null;
  override: (() => unknown) | null = null;
  discarded: string[] = []; // refs whose material was actually destroyed
  dispositions: string[] = []; // every answer, as `${ref}:${status}`
  discardThrows = false;
  disposeOverride: (() => unknown) | null = null;
  disposeGate: Deferred | null = null; // one-shot: pauses a disposal request before it reaches the registry
  disposeStarted: Deferred | null = null;
  // 'unique': every exchange yields new material (the original fixture).
  // 'by_challenge' / 'by_uid': an IDEMPOTENT authorizer that returns the SAME reference
  // again for the same challenge / account. The coordinator must not assume otherwise.
  refMode: 'unique' | 'by_challenge' | 'by_uid' = 'unique';
  identityOverride: (() => unknown) | null = null;
  private refCount = new Map<string, number>();

  constructor(private clock: () => number, readonly vault: MaterialVault = new MaterialVault()) {}

  async disposeIfUnreferenced(ref: string): Promise<MaterialDisposition> {
    const gate = this.disposeGate;
    if (gate) {
      this.disposeGate = null;
      this.disposeStarted?.resolve();
      await gate.promise;
    }
    if (this.discardThrows) throw new Error('discard failed SECRET-PROVIDER-TEXT');
    if (this.disposeOverride) return this.disposeOverride() as MaterialDisposition;
    const out = this.vault.dispose(ref);
    this.dispositions.push(`${ref}:${out.status}`);
    if (out.status === 'disposed') this.discarded.push(ref);
    return out;
  }

  verifyIdentity(token: string): Promise<IdentityResult> {
    this.verifyCalls++;
    if (this.identityOverride) return Promise.resolve(this.identityOverride() as IdentityResult);
    const uid = this.tokens.get(token);
    return Promise.resolve(uid ? { ok: true, uid } : { ok: false });
  }

  private arrivalWaiters: { count: number; resolve: () => void }[] = [];

  /** Resolves once `count` authorize calls have registered; rejects clearly after `timeoutMs`. */
  async waitForAuthorizeCalls(count: number, timeoutMs = 2_000): Promise<void> {
    if (this.authorizeCalls.length >= count) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const arrived = new Promise<void>((resolve) => this.arrivalWaiters.push({ count, resolve }));
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(
        () => reject(new Error(`timed out: only ${this.authorizeCalls.length} of ${count} authorize calls arrived`)),
        timeoutMs,
      );
    });
    try {
      await Promise.race([arrived, timeout]);
    } finally {
      clearTimeout(timer);
    }
  }

  async authorizeDeletion(input: { uid: string; challengeId: string; challengeResponse: string }) {
    this.authorizeCalls.push({ ...input });
    this.arrivalWaiters = this.arrivalWaiters.filter((w) => {
      if (this.authorizeCalls.length < w.count) return true;
      w.resolve();
      return false;
    });
    if (this.gate) await this.gate.promise;
    if (this.override) return this.override() as AuthorizationResult;
    const key = `${input.uid}:${input.challengeId}`;
    const c = this.challenges.get(key);
    if (!c) return { ok: false, code: 'challenge_invalid' } as const;
    if (c.expiresAtMs <= this.clock()) return { ok: false, code: 'challenge_expired' } as const;
    if (this.singleUse && this.spent.has(key)) return { ok: false, code: 'challenge_replayed' } as const;
    if (!c.subjectOk) return { ok: false, code: 'apple_subject_mismatch' } as const;
    let ref: string;
    if (this.refMode === 'unique') {
      // Each real exchange yields distinct material; the first keeps its plain name.
      const n = (this.refCount.get(key) ?? 0) + 1;
      this.refCount.set(key, n);
      ref = n === 1 ? `enc:ref-${input.challengeId}` : `enc:ref-${input.challengeId}-dup${n}`;
    } else if (this.refMode === 'by_challenge') {
      ref = `enc:ref-${input.challengeId}`;
      // The one-use code is spent: destroyed material cannot be re-created for this challenge.
      if (this.vault.destroyed.has(ref)) return { ok: false, code: 'challenge_replayed' } as const;
    } else {
      ref = `enc:ref-acct-${input.uid.slice(0, 8)}`; // a new exchange may re-create it
    }
    this.spent.add(key);
    this.vault.issue(ref);
    return {
      ok: true,
      verified: true,
      appleSubjectMatched: true,
      challengeExpiresAtMs: c.expiresAtMs,
      appleMaterialRef: ref,
    } as const;
  }
}

function setup(options: CoordinatorOptions = OPTIONS, logImpl?: (e: LogEvent) => unknown) {
  const clock = { t: 1_000_000, advance(ms: number) { this.t += ms; } };
  const now = () => clock.t;
  const world = new World();
  const vault = new MaterialVault();
  const store = new MemStore(now, vault);
  const steps = new FakeSteps(world);
  const authz = new FakeAuthorizer(now, vault);
  const logs: LogEvent[] = [];
  const config: { missing: ConfigKey[]; impl?: () => unknown } = { missing: [] };
  const readiness = (): ConfigReadiness => {
    if (config.impl) return config.impl() as ConfigReadiness;
    return config.missing.length ? { ok: false, missing: config.missing } : { ok: true };
  };
  const coord = createAccountDeletionCoordinator({
    authorizer: authz,
    store,
    steps,
    readiness,
    log: logImpl ? (e) => { logs.push(e); return logImpl(e) as void; } : (e) => { logs.push(e); },
    options,
  });

  const secrets = new Map<string, string>();
  function addUser(uid: string, scheduledAt?: number) {
    world.addUser(uid, scheduledAt);
    authz.tokens.set(`token-${uid}`, uid);
  }
  /** Issues a fresh challenge for uid and returns the matching request. */
  function issue(uid: string, n = 1, extra: { subjectOk?: boolean; ttlMs?: number; id?: string } = {}) {
    const id = extra.id ?? `challenge-${n}-${uid.slice(0, 4)}`;
    authz.challenges.set(`${uid}:${id}`, {
      expiresAtMs: clock.t + (extra.ttlMs ?? 5 * 60_000),
      subjectOk: extra.subjectOk ?? true,
    });
    const secret = `receipt${n}${uid.slice(0, 4)}`.padEnd(48, 'x');
    secrets.set(`${uid}:${n}`, secret);
    const req: DeletionRequest = {
      bearerToken: `token-${uid}`,
      challengeId: id,
      challengeResponse: 'APPLE-CODE-PLAINTEXT-SENTINEL',
      receiptSecret: secret,
    };
    return req;
  }
  async function accept(uid: string, n = 1) {
    const result = await coord.requestDeletion(issue(uid, n));
    assertEquals(result.status, 'accepted');
    if (result.status !== 'accepted') throw new Error('unreachable');
    return result;
  }
  const secretOf = (uid: string, n = 1) => secrets.get(`${uid}:${n}`)!;
  return { clock, world, store, vault, steps, authz, logs, config, coord, addUser, issue, accept, secretOf };
}

function monotonic(trace: Key[]) {
  const idx = trace.map((k) => DELETION_STAGES.indexOf(k));
  for (let i = 1; i < idx.length; i++) assert(idx[i] >= idx[i - 1], `out-of-order step trace: ${trace.join(',')}`);
}

// ── authorization and acceptance ─────────────────────────────────────────────

Deno.test('anonymous or unresolvable identity is rejected before any other port is touched', async () => {
  const h = setup();
  h.addUser(UID_A);
  const empty = await h.coord.requestDeletion({ ...h.issue(UID_A), bearerToken: '   ' });
  assertEquals(empty, { status: 'error', code: 'unauthenticated', retryable: false });
  const unknown = await h.coord.requestDeletion({ ...h.issue(UID_A, 2), bearerToken: 'not-a-token' });
  assertEquals(unknown, { status: 'error', code: 'unauthenticated', retryable: false });
  assertEquals(h.authz.verifyCalls, 1); // the blank token never reached the adapter
  assertEquals(h.authz.authorizeCalls.length, 0);
  assertEquals(h.store.jobs.size, 0);
  assertEquals(h.store.frozen.size, 0);
});

Deno.test('a client-supplied uid/email/target is never read or forwarded', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.addUser(UID_B);
  const forged = { ...h.issue(UID_A), uid: UID_B, userId: UID_B, email: 'victim@example.test', target: UID_B };
  const result = await h.coord.requestDeletion(forged as unknown as DeletionRequest);
  assertEquals(result.status, 'accepted');
  assertEquals([...h.store.frozen], [UID_A]);
  assertEquals(h.authz.authorizeCalls.length, 1);
  assertEquals(Object.keys(h.authz.authorizeCalls[0]).sort(), ['challengeId', 'challengeResponse', 'uid']);
  assertEquals(h.authz.authorizeCalls[0].uid, UID_A);
  assertFalse(h.store.dump().includes('victim@example.test'));
});

Deno.test('a challenge issued to another account is refused and nothing is frozen', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.addUser(UID_B);
  const bReq = h.issue(UID_B);
  // A's valid token presenting B's challenge id.
  const foreign = await h.coord.requestDeletion({ ...bReq, bearerToken: `token-${UID_A}` });
  assertEquals(foreign, { status: 'error', code: 'challenge_invalid', retryable: false });
  assertEquals(h.store.jobs.size, 0);
  assertEquals(h.store.frozen.size, 0);
  assertEquals(h.world.users.get(UID_B)!.auth, true);
});

Deno.test('unknown, expired and replayed challenges and a wrong Apple subject all fail without persisting', async () => {
  const h = setup();
  h.addUser(UID_A);
  const unknown = await h.coord.requestDeletion({ ...h.issue(UID_A), challengeId: 'no-such-challenge' });
  assertEquals(unknown, { status: 'error', code: 'challenge_invalid', retryable: false });

  const expiring = h.issue(UID_A, 2, { ttlMs: 1_000 });
  h.clock.advance(2_000);
  assertEquals(await h.coord.requestDeletion(expiring), { status: 'error', code: 'challenge_expired', retryable: false });

  const mismatch = h.issue(UID_A, 3, { subjectOk: false });
  assertEquals(await h.coord.requestDeletion(mismatch), {
    status: 'error',
    code: 'apple_subject_mismatch',
    retryable: false,
  });

  // Spent by the adapter but the store write failed: the replay is refused.
  const spentReq = h.issue(UID_A, 4);
  h.store.failNextAccept = true;
  assertEquals(await h.coord.requestDeletion(spentReq), { status: 'error', code: 'store_unavailable', retryable: true });
  assertEquals(await h.coord.requestDeletion(spentReq), { status: 'error', code: 'challenge_replayed', retryable: false });

  assertEquals(h.store.jobs.size, 0);
  assertEquals(h.store.frozen.size, 0);
  assertEquals(h.store.receipts.size, 0);
});

Deno.test('a challenge that expires between authorization and the atomic accept is refused by the store', async () => {
  const h = setup();
  h.addUser(UID_A);
  const req = h.issue(UID_A, 1, { ttlMs: 5_000 });
  h.authz.gate = deferred();
  const pending = h.coord.requestDeletion(req);
  await tick();
  h.clock.advance(6_000);
  h.authz.gate.resolve();
  h.authz.override = () => ({
    ok: true,
    verified: true,
    appleSubjectMatched: true,
    challengeExpiresAtMs: h.clock.t - 1_000,
    appleMaterialRef: 'enc:ref-late-case',
  });
  assertEquals(await pending, { status: 'error', code: 'challenge_expired', retryable: false });
  assertEquals(h.store.jobs.size, 0);
  assertEquals(h.store.frozen.size, 0);
});

Deno.test('missing configuration fails closed at request time with nothing persisted or attempted', async () => {
  const keys: ConfigKey[] = [
    'intent_verification',
    'apple_signing',
    'token_encryption',
    'database',
    'storage_admin',
    'auth_admin',
  ];
  for (const key of keys) {
    const h = setup();
    h.addUser(UID_A);
    h.config.missing = [key];
    const r = await h.coord.requestDeletion(h.issue(UID_A));
    assertEquals(r, { status: 'error', code: 'not_configured', retryable: false }, key);
    assertEquals(h.authz.verifyCalls, 0, key);
    assertEquals(h.store.jobs.size, 0, key);
    assertEquals(h.steps.trace.length, 0, key);
  }
});

Deno.test('configuration lost after acceptance stops before any side effect and resumes once restored', async () => {
  const h = setup();
  h.addUser(UID_A);
  const { jobId } = await h.accept(UID_A);
  h.config.missing = ['apple_signing'];
  assertEquals(await h.coord.processJob(jobId, 'w1'), {
    outcome: 'retry_scheduled',
    stage: 'apple_revoke',
    code: 'not_configured',
  });
  assertEquals(h.steps.trace.length, 0);
  h.config.missing = [];
  h.clock.advance(LATE);
  assertEquals(await h.coord.processNext('w1'), { outcome: 'completed' });
});

Deno.test('a success the adapter did not positively assert, or a plaintext-looking token reference, is never accepted', async () => {
  const bad: unknown[] = [
    { ok: true, challengeExpiresAtMs: 9e15, appleMaterialRef: 'enc:ref-aaaaaaaa' }, // no verified flags
    { ok: true, verified: true, appleSubjectMatched: false, challengeExpiresAtMs: 9e15, appleMaterialRef: 'enc:ref-aaaaaaaa' },
    { ok: true, verified: true, appleSubjectMatched: true, challengeExpiresAtMs: 9e15, appleMaterialRef: 'eyJhbGciOiJSUzI1NiJ9.payload.sig' },
    { ok: true, verified: true, appleSubjectMatched: true, challengeExpiresAtMs: NaN, appleMaterialRef: 'enc:ref-aaaaaaaa' },
    { ok: false, code: 'something_unlisted' },
    undefined,
  ];
  for (const value of bad) {
    const h = setup();
    h.addUser(UID_A);
    h.authz.override = () => value;
    const r = await h.coord.requestDeletion(h.issue(UID_A));
    assertEquals(r.status, 'error');
    assertEquals(h.store.jobs.size, 0);
    assertEquals(h.store.frozen.size, 0);
  }
});

Deno.test('adapter and store exceptions fail closed with enumerated codes and no provider text', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.authz.override = () => {
    throw new Error(`apple said: SECRET-PROVIDER-TEXT for ${UID_A}`);
  };
  const r = await h.coord.requestDeletion(h.issue(UID_A));
  assertEquals(r, { status: 'error', code: 'authorization_unavailable', retryable: true });
  assertFalse(JSON.stringify(r).includes('SECRET-PROVIDER-TEXT'));
  assertEquals(h.store.jobs.size, 0);
});

Deno.test('acceptance records freeze, queue, encrypted material reference and hashed receipt together, and a failed accept leaves nothing', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.store.failNextAccept = true;
  const failed = await h.coord.requestDeletion(h.issue(UID_A));
  assertEquals(failed, { status: 'error', code: 'store_unavailable', retryable: true });
  assertEquals([h.store.jobs.size, h.store.frozen.size, h.store.receipts.size, h.store.scopes.size], [0, 0, 0, 0]);

  const r = await h.accept(UID_A, 2);
  const job = h.store.jobs.get(r.jobId)!;
  assert(h.store.frozen.has(UID_A));
  assertEquals(job.state, 'accepted');
  assertEquals(job.ref, 'enc:ref-challenge-2-aaaa');
  assertEquals(h.store.receipts.size, 1);
  // Only the hash of the capability is stored, never the secret or any credential.
  const dump = h.store.dump();
  assertFalse(dump.includes(h.secretOf(UID_A, 2)));
  assertFalse(dump.includes('APPLE-CODE-PLAINTEXT-SENTINEL'));
  assertFalse(dump.includes(`token-${UID_A}`));
});

Deno.test('a repeated request is an idempotent duplicate that does not repeat the one-use Apple exchange', async () => {
  const h = setup();
  h.addUser(UID_A);
  const req = h.issue(UID_A);
  const first = await h.coord.requestDeletion(req);
  const second = await h.coord.requestDeletion(req);
  assertEquals(first.status === 'accepted' && first.duplicate, false);
  assertEquals(second.status === 'accepted' && second.duplicate, true);
  assertEquals(h.authz.authorizeCalls.length, 1);
  assertEquals(h.store.jobs.size, 1);
  // Same challenge with a different receipt capability is a conflict, not a second job.
  const conflict = await h.coord.requestDeletion({ ...req, receiptSecret: 'z'.repeat(48) });
  assertEquals(conflict, { status: 'error', code: 'idempotency_conflict', retryable: false });
});

Deno.test('a fresh challenge for an already-pending UID attaches to the same job instead of creating another', async () => {
  const h = setup();
  h.addUser(UID_A);
  const first = await h.accept(UID_A, 1);
  const second = await h.accept(UID_A, 2);
  assertEquals(second.duplicate, true);
  assertEquals(second.jobId, first.jobId);
  assertEquals(h.store.jobs.size, 1);
  assertEquals((await h.coord.getStatus(h.secretOf(UID_A, 1))).status, 'accepted');
  assertEquals((await h.coord.getStatus(h.secretOf(UID_A, 2))).status, 'accepted');
});

Deno.test('simultaneous identical requests yield exactly one accepted job', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.authz.singleUse = false; // both pass the adapter; the store arbitrates
  const req = h.issue(UID_A);
  h.authz.gate = deferred();
  const p1 = h.coord.requestDeletion(req);
  const p2 = h.coord.requestDeletion(req);
  try {
    // Deterministic arrival barrier instead of a single timer tick (load-dependent flake).
    await h.authz.waitForAuthorizeCalls(2);
  } catch (e) {
    h.authz.gate.resolve(); // failure cleanup: release and drain outstanding requests
    await Promise.allSettled([p1, p2]);
    throw e;
  }
  assertEquals(h.authz.authorizeCalls.length, 2);
  h.authz.gate.resolve();
  const [r1, r2] = await Promise.all([p1, p2]);
  assert(r1.status === 'accepted' && r2.status === 'accepted');
  assertEquals([r1.duplicate, r2.duplicate].sort(), [false, true]);
  assertEquals(r1.jobId, r2.jobId);
  assertEquals(h.store.jobs.size, 1);
  assertEquals(h.store.receipts.size, 1);
});

Deno.test('the arrival barrier fails clearly when the second authorization never arrives, and cleanup settles the outstanding request', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.authz.gate = deferred();
  const p1 = h.coord.requestDeletion(h.issue(UID_A));
  let message = '';
  try {
    await h.authz.waitForAuthorizeCalls(2, 50);
  } catch (e) {
    message = (e as Error).message;
    h.authz.gate.resolve(); // same failure cleanup as the race schedules
    const settled = await Promise.allSettled([p1]);
    assertEquals(settled[0].status, 'fulfilled');
  }
  assert(message.includes('timed out: only 1 of 2'), message);
  assertEquals(h.authz.authorizeCalls.length, 1);
});

Deno.test('idempotency is scoped to the verified UID, so an identical challenge id for another UID is independent', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.addUser(UID_B);
  const a = await h.coord.requestDeletion(h.issue(UID_A, 1, { id: 'shared-challenge-id' }));
  const b = await h.coord.requestDeletion(h.issue(UID_B, 1, { id: 'shared-challenge-id' }));
  assert(a.status === 'accepted' && b.status === 'accepted');
  assertEquals([a.duplicate, b.duplicate], [false, false]);
  assertEquals(h.store.jobs.size, 2);
  assert(a.jobId !== b.jobId);
});

Deno.test('a malformed request is rejected before any adapter is called', async () => {
  const h = setup();
  h.addUser(UID_A);
  const base = h.issue(UID_A);
  for (const bad of [{ receiptSecret: 'short' }, { challengeId: 'x' }, { challengeResponse: '' }]) {
    assertEquals(await h.coord.requestDeletion({ ...base, ...bad }), {
      status: 'error',
      code: 'invalid_request',
      retryable: false,
    });
  }
  assertEquals(h.authz.verifyCalls, 0);
});

// ── saga ─────────────────────────────────────────────────────────────────────

Deno.test('the full saga runs in order, records every step, destroys Apple material, and completes the receipt', async () => {
  const h = setup();
  h.addUser(UID_A, 777);
  h.addUser(UID_C, 888); // never requests deletion; holds an existing 30-day schedule
  const { jobId } = await h.accept(UID_A);
  const before = h.world.snapshot(UID_C);
  assertEquals((await h.coord.getStatus(h.secretOf(UID_A))).status, 'accepted');

  assertEquals(await h.coord.processJob(jobId, 'request'), { outcome: 'completed' });

  assertEquals(h.steps.trace, [...DELETION_STAGES]);
  const job = h.store.job(UID_A);
  assertEquals(job.completed, [...DELETION_STAGES]);
  assertEquals(job.state, 'completed');
  assertEquals(job.ref, null); // temporary material gone only after verified revocation
  assert(h.store.frozen.has(UID_A)); // the freeze is never cleared
  assertEquals(h.world.users.get(UID_A)!.auth, false);
  const status = await h.coord.getStatus(h.secretOf(UID_A));
  assertEquals(status.status, 'completed');

  // Unrelated UID: never frozen, never touched, schedule unchanged.
  assertFalse(h.store.frozen.has(UID_C));
  assertEquals(h.world.snapshot(UID_C), before);
  assertEquals(h.world.scheduled.get(UID_C), 888);
  assertFalse(h.steps.uidCalls.some((c) => c.endsWith(UID_C)));
});

Deno.test('queue disappearance is not success: a completed receipt requires every step, and a status of pending persists while any is open', async () => {
  const h = setup();
  h.addUser(UID_A);
  await h.accept(UID_A);
  h.steps.overrides.sql_purge = () => ({ status: 'retryable' });
  await h.coord.processNext('w');
  assertEquals((await h.coord.getStatus(h.secretOf(UID_A))).status, 'pending');
  // The store itself refuses to complete a job whose steps are not all recorded.
  const grant = await h.store.claimLease({ workerId: 'x', leaseMs: LEASE_MS, jobId: 'job-1' });
  assertEquals(grant, null); // still inside the retry back-off
  h.clock.advance(LATE);
  const g2 = (await h.store.claimLease({ workerId: 'x', leaseMs: LEASE_MS, jobId: 'job-1' }))!;
  assertEquals(await h.store.completeJob(g2.lease, 1000), { ok: false, reason: 'incomplete_steps' });
  assertEquals(await h.store.beginStep(g2.lease, 'auth_delete'), { ok: false, reason: 'out_of_order' });
});

const FAILURES: Array<{ stage: DeletionStage; outcome: unknown; code: ErrorCode }> = [
  { stage: 'apple_revoke', outcome: { status: 'retryable' }, code: 'apple_revoke_retryable' },
  { stage: 'storage_sweep', outcome: { status: 'incomplete' }, code: 'storage_incomplete' },
  { stage: 'storage_sweep', outcome: { status: 'retryable' }, code: 'storage_error' },
  { stage: 'sql_purge', outcome: { status: 'retryable' }, code: 'sql_purge_error' },
  { stage: 'auth_delete', outcome: { status: 'retryable' }, code: 'auth_delete_error' },
  { stage: 'auth_delete', outcome: { status: 'ambiguous' }, code: 'auth_delete_ambiguous' },
  { stage: 'terminal_storage', outcome: { status: 'incomplete' }, code: 'terminal_storage_incomplete' },
  { stage: 'terminal_storage', outcome: { status: 'retryable' }, code: 'terminal_storage_error' },
];

for (const f of FAILURES) {
  Deno.test(`failure at ${f.stage} (${f.code}) stops later stages, stays pending, and converges on retry`, async () => {
    const h = setup();
    h.addUser(UID_A);
    await h.accept(UID_A);
    h.steps.overrides[f.stage] = (n) => (n === 1 ? f.outcome : undefined);

    assertEquals(await h.coord.processNext('w'), { outcome: 'retry_scheduled', stage: f.stage, code: f.code });
    const stageIdx = DELETION_STAGES.indexOf(f.stage);
    // Nothing after the failed stage ran; in particular no Auth delete before the
    // earlier destructive stages succeeded.
    assertEquals(h.steps.trace, DELETION_STAGES.slice(0, stageIdx + 1));
    if (stageIdx < DELETION_STAGES.indexOf('auth_delete')) {
      assertEquals(h.world.users.get(UID_A)!.auth, true);
    }
    const job = h.store.job(UID_A);
    assertEquals(job.state, 'retryable');
    assertEquals(job.lastCode, f.code);
    assertEquals(job.completed, DELETION_STAGES.slice(0, stageIdx));
    assertEquals((await h.coord.getStatus(h.secretOf(UID_A))).status, 'pending');

    // Back-off is honoured, then the job resumes and completes.
    assertEquals(await h.coord.processNext('w'), { outcome: 'no_work' });
    h.clock.advance(LATE);
    assertEquals(await h.coord.processNext('w'), { outcome: 'completed' });
    assertEquals((await h.coord.getStatus(h.secretOf(UID_A))).status, 'completed');
    monotonic(h.steps.trace);
  });
}

Deno.test('a permanent Apple rejection stops everything, is not auto-claimed, and never reports completion', async () => {
  const h = setup();
  h.addUser(UID_A);
  await h.accept(UID_A);
  h.steps.overrides.apple_revoke = () => ({ status: 'failed' });
  assertEquals(await h.coord.processNext('w'), { outcome: 'failed', stage: 'apple_revoke', code: 'apple_revoke_rejected' });
  h.clock.advance(LATE);
  assertEquals(await h.coord.processNext('w'), { outcome: 'no_work' });
  assertEquals(h.steps.trace, ['apple_revoke']);
  assertEquals((await h.coord.getStatus(h.secretOf(UID_A))).status, 'pending');
  assert(h.store.frozen.has(UID_A));
});

Deno.test('an ambiguous Auth 404 is never success and terminal verification waits for a confirmed outcome', async () => {
  const h = setup();
  h.addUser(UID_A);
  await h.accept(UID_A);
  h.steps.overrides.auth_delete = (n) => (n === 1 ? { status: 'ambiguous' } : { status: 'absent_confirmed' });
  assertEquals((await h.coord.processNext('w')).outcome, 'retry_scheduled');
  assertFalse(h.steps.trace.includes('terminal_storage'));
  assertEquals((await h.coord.getStatus(h.secretOf(UID_A))).status, 'pending');
  h.clock.advance(LATE);
  assertEquals(await h.coord.processNext('w'), { outcome: 'completed' });
});

Deno.test('an incomplete terminal sweep keeps the receipt pending and does not repeat earlier steps', async () => {
  const h = setup();
  h.addUser(UID_A);
  await h.accept(UID_A);
  h.steps.overrides.terminal_storage = (n) => (n === 1 ? { status: 'incomplete' } : undefined);
  await h.coord.processNext('w');
  assertEquals((await h.coord.getStatus(h.secretOf(UID_A))).status, 'pending');
  h.clock.advance(LATE);
  await h.coord.processNext('w');
  assertEquals((await h.coord.getStatus(h.secretOf(UID_A))).status, 'completed');
  assertEquals(
    [h.steps.counts.apple_revoke, h.steps.counts.sql_purge, h.steps.counts.auth_delete, h.steps.counts.terminal_storage],
    [1, 1, 1, 2],
  );
});

// ── crash recovery ───────────────────────────────────────────────────────────

type CrashCase = { name: string; fault: FaultPoint };
const CRASH_CASES: CrashCase[] = [];
for (const stage of DELETION_STAGES) {
  CRASH_CASES.push(
    { name: `${stage}: before begin recorded`, fault: { op: 'beginStep', when: 'before', stage } },
    { name: `${stage}: after begin recorded, before side effect`, fault: { op: 'beginStep', when: 'after', stage } },
    { name: `${stage}: after side effect, before completion recorded`, fault: { op: 'completeStep', when: 'before', stage } },
    { name: `${stage}: after completion recorded`, fault: { op: 'completeStep', when: 'after', stage } },
  );
}
CRASH_CASES.push(
  { name: 'job: before completion recorded', fault: { op: 'completeJob', when: 'before' } },
  { name: 'job: after completion recorded', fault: { op: 'completeJob', when: 'after' } },
);

for (const c of CRASH_CASES) {
  Deno.test(`crash ${c.name} converges after the lease expires, safely repeating at most one step`, async () => {
    const h = setup();
    h.addUser(UID_A);
    h.addUser(UID_C);
    await h.accept(UID_A);
    h.store.fault = c.fault;

    assertEquals(await h.coord.processNext('w1'), { outcome: 'aborted' });
    assertEquals((await h.coord.getStatus(h.secretOf(UID_A))).status === 'completed', c.fault.op === 'completeJob' && c.fault.when === 'after');

    // The crashed worker still holds an unexpired lease: nobody may overlap it.
    assertEquals(await h.coord.processNext('w2'), { outcome: 'no_work' });

    h.clock.advance(LEASE_MS + 1);
    const resumed = await h.coord.processNext('w2');
    assert(
      resumed.outcome === 'completed' || (resumed.outcome === 'no_work' && h.store.job(UID_A).state === 'completed'),
      JSON.stringify(resumed),
    );

    assertEquals((await h.coord.getStatus(h.secretOf(UID_A))).status, 'completed');
    assertEquals(h.store.job(UID_A).completed, [...DELETION_STAGES]);
    monotonic(h.steps.trace);
    for (const stage of DELETION_STAGES) assert(h.steps.counts[stage] <= 2, `${stage} repeated too often`);
    assert(h.steps.counts.apple_revoke >= 1 && h.steps.counts.auth_delete >= 1);
    assertEquals(h.world.users.get(UID_A)!.auth, false);
    assertEquals(h.world.users.get(UID_C)!.auth, true);
    assertFalse(h.store.frozen.has(UID_C));
  });
}

// ── leases ───────────────────────────────────────────────────────────────────

Deno.test('a replaced worker cannot record a step, complete the job, or complete the receipt', async () => {
  const h = setup();
  h.addUser(UID_A);
  const { jobId } = await h.accept(UID_A);
  const gate = deferred();
  h.steps.gates.apple_revoke = gate; // worker A's Apple call is dispatched, then stalls

  const workerA = h.coord.processJob(jobId, 'A');
  await tick();
  assertEquals(h.steps.counts.apple_revoke, 1);

  h.clock.advance(LEASE_MS + 1); // A's lease expires
  assertEquals(await h.coord.processNext('B'), { outcome: 'completed' });
  const doneState = JSON.stringify(h.store.job(UID_A));
  assertEquals(h.store.job(UID_A).generation, 2);

  gate.resolve();
  assertEquals(await workerA, { outcome: 'lease_lost' });
  // A's late write changed nothing, and it never ran a later stage itself.
  assertEquals(JSON.stringify(h.store.job(UID_A)), doneState);
  assertEquals(h.store.job(UID_A).completed, [...DELETION_STAGES]);
  assertEquals(h.steps.counts.apple_revoke, 2); // the dispatched call is repeated, not "cancelled"
  assertEquals(h.steps.counts.storage_sweep, 1);
  assertEquals(h.steps.counts.auth_delete, 1);
  assertEquals((await h.coord.getStatus(h.secretOf(UID_A))).status, 'completed');
});

Deno.test('a replaced worker cannot record a late failure over the new holder', async () => {
  const h = setup();
  h.addUser(UID_A);
  const { jobId } = await h.accept(UID_A);
  const gate = deferred();
  h.steps.overrides.apple_revoke = async (n) => {
    if (n !== 1) return undefined;
    await gate.promise;
    return { status: 'retryable' };
  };
  const workerA = h.coord.processJob(jobId, 'A');
  await tick();
  h.clock.advance(LEASE_MS + 1);
  assertEquals(await h.coord.processNext('B'), { outcome: 'completed' });
  gate.resolve();
  assertEquals(await workerA, { outcome: 'lease_lost' });
  assertEquals(h.store.job(UID_A).lastCode, null);
  assertEquals(h.store.job(UID_A).state, 'completed');
  assertEquals(h.store.job(UID_A).attempts, 0);
});

Deno.test('an expired but unreplaced lease still writes nothing; the step is repeated, not assumed done', async () => {
  const h = setup();
  h.addUser(UID_A);
  const { jobId } = await h.accept(UID_A);
  const gate = deferred();
  h.steps.gates.sql_purge = gate;
  const worker = h.coord.processJob(jobId, 'A');
  await tick();
  h.clock.advance(LEASE_MS + 1);
  gate.resolve();
  assertEquals(await worker, { outcome: 'lease_lost' });
  assertEquals(h.store.job(UID_A).completed, ['apple_revoke', 'storage_sweep']);
  assertEquals(await h.coord.processNext('B'), { outcome: 'completed' });
  assertEquals(h.steps.counts.sql_purge, 2);
});

Deno.test('a simultaneous request-path run and worker run never overlap', async () => {
  const h = setup();
  h.addUser(UID_A);
  const { jobId } = await h.accept(UID_A);
  const gate = deferred();
  h.steps.gates.apple_revoke = gate;
  const request = h.coord.processJob(jobId, 'request');
  await tick();
  assertEquals(await h.coord.processNext('worker'), { outcome: 'no_work' });
  gate.resolve();
  assertEquals(await request, { outcome: 'completed' });
  assertEquals(h.steps.trace, [...DELETION_STAGES]);
  assertEquals(h.store.job(UID_A).generation, 1);
});

// ── receipt ──────────────────────────────────────────────────────────────────

Deno.test('a lost response is recoverable by the client-held capability, and the capability alone', async () => {
  const h = setup();
  h.addUser(UID_A);
  await h.accept(UID_A); // response "lost": only the secret the client generated survives
  const secret = h.secretOf(UID_A);
  assertEquals((await h.coord.getStatus(secret)).status, 'accepted');
  await h.coord.processNext('w');
  assertEquals((await h.coord.getStatus(secret)).status, 'completed');
  const unknown = await h.coord.getStatus('q'.repeat(48));
  assertEquals(unknown, { status: 'unknown' });
  assertEquals(await h.coord.getStatus('too-short'), unknown);
  assertEquals(await h.coord.getStatus(undefined as unknown as string), unknown);
});

Deno.test('the receipt survives purge and Auth deletion, exposes no identifiers, and expires indistinguishably from never-issued', async () => {
  const h = setup();
  h.addUser(UID_A);
  await h.accept(UID_A);
  await h.coord.processNext('w');
  // User-owned rows are gone, yet the receipt still answers.
  assertEquals(h.world.users.get(UID_A)!.profile, false);
  assertEquals(h.world.users.get(UID_A)!.syncState, false);
  const status = await h.coord.getStatus(h.secretOf(UID_A));
  assertEquals(status.status, 'completed');
  assertEquals(Object.keys(status).sort(), ['retainedUntilMs', 'status']);
  const wire = JSON.stringify(status);
  assertFalse(wire.includes(UID_A));
  assertFalse(wire.includes('job-'));

  // The persisted receipt rows hold no UID and not the plaintext capability.
  const receiptRows = JSON.stringify([...h.store.receipts.entries()]);
  assertFalse(receiptRows.includes(UID_A));
  assertFalse(receiptRows.includes(h.secretOf(UID_A)));
  assertFalse(h.secretOf(UID_A).includes(UID_A));

  h.clock.advance(OPTIONS.receiptRetentionMs! + 1);
  assertEquals(await h.coord.getStatus(h.secretOf(UID_A)), await h.coord.getStatus('q'.repeat(48)));
  assertEquals(h.store.receipts.size, 0);
});

// ── redaction ────────────────────────────────────────────────────────────────

Deno.test('thrown provider text, tokens, codes and UIDs never reach persistence, logs or returned results', async () => {
  const h = setup();
  h.addUser(UID_A);
  const { jobId } = await h.accept(UID_A);
  const leak = `SECRET-PROVIDER-TEXT token=${`token-${UID_A}`} uid=${UID_A} APPLE-CODE-PLAINTEXT-SENTINEL`;
  h.steps.overrides.storage_sweep = (n) => {
    if (n === 1) throw new Error(leak);
    return undefined;
  };
  const first = await h.coord.processJob(jobId, 'w');
  assertEquals(first, { outcome: 'retry_scheduled', stage: 'storage_sweep', code: 'unexpected' });
  h.clock.advance(LATE);
  const second = await h.coord.processNext('w');
  assertEquals(second, { outcome: 'completed' });

  const observable = JSON.stringify([first, second, h.logs]) + h.store.dump().replace(UID_A, '<uid>');
  for (const needle of ['SECRET-PROVIDER-TEXT', 'APPLE-CODE-PLAINTEXT-SENTINEL', `token-${UID_A}`, h.secretOf(UID_A)]) {
    assertFalse(observable.includes(needle), `leaked ${needle}`);
  }
  // Logs and results name only enumerated stages/codes and an opaque job id.
  assertFalse(JSON.stringify([first, second, h.logs]).includes(UID_A));
  assert(h.logs.some((e) => e.event === 'stage_failed' && e.code === 'unexpected'));
  assertStringIncludes(JSON.stringify(h.logs), 'completed');
});

Deno.test('a store failure mid-run reports aborted without a message and without claiming progress', async () => {
  const h = setup();
  h.addUser(UID_A);
  await h.accept(UID_A);
  h.store.fault = { op: 'heartbeat', when: 'before' };
  const r = await h.coord.processNext('w');
  assertEquals(r, { outcome: 'aborted' });
  assertEquals(h.steps.trace.length, 0);
  assertFalse(JSON.stringify(r).includes('injected'));
});

Deno.test('invalid coordinator options are rejected at construction', () => {
  const h = setup();
  for (const options of [{ leaseMs: 10 }, { receiptRetentionMs: 1 }, { retryBaseMs: 0 }, { retryBaseMs: 5, retryMaxMs: 1 }]) {
    let threw = false;
    try {
      createAccountDeletionCoordinator({
        authorizer: h.authz,
        store: h.store,
        steps: h.steps,
        readiness: () => ({ ok: true }),
        options,
      });
    } catch {
      threw = true;
    }
    assert(threw, JSON.stringify(options));
  }
});

// ═════════════════════════════════════════════════════════════════════════════
// Rework regressions (review findings 1-5). Everything above is unchanged.
// ═════════════════════════════════════════════════════════════════════════════

const STATUS_OF = async (h: ReturnType<typeof setup>, uid = UID_A, n = 1) =>
  (await h.coord.getStatus(h.secretOf(uid, n))).status;

// ── 1. receipt retention starts only at confirmed terminal completion ────────

Deno.test('a receipt never expires while the job is accepted, running, retryable or failed', async () => {
  const far = OPTIONS.receiptRetentionMs! * 10;
  type H = ReturnType<typeof setup>;
  const build: Record<string, (h: H) => Promise<void>> = {
    accepted: async (h) => {
      await h.accept(UID_A);
    },
    running: async (h) => {
      await h.accept(UID_A);
      h.store.fault = { op: 'beginStep', when: 'after', stage: 'sql_purge' };
      assertEquals(await h.coord.processNext('w'), { outcome: 'aborted' });
    },
    retryable: async (h) => {
      await h.accept(UID_A);
      h.steps.overrides.storage_sweep = (n) => (n === 1 ? { status: 'incomplete' } : undefined);
      await h.coord.processNext('w');
    },
    failed: async (h) => {
      await h.accept(UID_A);
      h.steps.overrides.apple_revoke = () => ({ status: 'failed' });
      await h.coord.processNext('w');
    },
  };
  for (const [state, prepare] of Object.entries(build)) {
    const h = setup();
    h.addUser(UID_A);
    await prepare(h);
    assertEquals(h.store.job(UID_A).state, state);
    h.clock.advance(far); // far beyond any retention, lease or back-off
    assertEquals(await STATUS_OF(h), state === 'accepted' ? 'accepted' : 'pending', state);
    assertEquals(h.store.receipts.size, 1, state);
    // Nothing about the passage of time cancelled the job: it can still finish.
    if (state !== 'failed') {
      assertEquals((await h.coord.processNext('w')).outcome, 'completed', state);
      assertEquals(await STATUS_OF(h), 'completed', state);
    }
  }
});

Deno.test('retention starts at terminal completion, not acceptance, and then genuinely expires', async () => {
  const h = setup();
  h.addUser(UID_A);
  await h.accept(UID_A);
  h.steps.overrides.terminal_storage = (n) => (n === 1 ? { status: 'incomplete' } : undefined);
  await h.coord.processNext('w');
  h.clock.advance(OPTIONS.receiptRetentionMs! * 3); // would have expired if keyed to acceptance
  assertEquals(await STATUS_OF(h), 'pending');
  assertEquals((await h.coord.processNext('w')).outcome, 'completed');
  const completedAt = h.clock.t;
  const done = await h.coord.getStatus(h.secretOf(UID_A));
  assertEquals(done, { status: 'completed', retainedUntilMs: completedAt + OPTIONS.receiptRetentionMs! });

  h.clock.advance(OPTIONS.receiptRetentionMs! - 1);
  assertEquals(await STATUS_OF(h), 'completed');
  h.clock.advance(1);
  assertEquals(await h.coord.getStatus(h.secretOf(UID_A)), { status: 'unknown' });
  assertEquals(h.store.receipts.size, 0);
});

Deno.test('a store that reports an expiry on a non-terminal job, or a bad completed record, is invalid not pending', async () => {
  const bad: unknown[] = [
    { state: 'running', retainedUntilMs: 5 },
    { state: 'retryable', retainedUntilMs: 5 },
    { state: 'completed' },
    { state: 'completed', retainedUntilMs: NaN },
    { state: 'completed', retainedUntilMs: Infinity },
    { state: 'completed', retainedUntilMs: '5' },
    { state: 'mystery' },
    { state: undefined },
    'completed',
    42,
  ];
  for (const record of bad) {
    const h = setup();
    h.addUser(UID_A);
    await h.accept(UID_A);
    h.store.getReceipt = () => Promise.resolve(record as ReceiptRecord);
    assertEquals(await h.coord.getStatus(h.secretOf(UID_A)), { status: 'unavailable' }, JSON.stringify(record));
  }
});

Deno.test('a status lookup outage is unavailable, never unknown', async () => {
  const h = setup();
  h.addUser(UID_A);
  await h.accept(UID_A);
  h.store.down.add('getReceipt');
  assertEquals(await h.coord.getStatus(h.secretOf(UID_A)), { status: 'unavailable' });
  h.store.down.delete('getReceipt');
  assertEquals(await STATUS_OF(h), 'accepted');
});

// ── 2. acceptance unknown after a (possibly) spent Apple exchange ────────────

Deno.test('accept commits then the response throws: reconciled as accepted, material retained', async () => {
  const h = setup();
  h.addUser(UID_A);
  const req = h.issue(UID_A);
  h.store.fault = { op: 'accept', when: 'after' };
  const r = await h.coord.requestDeletion(req);
  assert(r.status === 'accepted' && r.duplicate === true);
  assertEquals(h.store.jobs.size, 1);
  assertEquals(h.store.job(UID_A).ref, 'enc:ref-challenge-1-aaaa');
  assertEquals(h.authz.discarded, []); // the committed job references it
  assertEquals(await STATUS_OF(h), 'accepted');
  assert(h.store.frozen.has(UID_A));
});

Deno.test('accept never commits after the exchange: authoritative non-acceptance disposes material and allows fresh authorization', async () => {
  const h = setup();
  h.addUser(UID_A);
  const req = h.issue(UID_A);
  h.store.fault = { op: 'accept', when: 'before' };
  assertEquals(await h.coord.requestDeletion(req), { status: 'error', code: 'store_unavailable', retryable: true });
  assertEquals([h.store.jobs.size, h.store.frozen.size, h.store.receipts.size], [0, 0, 0]);
  assertEquals(h.authz.discarded, ['enc:ref-challenge-1-aaaa']);
  // The spent code cannot be replayed; only a fresh authorization can proceed.
  assertEquals(await h.coord.requestDeletion(req), { status: 'error', code: 'challenge_replayed', retryable: false });
  const fresh = await h.coord.requestDeletion(h.issue(UID_A, 2));
  assertEquals(fresh.status, 'accepted');
});

Deno.test('accept fails AND the reconciliation lookup is down: acceptance unknown, nothing disposed, no fresh authorization advised', async () => {
  for (const commits of [true, false]) {
    const h = setup();
    h.addUser(UID_A);
    const req = h.issue(UID_A);
    h.store.hooks.accept = () => {
      h.store.down.add('findAccepted'); // outage begins after the first (pre-exchange) lookup
    };
    h.store.fault = { op: 'accept', when: commits ? 'after' : 'before' };
    const r = await h.coord.requestDeletion(req);
    assertEquals(r, { status: 'error', code: 'acceptance_unknown', retryable: true, recovery: 'lookup_receipt' });
    assertEquals(h.authz.discarded, [], 'material must be retained while acceptance is unknown');
    assertEquals(h.store.jobs.size, commits ? 1 : 0);
    // The status lookup that follows is also "unavailable", which proves nothing.
    h.store.down.add('getReceipt');
    assertEquals(await h.coord.getStatus(h.secretOf(UID_A)), { status: 'unavailable' });

    h.store.down.clear();
    if (commits) {
      assertEquals(await STATUS_OF(h), 'accepted');
      const again = await h.coord.requestDeletion(req); // same request recovers without re-exchanging
      assert(again.status === 'accepted' && again.duplicate);
      assertEquals(h.authz.authorizeCalls.length, 1);
    } else {
      // Only now, with a successful lookup showing nothing, is non-acceptance established.
      assertEquals(await h.coord.getStatus(h.secretOf(UID_A)), { status: 'unknown' });
      assertEquals((await h.coord.requestDeletion(h.issue(UID_A, 2))).status, 'accepted');
    }
  }
});

Deno.test('a malformed accept outcome is reconciled, not trusted: committed -> accepted, uncommitted -> non-acceptance', async () => {
  const cases: unknown[] = [undefined, null, {}, { outcome: 'accepted' }, { outcome: 'accepted', jobId: '' }, {
    outcome: 'weird',
  }];
  for (const malformed of cases) {
    const committed = setup();
    committed.addUser(UID_A);
    const realAccept = committed.store.accept.bind(committed.store);
    committed.store.accept = async (i) => {
      await realAccept(i);
      return malformed as AcceptOutcome;
    };
    const a = await committed.coord.requestDeletion(committed.issue(UID_A));
    assert(a.status === 'accepted' && a.duplicate, JSON.stringify(malformed));
    assertEquals(committed.authz.discarded, []);

    const lost = setup();
    lost.addUser(UID_A);
    lost.store.accept = () => Promise.resolve(malformed as AcceptOutcome);
    assertEquals(await lost.coord.requestDeletion(lost.issue(UID_A)), {
      status: 'error',
      code: 'store_unavailable',
      retryable: true,
    });
    assertEquals(lost.authz.discarded.length, 1);
  }
});

Deno.test('unused material is disposed after a duplicate, already_pending, conflict or expiry, and the winner keeps its own', async () => {
  // Simultaneous identical requests: exactly one exchange result is referenced.
  const race = setup();
  race.addUser(UID_A);
  race.authz.singleUse = false;
  const req = race.issue(UID_A);
  race.authz.gate = deferred();
  const p1 = race.coord.requestDeletion(req);
  const p2 = race.coord.requestDeletion(req);
  try {
    // Deterministic arrival barrier instead of a single timer tick (load-dependent flake).
    await race.authz.waitForAuthorizeCalls(2);
  } catch (e) {
    race.authz.gate.resolve(); // failure cleanup: release and drain outstanding requests
    await Promise.allSettled([p1, p2]);
    throw e;
  }
  race.authz.gate.resolve();
  await Promise.all([p1, p2]);
  assertEquals(race.authz.discarded.length, 1);
  assert(race.authz.discarded[0] !== race.store.job(UID_A).ref);
  assert(race.store.job(UID_A).ref !== null);

  // A fresh challenge for an already-pending UID: the new material is unused.
  const pending = setup();
  pending.addUser(UID_A);
  await pending.accept(UID_A, 1);
  const firstRef = pending.store.job(UID_A).ref;
  await pending.accept(UID_A, 2);
  assertEquals(pending.authz.discarded, ['enc:ref-challenge-2-aaaa']);
  assertEquals(pending.store.job(UID_A).ref, firstRef);

  // Store-level expiry race.
  const late = setup();
  late.addUser(UID_A);
  late.authz.override = () => ({
    ok: true,
    verified: true,
    appleSubjectMatched: true,
    challengeExpiresAtMs: late.clock.t - 1,
    appleMaterialRef: 'enc:ref-expired-race',
  });
  assertEquals((await late.coord.requestDeletion(late.issue(UID_A))).status, 'error');
  assertEquals(late.authz.discarded, ['enc:ref-expired-race']);

  // Store-arbitrated conflict (the pre-check missed it).
  const conflict = setup();
  conflict.addUser(UID_A);
  const original = conflict.issue(UID_A);
  await conflict.coord.requestDeletion(original);
  conflict.store.findAccepted = () => Promise.resolve(null);
  conflict.authz.singleUse = false;
  const clash = await conflict.coord.requestDeletion({ ...original, receiptSecret: 'z'.repeat(48) });
  assertEquals(clash, { status: 'error', code: 'idempotency_conflict', retryable: false });
  assertEquals(conflict.authz.discarded.length, 1);
});

Deno.test('a failing or leaking discard never changes the outcome, and malformed refs are never handed to the disposer', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.authz.discardThrows = true;
  h.store.fault = { op: 'accept', when: 'before' };
  const r = await h.coord.requestDeletion(h.issue(UID_A));
  assertEquals(r, { status: 'error', code: 'store_unavailable', retryable: true });
  assertFalse(JSON.stringify([r, h.logs]).includes('SECRET-PROVIDER-TEXT'));

  const plain = setup();
  plain.addUser(UID_A);
  plain.authz.override = () => ({
    ok: true,
    verified: true,
    appleSubjectMatched: true,
    challengeExpiresAtMs: plain.clock.t + 60_000,
    appleMaterialRef: 'eyJhbGciOiJSUzI1NiJ9.payload.sig',
  });
  assertEquals((await plain.coord.requestDeletion(plain.issue(UID_A))).status, 'error');
  assertEquals(plain.authz.discarded, []);
});

// ── 3. logging / readiness are non-essential or fail closed ──────────────────

Deno.test('a throwing or rejecting logger changes no outcome on success, failure or catch paths', async () => {
  const loggers: Array<(e: LogEvent) => unknown> = [
    () => {
      throw new Error('logger down SECRET-PROVIDER-TEXT');
    },
    () => Promise.reject(new Error('async logger down')),
  ];
  for (const logger of loggers) {
    const h = setup(OPTIONS, logger);
    h.addUser(UID_A);
    h.addUser(UID_B);
    const r = await h.accept(UID_A);
    await h.accept(UID_A, 2); // duplicate path logs too
    assertEquals(await h.coord.processJob(r.jobId, 'w'), { outcome: 'completed' });
    assertEquals(await STATUS_OF(h), 'completed');

    // Catch path: a store failure mid-run logs 'aborted' from inside the catch.
    await h.accept(UID_B);
    h.store.fault = { op: 'heartbeat', when: 'before' };
    assertEquals(await h.coord.processNext('w'), { outcome: 'aborted' });
    // Failure path.
    h.clock.advance(LATE);
    h.steps.overrides.storage_sweep = () => ({ status: 'incomplete' });
    assertEquals((await h.coord.processNext('w')).outcome, 'retry_scheduled');
    await tick(); // let any rejected promise surface as an unhandled rejection
  }
});

Deno.test('a throwing or malformed readiness reports not_configured before and during the run', async () => {
  const impls: Array<() => unknown> = [
    () => {
      throw new Error('config probe exploded SECRET-PROVIDER-TEXT');
    },
    () => undefined,
    () => null,
    () => ({}),
    () => ({ ok: 'true' }),
    () => ({ ok: 1 }),
    () => ({ ok: false }),
  ];
  for (const impl of impls) {
    const h = setup();
    h.addUser(UID_A);
    const { jobId } = await h.accept(UID_A);
    h.config.impl = impl;
    const req = await h.coord.requestDeletion(h.issue(UID_A, 2));
    assertEquals(req, { status: 'error', code: 'not_configured', retryable: false });
    assertEquals(await h.coord.processJob(jobId, 'w'), {
      outcome: 'retry_scheduled',
      stage: 'apple_revoke',
      code: 'not_configured',
    });
    assertEquals(h.steps.trace.length, 0);
    assertFalse(JSON.stringify([req, h.logs]).includes('SECRET-PROVIDER-TEXT'));
  }
});

// ── 3. malformed positive responses are rejected before trust or side effects ─

Deno.test('a malformed identity never becomes a target UID', async () => {
  const bad: unknown[] = [
    null,
    undefined,
    'uid',
    { ok: true },
    { ok: true, uid: 42 },
    { ok: true, uid: 'not-a-uuid' },
    { ok: true, uid: `${UID_A} ` },
    { ok: 'true', uid: UID_A },
  ];
  for (const value of bad) {
    const h = setup();
    h.addUser(UID_A);
    h.authz.identityOverride = () => value;
    const r = await h.coord.requestDeletion(h.issue(UID_A));
    assertEquals(r, { status: 'error', code: 'unauthenticated', retryable: false }, JSON.stringify(value));
    assertEquals(h.authz.authorizeCalls.length, 0);
    assertEquals(h.store.jobs.size, 0);
  }
});

Deno.test('a malformed or contradictory lease grant is invalid_state with no step taken', async () => {
  const goodRef = 'enc:ref-challenge-1-aaaa';
  const jobOf = (g: LeaseGrant) => g.job as unknown as Record<string, unknown>;
  const mutations: Array<[string, (g: LeaseGrant) => void]> = [
    ['job id differs from lease', (g) => (jobOf(g).jobId = 'job-other')],
    ['uid not a uuid', (g) => (jobOf(g).uid = 'someone')],
    ['uid missing', (g) => (jobOf(g).uid = undefined)],
    ['steps out of order', (g) => (jobOf(g).completedSteps = ['sql_purge'])],
    ['steps repeated', (g) => (jobOf(g).completedSteps = ['apple_revoke', 'apple_revoke'])],
    ['unknown stage', (g) => (jobOf(g).completedSteps = ['apple_revoke', 'format_disk'])],
    ['too many steps', (g) => (jobOf(g).completedSteps = [...DELETION_STAGES, 'apple_revoke'])],
    ['steps not an array', (g) => (jobOf(g).completedSteps = 'apple_revoke')],
    ['apple done but material still held', (g) => {
      jobOf(g).completedSteps = ['apple_revoke'];
      jobOf(g).appleMaterialRef = goodRef;
    }],
    ['plaintext-looking material', (g) => (jobOf(g).appleMaterialRef = 'eyJhbGciOiJSUzI1NiJ9.payload.sig')],
    ['non-string material', (g) => (jobOf(g).appleMaterialRef = 7)],
    ['negative attempts', (g) => (jobOf(g).attempts = -1)],
    ['NaN attempts', (g) => (jobOf(g).attempts = NaN)],
    ['generation zero', (g) => (g.lease.generation = 0)],
    ['fractional generation', (g) => (g.lease.generation = 1.5)],
    ['empty token', (g) => (g.lease.token = '')],
    ['missing job', (g) => ((g as unknown as Record<string, unknown>).job = undefined)],
  ];
  for (const [name, mutate] of mutations) {
    const h = setup();
    h.addUser(UID_A);
    const { jobId } = await h.accept(UID_A);
    const real = h.store.claimLease.bind(h.store);
    h.store.claimLease = async (input) => {
      const grant = await real(input);
      if (grant) mutate(grant);
      return grant;
    };
    assertEquals(await h.coord.processJob(jobId, 'w'), { outcome: 'invalid_state' }, name);
    assertEquals(h.steps.trace.length, 0, name);
    assertEquals(h.store.job(UID_A).completed, [], name);
  }
});

Deno.test('a grant for a different job than requested, or an undefined grant, is never run', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.addUser(UID_B);
  const a = await h.accept(UID_A);
  const b = await h.accept(UID_B);
  const real = h.store.claimLease.bind(h.store);
  h.store.claimLease = (input) => real({ ...input, jobId: b.jobId }); // store ignores the requested id
  assertEquals(await h.coord.processJob(a.jobId, 'w'), { outcome: 'invalid_state' });
  assertEquals(h.steps.trace.length, 0);
  h.store.claimLease = () => Promise.resolve(undefined as unknown as LeaseGrant | null);
  assertEquals(await h.coord.processNext('w'), { outcome: 'invalid_state' });
});

Deno.test('malformed lease-write responses stop the run as invalid_state, before the side effect where they precede it', async () => {
  const badWrites: unknown[] = [
    undefined,
    null,
    'ok',
    {},
    { ok: 'true' },
    { ok: false },
    { ok: false, reason: 'out_of_order' },
    { ok: false, reason: 'incomplete_steps' },
  ];
  for (const bad of badWrites) {
    for (const op of ['heartbeat', 'beginStep'] as const) {
      const h = setup();
      h.addUser(UID_A);
      await h.accept(UID_A);
      (h.store as unknown as Record<string, unknown>)[op] = () => Promise.resolve(bad);
      assertEquals(await h.coord.processNext('w'), { outcome: 'invalid_state' }, `${op} ${JSON.stringify(bad)}`);
      assertEquals(h.steps.trace.length, 0, `${op} must precede the side effect`);
    }
    const h = setup();
    h.addUser(UID_A);
    await h.accept(UID_A);
    (h.store as unknown as Record<string, unknown>).completeJob = () => Promise.resolve(bad);
    assertEquals(await h.coord.processNext('w'), { outcome: 'invalid_state' });
    assertEquals((await h.coord.getStatus(h.secretOf(UID_A))).status, 'pending'); // never "completed"
  }
});

Deno.test('a malformed findAccepted answer is a retryable store failure, not an acceptance', async () => {
  for (const bad of [{ jobId: 1, receiptHash: 'x' }, { jobId: 'j' }, 'yes', {}]) {
    const h = setup();
    h.addUser(UID_A);
    h.store.findAccepted = () => Promise.resolve(bad as never);
    assertEquals(await h.coord.requestDeletion(h.issue(UID_A)), {
      status: 'error',
      code: 'store_unavailable',
      retryable: true,
    });
    assertEquals(h.authz.authorizeCalls.length, 0);
  }
});

// ── 3. timing options ────────────────────────────────────────────────────────

Deno.test('non-finite, non-numeric and out-of-range timing options fail construction; undefined means default', () => {
  const h = setup();
  const build = (options: unknown) =>
    createAccountDeletionCoordinator({
      authorizer: h.authz,
      store: h.store,
      steps: h.steps,
      readiness: () => ({ ok: true }),
      options: options as CoordinatorOptions,
    });
  const bad: unknown[] = [];
  for (const key of ['leaseMs', 'receiptRetentionMs', 'retryBaseMs', 'retryMaxMs']) {
    for (const v of [NaN, Infinity, -Infinity, -1, 0, '60000', null, {}, true]) bad.push({ [key]: v });
  }
  bad.push(
    { leaseMs: 4_999 },
    { leaseMs: 300_001 },
    { receiptRetentionMs: 90 * 24 * 60 * 60 * 1000 + 1 },
    { retryBaseMs: 10_000, retryMaxMs: 9_999 },
    { retryMaxMs: 24 * 60 * 60 * 1000 + 1 },
  );
  for (const options of bad) {
    let threw = false;
    try {
      build(options);
    } catch {
      threw = true;
    }
    assert(threw, `accepted ${String(JSON.stringify(options))}`);
  }
  build({ leaseMs: undefined, receiptRetentionMs: undefined, retryBaseMs: undefined, retryMaxMs: undefined });
  build(undefined);
  build(OPTIONS);
});

// ── 4. lease checks fence bookkeeping, not dispatched calls ──────────────────

const replaceLease = (h: ReturnType<typeof setup>) => async () => {
  h.clock.advance(LEASE_MS + 1);
  const taken = await h.store.claimLease({ workerId: 'B', leaseMs: LEASE_MS });
  assert(taken !== null);
};

Deno.test('lease replaced before the heartbeat answer: no side effect, no write, replacement untouched', async () => {
  const h = setup();
  h.addUser(UID_A);
  await h.accept(UID_A);
  h.store.hooks.heartbeat = replaceLease(h);
  assertEquals(await h.coord.processNext('A'), { outcome: 'lease_lost' });
  assertEquals(h.steps.trace.length, 0);
  const job = h.store.job(UID_A);
  assertEquals([job.generation, job.state, job.completed, job.attempts], [2, 'running', [], 0]);
});

Deno.test('lease replaced between heartbeat and beginStep: no side effect', async () => {
  const h = setup();
  h.addUser(UID_A);
  await h.accept(UID_A);
  h.store.hooks.beginStep = replaceLease(h);
  assertEquals(await h.coord.processNext('A'), { outcome: 'lease_lost' });
  assertEquals(h.steps.trace.length, 0);
  assertEquals(h.store.job(UID_A).generation, 2);
});

Deno.test('lease replaced AFTER beginStep answered: the call is dispatched anyway, bookkeeping fails, next holder repeats it', async () => {
  // This is the irreducible window: no store answer can prevent the dispatch.
  const h = setup();
  h.addUser(UID_A);
  await h.accept(UID_A);
  const real = h.store.beginStep.bind(h.store);
  let lapsed = false;
  h.store.beginStep = async (lease, stage) => {
    const r = await real(lease, stage);
    if (!lapsed) {
      lapsed = true;
      await replaceLease(h)(); // replaced after the answer, before the dispatch
    }
    return r;
  };
  assertEquals(await h.coord.processNext('A'), { outcome: 'lease_lost' });
  assertEquals(h.steps.counts.apple_revoke, 1); // dispatched, not "cancelled"
  const job = h.store.job(UID_A);
  assertEquals([job.completed, job.generation], [[], 2]); // A recorded nothing
  assertEquals(h.steps.counts.storage_sweep, 0); // and never started a later stage

  h.clock.advance(LEASE_MS + 1);
  h.store.beginStep = real;
  assertEquals(await h.coord.processNext('C'), { outcome: 'completed' });
  assertEquals(h.steps.counts.apple_revoke, 2); // replayed idempotently
});

Deno.test('lease replaced before completeJob: the stale worker cannot complete the job or its receipt', async () => {
  const h = setup();
  h.addUser(UID_A);
  await h.accept(UID_A);
  h.store.hooks.completeJob = replaceLease(h);
  assertEquals(await h.coord.processNext('A'), { outcome: 'lease_lost' });
  assertEquals(h.store.job(UID_A).state, 'running');
  assertEquals(await STATUS_OF(h), 'pending');
  assertEquals(h.store.job(UID_A).completed, [...DELETION_STAGES]);
});

Deno.test('a stale holder cannot heartbeat, mark, fail, complete or dequeue after replacement (every write is fenced)', async () => {
  const h = setup();
  h.addUser(UID_A);
  await h.accept(UID_A);
  const grant = (await h.store.claimLease({ workerId: 'A', leaseMs: LEASE_MS }))!;
  h.clock.advance(LEASE_MS + 1);
  const newer = (await h.store.claimLease({ workerId: 'B', leaseMs: LEASE_MS }))!;
  const before = h.store.dump();
  const lost: LeaseWrite = { ok: false, reason: 'lease_lost' };
  assertEquals(await h.store.heartbeat(grant.lease, LEASE_MS), lost);
  assertEquals(await h.store.beginStep(grant.lease, 'apple_revoke'), lost);
  assertEquals(await h.store.completeStep(grant.lease, 'apple_revoke'), lost);
  assertEquals(
    await h.store.recordFailure(grant.lease, {
      stage: 'apple_revoke',
      code: 'unexpected',
      retryable: false,
      retryDelayMs: 1,
    }),
    lost,
  );
  assertEquals(await h.store.completeJob(grant.lease, 1_000), lost);
  assertEquals(h.store.dump(), before);
  assertEquals(await h.store.heartbeat(newer.lease, LEASE_MS), { ok: true }); // the holder still works
  assert(h.store.frozen.has(UID_A));
});

Deno.test('an unrecognised Auth outcome (HTTP-404-like) is never success', async () => {
  const outcomes: unknown[] = [{ status: 'not_found' }, { status: 404 }, { status: 'ok' }, {}, { status: undefined }];
  for (const outcome of outcomes) {
    const h = setup();
    h.addUser(UID_A);
    await h.accept(UID_A);
    h.steps.overrides.auth_delete = (n) => (n === 1 ? outcome : undefined);
    const r = await h.coord.processNext('w');
    assertEquals(r.outcome, 'retry_scheduled', JSON.stringify(outcome));
    assertFalse(h.steps.trace.includes('terminal_storage'));
    assertEquals(await STATUS_OF(h), 'pending');
  }
});

// ── 5. receipt secret format is not an entropy proof ─────────────────────────

Deno.test('the receipt secret check is format-only: a well-formed low-entropy value passes (client must use a CSPRNG)', async () => {
  const h = setup();
  h.addUser(UID_A);
  const weak = { ...h.issue(UID_A), receiptSecret: 'a'.repeat(43) };
  assertEquals((await h.coord.requestDeletion(weak)).status, 'accepted');
  assertEquals((await h.coord.getStatus('a'.repeat(43))).status, 'accepted');
  // Wrong alphabet or length is still refused outright.
  for (const secret of ['a'.repeat(42), 'a'.repeat(129), `${'a'.repeat(42)}!`, `${'a'.repeat(42)} `]) {
    const r = await h.coord.requestDeletion({ ...h.issue(UID_A, 2), receiptSecret: secret });
    assertEquals(r, { status: 'error', code: 'invalid_request', retryable: false });
  }
});

// ═════════════════════════════════════════════════════════════════════════════
// Rework 03: reference-aware material custody. An IDEMPOTENT authorizer may hand
// the SAME encrypted reference to a duplicate, a concurrent identical request, a
// fresh challenge for the same account or a conflicting retry, so the coordinator
// must never destroy material the winning acceptance still references. Everything
// above is unchanged. The registry models the property; it does not prove it.
// ═════════════════════════════════════════════════════════════════════════════

const REF_A = 'enc:ref-challenge-1-aaaa'; // by_challenge reference for UID_A's first challenge
type Harness = ReturnType<typeof setup>;

/** Two simultaneous identical requests; both are issued before either accepts. */
async function raceIdentical(h: Harness) {
  const req = h.issue(UID_A);
  h.authz.gate = deferred();
  const p1 = h.coord.requestDeletion(req);
  const p2 = h.coord.requestDeletion(req);
  try {
    // Deterministic arrival barrier instead of a single timer tick (load-dependent flake).
    await h.authz.waitForAuthorizeCalls(2);
  } catch (e) {
    h.authz.gate.resolve(); // failure cleanup: release and drain outstanding requests
    await Promise.allSettled([p1, p2]);
    throw e;
  }
  h.authz.gate.resolve();
  return await Promise.all([p1, p2]);
}

/** Material survived and is the very reference the winning job revokes with. */
async function assertWinnerMaterialIntact(h: Harness, jobId: string, ref: string) {
  assertEquals(h.store.job(UID_A).ref, ref);
  assertFalse(h.vault.destroyed.has(ref));
  assertEquals(h.authz.discarded, []);
  assertEquals(await h.coord.processJob(jobId, 'w'), { outcome: 'completed' });
  assertEquals(h.world.revokedRefs, [ref]); // Apple revocation used the surviving material
}

Deno.test('duplicate with the SAME reference: the loser\'s disposal keeps the winner\'s material', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.authz.refMode = 'by_challenge';
  h.authz.singleUse = false;
  const [r1, r2] = await raceIdentical(h);
  assert(r1.status === 'accepted' && r2.status === 'accepted');
  assertEquals([r1.duplicate, r2.duplicate].sort(), [false, true]);
  assertEquals(h.store.jobs.size, 1);
  assertEquals(h.authz.dispositions, [`${REF_A}:kept_referenced`]);
  assertEquals(h.vault.committed.get(REF_A), 1);
  assertEquals(h.logs.filter((e) => e.event === 'material_disposition').map((e) => e.disposition), ['kept_referenced']);
  await assertWinnerMaterialIntact(h, r1.jobId, REF_A);
  // Cleanup outcomes are enumerated only: no reference, UID or error text in logs.
  const wire = JSON.stringify(h.logs);
  assertFalse(wire.includes('enc:'));
  assertFalse(wire.includes(UID_A));
});

Deno.test('already_pending with the SAME account-level reference: the pending job\'s material is kept', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.authz.refMode = 'by_uid';
  const ref = 'enc:ref-acct-aaaaaaaa';
  const first = await h.accept(UID_A, 1);
  const second = await h.accept(UID_A, 2); // fresh challenge, same reference handed out again
  assertEquals(second.duplicate, true);
  assertEquals(second.jobId, first.jobId);
  assertEquals(h.authz.dispositions, [`${ref}:kept_referenced`]);
  await assertWinnerMaterialIntact(h, first.jobId, ref);
});

Deno.test('idempotency conflict with the SAME reference: the committed job\'s material is kept', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.authz.refMode = 'by_challenge';
  h.authz.singleUse = false;
  const original = h.issue(UID_A);
  const first = await h.coord.requestDeletion(original);
  assert(first.status === 'accepted');
  h.store.findAccepted = () => Promise.resolve(null); // the pre-check misses; the store arbitrates
  const clash = await h.coord.requestDeletion({ ...original, receiptSecret: 'z'.repeat(48) });
  assertEquals(clash, { status: 'error', code: 'idempotency_conflict', retryable: false });
  assertEquals(h.authz.dispositions, [`${REF_A}:kept_referenced`]);
  await assertWinnerMaterialIntact(h, first.jobId, REF_A);
});

Deno.test('conflict found by reconciliation with the SAME reference: the committed job\'s material is kept', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.authz.refMode = 'by_challenge';
  h.authz.singleUse = false;
  const original = h.issue(UID_A);
  const first = await h.coord.requestDeletion(original);
  assert(first.status === 'accepted');
  // Pre-check misses, the accept answer is lost, and the reconciliation read finds the winner.
  let reads = 0;
  const real = h.store.findAccepted.bind(h.store);
  h.store.findAccepted = (k) => (++reads === 1 ? Promise.resolve(null) : real(k));
  h.store.fault = { op: 'accept', when: 'before' };
  const clash = await h.coord.requestDeletion({ ...original, receiptSecret: 'y'.repeat(48) });
  assertEquals(clash, { status: 'error', code: 'idempotency_conflict', retryable: false });
  assertEquals(h.authz.dispositions, [`${REF_A}:kept_referenced`]);
  await assertWinnerMaterialIntact(h, first.jobId, REF_A);
});

Deno.test('unknown acceptance with a reused reference requests no disposal and keeps the material usable', async () => {
  for (const commits of [true, false]) {
    const h = setup();
    h.addUser(UID_A);
    h.authz.refMode = 'by_challenge';
    h.authz.singleUse = false;
    const req = h.issue(UID_A);
    h.store.hooks.accept = () => {
      h.store.down.add('findAccepted');
    };
    h.store.fault = { op: 'accept', when: commits ? 'after' : 'before' };
    const r = await h.coord.requestDeletion(req);
    assertEquals(r, { status: 'error', code: 'acceptance_unknown', retryable: true, recovery: 'lookup_receipt' });
    assertEquals(h.authz.dispositions, []); // no disposal was even requested
    assertFalse(h.vault.destroyed.has(REF_A));
    assertEquals(h.vault.committed.get(REF_A) ?? 0, commits ? 1 : 0);
    assertEquals(h.vault.holds.get(REF_A) ?? 0, commits ? 0 : 1);

    // After the outage the same request recovers and the retained material is what the job uses.
    h.store.down.clear();
    const again = await h.coord.requestDeletion(req);
    assert(again.status === 'accepted' && again.duplicate === commits);
    await assertWinnerMaterialIntact(h, again.status === 'accepted' ? again.jobId : '', REF_A);
  }
});

Deno.test('cleanup versus a concurrent acceptance of the same reference: neither order destroys it', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.authz.refMode = 'by_challenge';
  h.authz.singleUse = false;
  const req = h.issue(UID_A);
  const hold = deferred();
  h.store.hooks.accept = () => hold.promise; // P1's accept is in flight, not yet committed
  h.store.fault = { op: 'accept', when: 'before' }; // the next accept (P2's) fails without committing

  const p1 = h.coord.requestDeletion(req);
  await tick();
  assertEquals(h.vault.holds.get(REF_A), 1);

  // P2 learns of a known non-acceptance and requests cleanup while P1 could still commit.
  const r2 = await h.coord.requestDeletion(req);
  assertEquals(r2, { status: 'error', code: 'store_unavailable', retryable: true });
  assertEquals(h.authz.dispositions, [`${REF_A}:kept_referenced`]);
  assertFalse(h.vault.destroyed.has(REF_A));

  hold.resolve();
  const r1 = await p1;
  assert(r1.status === 'accepted' && r1.duplicate === false);
  assertEquals(h.vault.committed.get(REF_A), 1);
  await assertWinnerMaterialIntact(h, r1.jobId, REF_A);
});

Deno.test('a stale cleanup request cannot destroy material a newer acceptance now references', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.authz.refMode = 'by_challenge';
  h.authz.singleUse = false;
  const req = h.issue(UID_A);
  h.store.fault = { op: 'accept', when: 'before' }; // attempt A never commits
  const gate = deferred();
  const disposalStarted = deferred();
  h.authz.disposeStarted = disposalStarted;
  h.authz.disposeGate = gate; // A's disposal request is delayed on its way to the registry

  const a = h.coord.requestDeletion(req);
  await disposalStarted.promise;
  assertEquals(h.authz.dispositions, []); // still in flight

  const b = await h.coord.requestDeletion(req); // a newer attempt gets the same reference and commits
  assert(b.status === 'accepted' && b.duplicate === false);

  gate.resolve(); // the stale request finally arrives
  assertEquals(await a, { status: 'error', code: 'store_unavailable', retryable: true });
  assertEquals(h.authz.dispositions, [`${REF_A}:kept_referenced`]);
  await assertWinnerMaterialIntact(h, b.jobId, REF_A);
});

Deno.test('definitely unreferenced material may be disposed, cannot be resurrected, and no commit can reference it', async () => {
  const h = setup();
  h.addUser(UID_A);
  h.authz.refMode = 'by_challenge';
  const req = h.issue(UID_A);
  h.store.fault = { op: 'accept', when: 'before' };
  assertEquals(await h.coord.requestDeletion(req), { status: 'error', code: 'store_unavailable', retryable: true });
  assertEquals(h.authz.dispositions, [`${REF_A}:disposed`]);
  assertEquals(h.authz.discarded, [REF_A]);
  assert(h.vault.destroyed.has(REF_A));

  // The one-use code is spent and the material gone: the same request cannot revive it.
  h.authz.singleUse = false;
  assertEquals(await h.coord.requestDeletion(req), { status: 'error', code: 'challenge_replayed', retryable: false });

  // No acceptance may commit against disposed material, even if an adapter hands it back.
  const stale = setup();
  stale.addUser(UID_A);
  stale.vault.issue(REF_A);
  stale.vault.dispose(REF_A);
  stale.authz.override = () => ({
    ok: true,
    verified: true,
    appleSubjectMatched: true,
    challengeExpiresAtMs: stale.clock.t + 60_000,
    appleMaterialRef: REF_A,
  });
  assertEquals(await stale.coord.requestDeletion(stale.issue(UID_A)), {
    status: 'error',
    code: 'store_unavailable',
    retryable: true,
  });
  assertEquals([stale.store.jobs.size, stale.store.frozen.size, stale.store.receipts.size], [0, 0, 0]);
  let direct = true;
  try {
    await stale.store.accept({
      scopeKey: 's',
      uid: UID_B,
      challengeId: 'chal-direct',
      challengeExpiresAtMs: stale.clock.t + 1_000,
      receiptHash: 'h',
      appleMaterialRef: REF_A,
    });
  } catch {
    direct = false;
  }
  assertFalse(direct, 'accept must not commit against disposed material');
  assertEquals(stale.store.jobs.size, 0);
});

Deno.test('a failed, throwing or malformed disposal answer keeps the material and never changes the result', async () => {
  const answers: Array<[string, (h: Harness) => void]> = [
    ['throws', (h) => (h.authz.discardThrows = true)],
    ['undefined', (h) => (h.authz.disposeOverride = () => undefined)],
    ['null', (h) => (h.authz.disposeOverride = () => null)],
    ['empty object', (h) => (h.authz.disposeOverride = () => ({}))],
    ['bare string', (h) => (h.authz.disposeOverride = () => 'disposed')],
    ['unknown status', (h) => (h.authz.disposeOverride = () => ({ status: 'wiped' }))],
    ['wrong case', (h) => (h.authz.disposeOverride = () => ({ status: 'DISPOSED' }))],
  ];
  for (const [name, arm] of answers) {
    // Known non-acceptance: the error result is unchanged.
    const none = setup();
    none.addUser(UID_A);
    arm(none);
    none.store.fault = { op: 'accept', when: 'before' };
    const r = await none.coord.requestDeletion(none.issue(UID_A));
    assertEquals(r, { status: 'error', code: 'store_unavailable', retryable: true }, name);
    assertFalse(none.vault.destroyed.size > 0, `${name}: nothing was destroyed by an unconfirmed answer`);

    // Duplicate branch: the accepted result is unchanged.
    const dup = setup();
    dup.addUser(UID_A);
    dup.authz.refMode = 'by_challenge';
    dup.authz.singleUse = false;
    arm(dup);
    const [a, b] = await raceIdentical(dup);
    assert(a.status === 'accepted' && b.status === 'accepted', name);
    assertEquals([a.duplicate, b.duplicate].sort(), [false, true], name);
    assertFalse(dup.vault.destroyed.has(REF_A), name);
    assertEquals(dup.store.job(UID_A).ref, REF_A, name);

    for (const h of [none, dup]) {
      const events = h.logs.filter((e) => e.event === 'material_disposition');
      assertEquals(events.map((e) => e.disposition), ['kept_unconfirmed'], name);
      const wire = JSON.stringify([r, a, b, h.logs]);
      assertFalse(wire.includes('SECRET-PROVIDER-TEXT'), name);
      assertFalse(wire.includes('enc:'), name);
    }
  }
});
