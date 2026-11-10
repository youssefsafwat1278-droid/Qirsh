// Immediate account-deletion coordinator: dependency-injected state machine.
//
// SCOPE OF THIS UNIT. Pure orchestration over injected ports. There is no
// endpoint, no migration, no SQL, no real Apple/Storage/Auth adapter and no
// wiring into purge-scheduled-deletions or the client. The existing 30-day
// schedule and its worker are untouched; nothing here accelerates them.
//
// WHAT A PASSING UNIT TEST DOES NOT PROVE. The in-memory store used by the
// tests models the contract below; it cannot establish SQL transaction
// atomicity, row-lock ordering, RLS, or that every user-linked writer honours
// the pending freeze. Only a real transactional adapter plus isolated database
// concurrency tests can. "Accepted" here means the store reported an atomic
// commit; it is not evidence that any ingress is actually frozen. This unit is
// not completed-deletion or security release proof.
//
// STORE CONTRACT (a real adapter must satisfy all of it in ONE transaction):
//   accept(): record the IMMUTABLE pending freeze for the verified UID, the
//     durable queue row, the encrypted temporary Apple material reference, the
//     hashed receipt, and the consumption of the challenge. All or nothing.
//     Idempotent on scopeKey = H(verified UID, challenge id).
//   Every lease-scoped write (heartbeat/beginStep/completeStep/recordFailure/
//     completeJob) must be conditional on (job, token, generation) matching AND
//     the lease being unexpired by the store's own clock. A replaced or expired
//     lease writes nothing. The pending freeze is never cleared by any call
//     in this interface.
//   completeJob(): refuses unless all five steps are recorded complete, and is
//     the ONLY place a receipt retention clock starts.
//   RECEIPT RETENTION. A receipt of a job that is accepted, running, retryable
//     or failed NEVER expires, however long that takes: expiring it would lose
//     the client's only handle on a deletion that is still happening. Bounded
//     retention starts only at confirmed terminal completion (completeJob).
//     The receipt lives outside every user-FK table, so purge and Auth deletion
//     cannot remove it; it holds no UID and only a hash of the lookup secret.
//   Lease and retention times are judged by the STORE's clock (database now()),
//     which is why this module takes no clock.
//   findAccepted() is the reconciliation read. A SUCCESSFUL read that returns
//     null after a failed accept() is treated as authoritative non-acceptance,
//     so the adapter must guarantee a failed accept() can no longer commit by
//     the time it reports failure (statement cancelled or transaction ended);
//     a read that throws proves nothing either way.
//
// ACCEPTANCE UNKNOWN. authorizeDeletion() may have spent the one-use Apple
// code before store.accept() is called. If accept() throws or returns something
// unrecognisable, the transaction may or may not have committed. The coordinator
// then reconciles through findAccepted():
//   found with our receipt hash -> accepted (the committed job references the
//     material; nothing is disposed);
//   found with another hash     -> idempotency_conflict, a disposal REQUEST;
//   read succeeded, nothing     -> non-acceptance, a disposal REQUEST, and the
//     caller may authorise afresh (code store_unavailable);
//   read threw                  -> code acceptance_unknown, recovery
//     'lookup_receipt': the material is RETAINED and no disposal is requested. A
//     failing lookup is never read as non-acceptance. The client must poll
//     getStatus(receiptSecret) or repeat the same request, not authorise afresh
//     (note: getStatus 'unknown' is only meaningful once reconciliation has
//     succeeded; 'unavailable' means the lookup itself failed).
//
// MATERIAL CUSTODY (the coordinator can never know who else holds a reference).
// Neither AcceptOutcome nor findAccepted reveals the WINNING job's material
// reference, and an idempotent authorizer may legitimately hand the same
// reference to a duplicate, a concurrent identical request, a fresh challenge for
// the same account, or a conflicting retry. So the coordinator never decides that
// material is "different" or "unused". It only ever REQUESTS disposal, through
// authorizer.disposeIfUnreferenced(ref), after a known non-acceptance, duplicate,
// already_pending, conflict or expiry. That operation is the adapter's to make
// safe, and must be:
//   (a) ATOMIC and REFERENCE-AWARE: it destroys the material only if no committed
//       job references it AND no acceptance or reservation that could still
//       commit holds it (including a concurrent request that received the same
//       reference). Otherwise it keeps it ('kept_referenced'). Where it cannot
//       establish that, it keeps it too ('kept_unconfirmed'): keep-safe, never
//       "destroy when unsure". Tokenless by-reference counting is only sound
//       because this module calls it at most once per attempt; a real adapter
//       should key cleanup by a per-attempt reservation id.
//   (b) SERIALIZED with the reference/acceptance lifecycle in the same system as
//       store.accept(), and a commit against material already disposed must be
//       impossible (accept must fail rather than reference destroyed material).
//       A stale or late disposal request must not be able to destroy material
//       that a newer acceptance now references.
//   (c) STRUCTURED: it returns { status: 'disposed' | 'kept_referenced' |
//       'kept_unconfirmed' }. The coordinator validates the shape; a throw or a
//       malformed answer counts as 'kept_unconfirmed'. The outcome is only
//       logged as an enumerated value: it never changes the accepted/pending
//       result, and provider or cleanup error text is never surfaced or logged.
// Unknown acceptance requests no disposal at all (material retained). The
// remaining adapter contract: the material is encrypted at rest with a key the
// coordinator never sees and is never in plaintext anywhere, including logs and
// error text (the "enc:" prefix check below is only a sanity guard against an
// obviously plaintext token, NOT evidence of encryption); material for a
// possibly-committed acceptance stays readable until apple_revoke completes; and
// the adapter expires unreferenced material by its own TTL, because a disposal
// request can fail or the process can die first. THIS UNIT IMPLEMENTS NONE OF
// THAT: no SQL, no KMS, no real Apple or cleanup backend. The mock reference
// registry in the tests models the property; it does not prove it.
//
// RECEIPT CAPABILITY. The lookup secret is generated by the CLIENT and sent
// with the request; the server keeps only its hash. That is what lets a client
// whose response was lost still query status, which a server-generated secret
// could not offer. The format check below validates ALPHABET AND LENGTH ONLY;
// it cannot establish randomness. The future client must produce it with a
// CSPRNG (for example 32 random bytes, base64url) and a weak-but-well-formed
// value would pass. Status lookups return the same "unknown" for never-issued,
// expired and malformed secrets, so there is no account-existence oracle.
// Endpoint rate limiting of status lookups is the future endpoint's job.
//
// LEASE SEMANTICS. Lease checks fence BOOKKEEPING; they do not cancel an
// externally dispatched call. The lease is checked (heartbeat, then the
// conditional beginStep) immediately before each side effect, and completion is
// a further conditional write. Neither response guarantees the lease is still
// valid once the await returns: it can lapse or be replaced between the store's
// answer and the dispatch of the external call. That window is irreducible. The
// design answer is idempotent replay, not prevention: a call dispatched under a
// lost lease is never treated as cancelled, its bookkeeping is simply not
// written, and the next holder repeats the step, which therefore must be
// idempotent. Apple revocation idempotency on a repeated call is an assumption
// about the real adapter that this unit cannot verify.
//
// VALIDATION. Every positive response from a port is shape-checked before it is
// trusted or acted on (identity UID, lease/job agreement, ordered completed
// steps and material reference, receipt state and expiry). A malformed response
// is reported as invalid_state / unavailable, never as ordinary pending, and
// before any destructive call. Logging and readiness are non-essential or
// fail-closed: a throwing logger never changes control flow, and a throwing or
// malformed readiness reports not_configured.

