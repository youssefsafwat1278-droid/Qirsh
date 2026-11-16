-- SQL proof for 20261116180000_user_merchant_rules_sync.
-- Run against a LOCAL Postgres ONLY. Everything is rolled back.
--
--   { echo 'BEGIN;'; sed '/^begin;$/d;/^commit;$/d' supabase/migrations/20261116180000_user_merchant_rules_sync.sql;
--     cat supabase/tests/user_merchant_rules_sync_20261116.sql; echo 'ROLLBACK;'; } \
--   | psql "$LOCAL_URL" -v ON_ERROR_STOP=1
--
-- (The migration's own begin/commit are stripped so the outer ROLLBACK undoes it.)

CREATE TEMP TABLE _r (name text, ok boolean, detail text);
GRANT ALL ON _r TO anon, authenticated, account_fence_owner;

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
GRANT EXECUTE ON FUNCTION pg_temp.expect_err(text, text, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', p_uid::text, true)
$$;

-- Fixtures: two users.
INSERT INTO auth.users (id) VALUES
  ('7e1e0000-0000-0000-0000-0000000000a1'),
  ('7e1e0000-0000-0000-0000-0000000000b2');

-- ── structure ────────────────────────────────────────────────────────────────
INSERT INTO _r SELECT 'RLS enabled',
  relrowsecurity, '' FROM pg_class WHERE oid = 'public.user_merchant_rules'::regclass;
INSERT INTO _r SELECT 'authenticated holds no DELETE (tombstones only)',
  NOT has_table_privilege('authenticated', 'public.user_merchant_rules', 'DELETE'), '';
INSERT INTO _r SELECT 'anon holds no privilege',
  NOT has_table_privilege('anon', 'public.user_merchant_rules', 'SELECT, INSERT, UPDATE, DELETE'), '';
INSERT INTO _r SELECT 'only key/category/tombstone columns are client-writable',
  NOT has_column_privilege('authenticated', 'public.user_merchant_rules', 'updated_at', 'UPDATE')
  AND NOT has_column_privilege('authenticated', 'public.user_merchant_rules', 'sync_seq', 'INSERT')
  AND has_column_privilege('authenticated', 'public.user_merchant_rules', 'category_key', 'UPDATE')
  AND has_column_privilege('authenticated', 'public.user_merchant_rules', 'deleted_at', 'UPDATE'), '';
INSERT INTO _r SELECT 'no amount/message/text column exists',
  NOT EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'user_merchant_rules'
                AND column_name NOT IN ('id', 'user_id', 'merchant_key', 'category_key',
                                        'created_at', 'updated_at', 'deleted_at', 'sync_seq')), '';
INSERT INTO _r SELECT 'capability advertised, 0114 keys preserved',
  (public.qirsh_server_capabilities() ->> 'merchant_rules_sync')::boolean
  AND (public.qirsh_server_capabilities() ->> 'awaiting_fx_transactions')::boolean
  AND NOT (public.qirsh_server_capabilities() ->> 'sync_seq')::boolean
  AND public.qirsh_server_capabilities() ? 'min_client_build', '';
INSERT INTO _r SELECT 'erasure owner still owns the restated erasure functions',
  bool_and(pg_get_userbyid(proowner) = 'account_fence_owner'), string_agg(proname, ',')
  FROM pg_proc WHERE oid IN ('account_fence.erase_user_data(uuid,uuid)'::regprocedure,
                             'account_fence.erase_verify(uuid)'::regprocedure);
INSERT INTO _r SELECT 'migration role keeps no account_fence_owner membership',
  NOT pg_has_role(current_user, 'account_fence_owner', 'USAGE'), '';

-- ── user A writes ──────────────────────────────────────────────────────────
SELECT pg_temp.as_user('7e1e0000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
INSERT INTO public.user_merchant_rules (user_id, merchant_key, category_key)
VALUES ('7e1e0000-0000-0000-0000-0000000000a1', 'PROOF CAFE', 'cafes'),
       ('7e1e0000-0000-0000-0000-0000000000a1', 'PROOF SHOP', 'custom_هدايا');
-- A cannot write a row for B.
SELECT pg_temp.expect_err('A cannot insert a row owned by B',
  $q$INSERT INTO public.user_merchant_rules (user_id, merchant_key, category_key)
     VALUES ('7e1e0000-0000-0000-0000-0000000000b2', 'PROOF CAFE', 'cafes')$q$, '42501');
-- Shape checks: identifier-like merchant keys and malformed category keys.
SELECT pg_temp.expect_err('merchant key with digits refused',
  $q$INSERT INTO public.user_merchant_rules (user_id, merchant_key, category_key)
     VALUES ('7e1e0000-0000-0000-0000-0000000000a1', 'CARD 1234', 'cafes')$q$, '23514');
SELECT pg_temp.expect_err('untrimmed merchant key refused',
  $q$INSERT INTO public.user_merchant_rules (user_id, merchant_key, category_key)
     VALUES ('7e1e0000-0000-0000-0000-0000000000a1', ' PROOF ', 'cafes')$q$, '23514');
SELECT pg_temp.expect_err('category key with spaces refused',
  $q$INSERT INTO public.user_merchant_rules (user_id, merchant_key, category_key)
     VALUES ('7e1e0000-0000-0000-0000-0000000000a1', 'PROOF BAR', 'not a key')$q$, '23514');
-- Hard delete is not possible for a client.
SELECT pg_temp.expect_err('client DELETE refused',
  $q$DELETE FROM public.user_merchant_rules WHERE merchant_key = 'PROOF CAFE'$q$, '42501');
RESET ROLE;

INSERT INTO _r SELECT 'server stamps sync_seq on insert',
  bool_and(sync_seq IS NOT NULL), count(*)::text
  FROM public.user_merchant_rules WHERE user_id = '7e1e0000-0000-0000-0000-0000000000a1';

-- Remember the first stamp, then re-confirm through the client upsert path.
CREATE TEMP TABLE _s AS
  SELECT sync_seq, updated_at FROM public.user_merchant_rules
   WHERE user_id = '7e1e0000-0000-0000-0000-0000000000a1' AND merchant_key = 'PROOF CAFE';
GRANT SELECT ON _s TO authenticated;

SELECT pg_temp.as_user('7e1e0000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
-- The device's upsert (PostgREST on_conflict=user_id,merchant_key).
INSERT INTO public.user_merchant_rules (user_id, merchant_key, category_key, deleted_at)
VALUES ('7e1e0000-0000-0000-0000-0000000000a1', 'PROOF CAFE', 'restaurants', NULL)
ON CONFLICT (user_id, merchant_key) DO UPDATE
  SET user_id = EXCLUDED.user_id, merchant_key = EXCLUDED.merchant_key,
      category_key = EXCLUDED.category_key, deleted_at = EXCLUDED.deleted_at;
-- Tombstone (delete on a device) through the same upsert.
INSERT INTO public.user_merchant_rules (user_id, merchant_key, category_key, deleted_at)
VALUES ('7e1e0000-0000-0000-0000-0000000000a1', 'PROOF SHOP', 'custom_هدايا', now())
ON CONFLICT (user_id, merchant_key) DO UPDATE
  SET user_id = EXCLUDED.user_id, merchant_key = EXCLUDED.merchant_key,
      category_key = EXCLUDED.category_key, deleted_at = EXCLUDED.deleted_at;
RESET ROLE;

INSERT INTO _r SELECT 'upsert updates in place: one row per merchant, new category',
  count(*) = 1 AND min(category_key) = 'restaurants', count(*)::text
  FROM public.user_merchant_rules
 WHERE user_id = '7e1e0000-0000-0000-0000-0000000000a1' AND merchant_key = 'PROOF CAFE';
INSERT INTO _r SELECT 'every write advances sync_seq (keyset/seq pull sees it)',
  r.sync_seq > s.sync_seq, r.sync_seq::text || ' > ' || s.sync_seq::text
  FROM public.user_merchant_rules r, _s s
 WHERE r.user_id = '7e1e0000-0000-0000-0000-0000000000a1' AND r.merchant_key = 'PROOF CAFE';
INSERT INTO _r SELECT 'tombstone kept as a row (propagates to other devices)',
  deleted_at IS NOT NULL, '' FROM public.user_merchant_rules
 WHERE user_id = '7e1e0000-0000-0000-0000-0000000000a1' AND merchant_key = 'PROOF SHOP';

-- ── user B + isolation ─────────────────────────────────────────────────────
SELECT pg_temp.as_user('7e1e0000-0000-0000-0000-0000000000b2');
SET LOCAL ROLE authenticated;
INSERT INTO public.user_merchant_rules (user_id, merchant_key, category_key)
VALUES ('7e1e0000-0000-0000-0000-0000000000b2', 'PROOF CAFE', 'groceries');
INSERT INTO _r SELECT 'B sees only its own rows',
  count(*) = 1 AND bool_and(user_id = '7e1e0000-0000-0000-0000-0000000000b2'), count(*)::text
  FROM public.user_merchant_rules;
-- B's update aimed at A's row matches nothing.
UPDATE public.user_merchant_rules SET category_key = 'other'
 WHERE user_id = '7e1e0000-0000-0000-0000-0000000000a1';
RESET ROLE;
INSERT INTO _r SELECT 'B cannot change A''s rows',
  NOT EXISTS (SELECT 1 FROM public.user_merchant_rules
              WHERE user_id = '7e1e0000-0000-0000-0000-0000000000a1' AND category_key = 'other'), '';

SELECT pg_temp.as_user('7e1e0000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
INSERT INTO _r SELECT 'A sees only its own rows (incl. its tombstone)',
  count(*) = 2 AND bool_and(user_id = '7e1e0000-0000-0000-0000-0000000000a1'), count(*)::text
  FROM public.user_merchant_rules;
RESET ROLE;

SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);
SET LOCAL ROLE anon;
SELECT pg_temp.expect_err('anon reads nothing', 'SELECT count(*) FROM public.user_merchant_rules', '42501');
RESET ROLE;

-- ── account deletion: the real erasure entry removes A's rules, keeps B's ───
GRANT account_fence_owner TO current_user;
INSERT INTO account_fence.erasure_ctx (xid, backend_pid, job_id, uid)
VALUES (pg_current_xact_id(), pg_backend_pid(), gen_random_uuid(), '7e1e0000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE account_fence_owner;
DO $$
DECLARE d text;
BEGIN
  -- Only this table holds A's rows besides the sync-state anchor, which the
  -- closure list checks AFTER this table.
  PERFORM account_fence.erase_verify('7e1e0000-0000-0000-0000-0000000000a1');
  INSERT INTO _r VALUES ('closure check names this table while A still has rules', false, 'no error');
EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL;
  INSERT INTO _r VALUES ('closure check names this table while A still has rules',
    SQLSTATE = 'QD013' AND d = 'fence:user_merchant_rules', SQLSTATE || ' ' || coalesce(d, ''));
END $$;
SELECT account_fence.erase_user_data(gen_random_uuid(), '7e1e0000-0000-0000-0000-0000000000a1');
SELECT account_fence.erase_verify('7e1e0000-0000-0000-0000-0000000000a1');
RESET ROLE;
DELETE FROM account_fence.erasure_ctx WHERE xid = pg_current_xact_id();
REVOKE account_fence_owner FROM current_user;
INSERT INTO _r SELECT 'erasure removed every rule of A (rules and tombstones)',
  NOT EXISTS (SELECT 1 FROM public.user_merchant_rules
              WHERE user_id = '7e1e0000-0000-0000-0000-0000000000a1'), '';
INSERT INTO _r SELECT 'erasure kept B''s rules',
  EXISTS (SELECT 1 FROM public.user_merchant_rules
          WHERE user_id = '7e1e0000-0000-0000-0000-0000000000b2'), '';

-- Backstop: deleting the Auth user cascades whatever is left.
DELETE FROM auth.users WHERE id = '7e1e0000-0000-0000-0000-0000000000b2';
INSERT INTO _r SELECT 'auth user delete cascades the rules (backstop)',
  NOT EXISTS (SELECT 1 FROM public.user_merchant_rules
              WHERE user_id = '7e1e0000-0000-0000-0000-0000000000b2'), '';

SELECT name, ok, detail FROM _r ORDER BY ok, name;
DO $$
DECLARE n int; f int;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE NOT ok) INTO n, f FROM _r;
  IF f > 0 THEN RAISE EXCEPTION 'user_merchant_rules proof: % of % FAILED', f, n; END IF;
  RAISE NOTICE 'user_merchant_rules proof: % checks passed', n;
END $$;
