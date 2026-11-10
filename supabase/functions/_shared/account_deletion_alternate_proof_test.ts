import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { createAlternateDeletionProof } from './account_deletion_alternate_proof.ts';

const input = { uid: 'owner', challengeId: 'challenge', challengeResponse: '' };
const base = { consumed: false, expires_at_ms: 3000, nonce_hash: 'nonce' };

Deno.test('Google deletion matches the server-selected method, nonce and subject', async () => {
  const verify = createAlternateDeletionProof({
    now: () => 1000,
    rpc: {
      rpc: (_name, args) => {
        assertEquals(args, { p_uid: 'owner', p_challenge_id: 'challenge' });
        return Promise.resolve({ data: { ...base, proof_method: 'google', google_subject: '123' }, error: null });
      },
    },
    verifyGoogle: (token, nonce) => Promise.resolve(nonce === 'nonce' ? token : null),
  });
  const proof = (sub: string) => verify({
    ...input, challengeResponse: JSON.stringify({ proof: 'google', identity_token: sub }),
  });
  assertEquals(await proof('456'), { ok: false, code: 'challenge_invalid' });
  assertEquals(await proof('123'), {
    ok: true, verified: true, alternateProofMatched: true, challengeExpiresAtMs: 3000, appleMaterialRef: null,
  });
  assertEquals(await verify({ ...input, challengeResponse: '{"proof":"email","code":"12345678"}' }),
    { ok: false, code: 'challenge_invalid' });
});

Deno.test('Email proof delegates its bounded one-use check to the database', async () => {
  let used = false;
  const verify = createAlternateDeletionProof({
    now: () => 1000,
    verifyGoogle: () => Promise.reject(new Error('unexpected Google call')),
    rpc: {
      rpc: (name, args) => {
        if (name === 'account_deletion_read_challenge') {
          return Promise.resolve({ data: { ...base, proof_method: 'email' }, error: null });
        }
        assertEquals(name, 'account_deletion_verify_email_code');
        assertEquals(args, { p_uid: 'owner', p_challenge_id: 'challenge', p_code: '12345678' });
        const accepted = !used;
        used = true;
        return Promise.resolve({ data: accepted, error: null });
      },
    },
  });
  const proof = { ...input, challengeResponse: '{"proof":"email","code":"12345678"}' };
  assertEquals((await verify(proof))?.ok, true);
  assertEquals(await verify(proof), { ok: false, code: 'challenge_invalid' });
});
