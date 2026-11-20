// MALI-060n — shared contract for AI / paid / enrichment edge endpoints.
//
// One place for the things every such endpoint must do BEFORE it spends money
// or touches sensitive data:
//   * a safe, typed error envelope (never a raw exception / upstream body);
//   * verified identity resolution — a server-verified device secret or a real
//     user JWT, NEVER a caller-supplied install_id (which is rotatable and thus
//     unmetered); install_id alone is non-authoritative compatibility metadata;
//   * server-side consent enforcement from the verified record (fail-closed);
//   * bounded JSON body parsing + schema-version gating;
//   * a request correlation id that is NOT an identity, and structured logging
//     that carries only safe fields.
//
// Endpoint index.ts files stay thin wrappers over these helpers so the security
// logic is unit-tested here (ci_gates runs `deno test _shared/`).
import { corsHeaders, installHash, readString, serviceClient, sha256Hex, timingSafeEqual } from './capture_auth.ts';

// ── Typed error envelope ────────────────────────────────────────────────────

export type ApiErrorCode =
  | 'authentication_required'
  | 'invalid_device_credential'
  | 'credential_revoked'
  | 'consent_required'
  | 'rate_limited'
  | 'payload_too_large'
  | 'invalid_payload'
  | 'unsupported_schema'
  | 'request_replay_mismatch'
  | 'upstream_timeout'
  | 'upstream_unavailable'
  | 'upstream_rejected'
  | 'internal_error';

const STATUS: Record<ApiErrorCode, number> = {
  authentication_required: 401,
  invalid_device_credential: 401,
  credential_revoked: 401,
  consent_required: 403,
  rate_limited: 429,
  payload_too_large: 413,
  invalid_payload: 400,
  unsupported_schema: 400,
  request_replay_mismatch: 409,
  upstream_timeout: 504,
  upstream_unavailable: 503,
  upstream_rejected: 502,
  internal_error: 500,
};

// Whether a client should retry by default (a client may still override with an
// explicit retryable flag). Auth/consent/validation failures are not retryable;
// transient upstream/internal ones are.
const DEFAULT_RETRYABLE: Record<ApiErrorCode, boolean> = {
  authentication_required: false,
  invalid_device_credential: false,
  credential_revoked: false,
  consent_required: false,
  rate_limited: true,
  payload_too_large: false,
  invalid_payload: false,
  unsupported_schema: false,
  request_replay_mismatch: false,
  upstream_timeout: true,
  upstream_unavailable: true,
  upstream_rejected: false,
  internal_error: true,
};

/// Bound on any advertised retry-after so a bug/upstream cannot ask a client to
/// back off for an unreasonable time.
export const MAX_RETRY_AFTER_SECONDS = 3600;

/// Current request schema version. Absent `schema_version` is treated as v1 for
/// backward compatibility; any other value is rejected as unsupported.
export const SCHEMA_VERSION = 1;

export interface ApiErrorInit {
  correlationId: string;
  retryable?: boolean;
  retryAfterSeconds?: number;
  supportedSchemaVersion?: number;
}

/// Builds a safe error Response. The body carries ONLY: the stable error code,
/// a retryable flag, the correlation id, and (optionally) a bounded retry-after
/// and the supported schema version. Never a raw message or upstream body.
export function apiError(code: ApiErrorCode, init: ApiErrorInit): Response {
  const headers: Record<string, string> = {
    ...corsHeaders,
    'Content-Type': 'application/json',
  };
  const body: Record<string, unknown> = {
    error: code,
    retryable: init.retryable ?? DEFAULT_RETRYABLE[code],
    correlation_id: init.correlationId,
  };
  if (init.retryAfterSeconds != null) {
    const bounded = Math.min(
      Math.max(0, Math.floor(init.retryAfterSeconds)),
      MAX_RETRY_AFTER_SECONDS,
    );
    body.retry_after_seconds = bounded;
    headers['Retry-After'] = String(bounded);
  }
  if (init.supportedSchemaVersion != null) {
    body.supported_schema_version = init.supportedSchemaVersion;
  }
  return new Response(JSON.stringify(body), { status: STATUS[code], headers });
}

// ── Correlation id + safe logging ───────────────────────────────────────────

/// A per-request correlation id. Random and opaque — it is NOT an identity and
/// must never be used to select an owner or a rate-limit namespace.
export function correlationId(): string {
  return crypto.randomUUID();
}

/// Structured operational logging. Callers pass ONLY safe fields (correlation
/// id, endpoint code, identity CLASS, result code, coarse latency bucket, quota
/// outcome, upstream status class, retryability). This helper adds nothing
/// sensitive; it never logs a raw payload, secret, or upstream body.
export function safeLog(fields: Record<string, string | number | boolean | null>): void {
  console.log(JSON.stringify(fields));
}

