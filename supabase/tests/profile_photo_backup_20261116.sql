-- SQL proof for 20261116210000_profile_photo_backup.
-- Run against a LOCAL Supabase Postgres ONLY. Everything is rolled back; the
-- migration is inlined so it does not need to be applied first:
--
--   { echo 'BEGIN;';
--     sed '/^begin;$/d;/^commit;$/d' supabase/migrations/20261116210000_profile_photo_backup.sql;
--     cat supabase/tests/profile_photo_backup_20261116.sql; echo 'ROLLBACK;'; } \
--   | psql "$LOCAL_URL" -v ON_ERROR_STOP=1 -q
--
-- Storage RLS is exercised exactly as the Storage API does it: as the
-- `authenticated` role with the caller's JWT claims, against storage.objects.
-- Ends with one line: `profile_photo_backup proof: pass (N checks)` or an
-- exception naming the failures.

CREATE TEMP TABLE _r (name text, ok boolean, detail text);
GRANT ALL ON _r TO authenticated, anon;

CREATE OR REPLACE FUNCTION pg_temp.as_user(p uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', p::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p::text, true);
END $$;

-- Tries one write as the CURRENT role/claims; true when it was admitted.
CREATE OR REPLACE FUNCTION pg_temp.try_insert(p_name text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO storage.objects (bucket_id, name, owner_id) VALUES ('profile-photos', p_name, auth.uid()::text);
  RETURN true;
EXCEPTION WHEN insufficient_privilege OR check_violation THEN
  RETURN false;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.try_update(p_name text, p_new_name text) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  UPDATE storage.objects SET name = p_new_name, updated_at = now()
   WHERE bucket_id = 'profile-photos' AND name = p_name;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
EXCEPTION WHEN insufficient_privilege OR check_violation THEN
  RETURN -1;
END $$;

GRANT EXECUTE ON FUNCTION pg_temp.as_user(uuid), pg_temp.try_insert(text), pg_temp.try_update(text, text)
  TO authenticated, anon;

-- Users: A and B live, C pending deletion, D deleted from Auth (stale JWT).
INSERT INTO auth.users (id) VALUES
  ('9f070000-0000-0000-0000-00000000000a'),
  ('9f070000-0000-0000-0000-00000000000b'),
  ('9f070000-0000-0000-0000-00000000000c');
GRANT account_fence_owner TO current_user;
SET LOCAL ROLE account_fence_owner;
INSERT INTO account_fence.deletion_job (uid, attempt_id)
VALUES ('9f070000-0000-0000-0000-00000000000c', 'profile-photo-proof');
RESET ROLE;
REVOKE account_fence_owner FROM current_user;

-- ── Bucket shape and capability ──────────────────────────────────────────────
INSERT INTO _r SELECT 'bucket exists, private, 5 MiB, images only',
  EXISTS (SELECT 1 FROM storage.buckets
          WHERE id = 'profile-photos' AND public = false AND file_size_limit = 5242880
            AND allowed_mime_types @> array['image/jpeg', 'image/png']
            AND NOT allowed_mime_types && array['application/octet-stream', 'text/html', 'image/svg+xml']), '';
INSERT INTO _r SELECT 'capability profile_photo_backup advertised, merchant_rules_sync kept',
  (public.qirsh_server_capabilities() ->> 'profile_photo_backup')::boolean
  AND (public.qirsh_server_capabilities() ->> 'merchant_rules_sync')::boolean
  AND (public.qirsh_server_capabilities() ->> 'awaiting_fx_transactions')::boolean,
  public.qirsh_server_capabilities()::text;
INSERT INTO _r SELECT 'capability RPC not callable by anon',
  NOT has_function_privilege('anon', 'public.qirsh_server_capabilities()', 'execute'), '';

-- ── A writes its own photo ─────────────────────────────────────────────────────
SET LOCAL ROLE authenticated;
DO $$ BEGIN PERFORM pg_temp.as_user('9f070000-0000-0000-0000-00000000000a'); END $$;
INSERT INTO _r SELECT 'owner can create <uid>/avatar',
  pg_temp.try_insert('9f070000-0000-0000-0000-00000000000a/avatar'), '';
INSERT INTO _r SELECT 'owner cannot write into another user''s folder',
  NOT pg_temp.try_insert('9f070000-0000-0000-0000-00000000000b/avatar'), '';
INSERT INTO _r SELECT 'owner cannot write any other name in its own folder',
  NOT pg_temp.try_insert('9f070000-0000-0000-0000-00000000000a/other.jpg'), '';
INSERT INTO _r SELECT 'owner cannot write a top-level object',
  NOT pg_temp.try_insert('avatar'), '';
INSERT INTO _r SELECT 'owner can overwrite (update) its own photo',
  pg_temp.try_update('9f070000-0000-0000-0000-00000000000a/avatar',
                     '9f070000-0000-0000-0000-00000000000a/avatar') = 1, '';
INSERT INTO _r SELECT 'owner cannot move its photo into another user''s folder',
  pg_temp.try_update('9f070000-0000-0000-0000-00000000000a/avatar',
                     '9f070000-0000-0000-0000-00000000000b/avatar') <= 0, '';
RESET ROLE;

-- ── B writes its own; isolation of reads ───────────────────────────────────────
SET LOCAL ROLE authenticated;
DO $$ BEGIN PERFORM pg_temp.as_user('9f070000-0000-0000-0000-00000000000b'); END $$;
INSERT INTO _r SELECT 'second user can create its own photo',
  pg_temp.try_insert('9f070000-0000-0000-0000-00000000000b/avatar'), '';
INSERT INTO _r SELECT 'B sees only its own photo',
  (SELECT array_agg(name) FROM storage.objects WHERE bucket_id = 'profile-photos')
    = array['9f070000-0000-0000-0000-00000000000b/avatar'],
  (SELECT coalesce(string_agg(name, ','), '') FROM storage.objects WHERE bucket_id = 'profile-photos');
INSERT INTO _r SELECT 'B cannot overwrite A''s photo',
  pg_temp.try_update('9f070000-0000-0000-0000-00000000000a/avatar',
                     '9f070000-0000-0000-0000-00000000000a/avatar') = 0, '';
RESET ROLE;

SET LOCAL ROLE authenticated;
DO $$ BEGIN PERFORM pg_temp.as_user('9f070000-0000-0000-0000-00000000000a'); END $$;
INSERT INTO _r SELECT 'A sees only its own photo',
  (SELECT array_agg(name) FROM storage.objects WHERE bucket_id = 'profile-photos')
    = array['9f070000-0000-0000-0000-00000000000a/avatar'], '';
RESET ROLE;

SET LOCAL ROLE anon;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"anon"}', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
END $$;
INSERT INTO _r SELECT 'anon sees no photo',
  NOT EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'profile-photos'), '';
