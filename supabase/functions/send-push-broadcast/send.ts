// Sends one admin push broadcast (migration 20261116160000).
//
// Callers:
//  * the Admin panel's server route, forwarding the signed-in admin's access
//    token (send + the manual retry button). The JWT is resolved with the
//    service client and the user must be in public.admin_users; the claim RPC
//    re-checks that id. Never trust a role claim or a header.
//  * the pg_cron dispatcher (migration 20261116200000), presenting
//    PUSH_BROADCAST_WORKER_SECRET as a raw bearer. It resumes every recent
//    broadcast with deliveries due, through the backoff-aware claim. verify_jwt
//    is off for this function (config.toml) so that raw secret reaches here; the
//    admin path still verifies its JWT itself.
//
// Both paths claim through the same SQL lease (SKIP LOCKED + 'sending'), so a
// scheduled run and a manual run never hold, and never send, the same row.
//
// Per device, at send time: the claim RPC re-evaluates the Cloud audience, this
// function re-checks "Messages from Qirsh" and picks Arabic or English from the
// account's app language. Each claimed row is finished exactly once; only rows
// that were never delivered are ever claimed, so invoking this twice cannot
// send a device the same broadcast twice. Missing APNs credentials fail every
// row closed as `apns_not_configured` without consuming an attempt.
import { type ApnsEnvironment, type ApnsResult, sendApnsAlert } from '../_shared/apns.ts';
import { bearerSecretAuthorized, corsHeaders, json, serviceClient } from '../_shared/capture_auth.ts';
import { clearDeadApnsToken, isDeadApnsToken } from '../_shared/capture_push.ts';

/// `notificationType` and `source` of a broadcast push. The app routes a tap on
/// this source to the broadcast's deep link (or the announcements page).
export const BROADCAST_SOURCE = 'qirsh_broadcast';

const BATCH_SIZE = 100;
const MAX_BATCHES = 50;
/// No new batch is claimed after this long. Keeps every claimed row far inside
/// its 15-minute SQL lease (and the Edge wall clock); the rest is picked up by
/// the next scheduled run or click.
export const CLAIM_BUDGET_MS = 120_000;
/// Broadcasts one scheduled run resumes at most.
const SCHEDULED_BROADCASTS = 20;
/// APNs answers that no retry of this token can fix. Recorded as 'skipped'
/// (terminal). DeviceTokenNotForTopic is permanent for the token but can also
/// mean a wrong APNS_BUNDLE_ID, so the token itself is only cleared for the
/// dead-token codes isDeadApnsToken() already recognises.
const PERMANENT_TOKEN_CODES = new Set(['DeviceTokenNotForTopic']);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// deno-lint-ignore no-explicit-any -- the Supabase Edge client is loosely typed here.
type SupabaseClientLike = any;

type AdminAuth = { ok: true; userId: string } | { ok: false; status: number; error: string };

export type SendPushBroadcastDependencies = {
  createServiceClient: () => SupabaseClientLike;
  authenticateAdmin: (supabase: SupabaseClientLike, token: string) => Promise<AdminAuth>;
  sendAlert: typeof sendApnsAlert;
  newRunId: () => string;
  /// PUSH_BROADCAST_WORKER_SECRET; empty disables the scheduled path.
  workerSecret: () => string;
  /// False while any APNs credential is missing.
  apnsConfigured: () => boolean;
  now: () => number;
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
  workerSecret: () => Deno.env.get('PUSH_BROADCAST_WORKER_SECRET') ?? '',
  apnsConfigured: () =>
    ['APNS_KEY_ID', 'APNS_TEAM_ID', 'APNS_BUNDLE_ID', 'APNS_PRIVATE_KEY'].every((k) => !!Deno.env.get(k)),
  now: () => Date.now(),
};

type Totals = { claimed: number; sent: number; failed: number; skipped: number; not_configured: number };
type Claim = (limit: number) => PromiseLike<{ data: unknown; error: unknown }>;

const BROADCAST_COLUMNS = 'id,title_ar,title_en,body_ar,body_en,deep_link';

