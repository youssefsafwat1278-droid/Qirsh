// Shared category learning — ingress for one user-confirmed merchant rule.
//
// The body is EXACTLY {merchant_key, category_key}; any other key is refused so
// a client cannot start sending more than was agreed. Identity is the caller's
// user JWT only (no device secret, no install id): contributions are counted
// per user, and the database stores only an HMAC of the user id (see migration
// 20261116150000). Both Cloud and AI consent are re-checked here from the
// server's own record, so a stale client cannot contribute after withdrawal.
//
// The merchant-feedback route stays retired; this is the verified-identity +
// consent flow its retirement note asked for.
import { bumpCaptureEndpointRateLimit, corsHeaders, serviceClient } from '../_shared/capture_auth.ts';
import { redactPii } from '../_shared/sms_redaction.ts';
import {
  apiError,
  consentError,
  correlationId,
  readJsonBody,
  resolveVerifiedIdentity,
} from '../_shared/ai_endpoint.ts';

const MAX_BODY_BYTES = 512;
const DAILY_LIMIT_PER_USER = 100;
const ALLOWED_KEYS = ['category_key', 'merchant_key'];
const EXCLUDED_CATEGORIES = new Set(['transfers', 'income', 'cash', 'other', 'all_expenses']);

/// Mirrors the device's TransactionDedup.normalizeMerchant output plus the
/// database check merchant_contribution_key_ok: upper-case, single spaces, no
/// digit of any script, at least one letter, 3..64 characters.
export function merchantKeyOk(key: string): boolean {
  if (key.length < 3 || key.length > 64) return false;
  if (key !== key.toUpperCase()) return false;
  if (key !== key.replace(/\s+/g, ' ').trim()) return false;
  if (/[0-9٠-٩۰-۹@]/.test(key)) return false;
  if (!/\p{L}/u.test(key)) return false;
  return redactPii(key) === key;
}

export function categoryKeyOk(key: string): boolean {
  return /^[a-z_]{2,32}$/.test(key) && !EXCLUDED_CATEGORIES.has(key);
}

type Deps = {
  createServiceClient: typeof serviceClient;
  resolveIdentity: typeof resolveVerifiedIdentity;
  bumpRateLimit: typeof bumpCaptureEndpointRateLimit;
};

const defaultDeps: Deps = {
  createServiceClient: serviceClient,
  resolveIdentity: resolveVerifiedIdentity,
  bumpRateLimit: bumpCaptureEndpointRateLimit,
};

export async function handleContribution(req: Request, deps: Deps = defaultDeps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  const cid = correlationId();
  if (req.method !== 'POST') return apiError('invalid_payload', { correlationId: cid });

  const bodyRes = await readJsonBody(req, MAX_BODY_BYTES);
  if (!bodyRes.ok) return apiError(bodyRes.code, { correlationId: cid });
  const body = bodyRes.body;
  const keys = Object.keys(body).sort();
  if (keys.length !== ALLOWED_KEYS.length || keys.some((k, i) => k !== ALLOWED_KEYS[i])) {
    return apiError('invalid_payload', { correlationId: cid });
  }
  const merchantKey = body.merchant_key;
  const categoryKey = body.category_key;
  if (typeof merchantKey !== 'string' || typeof categoryKey !== 'string') {
    return apiError('invalid_payload', { correlationId: cid });
  }

  const supabase = deps.createServiceClient();
  // An empty body: the device-secret path is never taken, only a user JWT.
  const identity = await deps.resolveIdentity(req, supabase, {}, cid);
  if (!identity.ok) return identity.response;
  if (identity.identity.kind !== 'user' || !identity.identity.userId) {
    return apiError('authentication_required', { correlationId: cid });
  }
  // 'ai' = Cloud AND AI consent.
  const consentBad = consentError(identity.identity, 'ai', cid);
  if (consentBad) return consentBad;

  if (!merchantKeyOk(merchantKey) || !categoryKeyOk(categoryKey)) {
    return apiError('invalid_payload', { correlationId: cid });
  }

  const limited = await deps.bumpRateLimit(
    supabase,
    identity.identity.ownerKey,
    'merchant-category-contribution',
    DAILY_LIMIT_PER_USER,
  );
  if (limited) return apiError('rate_limited', { correlationId: cid, retryable: true });

  const { error } = await supabase.rpc('submit_merchant_category_contribution', {
    p_user_id: identity.identity.userId,
    p_merchant_key: merchantKey,
    p_category_key: categoryKey,
  });
  if (error) {
    const code = (error as { code?: string }).code;
    return apiError(code === 'P0422' ? 'invalid_payload' : 'internal_error', { correlationId: cid });
  }
  return new Response(JSON.stringify({ accepted: true }), {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

if (import.meta.main) Deno.serve((req) => handleContribution(req));
