// Drains due rows from notification_retry_queue and re-attempts the APNs
// send. Invoked periodically by pg_cron (see
// supabase/migrations/0052_notification_logs.sql,
// run_notification_retry_dispatch). See
// docs/NOTIFICATION_PIPELINE_AUDIT.md Phase 1, item 8 — retries are durable
// rows processed here, never a sleep loop inside process-ios-sms.
import { corsHeaders, json, serviceClient, timingSafeEqual } from '../_shared/capture_auth.ts';
import { retryWorkerClaim } from '../_shared/worker_claim_retry.ts';
import { processOne } from './process_one.ts';

export { processOne };

const BATCH_SIZE = 25;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });

  // Admin-only: this function is invoked by the scheduled pg_cron dispatch
  // (which authenticates with a dedicated worker secret) or manually by an
  // operator, never by a client. Gated by NOTIFICATION_RETRY_WORKER_SECRET
  // (set via `supabase secrets set`), not SUPABASE_SERVICE_ROLE_KEY: that
  // name is platform-reserved and its value is rotated/managed by Supabase
  // itself (confirmed to differ from the project's actual service-role JWT
  // — see the identical note in purge-scheduled-deletions/index.ts), so its
  // plaintext isn't something a caller could ever be given to present back.
  const authHeader = req.headers.get('authorization') ?? '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  const workerSecret = Deno.env.get('NOTIFICATION_RETRY_WORKER_SECRET') ?? '';
  if (!workerSecret || !timingSafeEqual(token, workerSecret)) {
    return json({ error: 'unauthorized' }, 401);
  }

  const supabase = serviceClient();
  // Atomic claim (FOR UPDATE SKIP LOCKED under the hood) so two overlapping
  // dispatch invocations can never claim, and therefore never send an APNs
  // push for, the same row — see claim_notification_retries() in
  // 0052_notification_logs.sql.
  const due = await retryWorkerClaim(() => supabase.rpc('claim_notification_retries', {
    p_limit: BATCH_SIZE,
  }));

  if (due.error) {
    console.error(JSON.stringify({ event: 'notification_retry_dispatch_failed', error: due.error.message }));
    return json({ error: 'query_failed' }, 500);
  }

  let processed = 0;
  let resolvedOk = 0;
  let exhausted = 0;

  for (const row of due.data ?? []) {
    processed++;
    const outcome = await processOne(
      supabase,
      row as {
        id: string;
        notification_log_id: string;
        install_id_hash: string;
        payload_id: string;
        attempt_number: number;
        max_attempts: number;
      },
    );
    if (outcome === 'sent') resolvedOk++;
    if (outcome === 'exhausted') exhausted++;
  }

  console.log(JSON.stringify({
    event: 'notification_retry_dispatch_complete',
    processed,
    resolvedOk,
    exhausted,
  }));
  return json({ processed, resolvedOk, exhausted });
});
