-- SQL proof for 20261116150000_shared_merchant_category_learning.
-- Run against a LOCAL Postgres ONLY. Everything is rolled back.
--
--   { echo 'BEGIN;'; sed '/^BEGIN;$/d;/^COMMIT;$/d' supabase/migrations/20261116150000_shared_merchant_category_learning.sql;
--     cat supabase/tests/shared_merchant_category_learning_20261116.sql; echo 'ROLLBACK;'; } \
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

-- Fixtures: an admin, a non-admin, a clean slate for the proof merchants.
INSERT INTO auth.users (id) VALUES ('5a1e0000-0000-0000-0000-00000000ad01');
INSERT INTO public.admin_users (id, note)
VALUES ('5a1e0000-0000-0000-0000-00000000ad01', 'shared learning proof');
DELETE FROM public.merchant_keywords WHERE upper(keyword) IN ('PROOF CAFE', 'PROOF SHOP', 'PROOF RARE');

CREATE OR REPLACE FUNCTION pg_temp.u(n int) RETURNS uuid LANGUAGE sql AS $$
  SELECT ('5a1e0000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
$$;
CREATE OR REPLACE FUNCTION pg_temp.contribute(n int, m text, c text) RETURNS void LANGUAGE sql AS $$
  SELECT public.submit_merchant_category_contribution(pg_temp.u(n), m, c)
$$;

-- 1. distinct-user counting; a repeat from the same user counts once
SELECT pg_temp.contribute(i, 'PROOF CAFE', 'cafes') FROM generate_series(1, 5) i;
SELECT pg_temp.contribute(1, 'PROOF CAFE', 'cafes');
SELECT pg_temp.contribute(1, 'PROOF CAFE', 'cafes');
INSERT INTO _r SELECT 'five users, repeats from one user counted once',
  count(*) = 5, count(*)::text
  FROM public.merchant_category_contributions WHERE merchant_key = 'PROOF CAFE';

-- a user changing their mind moves their single vote, never adds one
SELECT pg_temp.contribute(6, 'PROOF CAFE', 'cafes');
SELECT pg_temp.contribute(6, 'PROOF CAFE', 'restaurants');
INSERT INTO _r SELECT 'changed vote replaces, not adds',
  (SELECT count(*) FROM public.merchant_category_contributions WHERE merchant_key = 'PROOF CAFE') = 6
  AND (SELECT count(*) FROM public.merchant_category_contributions
       WHERE merchant_key = 'PROOF CAFE' AND category_key = 'cafes') = 5, '';

-- only an HMAC is stored, never the user id
INSERT INTO _r SELECT 'no raw user id stored',
  NOT EXISTS (SELECT 1 FROM public.merchant_category_contributions
              WHERE contributor_hash LIKE '%5a1e0000%'), '';

-- 2. below threshold is not a candidate
SELECT pg_temp.contribute(i, 'PROOF SHOP', 'shopping') FROM generate_series(1, 4) i;
SELECT pg_temp.contribute(1, 'PROOF SHOP', 'shopping');
INSERT INTO _r SELECT 'four users (plus a repeat) is below threshold',
  NOT EXISTS (SELECT 1 FROM public.admin_list_merchant_category_candidates('5a1e0000-0000-0000-0000-00000000ad01')
              WHERE merchant_key = 'PROOF SHOP'), '';
INSERT INTO _r SELECT 'five users is a candidate',
  EXISTS (SELECT 1 FROM public.admin_list_merchant_category_candidates('5a1e0000-0000-0000-0000-00000000ad01')
          WHERE merchant_key = 'PROOF CAFE' AND category_key = 'cafes' AND user_count = 5
            AND merchant_user_count = 6), '';
SELECT pg_temp.expect_err('approving a below-threshold pair is refused',
  $q$SELECT public.admin_review_merchant_category_candidate('5a1e0000-0000-0000-0000-00000000ad01',
     'PROOF SHOP', 'shopping', 'approved')$q$, 'P0409');

-- 3. non-admin cannot list or approve; client roles cannot even call
SELECT pg_temp.expect_err('non-admin actor cannot approve',
  $q$SELECT public.admin_review_merchant_category_candidate(pg_temp.u(1), 'PROOF CAFE', 'cafes', 'approved')$q$,
  'P0403');
SELECT pg_temp.expect_err('non-admin actor cannot list',
  $q$SELECT * FROM public.admin_list_merchant_category_candidates(pg_temp.u(1))$q$, 'P0403');
INSERT INTO _r SELECT 'authenticated cannot execute review/submit/list',
  NOT has_function_privilege('authenticated',
        'public.admin_review_merchant_category_candidate(uuid,text,text,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated',
        'public.submit_merchant_category_contribution(uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon',
        'public.admin_list_merchant_category_candidates(uuid)', 'EXECUTE'), '';
INSERT INTO _r SELECT 'no API role can read contributions or the salt',
  NOT has_table_privilege('service_role', 'public.merchant_category_contributions', 'SELECT')
  AND NOT has_table_privilege('authenticated', 'public.merchant_category_contributions', 'SELECT')
  AND NOT has_table_privilege('service_role', 'public.merchant_contribution_secret', 'SELECT'), '';

-- 4. invalid contributions are refused
SELECT pg_temp.expect_err('transfers category refused',
  $q$SELECT pg_temp.contribute(1, 'PROOF CAFE', 'transfers')$q$, 'P0422');
SELECT pg_temp.expect_err('merchant key with digits refused',
  $q$SELECT pg_temp.contribute(1, 'CAFE 0551234567', 'cafes')$q$, 'P0422');
SELECT pg_temp.expect_err('lower-case (un-normalised) key refused',
  $q$SELECT pg_temp.contribute(1, 'proof cafe', 'cafes')$q$, 'P0422');
SELECT pg_temp.expect_err('unknown category refused',
  $q$SELECT pg_temp.contribute(1, 'PROOF CAFE', 'no_such_category')$q$, 'P0422');

-- 5. only approved mappings reach the catalog devices pull
INSERT INTO _r SELECT 'nothing in the catalog before approval',
  NOT EXISTS (SELECT 1 FROM public.merchant_keywords WHERE upper(keyword) IN ('PROOF CAFE', 'PROOF SHOP')), '';
CREATE TEMP TABLE _v AS SELECT version FROM public.catalog_versions WHERE category = 'merchant_keywords';
SELECT pg_temp.expect_ok('admin approves with an edited category',
  $q$SELECT public.admin_review_merchant_category_candidate('5a1e0000-0000-0000-0000-00000000ad01',
     'PROOF CAFE', 'cafes', 'approved', 'restaurants')$q$);
INSERT INTO _r SELECT 'approved mapping is in merchant_keywords (active, global)',
  EXISTS (SELECT 1 FROM public.merchant_keywords WHERE keyword = 'PROOF CAFE' AND category_key = 'restaurants'
          AND is_active AND NOT is_deleted AND country_code = 'ALL'), '';
INSERT INTO _r SELECT 'catalog version bumped so devices receive it',
  (SELECT version FROM public.catalog_versions WHERE category = 'merchant_keywords') > (SELECT version FROM _v), '';
INSERT INTO _r SELECT 'below-threshold merchant never reached the catalog',
  NOT EXISTS (SELECT 1 FROM public.merchant_keywords WHERE upper(keyword) = 'PROOF SHOP'), '';
INSERT INTO _r SELECT 'approved pair leaves the candidate list',
  NOT EXISTS (SELECT 1 FROM public.admin_list_merchant_category_candidates('5a1e0000-0000-0000-0000-00000000ad01')
              WHERE merchant_key = 'PROOF CAFE' AND category_key = 'cafes'), '';
SELECT pg_temp.expect_err('a reviewed pair cannot be reviewed again',
  $q$SELECT public.admin_review_merchant_category_candidate('5a1e0000-0000-0000-0000-00000000ad01',
     'PROOF CAFE', 'cafes', 'rejected')$q$, 'P0409');

-- 6. rejection: stays out of the catalog and does not come back
SELECT pg_temp.contribute(i, 'PROOF RARE', 'gifts') FROM generate_series(1, 5) i;
SELECT pg_temp.expect_ok('admin rejects',
  $q$SELECT public.admin_review_merchant_category_candidate('5a1e0000-0000-0000-0000-00000000ad01',
     'PROOF RARE', 'gifts', 'rejected')$q$);
SELECT pg_temp.contribute(i, 'PROOF RARE', 'gifts') FROM generate_series(6, 9) i;
INSERT INTO _r SELECT 'rejected pair not in catalog and not listed again',
  NOT EXISTS (SELECT 1 FROM public.merchant_keywords WHERE upper(keyword) = 'PROOF RARE')
  AND NOT EXISTS (SELECT 1 FROM public.admin_list_merchant_category_candidates('5a1e0000-0000-0000-0000-00000000ad01')
                  WHERE merchant_key = 'PROOF RARE'), '';

-- 7. deleting the auth user erases their contributions
INSERT INTO auth.users (id) VALUES (pg_temp.u(42));
SELECT pg_temp.contribute(42, 'PROOF SHOP', 'shopping');
DELETE FROM auth.users WHERE id = pg_temp.u(42);
INSERT INTO _r SELECT 'account deletion erases contributions',
  (SELECT count(*) FROM public.merchant_category_contributions WHERE merchant_key = 'PROOF SHOP') = 4, '';

SELECT name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM _r ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _r;
