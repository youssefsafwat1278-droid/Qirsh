-- SQL proof for 20261116120000_announcement_update_severities.
-- Run against a LOCAL Postgres ONLY. Everything is rolled back.
--
--   { echo 'BEGIN;'; sed '/^BEGIN;$/d;/^COMMIT;$/d' supabase/migrations/20261116120000_announcement_update_severities.sql;
--     cat supabase/tests/announcement_update_severities_20261116.sql; echo 'ROLLBACK;'; } \
--   | psql "$LOCAL_URL" -v ON_ERROR_STOP=1
--
-- (The migration's own BEGIN/COMMIT are stripped so the outer ROLLBACK undoes it.)

CREATE TEMP TABLE _r (name text, ok boolean, detail text);

CREATE OR REPLACE FUNCTION pg_temp.expect_err(p_name text, p_sql text, p_state text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
    INSERT INTO _r VALUES (p_name, false, 'no error raised');
  EXCEPTION WHEN others THEN
    INSERT INTO _r VALUES (p_name, SQLSTATE = p_state, SQLSTATE || ' ' || SQLERRM);
  END;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.expect_ok(p_name text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
    INSERT INTO _r VALUES (p_name, true, '');
  EXCEPTION WHEN others THEN
    INSERT INTO _r VALUES (p_name, false, SQLSTATE || ' ' || SQLERRM);
  END;
END $$;

-- 1. the two new values are accepted, active, with no arming sentinel set
SELECT pg_temp.expect_ok('update_available accepted (active, no sentinel)',
  $q$INSERT INTO public.announcements (id, title_ar, title_en, severity, max_app_version, action_url, is_active)
     VALUES ('20261116-0000-0000-0000-000000000001', 'تحديث', 'Update', 'update_available', '1.0.0',
             'https://apps.apple.com/app/id0', true)$q$);
SELECT pg_temp.expect_ok('release_notes accepted (active, no sentinel)',
  $q$INSERT INTO public.announcements (id, title_ar, title_en, severity, is_active)
     VALUES ('20261116-0000-0000-0000-000000000002', 'الجديد', 'New', 'release_notes', true)$q$);

-- 2. an unknown value is still rejected by the CHECK constraint
SELECT pg_temp.expect_err('unknown severity rejected',
  $q$INSERT INTO public.announcements (title_ar, title_en, severity) VALUES ('x', 'x', 'update_required')$q$,
  '23514');

-- 3. only force_update blocks clients
INSERT INTO _r SELECT 'update_available does not block',
  NOT public.announcement_blocks_clients('update_available', true, NULL), '';
INSERT INTO _r SELECT 'release_notes does not block',
  NOT public.announcement_blocks_clients('release_notes', true, NULL), '';
INSERT INTO _r SELECT 'force_update still blocks',
  public.announcement_blocks_clients('force_update', true, NULL), '';

-- 4. arming still refuses a force_update written without arm_force_update()
SELECT pg_temp.expect_err('force_update still needs arm_force_update()',
  $q$INSERT INTO public.announcements (title_ar, title_en, severity, action_url, is_active)
     VALUES ('x', 'x', 'force_update', 'https://example.test', true)$q$,
  '42501');
-- re-typing an active update_available row into force_update is an arming too
SELECT pg_temp.expect_err('update_available -> force_update re-type needs arm_force_update()',
  $q$UPDATE public.announcements SET severity = 'force_update'
     WHERE id = '20261116-0000-0000-0000-000000000001'$q$,
  '42501');
-- and arm_force_update() refuses to arm a non-force_update row
SELECT pg_temp.expect_err('arm_force_update() refuses update_available',
  $q$SELECT public.arm_force_update('20261116-0000-0000-0000-000000000001', 'proof run', NULL)$q$,
  '23514');

SELECT name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM _r ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _r;
