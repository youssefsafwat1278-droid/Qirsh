// Sends one admin push broadcast (migration 20261116160000).
//
// Caller: the Admin panel's server route, forwarding the signed-in admin's
// access token. Authorization is the same as parser-test: the JWT is resolved
// with the service client and the user must be in public.admin_users; the
// claim RPC re-checks that id. Never trust a role claim or a header.
//
// Per device, at send time: the claim RPC re-evaluates the Cloud audience, this
// function re-checks "Messages from Qirsh" and picks Arabic or English from the
// account's app language. Each claimed row is finished exactly once; only rows
// that were never delivered are ever claimed, so invoking this twice cannot
// send a device the same broadcast twice. Missing APNs credentials fail every
// row closed as `apns_not_configured` without consuming an attempt.
import { type ApnsEnvironment, type ApnsResult, sendApnsAlert } from '../_shared/apns.ts';
import { corsHeaders, json, serviceClient } from '../_shared/capture_auth.ts';
import { clearDeadApnsToken, isDeadApnsToken } from '../_shared/capture_push.ts';

/// `notificationType` and `source` of a broadcast push. The app routes a tap on
/// this source to the broadcast's deep link (or the announcements page).
export const BROADCAST_SOURCE = 'qirsh_broadcast';

const BATCH_SIZE = 100;
const MAX_BATCHES = 50;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// deno-lint-ignore no-explicit-any -- the Supabase Edge client is loosely typed here.
type SupabaseClientLike = any;

type AdminAuth = { ok: true; userId: string } | { ok: false; status: number; error: string };

export type SendPushBroadcastDependencies = {
  createServiceClient: () => SupabaseClientLike;
  authenticateAdmin: (supabase: SupabaseClientLike, token: string) => Promise<AdminAuth>;
  sendAlert: typeof sendApnsAlert;
  newRunId: () => string;
};

type Broadcast = {
  id: string;
  title_ar: string;
  title_en: string;
  body_ar: string;
  body_en: string;
  deep_link: string | null;
};

type ClaimedRow = {
  delivery_id: string;
  device_hash: string;
  attempts: number;
  in_audience: boolean;
  token: string | null;
  environment: string | null;
  settings_language: string | null;
  notifications_json: string | null;
};

type Outcome = {
  status: 'sent' | 'failed' | 'skipped';
  errorCode: string | null;
  countAttempt: boolean;
  exhaust: boolean;
  language: 'ar' | 'en' | null;
  apnsId: string | null;
};

/// Arabic unless the account's app language is English. The server has no
/// per-device locale; `user_settings.language` is the language the app shows.
/// Unknown or unset falls back to Arabic, the product's primary language.
export function pickBroadcastLanguage(settingsLanguage: string | null | undefined): 'ar' | 'en' {
  return (settingsLanguage ?? '').trim().toLowerCase().startsWith('en') ? 'en' : 'ar';
}

/// NotificationPreferences.marketingMessages ("Messages from Qirsh"), default
/// ON. Mirrors public.push_broadcast_messages_enabled().
export function broadcastMessagesEnabled(notificationsJson: string | null | undefined): boolean {
  if (!notificationsJson || !notificationsJson.trim()) return true;
  try {
    const parsed = JSON.parse(notificationsJson);
    return !(parsed && typeof parsed === 'object' && parsed.marketingMessages === false);
  } catch {
    return true;
  }
}

export async function authenticateAdmin(supabase: SupabaseClientLike, token: string): Promise<AdminAuth> {
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data?.user) return { ok: false, status: 401, error: 'unauthenticated' };
  const admin = await supabase.from('admin_users').select('id').eq('id', data.user.id).maybeSingle();
  if (admin.error) return { ok: false, status: 503, error: 'authorization_unavailable' };
  if (!admin.data) return { ok: false, status: 403, error: 'not_authorized' };
  return { ok: true, userId: data.user.id };
}

const defaultDependencies: SendPushBroadcastDependencies = {
  createServiceClient: serviceClient,
  authenticateAdmin,
  sendAlert: sendApnsAlert,
  newRunId: () => crypto.randomUUID(),
};

