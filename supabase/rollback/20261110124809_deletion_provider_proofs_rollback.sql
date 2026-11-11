-- Restore the Apple-only challenge implementation without changing erasure
-- jobs, receipts or financial data. Finish/expire non-Apple challenges first.
begin;
grant account_fence_owner to current_user;
grant create on schema public to account_fence_owner;
do $$
begin
  if exists (select 1 from account_fence.deletion_challenge
      where proof_method <> 'apple' and consumed_at is null
        and expires_at > clock_timestamp()) then
    raise exception 'Finish or expire non-Apple deletion challenges before downgrade';
  end if;
end;
$$;
create or replace function public.account_deletion_read_challenge(p_uid uuid, p_challenge_id text)
returns jsonb
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select pg_catalog.jsonb_build_object(
      'nonce_hash', c.nonce_hash,
      'expires_at_ms', pg_catalog.floor(extract(epoch from c.expires_at) * 1000)::bigint,
      'consumed', c.consumed_at is not null)
    from account_fence.deletion_challenge c
   where c.challenge_id = p_challenge_id and c.uid = p_uid
$$;
create or replace function public.account_deletion_accept(
  p_scope_key text, p_uid uuid, p_challenge_id text, p_challenge_expires_at_ms bigint,
  p_receipt_hash text, p_apple_material_ref text, p_attempt_id text
) returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  v_scope account_fence.deletion_scope;
  v_open  account_fence.deletion_job;
  v_chal  account_fence.deletion_challenge;
  v_job   uuid;
  v_n     integer;
