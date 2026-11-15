import {
  bumpCaptureEndpointRateLimit,
  corsHeaders,
  json,
  readString,
  serviceClient,
  verifyDevice,
} from '../_shared/capture_auth.ts';

const REGISTER_PUSH_TOKEN_LIMIT_PER_DAY = 60;

type RegisterPushTokenDependencies = {
  createServiceClient: typeof serviceClient;
  verifyDevice: typeof verifyDevice;
};

const defaultDependencies: RegisterPushTokenDependencies = {
  createServiceClient: serviceClient,
  verifyDevice,
};

export async function handleRegisterPushToken(
  req: Request,
  dependencies: RegisterPushTokenDependencies = defaultDependencies,
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return json({ error: 'invalid_json' }, 400);

  const installId = readString(body, 'installId', 'install_id');
  const deviceSecret = readString(body, 'deviceSecret', 'device_secret');
  const apnsToken = readString(body, 'apnsToken', 'apns_token');
  const environment = readString(body, 'apnsEnvironment', 'apns_environment');
  if (!apnsToken || !['sandbox', 'production'].includes(environment)) {
    return json({ error: 'missing_push_token' }, 400);
  }

  const supabase = dependencies.createServiceClient();
  const auth = await dependencies.verifyDevice(supabase, installId, deviceSecret);
  if (!auth.ok) return json({ error: auth.error }, auth.status);

  // Compare-and-swap: the write only lands if the stored token is still the one this
  // request read, so two concurrent registrations (or a registration racing a dead-token
  // clear) can never silently overwrite each other with a stale value. One re-read on loss.
  let rateChecked = false;
  for (let attempt = 0; attempt < 2; attempt++) {
    const current = await supabase
      .from('capture_devices')
      .select('apns_token,apns_environment')
      .eq('install_id_hash', auth.installIdHash)
      .maybeSingle();
    if (current.error) return json({ error: 'token_lookup_failed' }, 500);
    // iOS may deliver the same APNs token repeatedly on startup/resume. Treat that as an
    // idempotent success before consuming rate-limit budget; only actual token/environment
    // changes count toward the abuse limit.
    if (
      current.data?.apns_token === apnsToken &&
      current.data?.apns_environment === environment
    ) {
      return json({ ok: true, unchanged: true });
    }
    if (!rateChecked) {
      rateChecked = true;
      if (
        await bumpCaptureEndpointRateLimit(
          supabase,
          auth.installIdHash,
          'register-push-token',
          REGISTER_PUSH_TOKEN_LIMIT_PER_DAY,
        )
      ) {
        return json({ error: 'rate_limit_exceeded' }, 429);
      }
    }

    const expected = (current.data?.apns_token as string | null | undefined) ?? null;
    const update = supabase
      .from('capture_devices')
      .update({
        apns_token: apnsToken,
        apns_environment: environment,
        token_updated_at: new Date().toISOString(),
        last_seen_at: new Date().toISOString(),
      })
      .eq('install_id_hash', auth.installIdHash);
    const { data, error } = await (expected == null ? update.is('apns_token', null) : update.eq('apns_token', expected))
      .select('install_id_hash');
    if (error?.code === '55P03') {
      if (attempt === 1) return json({ error: 'token_update_busy' }, 503);
      await new Promise((resolve) => setTimeout(resolve, 50));
      // This attempt rolled back. Revalidate the credential before making a
      // new read and CAS, and keep the rate-limit charge for this request.
      const retryAuth = await dependencies.verifyDevice(supabase, installId, deviceSecret);
      if (!retryAuth.ok) return json({ error: retryAuth.error }, retryAuth.status);
      if (retryAuth.userId !== auth.userId) return json({ error: 'capture_owner_mismatch' }, 409);
      continue;
    }
    if (error) return json({ error: 'token_update_failed' }, 500);
    if (data && data.length > 0) return json({ ok: true });
  }
  return json({ error: 'token_update_conflict' }, 409);
}

if (import.meta.main) Deno.serve((req) => handleRegisterPushToken(req));
