-- Automatic retry of admin push broadcasts (builds on 20261116160000).
--
-- Until now a failed delivery was retried only when the admin pressed
-- "إعادة المحاولة". A pg_cron job now resumes every recent broadcast that still
-- has deliveries due, through the same send-push-broadcast Edge Function, in a
-- worker mode authenticated by a dedicated secret (process-notification-retries
-- / 0098 pattern).
--
-- RETRY POLICY (scheduled runs only; the manual button ignores the backoff):
--   * A counted failure waits push_broadcast_retry_backoff(attempt_count) after
--     its attempt: 10, 20, 40, 80 minutes. Still capped at 5 attempts.
--   * apns_not_configured (nothing reached Apple) burns no attempt and waits 30
--     minutes. The worker also refuses to claim anything while APNs credentials
--     are missing, so a misconfigured project does not churn rows.
--   * Dead tokens (410 / BadDeviceToken / Unregistered / ExpiredToken) and
--     DeviceTokenNotForTopic are permanent: the sender records them as
--     'skipped' (terminal) instead of 'failed'. Already-exhausted rows with those
--     errors are reclassified below.
--   * A 'pending' row is left to the admin's own send call for its first 5
--     minutes, then the scheduler picks it up (resumes a send that died).
--   * Only broadcasts created in the last 72 hours are resumed automatically;
--     older ones keep their manual retry button.
--
-- NO DOUBLE SEND. Manual and scheduled runs claim through ONE function
-- (push_broadcast_claim_rows): FOR UPDATE SKIP LOCKED, and the claim moves the
-- row to 'sending' in the same statement, so a row is held by exactly one run
-- until that run finishes it. An abandoned 'sending' row is reclaimable only
-- after 15 minutes (was 5): longer than an Edge Function can live (400 s wall
-- clock) and than the sender's own 120 s claim budget, so a live run can never
-- lose a row to another run while it is still about to send it.
--
-- OWNER ACTION (deliberately NOT performed by this migration):
--   supabase secrets set PUSH_BROADCAST_WORKER_SECRET=<openssl rand -hex 32>
--   and store the SAME value in Vault as 'push_broadcast_worker_secret'
--   (>= 32 chars, >= 10 distinct; a weaker value is treated as unset on both
--   sides). Rollback: docs/PUSH_BROADCAST_AUTO_RETRY_ROLLBACK_RUNBOOK.md
--   ('project_url' is already in Vault for the other workers). Until then the
--   dispatcher logs a skip and does nothing; the manual button is unaffected.

begin;

-- ─── 1. Column ──────────────────────────────────────────────────────────────
-- Earliest time a scheduled run may retry a failed row. NULL = due now.
alter table public.push_broadcast_deliveries
  add column if not exists next_attempt_at timestamptz null;

-- ─── 2. Policy helpers ──────────────────────────────────────────────────────
create or replace function public.push_broadcast_retry_backoff(p_attempts integer)
returns interval
language sql immutable
set search_path = pg_catalog, pg_temp
as $$
  select make_interval(mins => 10 * (2 ^ (least(greatest(coalesce(p_attempts, 1), 1), 5) - 1))::integer)
$$;

-- The single definition of "this row may be claimed now". p_scheduled adds the
-- backoff, the pending grace and the 72 h window; the lease rule is identical
-- for both callers.
create or replace function public.push_broadcast_delivery_claimable(
  p_status          text,
  p_attempts        integer,
  p_next_attempt_at timestamptz,
  p_created_at      timestamptz,
  p_claimed_at      timestamptz,
  p_scheduled       boolean
) returns boolean
language sql stable
set search_path = pg_catalog, pg_temp
as $$
  select case
    when p_status = 'sending' then p_claimed_at < now() - interval '15 minutes'
    when p_status not in ('pending', 'failed') or p_attempts >= 5 then false
    when not p_scheduled then true
    when p_status = 'pending' then p_created_at <= now() - interval '5 minutes'
    else p_next_attempt_at is null or p_next_attempt_at <= now()
  end
$$;

-- ─── 3. Shared claim (manual and scheduled) ─────────────────────────────────
-- SECURITY INVOKER and executable by no API role: reached only through the two
-- definer wrappers below, which run as the owner.
create or replace function public.push_broadcast_claim_rows(
  p_broadcast_id uuid,
  p_run_id       uuid,
  p_limit        integer,
  p_scheduled    boolean
) returns table (
  delivery_id        uuid,
  device_hash        text,
  attempts           integer,
  in_audience        boolean,
  token              text,
  environment        text,
  settings_language  text,
  notifications_json text
)
language plpgsql volatile
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  if p_run_id is null then
    raise exception 'run_id_required' using errcode = 'P0422';
  end if;
  return query
  with picked as (
    select x.id
      from public.push_broadcast_deliveries x
      join public.push_broadcasts b on b.id = x.broadcast_id
     where x.broadcast_id = p_broadcast_id
       and public.push_broadcast_delivery_claimable(x.status, x.attempt_count, x.next_attempt_at,
             x.created_at, x.claimed_at, p_scheduled)
       and x.last_run_id is distinct from p_run_id
       and (not p_scheduled or b.created_at > now() - interval '72 hours')
     order by x.created_at, x.id
     limit greatest(1, least(coalesce(p_limit, 100), 500))
     for update of x skip locked
  ), claimed as (
    update public.push_broadcast_deliveries x
       set status = 'sending', claimed_at = now(), last_run_id = p_run_id, updated_at = now()
      from picked
     where x.id = picked.id
    returning x.id, x.install_id_hash, x.attempt_count
  )
  select c.id, c.install_id_hash, c.attempt_count, a.install_id_hash is not null,
         a.apns_token, a.apns_environment, a.settings_language, a.notifications_json
    from claimed c
    left join public.push_broadcast_audience_devices() a on a.install_id_hash = c.install_id_hash;