export async function handleSendPushBroadcast(
  req: Request,
  deps: SendPushBroadcastDependencies = defaultDependencies,
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const authHeader = req.headers.get('authorization') ?? '';
  if (bearerSecretAuthorized(authHeader, deps.workerSecret())) {
    return await runScheduled(deps);
  }
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
    .select(BROADCAST_COLUMNS)
    .eq('id', broadcastId)
    .maybeSingle();
  if (loaded.error) return json({ error: 'broadcast_lookup_failed' }, 500);
  if (!loaded.data) return json({ error: 'broadcast_not_found' }, 404);
  const broadcast = loaded.data as Broadcast;

  const runId = deps.newRunId();
  const deadline = deps.now() + CLAIM_BUDGET_MS;
  const run = await sendBroadcast(
    supabase,
    broadcast,
    deps,
    deadline,
    (limit) =>
      supabase.rpc('claim_push_broadcast_deliveries', {
        p_actor: auth.userId,
        p_broadcast_id: broadcastId,
        p_run_id: runId,
        p_limit: limit,
      }),
  );
  console.log(JSON.stringify({ event: 'push_broadcast_run', broadcastId, runId, ...run.totals }));
  if (!run.ok) return json({ error: 'claim_failed', ...run.totals }, 500);
  return json({ broadcast_id: broadcastId, run_id: runId, ...run.totals });
}

/// Scheduled path: resume every recent broadcast that has deliveries due under
/// the backoff. Never claims while APNs is unconfigured, so a missing key
/// leaves rows untouched (no attempt burned, nothing churned) for later.
async function runScheduled(deps: SendPushBroadcastDependencies): Promise<Response> {
  if (!deps.apnsConfigured()) {
    console.log(JSON.stringify({ event: 'push_broadcast_scheduled_skipped', reason: 'apns_not_configured' }));
    return json({ mode: 'scheduled', skipped: 'apns_not_configured', broadcasts: 0 });
  }
  const supabase = deps.createServiceClient();
  const due = await supabase.rpc('push_broadcast_retry_due', { p_limit: SCHEDULED_BROADCASTS });
  if (due.error) return json({ error: 'due_lookup_failed' }, 500);
  const ids = ((due.data ?? []) as { broadcast_id: string }[]).map((r) => r.broadcast_id);

  const runId = deps.newRunId();
  const deadline = deps.now() + CLAIM_BUDGET_MS;
  const totals: Totals = { claimed: 0, sent: 0, failed: 0, skipped: 0, not_configured: 0 };
  let broadcasts = 0;
  let errors = 0;
  for (const broadcastId of ids) {
    if (deps.now() >= deadline) break;
    const loaded = await supabase.from('push_broadcasts').select(BROADCAST_COLUMNS).eq('id', broadcastId)
      .maybeSingle();
    if (loaded.error || !loaded.data) {
      errors++;
      continue;
    }
    broadcasts++;
    const run = await sendBroadcast(
      supabase,
      loaded.data as Broadcast,
      deps,
      deadline,
      (limit) =>
        supabase.rpc('claim_push_broadcast_retry_deliveries', {
          p_broadcast_id: broadcastId,
          p_run_id: runId,
          p_limit: limit,
        }),
    );
    if (!run.ok) errors++;
    for (const k of Object.keys(totals) as (keyof Totals)[]) totals[k] += run.totals[k];
  }
  console.log(JSON.stringify({ event: 'push_broadcast_scheduled_run', runId, broadcasts, errors, ...totals }));
  return json({ mode: 'scheduled', run_id: runId, broadcasts, errors, ...totals }, errors > 0 ? 500 : 200);
}

/// Claims and delivers batches until nothing is left or the claim budget ends.
async function sendBroadcast(
  supabase: SupabaseClientLike,
  broadcast: Broadcast,
  deps: SendPushBroadcastDependencies,
  deadline: number,
  claim: Claim,
): Promise<{ ok: boolean; totals: Totals }> {
  const totals: Totals = { claimed: 0, sent: 0, failed: 0, skipped: 0, not_configured: 0 };
  for (let batch = 0; batch < MAX_BATCHES && deps.now() < deadline; batch++) {
    const claimed = await claim(BATCH_SIZE);
    // Claimed rows of a failed call stay 'sending' and become reclaimable after 15 minutes.
    if (claimed.error) return { ok: false, totals };
    const rows = (claimed.data ?? []) as ClaimedRow[];
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
  return { ok: true, totals };
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
  if (isDeadApnsToken(result) || PERMANENT_TOKEN_CODES.has(result.errorCode)) {
    // Permanent for this token: terminal 'skipped', never retried by either path.
    if (isDeadApnsToken(result)) await clearDeadApnsToken(supabase, row.device_hash, row.token);
    return { status: 'skipped', errorCode: result.reason, countAttempt: true, exhaust: false, language, apnsId: null };
  }
  return { status: 'failed', errorCode: result.reason, countAttempt: true, exhaust: false, language, apnsId: null };
}