export const DELETION_STAGES = [
  'apple_revoke',
  'storage_sweep',
  'sql_purge',
  'auth_delete',
  'terminal_storage',
] as const;
export type DeletionStage = (typeof DELETION_STAGES)[number];

export type ConfigKey =
  | 'intent_verification'
  | 'apple_signing'
  | 'token_encryption'
  | 'database'
  | 'storage_admin'
  | 'auth_admin';

export type ErrorCode =
  | 'invalid_request'
  | 'unauthenticated'
  | 'not_configured'
  | 'challenge_invalid'
  | 'challenge_expired'
  | 'challenge_replayed'
  | 'apple_subject_mismatch'
  | 'authorization_unavailable'
  | 'idempotency_conflict'
  | 'admin_self_delete_blocked'
  | 'store_unavailable'
  | 'acceptance_unknown'
  | 'invalid_store_response'
  | 'apple_material_missing'
  | 'apple_revoke_retryable'
  | 'apple_revoke_rejected'
  | 'storage_incomplete'
  | 'storage_error'
  | 'sql_purge_error'
  | 'auth_delete_ambiguous'
  | 'auth_delete_error'
  | 'terminal_storage_incomplete'
  | 'terminal_storage_error'
  | 'unexpected';

// ── Ports ────────────────────────────────────────────────────────────────────

export type ConfigReadiness = { ok: true } | { ok: false; missing: readonly ConfigKey[] };

export type IdentityResult = { ok: true; uid: string } | { ok: false };