end;
$$;

-- Manual (admin) claim: same signature and contract as 20261116160000; it now
-- delegates to the shared claim and so shares its lease with the scheduler.
create or replace function public.claim_push_broadcast_deliveries(
  p_actor        uuid,
  p_broadcast_id uuid,
  p_run_id       uuid,
  p_limit        integer default 100
) returns table (
  delivery_id        uuid,
  device_hash        text,
  attempts           integer,
  in_audience        boolean,
  token              text,
  environment        text,
  settings_language  text,
  notifications_json text
)
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
begin
  perform public.push_broadcast_require_admin(p_actor);
  return query select * from public.push_broadcast_claim_rows(p_broadcast_id, p_run_id, p_limit, false);
end;
$$;

-- Scheduled claim: backoff-aware, no actor (service_role only).
create or replace function public.claim_push_broadcast_retry_deliveries(
  p_broadcast_id uuid,
  p_run_id       uuid,
  p_limit        integer default 100
) returns table (
  delivery_id        uuid,
  device_hash        text,
  attempts           integer,
  in_audience        boolean,
  token              text,
  environment        text,
  settings_language  text,
  notifications_json text
)
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
begin
  return query select * from public.push_broadcast_claim_rows(p_broadcast_id, p_run_id, p_limit, true);
end;
$$;

-- Broadcasts the scheduler should resume now, oldest first.
create or replace function public.push_broadcast_retry_due(p_limit integer default 20)
returns table (broadcast_id uuid)
language sql stable security definer
set search_path = public, pg_temp
as $$
  select b.id
    from public.push_broadcasts b
   where b.created_at > now() - interval '72 hours'
     and exists (
       select 1 from public.push_broadcast_deliveries x
        where x.broadcast_id = b.id
          and x.status in ('pending', 'sending', 'failed')
          and public.push_broadcast_delivery_claimable(x.status, x.attempt_count, x.next_attempt_at,
                x.created_at, x.claimed_at, true))
   order by b.created_at
   limit greatest(1, least(coalesce(p_limit, 20), 100))
$$;

-- ─── 4. Finish: also schedules the next automatic attempt ───────────────────
-- Same signature and contract as 20261116160000, plus next_attempt_at.
create or replace function public.finish_push_broadcast_delivery(
  p_delivery_id   uuid,
  p_status        text,
  p_error_code    text,
  p_count_attempt boolean,
  p_exhaust       boolean,
  p_language      text,
  p_apns_id       text
) returns boolean
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
begin
  if p_status not in ('sent', 'failed', 'skipped') then
    raise exception 'status_invalid' using errcode = 'P0422';
  end if;
  update public.push_broadcast_deliveries
     set status = p_status,
         error_code = case when p_status = 'sent' then null else left(p_error_code, 120) end,
         attempt_count = case when p_exhaust then greatest(attempt_count, 5)
                              when p_count_attempt then attempt_count + 1
                              else attempt_count end,
         next_attempt_at = case
           when p_status <> 'failed' or p_exhaust then null
           when p_count_attempt then now() + public.push_broadcast_retry_backoff(attempt_count + 1)
           else now() + interval '30 minutes' end,
         language = coalesce(p_language, language),
         apns_id = coalesce(p_apns_id, apns_id),
         sent_at = case when p_status = 'sent' then now() else sent_at end,
         claimed_at = null,
         updated_at = now()
   where id = p_delivery_id and status = 'sending';
  return found;
end;
$$;

