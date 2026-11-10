// Adapter wiring the FROZEN account-deletion coordinator's ports to concrete
// clients: the draft acceptance/lease RPCs, Apple token revocation, Storage
// purge, the SQL erasure entry, the Auth admin API and the terminal Storage
// sweep (in the coordinator's order: Apple -> Storage -> SQL -> Auth -> terminal
// Storage).
//
// DRAFT - NOT APPLIED. The RPC names below are defined only in
// supabase/drafts/account_deletion_fence/fence.sql, which has not been run
// anywhere. Every collaborator is injected, so this module has no network,
// environment or SDK dependency; the unit tests exercise it with fakes only.
// A passing test proves control flow against the contract documented here, not
// that the SQL, Apple or Supabase APIs behave that way.
//
// CUSTODY AND ACCEPTANCE. The coordinator treats a SUCCESSFUL empty
// findAccepted() after a failed accept() as authoritative nonacceptance, which
// is only sound if the failed accept can no longer commit. This adapter makes
// that true with a per-attempt FENCE: accept() carries a random attempt id; if
// accept() throws, times out or answers something unrecognisable, the adapter
// calls account_deletion_fence_attempt(attempt). That RPC serialises with the
// accept transaction (same per-attempt advisory lock) and either reports the
// job the attempt committed, or records a tombstone so a late-arriving accept
// aborts. If the fence call itself cannot be completed, acceptance is UNKNOWN:
// the scope is remembered as "unfenced" and findAccepted() throws for it (a
// read that throws proves nothing), so the coordinator keeps the material and
// answers acceptance_unknown. There is no SELECT-after-timeout as nonacceptance.
//
// SQL ERASURE AUTHORITY. purgeSql() carries only job id, lease token and lease
// generation. The coordinator's port passes a uid, but the adapter never
// forwards it: it checks it against the uid of the lease this adapter was
// granted and lets SQL derive the subject from the job row.

import {
  type AcceptInput,
  type AcceptOutcome,
  type AppleRevokeOutcome,
  type AuthDeleteOutcome,
  type AuthorizationResult,
  type CoordinatorOptions,
  type ConfigKey,
  type ConfigReadiness,
  createAccountDeletionCoordinator,
  DELETION_STAGES,
  type DeletionAuthorizer,
  type DeletionStage,
  type DeletionStore,
  type DeletionSteps,
  type ErrorCode,
  type IdentityResult,
  type JobSnapshot,
  type Lease,
  type LeaseGrant,
  type LeaseWrite,
  type LogEvent,
  type MaterialDisposition,
  type ReceiptRecord,
  type StepOutcome,
  type StorageOutcome,
} from './account_deletion_coordinator.ts';
import { eraseBackupObjects, type StorageErasureResult, type StorageLike } from './storage_erasure.ts';

// ── Injected collaborators ───────────────────────────────────────────────────

export type RpcError = { code?: string; message?: string };
export type RpcResult = { data: unknown; error: RpcError | null };
/** Shape of supabase-js `client.rpc(name, args)` (service-role client). */
export interface RpcClient {
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<RpcResult>;
}

export type AppleAuthorizeResult =
  | { status: 'ok'; refreshToken: string; challengeExpiresAtMs: number }
  | {
    status:
      | 'challenge_invalid'
      | 'challenge_expired'
      | 'challenge_replayed'
      | 'apple_subject_mismatch'
      | 'not_configured';
  };

export interface AppleGateway {
  /**
   * Verifies the one-use challenge/intent for `uid`, the fresh Apple proof
   * against the account's stored Apple subject (never by email), and exchanges
   * the one-use code for a refresh token. Rejects (throws) on outage.
   */
  authorize(input: { uid: string; challengeId: string; challengeResponse: string }): Promise<AppleAuthorizeResult>;
  /** Revokes the refresh token at Apple. Must be idempotent on repeat. */
  revoke(refreshToken: string): Promise<'revoked_verified' | 'retryable' | 'failed'>;
}

/** Encrypts/decrypts the temporary Apple token. The key never reaches this module. */
export interface MaterialSealer {
  seal(plaintext: string): Promise<string>;
  unseal(ciphertext: string): Promise<string>;
}

export type AuthAdminError = { status?: number; code?: string; message?: string };
export interface AuthAdmin {
  deleteUser(uid: string): Promise<{ error: AuthAdminError | null }>;
}

export interface AdapterPorts {
  rpc: RpcClient;
  /** Resolves a bearer JWT against Auth. null = not a live user (stale/invalid). */
  identity: { getUser(bearerToken: string): Promise<{ id: string } | null> };
  apple: AppleGateway;
  alternateProof?: (input: { uid: string; challengeId: string; challengeResponse: string }) =>
    Promise<AuthorizationResult | null>;
  sealer: MaterialSealer;
  storage: StorageLike;
  authAdmin: AuthAdmin;
  config: Record<ConfigKey, boolean>;
  /** Override for tests/diagnostics; defaults to eraseBackupObjects over `storage`. */
  eraseObjects?: (uid: string) => Promise<StorageErasureResult>;
  randomId?: () => string;
}

