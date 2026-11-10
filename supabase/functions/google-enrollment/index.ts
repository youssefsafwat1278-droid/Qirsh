import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { verifyGoogleEnrollment } from '../_shared/google_identity_proof.ts';

const client = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// The Google-signed credential is the only caller authority. No UID, email
// address, or supplied subject is trusted. The hook consumes the short permit
// when Supabase Auth subsequently sees a first-time Google identity.
Deno.serve(async (request) => {
  const reply = (status: number) =>
    Response.json({ allowed: status === 200 }, { status, headers: { 'cache-control': 'no-store' } });
  if (request.method !== 'POST') return reply(405);
  try {
    const raw = await request.text();
    if (raw.length > 8192) return reply(400);
    const body = JSON.parse(raw);
    if (!body || typeof body.id_token !== 'string' ||
        (body.nonce !== null && typeof body.nonce !== 'string')) return reply(400);
    const subject = await verifyGoogleEnrollment(body.id_token, body.nonce);
    if (!subject) return reply(403);
    const { error } = await client.rpc('qirsh_permit_google_enrollment', { p_subject: subject });
    return reply(error ? 503 : 200);
  } catch {
    return reply(503);
  }
});
