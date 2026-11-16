-- SQL proof for 20261116170000_shared_learning_auto_approve.
-- Run against a LOCAL Postgres ONLY. Everything is rolled back. Needs
-- 20261116150000 first (applied or inlined):
--
--   { echo 'BEGIN;';
--     for m in 20261116150000_shared_merchant_category_learning 20261116170000_shared_learning_auto_approve; do
--       sed '/^BEGIN;$/d;/^COMMIT;$/d' supabase/migrations/$m.sql; done;
--     cat supabase/tests/shared_learning_auto_approve_20261116.sql; echo 'ROLLBACK;'; } \
--   | psql "$LOCAL_URL" -v ON_ERROR_STOP=1

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

CREATE OR REPLACE FUNCTION pg_temp.u(n int) RETURNS uuid LANGUAGE sql AS $$
  SELECT ('5a1e0000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
$$;
CREATE OR REPLACE FUNCTION pg_temp.contribute(n int, m text, c text) RETURNS void LANGUAGE sql AS $$
  SELECT public.submit_merchant_category_contribution(pg_temp.u(n), m, c)
$$;
CREATE OR REPLACE FUNCTION pg_temp.kw(m text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.merchant_keywords WHERE upper(keyword) = m
$$;
CREATE OR REPLACE FUNCTION pg_temp.live(m text, c text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM public.merchant_keywords WHERE upper(keyword) = m AND category_key = c
                 AND is_active AND NOT is_deleted AND country_code = 'ALL')
$$;
CREATE OR REPLACE FUNCTION pg_temp.version() RETURNS bigint LANGUAGE sql AS $$
  SELECT version FROM public.catalog_versions WHERE category = 'merchant_keywords'
$$;

INSERT INTO auth.users (id) VALUES ('5a1e0000-0000-0000-0000-00000000ad01');
INSERT INTO public.admin_users (id, note) VALUES ('5a1e0000-0000-0000-0000-00000000ad01', 'auto-approve proof');
DELETE FROM public.merchant_keywords
 WHERE upper(keyword) IN ('AUTO CAFE', 'AUTO SPLIT', 'AUTO REJ', 'AUTO HELD', 'AUTO KW', 'AUTO TWICE');

INSERT INTO _r SELECT 'thresholds are 5 (candidate), 6 users and 75% (auto)',
  public.merchant_category_candidate_min_users() = 5
  AND public.merchant_category_auto_min_users() = 6
  AND public.merchant_category_auto_min_percent() = 75, '';

-- 1. five agreeing: a candidate only, not published
SELECT pg_temp.contribute(i, 'AUTO CAFE', 'cafes') FROM generate_series(1, 5) i;
INSERT INTO _r SELECT 'five agreeing: candidate, not published',
  pg_temp.kw('AUTO CAFE') = 0
  AND EXISTS (SELECT 1 FROM public.admin_list_merchant_category_candidates('5a1e0000-0000-0000-0000-00000000ad01')
              WHERE merchant_key = 'AUTO CAFE' AND category_key = 'cafes'), '';

-- 2. the sixth agreeing (6/6 = 100%): published once, marked auto
CREATE TEMP TABLE _v AS SELECT pg_temp.version() AS v;
SELECT pg_temp.contribute(6, 'AUTO CAFE', 'cafes');
INSERT INTO _r SELECT 'six agreeing at >=75%: published once',
  pg_temp.kw('AUTO CAFE') = 1 AND pg_temp.live('AUTO CAFE', 'cafes'), pg_temp.kw('AUTO CAFE')::text;
INSERT INTO _r SELECT 'auto-approval bumps the catalog version',
  pg_temp.version() > (SELECT v FROM _v), '';
INSERT INTO _r SELECT 'recorded as auto (no reviewer, timestamped)',
  EXISTS (SELECT 1 FROM public.merchant_category_reviews WHERE merchant_key = 'AUTO CAFE'
          AND category_key = 'cafes' AND decision = 'approved' AND auto_approved
          AND reviewed_by IS NULL AND reviewed_at IS NOT NULL AND user_count_at_review = 6), '';
INSERT INTO _r SELECT 'auto-approved pair leaves the candidate list, shows as published',
  NOT EXISTS (SELECT 1 FROM public.admin_list_merchant_category_candidates('5a1e0000-0000-0000-0000-00000000ad01')
              WHERE merchant_key = 'AUTO CAFE')
  AND EXISTS (SELECT 1 FROM public.admin_list_merchant_category_published('5a1e0000-0000-0000-0000-00000000ad01')
              WHERE merchant_key = 'AUTO CAFE' AND auto_approved), '';

-- 3. double evaluation: one row, one review
SELECT pg_temp.contribute(7, 'AUTO CAFE', 'cafes');
SELECT pg_temp.contribute(7, 'AUTO CAFE', 'cafes');
SELECT public.evaluate_merchant_category_auto_approval('AUTO CAFE');
SELECT public.evaluate_merchant_category_auto_approval('AUTO CAFE');
INSERT INTO _r SELECT 'evaluating again publishes nothing more',
  pg_temp.kw('AUTO CAFE') = 1
  AND (SELECT count(*) FROM public.merchant_category_reviews WHERE merchant_key = 'AUTO CAFE') = 1, '';
SELECT pg_temp.contribute(i, 'AUTO TWICE', 'groceries') FROM generate_series(1, 6) i;
SELECT public.evaluate_merchant_category_auto_approval('AUTO TWICE');
INSERT INTO _r SELECT 'explicit double evaluation -> one merchant_keywords row',
  pg_temp.kw('AUTO TWICE') = 1, pg_temp.kw('AUTO TWICE')::text;

-- 4. 6 vs 3 (67%): not auto, stays a candidate
SELECT pg_temp.contribute(i, 'AUTO SPLIT', 'restaurants') FROM generate_series(1, 3) i;
SELECT pg_temp.contribute(i, 'AUTO SPLIT', 'cafes') FROM generate_series(4, 9) i;
INSERT INTO _r SELECT '6 vs 3 (67%): not published, still a candidate',
  pg_temp.kw('AUTO SPLIT') = 0
  AND EXISTS (SELECT 1 FROM public.admin_list_merchant_category_candidates('5a1e0000-0000-0000-0000-00000000ad01')
              WHERE merchant_key = 'AUTO SPLIT' AND category_key = 'cafes' AND user_count = 6), '';
-- 75% exactly is enough: 9 vs 3
SELECT pg_temp.contribute(i, 'AUTO SPLIT', 'cafes') FROM generate_series(10, 12) i;
INSERT INTO _r SELECT '9 vs 3 (exactly 75%): published',
  pg_temp.live('AUTO SPLIT', 'cafes'), '';

-- 5. a rejected pair is never auto-approved
SELECT pg_temp.contribute(i, 'AUTO REJ', 'gifts') FROM generate_series(1, 5) i;
SELECT public.admin_review_merchant_category_candidate('5a1e0000-0000-0000-0000-00000000ad01',
  'AUTO REJ', 'gifts', 'rejected');
SELECT pg_temp.contribute(i, 'AUTO REJ', 'gifts') FROM generate_series(6, 12) i;
INSERT INTO _r SELECT 'rejected pair never auto-approved',
  pg_temp.kw('AUTO REJ') = 0, '';

-- 6. an approved mapping to another category is not auto-replaced
SELECT pg_temp.contribute(i, 'AUTO HELD', 'shopping') FROM generate_series(1, 5) i;
SELECT public.admin_review_merchant_category_candidate('5a1e0000-0000-0000-0000-00000000ad01',
  'AUTO HELD', 'shopping', 'approved');
SELECT pg_temp.contribute(i, 'AUTO HELD', 'home') FROM generate_series(1, 5) i;   -- users change their minds
SELECT pg_temp.contribute(i, 'AUTO HELD', 'home') FROM generate_series(6, 20) i;  -- 20 home, 0 shopping
INSERT INTO _r SELECT 'existing approved mapping is not auto-replaced',
  pg_temp.live('AUTO HELD', 'shopping') AND NOT pg_temp.live('AUTO HELD', 'home')
  AND EXISTS (SELECT 1 FROM public.admin_list_merchant_category_candidates('5a1e0000-0000-0000-0000-00000000ad01')
              WHERE merchant_key = 'AUTO HELD' AND category_key = 'home'), '';
-- nor an existing catalog keyword (admin / enrichment) with another category
INSERT INTO public.merchant_keywords (keyword, category_key, country_code) VALUES ('AUTO KW', 'bills', 'ALL');
SELECT pg_temp.contribute(i, 'AUTO KW', 'shopping') FROM generate_series(1, 8) i;
INSERT INTO _r SELECT 'existing catalog keyword with another category is not auto-replaced',
  pg_temp.live('AUTO KW', 'bills') AND NOT pg_temp.live('AUTO KW', 'shopping'), '';

-- 7. revoke: soft-deletes the row, bumps the version, never re-approves
SELECT pg_temp.expect_err('a non-admin cannot revoke',
  $q$SELECT public.admin_revoke_merchant_category_mapping(pg_temp.u(1), 'AUTO CAFE', 'cafes')$q$, 'P0403');
INSERT INTO _r SELECT 'client roles cannot call revoke',
  NOT has_function_privilege('authenticated',
        'public.admin_revoke_merchant_category_mapping(uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon',
        'public.admin_revoke_merchant_category_mapping(uuid,text,text)', 'EXECUTE'), '';
UPDATE _v SET v = pg_temp.version();
SELECT public.admin_revoke_merchant_category_mapping('5a1e0000-0000-0000-0000-00000000ad01', 'AUTO CAFE', 'cafes');
INSERT INTO _r SELECT 'revoke deactivates and soft-deletes the catalog row',
  NOT pg_temp.live('AUTO CAFE', 'cafes')
  AND EXISTS (SELECT 1 FROM public.merchant_keywords WHERE upper(keyword) = 'AUTO CAFE'
              AND NOT is_active AND is_deleted), '';
INSERT INTO _r SELECT 'revoke bumps the catalog version', pg_temp.version() > (SELECT v FROM _v), '';
INSERT INTO _r SELECT 'revoked pair is marked rejected by the admin',
  EXISTS (SELECT 1 FROM public.merchant_category_reviews WHERE merchant_key = 'AUTO CAFE'
          AND decision = 'rejected' AND reviewed_by = '5a1e0000-0000-0000-0000-00000000ad01'), '';
SELECT pg_temp.contribute(i, 'AUTO CAFE', 'cafes') FROM generate_series(20, 30) i;
SELECT public.evaluate_merchant_category_auto_approval('AUTO CAFE');
INSERT INTO _r SELECT 'revoked pair never auto-approves again',
  NOT pg_temp.live('AUTO CAFE', 'cafes'), '';
SELECT pg_temp.expect_err('revoking twice is refused',
  $q$SELECT public.admin_revoke_merchant_category_mapping('5a1e0000-0000-0000-0000-00000000ad01', 'AUTO CAFE', 'cafes')$q$,
  'P0409');
-- manual approvals use the same revoke
SELECT public.admin_revoke_merchant_category_mapping('5a1e0000-0000-0000-0000-00000000ad01', 'AUTO HELD', 'shopping');
INSERT INTO _r SELECT 'a manual approval is revoked the same way',
  NOT pg_temp.live('AUTO HELD', 'shopping'), '';

SELECT name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM _r ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _r;
