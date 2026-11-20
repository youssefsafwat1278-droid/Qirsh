-- Gemini-first phase 4: the shared, non-personal analysis memory.
--
-- 1. sms_shape_templates — the shape memory. One row per (bank sender, message
--    skeleton). A skeleton is the masked message with every figure and the
--    merchant replaced by a typed slot ({A} amount, {M} merchant, {L} card
--    last 4, {N} any other figure). While a shape is a CANDIDATE only its hash,
--    the model's reading and counts are stored (no wording); the skeleton text
--    is written when it becomes ACTIVE: 3 consistent Gemini reads from at
--    least 2 devices. A read that disagrees drops it for good (skeleton and
--    reading cleared, hash kept so it is never learned again).
-- 2. merchant_code_memory — a merchant code (the device merchant key: upper
--    case, digits removed) the model classified as a merchant, with the
--    model's category (a later different category marks it 'conflict': no
--    template reads it) and a display name from one Google Places lookup.
-- 3. sms_analysis_daily — counts only (day, counter, count): template hits,
--    Gemini reads, checks, drops, activations, Places lookups.
--
-- No personal data: no user, install or owner column; no amount, number, name
-- or merchant value in a template; a message with a masked person ([NAME]) is
-- never a shape (enforced in supabase/functions/_shared/sms_shape_memory.ts).
-- The per-device tag counts distinct devices; it is a truncated hash of the
-- install hash and the shape hash, unlinkable across shapes.
--
-- RLS on, no policy: only service_role (process-ios-sms) reads or writes.
-- Additive and idempotent (IF NOT EXISTS, CREATE OR REPLACE); no existing
-- object is altered or locked. Old function code never touches these objects.
-- Deploy order: this migration, then process-ios-sms. A function deployed
-- first finds no table/RPC and behaves exactly as before (every read fails
-- as "nothing known": Gemini is called; every write is best-effort).
-- Rollback: supabase/rollback/20261120130000_sms_analysis_memory_rollback.sql

begin;

create table if not exists public.sms_shape_templates (
  skeleton_hash text primary key check (skeleton_hash ~ '^[0-9a-f]{64}$'),
  sender_key    text not null check (char_length(sender_key) between 2 and 32),
  status        text not null default 'candidate' check (status in ('candidate', 'active', 'dropped')),
  skeleton      text null check (skeleton is null or char_length(skeleton) <= 2000),
  reading       jsonb null,
  observations  integer not null default 1 check (observations >= 0),
  sources       text[] not null default '{}',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  activated_at  timestamptz null,
  dropped_at    timestamptz null,
  check (status <> 'active' or (skeleton is not null and reading is not null))
);

create index if not exists sms_shape_templates_active_sender
  on public.sms_shape_templates (sender_key) where status = 'active';

