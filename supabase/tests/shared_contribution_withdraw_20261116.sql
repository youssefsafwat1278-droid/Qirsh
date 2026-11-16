-- SQL proof for 20261116220000_shared_contribution_withdraw.
-- Run against a LOCAL Postgres ONLY. Everything is rolled back. Needs
-- 20261116150000, 20261116170000 and 20261116190000 first (applied or inlined).

CREATE TEMP TABLE _w (name text, ok boolean, detail text);

CREATE OR REPLACE FUNCTION pg_temp.u(n int) RETURNS uuid LANGUAGE sql AS $$
  SELECT ('3d1e0000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
$$;
CREATE OR REPLACE FUNCTION pg_temp.votes(m text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.merchant_category_contributions WHERE merchant_key = m
$$;
CREATE OR REPLACE FUNCTION pg_temp.live(m text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM public.merchant_keywords
                 WHERE upper(keyword) = m AND country_code = 'ALL' AND is_active AND NOT is_deleted)
$$;

DELETE FROM public.merchant_category_contributions WHERE merchant_key IN ('WD SHOP', 'WD PUB');
DELETE FROM public.merchant_keywords WHERE upper(keyword) IN ('WD SHOP', 'WD PUB');
DELETE FROM public.merchant_category_reviews WHERE merchant_key IN ('WD SHOP', 'WD PUB');

-- 1. withdrawing removes exactly the caller's vote
SELECT public.submit_merchant_category_contribution(pg_temp.u(1), 'WD SHOP', 'cafes');
SELECT public.submit_merchant_category_contribution(pg_temp.u(2), 'WD SHOP', 'cafes');
INSERT INTO _w SELECT 'withdraw returns true for an existing vote',
  public.withdraw_merchant_category_contribution(pg_temp.u(1), 'WD SHOP'), '';
INSERT INTO _w SELECT 'only the caller''s vote is removed',
  pg_temp.votes('WD SHOP') = 1
  AND EXISTS (SELECT 1 FROM public.merchant_category_contributions
              WHERE merchant_key = 'WD SHOP'
                AND contributor_hash = public.merchant_contributor_hash(pg_temp.u(2))), '';

-- 2. withdrawing again (or never having voted) is a harmless no-op
INSERT INTO _w SELECT 'a second withdraw returns false',
  NOT public.withdraw_merchant_category_contribution(pg_temp.u(1), 'WD SHOP'), '';
INSERT INTO _w SELECT 'withdrawing a vote never cast returns false',
  NOT public.withdraw_merchant_category_contribution(pg_temp.u(9), 'WD SHOP'), '';

-- 3. a published pair stays published (the admin decides), and withdrawals never publish
SELECT public.submit_merchant_category_contribution(pg_temp.u(i), 'WD PUB', 'groceries') FROM generate_series(1, 6) i;
INSERT INTO _w SELECT 'six agreeing votes auto-publish (precondition)', pg_temp.live('WD PUB'), '';
SELECT public.withdraw_merchant_category_contribution(pg_temp.u(i), 'WD PUB') FROM generate_series(1, 3) i;
INSERT INTO _w SELECT 'withdrawals reduce the count', pg_temp.votes('WD PUB') = 3, '';
INSERT INTO _w SELECT 'a published mapping is not silently removed by withdrawals', pg_temp.live('WD PUB'), '';

-- 4. invalid input is refused
DO $$ BEGIN
  PERFORM public.withdraw_merchant_category_contribution(pg_temp.u(1), 'wd shop 12');
  INSERT INTO _w VALUES ('an invalid merchant key is refused', false, 'accepted');
EXCEPTION WHEN SQLSTATE 'P0422' THEN
  INSERT INTO _w VALUES ('an invalid merchant key is refused', true, '');
END $$;
DO $$ BEGIN
  PERFORM public.withdraw_merchant_category_contribution(NULL, 'WD SHOP');
  INSERT INTO _w VALUES ('a missing user is refused', false, 'accepted');
EXCEPTION WHEN SQLSTATE 'P0422' THEN
  INSERT INTO _w VALUES ('a missing user is refused', true, '');
END $$;

-- 5. only the service role (the Edge Function) can call it
INSERT INTO _w SELECT 'withdraw is unreachable from anon and authenticated',
  NOT has_function_privilege('anon', 'public.withdraw_merchant_category_contribution(uuid,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.withdraw_merchant_category_contribution(uuid,text)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.withdraw_merchant_category_contribution(uuid,text)', 'EXECUTE'), '';

SELECT name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM _w ORDER BY ok, name;
SELECT CASE WHEN bool_and(ok) THEN 'pass' ELSE 'fail' END AS proof,
       count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _w;
