begin;

-- An Apple account must still complete Apple's proof and token revocation.
-- Non-Apple accounts use a challenge tied to a linked identity and skip only
-- the inapplicable Apple step. The same erasure, fence and receipts follow.
grant account_fence_owner to current_user;
grant create on schema public to account_fence_owner;

alter table account_fence.deletion_challenge
  add column proof_method text not null default 'apple' check (proof_method in ('apple','google','email')),
  add column google_subject text,
  add column otp_sent_at timestamptz,
  add column otp_attempts integer not null default 0 check (otp_attempts between 0 and 5),
  add column email_verified boolean not null default false,
  add constraint deletion_challenge_google_subject_shape
    check ((proof_method = 'google') = (google_subject is not null));
create unique index deletion_challenge_bound_email_code
  on account_fence.deletion_challenge(uid, otp_sent_at) where otp_sent_at is not null;

-- These narrow Auth shims are owned by the migration role, like the existing
-- Apple subject shim. The erasure role receives no general auth table access.
create function account_fence.auth_google_subject(p_uid uuid) returns text
language sql volatile security definer set search_path = pg_catalog, pg_temp
as $$
  select coalesce(nullif(i.provider_id, ''), i.identity_data ->> 'sub')
  from auth.identities i where i.user_id = p_uid and i.provider = 'google' limit 1
$$;

create function account_fence.auth_email_proof_state(p_uid uuid) returns timestamptz
language sql volatile security definer set search_path = pg_catalog, pg_temp
as $$
  select coalesce(u.reauthentication_sent_at, '-infinity'::timestamptz)
  from auth.users u
  where u.id = p_uid and u.email_confirmed_at is not null and nullif(u.email,'') is not null
$$;

create function account_fence.consume_deletion_email_code(
  p_uid uuid, p_sent_at timestamptz, p_code text
) returns boolean
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp
as $$
begin
  -- Supabase Auth's reauthentication code is SHA-224(email + code).
  -- Consume only this purpose's nonce and preserve the send cooldown.
  update auth.users u set reauthentication_token = ''
  where u.id = p_uid and u.email_confirmed_at is not null
    and u.reauthentication_sent_at = p_sent_at
    and u.reauthentication_token = pg_catalog.encode(
      pg_catalog.sha224(pg_catalog.convert_to(u.email || p_code, 'UTF8')), 'hex');
  if not found then return false; end if;
  delete from auth.one_time_tokens
    where user_id = p_uid and token_type = 'reauthentication_token';
  return true;
end;
$$;

revoke all on function account_fence.auth_google_subject(uuid),
  account_fence.auth_email_proof_state(uuid),
  account_fence.consume_deletion_email_code(uuid,timestamptz,text)
  from public, anon, authenticated, service_role;
grant execute on function account_fence.auth_google_subject(uuid),
  account_fence.auth_email_proof_state(uuid),
  account_fence.consume_deletion_email_code(uuid,timestamptz,text)
  to account_fence_owner;

create function public.account_deletion_issue_challenge_v2(p_uid uuid, p_email_only boolean)
returns jsonb
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp
as $$
declare
  v_issued jsonb;
  v_method text;
  v_google text;
begin
  v_issued := public.account_deletion_issue_challenge(p_uid);
  if v_issued->>'outcome' <> 'issued' then return v_issued; end if;
  if account_fence.auth_apple_subject(p_uid) is not null then
    v_method := 'apple';
  else
    v_google := account_fence.auth_google_subject(p_uid);
    if v_google is not null and not p_email_only then
      v_method := 'google';
    elsif account_fence.auth_email_proof_state(p_uid) is not null then
      v_method := 'email';
    else
      raise exception 'deletion_proof_unavailable' using errcode = 'QD093';
    end if;
  end if;
  update account_fence.deletion_challenge
  set proof_method = v_method, google_subject = case when v_method = 'google' then v_google end
  where uid = p_uid and challenge_id = v_issued->>'challenge_id';
  return v_issued || pg_catalog.jsonb_build_object('proof_method',v_method);
end;
$$;

create or replace function public.account_deletion_read_challenge(p_uid uuid, p_challenge_id text)
returns jsonb
language sql stable security definer set search_path = pg_catalog, pg_temp
as $$
  select pg_catalog.jsonb_build_object(
    'nonce_hash', c.nonce_hash,
    'expires_at_ms', pg_catalog.floor(extract(epoch from c.expires_at)*1000)::bigint,
    'consumed', c.consumed_at is not null, 'proof_method', c.proof_method,
    'google_subject', c.google_subject)
  from account_fence.deletion_challenge c
  where c.challenge_id = p_challenge_id and c.uid = p_uid
