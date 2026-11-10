// Cold-start resolution of the Apple gateway and the sealer (contract section 7).
// Readiness is true only when every required secret is present, well-formed and
// importable. Otherwise the fail-closed stubs are returned and the three
// readiness flags stay false. No secret value is ever logged or returned.

import type { AppleGateway, MaterialSealer, RpcClient } from './account_deletion_adapter.ts';
import { createAppleDeletionGateway, parseAppleDeletionConfig } from './apple_deletion_gateway.ts';
import { createMaterialSealer, decodeSealerKey } from './material_sealer.ts';

const unconfiguredApple: AppleGateway = {
  authorize: () => Promise.resolve({ status: 'not_configured' }),
  revoke: () => Promise.resolve('retryable'),
};
const unconfiguredSealer: MaterialSealer = {
  seal: () => Promise.reject(new Error('sealer_not_configured')),
  unseal: () => Promise.reject(new Error('sealer_not_configured')),
};

/** Ports for the challenge route; absent (undefined) means "not configured" and fails closed. */
export type ChallengeIssue =
  | { outcome: 'issued'; challengeId: string; nonce: string; expiresAtMs: number; proofMethod?: 'apple' | 'google' | 'email' }
  | { outcome: 'admin' | 'rate_limited' | 'already_pending' | 'unauthenticated' };

export interface ChallengePort {
  /** null = not a live user. */
  getUser(bearerToken: string): Promise<{ id: string } | null>;
  isAdmin(uid: string): Promise<boolean>;
  issue(uid: string, request?: { bearerToken: string; emailOnly: boolean }): Promise<ChallengeIssue>;
}

export interface DeletionCollaborators {
  apple: AppleGateway;
  sealer: MaterialSealer;
  ready: boolean;
}

export async function resolveDeletionCollaborators(deps: {
  env: (name: string) => string | undefined;
  fetch: typeof fetch;
  now: () => number;
  rpc: RpcClient;
}): Promise<DeletionCollaborators> {
  const failClosed = { apple: unconfiguredApple, sealer: unconfiguredSealer, ready: false };
  try {
    const config = parseAppleDeletionConfig(deps.env);
    const keyB64 = deps.env('ACCOUNT_DELETION_SEALER_KEY');
    if (!config || decodeSealerKey(keyB64) === null) return failClosed;
    const gateway = createAppleDeletionGateway({ fetch: deps.fetch, now: deps.now, rpc: deps.rpc, config });
    if (!(await gateway.signingKeyUsable())) return failClosed;
    const sealer = await createMaterialSealer(keyB64 as string);
    return { apple: gateway, sealer, ready: true };
  } catch {
    return failClosed;
  }
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/**
 * Challenge issuer over the service-role RPC. Maps SQLSTATE QD031 -> admin,
 * QD032 -> rate_limited and an `already_pending` answer (as outcome, status or
 * error code/message) -> already_pending. Anything else throws (outage).
 */
export function createChallengePort(deps: {
  rpc: RpcClient;
  getUser: (bearerToken: string) => Promise<{ id: string } | null>;
  isAdmin: (uid: string) => Promise<boolean>;
  sendEmailCode?: (bearerToken: string) => Promise<void>;
}): ChallengePort {
  return {
    getUser: deps.getUser,
    isAdmin: deps.isAdmin,
    async issue(uid, request) {
      const supportsMethods = request && deps.sendEmailCode;
      const res = await deps.rpc.rpc(
        supportsMethods ? 'account_deletion_issue_challenge_v2' : 'account_deletion_issue_challenge',
        supportsMethods ? { p_uid: uid, p_email_only: request.emailOnly } : { p_uid: uid },
      );
      if (res.error) {
        const code = res.error.code;
        if (code === 'QD031') return { outcome: 'admin' };
        if (code === 'QD032') return { outcome: 'rate_limited' };
        if (code === 'already_pending' || res.error.message === 'already_pending') return { outcome: 'already_pending' };
        throw new Error('challenge_rpc_failed');
      }
      const d = Array.isArray(res.data) ? res.data[0] : res.data;
      if (isObject(d) && (d.outcome === 'already_pending' || d.status === 'already_pending' || d.code === 'already_pending')) {
        return { outcome: 'already_pending' };
      }
      if (
        !isObject(d) || typeof d.challenge_id !== 'string' || d.challenge_id.length === 0 ||
        typeof d.nonce !== 'string' || d.nonce.length === 0
      ) throw new Error('challenge_rpc_malformed');
      const ms = typeof d.expires_at_ms === 'number' ? d.expires_at_ms : Date.parse(String(d.expires_at));
      if (!Number.isFinite(ms)) throw new Error('challenge_rpc_malformed');
      const proofMethod = supportsMethods ? d.proof_method : undefined;
      if (supportsMethods && proofMethod !== 'apple' && proofMethod !== 'google' && proofMethod !== 'email') {
        throw new Error('challenge_method_malformed');
      }
      if (proofMethod === 'email' && request && deps.sendEmailCode) {
        await deps.sendEmailCode(request.bearerToken);
        const binding = await deps.rpc.rpc('account_deletion_bind_email_code', {
          p_uid: uid, p_challenge_id: d.challenge_id,
        });
        if (binding.error || binding.data !== true) throw new Error('challenge_email_unbound');
      }
      return {
        outcome: 'issued', challengeId: d.challenge_id, nonce: d.nonce, expiresAtMs: ms,
        ...(proofMethod === 'apple' || proofMethod === 'google' || proofMethod === 'email' ? { proofMethod } : {}),
      };
    },
  };
}
