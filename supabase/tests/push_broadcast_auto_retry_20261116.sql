-- SQL proof for 20261116200000_push_broadcast_auto_retry.
-- Run against a LOCAL Postgres ONLY (a Supabase dev stack, or the dry-run
-- scaffold with the chain applied). Everything is rolled back.
--
-- Against a database that already has the migration:
--   { echo 'BEGIN;'; cat supabase/tests/push_broadcast_auto_retry_20261116.sql; echo 'ROLLBACK;'; } \
--   | psql "$LOCAL_URL" -v ON_ERROR_STOP=1 -q -t -A | tail -1
-- Against one that does not (the migration's lowercase begin;/commit; are stripped
-- so the outer ROLLBACK undoes it too):
--   { echo 'BEGIN;'; sed -E '/^(begin|BEGIN);$/d;/^(commit|COMMIT);$/d' \
--       supabase/migrations/20261116200000_push_broadcast_auto_retry.sql;
--     cat supabase/tests/push_broadcast_auto_retry_20261116.sql; echo 'ROLLBACK;'; } \
--   | psql "$LOCAL_URL" -v ON_ERROR_STOP=1 -q -t -A | tail -1
--
-- The last line is exactly `pass` or `fail (<n>): <names>`.
-- Time is simulated by moving the rows' own timestamps (now() is fixed inside
-- one transaction).

CREATE TEMP TABLE _r (name text, ok boolean, detail text);

CREATE FUNCTION pg_temp.ok(p_name text, p_cond boolean, p_detail text DEFAULT '') RETURNS void
LANGUAGE sql AS $$ INSERT INTO _r VALUES (p_name, coalesce(p_cond, false), p_detail) $$;

-- Outbound HTTP queued by pg_net: the scaffold stub logs to net._http_log, a
-- real stack queues into net.http_request_queue (rolled back, so never sent).
CREATE FUNCTION pg_temp.http_calls() RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  IF to_regclass('net._http_log') IS NOT NULL THEN
    EXECUTE $q$SELECT count(*) FROM net._http_log WHERE url LIKE '%/functions/v1/send-push-broadcast'$q$ INTO n;
  ELSE
    EXECUTE $q$SELECT count(*) FROM net.http_request_queue WHERE url LIKE '%/functions/v1/send-push-broadcast'$q$ INTO n;
  END IF;
  RETURN n;
END $$;

-- Admin Z, user A (Cloud ON) with three token-bearing devices.
INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-00000000a0a1'), ('00000000-0000-0000-0000-00000000a0aa');
INSERT INTO public.admin_users (id) VALUES ('00000000-0000-0000-0000-00000000a0aa');
INSERT INTO public.user_settings (user_id, local_id, language, notifications_json, cloud_processing_enabled, consent_version)
VALUES ('00000000-0000-0000-0000-00000000a0a1', 'user_settings', 'ar', NULL, true, 3);
INSERT INTO public.capture_devices
  (install_id_hash, device_secret_hash, user_id, consent_owner_uid, cloud_processing_enabled, ai_consent_granted,
   consent_version, apns_token, apns_environment)
SELECT 'ar-' || n, 's', '00000000-0000-0000-0000-00000000a0a1', '00000000-0000-0000-0000-00000000a0a1',
       true, true, 3, 'tok-' || n, 'sandbox'
  FROM generate_series(1, 3) n;

CREATE TEMP TABLE _b AS
SELECT (public.admin_create_push_broadcast('00000000-0000-0000-0000-00000000a0aa',
  '20261116-2000-4000-8000-000000000001', 'عنوان', 'Title', 'نص', 'Body', NULL,
  (SELECT count(*)::int FROM public.push_broadcast_audience_devices() WHERE messages_enabled)) ->> 'broadcast_id')::uuid AS id;

CREATE FUNCTION pg_temp.bid() RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM _b $$;
CREATE FUNCTION pg_temp.row_of(p_hash text) RETURNS public.push_broadcast_deliveries LANGUAGE sql AS $$
  SELECT * FROM public.push_broadcast_deliveries WHERE broadcast_id = pg_temp.bid() AND install_id_hash = p_hash $$;
-- Hashes claimed by one manual / one scheduled run (each call = a new sender run).
CREATE FUNCTION pg_temp.manual() RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(device_hash, ',' ORDER BY device_hash), '')
    FROM public.claim_push_broadcast_deliveries('00000000-0000-0000-0000-00000000a0aa', pg_temp.bid(),
           gen_random_uuid(), 100) $$;