export type AuthorizationResult =
  | {
    ok: true;
    // Literal flags: a result is only accepted when the audited adapter states
    // that it validated the one-use bound intent AND the Apple subject.
    verified: true;
    appleSubjectMatched: true;
    challengeExpiresAtMs: number;
    // Opaque reference to ENCRYPTED temporary Apple material ("enc:..."). The
    // plaintext code/token never crosses this port. See ACCEPTANCE UNKNOWN.
    appleMaterialRef: string;
  }
  | {
    ok: true;
    verified: true;
    alternateProofMatched: true;
    challengeExpiresAtMs: number;
    appleMaterialRef: null;
  }
  | {
    ok: false;
    code:
      | 'challenge_invalid'
      | 'challenge_expired'
      | 'challenge_replayed'
      | 'apple_subject_mismatch'
      | 'not_configured';
  };

export interface DeletionAuthorizer {
  /** Resolves the bearer credential against Auth. The UID is never client-supplied. */
  verifyIdentity(bearerToken: string): Promise<IdentityResult>;
  /**
   * Validates, for the already-verified `uid`: the challenge is bound to that
   * UID and the confirmed deletion intent, is fresh and unconsumed; the fresh
   * Apple proof matches the account's stored Apple subject. Exchanges the
   * one-use Apple code into encrypted material. Must not match by email.
   */
  authorizeDeletion(input: {
    uid: string;
    challengeId: string;
    challengeResponse: string;
  }): Promise<AuthorizationResult>;
  /**
   * Requests disposal of the material THIS attempt received. Atomic and
   * reference-aware (see MATERIAL CUSTODY): destroys only when nothing committed
   * or still able to commit references it; otherwise keeps it. Called after a
   * known non-acceptance, duplicate, already_pending, conflict or expiry; never
   * while acceptance is unknown.
   */
  disposeIfUnreferenced(appleMaterialRef: string): Promise<MaterialDisposition>;
}

export type MaterialDisposition = {
  status: 'disposed' | 'kept_referenced' | 'kept_unconfirmed';
};

export type AcceptInput = {
  scopeKey: string;
  uid: string;
  challengeId: string;
  challengeExpiresAtMs: number;
  receiptHash: string;
  appleMaterialRef: string | null;
};

export type AcceptOutcome =
  | { outcome: 'accepted'; jobId: string }
  | { outcome: 'duplicate'; jobId: string }
  // The UID already has a job (fresh challenge after a crash): the new receipt
  // hash is attached to it; no second job or freeze is created.
  | { outcome: 'already_pending'; jobId: string }
  | { outcome: 'challenge_expired' }
  | { outcome: 'idempotency_conflict' }
  // The account was promoted to admin after authorization (SQLSTATE QD031).
  // Only ever returned by a store once the attempt is proven fenced.
  | { outcome: 'admin_blocked' };

export type Lease = { jobId: string; token: string; generation: number };
export type JobSnapshot = {
  jobId: string;
  uid: string; // server-side only; never logged or returned
  completedSteps: readonly DeletionStage[];
  appleMaterialRef: string | null;
  attempts: number;
};
export type LeaseGrant = { lease: Lease; job: JobSnapshot };
export type LeaseWrite =
  | { ok: true }
  | { ok: false; reason: 'lease_lost' | 'out_of_order' | 'incomplete_steps' };

export type JobState = 'accepted' | 'running' | 'retryable' | 'failed' | 'completed';
// Only a completed job has an expiry. A non-terminal record carrying one is a
// contract violation and is rejected by the coordinator.
export type ReceiptRecord =
  | { state: 'accepted' | 'running' | 'retryable' | 'failed' }
  | { state: 'completed'; retainedUntilMs: number };

export interface DeletionStore {
  findAccepted(scopeKey: string): Promise<{ jobId: string; receiptHash: string } | null>;
  accept(input: AcceptInput): Promise<AcceptOutcome>;
  claimLease(input: { workerId: string; leaseMs: number; jobId?: string }): Promise<LeaseGrant | null>;
  heartbeat(lease: Lease, leaseMs: number): Promise<LeaseWrite>;
  beginStep(lease: Lease, stage: DeletionStage): Promise<LeaseWrite>;
  /** Also destroys the encrypted Apple material reference when stage is apple_revoke. */
  completeStep(lease: Lease, stage: DeletionStage): Promise<LeaseWrite>;
  recordFailure(
    lease: Lease,
    failure: { stage: DeletionStage; code: ErrorCode; retryable: boolean; retryDelayMs: number },
  ): Promise<LeaseWrite>;
  /** Starts the receipt retention clock (store time + receiptRetentionMs). */
  completeJob(lease: Lease, receiptRetentionMs: number): Promise<LeaseWrite>;
  /** null for unknown AND expired: the two must be indistinguishable. */
  getReceipt(receiptHash: string): Promise<ReceiptRecord | null>;
}