export async function handleSendPushBroadcast(
  req: Request,
  deps: SendPushBroadcastDependencies = defaultDependencies,
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const authHeader = req.headers.get('authorization') ?? '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';
  if (!token) return json({ error: 'unauthenticated' }, 401);

  const supabase = deps.createServiceClient();
  const auth = await deps.authenticateAdmin(supabase, token);
  if (!auth.ok) return json({ error: auth.error }, auth.status);

  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  const broadcastId = typeof body?.broadcast_id === 'string' ? body.broadcast_id : '';
  if (!UUID_RE.test(broadcastId)) return json({ error: 'broadcast_id_invalid' }, 400);

  const loaded = await supabase
    .from('push_broadcasts')
    .select('id,title_ar,title_en,body_ar,body_en,deep_link')
    .eq('id', broadcastId)
    .maybeSingle();
  if (loaded.error) return json({ error: 'broadcast_lookup_failed' }, 500);
  if (!loaded.data) return json({ error: 'broadcast_not_found' }, 404);
  const broadcast = loaded.data as Broadcast;

  const runId = deps.newRunId();
  const totals = { claimed: 0, sent: 0, failed: 0, skipped: 0, not_configured: 0 };
  for (let batch = 0; batch < MAX_BATCHES; batch++) {
    const claim = await supabase.rpc('claim_push_broadcast_deliveries', {
      p_actor: auth.userId,
      p_broadcast_id: broadcastId,
      p_run_id: runId,
      p_limit: BATCH_SIZE,
    });
    // Claimed rows of a failed call stay 'sending' and become reclaimable after 5 minutes.
    if (claim.error) return json({ error: 'claim_failed', ...totals }, 500);
    const rows = (claim.data ?? []) as ClaimedRow[];
    if (rows.length === 0) break;

    for (const row of rows) {
      totals.claimed++;
      const outcome = await deliverOne(supabase, broadcast, row, deps.sendAlert);
      totals[outcome.status]++;
      if (outcome.errorCode === 'apns_not_configured') totals.not_configured++;
      const finished = await supabase.rpc('finish_push_broadcast_delivery', {
        p_delivery_id: row.delivery_id,
        p_status: outcome.status,
        p_error_code: outcome.errorCode,
        p_count_attempt: outcome.countAttempt,
        p_exhaust: outcome.exhaust,
        p_language: outcome.language,
        p_apns_id: outcome.apnsId,
      });
      if (finished.error) {
        console.error(JSON.stringify({ event: 'push_broadcast_finish_failed', deliveryId: row.delivery_id }));
      }
    }
  }

  console.log(JSON.stringify({ event: 'push_broadcast_run', broadcastId, runId, ...totals }));
  return json({ broadcast_id: broadcastId, run_id: runId, ...totals });
}

async function deliverOne(
  supabase: SupabaseClientLike,
  broadcast: Broadcast,
  row: ClaimedRow,
  sendAlert: typeof sendApnsAlert,
): Promise<Outcome> {
  const skip = (errorCode: string): Outcome => ({
    status: 'skipped',
    errorCode,
    countAttempt: false,
    exhaust: false,
    language: null,
    apnsId: null,
  });
  if (!row.in_audience || !row.token || !row.environment) return skip('audience_left');
  if (!broadcastMessagesEnabled(row.notifications_json)) return skip('preference_off');

  const language = pickBroadcastLanguage(row.settings_language);
  const result: ApnsResult = await sendAlert({
    token: row.token,
    environment: row.environment as ApnsEnvironment,
    collapseKey: `broadcast:${broadcast.id}`,
    title: language === 'en' ? broadcast.title_en : broadcast.title_ar,
    body: language === 'en' ? broadcast.body_en : broadcast.body_ar,
    // No payloadId key: the iOS host treats any payloadId as a capture push.
    data: {
      notificationType: BROADCAST_SOURCE,
      source: BROADCAST_SOURCE,
      broadcastId: broadcast.id,
      route: broadcast.deep_link ?? '',
    },
  });
  if (result.ok) {
    return { status: 'sent', errorCode: null, countAttempt: true, exhaust: false, language, apnsId: result.apnsId };
  }
  if (result.reason === 'apns_not_configured') {
    // Nothing reached Apple: fail closed, keep the row retryable, burn no attempt.
    return {
      status: 'failed',
      errorCode: 'apns_not_configured',
      countAttempt: false,
      exhaust: false,
      language,
      apnsId: null,
    };
  }
  if (isDeadApnsToken(result)) {
    await clearDeadApnsToken(supabase, row.device_hash, row.token);
    return { status: 'failed', errorCode: result.reason, countAttempt: true, exhaust: true, language, apnsId: null };
  }
  return { status: 'failed', errorCode: result.reason, countAttempt: true, exhaust: false, language, apnsId: null };
}
