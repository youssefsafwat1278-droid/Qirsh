-- Project-wide daily ceiling on paid AI calls (V1-022 / audit F BE-03).
--
-- Per-identity caps (parse-sms 500/day, process-ios-sms 300, bank-discovery 50,
-- enrich-merchant 200) can be multiplied with new device identities. This adds
-- ONE counter per provider bucket per UTC day, checked server-side before the
-- provider is called. When the ceiling is reached, or the bucket is switched
-- off, or this function cannot be reached, the caller does NOT call the
-- provider and sends the item to review (fail closed; see
-- supabase/functions/_shared/ai_spend_guard.ts).
--
-- Buckets: 'gemini' (every Gemini call: process-ios-sms, parse-sms,
-- bank-discovery) and 'places' (enrich-merchant). The ceilings below are
-- starting values chosen from production volume on 2026-11-17 (under 30 AI
-- calls/day across all users); the owner changes them with an UPDATE on
-- public.ai_global_budget (no deploy). Setting enabled = false is a server-side
-- AI kill switch that needs no secret change.
--
-- No personal data: rows hold a bucket name, a UTC date and counts.
--
-- LOCKS / SAFETY: additive only. Two new tables and one new function; no
-- existing object is altered, so no lock is taken on any existing table.
-- Idempotent: IF NOT EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING; the
-- grants are repeatable. Old function code never calls the new function, so
-- applying this migration changes no behaviour until a function that uses
-- the guard is deployed.
-- Rollback: supabase/rollback/20261117120000_ai_global_spend_guard_rollback.sql

create table if not exists public.ai_global_budget (
  bucket      text primary key check (bucket ~ '^[a-z][a-z0-9_]{0,31}$'),
  daily_limit integer not null check (daily_limit >= 0),
  enabled     boolean not null default true,
  updated_at  timestamptz not null default now()
);

create table if not exists public.ai_global_spend (
  day     date not null,
  bucket  text not null,
  calls   integer not null default 0 check (calls >= 0),
  denied  integer not null default 0 check (denied >= 0),
  primary key (day, bucket)
);

alter table public.ai_global_budget enable row level security;
alter table public.ai_global_spend enable row level security;
revoke all on table public.ai_global_budget from public, anon, authenticated;
revoke all on table public.ai_global_spend from public, anon, authenticated;
grant select, insert, update on table public.ai_global_budget to service_role;
grant select, insert, update on table public.ai_global_spend to service_role;

insert into public.ai_global_budget (bucket, daily_limit, enabled) values
  ('gemini', 3000, true),
  ('places', 1000, true)
on conflict (bucket) do nothing;

-- Reserve p_units calls in p_bucket for the current UTC day.
-- Returns {allowed, reason, used, limit}. reason: ok | ceiling | disabled |
-- unknown_bucket. The reservation and the ceiling check are one statement, so
-- concurrent callers cannot overshoot the ceiling.
create or replace function public.consume_ai_global_budget(
  p_bucket text,
  p_units integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit   integer;
  v_enabled boolean;
  v_day     date := (now() at time zone 'utc')::date;
  v_used    integer;
begin
  if p_units is null or p_units < 1 or p_units > 100 then
    raise exception 'consume_ai_global_budget: p_units must be 1..100' using errcode = '22023';
  end if;

  select b.daily_limit, b.enabled into v_limit, v_enabled
  from public.ai_global_budget b
  where b.bucket = p_bucket;

  if not found then
    return jsonb_build_object('allowed', false, 'reason', 'unknown_bucket', 'used', 0, 'limit', 0);
  end if;

  if not v_enabled or p_units > v_limit then
    insert into public.ai_global_spend as s (day, bucket, calls, denied)
    values (v_day, p_bucket, 0, 1)
    on conflict (day, bucket) do update set denied = s.denied + 1
    returning s.calls into v_used;
    return jsonb_build_object(
      'allowed', false,
      'reason', case when not v_enabled then 'disabled' else 'ceiling' end,
      'used', v_used, 'limit', v_limit);
  end if;

  insert into public.ai_global_spend as s (day, bucket, calls)
  values (v_day, p_bucket, p_units)
  on conflict (day, bucket) do update set calls = s.calls + excluded.calls
    where s.calls + excluded.calls <= v_limit
  returning s.calls into v_used;

  if v_used is null then
    update public.ai_global_spend s set denied = s.denied + 1
    where s.day = v_day and s.bucket = p_bucket
    returning s.calls into v_used;
    return jsonb_build_object('allowed', false, 'reason', 'ceiling', 'used', v_used, 'limit', v_limit);
  end if;

  return jsonb_build_object('allowed', true, 'reason', 'ok', 'used', v_used, 'limit', v_limit);
end;
$$;

revoke all on function public.consume_ai_global_budget(text, integer) from public, anon, authenticated;
grant execute on function public.consume_ai_global_budget(text, integer) to service_role;