CREATE FUNCTION pg_temp.scheduled() RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(device_hash, ',' ORDER BY device_hash), '')
    FROM public.claim_push_broadcast_retry_deliveries(pg_temp.bid(), gen_random_uuid(), 100) $$;
CREATE FUNCTION pg_temp.due() RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM public.push_broadcast_retry_due(100) WHERE broadcast_id = pg_temp.bid()) $$;
CREATE FUNCTION pg_temp.finish(p_hash text, p_status text, p_code text, p_count boolean) RETURNS boolean
LANGUAGE sql AS $$
  SELECT public.finish_push_broadcast_delivery((pg_temp.row_of(p_hash)).id, p_status, p_code, p_count, false, 'ar', NULL) $$;

-- 1. Backoff schedule.
SELECT pg_temp.ok('backoff grows 10/20/40/80 minutes per attempt',
  public.push_broadcast_retry_backoff(1) = interval '10 minutes'
  AND public.push_broadcast_retry_backoff(2) = interval '20 minutes'
  AND public.push_broadcast_retry_backoff(3) = interval '40 minutes'
  AND public.push_broadcast_retry_backoff(4) = interval '80 minutes');

-- 2. A fresh broadcast belongs to the admin's own send call for 5 minutes.
SELECT pg_temp.ok('fresh pending rows are not due for the scheduler', NOT pg_temp.due());
SELECT pg_temp.ok('scheduler claims nothing from a fresh broadcast', pg_temp.scheduled() = '');
SELECT pg_temp.ok('no HTTP dispatch when nothing is due',
  (SELECT pg_temp.http_calls() FROM (SELECT public.run_push_broadcast_retry_dispatch()) s) = 0);

-- 3. The admin's send died after creating the rows: the scheduler resumes them.
UPDATE public.push_broadcast_deliveries SET created_at = now() - interval '6 minutes' WHERE broadcast_id = pg_temp.bid();
SELECT pg_temp.ok('stale pending rows make the broadcast due', pg_temp.due());
CREATE TEMP TABLE _s1 AS SELECT pg_temp.scheduled() AS h;
SELECT pg_temp.ok('scheduler resumes every pending row', (SELECT h = 'ar-1,ar-2,ar-3' FROM _s1), (SELECT h FROM _s1));

-- 4. NO DOUBLE SEND: while the scheduler holds the rows, neither a manual run
--    nor another scheduled run can take them, even when they look due.
UPDATE public.push_broadcast_deliveries SET next_attempt_at = now() - interval '1 hour',
       claimed_at = now() - interval '14 minutes' WHERE broadcast_id = pg_temp.bid();
SELECT pg_temp.ok('manual run cannot claim rows a scheduled run is sending', pg_temp.manual() = '');
SELECT pg_temp.ok('a second scheduled run cannot claim them either', pg_temp.scheduled() = '');
SELECT pg_temp.ok('nothing is due while every row is leased', NOT pg_temp.due());
UPDATE public.push_broadcast_deliveries SET claimed_at = now() WHERE broadcast_id = pg_temp.bid();

-- 5. Outcomes: sent, transient failure, APNs not configured.
SELECT pg_temp.ok('finish ar-1 sent', pg_temp.finish('ar-1', 'sent', NULL, true));
SELECT pg_temp.ok('finish ar-2 transient failure', pg_temp.finish('ar-2', 'failed', 'apns_503_ServiceUnavailable', true));
SELECT pg_temp.ok('finish ar-3 not configured', pg_temp.finish('ar-3', 'failed', 'apns_not_configured', false));
SELECT pg_temp.ok('transient failure counts an attempt and waits 10 minutes',
  (pg_temp.row_of('ar-2')).attempt_count = 1 AND (pg_temp.row_of('ar-2')).next_attempt_at = now() + interval '10 minutes');
SELECT pg_temp.ok('not configured burns no attempt and waits 30 minutes',
  (pg_temp.row_of('ar-3')).attempt_count = 0 AND (pg_temp.row_of('ar-3')).next_attempt_at = now() + interval '30 minutes');
SELECT pg_temp.ok('a sent row has no next attempt',
  (pg_temp.row_of('ar-1')).status = 'sent' AND (pg_temp.row_of('ar-1')).next_attempt_at IS NULL);

