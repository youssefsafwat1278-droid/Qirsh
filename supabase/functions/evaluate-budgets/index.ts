import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.0';
import { sendCapturePush } from '../_shared/apns.ts';
import { timingSafeEqual } from '../_shared/capture_auth.ts';
import { anyDeviceRecentlyActive, isPushAllowed, loadNotificationPolicy } from '../_shared/notification_policy.ts';
import { budgetWindow, pendingCaptureSpend } from '../_shared/budget_capture_spend.ts';

// The client maps BudgetEntity.allExpensesCategoryId ('__all_expenses__') to
// this key when syncing budgets to user_budgets — see
// supabase_planning_support.dart serverCategoryKey().
export function normalizeBudgetWarning(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value)
    ? Math.min(100, Math.max(10, Math.round(value / 5) * 5)) : 80;
}

const ALL_EXPENSES_CATEGORY_ID = 'all_expenses';

// AUTH (migration 0099). This previously compared the caller's bearer against
// `SUPABASE_SERVICE_ROLE_KEY`. That name is PLATFORM-RESERVED: Supabase manages
// and rotates its value, and it differs from the project's real service-role
// JWT — so no caller, including the pg trigger dispatcher, could ever present
// it back. The comparison could therefore never succeed and this function was
// unreachable in production. Migration 0053 already solved exactly this for
// process-notification-retries, and purge-scheduled-deletions before it; this
// applies the same dedicated-worker-secret contract.
//
// The three evaluate-* functions SHARE one secret: they are one trust domain —
// same caller (the 0057 trigger layer), same capability (forge a push for an
// arbitrary user_id), same rotation lifecycle. Splitting them would not reduce
// blast radius, because all copies live in the same Vault and the same Edge
// env, so a compromise yielding one yields all three. cron-daily-reminders is
// deliberately NOT in this domain and holds its own secret.
//
// Fails closed: an empty configured secret rejects every request.
export async function handleEvaluateBudgets(req: Request, dependencies = { createClient, sendCapturePush }): Promise<Response> {
  // Service-only endpoint (MALI-004): the DB webhook (migration 0057) sends
  // the service-role key from Vault as its Bearer token. Anything else —
  // including a perfectly valid ordinary user JWT — must be rejected, because
  // the body's record.user_id is trusted blindly below.
  const authHeader = req.headers.get('authorization') ?? '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  const workerSecret = Deno.env.get('ENGAGEMENT_WORKER_SECRET') ?? '';
  if (!workerSecret || !timingSafeEqual(token, workerSecret)) {
    return new Response('Forbidden', { status: 403 });
  }

  const payload = await req.json();
  const transaction = payload.record;
  if (!transaction || !transaction.user_id) {
    return new Response('OK');
  }

  const userId = transaction.user_id;

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const supabase = dependencies.createClient(supabaseUrl, supabaseServiceKey);

  const { data: budgets, error: budgetError } = await supabase
    .from('user_budgets')
    .select('*')
    .eq('user_id', userId)
    .eq('is_active', true)
    .is('deleted_at', null);
  if (budgetError) throw budgetError;

  if (!budgets || budgets.length === 0) {
    return new Response('OK');
  }

  const { data: devices } = await supabase
    .from('capture_devices')
    .select('apns_token, apns_environment, install_id_hash, last_seen_at')
    .eq('user_id', userId)
    .eq('cloud_processing_enabled', true)
    .is('revoked_at', null)
    .not('apns_token', 'is', null);

  // MALI-061n — single-authority coordination. The LOCAL app fires the budget
  // alert immediately when it processes a transaction; this server path is only
  // the FALLBACK for when no device has been active recently (so the local
  // alert could not have fired). When a device IS recently active we still
  // advance the notified watermark (below) so the tier isn't re-pushed later,
  // but we do NOT push here — avoiding the local+server duplicate.
  const budgetFallbackWindowMs = 6 * 60 * 60 * 1000;
  const deviceRecentlyActive = anyDeviceRecentlyActive(
    (devices ?? []).map((d) => d.last_seen_at as string | null),
    Date.now(),
    budgetFallbackWindowMs,
  );

  // Server-side honoring of the user's notification preferences (MALI-019):
  // one load per request (userId is fixed here).
  const policy = await loadNotificationPolicy(supabase, userId);
  const backgroundCapture = typeof payload.capturePayloadId === 'string';
  // The worker secret authenticates the caller, but the event must still name
  // an actual finalized capture owned by this user.
  if (backgroundCapture) {
    const { data: capture, error } = await supabase.from('processed_captures')
      .select('payload_id').eq('payload_id', payload.capturePayloadId)
      .eq('owner_uid', userId).eq('status', 'processed')
      .in('state', ['processed', 'consumed']).maybeSingle();
    if (error || !capture) return new Response('Invalid capture', { status: 409 });
  }
  const offset = Number.isInteger(payload.tzOffsetMinutes) && Math.abs(payload.tzOffsetMinutes) <= 840
    ? payload.tzOffsetMinutes : (policy.utcOffsetHours ?? 0) * 60;
  const ar = String(payload.locale ?? 'ar').startsWith('ar');
  const { data: accounts, error: accountError } = await supabase.from('user_accounts')
    .select('id,local_id,currency').eq('user_id', userId).is('deleted_at', null)
    .order('is_default', { ascending: false }).order('sort_order').order('created_at');
  if (accountError) return new Response('Account read failed', { status: 500 });

  for (const budget of budgets) {
    if (!budget.amount || budget.amount <= 0) continue;

    // Scoped to the budget's current period (client resets start_date on
    // rollover), so this doesn't sum spend across every past period.
    const [from, to] = budgetWindow(budget.period, Date.now(), offset);
    let query = supabase
      .from('user_transactions')
      .select('amount,transaction_type')
      .eq('user_id', userId)
      .in('transaction_type', ['expense', 'refund'])
      .is('deleted_at', null)
      .eq('currency', budget.currency)
      .eq('status', 'confirmed')
      .gte('occurred_at', new Date(from).toISOString())
      .lt('occurred_at', new Date(to).toISOString());

    if (budget.category_id !== ALL_EXPENSES_CATEGORY_ID) {
      if (budget.user_category_id) {
        query = query.eq('user_category_id', budget.user_category_id);
      } else {
        query = query.eq('category_id', budget.category_id);
      }
    }
    if (budget.server_account_id) {
      const account = (accounts ?? []).find((a) => a.id === budget.server_account_id);
      if (account?.local_id) {
        // Older ledger rows can predate the server-account mapping. Resolve
        // their local ID through this owner's current account; a conflicting
        // non-null server link must never be matched by the local fallback.
        const quoted = `"${account.local_id.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
        query = query.or(`server_account_id.eq.${budget.server_account_id},and(server_account_id.is.null,local_account_id.eq.${quoted})`);
      } else {
        query = query.eq('server_account_id', budget.server_account_id);
      }
    } else if (budget.local_account_id) {
      query = query.eq('local_account_id', budget.local_account_id);
    }

    const { data: txs, error: txError } = await query;
    if (txError) throw txError;
    const { data: captures, error: captureError } = await supabase.from('processed_captures')
      .select('payload_id,parsed').eq('owner_uid', userId).eq('state', 'processed')
      .is('consumed_at', null);
    if (captureError) throw captureError;
    const ids = (captures ?? []).map((c) => c.payload_id);
    const ledgerIds = new Set<string>();
    if (ids.length) {
      const { data: imported, error } = await supabase.from('user_transactions')
        .select('client_request_id').eq('user_id', userId).in('client_request_id', ids);
      if (error) throw error;
      for (const tx of imported ?? []) ledgerIds.add(tx.client_request_id);
    }

    const currentSpend = Math.max(0, (txs || []).reduce((sum, tx) =>
      sum + (tx.transaction_type === 'refund' ? -1 : 1) * Number(tx.amount || 0), 0) +
      pendingCaptureSpend(captures ?? [], accounts ?? [], ledgerIds, budget, from, to));
    const lastNotified = Date.parse(budget.last_notified_period_start) === from
      ? Number(budget.last_notified_spent_amount || 0) : 0;

    const warning = normalizeBudgetWarning(budget.alert_threshold_percent);
    const thresholds = [...(warning < 100 ? [warning] : []), ...(warning < 90 ? [90] : []), 100];
    const bucketFor = (spend: number) => thresholds.filter(percent => spend >= budget.amount * percent / 100).at(-1) ?? 0;
    const bucket = bucketFor(currentSpend);
    if (bucket === 0) continue;
    const lastBucket = bucketFor(lastNotified);
    const crossedNewTier = bucket > lastBucket;
    const grewFurtherPastOver = bucket === 100 && lastBucket === 100 && currentSpend >= lastNotified + budget.amount * 0.1;
    if (!crossedNewTier && !grewFurtherPastOver) continue;

    let title: string;
    let body: string;
    if (bucket === 100) {
      title = 'تجاوزت ميزانيتك';
      body = `تجاوزت ميزانيتك بمقدار ${(currentSpend - budget.amount).toFixed(0)}؛ الإجمالي ${currentSpend.toFixed(0)} من ${budget.amount.toFixed(0)}.`;
    } else if (bucket === 90 && warning !== 90) {
      title = 'ميزانيتك على وشك الاكتمال';
      body = `بقيلك ${(budget.amount - currentSpend).toFixed(0)} فقط من ميزانيتك (${budget.amount.toFixed(0)}).`;
    } else {
      title = `وصلت ${warning.toLocaleString('ar-EG')}٪ من ميزانيتك`;
      body = `صرفت ${currentSpend.toFixed(0)} من ${budget.amount.toFixed(0)}.`;
    }
    if (!ar) {
      title = bucket === 100 ? 'Budget exceeded' : bucket === 90 && warning !== 90 ? 'Budget almost used up' : `Budget reached ${warning}%`;
      body = `Spent ${currentSpend.toFixed(2)} of ${Number(budget.amount).toFixed(2)} ${budget.currency}.`;
    }
    if (policy.hideLockScreenContent) body = ar ? 'افتح قرش لمراجعة ميزانيتك.' : 'Open Qirsh to review your budget.';

    // Respect the per-type toggle + quiet hours before touching state or
    // sending (MALI-019). Over-100% = budget_over, otherwise budget_warning.
    // We skip the last_notified bump too, so re-enabling the toggle later
    // still surfaces the tier the user is currently in.
    const budgetType = bucket === 100 ? 'budget_over' : 'budget_warning';
    if (!isPushAllowed(policy, budgetType)) continue;

    // A finalized Shortcut capture is processed while the app may be closed.
    // Device registration/Shortcut activity is not proof of a local alert.
    if (deviceRecentlyActive && !backgroundCapture) continue;

    if (devices && devices.length > 0) {
      let delivered = false;
      for (const device of devices) {
        const result = await dependencies.sendCapturePush({
          token: device.apns_token,
          environment: device.apns_environment as 'sandbox' | 'production',
          payloadId: `budget:${budget.id}:${from}:${bucket}`,
          title,
          body,
          notificationType: 'budget_alert',
        });
        delivered ||= result.ok;
      }
      if (delivered) await supabase.from('user_budgets')
        .update({ last_notified_spent_amount: currentSpend,
          last_notified_period_start: new Date(from).toISOString() }).eq('id', budget.id);
    }
  }

  return new Response('OK', { headers: { 'Content-Type': 'application/json' } });
}

if (import.meta.main) serve((req) => handleEvaluateBudgets(req));
