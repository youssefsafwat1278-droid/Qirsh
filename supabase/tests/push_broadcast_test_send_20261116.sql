-- SQL proof for 20261116230000_push_broadcast_test_send.
-- Run against a LOCAL Postgres ONLY, with 20261116160000 applied. Rolled back:
--   { echo 'BEGIN;'; sed '/^BEGIN;$/d;/^COMMIT;$/d' supabase/migrations/20261116230000_push_broadcast_test_send.sql;
--     cat supabase/tests/push_broadcast_test_send_20261116.sql; echo 'ROLLBACK;'; } | psql "$LOCAL_URL"

CREATE TEMP TABLE _r (name text, ok boolean, detail text);
CREATE FUNCTION pg_temp.ok(p_name text, p_cond boolean, p_detail text DEFAULT '') RETURNS void
LANGUAGE sql AS $$ INSERT INTO _r VALUES (p_name, coalesce(p_cond, false), p_detail) $$;
CREATE FUNCTION pg_temp.expect_err(p_name text, p_sql text, p_state text, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
    INSERT INTO _r VALUES (p_name, false, 'no error raised');
  EXCEPTION WHEN others THEN
    INSERT INTO _r VALUES (p_name, SQLSTATE = p_state AND SQLERRM = p_msg, SQLSTATE || ' ' || SQLERRM);
  END;
END $$;

-- A: Cloud on, 2 devices. B: Cloud on, 1 device, "Messages from Qirsh" OFF. Z: admin.
INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000007a1', 'tester.a@example.com'),
  ('00000000-0000-0000-0000-0000000007b1', 'tester.b@example.com'),
  ('00000000-0000-0000-0000-0000000007c1', 'tester.c@example.com'),
  ('00000000-0000-0000-0000-0000000007aa', NULL);
INSERT INTO public.admin_users (id) VALUES ('00000000-0000-0000-0000-0000000007aa');
INSERT INTO public.user_settings (user_id, local_id, language, notifications_json, cloud_processing_enabled, consent_version)
VALUES
  ('00000000-0000-0000-0000-0000000007a1', 'user_settings', 'ar', NULL, true, 3),
  ('00000000-0000-0000-0000-0000000007b1', 'user_settings', 'ar', '{"marketingMessages":false}', true, 3),
  ('00000000-0000-0000-0000-0000000007c1', 'user_settings', 'ar', NULL, true, 3);
INSERT INTO public.capture_devices
  (install_id_hash, device_secret_hash, user_id, consent_owner_uid, cloud_processing_enabled, ai_consent_granted,
   consent_version, apns_token, apns_environment)
VALUES
  ('pt-a1', 's', '00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000007a1', true, true, 3, 'tok-a1', 'production'),
  ('pt-a2', 's', '00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000007a1', true, true, 3, 'tok-a2', 'sandbox'),
  ('pt-b1', 's', '00000000-0000-0000-0000-0000000007b1', '00000000-0000-0000-0000-0000000007b1', true, true, 3, 'tok-b1', 'sandbox'),
  ('pt-c1', 's', '00000000-0000-0000-0000-0000000007c1', '00000000-0000-0000-0000-0000000007c1', true, true, 3, 'tok-c1', 'sandbox');

CREATE TEMP TABLE _ann AS SELECT count(*) AS n FROM public.announcements;

-- 1. by email (case-insensitive): only A's devices, no announcement
CREATE TEMP TABLE _t1 AS SELECT public.admin_create_push_broadcast_test(
  '00000000-0000-0000-0000-0000000007aa', '00000000-0000-0000-0000-000000007001',
  'تجربة', 'Test', 'نص', 'Body', '/budgets', '  Tester.A@Example.com ') AS r;
SELECT pg_temp.ok('email target: two devices, one user',
  (SELECT (r->>'devices')::int = 2 AND (r->>'users')::int = 1 AND (r->>'test')::boolean FROM _t1));
SELECT pg_temp.ok('deliveries are exactly the target''s devices',
  (SELECT array_agg(install_id_hash ORDER BY install_id_hash) = ARRAY['pt-a1', 'pt-a2']
     FROM public.push_broadcast_deliveries WHERE broadcast_id = (SELECT (r->>'broadcast_id')::uuid FROM _t1)));
SELECT pg_temp.ok('no in-app announcement for a test',
  (SELECT count(*) FROM public.announcements) = (SELECT n FROM _ann)
  AND (SELECT announcement_id IS NULL AND test_user_id = '00000000-0000-0000-0000-0000000007a1'
         FROM public.push_broadcasts WHERE id = (SELECT (r->>'broadcast_id')::uuid FROM _t1)));
SELECT pg_temp.ok('history marks it as a test',
  (SELECT (e->>'is_test')::boolean FROM jsonb_array_elements(
     public.admin_push_broadcast_history('00000000-0000-0000-0000-0000000007aa', 50)) e
   WHERE e->>'id' = (SELECT r->>'broadcast_id' FROM _t1)));

-- 2. replay is idempotent
SELECT pg_temp.ok('same operation id replays, adds nothing',
  (public.admin_create_push_broadcast_test('00000000-0000-0000-0000-0000000007aa', '00000000-0000-0000-0000-000000007001',
     'تجربة', 'Test', 'نص', 'Body', NULL, 'tester.a@example.com')->>'replayed')::boolean
  AND (SELECT count(*) FROM public.push_broadcasts WHERE operation_id = '00000000-0000-0000-0000-000000007001') = 1);

-- 3. by user id
SELECT pg_temp.ok('user-id target works',
  (public.admin_create_push_broadcast_test('00000000-0000-0000-0000-0000000007aa', '00000000-0000-0000-0000-000000007002',
     't', 't', 'b', 'b', NULL, '00000000-0000-0000-0000-0000000007c1')->>'devices')::int = 1);

-- 4. refusals
SELECT pg_temp.expect_err('preference off: no recipients',
  $q$SELECT public.admin_create_push_broadcast_test('00000000-0000-0000-0000-0000000007aa',
     '00000000-0000-0000-0000-000000007003', 't', 't', 'b', 'b', NULL, 'tester.b@example.com')$q$, 'P0422', 'no_recipients');
SELECT pg_temp.expect_err('unknown account',
  $q$SELECT public.admin_create_push_broadcast_test('00000000-0000-0000-0000-0000000007aa',
     '00000000-0000-0000-0000-000000007004', 't', 't', 'b', 'b', NULL, 'nobody@example.com')$q$, 'P0422', 'test_target_not_found');
SELECT pg_temp.expect_err('free text is not a target',
  $q$SELECT public.admin_create_push_broadcast_test('00000000-0000-0000-0000-0000000007aa',
     '00000000-0000-0000-0000-000000007005', 't', 't', 'b', 'b', NULL, '%')$q$, 'P0422', 'test_target_not_found');
SELECT pg_temp.expect_err('non-admin refused',
  $q$SELECT public.admin_create_push_broadcast_test('00000000-0000-0000-0000-0000000007a1',
     '00000000-0000-0000-0000-000000007006', 't', 't', 'b', 'b', NULL, 'tester.a@example.com')$q$, '42501', 'not_authorized');
SELECT pg_temp.expect_err('deep link outside the allowlist refused',
  $q$SELECT public.admin_create_push_broadcast_test('00000000-0000-0000-0000-0000000007aa',
     '00000000-0000-0000-0000-000000007007', 't', 't', 'b', 'b', 'https://evil', 'tester.a@example.com')$q$, 'P0422', 'deep_link_not_allowed');

-- 5. privileges
SELECT pg_temp.ok('service role only',
  NOT has_function_privilege('anon', 'public.admin_create_push_broadcast_test(uuid,uuid,text,text,text,text,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.admin_create_push_broadcast_test(uuid,uuid,text,text,text,text,text,text)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.admin_create_push_broadcast_test(uuid,uuid,text,text,text,text,text,text)', 'EXECUTE'));

SELECT name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM _r ORDER BY ok, name;
SELECT CASE WHEN bool_and(ok) THEN 'pass' ELSE 'fail' END AS proof,
       count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _r;