-- 6. Backoff gates the scheduler only; the manual button still retries at once.
SELECT pg_temp.ok('scheduler waits out the backoff', pg_temp.scheduled() = '' AND NOT pg_temp.due());
CREATE TEMP TABLE _m1 AS SELECT pg_temp.manual() AS h;
SELECT pg_temp.ok('manual retry ignores the backoff and never re-takes the sent row',
  (SELECT h = 'ar-2,ar-3' FROM _m1), (SELECT h FROM _m1));
-- ... and while the manual run holds them, the scheduler cannot touch them.
UPDATE public.push_broadcast_deliveries SET next_attempt_at = now() - interval '1 hour'
 WHERE broadcast_id = pg_temp.bid() AND status = 'sending';
SELECT pg_temp.ok('scheduler cannot claim rows a manual run is sending', pg_temp.scheduled() = '');
SELECT pg_temp.ok('second transient failure waits 20 minutes',
  pg_temp.finish('ar-2', 'failed', 'apns_500_InternalServerError', true)
  AND (pg_temp.row_of('ar-2')).attempt_count = 2
  AND (pg_temp.row_of('ar-2')).next_attempt_at = now() + interval '20 minutes');
SELECT pg_temp.finish('ar-3', 'failed', 'apns_not_configured', false);

-- 7. Backoff elapsed: the scheduler retries; a dead token ends as skipped.
UPDATE public.push_broadcast_deliveries SET next_attempt_at = now() - interval '1 minute'
 WHERE broadcast_id = pg_temp.bid() AND status = 'failed';
SELECT pg_temp.ok('elapsed backoff makes the broadcast due', pg_temp.due());
CREATE TEMP TABLE _s2 AS SELECT pg_temp.scheduled() AS h;
SELECT pg_temp.ok('scheduler retries both failed rows', (SELECT h = 'ar-2,ar-3' FROM _s2), (SELECT h FROM _s2));
SELECT pg_temp.ok('dead token recorded as skipped',
  pg_temp.finish('ar-3', 'skipped', 'apns_410_Unregistered', true)
  AND (pg_temp.row_of('ar-3')).status = 'skipped' AND (pg_temp.row_of('ar-3')).next_attempt_at IS NULL);

-- 8. The 5-attempt cap still holds.
UPDATE public.push_broadcast_deliveries SET attempt_count = 4 WHERE id = (pg_temp.row_of('ar-2')).id;
SELECT pg_temp.ok('fifth failure exhausts the row with no next attempt',
  pg_temp.finish('ar-2', 'failed', 'apns_503_ServiceUnavailable', true)
  AND (pg_temp.row_of('ar-2')).attempt_count = 5);
UPDATE public.push_broadcast_deliveries SET next_attempt_at = now() - interval '1 day' WHERE broadcast_id = pg_temp.bid();
SELECT pg_temp.ok('exhausted, skipped and sent rows are never claimed by either path',
  pg_temp.scheduled() = '' AND pg_temp.manual() = '' AND NOT pg_temp.due());

-- 9. An abandoned 'sending' lease is reclaimable after 15 minutes, not before.
UPDATE public.push_broadcast_deliveries SET status = 'sending', attempt_count = 1, claimed_at = now() - interval '10 minutes'
 WHERE id = (pg_temp.row_of('ar-2')).id;
SELECT pg_temp.ok('a 10-minute-old lease is still held', pg_temp.scheduled() = '' AND pg_temp.manual() = '');
UPDATE public.push_broadcast_deliveries SET claimed_at = now() - interval '16 minutes' WHERE id = (pg_temp.row_of('ar-2')).id;
SELECT pg_temp.ok('a 16-minute-old lease makes the broadcast due', pg_temp.due());
SELECT pg_temp.ok('a 16-minute-old lease is reclaimed by the scheduler', pg_temp.scheduled() = 'ar-2');
SELECT pg_temp.finish('ar-2', 'failed', 'apns_503_ServiceUnavailable', true);

-- 10. History reports the next automatic retry.
SELECT pg_temp.ok('history reports next_auto_retry_at for a broadcast with retryable rows',
  (SELECT (e->>'next_auto_retry_at')::timestamptz = now() + interval '20 minutes'
     FROM jsonb_array_elements(public.admin_push_broadcast_history('00000000-0000-0000-0000-00000000a0aa', 10)) e
    WHERE (e->>'id')::uuid = pg_temp.bid()),
  public.admin_push_broadcast_history('00000000-0000-0000-0000-00000000a0aa', 10)::text);

