-- The user's profile photo is backed up with Cloud Sync, so a reinstall or a new
-- phone + sign-in brings it back.
--
-- WHAT IS STORED
-- One object per user in the PRIVATE `profile-photos` bucket, at exactly
-- `<uid>/avatar`: the image the user picked (already resized on the device).
-- Nothing else: the device path, the file name and the time it was picked stay
-- on the device. The object is overwritten when the user picks a new photo.
--
-- WHO CAN REACH IT
-- Storage RLS, same shape as the `backups` bucket (0010 / 0086 / 0117):
--   * read / delete: only the owner's own `<uid>/` folder;
--   * insert / update: only the exact `<uid>/avatar` name, and only while the
--     Auth row is live and no account deletion is pending
--     (public.backups_owner_is_live(), 0117 body: Auth liveness AND
--     NOT account_fence.is_pending). A stale JWT of a deleted account cannot
--     re-create the object after the deletion sweep.
-- The bucket is private (no public URL), capped at 5 MiB and limited to image
-- types. The client uploads only while Cloud consent allows it (EgressClass
-- profileAndSettings, read fresh) and only while the server advertises the
-- capability below.
--
-- ERASURE
-- Storage objects cannot be deleted from SQL (storage.protect_delete). Account
-- deletion erases them in the deletion worker: supabase/functions/_shared/
-- storage_erasure.ts sweeps every bucket in ERASURE_BUCKETS (now `backups` AND
-- `profile-photos`) under the same exact-owner-prefix and two-empty-scan rules,
-- in both the pre-SQL `storage_sweep` and the post-Auth `terminal_storage`
-- steps, for the scheduled and the immediate deletion paths. The write barrier
-- above is what makes the terminal sweep final.
--
-- KILL SWITCH
-- qirsh_server_capabilities() gains `profile_photo_backup` = true (every
-- previous key preserved, 20261116180000 body). The client neither uploads nor
-- downloads the photo unless it is advertised.
--
-- Reversible: rollback/20261116210000_profile_photo_backup_rollback.sql.

begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('profile-photos', 'profile-photos', false, 5242880,
        array['image/jpeg', 'image/png', 'image/heic', 'image/heif', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "own profile photo read" on storage.objects;
drop policy if exists "own profile photo write" on storage.objects;
drop policy if exists "own profile photo update" on storage.objects;
drop policy if exists "own profile photo delete" on storage.objects;

create policy "own profile photo read" on storage.objects for select
  to authenticated
  using (
    bucket_id = 'profile-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "own profile photo write" on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'profile-photos'
    and name = (select auth.uid())::text || '/avatar'
    and public.backups_owner_is_live()
  );

create policy "own profile photo update" on storage.objects for update
  to authenticated
  using (
    bucket_id = 'profile-photos'
    and name = (select auth.uid())::text || '/avatar'
    and public.backups_owner_is_live()
  )
  with check (
    bucket_id = 'profile-photos'
    and name = (select auth.uid())::text || '/avatar'
    and public.backups_owner_is_live()
  );

create policy "own profile photo delete" on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'profile-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- ── Capability (0114 convention: every previous key preserved) ─────────────
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
    'merchant_rules_sync', true,
    'profile_photo_backup', true
  );
$$;

revoke all on function public.qirsh_server_capabilities() from public, anon;
grant execute on function public.qirsh_server_capabilities() to authenticated;

commit;