-- ─── 5. History: when the scheduler will next look at a broadcast ───────────
-- Same signature; keeps is_test (20261116230000) and adds next_auto_retry_at
-- (NULL = no automatic retry pending).
create or replace function public.admin_push_broadcast_history(p_actor uuid, p_limit integer default 50)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  perform public.push_broadcast_require_admin(p_actor);
  select coalesce(jsonb_agg(row_to_json(h)::jsonb order by h.created_at desc), '[]'::jsonb) into v
    from (
      select b.id, b.created_at, b.created_by, b.title_ar, b.title_en, b.deep_link, b.announcement_id,
             b.recipient_devices, b.recipient_users, (b.test_user_id is not null) as is_test,
             count(d.id) filter (where d.status in ('pending', 'sending')) as pending,
             count(d.id) filter (where d.status = 'sent') as sent,
             count(d.id) filter (where d.status = 'failed') as failed,
             count(d.id) filter (where d.status = 'skipped') as skipped,
             count(d.id) filter (where d.status in ('pending', 'failed') and d.attempt_count < 5) as retryable,
             (select d2.error_code from public.push_broadcast_deliveries d2
               where d2.broadcast_id = b.id and d2.status = 'failed' and d2.error_code is not null
               group by d2.error_code order by count(*) desc, d2.error_code limit 1) as top_error,
             case when b.created_at > now() - interval '72 hours' then
               min(case when d.status = 'failed' then coalesce(d.next_attempt_at, now())
                        else d.created_at + interval '5 minutes' end)
                 filter (where d.status in ('pending', 'failed') and d.attempt_count < 5)
             end as next_auto_retry_at
        from public.push_broadcasts b
        left join public.push_broadcast_deliveries d on d.broadcast_id = b.id
       group by b.id
       order by b.created_at desc
       limit greatest(1, least(coalesce(p_limit, 50), 200))
    ) h;
  return v;
end;
$$;

-- ─── 6. Reclassify exhausted dead-token rows as skipped ─────────────────────
-- 20261116160000 recorded a dead token as failed + exhausted. They are terminal
-- either way; 'skipped' is what the sender records from now on.
update public.push_broadcast_deliveries
   set status = 'skipped', next_attempt_at = null, updated_at = now()
 where status = 'failed'
   and attempt_count >= 5
   and (error_code like 'apns\_410\_%'
        or error_code in ('apns_400_BadDeviceToken', 'apns_400_Unregistered', 'apns_400_ExpiredToken',
                          'apns_400_DeviceTokenNotForTopic'));

-- ─── 7. Dispatcher (pg_cron -> Edge Function) ───────────────────────────────
create or replace function public.run_push_broadcast_retry_dispatch()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  project_url   text;
  worker_secret text;
begin
  -- Nothing due: no HTTP call at all.
  if not exists (select 1 from public.push_broadcast_retry_due(1)) then
    return;
  end if;

  select decrypted_secret into project_url
    from vault.decrypted_secrets where name = 'project_url' limit 1;
  select decrypted_secret into worker_secret
    from vault.decrypted_secrets where name = 'push_broadcast_worker_secret' limit 1;

  -- Fail closed. A missing secret must not fall back to any other credential.
  if project_url is null or worker_secret is null then
    raise log 'push_broadcast_retry_dispatch skipped: worker secret not configured';
    return;
  end if;
  -- Same strength rule as the Edge Function (usableWorkerSecret): at least 32
  -- characters and 10 distinct ones. A weak value is never sent anywhere.
  if length(worker_secret) < 32
     or (select count(distinct c) from regexp_split_to_table(worker_secret, '') as c) < 10 then
    raise log 'push_broadcast_retry_dispatch skipped: worker secret too weak';
    return;
  end if;

  perform net.http_post(
    url := project_url || '/functions/v1/send-push-broadcast',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || worker_secret
    ),
    body := jsonb_build_object('mode', 'scheduled')
  );
end;
$$;

-- ─── 8. Privileges ──────────────────────────────────────────────────────────
revoke all on function public.push_broadcast_retry_backoff(integer) from public, anon, authenticated;
revoke all on function public.push_broadcast_delivery_claimable(text, integer, timestamptz, timestamptz, timestamptz, boolean)
  from public, anon, authenticated;
revoke all on function public.push_broadcast_claim_rows(uuid, uuid, integer, boolean)
  from public, anon, authenticated, service_role;
revoke all on function public.claim_push_broadcast_deliveries(uuid, uuid, uuid, integer) from public, anon, authenticated;
revoke all on function public.claim_push_broadcast_retry_deliveries(uuid, uuid, integer) from public, anon, authenticated;
revoke all on function public.push_broadcast_retry_due(integer) from public, anon, authenticated;
revoke all on function public.finish_push_broadcast_delivery(uuid, text, text, boolean, boolean, text, text)
  from public, anon, authenticated;
revoke all on function public.admin_push_broadcast_history(uuid, integer) from public, anon, authenticated;
revoke all on function public.run_push_broadcast_retry_dispatch() from public, anon, authenticated, service_role;

grant execute on function public.claim_push_broadcast_deliveries(uuid, uuid, uuid, integer) to service_role;
grant execute on function public.claim_push_broadcast_retry_deliveries(uuid, uuid, integer) to service_role;
grant execute on function public.push_broadcast_retry_due(integer) to service_role;
grant execute on function public.finish_push_broadcast_delivery(uuid, text, text, boolean, boolean, text, text)
  to service_role;
grant execute on function public.admin_push_broadcast_history(uuid, integer) to service_role;

-- ─── 9. Schedule (skipped when pg_cron is absent) ───────────────────────────
-- cron.schedule upserts by job name, so re-running is safe; the rollback unschedules it.
do $cron$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') then
    perform cron.schedule('push-broadcast-retry', '*/10 * * * *',
      $job$select public.run_push_broadcast_retry_dispatch()$job$);
  end if;
end
$cron$;

commit;