// Step outcomes are enumerated; adapters return no free text, so provider
// error messages cannot reach persistence, logs or responses.
export type StepOutcome = { status: 'done' | 'retryable' | 'failed' };
export type AppleRevokeOutcome = { status: 'revoked_verified' | 'retryable' | 'failed' };
export type StorageOutcome = { status: 'empty_verified' | 'incomplete' | 'retryable' | 'failed' };
// 'absent_confirmed' requires the adapter to have confirmed absence from an
// authoritative source (Auth's user-not-found code or a lookup). A bare or
// generic 404 must be returned as 'ambiguous', which is never success.
export type AuthDeleteOutcome = {
  status: 'deleted' | 'absent_confirmed' | 'ambiguous' | 'retryable' | 'failed';
};

export interface DeletionSteps {
  revokeApple(appleMaterialRef: string): Promise<AppleRevokeOutcome>;
  sweepStorage(uid: string, phase: 'pre_sql' | 'terminal'): Promise<StorageOutcome>;
  purgeSql(uid: string): Promise<StepOutcome>;
  deleteAuthUser(uid: string): Promise<AuthDeleteOutcome>;
}

export type LogEvent = {
  event:
    | 'accepted'
    | 'duplicate'
    | 'lease_claimed'
    | 'lease_lost'
    | 'stage_done'
    | 'stage_failed'
    | 'completed'
    | 'aborted'
    | 'material_disposition';
  job?: string; // opaque job id, never a UID
  disposition?: MaterialDisposition['status']; // enumerated; never a reference or error text
  stage?: DeletionStage;
  code?: ErrorCode;
};

export type CoordinatorOptions = {
  leaseMs?: number;
  receiptRetentionMs?: number;
  retryBaseMs?: number;
  retryMaxMs?: number;
};

export type CoordinatorDeps = {
  authorizer: DeletionAuthorizer;
  store: DeletionStore;
  steps: DeletionSteps;
  readiness: () => ConfigReadiness;
  log?: (event: LogEvent) => void;
  sha256Hex?: (value: string) => Promise<string>;
  options?: CoordinatorOptions;
};

// ── Public shapes ────────────────────────────────────────────────────────────

export type DeletionRequest = {
  bearerToken: string;
  challengeId: string;
  challengeResponse: string;
  receiptSecret: string;
};

export type RequestResult =
  // jobId is an opaque random id for the server-side caller to start processing;
  // an endpoint must forward only the receipt capability, never this id.
  | { status: 'accepted'; duplicate: boolean; jobId: string }
  // `recovery` is present only when acceptance is UNKNOWN: look the receipt up
  // (getStatus) or repeat the same request; do not authorise afresh.
  | { status: 'error'; code: ErrorCode; retryable: boolean; recovery?: 'lookup_receipt' };

export type PublicStatus =
  | { status: 'accepted' | 'pending' }
  | { status: 'completed'; retainedUntilMs: number }
  // Never issued, expired, or malformed secret: indistinguishable on purpose.
  | { status: 'unknown' }
  // The lookup failed or returned an invalid record. NOT proof of non-acceptance.
  | { status: 'unavailable' };

export type RunOutcome =
  | { outcome: 'completed' }
  | { outcome: 'retry_scheduled'; stage: DeletionStage; code: ErrorCode }
  | { outcome: 'failed'; stage: DeletionStage; code: ErrorCode }
  | { outcome: 'lease_lost' }
  | { outcome: 'aborted' }
  // A port returned a malformed or self-contradicting response; nothing further
  // was done. Not an ordinary retry.
  | { outcome: 'invalid_state' }
  | { outcome: 'no_work' };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Format and length only. This does NOT establish randomness (see header).
const RECEIPT_SECRET_RE = /^[A-Za-z0-9_-]{43,128}$/;
const CHALLENGE_ID_RE = /^[A-Za-z0-9_-]{8,128}$/;
// Sanity guard only; NOT evidence that the referenced material is encrypted.
const MATERIAL_REF_RE = /^enc:[A-Za-z0-9_.:-]{8,256}$/;

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;
const DEFAULTS = {
  leaseMs: 60_000,
  receiptRetentionMs: 30 * DAY_MS,
  retryBaseMs: 30_000,
  retryMaxMs: HOUR_MS,
};

async function defaultSha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

const err = (
  code: ErrorCode,
  retryable: boolean,
  recovery?: 'lookup_receipt',
): RequestResult => ({
  status: 'error',
  code,
  retryable,
  ...(recovery ? { recovery } : {}),
});

const AUTH_CODES: ReadonlySet<string> = new Set([
  'challenge_invalid',
  'challenge_expired',
  'challenge_replayed',
  'apple_subject_mismatch',
  'not_configured',
]);

