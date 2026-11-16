-- SQL proof for 20261116150000_admin_push_broadcasts.
-- Run against a LOCAL Postgres ONLY. Everything is rolled back.
--
--   { echo 'BEGIN;'; sed '/^BEGIN;$/d;/^COMMIT;$/d' supabase/migrations/20261116150000_admin_push_broadcasts.sql;
--     cat supabase/tests/admin_push_broadcasts_20261116.sql; echo 'ROLLBACK;'; } \
--   | psql "$LOCAL_URL" -v ON_ERROR_STOP=1
--
-- (The migration's own BEGIN/COMMIT are stripped so the outer ROLLBACK undoes it.)

CREATE TEMP TABLE _r (name text, ok boolean, detail text);
GRANT ALL ON _r TO anon, authenticated, service_role;

CREATE FUNCTION pg_temp.ok(p_name text, p_cond boolean, p_detail text DEFAULT '') RETURNS void
LANGUAGE sql AS $$ INSERT INTO _r VALUES (p_name, coalesce(p_cond, false), p_detail) $$;

CREATE FUNCTION pg_temp.expect_err(p_name text, p_sql text, p_state text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
    INSERT INTO _r VALUES (p_name, false, 'no error raised');
  EXCEPTION WHEN others THEN
    INSERT INTO _r VALUES (p_name, SQLSTATE = p_state, SQLSTATE || ' ' || SQLERRM);
  END;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.expect_err(text, text, text) TO anon, authenticated;

-- Users: A Cloud ON (2 devices, no preference blob), B Cloud OFF, C Cloud ON with
-- "Messages from Qirsh" OFF, D TRUE but never versioned (= OFF), F Cloud ON with the
-- device projection OFF, G Cloud ON with a revoked device, Z the admin (no device).
INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b1'),
  ('00000000-0000-0000-0000-0000000000c1'), ('00000000-0000-0000-0000-0000000000d1'),
  ('00000000-0000-0000-0000-0000000000f1'), ('00000000-0000-0000-0000-0000000000e1'),
  ('00000000-0000-0000-0000-0000000000aa');
INSERT INTO public.admin_users (id) VALUES ('00000000-0000-0000-0000-0000000000aa');

INSERT INTO public.user_settings (user_id, local_id, language, notifications_json, cloud_processing_enabled, consent_version)
VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'user_settings', 'en', NULL, true, 3),
  ('00000000-0000-0000-0000-0000000000b1', 'user_settings', 'ar', NULL, false, 3),
  ('00000000-0000-0000-0000-0000000000c1', 'user_settings', 'ar', '{"marketingMessages":false,"budgetWarning":true}', true, 3),
  ('00000000-0000-0000-0000-0000000000d1', 'user_settings', 'ar', NULL, true, 0),
  ('00000000-0000-0000-0000-0000000000f1', 'user_settings', 'ar', '{"marketingMessages":true}', true, 3),
  ('00000000-0000-0000-0000-0000000000e1', 'user_settings', 'ar', NULL, true, 3);

INSERT INTO public.capture_devices
  (install_id_hash, device_secret_hash, user_id, consent_owner_uid, cloud_processing_enabled, ai_consent_granted,
   consent_version, apns_token, apns_environment, revoked_at)
VALUES
  ('pb-a1', 's', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1', true, true, 3, 'tok-a1', 'sandbox', NULL),
  ('pb-a2', 's', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1', true, true, 3, 'tok-a2', 'production', NULL),
  ('pb-a3', 's', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1', true, true, 3, NULL, NULL, NULL),
  ('pb-b1', 's', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', true, true, 3, 'tok-b1', 'sandbox', NULL),
  ('pb-c1', 's', '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c1', true, true, 3, 'tok-c1', 'sandbox', NULL),
  ('pb-d1', 's', '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d1', true, true, 3, 'tok-d1', 'sandbox', NULL),
  ('pb-f1', 's', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f1', false, false, 3, 'tok-f1', 'sandbox', NULL),
  ('pb-e1', 's', '00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e1', true, true, 3, 'tok-e1', 'sandbox', now());

-- 1. Audience: only A's two token-bearing devices.
SELECT pg_temp.ok('dry run counts only Cloud-ON, preference-ON, token-bearing devices',
  public.admin_push_broadcast_dry_run('00000000-0000-0000-0000-0000000000aa') = '{"devices": 2, "users": 1}'::jsonb,
  public.admin_push_broadcast_dry_run('00000000-0000-0000-0000-0000000000aa')::text);
SELECT pg_temp.ok('Cloud-OFF user excluded',
  NOT EXISTS (SELECT 1 FROM public.push_broadcast_audience_devices() WHERE install_id_hash = 'pb-b1'));
SELECT pg_temp.ok('unversioned Cloud TRUE excluded',
  NOT EXISTS (SELECT 1 FROM public.push_broadcast_audience_devices() WHERE install_id_hash = 'pb-d1'));
SELECT pg_temp.ok('device projection OFF excluded',
  NOT EXISTS (SELECT 1 FROM public.push_broadcast_audience_devices() WHERE install_id_hash = 'pb-f1'));
SELECT pg_temp.ok('revoked device excluded',
  NOT EXISTS (SELECT 1 FROM public.push_broadcast_audience_devices() WHERE install_id_hash = 'pb-e1'));
SELECT pg_temp.ok('"Messages from Qirsh" OFF reported and excluded from the count',
  (SELECT NOT messages_enabled FROM public.push_broadcast_audience_devices() WHERE install_id_hash = 'pb-c1'));
SELECT pg_temp.ok('preference: absent / malformed / true read as ON, false as OFF',
  public.push_broadcast_messages_enabled(NULL) AND public.push_broadcast_messages_enabled('{not json')
  AND public.push_broadcast_messages_enabled('{"marketingMessages":true}')
  AND NOT public.push_broadcast_messages_enabled('{"marketingMessages":false}'));

-- 2. Authorization: non-admin actor, and direct client roles.
SELECT pg_temp.expect_err('dry run refuses a non-admin actor',
  $q$SELECT public.admin_push_broadcast_dry_run('00000000-0000-0000-0000-0000000000a1')$q$, '42501');
SELECT pg_temp.expect_err('create refuses a non-admin actor',
  $q$SELECT public.admin_create_push_broadcast('00000000-0000-0000-0000-0000000000a1', gen_random_uuid(),
       't', 't', 'b', 'b', NULL, 2)$q$, '42501');
SELECT pg_temp.expect_err('create refuses a null actor',
  $q$SELECT public.admin_create_push_broadcast(NULL, gen_random_uuid(), 't', 't', 'b', 'b', NULL, 2)$q$, '42501');

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000aa","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
-- Even the admin's own JWT cannot reach the RPCs or tables directly.
SELECT pg_temp.expect_err('authenticated cannot execute create',
  $q$SELECT public.admin_create_push_broadcast('00000000-0000-0000-0000-0000000000aa', gen_random_uuid(),
       't', 't', 'b', 'b', NULL, 2)$q$, '42501');
SELECT pg_temp.expect_err('authenticated cannot execute claim',
  $q$SELECT * FROM public.claim_push_broadcast_deliveries('00000000-0000-0000-0000-0000000000aa', gen_random_uuid(),
       gen_random_uuid(), 10)$q$,
  '42501');
SELECT pg_temp.expect_err('authenticated cannot read deliveries',
  $q$SELECT count(*) FROM public.push_broadcast_deliveries$q$, '42501');
SELECT pg_temp.expect_err('authenticated cannot insert broadcasts',
  $q$INSERT INTO public.push_broadcasts (operation_id, created_by, title_ar, title_en, body_ar, body_en,
       recipient_devices, recipient_users) VALUES (gen_random_uuid(), gen_random_uuid(), 't', 't', 'b', 'b', 0, 0)$q$,
  '42501');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.expect_err('anon cannot execute dry run',
  $q$SELECT public.admin_push_broadcast_dry_run('00000000-0000-0000-0000-0000000000aa')$q$, '42501');
RESET ROLE;

-- 3. Create: typed count must match, links are allowlisted, replay is idempotent.
SELECT pg_temp.expect_err('stale confirmed count refused',
  $q$SELECT public.admin_create_push_broadcast('00000000-0000-0000-0000-0000000000aa', gen_random_uuid(),
       't', 't', 'b', 'b', NULL, 3)$q$, 'P0409');
SELECT pg_temp.expect_err('deep link outside the allowlist refused',
  $q$SELECT public.admin_create_push_broadcast('00000000-0000-0000-0000-0000000000aa', gen_random_uuid(),
       't', 't', 'b', 'b', 'https://evil.example', 2)$q$, 'P0422');
SELECT pg_temp.expect_err('empty English body refused',
  $q$SELECT public.admin_create_push_broadcast('00000000-0000-0000-0000-0000000000aa', gen_random_uuid(),
       't', 't', 'b', '  ', NULL, 2)$q$, 'P0422');

CREATE TEMP TABLE _b AS
SELECT public.admin_create_push_broadcast('00000000-0000-0000-0000-0000000000aa',
  '20261116-0000-4000-8000-000000000001', 'عنوان', 'Title', 'نص', 'Body', '/budgets', 2) AS r;
SELECT pg_temp.ok('create returns 2 devices / 1 user', (SELECT r->>'devices' = '2' AND r->>'users' = '1' FROM _b),
  (SELECT r::text FROM _b));
SELECT pg_temp.ok('one pending delivery per device',
  (SELECT count(*) = 2 AND bool_and(status = 'pending') FROM public.push_broadcast_deliveries
    WHERE broadcast_id = (SELECT (r->>'broadcast_id')::uuid FROM _b)));
SELECT pg_temp.ok('stored as an info announcement carrying the deep link',
  EXISTS (SELECT 1 FROM public.announcements a WHERE a.id = (SELECT (r->>'announcement_id')::uuid FROM _b)
           AND a.severity = 'info' AND a.is_active AND a.action_url = '/budgets' AND a.title_en = 'Title'));
SELECT pg_temp.ok('replaying the operation id creates nothing new',
  (public.admin_create_push_broadcast('00000000-0000-0000-0000-0000000000aa',
     '20261116-0000-4000-8000-000000000001', 'x', 'x', 'x', 'x', NULL, 99) ->> 'replayed') = 'true'
  AND (SELECT count(*) FROM public.push_broadcasts) = 1
  AND (SELECT count(*) FROM public.push_broadcast_deliveries) = 2);
SELECT pg_temp.expect_err('UNIQUE (broadcast, device) refuses a second row',
  format($q$INSERT INTO public.push_broadcast_deliveries (broadcast_id, install_id_hash) VALUES (%L, 'pb-a1')$q$,
         (SELECT r->>'broadcast_id' FROM _b)), '23505');

-- 4. Claim / finish / retry.
-- Each claim() is a fresh sender run; claim_in(run) reuses one.
CREATE FUNCTION pg_temp.claim_in(p_run uuid) RETURNS SETOF record LANGUAGE sql AS $$
  SELECT delivery_id, device_hash, attempts, in_audience
    FROM public.claim_push_broadcast_deliveries('00000000-0000-0000-0000-0000000000aa',
           (SELECT (r->>'broadcast_id')::uuid FROM _b), p_run, 100) $$;
CREATE FUNCTION pg_temp.claim() RETURNS SETOF record LANGUAGE sql AS $$
  SELECT * FROM pg_temp.claim_in(gen_random_uuid()) AS (id uuid, h text, n int, aud boolean) $$;
CREATE TEMP TABLE _c1 AS SELECT * FROM pg_temp.claim_in('20261116-0000-4000-8000-0000000000f1')
  AS (id uuid, h text, n int, aud boolean);
SELECT pg_temp.ok('first claim takes both rows, both still in audience',
  (SELECT count(*) = 2 AND bool_and(aud) FROM _c1));
SELECT pg_temp.ok('a concurrent/second claim takes nothing while rows are sending',
  (SELECT count(*) = 0 FROM pg_temp.claim() AS (id uuid, h text, n int, aud boolean)));
SELECT pg_temp.expect_err('claim refuses a non-admin actor',
  format($q$SELECT * FROM public.claim_push_broadcast_deliveries('00000000-0000-0000-0000-0000000000a1', %L, gen_random_uuid(), 10)$q$,
         (SELECT r->>'broadcast_id' FROM _b)), '42501');

SELECT pg_temp.ok('finish a1 as sent',
  public.finish_push_broadcast_delivery((SELECT id FROM _c1 WHERE h = 'pb-a1'), 'sent', NULL, true, false, 'en', 'apns-1'));
SELECT pg_temp.ok('finish a2 as apns_not_configured without burning an attempt',
  public.finish_push_broadcast_delivery((SELECT id FROM _c1 WHERE h = 'pb-a2'), 'failed', 'apns_not_configured',
    false, false, NULL, NULL));
SELECT pg_temp.ok('a late duplicate finish is a no-op',
  NOT public.finish_push_broadcast_delivery((SELECT id FROM _c1 WHERE h = 'pb-a1'), 'failed', 'x', true, false, NULL, NULL)
  AND (SELECT status = 'sent' FROM public.push_broadcast_deliveries WHERE install_id_hash = 'pb-a1'));

SELECT pg_temp.ok('the same run never re-claims the row it just failed',
  (SELECT count(*) = 0 FROM pg_temp.claim_in('20261116-0000-4000-8000-0000000000f1') AS (id uuid, h text, n int, aud boolean)));
CREATE TEMP TABLE _c2 AS SELECT * FROM pg_temp.claim() AS (id uuid, h text, n int, aud boolean);
SELECT pg_temp.ok('retry claims only the undelivered row, attempts unchanged',
  (SELECT count(*) = 1 AND min(h) = 'pb-a2' AND min(n) = 0 FROM _c2), (SELECT string_agg(h, ',') FROM _c2));

-- The user turns Cloud OFF between queue and send: the claim reports it.
UPDATE public.user_settings SET cloud_processing_enabled = false WHERE user_id = '00000000-0000-0000-0000-0000000000a1';
SELECT public.finish_push_broadcast_delivery((SELECT id FROM _c2), 'failed', 'apns_500_x', true, false, NULL, NULL);
SELECT pg_temp.ok('a user who left the audience is reported out of audience at send time',
  (SELECT count(*) = 1 AND NOT bool_or(aud) FROM pg_temp.claim() AS (id uuid, h text, n int, aud boolean)));
UPDATE public.push_broadcast_deliveries SET status = 'failed', attempt_count = 5 WHERE install_id_hash = 'pb-a2';
SELECT pg_temp.ok('an exhausted row is never claimed again',
  (SELECT count(*) = 0 FROM pg_temp.claim() AS (id uuid, h text, n int, aud boolean)));

-- 5. History counts.
SELECT pg_temp.ok('history reports per-status counts',
  (SELECT e->>'sent' = '1' AND e->>'failed' = '1' AND e->>'pending' = '0' AND e->>'retryable' = '0'
     FROM jsonb_array_elements(public.admin_push_broadcast_history('00000000-0000-0000-0000-0000000000aa', 10)) e),
  public.admin_push_broadcast_history('00000000-0000-0000-0000-0000000000aa', 10)::text);

SELECT name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM _r ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _r;
