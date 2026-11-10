// Shared cold-start wiring for the account-deletion Edge Functions. DRAFT, NOT DEPLOYED.
// Not evaluated by tests (it needs the platform environment and the Supabase SDK).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { buildAccountDeletionCoordinator } from './account_deletion_adapter.ts';
import { createChallengePort, resolveDeletionCollaborators } from './account_deletion_wiring.ts';
import { createAlternateDeletionProof } from './account_deletion_alternate_proof.ts';
import { verifyGoogleProof } from './google_identity_proof.ts';

export async function buildDeletionRuntime() {
  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const rpc = { rpc: (fn: string, args: Record<string, unknown>) => db.rpc(fn, args) as never };
  const getUser = async (jwt: string) => {
    const { data, error } = await db.auth.getUser(jwt);
    return error || !data?.user ? null : { id: data.user.id };
  };
  const { apple, sealer, ready } = await resolveDeletionCollaborators({
    env: (name) => Deno.env.get(name),
    fetch: (input, init) => fetch(input, init),
    now: () => Date.now(),
    rpc,
  });
  const coordinator = buildAccountDeletionCoordinator({
    rpc,
    identity: { getUser },
    apple,
    alternateProof: createAlternateDeletionProof({ rpc, now: Date.now, verifyGoogle: verifyGoogleProof }),
    sealer,
    storage: db.storage as never,
    authAdmin: {
      deleteUser: async (uid) => {
        const { error } = await db.auth.admin.deleteUser(uid);
        return { error: error ? { status: error.status, code: error.code, message: error.message } : null };
      },
    },
    config: {
      database: url !== '' && serviceKey !== '',
      storage_admin: url !== '' && serviceKey !== '',
      auth_admin: url !== '' && serviceKey !== '',
      // True only when every Apple/sealer secret was present, well-formed and importable.
      intent_verification: ready,
      apple_signing: ready,
      token_encryption: ready,
    },
  });
  const challenge = ready && url !== '' && serviceKey !== ''
    ? createChallengePort({
      rpc,
      getUser,
      sendEmailCode: async (bearerToken) => {
        if (!anonKey) throw new Error('email_proof_unconfigured');
        const response = await fetch(`${url}/auth/v1/reauthenticate`, {
          headers: { apikey: anonKey, authorization: `Bearer ${bearerToken}` },
          signal: AbortSignal.timeout(10_000),
        });
        await response.body?.cancel().catch(() => {});
        if (!response.ok) throw new Error('deletion_email_send_failed');
      },
      isAdmin: async (uid) => {
        const { data, error } = await db.from('admin_users').select('id').eq('id', uid).maybeSingle();
        if (error) throw new Error('admin_check_failed');
        return data !== null;
      },
    })
    : undefined;
  return { coordinator, challenge };
}