begin
  if pg_catalog.current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'account_fence_isolation_unsupported' using errcode = '0A000';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('qirsh.account_fence.attempt:' || p_attempt_id, 0));
  if exists (select 1 from account_fence.deletion_attempt_tombstone t where t.attempt_id = p_attempt_id) then
    return pg_catalog.jsonb_build_object('outcome', 'fenced');
  end if;

  perform pg_catalog.set_config('lock_timeout', '5s', true);
  perform pg_catalog.pg_advisory_xact_lock(account_fence.gate_key(p_uid));   -- lock_timeout -> 55P03

  select * into v_scope from account_fence.deletion_scope where scope_key = p_scope_key;
  if found then
    return case when v_scope.receipt_hash = p_receipt_hash
      then pg_catalog.jsonb_build_object('outcome', 'duplicate', 'job_id', v_scope.job_id)
      else pg_catalog.jsonb_build_object('outcome', 'idempotency_conflict') end;
  end if;

  if not account_fence.auth_user_exists(p_uid) then
    perform account_fence.deny('gone');
  end if;
  -- D7: an admin account is never accepted (QD031, before any insert); admin rights must be removed first.
  if exists (select 1 from public.admin_users a where a.id = p_uid) then
    perform account_fence.deny('admin');
  end if;

  -- Existing-job order matches completion: job row BEFORE challenge. Re-read under lock.
  select * into v_open from account_fence.deletion_job
   where uid = p_uid and state <> 'completed' for update;

  select * into v_chal from account_fence.deletion_challenge
   where challenge_id = p_challenge_id and uid = p_uid for update;
  if not found or v_chal.consumed_at is not null or v_chal.expires_at <= pg_catalog.clock_timestamp()
     or pg_catalog.clock_timestamp() > pg_catalog.to_timestamp(p_challenge_expires_at_ms / 1000.0) then
    return pg_catalog.jsonb_build_object('outcome', 'challenge_expired');
  end if;

  if v_open.job_id is not null then
    insert into account_fence.deletion_scope values (p_scope_key, v_open.job_id, p_receipt_hash);
    insert into account_fence.deletion_receipt values (p_receipt_hash, v_open.job_id) on conflict do nothing;
    update account_fence.deletion_challenge set consumed_at = pg_catalog.clock_timestamp() where challenge_id = p_challenge_id;
    return pg_catalog.jsonb_build_object('outcome', 'already_pending', 'job_id', v_open.job_id);
  end if;

  insert into account_fence.deletion_job (uid, attempt_id, apple_material_ref)
  values (p_uid, p_attempt_id, p_apple_material_ref) returning job_id into v_job;
  update account_fence.deletion_material
     set state = 'committed', job_id = v_job
   where ref = p_apple_material_ref and state = 'reserved' and expires_at > pg_catalog.clock_timestamp();
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    -- Never commit a job that references destroyed/expired material.
    raise exception 'material_unavailable' using errcode = 'QD020';
  end if;
  insert into account_fence.deletion_workset (job_id, install_id_hash, source)
  select v_job, d.install_id_hash, 'device_owner' from public.capture_devices d
   where d.user_id = p_uid and d.install_id_hash ~ '^[0-9a-f]{32}$'
  union
  select v_job, d.install_id_hash, 'consent_owner' from public.capture_devices d
   where d.consent_owner_uid = p_uid and d.install_id_hash ~ '^[0-9a-f]{32}$'
  union
  select v_job, p.install_id_hash, 'claimant' from public.processed_captures p
   where p.claimed_user_id = p_uid and p.install_id_hash ~ '^[0-9a-f]{32}$'
  union
  select v_job, p.install_id_hash, 'capture_owner' from public.processed_captures p
   where p.owner_uid = p_uid and p.install_id_hash ~ '^[0-9a-f]{32}$'
  union
  select v_job, p.install_id_hash, 'capture_consent' from public.processed_captures p
   where p.consent_owner_uid = p_uid and p.install_id_hash ~ '^[0-9a-f]{32}$'
  union
  select v_job, p.consumed_by_install_hash, 'consumed_install' from public.processed_captures p
   where p_uid = any(array[p.claimed_user_id, p.owner_uid, p.consent_owner_uid])
     and p.consumed_by_install_hash ~ '^[0-9a-f]{32}$'
  union
  select v_job, l.install_id_hash, 'log_owner' from public.notification_logs l
   where l.user_id = p_uid and l.install_id_hash ~ '^[0-9a-f]{32}$'
  union
  select v_job, q.install_id_hash, 'retry_install' from public.notification_retry_queue q
    left join public.notification_logs l on l.id = q.notification_log_id
   where q.install_id_hash ~ '^[0-9a-f]{32}$'
     and (l.user_id = p_uid or p_uid = any(account_fence.install_owners(q.install_id_hash))
          or p_uid = any(account_fence.install_owners(l.install_id_hash)))
  union
  select v_job, l.install_id_hash, 'retry_parent_install' from public.notification_retry_queue q
    join public.notification_logs l on l.id = q.notification_log_id
   where l.install_id_hash ~ '^[0-9a-f]{32}$'
     and (l.user_id = p_uid or p_uid = any(account_fence.install_owners(q.install_id_hash))
          or p_uid = any(account_fence.install_owners(l.install_id_hash)))
  union
  select v_job, h.install_id_hash, 'first_owner' from public.capture_install_owner_history h
   where h.first_owner_uid = p_uid and h.install_id_hash ~ '^[0-9a-f]{32}$'
  on conflict do nothing;
  insert into account_fence.deletion_scope values (p_scope_key, v_job, p_receipt_hash);
  insert into account_fence.deletion_receipt values (p_receipt_hash, v_job);
  update account_fence.deletion_challenge set consumed_at = pg_catalog.clock_timestamp() where challenge_id = p_challenge_id;
  return pg_catalog.jsonb_build_object('outcome', 'accepted', 'job_id', v_job);
end;
$$;
drop function public.account_deletion_issue_challenge_v2(uuid,boolean);
drop function public.account_deletion_bind_email_code(uuid,text);
drop function public.account_deletion_verify_email_code(uuid,text,text);
drop function account_fence.consume_deletion_email_code(uuid,timestamptz,text);
drop function account_fence.auth_google_subject(uuid);
drop function account_fence.auth_email_proof_state(uuid);
drop index account_fence.deletion_challenge_bound_email_code;
alter table account_fence.deletion_challenge
  drop constraint deletion_challenge_google_subject_shape,
  drop column proof_method,
  drop column google_subject,
  drop column otp_sent_at,
  drop column otp_attempts,
  drop column email_verified;
revoke create on schema public from account_fence_owner;
revoke account_fence_owner from current_user;
commit;
