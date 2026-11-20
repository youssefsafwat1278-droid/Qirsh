-- Gemini-first phase 3: smart analysis without Cloud.
--
-- Smart analysis (the bank message, after the device hides names, phone and
-- account numbers, read by Google Gemini through Qirsh's server) no longer
-- requires Cloud sync. A capture device may now upload a message for analysis
-- when it holds Cloud consent OR smart-analysis (AI) consent, and the model may
-- run when it holds AI consent (Cloud is no longer required for that).
--
-- What changes (four functions, each the latest definition copied verbatim
-- with one condition changed; capture_claim also returns `cloud_allowed`):
--   capture_claim        cloud is not true                 -> cloud is not true AND ai is not true
--                        + 'cloud_allowed' in the claimed reply (additive)
--   capture_ai_dispatch  cloud is not true OR ai is not true -> ai is not true
--   capture_finalize     cloud is not true                 -> cloud is not true AND ai is not true
--   capture_retry_fence  cloud is not true                 -> cloud is not true AND ai is not true
-- Sources: 0117_account_deletion_fence.sql (claim, finalize, retry_fence) and
-- 20261106104441_capture_ai_attempt_budget.sql (ai_dispatch).
--
-- Unchanged: the device secret, owner binding (owner_uid = user_id =
-- consent_owner_uid, so a signed-in account is still required), revocation,
-- consent_version snapshots, the account-deletion fence, the per-install daily
-- quota (process-ios-sms), the three AI attempts per capture, and the global
-- AI ceiling (ai_global_budget, consume_ai_global_budget) checked right before
-- every provider request. A device with neither consent is refused exactly as
-- before.
--
-- Old app builds never store AI consent without Cloud consent (AI required both
-- on the device), so their behaviour is unchanged. Additive: no table, column,
-- grant or lock beyond CREATE OR REPLACE of the four functions.
-- Deploy order: this migration, then process-ios-sms (reads cloud_allowed;
-- an older server reply without it is treated as Cloud on, as before), then
-- the app build.
-- Rollback: supabase/rollback/20261120120000_smart_analysis_without_cloud_rollback.sql

begin;

create or replace function public.capture_claim(
  p_install_id_hash text,
  p_install_id text,
  p_payload_id text,
  p_raw_fingerprint text,
  p_owner_uid uuid,
  p_contract integer,
  p_lease_seconds integer default 60,
  p_owner_generation bigint default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d public.capture_devices%rowtype;
  r public.processed_captures%rowtype;
  v_push jsonb;
  v_ownerless boolean := false;
begin
  perform account_fence.admit_install(p_install_id_hash);  -- [fence]
  perform account_fence.admit(p_owner_uid);  -- [fence]
  -- One snapshot: the device row is share-locked for the rest of this tx, so a
  -- concurrent link / consent change / revoke serializes strictly before or after.
  select * into d from public.capture_devices
   where install_id_hash = p_install_id_hash for share;
  if not found then
    return jsonb_build_object('outcome', 'denied', 'code', 'consent_required');
  end if;
  if d.revoked_at is not null then
    return jsonb_build_object('outcome', 'denied', 'code', 'credential_revoked');
  end if;
  if p_contract = 2 or p_owner_uid is not null then
    -- Owner-bound upload (any schema version): owner_uid == user_id == consent_owner_uid.
    if p_owner_uid is null or d.user_id is null or d.consent_owner_uid is null
       or p_owner_uid <> d.user_id or d.user_id <> d.consent_owner_uid then
      return jsonb_build_object('outcome', 'denied', 'code', 'capture_owner_mismatch');
    end if;
  elsif d.consent_owner_uid is distinct from d.user_id then
    return jsonb_build_object('outcome', 'denied', 'code', 'consent_required');
  else
    v_ownerless := true;
  end if;
  -- Smart analysis without Cloud: a device may upload for analysis under Cloud
  -- consent OR smart-analysis (AI) consent. Neither = nothing is claimed.
  if d.cloud_processing_enabled is not true and d.ai_consent_granted is not true then
    return jsonb_build_object('outcome', 'denied', 'code', 'consent_required');
  end if;
  if v_ownerless and not exists (
       select 1 from public.capture_install_owner_history h
        where h.install_id_hash = p_install_id_hash
          and h.trusted and not h.transitioned
          and h.first_owner_uid is not null
          and h.first_owner_uid = d.user_id
          and d.user_id = d.consent_owner_uid) then
    -- H1 option B: an OWNERLESS (build-50) upload is attributable only when the trusted
    -- install history proves one owner who never changed (see 0110). No row, no content, no AI.
    return jsonb_build_object('outcome', 'owner_conflict', 'reason', 'ownerless_not_eligible');
  end if;

  insert into public.processed_captures
    (payload_id, install_id_hash, claimed_user_id, status, state, parsed, notification,
     raw_fingerprint, lease_until, lease_token, attempts, owner_uid, consent_owner_uid, consent_version,
     client_owner_generation)
  values
    (p_payload_id, p_install_id_hash, d.user_id, 'rejected', 'processing', '{}'::jsonb, '{}'::jsonb,
     p_raw_fingerprint, now() + make_interval(secs => p_lease_seconds), 1, 1,
     p_owner_uid, d.consent_owner_uid, d.consent_version, p_owner_generation)
  on conflict (install_id_hash, payload_id) do nothing
  returning * into r;
  if found then
    return jsonb_build_object('outcome', 'claimed', 'lease_token', r.lease_token,
      'attempts', r.attempts, 'claimed_user_id', d.user_id,
      'consent_owner_uid', d.consent_owner_uid, 'consent_version', d.consent_version,
      'ai_allowed', d.ai_consent_granted,
      'cloud_allowed', d.cloud_processing_enabled is true);
  end if;

  select * into r from public.processed_captures
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id for update;
  if not found then
    -- Row pruned between the conflict and the read: caller retries.
    return jsonb_build_object('outcome', 'in_progress');
  end if;

  if r.claimed_user_id is distinct from d.user_id then
    return jsonb_build_object('outcome', 'owner_conflict');
  end if;
  if r.raw_fingerprint is not null and r.raw_fingerprint is distinct from p_raw_fingerprint then
    return jsonb_build_object('outcome', 'id_conflict');
  end if;

  -- F1: past the expiry fence nothing is re-claimed, re-leased or replayed with content:
  -- the row is nulled and expired, and the stored (empty, expired) result is replayed.
  if r.state in ('processing', 'processed', 'retryable', 'rejected')
     and not public.capture_content_live(r.created_at) then
    perform public.capture_expire_row(p_install_id_hash, p_payload_id);
    select * into r from public.processed_captures
     where install_id_hash = p_install_id_hash and payload_id = p_payload_id;
    return jsonb_build_object('outcome', 'replay', 'row', public.capture_row_json(r));
  end if;

  if r.state in ('processing', 'retryable') then
    if r.state = 'processing' and r.lease_until > now() then
      return jsonb_build_object('outcome', 'in_progress');
    end if;
    if r.state = 'retryable' and r.next_attempt_at > now() then
      return jsonb_build_object('outcome', 'replay', 'row', public.capture_row_json(r));
    end if;
    if r.attempts >= 5 then
      update public.processed_captures
         set state = 'rejected', status = 'rejected', lease_until = null,
             failure_reason = 'attempts_exhausted', parsed = '{}'::jsonb,
             notification = '{}'::jsonb, sanitized_text = null
       where install_id_hash = p_install_id_hash and payload_id = p_payload_id
       returning * into r;
      return jsonb_build_object('outcome', 'replay', 'row', public.capture_row_json(r));
    end if;
    -- Re-claim: lease_token and attempts increment AT CLAIM; the consent snapshot
    -- is retaken; the AI marker is cleared so a new dispatch is required.
    update public.processed_captures
       set state = 'processing', lease_until = now() + make_interval(secs => p_lease_seconds),
           lease_token = lease_token + 1, attempts = attempts + 1,
           consent_owner_uid = d.consent_owner_uid, consent_version = d.consent_version,
           owner_uid = p_owner_uid, client_owner_generation = p_owner_generation,
           ai_started_at = null, ai_consent_version = null, next_attempt_at = null
     where install_id_hash = p_install_id_hash and payload_id = p_payload_id
     returning * into r;
    return jsonb_build_object('outcome', 'claimed', 'lease_token', r.lease_token,
      'attempts', r.attempts, 'claimed_user_id', d.user_id,
      'consent_owner_uid', d.consent_owner_uid, 'consent_version', d.consent_version,
      'ai_allowed', d.ai_consent_granted,
      'cloud_allowed', d.cloud_processing_enabled is true);
  end if;

  -- processed | rejected | consumed | expired: replay the stored result. A push
  -- that was never confirmed is re-offered only when the stored consent snapshot
  -- still matches the device (the replay is inside the same fenced snapshot).
  if r.state in ('processed', 'rejected') and r.apns_push_sent_at is null
     and coalesce(r.notification ->> 'title', '') <> ''
     and r.consent_owner_uid is not distinct from d.consent_owner_uid
     and r.consent_version is not distinct from d.consent_version then
    v_push := public.capture_queue_push(p_install_id_hash, p_install_id, p_payload_id,
      d.user_id, r.notification ->> 'type');
  end if;
  return jsonb_build_object('outcome', 'replay', 'row', public.capture_row_json(r), 'push', v_push);
end;
$$;


CREATE OR REPLACE FUNCTION public.capture_ai_dispatch(p_install_id_hash text, p_payload_id text, p_lease_token integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  d public.capture_devices%rowtype;
  r public.processed_captures%rowtype;
  v_reason text;
begin
  perform account_fence.admit_install(p_install_id_hash);  -- [fence]
  select * into d from public.capture_devices
   where install_id_hash = p_install_id_hash for share;
  select * into r from public.processed_captures
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id for update;
  if not found or r.lease_token <> p_lease_token or r.state <> 'processing'
     or r.lease_until is null or r.lease_until <= clock_timestamp()
     or d.install_id_hash is null then
    return jsonb_build_object('allowed', false, 'reason', 'lease_lost');
  end if;
  -- F1: an expired row never starts AI (no ai_started_at); it is nulled and expired.
  if not public.capture_content_live(r.created_at) then
    perform public.capture_expire_row(p_install_id_hash, p_payload_id);
    return jsonb_build_object('allowed', false, 'reason', 'expired');
  end if;

  if d.user_id is distinct from r.claimed_user_id
     or d.consent_owner_uid is distinct from r.consent_owner_uid
     or d.consent_owner_uid is distinct from d.user_id
     or (r.owner_uid is not null and r.owner_uid is distinct from d.user_id) then
    v_reason := 'owner_changed';
  -- AI needs the smart-analysis (AI) consent only; Cloud is no longer required.
  elsif d.revoked_at is not null
     or d.ai_consent_granted is not true
     or d.consent_version is distinct from r.consent_version then
    v_reason := 'consent_revoked';
  end if;

  if v_reason is not null then
    update public.processed_captures
       set state = 'retryable', failure_reason = v_reason, lease_until = null,
           next_attempt_at = now() + make_interval(secs => 30 * attempts)
     where install_id_hash = p_install_id_hash and payload_id = p_payload_id;
    return jsonb_build_object('allowed', false, 'reason', v_reason);
  end if;

  if r.ai_attempts >= 3 then
    return jsonb_build_object('allowed', false, 'reason', 'analysis_exhausted');
  end if;

  update public.processed_captures
     set ai_attempts = ai_attempts + 1,
         ai_started_at = now(), ai_consent_version = d.consent_version, ai_invoked = true
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id;
  return jsonb_build_object('allowed', true);
end;
$function$;


create or replace function public.capture_finalize(
  p_install_id_hash text,
  p_install_id text,
  p_payload_id text,
  p_lease_token integer,
  p_state text,
  p_status text,
  p_parsed jsonb,
  p_notification jsonb,
  p_sanitized_text text,
  p_failure_reason text,
  p_possible_duplicate boolean,
  p_validator_result jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d public.capture_devices%rowtype;
  r public.processed_captures%rowtype;
  v_reason text;
  v_push jsonb;
begin
  perform account_fence.admit_install(p_install_id_hash);  -- [fence]
  if p_state not in ('processed', 'rejected', 'retryable') then
    raise exception 'invalid_terminal_state' using errcode = '22023';
  end if;
  select * into d from public.capture_devices
   where install_id_hash = p_install_id_hash for share;
  select * into r from public.processed_captures
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id for update;
  if not found or d.install_id_hash is null or r.lease_token <> p_lease_token or r.state <> 'processing' then
    return jsonb_build_object('written', false, 'push_allowed', false, 'reason', 'lease_lost');
  end if;
  -- F1: an expired lease writes no result and queues no push; it nulls instead.
  if not public.capture_content_live(r.created_at) then
    perform public.capture_expire_row(p_install_id_hash, p_payload_id);
    return jsonb_build_object('written', false, 'push_allowed', false, 'reason', 'expired');
  end if;

  if d.user_id is distinct from r.claimed_user_id
     or d.consent_owner_uid is distinct from r.consent_owner_uid
     or d.consent_owner_uid is distinct from d.user_id
     or (r.owner_uid is not null and r.owner_uid is distinct from d.user_id) then
    v_reason := 'owner_changed';
  elsif d.revoked_at is not null
     or (d.cloud_processing_enabled is not true and d.ai_consent_granted is not true)
     or d.consent_version is distinct from r.consent_version then
    v_reason := 'consent_revoked';
  end if;

  if v_reason is not null then
    update public.processed_captures
       set state = 'retryable', failure_reason = v_reason, lease_until = null,
           next_attempt_at = now() + make_interval(secs => 30 * attempts)
     where install_id_hash = p_install_id_hash and payload_id = p_payload_id;
    return jsonb_build_object('written', false, 'push_allowed', false, 'reason', v_reason);
  end if;

  if p_state = 'retryable' then
    update public.processed_captures
       set state = 'retryable', failure_reason = p_failure_reason, lease_until = null,
           next_attempt_at = now() + make_interval(secs => 30 * attempts)
     where install_id_hash = p_install_id_hash and payload_id = p_payload_id
     returning * into r;
    return jsonb_build_object('written', true, 'push_allowed', false, 'state', 'retryable',
      'row', public.capture_row_json(r));
  end if;

  update public.processed_captures
     set state = p_state, status = p_status, parsed = coalesce(p_parsed, '{}'::jsonb),
         notification = coalesce(p_notification, '{}'::jsonb), sanitized_text = p_sanitized_text,
         failure_reason = p_failure_reason, possible_duplicate = coalesce(p_possible_duplicate, false),
         validator_result = p_validator_result, lease_until = null, next_attempt_at = null
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id
   returning * into r;
  if coalesce(p_notification ->> 'title', '') <> '' then
    v_push := public.capture_queue_push(p_install_id_hash, p_install_id, p_payload_id,
      r.claimed_user_id, p_notification ->> 'type');
    select * into r from public.processed_captures
     where install_id_hash = p_install_id_hash and payload_id = p_payload_id;
  end if;
  return jsonb_build_object('written', true, 'push_allowed', true, 'state', p_state,
    'row', public.capture_row_json(r), 'push', v_push);
end;
$$;


create or replace function public.capture_retry_fence(
  p_install_id_hash text,
  p_payload_id text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d public.capture_devices%rowtype;
  r public.processed_captures%rowtype;
  v_expired boolean;
begin
  perform account_fence.admit_install(p_install_id_hash);  -- [fence]
  select * into d from public.capture_devices
   where install_id_hash = p_install_id_hash for share;
  select * into r from public.processed_captures
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id for update;
  if d.install_id_hash is null or r.payload_id is null then
    return jsonb_build_object('allowed', false, 'reason', 'gone');
  end if;
  -- F1: a row past the expiry fence is nulled and expired on sight (the row lock is
  -- exclusive so the null cannot race a finalize); a consumed tombstone is untouched.
  v_expired := r.state <> 'consumed' and not public.capture_content_live(r.created_at);
  if v_expired then
    perform public.capture_expire_row(p_install_id_hash, p_payload_id);
  end if;
  if r.apns_push_sent_at is not null then
    return jsonb_build_object('allowed', false, 'reason', 'already_sent');
  end if;
  if v_expired then
    return jsonb_build_object('allowed', false, 'reason', 'expired');
  end if;
  -- consumed / expired / retryable / processing: nothing (or nothing yet) to alert about.
  if r.state not in ('processed', 'rejected') then
    return jsonb_build_object('allowed', false, 'reason', 'not_pending');
  end if;
  if d.revoked_at is not null then
    return jsonb_build_object('allowed', false, 'reason', 'credential_revoked');
  end if;
  if d.cloud_processing_enabled is not true and d.ai_consent_granted is not true then
    return jsonb_build_object('allowed', false, 'reason', 'consent_revoked');
  end if;
  if d.user_id is distinct from r.claimed_user_id
     or d.consent_owner_uid is distinct from r.consent_owner_uid
     or d.consent_owner_uid is distinct from d.user_id
     or d.consent_version is distinct from r.consent_version then
    return jsonb_build_object('allowed', false, 'reason', 'owner_changed');
  end if;
  if d.apns_token is null or d.apns_environment is null then
    return jsonb_build_object('allowed', false, 'reason', 'no_token');
  end if;
  if coalesce(r.notification ->> 'title', '') = '' then
    return jsonb_build_object('allowed', false, 'reason', 'no_content');
  end if;
  return jsonb_build_object(
    'allowed', true,
    'apns_token', d.apns_token,
    'apns_environment', d.apns_environment,
    'notification_type', r.notification ->> 'type');
end;
$$;


revoke all on function public.capture_claim(text, text, text, text, uuid, integer, integer, bigint) from public, anon, authenticated;
revoke all on function public.capture_ai_dispatch(text, text, integer) from public, anon, authenticated;
revoke all on function public.capture_finalize(text, text, text, integer, text, text, jsonb, jsonb, text, text, boolean, jsonb) from public, anon, authenticated;
revoke all on function public.capture_retry_fence(text, text) from public, anon, authenticated;
grant execute on function public.capture_claim(text, text, text, text, uuid, integer, integer, bigint) to service_role;
grant execute on function public.capture_ai_dispatch(text, text, integer) to service_role;
grant execute on function public.capture_finalize(text, text, text, integer, text, text, jsonb, jsonb, text, text, boolean, jsonb) to service_role;
grant execute on function public.capture_retry_fence(text, text) to service_role;

commit;