$$;

create function public.account_deletion_bind_email_code(p_uid uuid, p_challenge_id text)
returns boolean
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp
as $$
declare v_sent timestamptz := account_fence.auth_email_proof_state(p_uid);
begin
  update account_fence.deletion_challenge set otp_sent_at = v_sent
  where uid = p_uid and challenge_id = p_challenge_id and proof_method = 'email'
    and consumed_at is null and otp_sent_at is null and expires_at > pg_catalog.clock_timestamp()
    and v_sent >= expires_at - interval '5 minutes' and v_sent <= pg_catalog.clock_timestamp();
  return found;
end;
$$;

create function public.account_deletion_verify_email_code(p_uid uuid, p_challenge_id text, p_code text)
returns boolean
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp
as $$
declare v_sent timestamptz;
begin
  if p_code is null or p_code !~ '^[0-9]{6,10}$' then return false; end if;
  perform pg_catalog.set_config('lock_timeout', '5s', true);
  perform pg_catalog.pg_advisory_xact_lock(account_fence.gate_key(p_uid));
  update account_fence.deletion_challenge set otp_attempts = otp_attempts + 1
  where uid = p_uid and challenge_id = p_challenge_id and proof_method = 'email'
    and consumed_at is null and not email_verified and otp_sent_at is not null
    and expires_at > pg_catalog.clock_timestamp() and otp_attempts < 5
  returning otp_sent_at into v_sent;
  if not found or not account_fence.consume_deletion_email_code(p_uid, v_sent, p_code) then
    return false;
  end if;
  update account_fence.deletion_challenge set email_verified = true
  where uid = p_uid and challenge_id = p_challenge_id;
  return true;
end;
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

  -- Only the server-verified alternative for this challenge may bypass Apple
  -- revocation. Any Apple identity still present requires the Apple path.
  if (v_chal.proof_method = 'apple') <> (p_apple_material_ref is not null)
     or (v_chal.proof_method <> 'apple' and account_fence.auth_apple_subject(p_uid) is not null)
     or (v_chal.proof_method = 'google' and v_chal.google_subject is distinct from account_fence.auth_google_subject(p_uid))
     or (v_chal.proof_method = 'email' and not v_chal.email_verified) then
    return pg_catalog.jsonb_build_object('outcome', 'challenge_expired');
  end if;

  if v_open.job_id is not null then
    insert into account_fence.deletion_scope values (p_scope_key, v_open.job_id, p_receipt_hash);
    insert into account_fence.deletion_receipt values (p_receipt_hash, v_open.job_id) on conflict do nothing;
    update account_fence.deletion_challenge set consumed_at = pg_catalog.clock_timestamp() where challenge_id = p_challenge_id;
    return pg_catalog.jsonb_build_object('outcome', 'already_pending', 'job_id', v_open.job_id);
  end if;

  insert into account_fence.deletion_job (uid, attempt_id, apple_material_ref, completed_steps)
  values (p_uid, p_attempt_id, p_apple_material_ref,
    case when v_chal.proof_method = 'apple' then array[]::text[] else array['apple_revoke'] end)
  returning job_id into v_job;
  if v_chal.proof_method = 'apple' then
    update account_fence.deletion_material
       set state = 'committed', job_id = v_job
     where ref = p_apple_material_ref and state = 'reserved' and expires_at > pg_catalog.clock_timestamp();
    get diagnostics v_n = row_count;
    if v_n <> 1 then
      raise exception 'material_unavailable' using errcode = 'QD020';
    end if;
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

revoke all on function public.account_deletion_issue_challenge_v2(uuid,boolean),
  public.account_deletion_bind_email_code(uuid,text),
  public.account_deletion_verify_email_code(uuid,text,text)
  from public, anon, authenticated, service_role;
grant execute on function public.account_deletion_issue_challenge_v2(uuid,boolean),
  public.account_deletion_bind_email_code(uuid,text),
  public.account_deletion_verify_email_code(uuid,text,text)
  to service_role;
alter function public.account_deletion_issue_challenge_v2(uuid,boolean) owner to account_fence_owner;
alter function public.account_deletion_bind_email_code(uuid,text) owner to account_fence_owner;
alter function public.account_deletion_verify_email_code(uuid,text,text) owner to account_fence_owner;

revoke create on schema public from account_fence_owner;
revoke account_fence_owner from current_user;
commit;