-- 11. Only recent broadcasts are resumed automatically.
UPDATE public.push_broadcast_deliveries SET next_attempt_at = now() - interval '1 minute' WHERE id = (pg_temp.row_of('ar-2')).id;
UPDATE public.push_broadcasts SET created_at = now() - interval '73 hours' WHERE id = pg_temp.bid();
SELECT pg_temp.ok('a broadcast older than 72 hours is not resumed automatically',
  NOT pg_temp.due() AND pg_temp.scheduled() = '');
SELECT pg_temp.ok('history shows no automatic retry for it',
  (SELECT e->'next_auto_retry_at' = 'null'::jsonb
     FROM jsonb_array_elements(public.admin_push_broadcast_history('00000000-0000-0000-0000-00000000a0aa', 10)) e
    WHERE (e->>'id')::uuid = pg_temp.bid()));
SELECT pg_temp.ok('the manual button still retries it', pg_temp.manual() = 'ar-2');
SELECT pg_temp.finish('ar-2', 'failed', 'apns_503_ServiceUnavailable', true);
UPDATE public.push_broadcasts SET created_at = now() - interval '1 hour' WHERE id = pg_temp.bid();
UPDATE public.push_broadcast_deliveries SET next_attempt_at = now() - interval '1 minute' WHERE id = (pg_temp.row_of('ar-2')).id;

-- 12. Dispatcher: fails closed without its secret, posts with it.
DELETE FROM vault.secrets WHERE name = 'push_broadcast_worker_secret';
SELECT pg_temp.ok('due work but no worker secret: no HTTP dispatch',
  pg_temp.due() AND (SELECT pg_temp.http_calls() FROM (SELECT public.run_push_broadcast_retry_dispatch()) s) = 0);
SELECT vault.create_secret('http://proof.invalid', 'project_url')
 WHERE NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'project_url');
SELECT vault.create_secret('proof-worker-secret', 'push_broadcast_worker_secret');
SELECT pg_temp.ok('due work and a worker secret: exactly one POST to send-push-broadcast',
  (SELECT pg_temp.http_calls() FROM (SELECT public.run_push_broadcast_retry_dispatch()) s) = 1);
SELECT pg_temp.ok('the dispatch does not claim rows itself (the function does)',
  (pg_temp.row_of('ar-2')).status = 'failed');

-- 13. Privileges.
SELECT pg_temp.ok('client roles cannot execute the scheduled claim, due list or dispatcher',
  NOT has_function_privilege('anon', 'public.claim_push_broadcast_retry_deliveries(uuid, uuid, integer)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.claim_push_broadcast_retry_deliveries(uuid, uuid, integer)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.push_broadcast_retry_due(integer)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.run_push_broadcast_retry_dispatch()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.run_push_broadcast_retry_dispatch()', 'EXECUTE'));
SELECT pg_temp.ok('service_role cannot call the dispatcher or the raw shared claim',
  NOT has_function_privilege('service_role', 'public.run_push_broadcast_retry_dispatch()', 'EXECUTE')
  AND NOT has_function_privilege('service_role', 'public.push_broadcast_claim_rows(uuid, uuid, integer, boolean)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.push_broadcast_claim_rows(uuid, uuid, integer, boolean)', 'EXECUTE'));
SELECT pg_temp.ok('service_role can run the scheduled claim and due list',
  has_function_privilege('service_role', 'public.claim_push_broadcast_retry_deliveries(uuid, uuid, integer)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.push_broadcast_retry_due(integer)', 'EXECUTE'));

-- 14. Schedule: present exactly when pg_cron is installed.
SELECT pg_temp.ok('cron job scheduled iff pg_cron is installed',
  CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
       THEN EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'push-broadcast-retry' AND schedule = '*/10 * * * *'
                      AND command = 'select public.run_push_broadcast_retry_dispatch()')
       ELSE to_regclass('cron.job') IS NULL
            OR NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'push-broadcast-retry') END);

SELECT CASE WHEN bool_and(ok) THEN 'pass'
            ELSE 'fail (' || count(*) FILTER (WHERE NOT ok) || '): '
                 || string_agg(name || ' [' || detail || ']', '; ') FILTER (WHERE NOT ok) END
  FROM _r;