INSERT INTO _r SELECT 'anon cannot write a photo',
  NOT pg_temp.try_insert('9f070000-0000-0000-0000-00000000000a/avatar'), '';
RESET ROLE;

-- ── Deletion barrier: pending deletion and deleted Auth row ───────────────────
SET LOCAL ROLE authenticated;
DO $$ BEGIN PERFORM pg_temp.as_user('9f070000-0000-0000-0000-00000000000c'); END $$;
INSERT INTO _r SELECT 'no upload while the account deletion is pending',
  NOT pg_temp.try_insert('9f070000-0000-0000-0000-00000000000c/avatar'), '';
RESET ROLE;

DELETE FROM auth.users WHERE id = '9f070000-0000-0000-0000-00000000000b';
SET LOCAL ROLE authenticated;
DO $$ BEGIN PERFORM pg_temp.as_user('9f070000-0000-0000-0000-00000000000b'); END $$;
INSERT INTO _r SELECT 'a deleted account''s stale JWT cannot overwrite its photo',
  pg_temp.try_update('9f070000-0000-0000-0000-00000000000b/avatar',
                     '9f070000-0000-0000-0000-00000000000b/avatar') <= 0, '';
RESET ROLE;
-- (Its leftover object is what the deletion worker's Storage sweep removes:
-- storage_erasure_test.ts covers the profile-photos bucket.)
INSERT INTO _r SELECT 'the backups bucket policies are unchanged',
  (SELECT count(*) FROM pg_policy WHERE polrelid = 'storage.objects'::regclass
     AND polname LIKE 'own backup objects %') = 4, '';

DO $$
DECLARE n int; f int; names text;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE NOT ok),
         string_agg(name || CASE WHEN detail <> '' THEN ' [' || detail || ']' ELSE '' END, '; ') FILTER (WHERE NOT ok)
    INTO n, f, names FROM _r;
  IF f > 0 THEN RAISE EXCEPTION 'profile_photo_backup proof: fail (% of % checks): %', f, n, names; END IF;
  RAISE NOTICE 'profile_photo_backup proof: pass (% checks)', n;
END $$;
