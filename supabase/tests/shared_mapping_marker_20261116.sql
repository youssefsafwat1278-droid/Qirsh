-- SQL proof for 20261116190000_shared_mapping_marker.
-- Run against a LOCAL Postgres ONLY. Everything is rolled back. Needs
-- 20261116150000 and 20261116170000 first (applied or inlined):
--
--   { echo 'BEGIN;';
--     for m in 20261116150000_shared_merchant_category_learning 20261116170000_shared_learning_auto_approve 20261116190000_shared_mapping_marker; do
--       sed '/^BEGIN;$/d;/^COMMIT;$/d' supabase/migrations/$m.sql; done;
--     cat supabase/tests/shared_mapping_marker_20261116.sql; echo 'ROLLBACK;'; } \
--   | psql "$LOCAL_URL" -v ON_ERROR_STOP=1

CREATE TEMP TABLE _r (name text, ok boolean, detail text);

CREATE OR REPLACE FUNCTION pg_temp.u(n int) RETURNS uuid LANGUAGE sql AS $$
  SELECT ('5a1e0000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
$$;
CREATE OR REPLACE FUNCTION pg_temp.contribute(n int, m text, c text) RETURNS void LANGUAGE sql AS $$
  SELECT public.submit_merchant_category_contribution(pg_temp.u(n), m, c)
$$;
CREATE OR REPLACE FUNCTION pg_temp.prio(m text) RETURNS integer LANGUAGE sql AS $$
  SELECT priority FROM public.merchant_keywords
  WHERE upper(keyword) = m AND country_code = 'ALL' AND NOT is_deleted AND is_active
$$;
CREATE OR REPLACE FUNCTION pg_temp.version() RETURNS bigint LANGUAGE sql AS $$
  SELECT version FROM public.catalog_versions WHERE category = 'merchant_keywords'
$$;

INSERT INTO auth.users (id) VALUES ('5a1e0000-0000-0000-0000-00000000ad01');
INSERT INTO public.admin_users (id, note) VALUES ('5a1e0000-0000-0000-0000-00000000ad01', 'marker proof');
DELETE FROM public.merchant_keywords
 WHERE upper(keyword) IN ('MARK AUTO', 'MARK MANUAL', 'MARK CURATED', 'MARK OVER', 'MARK OLD');

INSERT INTO _r SELECT 'the reserved shared priority is 1000',
  public.merchant_category_shared_priority() = 1000, '';

-- 1. auto-approval publishes with the marker
SELECT pg_temp.contribute(i, 'MARK AUTO', 'cafes') FROM generate_series(1, 6) i;
INSERT INTO _r SELECT 'auto-approved mapping carries the shared priority',
  pg_temp.prio('MARK AUTO') = 1000, coalesce(pg_temp.prio('MARK AUTO')::text, 'none');

-- 2. a manual approval publishes with the marker
SELECT pg_temp.contribute(i, 'MARK MANUAL', 'groceries') FROM generate_series(1, 5) i;
SELECT public.admin_review_merchant_category_candidate('5a1e0000-0000-0000-0000-00000000ad01',
  'MARK MANUAL', 'groceries', 'approved');
INSERT INTO _r SELECT 'manually approved mapping carries the shared priority',
  pg_temp.prio('MARK MANUAL') = 1000, coalesce(pg_temp.prio('MARK MANUAL')::text, 'none');

-- 3. an admin approval that replaces a curated row marks that row
INSERT INTO public.merchant_keywords (keyword, category_key, country_code) VALUES ('MARK OVER', 'bills', 'ALL');
SELECT pg_temp.contribute(i, 'MARK OVER', 'shopping') FROM generate_series(1, 5) i;
SELECT public.admin_review_merchant_category_candidate('5a1e0000-0000-0000-0000-00000000ad01',
  'MARK OVER', 'shopping', 'approved');
INSERT INTO _r SELECT 'approval over a curated row marks it (one live row)',
  pg_temp.prio('MARK OVER') = 1000
  AND (SELECT count(*) FROM public.merchant_keywords
       WHERE upper(keyword) = 'MARK OVER' AND NOT is_deleted) = 1, '';

-- 4. other writers are untouched: a curated keyword stays at 0
INSERT INTO public.merchant_keywords (keyword, category_key, country_code) VALUES ('MARK CURATED', 'bills', 'ALL');
INSERT INTO _r SELECT 'a curated keyword keeps priority 0',
  pg_temp.prio('MARK CURATED') = 0, '';
SELECT pg_temp.contribute(i, 'MARK CURATED', 'shopping') FROM generate_series(1, 8) i;
INSERT INTO _r SELECT 'auto-approval still never replaces a curated keyword',
  pg_temp.prio('MARK CURATED') = 0
  AND EXISTS (SELECT 1 FROM public.merchant_keywords WHERE upper(keyword) = 'MARK CURATED'
              AND category_key = 'bills' AND is_active AND NOT is_deleted), '';

-- 5. the backfill marks a mapping published before this migration
SELECT pg_temp.contribute(i, 'MARK OLD', 'home') FROM generate_series(1, 6) i;
UPDATE public.merchant_keywords SET priority = 0 WHERE upper(keyword) = 'MARK OLD';
CREATE TEMP TABLE _v AS SELECT pg_temp.version() AS v;
UPDATE public.merchant_keywords k
   SET priority = public.merchant_category_shared_priority(), updated_at = now()
  FROM public.merchant_category_reviews r
 WHERE r.decision = 'approved'
   AND upper(k.keyword) = r.merchant_key
   AND k.category_key = r.published_category_key
   AND k.country_code = 'ALL'
   AND NOT k.is_deleted
   AND k.priority <> public.merchant_category_shared_priority();
INSERT INTO _r SELECT 'backfill marks an older published mapping',
  pg_temp.prio('MARK OLD') = 1000, '';
INSERT INTO _r SELECT 'marking bumps the catalog version (devices re-download)',
  pg_temp.version() > (SELECT v FROM _v), '';
INSERT INTO _r SELECT 'backfill leaves curated keywords alone',
  pg_temp.prio('MARK CURATED') = 0, '';

-- 6. revoke still soft-deletes the marked row
SELECT public.admin_revoke_merchant_category_mapping('5a1e0000-0000-0000-0000-00000000ad01', 'MARK AUTO', 'cafes');
INSERT INTO _r SELECT 'revoke removes the marked mapping',
  pg_temp.prio('MARK AUTO') IS NULL, '';

INSERT INTO _r SELECT 'publish stays unreachable from API roles',
  NOT has_function_privilege('authenticated', 'public.merchant_category_publish(text,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.merchant_category_publish(text,text)', 'EXECUTE')
  AND NOT has_function_privilege('service_role', 'public.merchant_category_publish(text,text)', 'EXECUTE'), '';

SELECT name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM _r ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _r;