/// Coarse latency bucket so timing is loggable without being a fingerprint.
export function latencyBucket(ms: number): string {
  if (ms < 100) return 'lt_100ms';
  if (ms < 500) return 'lt_500ms';
  if (ms < 1000) return 'lt_1s';
  if (ms < 3000) return 'lt_3s';
  if (ms < 10000) return 'lt_10s';
  return 'gte_10s';
}

// ── Bounded JSON body + schema gating ───────────────────────────────────────

export type BodyResult =
  | { ok: true; body: Record<string, unknown> }
  | { ok: false; code: 'payload_too_large' | 'invalid_payload' };

/// Reads a JSON object body, rejecting anything larger than [maxBytes] (checked
/// against Content-Length first, then the actual text) and anything that is not
/// a plain JSON object. Bounds cost before any parsing/allocation blows up.
export async function readJsonBody(req: Request, maxBytes: number): Promise<BodyResult> {
  const declared = Number(req.headers.get('content-length') ?? '');
  if (Number.isFinite(declared) && declared > maxBytes) {
    return { ok: false, code: 'payload_too_large' };
  }
  const raw = await req.text();
  // `raw.length` bounds UTF-16 code units; byte length is ≥ this, so a value
  // under the byte cap is safe, and this also catches a lying Content-Length.
  if (raw.length > maxBytes) return { ok: false, code: 'payload_too_large' };
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ok: false, code: 'invalid_payload' };
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    return { ok: false, code: 'invalid_payload' };
  }
  return { ok: true, body: parsed as Record<string, unknown> };
}

/// Returns an error Response if `schema_version` is present and unsupported.
/// Absent = v1 (backward compatible with old clients).
export function schemaError(body: Record<string, unknown>, cid: string): Response | null {
  const v = body.schema_version ?? body.schemaVersion;
  if (v === undefined || v === null) return null;
  if (v !== SCHEMA_VERSION) {
    return apiError('unsupported_schema', {
      correlationId: cid,
      supportedSchemaVersion: SCHEMA_VERSION,
    });
  }
  return null;
}

// ── Verified identity ───────────────────────────────────────────────────────

export interface VerifiedIdentity {
  /// Which authoritative source proved this identity.
  kind: 'device' | 'user';
  /// Server-DERIVED rate-limit / idempotency namespace. Never caller-selected.
  ownerKey: string;
  userId: string | null;
  installIdHash: string | null;
  aiConsent: boolean;
  cloudConsent: boolean;
}

export type IdentityResult =
  | { ok: true; identity: VerifiedIdentity }
  | { ok: false; response: Response };

function bearerToken(header: string | null): string {
  const h = header ?? '';
  return h.startsWith('Bearer ') ? h.slice(7).trim() : '';
}

/// Resolves the authoritative identity for an AI/paid request.
///
/// Order (fail-closed, never falls back to a caller-selected identity):
///   1. A device secret (`device_secret` + `install_id`) verified against
///      `capture_devices` — the primary capture-adjacent path.
///   2. Otherwise a REAL user JWT (role=authenticated) resolved via getUser;
///      the anon key yields no user and is therefore not authoritative.
///   3. Otherwise `authentication_required`. `install_id` on its own is
///      non-authoritative compatibility metadata and never selects an owner.
export async function resolveVerifiedIdentity(
  req: Request,
  supabase: ReturnType<typeof serviceClient>,
  body: Record<string, unknown>,
  cid: string,
): Promise<IdentityResult> {
  const installId = readString(body, 'installId', 'install_id');
  const deviceSecret = readString(body, 'deviceSecret', 'device_secret');

  // 1) Verified device secret.
  if (deviceSecret) {
    if (!installId) {
      return { ok: false, response: apiError('invalid_device_credential', { correlationId: cid }) };
    }
    const installIdHash = await installHash(installId);
    const providedHash = await sha256Hex(deviceSecret);
    const { data, error } = await supabase
      .from('capture_devices')
      .select('device_secret_hash, user_id, revoked_at, ai_consent_granted, cloud_processing_enabled')
      .eq('install_id_hash', installIdHash)
      .maybeSingle();
    if (error) {
      return { ok: false, response: apiError('internal_error', { correlationId: cid }) };
    }
    if (!data || !timingSafeEqual(data.device_secret_hash, providedHash)) {
      return { ok: false, response: apiError('invalid_device_credential', { correlationId: cid }) };
    }
    if (data.revoked_at != null) {
      return { ok: false, response: apiError('credential_revoked', { correlationId: cid }) };
    }
    // Best-effort liveness touch; never blocks the request.
    await supabase
      .from('capture_devices')
      .update({ last_seen_at: new Date().toISOString() })
      .eq('install_id_hash', installIdHash);
    return {
      ok: true,
      identity: {
        kind: 'device',
        ownerKey: `d:${installIdHash}`,
        userId: (data.user_id as string | null) ?? null,
        installIdHash,
        aiConsent: data.ai_consent_granted === true,
        cloudConsent: data.cloud_processing_enabled === true,
      },
    };
  }

  // 2) Real user JWT (never the anon key — it resolves to no user).
  const token = bearerToken(req.headers.get('Authorization') ?? req.headers.get('authorization'));
  if (token) {
    const { data: userData, error } = await supabase.auth.getUser(token);
    const user = !error ? userData?.user : null;
    if (user?.id) {
      const { data: settings, error: settingsError } = await supabase
        .from('user_settings')
        .select('ai_consent_granted, cloud_processing_enabled, consent_version')
        .eq('user_id', user.id)
        .maybeSingle();
      const provenConsent = Number(settings?.consent_version ?? 0) > 0;
      return {
        ok: true,
        identity: {
          kind: 'user',
          ownerKey: `u:${user.id}`,
          userId: user.id,
          installIdHash: null,
          // Fail closed: a missing or errored settings read is consent OFF.
          // NULL/FALSE = denied; TRUE counts only with consent_version > 0 (an
          // unproven TRUE, e.g. a legacy column default, is never sufficient).
          aiConsent: !settingsError && settings?.ai_consent_granted === true && provenConsent,
          cloudConsent: !settingsError && settings?.cloud_processing_enabled === true && provenConsent,
        },
      };
    }
  }

  // 3) No authoritative identity.
  return { ok: false, response: apiError('authentication_required', { correlationId: cid }) };
}