const CONFIG_ORDER: readonly ConfigKey[] = [
  'intent_verification',
  'apple_signing',
  'token_encryption',
  'database',
  'storage_admin',
  'auth_admin',
];

// ── helpers ──────────────────────────────────────────────────────────────────

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null;
const isStr = (v: unknown): v is string => typeof v === 'string' && v.length > 0;

function base64Url(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

function defaultRandomId(): string {
  return base64Url(crypto.getRandomValues(new Uint8Array(24)));
}

/** Thrown for any RPC failure. Carries only the SQLSTATE-ish code, never provider text. */
export class RpcFailure extends Error {
  constructor(readonly fn: string, readonly code: string) {
    super(`rpc_failed:${fn}`);
  }
}

// ── adapter ──────────────────────────────────────────────────────────────────

export function createAccountDeletionAdapter(ports: AdapterPorts) {
  const randomId = ports.randomId ?? defaultRandomId;

  async function call(fn: string, args: Record<string, unknown>): Promise<unknown> {
    const res = await ports.rpc.rpc(fn, args);
    if (!isObject(res) || res.error) {
      const code = isObject(res) && isObject(res.error) && typeof res.error.code === 'string' ? res.error.code : 'rpc';
      throw new RpcFailure(fn, code);
    }
    return res.data;
  }

  // Scopes whose accept() outcome could not be fenced: findAccepted() must not
  // be trusted (it throws) so a null can never be read as nonacceptance.
  const unfenced = new Set<string>();

  // A raw adapter supports one claim attempt only, including unsuccessful
  // attempts. Its private purge binding must never be replaced by another run.
  let claimAttempted = false;
  let active: { lease: Lease; uid: string } | null = null;

  const readiness = (): ConfigReadiness => {
    const missing = CONFIG_ORDER.filter((k) => ports.config?.[k] !== true);
    return missing.length === 0 ? { ok: true } : { ok: false, missing };
  };

  // ── DeletionAuthorizer ─────────────────────────────────────────────────────

  const authorizer: DeletionAuthorizer = {
    async verifyIdentity(bearerToken: string): Promise<IdentityResult> {
      const user = await ports.identity.getUser(bearerToken);
      return user && isStr(user.id) ? { ok: true, uid: user.id } : { ok: false };
    },

    async authorizeDeletion(input): Promise<AuthorizationResult> {
      const alternate = await ports.alternateProof?.(input);
      if (alternate) return alternate;
      const verdict = await ports.apple.authorize(input);
      if (!isObject(verdict)) throw new Error('apple_authorize_malformed');
      if (verdict.status !== 'ok') {
        const code = verdict.status;
        if (
          code === 'challenge_invalid' || code === 'challenge_expired' || code === 'challenge_replayed' ||
          code === 'apple_subject_mismatch' || code === 'not_configured'
        ) return { ok: false, code };
        throw new Error('apple_authorize_unrecognised');
      }
      if (!isStr(verdict.refreshToken) || !Number.isFinite(verdict.challengeExpiresAtMs)) {
        throw new Error('apple_authorize_malformed');
      }
      // Unique reference per attempt: reference sharing between attempts never
      // happens here, so disposal can be scoped to this attempt's own reservation.
      const ref = `enc:${randomId()}`;
      const ciphertext = await ports.sealer.seal(verdict.refreshToken);
      // Reservation precedes acceptance; if this fails nothing was accepted.
      await call('account_deletion_reserve_material', { p_ref: ref, p_ciphertext: ciphertext });
      return {
        ok: true,
        verified: true,
        appleSubjectMatched: true,
        challengeExpiresAtMs: verdict.challengeExpiresAtMs,
        appleMaterialRef: ref,
      };
    },

    async disposeIfUnreferenced(appleMaterialRef: string): Promise<MaterialDisposition> {
      // A transport failure propagates: the coordinator records kept_unconfirmed.
      const data = await call('account_deletion_dispose_material', { p_ref: appleMaterialRef });
      if (
        isObject(data) &&
        (data.status === 'disposed' || data.status === 'kept_referenced' || data.status === 'kept_unconfirmed')
      ) return { status: data.status };
      return { status: 'kept_unconfirmed' };
    },
  };

  // ── DeletionStore ──────────────────────────────────────────────────────────

  const mapOutcome = (data: unknown): AcceptOutcome | null => {
    if (!isObject(data) || !isStr(data.outcome)) return null;
    switch (data.outcome) {
      case 'accepted':
      case 'duplicate':
      case 'already_pending':
        return isStr(data.job_id) ? { outcome: data.outcome, jobId: data.job_id } : null;
      case 'challenge_expired':
      case 'idempotency_conflict':
        return { outcome: data.outcome };
    }
    return null;
  };

  const leaseArgs = (lease: Lease) => ({
    p_job_id: lease.jobId,
    p_lease_token: lease.token,
    p_generation: lease.generation,
  });

  const leaseWrite = async (fn: string, args: Record<string, unknown>): Promise<LeaseWrite> => {
    const data = await call(fn, args);
    if (isObject(data) && data.ok === true) return { ok: true };
    if (isObject(data) && data.ok === false) {
      if (data.reason === 'lease_lost' || data.reason === 'out_of_order' || data.reason === 'incomplete_steps') {
        return { ok: false, reason: data.reason };
      }
    }
    // Unrecognisable: let the coordinator classify it as invalid_state.
    return data as LeaseWrite;
  };

  const store: DeletionStore = {
    async findAccepted(scopeKey) {
      if (unfenced.has(scopeKey)) throw new Error('acceptance_unfenced');
      const data = await call('account_deletion_find_accepted', { p_scope_key: scopeKey });
      if (data === null || data === undefined) return null;
      if (!isObject(data) || !isStr(data.job_id) || !isStr(data.receipt_hash)) {
        throw new Error('find_accepted_malformed');
      }
      return { jobId: data.job_id, receiptHash: data.receipt_hash };
    },

    async accept(input: AcceptInput): Promise<AcceptOutcome> {
      const attemptId = randomId();
      let failure: unknown;
      try {
        const data = await call('account_deletion_accept', {
          p_scope_key: input.scopeKey,
          p_uid: input.uid,
          p_challenge_id: input.challengeId,
          p_challenge_expires_at_ms: input.challengeExpiresAtMs,
          p_receipt_hash: input.receiptHash,
          p_apple_material_ref: input.appleMaterialRef,
          p_attempt_id: attemptId,
        });
        const mapped = mapOutcome(data);
        if (mapped) return mapped;
        failure = new Error('accept_malformed');
      } catch (e) {
        failure = e;
      }

      // The attempt may or may not have committed. Fence it.
      let fenced: unknown;
      try {
        fenced = await call('account_deletion_fence_attempt', { p_attempt_id: attemptId });
      } catch {
        unfenced.add(input.scopeKey);
        throw failure;
      }
      if (isObject(fenced) && fenced.fenced === true) {
        // Proven: this attempt can never commit. The coordinator's following
        // findAccepted() may now be trusted as nonacceptance.
        // An admin promoted mid-flow (QD031) is a definite refusal, not an outage.
        if (failure instanceof RpcFailure && failure.fn === 'account_deletion_accept' && failure.code === 'QD031') {
          return { outcome: 'admin_blocked' };
        }
        throw failure;
      }
      const committed = isObject(fenced) && fenced.fenced === false ? mapOutcome(fenced) : null;
      if (committed) return committed;
      unfenced.add(input.scopeKey);
      throw failure;
    },

    async claimLease(input): Promise<LeaseGrant | null> {
      // Latch before the first await, so even overlapping calls cannot claim.
      if (claimAttempted) throw new Error('claim_already_attempted');
      claimAttempted = true;
      const data = await call('account_deletion_claim_lease', {
        p_worker_id: input.workerId,
        p_lease_ms: input.leaseMs,
        p_job_id: input.jobId ?? null,
      });
      if (data === null || data === undefined) return null;
      if (!isObject(data) || !isObject(data.lease) || !isObject(data.job)) throw new Error('claim_malformed');
      const l = data.lease;
      const j = data.job;
      const lease: Lease = { jobId: l.job_id as string, token: l.token as string, generation: l.generation as number };
      const job: JobSnapshot = {
        jobId: j.job_id as string,
        uid: j.uid as string,
        completedSteps: j.completed_steps as DeletionStage[],
        appleMaterialRef: (j.apple_material_ref ?? null) as string | null,
        attempts: j.attempts as number,
      };
      // Remember who we are working for; the coordinator validates the grant
      // before any step, so a malformed value here never reaches a side effect.
      active = { lease: { ...lease }, uid: job.uid };
      return { lease, job };
    },

    heartbeat: (lease, leaseMs) =>
      leaseWrite('account_deletion_heartbeat', { ...leaseArgs(lease), p_lease_ms: leaseMs }),
    beginStep: (lease, stage) => leaseWrite('account_deletion_begin_step', { ...leaseArgs(lease), p_stage: stage }),
    completeStep: (lease, stage) =>
      leaseWrite('account_deletion_complete_step', { ...leaseArgs(lease), p_stage: stage }),
    recordFailure: (lease, failure: { stage: DeletionStage; code: ErrorCode; retryable: boolean; retryDelayMs: number }) =>
      leaseWrite('account_deletion_record_failure', {
        ...leaseArgs(lease),
        p_stage: failure.stage,
        p_code: failure.code,
        p_retryable: failure.retryable,
        p_retry_delay_ms: failure.retryDelayMs,
      }),
    completeJob: (lease, receiptRetentionMs) =>
      leaseWrite('account_deletion_complete_job', { ...leaseArgs(lease), p_receipt_retention_ms: receiptRetentionMs }),

    async getReceipt(receiptHash): Promise<ReceiptRecord | null> {
      const data = await call('account_deletion_get_receipt', { p_receipt_hash: receiptHash });
      if (data === null || data === undefined) return null;
      if (!isObject(data)) throw new Error('receipt_malformed');
      if (data.state === 'completed') {
        return { state: 'completed', retainedUntilMs: data.retained_until_ms as number };
      }
      return { state: data.state as 'accepted' | 'running' | 'retryable' | 'failed' };
    },
  };

  // ── DeletionSteps ──────────────────────────────────────────────────────────

  const sweep = async (uid: string): Promise<StorageOutcome> => {
    let result: StorageErasureResult;
    try {
      result = await (ports.eraseObjects ? ports.eraseObjects(uid) : eraseBackupObjects(ports.storage, uid, null));
    } catch {
      return { status: 'retryable' };
    }
    if (result.complete) return { status: 'empty_verified' };
    if (!result.retryable) return { status: 'failed' };
    return { status: result.error?.startsWith('work_limit_reached') ? 'incomplete' : 'retryable' };
  };

  const steps: DeletionSteps = {
    async revokeApple(appleMaterialRef): Promise<AppleRevokeOutcome> {
      try {
        const sealed = await call('account_deletion_read_material', { p_ref: appleMaterialRef });
        // Material missing at this point is corruption, not an outage.
        if (!isStr(sealed)) return { status: 'failed' };
        const token = await ports.sealer.unseal(sealed);
        const r = await ports.apple.revoke(token);
        return { status: r === 'revoked_verified' || r === 'failed' ? r : 'retryable' };
      } catch {
        return { status: 'retryable' };
      }
    },

    sweepStorage: (uid, _phase) => sweep(uid),

    async purgeSql(uid): Promise<StepOutcome> {
      if (!active || active.uid !== uid) return { status: 'failed' };
      try {
        const data = await call('account_deletion_purge', leaseArgs(active.lease));
        return isObject(data) && data.status === 'done' ? { status: 'done' } : { status: 'retryable' };
      } catch {
        return { status: 'retryable' };
      }
    },

    async deleteAuthUser(uid): Promise<AuthDeleteOutcome> {
      let res: { error: AuthAdminError | null };
      try {
        res = await ports.authAdmin.deleteUser(uid);
      } catch {
        return { status: 'retryable' };
      }
      const e = res?.error;
      if (!e) return { status: 'deleted' };
      if (e.status === 404) {
        // Only Auth's own user-not-found code proves absence; a bare 404 is ambiguous.
        return { status: e.code === 'user_not_found' ? 'absent_confirmed' : 'ambiguous' };
      }
      if (typeof e.status === 'number' && e.status >= 400 && e.status < 500 && e.status !== 408 && e.status !== 429) {
        return { status: 'failed' };
      }
      return { status: 'retryable' };
    },
  };

  return { authorizer, store, steps, readiness };
}

export type AccountDeletionAdapter = ReturnType<typeof createAccountDeletionAdapter>;

/** Reusable facade: acceptance/status custody persists; each worker is isolated. */
export function buildAccountDeletionCoordinator(
  ports: AdapterPorts,
  extra: { log?: (e: LogEvent) => void; options?: CoordinatorOptions } = {},
) {
  const snapshot = { ...ports, config: { ...ports.config } };
  const options = extra.options ? { ...extra.options } : undefined;
  const log = extra.log;
  const randomId = snapshot.randomId ?? defaultRandomId;
  const coordinator = () => {
    const adapter = createAccountDeletionAdapter(snapshot);
    return createAccountDeletionCoordinator({
      authorizer: adapter.authorizer,
      store: adapter.store,
      steps: adapter.steps,
      readiness: adapter.readiness,
      log,
      options,
    });
  };
  // Never use this adapter for worker calls: its unfenced-acceptance memory
  // must survive subsequent requests through the same facade.
  const requests = coordinator();
  return {
    requestDeletion: requests.requestDeletion,
    getStatus: requests.getStatus,
    // The caller's worker id is a label; invocation identity is private/fresh.
    processJob: (jobId: string, workerId: string) =>
      coordinator().processJob(jobId, `${workerId}:${randomId()}`),
    processNext: (workerId: string) => coordinator().processNext(`${workerId}:${randomId()}`),
  };
}

export { DELETION_STAGES };