create table if not exists public.merchant_code_memory (
  code_key       text primary key check (char_length(code_key) between 2 and 60),
  category_key   text null check (category_key is null or category_key ~ '^[a-z_]{1,32}$'),
  category_state text not null default 'agreed' check (category_state in ('agreed', 'conflict')),
  reads          integer not null default 1 check (reads >= 0),
  display_name   text null check (display_name is null or char_length(display_name) <= 60),
  lookup_state   text not null default 'none' check (lookup_state in ('none', 'pending', 'done', 'failed')),
  lookup_at      timestamptz null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table if not exists public.sms_analysis_daily (
  day     date not null,
  counter text not null check (counter in (
    'model_read', 'template_hit', 'template_check', 'template_drop', 'template_activated', 'merchant_lookup')),
  count   integer not null default 0 check (count >= 0),
  primary key (day, counter)
);

alter table public.sms_shape_templates enable row level security;
alter table public.merchant_code_memory enable row level security;
alter table public.sms_analysis_daily enable row level security;
revoke all on table public.sms_shape_templates from public, anon, authenticated;
revoke all on table public.merchant_code_memory from public, anon, authenticated;
revoke all on table public.sms_analysis_daily from public, anon, authenticated;
grant select, insert, update on table public.sms_shape_templates to service_role;
grant select, insert, update on table public.merchant_code_memory to service_role;
grant select, insert, update on table public.sms_analysis_daily to service_role;

-- One Gemini read of a shape. Returns the shape's state after it:
-- 'candidate', 'activated' (just became a template), 'active', 'dropped'
-- (already dropped) or 'conflict' (this read disagreed: dropped now).
create or replace function public.sms_template_observe(
  p_sender_key text,
  p_skeleton_hash text,
  p_source_tag text,
  p_reading jsonb,
  p_skeleton text,
  p_min_reads integer default 3,
  p_min_sources integer default 2
) returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r public.sms_shape_templates%rowtype;
  v_sources text[];
  v_reads integer;
begin
  if p_source_tag is null or p_source_tag !~ '^[0-9a-f]{16}$' or p_reading is null
     or jsonb_typeof(p_reading) <> 'object' or p_min_reads < 2 or p_min_sources < 1 then
    raise exception 'sms_template_observe: invalid arguments' using errcode = '22023';
  end if;

  insert into public.sms_shape_templates (skeleton_hash, sender_key, reading, observations, sources)
  values (p_skeleton_hash, p_sender_key, p_reading, 1, array[p_source_tag])
  on conflict (skeleton_hash) do nothing;
  if found then
    return 'candidate';
  end if;

  select * into r from public.sms_shape_templates where skeleton_hash = p_skeleton_hash for update;
  if r.status = 'dropped' then
    return 'dropped';
  end if;
  if r.sender_key <> p_sender_key or r.reading is distinct from p_reading then
    update public.sms_shape_templates
       set status = 'dropped', skeleton = null, reading = null, dropped_at = now(), updated_at = now()
     where skeleton_hash = p_skeleton_hash;
    return 'conflict';
  end if;

  v_sources := case when p_source_tag = any(r.sources) then r.sources
                    else (r.sources || p_source_tag)[greatest(1, cardinality(r.sources) - 6):] end;
  v_reads := r.observations + 1;
  if r.status = 'candidate' and v_reads >= p_min_reads and cardinality(v_sources) >= p_min_sources then
    update public.sms_shape_templates
       set status = 'active', skeleton = p_skeleton, observations = v_reads, sources = v_sources,
           activated_at = now(), updated_at = now()
     where skeleton_hash = p_skeleton_hash;
    return 'activated';
  end if;
  update public.sms_shape_templates
     set observations = v_reads, sources = v_sources, updated_at = now()
   where skeleton_hash = p_skeleton_hash;
  return r.status;
end;
$$;

-- Gemini disagreed with a template's reading: dropped for good.
create or replace function public.sms_template_drop(p_skeleton_hash text)
returns boolean
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.sms_shape_templates
     set status = 'dropped', skeleton = null, reading = null, dropped_at = now(), updated_at = now()
   where skeleton_hash = p_skeleton_hash and status <> 'dropped'
  returning true;
$$;

-- One model reading of a merchant code with its category.
create or replace function public.merchant_code_observe(p_code_key text, p_category text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r public.merchant_code_memory%rowtype;
begin
  insert into public.merchant_code_memory as m (code_key, category_key)
  values (p_code_key, p_category)
  on conflict (code_key) do update
    set reads = m.reads + 1,
        category_state = case when m.category_key is distinct from excluded.category_key
                              then 'conflict' else m.category_state end,
        updated_at = now()
  returning * into r;
  return jsonb_build_object('category_state', r.category_state, 'lookup_state', r.lookup_state);
end;
$$;

-- Claims the single Places lookup of a code (true = this caller looks it up).
-- A claim left pending for a day (a crashed worker) may be taken again.
create or replace function public.merchant_code_claim_lookup(p_code_key text)
returns boolean
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.merchant_code_memory
     set lookup_state = 'pending', lookup_at = now(), updated_at = now()
   where code_key = p_code_key
     and (lookup_state = 'none' or (lookup_state = 'pending' and lookup_at < now() - interval '1 day'))
  returning true;
$$;

-- The lookup's result: a name ('done'), '' = looked up, nothing usable
-- ('failed', never again), null = not looked up (released to 'none').
create or replace function public.merchant_code_resolve(p_code_key text, p_display_name text)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.merchant_code_memory
     set display_name = nullif(p_display_name, ''),
         lookup_state = case when p_display_name is null then 'none'
                             when p_display_name = '' then 'failed' else 'done' end,
         updated_at = now()
   where code_key = p_code_key and lookup_state = 'pending';
$$;

create or replace function public.bump_sms_analysis_daily(p_counter text)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.sms_analysis_daily as s (day, counter, count)
  values ((now() at time zone 'utc')::date, p_counter, 1)
  on conflict (day, counter) do update set count = s.count + 1;
$$;

revoke all on function public.sms_template_observe(text, text, text, jsonb, text, integer, integer) from public, anon, authenticated;
revoke all on function public.sms_template_drop(text) from public, anon, authenticated;
revoke all on function public.merchant_code_observe(text, text) from public, anon, authenticated;
revoke all on function public.merchant_code_claim_lookup(text) from public, anon, authenticated;
revoke all on function public.merchant_code_resolve(text, text) from public, anon, authenticated;
revoke all on function public.bump_sms_analysis_daily(text) from public, anon, authenticated;
grant execute on function public.sms_template_observe(text, text, text, jsonb, text, integer, integer) to service_role;
grant execute on function public.sms_template_drop(text) to service_role;
grant execute on function public.merchant_code_observe(text, text) to service_role;
grant execute on function public.merchant_code_claim_lookup(text) to service_role;
grant execute on function public.merchant_code_resolve(text, text) to service_role;
grant execute on function public.bump_sms_analysis_daily(text) to service_role;

commit;
