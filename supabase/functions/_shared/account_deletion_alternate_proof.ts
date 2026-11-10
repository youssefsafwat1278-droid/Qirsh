import type { RpcClient } from './account_deletion_adapter.ts';
import type { AuthorizationResult } from './account_deletion_coordinator.ts';

export function createAlternateDeletionProof(deps: {
  rpc: RpcClient;
  now: () => number;
  verifyGoogle: (token: string, nonce: string) => Promise<string | null>;
}) {
  return async (input: {
    uid: string;
    challengeId: string;
    challengeResponse: string;
  }): Promise<AuthorizationResult | null> => {
    let body: Record<string, unknown>;
    try {
      body = JSON.parse(input.challengeResponse);
    } catch {
      return null; // The existing Apple validator owns this input.
    }
    if (!body || (body.proof !== 'google' && body.proof !== 'email')) return null;
    const args = { p_uid: input.uid, p_challenge_id: input.challengeId };
    const read = await deps.rpc.rpc('account_deletion_read_challenge', args);
    if (read.error) throw new Error('challenge_lookup_failed');
    const challenge = read.data as Record<string, unknown> | null;
    if (!challenge || challenge.proof_method !== body.proof ||
        typeof challenge.expires_at_ms !== 'number' || !Number.isFinite(challenge.expires_at_ms)) {
      return { ok: false, code: 'challenge_invalid' };
    }
    if (challenge.consumed === true) return { ok: false, code: 'challenge_replayed' };
    if (challenge.expires_at_ms <= deps.now()) return { ok: false, code: 'challenge_expired' };
    if (challenge.consumed !== false) return { ok: false, code: 'challenge_invalid' };
    if (body.proof === 'google') {
      if (typeof body.identity_token !== 'string' || !body.identity_token ||
          typeof challenge.nonce_hash !== 'string' ||
          typeof challenge.google_subject !== 'string' || !challenge.google_subject) {
        return { ok: false, code: 'challenge_invalid' };
      }
      const sub = await deps.verifyGoogle(body.identity_token, challenge.nonce_hash);
      if (sub !== challenge.google_subject) return { ok: false, code: 'challenge_invalid' };
    } else {
      if (typeof body.code !== 'string' || !/^[0-9]{6,10}$/.test(body.code)) {
        return { ok: false, code: 'challenge_invalid' };
      }
      const verified = await deps.rpc.rpc('account_deletion_verify_email_code', {
        ...args, p_code: body.code,
      });
      if (verified.error) throw new Error('email_proof_unavailable');
      if (verified.data !== true) return { ok: false, code: 'challenge_invalid' };
    }
    return {
      ok: true, verified: true, alternateProofMatched: true,
      challengeExpiresAtMs: challenge.expires_at_ms, appleMaterialRef: null,
    };
  };
}
