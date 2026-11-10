// HTTP handler for POST /delete-account-immediate. Thin: all decisions belong
// to the frozen coordinator. DRAFT - NOT DEPLOYED.
//
// Wire contract (see app/lib/core/auth/account_deletion_service.dart):
//   request : { challenge_id, challenge_response, receipt_secret }  + Bearer JWT
//   status  : { action: 'status', receipt_secret } (receipt capability only)
//   challenge: { action: 'challenge' } + Bearer JWT -> { status: 'challenge', challenge_id,
//               nonce, expires_at_ms } | 403 admin_self_delete_blocked | 429 challenge_rate_limited
//               | { status: 'accepted' } when a deletion is already pending
//   response: { status: 'completed' | 'in_progress' | 'accepted' | 'unknown'
//               | 'unavailable' | 'error', code?, retryable?, recovery? }
// 'completed' is returned ONLY when the coordinator's receipt reports completed.
// No job id, uid or provider text is ever in a body.

import type {
  DeletionRequest,
  PublicStatus,
  RequestResult,
  RunOutcome,
} from '../_shared/account_deletion_coordinator.ts';
import type { ChallengePort } from '../_shared/account_deletion_wiring.ts';

export type { ChallengeIssue, ChallengePort } from '../_shared/account_deletion_wiring.ts';

export interface DeletionCoordinatorLike {
  requestDeletion(req: DeletionRequest): Promise<RequestResult>;
  getStatus(receiptSecret: string): Promise<PublicStatus>;
  processJob(jobId: string, workerId: string): Promise<RunOutcome>;
}

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST,OPTIONS',
};

function reply(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

const ERROR_HTTP: Record<string, number> = {
  unauthenticated: 401,
  invalid_request: 400,
  challenge_invalid: 400,
  challenge_expired: 400,
  challenge_replayed: 409,
  apple_subject_mismatch: 403,
  idempotency_conflict: 409,
  admin_self_delete_blocked: 403,
  challenge_rate_limited: 429,
};

function bearerOf(req: Request): string {
  const h = req.headers.get('authorization') ?? '';
  const m = /^Bearer\s+(.+)$/i.exec(h.trim());
  return m ? m[1].trim() : '';
}

function statusReply(st: PublicStatus): Response {
  switch (st.status) {
    case 'completed':
      return reply({ status: 'completed' }, 200);
    case 'accepted':
      return reply({ status: 'accepted' }, 200);
    case 'pending':
      return reply({ status: 'in_progress' }, 200);
    case 'unknown':
      return reply({ status: 'unknown' }, 404);
    default:
      return reply({ status: 'unavailable' }, 503);
  }
}

async function challengeReply(
  port: ChallengePort | undefined,
  bearerToken: string,
  emailOnly?: boolean,
): Promise<Response> {
  if (!port) return reply({ status: 'error', code: 'not_configured', retryable: false }, 503);
  try {
    const user = await port.getUser(bearerToken);
    if (!user) return reply({ status: 'error', code: 'unauthenticated', retryable: false }, 401);
    if (await port.isAdmin(user.id)) {
      return reply({ status: 'error', code: 'admin_self_delete_blocked', retryable: false }, 403);
    }
    const r = await port.issue(user.id, emailOnly === undefined ? undefined : { bearerToken, emailOnly });
    switch (r.outcome) {
      case 'issued':
        return reply({
          status: 'challenge', challenge_id: r.challengeId, nonce: r.nonce, expires_at_ms: r.expiresAtMs,
          ...(r.proofMethod ? { proof_method: r.proofMethod } : {}),
        }, 200);
      case 'admin':
        return reply({ status: 'error', code: 'admin_self_delete_blocked', retryable: false }, 403);
      case 'rate_limited':
        return reply({ status: 'error', code: 'challenge_rate_limited', retryable: true }, 429);
      case 'already_pending':
        return reply({ status: 'accepted' }, 200);
      case 'unauthenticated':
        return reply({ status: 'error', code: 'unauthenticated', retryable: false }, 401);
    }
  } catch {
    // Admin check or issuer unreachable: refuse rather than issue a challenge unchecked.
    return reply({ status: 'error', code: 'store_unavailable', retryable: true }, 503);
  }
}

export function createDeleteAccountHandler(
  deps: { coordinator: DeletionCoordinatorLike; workerId: string; challenge?: ChallengePort },
) {
  const { coordinator, workerId } = deps;

  return async (req: Request): Promise<Response> => {
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
    if (req.method !== 'POST') return reply({ status: 'error', code: 'method_not_allowed', retryable: false }, 405);

    try {
      let body: unknown;
      try {
        body = await req.json();
      } catch {
        return reply({ status: 'error', code: 'invalid_request', retryable: false }, 400);
      }
      if (typeof body !== 'object' || body === null || Array.isArray(body)) {
        return reply({ status: 'error', code: 'invalid_request', retryable: false }, 400);
      }
      const b = body as Record<string, unknown>;
      const action = Object.hasOwn(b, 'action') ? b.action : 'request';

      if (action === 'status') {
        // Receipt capability only; never starts work. The coordinator validates format.
        if (
          Object.keys(b).length !== 2 || typeof b.receipt_secret !== 'string' ||
          !/^[A-Za-z0-9_-]{43,128}$/.test(b.receipt_secret)
        ) return reply({ status: 'error', code: 'invalid_request', retryable: false }, 400);
        return statusReply(await coordinator.getStatus(b.receipt_secret));
      }
      if (action === 'challenge') {
        const legacy = Object.keys(b).length === 1;
        const v2 = Object.keys(b).length === 3 && b.proof_version === 2 && typeof b.email_only === 'boolean';
        if (!legacy && !v2) return reply({ status: 'error', code: 'invalid_request', retryable: false }, 400);
        const token = bearerOf(req);
        if (!token) return reply({ status: 'error', code: 'unauthenticated', retryable: false }, 401);
        return await challengeReply(deps.challenge, token, v2 ? b.email_only as boolean : undefined);
      }
      if (action !== 'request') {
        return reply({ status: 'error', code: 'invalid_request', retryable: false }, 400);
      }

      const bearerToken = bearerOf(req);
      if (!bearerToken) return reply({ status: 'error', code: 'unauthenticated', retryable: false }, 401);

      // Only these fields are read; any client-supplied uid/email is dropped.
      const result = await coordinator.requestDeletion({
        bearerToken,
        challengeId: typeof b.challenge_id === 'string' ? b.challenge_id : '',
        challengeResponse: typeof b.challenge_response === 'string' ? b.challenge_response : '',
        receiptSecret: typeof b.receipt_secret === 'string' ? b.receipt_secret : '',
      });

      if (result.status === 'error') {
        const http = ERROR_HTTP[result.code] ?? 503;
        return reply({
          status: 'error',
          code: result.code,
          retryable: result.retryable,
          ...(result.recovery ? { recovery: result.recovery } : {}),
        }, http);
      }

      // Accepted. Drive the saga now, but whatever happens, the client is told
      // only what the server's own receipt says.
      try {
        await coordinator.processJob(result.jobId, workerId);
      } catch {
        // swallowed: the job is durable and will be resumed
      }
      const st = await coordinator.getStatus(typeof b.receipt_secret === 'string' ? b.receipt_secret : '');
      if (st.status === 'completed') return reply({ status: 'completed' }, 200);
      // Anything else (pending, accepted, unavailable, unknown): honest in-progress.
      return reply({ status: 'in_progress' }, 202);
    } catch {
      return reply({ status: 'error', code: 'unexpected', retryable: true }, 500);
    }
  };
}