type Attempt<T> = { ok: true; value: T } | { ok: false };
async function attempt<T>(fn: () => Promise<T>): Promise<Attempt<T>> {
  try {
    return { ok: true, value: await fn() };
  } catch {
    // The thrown value is deliberately dropped: it may carry provider text.
    return { ok: false };
  }
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null;
const isNonEmptyString = (v: unknown): v is string => typeof v === 'string' && v.length > 0;

function resolveOptions(o: CoordinatorOptions | undefined) {
  // An explicit undefined means "default"; NaN/Infinity/non-numbers never do.
  const pick = (v: number | undefined, d: number) => (v === undefined ? d : v);
  const r = {
    leaseMs: pick(o?.leaseMs, DEFAULTS.leaseMs),
    receiptRetentionMs: pick(o?.receiptRetentionMs, DEFAULTS.receiptRetentionMs),
    retryBaseMs: pick(o?.retryBaseMs, DEFAULTS.retryBaseMs),
    retryMaxMs: pick(o?.retryMaxMs, DEFAULTS.retryMaxMs),
  };
  const within = (v: unknown, min: number, max: number) =>
    typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max;
  if (!within(r.leaseMs, 5_000, 300_000)) throw new Error('invalid_lease_ms');
  if (!within(r.receiptRetentionMs, HOUR_MS, 90 * DAY_MS)) {
    throw new Error('invalid_receipt_retention_ms');
  }
  if (!within(r.retryBaseMs, 1, DAY_MS) || !within(r.retryMaxMs, r.retryBaseMs, DAY_MS)) {
    throw new Error('invalid_retry_options');
  }
  return r;
}

export function createAccountDeletionCoordinator(deps: CoordinatorDeps) {
  const { authorizer, store, steps } = deps;
  const sha256Hex = deps.sha256Hex ?? defaultSha256Hex;
  const opts = resolveOptions(deps.options);

  // Logging is non-essential: it can never throw into, delay, or alter control
  // flow, including on the catch paths below.
  const log = (event: LogEvent): void => {
    try {
      const out = deps.log?.(event) as unknown;
      if (isObject(out) && typeof out.then === 'function') {
        (out as unknown as PromiseLike<unknown>).then(undefined, () => {});
      }
    } catch {
      // swallowed on purpose
    }
  };

  // Fail closed: a throwing or malformed readiness is "not configured".
  const isReady = (): boolean => {
    try {
      const r = deps.readiness() as unknown;
      return isObject(r) && r.ok === true;
    } catch {
      return false;
    }
  };

  const receiptHashOf = (secret: string) => sha256Hex(`qirsh-del-receipt-v1\n${secret}`);
  const scopeKeyOf = (uid: string, challengeId: string) =>
    sha256Hex(`qirsh-del-scope-v1\n${uid}\n${challengeId}`);
  const retryDelay = (attempts: number) =>
    Math.min(opts.retryBaseMs * 2 ** Math.min(attempts, 30), opts.retryMaxMs);

  // Requests reference-aware disposal and records ONLY an enumerated outcome.
  // Keep-safe: a throw or malformed answer is 'kept_unconfirmed'. It never throws,
  // never alters the caller's result, and never logs the reference or any error.
  const releaseMaterial = async (ref: string | null): Promise<void> => {
    if (ref === null) return;
    let disposition: MaterialDisposition['status'] = 'kept_unconfirmed';
    try {
      const out = await authorizer.disposeIfUnreferenced(ref) as unknown;
      if (
        isObject(out) &&
        (out.status === 'disposed' || out.status === 'kept_referenced' || out.status === 'kept_unconfirmed')
      ) disposition = out.status;
    } catch {
      // swallowed: the adapter also expires unreferenced material by TTL
    }
    log({ event: 'material_disposition', disposition });
  };

  const validFound = (v: unknown): v is { jobId: string; receiptHash: string } =>
    isObject(v) && isNonEmptyString(v.jobId) && isNonEmptyString(v.receiptHash);

  // Only the fields below are ever read from the request: a client-supplied
  // uid/email/target property is not part of the type and is never forwarded.
  async function requestDeletion(req: DeletionRequest): Promise<RequestResult> {
    const bearerToken = typeof req?.bearerToken === 'string' ? req.bearerToken.trim() : '';
    if (!bearerToken) return err('unauthenticated', false);
    const { challengeId, challengeResponse, receiptSecret } = req;
    if (
      typeof challengeId !== 'string' || !CHALLENGE_ID_RE.test(challengeId) ||
      typeof challengeResponse !== 'string' || !challengeResponse ||
      typeof receiptSecret !== 'string' || !RECEIPT_SECRET_RE.test(receiptSecret)
    ) return err('invalid_request', false);

    // Fail closed before any side effect when a dependency is unconfigured.
    if (!isReady()) return err('not_configured', false);

    const identity = await attempt(() => authorizer.verifyIdentity(bearerToken));
    if (!identity.ok) return err('authorization_unavailable', true);
    const id = identity.value as unknown;
    if (!isObject(id) || id.ok !== true || typeof id.uid !== 'string' || !UUID_RE.test(id.uid)) {
      return err('unauthenticated', false);
    }
    const uid = id.uid;

    const hashes = await attempt(async () => ({
      receiptHash: await receiptHashOf(receiptSecret),
      scopeKey: await scopeKeyOf(uid, challengeId),
    }));
    if (!hashes.ok) return err('unexpected', true);
    const { receiptHash, scopeKey } = hashes.value;

    // A retry after a lost response must not re-run the one-use Apple exchange.
    // Nothing has been spent yet, so a lookup outage here is plainly retryable.
    const existing = await attempt(() => store.findAccepted(scopeKey));
    if (!existing.ok) return err('store_unavailable', true);
    if (existing.value !== null) {
      if (!validFound(existing.value)) return err('store_unavailable', true);
      if (existing.value.receiptHash !== receiptHash) return err('idempotency_conflict', false);
      log({ event: 'duplicate', job: existing.value.jobId });
      return { status: 'accepted', duplicate: true, jobId: existing.value.jobId };
    }

    const authz = await attempt(() => authorizer.authorizeDeletion({ uid, challengeId, challengeResponse }));
    if (!authz.ok) return err('authorization_unavailable', true);
    const a = authz.value as unknown;
    if (!isObject(a) || a.ok !== true) {
      const code = isObject(a) && a.ok === false && typeof a.code === 'string' && AUTH_CODES.has(a.code)
        ? a.code as ErrorCode
        : 'authorization_unavailable';
      return err(code, code === 'authorization_unavailable');
    }
    // Never accept a success the audited adapter did not positively assert.
    const appleMaterial = a.appleSubjectMatched === true &&
      typeof a.appleMaterialRef === 'string' && MATERIAL_REF_RE.test(a.appleMaterialRef);
    const alternateProof = a.alternateProofMatched === true && a.appleMaterialRef === null;
    if (
      a.verified !== true || (!appleMaterial && !alternateProof) ||
      typeof a.challengeExpiresAtMs !== 'number' || !Number.isFinite(a.challengeExpiresAtMs)
    ) return err('authorization_unavailable', false);
    const challengeExpiresAtMs = a.challengeExpiresAtMs;
    const appleMaterialRef = a.appleMaterialRef as string | null;

    // From here the one-use Apple code may be spent. Any doubt about whether the
    // accept committed is resolved by reconciliation, never by guessing.
    const accepted = await attempt(() =>
      store.accept({
        scopeKey,
        uid,
        challengeId,
        challengeExpiresAtMs,
        receiptHash,
        appleMaterialRef,
      })
    );
    const out = accepted.ok ? accepted.value as unknown : null;
    if (isObject(out) && isNonEmptyString(out.outcome)) {
      switch (out.outcome) {
        case 'accepted':
          if (isNonEmptyString(out.jobId)) {
            log({ event: 'accepted', job: out.jobId });
            return { status: 'accepted', duplicate: false, jobId: out.jobId };
          }
          break;
        case 'duplicate':
        case 'already_pending':
          // Another acceptance won. Whether it references the SAME material is
          // unknown to us, so this is only a request; the adapter decides.
          if (isNonEmptyString(out.jobId)) {
            await releaseMaterial(appleMaterialRef);
            log({ event: 'duplicate', job: out.jobId });
            return { status: 'accepted', duplicate: true, jobId: out.jobId };
          }
          break;
        case 'challenge_expired':
          await releaseMaterial(appleMaterialRef);
          return err('challenge_expired', false);
        case 'idempotency_conflict':
          await releaseMaterial(appleMaterialRef);
          return err('idempotency_conflict', false);
        case 'admin_blocked':
          await releaseMaterial(appleMaterialRef);
          return err('admin_self_delete_blocked', false);
      }
    }
    return await reconcileAcceptance(scopeKey, receiptHash, appleMaterialRef);
  }

  async function reconcileAcceptance(
    scopeKey: string,
    receiptHash: string,
    appleMaterialRef: string | null,
  ): Promise<RequestResult> {
    const found = await attempt(() => store.findAccepted(scopeKey));
    // The read itself failed or was malformed: acceptance is UNKNOWN. Retain the
    // material; do not tell the client to authorise afresh.
    if (!found.ok || (found.value !== null && !validFound(found.value))) {
      log({ event: 'aborted', code: 'acceptance_unknown' });
      return err('acceptance_unknown', true, 'lookup_receipt');
    }
    if (found.value === null) {
      // Non-acceptance (relies on the store contract that a failed accept can no
      // longer commit). Another identical attempt may still hold the same material,
      // so this is a reference-aware disposal request, not a deletion.
      await releaseMaterial(appleMaterialRef);
      return err('store_unavailable', true);
    }
    if (found.value.receiptHash !== receiptHash) {
      await releaseMaterial(appleMaterialRef);
      return err('idempotency_conflict', false);
    }
    // Committed after all (response lost): the job references the material, so
    // no disposal is requested.
    log({ event: 'duplicate', job: found.value.jobId });
    return { status: 'accepted', duplicate: true, jobId: found.value.jobId };
  }

  async function getStatus(receiptSecret: string): Promise<PublicStatus> {
    if (typeof receiptSecret !== 'string' || !RECEIPT_SECRET_RE.test(receiptSecret)) {
      return { status: 'unknown' };
    }
    const looked = await attempt(async () => store.getReceipt(await receiptHashOf(receiptSecret)));
    if (!looked.ok) return { status: 'unavailable' };
    const rec = looked.value as unknown;
    if (rec === null) return { status: 'unknown' };
    if (!isObject(rec)) return { status: 'unavailable' };
    if (rec.state === 'completed') {
      return typeof rec.retainedUntilMs === 'number' && Number.isFinite(rec.retainedUntilMs)
        ? { status: 'completed', retainedUntilMs: rec.retainedUntilMs }
        : { status: 'unavailable' };
    }
    if (
      rec.state !== 'accepted' && rec.state !== 'running' && rec.state !== 'retryable' &&
      rec.state !== 'failed'
    ) return { status: 'unavailable' };
    // A non-terminal job must not carry an expiry.
    if (rec.retainedUntilMs !== undefined) return { status: 'unavailable' };
    // Failures and retries are deliberately reported as plain "pending".
    return { status: rec.state === 'accepted' ? 'accepted' : 'pending' };
  }

  async function perform(
    stage: DeletionStage,
    job: JobSnapshot,
  ): Promise<{ done: true } | { done: false; code: ErrorCode; retryable: boolean }> {
    const fail = (code: ErrorCode, retryable: boolean) => ({ done: false as const, code, retryable });
    switch (stage) {
      case 'apple_revoke': {
        if (!job.appleMaterialRef) return fail('apple_material_missing', false);
        const r = await steps.revokeApple(job.appleMaterialRef);
        if (r?.status === 'revoked_verified') return { done: true };
        if (r?.status === 'failed') return fail('apple_revoke_rejected', false);
        return fail('apple_revoke_retryable', true);
      }
      case 'storage_sweep':
      case 'terminal_storage': {
        const terminal = stage === 'terminal_storage';
        const r = await steps.sweepStorage(job.uid, terminal ? 'terminal' : 'pre_sql');
        if (r?.status === 'empty_verified') return { done: true };
        if (r?.status === 'incomplete') {
          return fail(terminal ? 'terminal_storage_incomplete' : 'storage_incomplete', true);
        }
        return fail(terminal ? 'terminal_storage_error' : 'storage_error', r?.status !== 'failed');
      }
      case 'sql_purge': {
        const r = await steps.purgeSql(job.uid);
        if (r?.status === 'done') return { done: true };
        return fail('sql_purge_error', r?.status !== 'failed');
      }
      case 'auth_delete': {
        const r = await steps.deleteAuthUser(job.uid);
        if (r?.status === 'deleted' || r?.status === 'absent_confirmed') return { done: true };
        if (r?.status === 'ambiguous') return fail('auth_delete_ambiguous', true);
        return fail('auth_delete_error', r?.status !== 'failed');
      }
    }
  }

  // Validates a claimed grant before any step. Returns null when it is malformed
  // or contradicts itself or the request.
  function validateGrant(raw: unknown, requestedJobId: string | undefined): LeaseGrant | null {
    if (!isObject(raw) || !isObject(raw.lease) || !isObject(raw.job)) return null;
    const { lease, job } = raw as { lease: Record<string, unknown>; job: Record<string, unknown> };
    if (
      !isNonEmptyString(lease.jobId) || !isNonEmptyString(lease.token) ||
      !Number.isInteger(lease.generation) || (lease.generation as number) < 1
    ) return null;
    if (job.jobId !== lease.jobId) return null;
    if (requestedJobId !== undefined && lease.jobId !== requestedJobId) return null;
    if (typeof job.uid !== 'string' || !UUID_RE.test(job.uid)) return null;
    if (!Number.isInteger(job.attempts) || (job.attempts as number) < 0) return null;
    const done = job.completedSteps;
    // Strictly an ordered prefix of the saga: no gaps, repeats or unknown stages.
    if (
      !Array.isArray(done) || done.length > DELETION_STAGES.length ||
      !done.every((s, i) => s === DELETION_STAGES[i])
    ) return null;
    const ref = job.appleMaterialRef;
    if (done.length > 0) {
      // Apple revocation recorded: its temporary material must already be gone.
      if (ref !== null) return null;
    } else if (ref !== null && (typeof ref !== 'string' || !MATERIAL_REF_RE.test(ref))) {
      return null;
    }
    return raw as unknown as LeaseGrant;
  }

  // 'ok' | 'lease_lost' | 'invalid' for any lease-scoped write response.
  function classify(w: unknown): 'ok' | 'lease_lost' | 'invalid' {
    if (!isObject(w)) return 'invalid';
    if (w.ok === true) return 'ok';
    if (w.ok === false && w.reason === 'lease_lost') return 'lease_lost';
    return 'invalid';
  }

  async function runLeased(rawGrant: unknown, requestedJobId: string | undefined): Promise<RunOutcome> {
    const grant = validateGrant(rawGrant, requestedJobId);
    if (!grant) {
      // The lease (if any) simply expires; no step has been taken.
      log({ event: 'aborted', code: 'invalid_store_response' });
      return { outcome: 'invalid_state' };
    }
    const { lease, job } = grant;
    const jobRef = lease.jobId;
    log({ event: 'lease_claimed', job: jobRef });

    // Maps a write response to a terminal outcome, or null to continue.
    const stop = (w: unknown, stage?: DeletionStage): RunOutcome | null => {
      const verdict = classify(w);
      if (verdict === 'ok') return null;
      if (verdict === 'lease_lost') {
        log({ event: 'lease_lost', job: jobRef, ...(stage ? { stage } : {}) });
        return { outcome: 'lease_lost' };
      }
      log({ event: 'aborted', job: jobRef, code: 'invalid_store_response' });
      return { outcome: 'invalid_state' };
    };

    try {
      const pendingStage = DELETION_STAGES.find((s) => !job.completedSteps.includes(s));
      const failWith = async (
        stage: DeletionStage,
        code: ErrorCode,
        retryable: boolean,
      ): Promise<RunOutcome> => {
        const written = await store.recordFailure(lease, {
          stage,
          code,
          retryable,
          retryDelayMs: retryDelay(job.attempts),
        });
        const halted = stop(written, stage);
        if (halted) return halted;
        log({ event: 'stage_failed', job: jobRef, stage, code });
        return retryable
          ? { outcome: 'retry_scheduled', stage, code }
          : { outcome: 'failed', stage, code };
      };

      if (pendingStage && !isReady()) return await failWith(pendingStage, 'not_configured', true);

      for (const stage of DELETION_STAGES) {
        if (job.completedSteps.includes(stage)) continue;

        // Check the lease immediately before the side effect: a replaced or
        // expired holder must not START a step. This is a bookkeeping fence, not
        // a guarantee: the lease can still lapse after these awaits return, and
        // a call dispatched in that window is repeated by the next holder.
        const halted1 = stop(await store.heartbeat(lease, opts.leaseMs), stage);
        if (halted1) return halted1;
        const halted2 = stop(await store.beginStep(lease, stage), stage);
        if (halted2) return halted2;

        let result: Awaited<ReturnType<typeof perform>>;
        try {
          result = await perform(stage, job);
        } catch {
          result = { done: false, code: 'unexpected', retryable: true };
        }
        if (!result.done) return await failWith(stage, result.code, result.retryable);

        // The call may have been dispatched under a lease that has since been
        // replaced; this write is conditional again and simply does not land.
        const halted3 = stop(await store.completeStep(lease, stage), stage);
        if (halted3) return halted3;
        log({ event: 'stage_done', job: jobRef, stage });
      }

      const halted4 = stop(await store.completeJob(lease, opts.receiptRetentionMs));
      if (halted4) return halted4;
      log({ event: 'completed', job: jobRef });
      return { outcome: 'completed' };
    } catch {
      // Store failure mid-run: nothing is claimed. The lease expires and the
      // job is re-claimed; every step is idempotent.
      log({ event: 'aborted', job: jobRef, code: 'store_unavailable' });
      return { outcome: 'aborted' };
    }
  }

  async function claimAndRun(workerId: string, jobId?: string): Promise<RunOutcome> {
    const claimed = await attempt(() => store.claimLease({ workerId, leaseMs: opts.leaseMs, jobId }));
    if (!claimed.ok) return { outcome: 'aborted' };
    if (claimed.value === null) return { outcome: 'no_work' };
    return await runLeased(claimed.value, jobId);
  }

  return {
    requestDeletion,
    getStatus,
    /** Request path: run one specific accepted job (e.g. immediately after acceptance). */
    processJob: (jobId: string, workerId: string) => claimAndRun(workerId, jobId),
    /** Recovery path: run the next runnable job, if any. */
    processNext: (workerId: string) => claimAndRun(workerId),
  };
}
