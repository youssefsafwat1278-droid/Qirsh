-- Removes the profile-photo backup (20261116210000). The capability set goes
-- back to its 20261116180000 body, so devices stop uploading and downloading
-- the photo (they keep their local copy); the four storage policies are dropped,
-- so no client can read or write the bucket any more.
--
-- The bucket itself is removed only when it is empty: Storage objects cannot be
-- deleted from SQL (storage.protect_delete). If photos were uploaded, empty the
-- bucket through the Storage API first (Dashboard -> Storage -> profile-photos
-- -> Empty bucket) and run this file again; until then it is left in place,
-- private and unreachable by clients, and a NOTICE says so.
begin;

drop policy if exists "own profile photo read" on storage.objects;
drop policy if exists "own profile photo write" on storage.objects;
drop policy if exists "own profile photo update" on storage.objects;
drop policy if exists "own profile photo delete" on storage.objects;

do $$
begin
  if exists (select 1 from storage.objects where bucket_id = 'profile-photos') then
    raise notice 'profile-photos still holds objects: empty it through the Storage API, then re-run this rollback to remove the bucket';
  else
    -- The bucket row only (it holds no objects): storage.protect_delete refuses
    -- SQL deletes unless this transaction-local switch is on.
    perform set_config('storage.allow_delete_query', 'true', true);
    delete from storage.buckets where id = 'profile-photos';
    perform set_config('storage.allow_delete_query', 'false', true);
  end if;
end $$;

-- Restore the 20261116180000 capability body.
create or replace function public.qirsh_server_capabilities()
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select jsonb_build_object(
    'awaiting_fx_transactions', true,
    'capture_contract_v2', false,
    'sync_seq', false,
    'revision_cas', false,
    'replica_epoch', false,
    'min_supported_seq', false,
    'min_client_build', false,
    'merchant_rules_sync', true
  );
$$;

revoke all on function public.qirsh_server_capabilities() from public, anon;
grant execute on function public.qirsh_server_capabilities() to authenticated;

commit;