// ── Bounded upstream fetch ──────────────────────────────────────────────────

/// fetch() with a hard timeout via AbortController, so a hung upstream cannot
/// pin an edge invocation open. Throws an AbortError on timeout — callers map it
/// to `upstream_timeout`.
export function fetchWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs: number,
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  return fetch(url, { ...init, signal: controller.signal }).finally(() => clearTimeout(timer));
}

/// True when a thrown error is an abort (our timeout) rather than a real fault.
export function isAbortError(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError' ||
    (error instanceof Error && error.name === 'AbortError');
}

// ── Idempotency (backed by the 0071 claim_ai_idempotency RPC) ────────────────

export const AI_IDEMPOTENCY_TTL_SECONDS = 3600;

/// A stable hash over the SERVER-derived owner + endpoint + normalized payload.
/// The raw payload is never stored — only this hash — so a replay with a changed
/// payload is detectable without retaining sensitive text.
export function payloadHash(parts: string[]): Promise<string> {
  return sha256Hex(parts.join(' '));
}

export type ClaimResult =
  | { outcome: 'claimed' }
  | { outcome: 'exists'; status: string; result: Record<string, unknown> }
  | { outcome: 'mismatch' }
  | { outcome: 'error' };

/// Atomically claims a request id (see the 0071 RPC). `error` on any RPC fault
/// so the caller can decide to proceed best-effort rather than fail the request.
export async function claimIdempotency(
  supabase: ReturnType<typeof serviceClient>,
  ownerKey: string,
  endpoint: string,
  requestId: string,
  hash: string,
  ttlSeconds = AI_IDEMPOTENCY_TTL_SECONDS,
): Promise<ClaimResult> {
  const { data, error } = await supabase.rpc('claim_ai_idempotency', {
    p_owner_key: ownerKey,
    p_endpoint: endpoint,
    p_request_id: requestId,
    p_payload_hash: hash,
    p_ttl_seconds: ttlSeconds,
  });
  if (error || !Array.isArray(data) || data.length === 0) return { outcome: 'error' };
  const row = data[0] as { outcome: string; status: string; result: unknown };
  if (row.outcome === 'claimed') return { outcome: 'claimed' };
  if (row.outcome === 'mismatch') return { outcome: 'mismatch' };
  return {
    outcome: 'exists',
    status: row.status,
    result: (row.result ?? {}) as Record<string, unknown>,
  };
}

/// Records the outcome of a claimed request (safe metadata only).
export async function completeIdempotency(
  supabase: ReturnType<typeof serviceClient>,
  ownerKey: string,
  endpoint: string,
  requestId: string,
  status: 'succeeded' | 'failed',
  result: Record<string, unknown>,
): Promise<void> {
  await supabase.rpc('complete_ai_idempotency', {
    p_owner_key: ownerKey,
    p_endpoint: endpoint,
    p_request_id: requestId,
    p_status: status,
    p_result: result,
  });
}

// 'smart' (Gemini-first phase 3): smart analysis of a captured bank message
// (parse-sms) needs the AI consent only, not Cloud; 'ai' (bank discovery,
// shared learning) still needs both.
export type ConsentKind = 'ai' | 'cloud' | 'smart';

/// Returns a `consent_required` Response when the verified identity has not
/// granted the required processing consent; null when it is granted. Cloud is
/// the master gate: AI requires BOTH cloud-processing and AI consent.
export function consentError(
  identity: VerifiedIdentity,
  kind: ConsentKind,
  cid: string,
): Response | null {
  const granted = kind === 'smart'
    ? identity.aiConsent
    : kind === 'ai'
    ? identity.cloudConsent && identity.aiConsent
    : identity.cloudConsent;
  if (granted) return null;
  return apiError('consent_required', { correlationId: cid, retryable: false });
}
