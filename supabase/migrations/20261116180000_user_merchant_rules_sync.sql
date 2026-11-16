-- A user's own learned category rules ("Remember for this merchant") sync to
-- their cloud account, so a reinstall + sign-in + restore brings them back.
--
-- WHAT IS STORED
-- One row per (user, merchant): the device's normalised merchant key and the
-- category key the user chose, server-owned timestamps and a tombstone. No
-- amount, date, message, account, card or free text. Shipped catalog mappings
-- never reach this table (the client sends only user-confirmed rules).
--
-- SYNC SHAPE (same as sender_bank_mappings)
--   * keyed upsert on (user_id, merchant_key); `updated_at` and `sync_seq` are
--     server-owned (stamp_sync_seq), so the keyset pull never skips a row and
--     the newest arrival wins;
--   * deletes are tombstones (deleted_at); clients hold no DELETE privilege
--     (0115 rule for synced tables);
--   * account-deletion fence: inserts/updates go through stamp_sync_seq, which
--     admits the owner (0117), so writes are refused while a deletion is pending.
--
-- ERASURE
-- account_fence.erase_user_data / erase_verify are restated from
-- 0117_account_deletion_fence.sql (sections 7) with ONE added line each: the
-- delete of this table and its closure check. The narrow owner gets exactly the
-- erasure grant + policy every other owner table has. The FK to auth.users
-- (ON DELETE CASCADE) is the backstop.
--
-- KILL SWITCH
-- qirsh_server_capabilities() gains `merchant_rules_sync` = true (every 0114 key
-- preserved). The client syncs rules only while the server advertises it.
--
-- Reversible: rollback/20261116180000_user_merchant_rules_sync_rollback.sql.

begin;

grant account_fence_owner to current_user;

create table public.user_merchant_rules (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  merchant_key text not null,
  category_key text not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz null,
  sync_seq     bigint,
  constraint user_merchant_rules_user_merchant_key unique (user_id, merchant_key),
  -- The device key (AppDatabase.normalizeMerchant): upper-cased, ASCII digits
  -- removed, whitespace collapsed and trimmed. Bounded; never a free-text blob.
  constraint user_merchant_rules_merchant_key_shape check (
    char_length(merchant_key) between 1 and 120
    and merchant_key = btrim(regexp_replace(merchant_key, '\s+', ' ', 'g'))
    and merchant_key !~ '[0-9]'
  ),
  -- Stable category keys: catalog keys ('groceries') and custom keys
  -- ('custom_<slug>', Arabic letters allowed).
  constraint user_merchant_rules_category_key_shape check (
    char_length(category_key) between 1 and 80
    and category_key ~ '^[a-z0-9_؀-ۿ]+$'
  )
);

create index idx_user_merchant_rules_user_sync_seq
  on public.user_merchant_rules (user_id, sync_seq);
create index idx_user_merchant_rules_user_updated
  on public.user_merchant_rules (user_id, updated_at, id);

alter table public.user_merchant_rules enable row level security;

revoke all on table public.user_merchant_rules from public, anon, authenticated;
grant select on table public.user_merchant_rules to authenticated;
grant insert (user_id, merchant_key, category_key, deleted_at)
  on table public.user_merchant_rules to authenticated;
grant update (user_id, merchant_key, category_key, deleted_at)
  on table public.user_merchant_rules to authenticated;

create policy user_merchant_rules_select_own on public.user_merchant_rules
  for select to authenticated using (auth.uid() = user_id);
create policy user_merchant_rules_insert_own on public.user_merchant_rules
  for insert to authenticated with check (auth.uid() = user_id);
create policy user_merchant_rules_update_own on public.user_merchant_rules
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Server-owned updated_at + sync_seq, and the 0117 owner admission.
create trigger trg_user_merchant_rules_stamp_sync_seq
  before insert or update on public.user_merchant_rules
  for each row execute function public.stamp_sync_seq();

-- Erasure reach for the narrow owner (same shape as every 0117 owner table).
grant select, delete on table public.user_merchant_rules to account_fence_owner;
create policy account_fence_erasure on public.user_merchant_rules as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);

-- ── Erasure: restated from 0117 section 7, plus this table ─────────────────
create or replace function account_fence.erase_user_data(p_job_id uuid, p_uid uuid) returns void
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare v_log_id uuid;
begin
  if account_fence.in_erasure(p_uid) is not true then
    raise exception 'not_in_erasure_context' using errcode = 'QD012';
  end if;

  -- Retry/log preflight BEFORE ANY domain erasure. Same parent keys as ordinary I/U/D, all TRY.
  -- Freeze targeted parents and every subject-workset-linked child/parent, then read again under keys.
  -- Missing/conflicting bindings or a non-exclusive child of a targeted log block the ENTIRE purge;
  -- historical shared/conflicting disposition remains pending owner approval, never foreign-child deletion.
  for v_log_id in
    select l.id from public.notification_logs l
     where l.user_id = p_uid or (l.user_id is null and l.install_id_hash = any(account_fence.erasure_exclusive_installs()))
    union
    select q.notification_log_id from public.notification_retry_queue q
      left join public.notification_logs l on l.id = q.notification_log_id
     where l.user_id = p_uid or q.install_id_hash = any(account_fence.erasure_installs())
        or l.install_id_hash = any(account_fence.erasure_installs())
  loop
    if not pg_catalog.pg_try_advisory_xact_lock(pg_catalog.hashtextextended('qirsh.account_fence.notification_log:' || v_log_id::text, 0)) then
      perform account_fence.deny('busy');
    end if;
  end loop;
  if exists (select 1 from public.notification_retry_queue q
              left join public.notification_logs l on l.id = q.notification_log_id
             where (l.user_id = p_uid or q.install_id_hash = any(account_fence.erasure_installs())
                    or l.install_id_hash = any(account_fence.erasure_installs()))
               and (l.id is null or l.install_id_hash is null or q.install_id_hash is distinct from l.install_id_hash
                 or ((l.user_id = p_uid or (l.user_id is null and l.install_id_hash = any(account_fence.erasure_exclusive_installs())))
                     and (not (q.install_id_hash = any(account_fence.erasure_exclusive_installs()))
                       or not account_fence.holds_install_gate(q.install_id_hash, true))))) then
    raise exception 'retry_erasure_attribution_unproven'
      using errcode = 'QD013', detail = 'fence:retry_attribution', hint = 'owner_review_required_no_partial_erasure';
  end if;

  -- ── Referral / entitlement domain (0113:21-45) ───────────────────────────
  delete from public.referrals where referred_user_id = p_uid and status in ('attributed', 'rejected');
  update public.referrals set referred_user_id = null, referred_user_deleted_at = now() where referred_user_id = p_uid;
  delete from public.referral_reward_grants   where referrer_user_id = p_uid;
  delete from public.referral_reward_progress where referrer_user_id = p_uid;
  delete from public.referrals                where referrer_user_id = p_uid;
  delete from public.referral_codes           where user_id = p_uid;
  delete from public.user_entitlement_state   where user_id = p_uid;
  delete from public.entitlement_events       where user_id = p_uid;

  -- ── O5 (PENDING OWNER APPROVAL; DECISIONS.md lists every retained identifying field) ─────────────
  -- Actor rows get actor -> NULL and reason -> the fixed tombstone (no pattern redaction). The retained-field
  -- inventory (admin_users.note, before/after snapshots, target_ref, operation fingerprints, ...) is NOT changed
  -- here; each is an owner decision.
  update public.referral_admin_audit
     set target_user_id = null, target_ref = null, reason = '[redacted: subject account deleted]',
         before_state = null, after_state = null
   where target_user_id = p_uid;
  update public.referral_admin_audit
     set actor_admin_id = null, reason = account_fence.deletion_tombstone() where actor_admin_id = p_uid;
  update public.entitlement_events
     set actor_admin_id = null, reason = account_fence.deletion_tombstone() where actor_admin_id = p_uid;
  update public.referral_reward_rules set created_by = null where created_by = p_uid;
  update public.announcement_admin_audit
     set actor_admin_id = null, reason = account_fence.deletion_tombstone() where actor_admin_id = p_uid;
  -- feature_flag_admin_audit is append-only: this UPDATE passes only the narrow exception in
  -- public.feature_flag_audit_append_only (section 8); every other UPDATE/DELETE/TRUNCATE stays denied.
  update public.feature_flag_admin_audit
     set actor_admin_id = null, reason = account_fence.deletion_tombstone() where actor_admin_id = p_uid;

  -- ── Capture (0113:63-98) + O4 ────────────────────────────────────────────
  -- history first: a later device delete/update fires the history tracker, which must not see the subject.
  update public.capture_install_owner_history
     set first_owner_uid = null, transitioned = true,
         transitioned_at = coalesce(transitioned_at, clock_timestamp()), updated_at = clock_timestamp()
   where first_owner_uid = p_uid;
  -- O4/Q15 recommendation, PENDING OWNER APPROVAL: conflicting/shared rows are retained, not blanket deleted.
  -- Frozen exclusive evidence was captured before history/UUID minimisation and is never inferred from it.
  delete from public.processed_captures
   where install_id_hash = any(account_fence.erasure_exclusive_installs());
  update public.processed_captures
     set claimed_user_id = case when claimed_user_id = p_uid then null else claimed_user_id end,
         owner_uid = case when owner_uid = p_uid then null else owner_uid end,
         consent_owner_uid = case when consent_owner_uid = p_uid then null else consent_owner_uid end,
         consumed_by_install_hash = case when consumed_by_install_hash = any(account_fence.erasure_exclusive_installs())
                                        then null else consumed_by_install_hash end
   where p_uid = any(array[claimed_user_id, owner_uid, consent_owner_uid])
      or consumed_by_install_hash = any(account_fence.erasure_exclusive_installs());
  delete from public.capture_fingerprints where install_id_hash = any(account_fence.erasure_exclusive_installs());
  update public.capture_devices
     set consent_owner_uid = null, cloud_processing_enabled = false, ai_consent_granted = false,
         consent_version = 0, consent_client_generation = 0, last_revoke_generation = null
   where consent_owner_uid = p_uid and user_id is distinct from p_uid;
  -- E1.2 / O4: capture_devices. The parent DELETE cascades to processed_captures and capture_fingerprints
  -- (0012:25,50), so it is used ONLY for proven single-owner installs (erasure_exclusive_installs, computed under
  -- the exclusive install gates with an explicit "no row attributed to anyone else" test). Every other device of
  -- the subject is UNLINKED (the column set of unlink_capture_device, 0110:662-675): the row and all of its
  -- children stay for the other claimants; only the subject's link, consent and push token go.
  delete from public.capture_devices
   where user_id = p_uid and install_id_hash = any (account_fence.erasure_exclusive_installs());
  update public.capture_devices
     set owner_generation = owner_generation + 1, consent_client_generation = 0, last_revoke_generation = null,
         user_id = null, consent_owner_uid = null, cloud_processing_enabled = false, ai_consent_granted = false,
         consent_version = 0, apns_token = null, token_updated_at = null
   where user_id = p_uid and (consent_owner_uid is null or consent_owner_uid = p_uid);
  update public.capture_devices
     set owner_generation = owner_generation + 1, user_id = null, apns_token = null, token_updated_at = null
   where user_id = p_uid and consent_owner_uid is not null and consent_owner_uid <> p_uid;
  delete from public.capture_rate_limits where account_fence.rate_key_in_scope(install_id_hash);
  delete from public.ai_request_idempotency where account_fence.owner_key_in_scope(owner_key);
  delete from public.notification_retry_queue r
   where r.install_id_hash = any(account_fence.erasure_exclusive_installs())
     and account_fence.holds_install_gate(r.install_id_hash, true)
     and exists (select 1 from public.notification_logs l
       where l.id = r.notification_log_id and l.install_id_hash is not null and l.install_id_hash = r.install_id_hash
         and (l.user_id = p_uid or (l.user_id is null and l.install_id_hash = any(account_fence.erasure_exclusive_installs()))));
  delete from public.notification_logs
   where user_id = p_uid or (user_id is null and install_id_hash = any (account_fence.erasure_exclusive_installs()));

  -- ── Owner data (0113:100-125) ─────────────────────────────────────────────
  delete from public.user_bill_payments          where user_id = p_uid;
  delete from public.user_goal_contributions     where user_id = p_uid;
  delete from public.user_plan_transaction_links where user_id = p_uid;
  delete from public.user_subscriptions          where user_id = p_uid;
  delete from public.user_goals                  where user_id = p_uid;
  delete from public.user_plans                  where user_id = p_uid;
  delete from public.user_budgets                where user_id = p_uid;
  delete from public.user_transactions           where user_id = p_uid;
  delete from public.user_cards                  where user_id = p_uid;
  delete from public.user_accounts               where user_id = p_uid;
  delete from public.user_smart_inbox            where user_id = p_uid;
  delete from public.user_categories             where user_id = p_uid;
  delete from public.financial_import_runs       where user_id = p_uid;
  delete from public.user_settings               where user_id = p_uid;
  delete from public.user_achievements           where user_id = p_uid;
  delete from public.user_streaks                where user_id = p_uid;
  delete from public.user_xp_levels              where user_id = p_uid;
  delete from public.user_engagement_events      where user_id = p_uid;
  delete from public.metrics_rate_limits         where user_id = p_uid;
  delete from public.gamification_awarded_transactions where user_id = p_uid;
  delete from public.feature_flag_overrides      where user_id = p_uid;
  delete from public.sender_bank_mappings        where user_id = p_uid;
  delete from public.user_merchant_rules         where user_id = p_uid;  -- 20261116180000
  delete from public.backups                     where user_id = p_uid;
  delete from public.profiles                    where id      = p_uid;

  -- ── E1 closure: the sync-state anchor is DELETED, never upserted (0113:138-141 re-created it) ──
  delete from public.user_sync_state where user_id = p_uid;
  -- Admin membership of a deleted account (PROPOSED, PENDING OWNER APPROVAL, O5): the subject's membership row is
  -- removed (no Auth user can use it); rows naming the subject only as grantor lose granted_by. Their free-text
  -- `note` is NOT changed (owner decision, DECISIONS.md).
  update public.admin_users set granted_by = null where granted_by = p_uid;
  delete from public.admin_users where id = p_uid;
end;
$$;

create or replace function account_fence.erase_verify(p_uid uuid) returns void
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare v_tbl text;
begin
  if account_fence.in_erasure(p_uid) is not true then
    raise exception 'not_in_erasure_context' using errcode = 'QD012';
  end if;
  select s.tbl into v_tbl from (
    select 'user_accounts'::text as tbl where exists (select 1 from public.user_accounts where user_id = p_uid)
    union all select 'user_transactions'::text as tbl where exists (select 1 from public.user_transactions where user_id = p_uid)
    union all select 'user_budgets'::text as tbl where exists (select 1 from public.user_budgets where user_id = p_uid)
    union all select 'user_goals'::text as tbl where exists (select 1 from public.user_goals where user_id = p_uid)
    union all select 'user_goal_contributions'::text as tbl where exists (select 1 from public.user_goal_contributions where user_id = p_uid)
    union all select 'user_plans'::text as tbl where exists (select 1 from public.user_plans where user_id = p_uid)
    union all select 'user_plan_transaction_links'::text as tbl where exists (select 1 from public.user_plan_transaction_links where user_id = p_uid)
    union all select 'user_subscriptions'::text as tbl where exists (select 1 from public.user_subscriptions where user_id = p_uid)
    union all select 'user_bill_payments'::text as tbl where exists (select 1 from public.user_bill_payments where user_id = p_uid)
    union all select 'user_cards'::text as tbl where exists (select 1 from public.user_cards where user_id = p_uid)
    union all select 'user_categories'::text as tbl where exists (select 1 from public.user_categories where user_id = p_uid)
    union all select 'user_settings'::text as tbl where exists (select 1 from public.user_settings where user_id = p_uid)
    union all select 'user_smart_inbox'::text as tbl where exists (select 1 from public.user_smart_inbox where user_id = p_uid)
    union all select 'sender_bank_mappings'::text as tbl where exists (select 1 from public.sender_bank_mappings where user_id = p_uid)
    union all select 'user_merchant_rules'::text as tbl where exists (select 1 from public.user_merchant_rules where user_id = p_uid)
    union all select 'user_achievements'::text as tbl where exists (select 1 from public.user_achievements where user_id = p_uid)
    union all select 'user_streaks'::text as tbl where exists (select 1 from public.user_streaks where user_id = p_uid)
    union all select 'user_xp_levels'::text as tbl where exists (select 1 from public.user_xp_levels where user_id = p_uid)
    union all select 'user_sync_state'::text as tbl where exists (select 1 from public.user_sync_state where user_id = p_uid)
    union all select 'backups'::text as tbl where exists (select 1 from public.backups where user_id = p_uid)
    union all select 'feature_flag_overrides'::text as tbl where exists (select 1 from public.feature_flag_overrides where user_id = p_uid)
    union all select 'financial_import_runs'::text as tbl where exists (select 1 from public.financial_import_runs where user_id = p_uid)
    union all select 'user_engagement_events'::text as tbl where exists (select 1 from public.user_engagement_events where user_id = p_uid)
    union all select 'metrics_rate_limits'::text as tbl where exists (select 1 from public.metrics_rate_limits where user_id = p_uid)
    union all select 'gamification_awarded_transactions'::text as tbl where exists (select 1 from public.gamification_awarded_transactions where user_id = p_uid)
    union all select 'referral_codes'::text as tbl where exists (select 1 from public.referral_codes where user_id = p_uid)
    union all select 'user_entitlement_state'::text as tbl where exists (select 1 from public.user_entitlement_state where user_id = p_uid)
    union all select 'entitlement_events'::text as tbl where exists (select 1 from public.entitlement_events where user_id = p_uid)
    union all select 'notification_logs'::text as tbl where exists (select 1 from public.notification_logs where user_id = p_uid)
    union all select 'notification_retry_queue'::text as tbl where exists (
      select 1 from public.notification_retry_queue q left join public.notification_logs l on l.id = q.notification_log_id
       where l.user_id = p_uid or q.install_id_hash = any(account_fence.erasure_exclusive_installs())
          or l.install_id_hash = any(account_fence.erasure_exclusive_installs())
          or ((q.install_id_hash = any(account_fence.erasure_installs()) or l.install_id_hash = any(account_fence.erasure_installs()))
              and (l.id is null or l.install_id_hash is null or q.install_id_hash is distinct from l.install_id_hash)))
    union all select 'profiles'::text as tbl where exists (select 1 from public.profiles where id = p_uid)
    union all select 'referral_reward_grants'::text as tbl where exists (select 1 from public.referral_reward_grants where referrer_user_id = p_uid)
    union all select 'referral_reward_progress'::text as tbl where exists (select 1 from public.referral_reward_progress where referrer_user_id = p_uid)
    union all select 'referrals'::text as tbl where exists (select 1 from public.referrals where referrer_user_id = p_uid or referred_user_id = p_uid)
    union all select 'entitlement_events'::text as tbl where exists (select 1 from public.entitlement_events where actor_admin_id = p_uid)
    union all select 'referral_admin_audit'::text as tbl where exists (select 1 from public.referral_admin_audit where target_user_id = p_uid or actor_admin_id = p_uid)
    union all select 'referral_reward_rules'::text as tbl where exists (select 1 from public.referral_reward_rules where created_by = p_uid)
    union all select 'announcement_admin_audit'::text as tbl where exists (select 1 from public.announcement_admin_audit where actor_admin_id = p_uid)
    union all select 'feature_flag_admin_audit'::text as tbl where exists (select 1 from public.feature_flag_admin_audit where actor_admin_id = p_uid)
    union all select 'processed_captures'::text as tbl where exists (select 1 from public.processed_captures where p_uid = any(array[claimed_user_id, owner_uid, consent_owner_uid])
      or consumed_by_install_hash = any(account_fence.erasure_exclusive_installs())
      or install_id_hash = any(account_fence.erasure_exclusive_installs()))
    union all select 'capture_devices'::text as tbl where exists (select 1 from public.capture_devices where user_id = p_uid or consent_owner_uid = p_uid)
    union all select 'capture_install_owner_history'::text as tbl where exists (select 1 from public.capture_install_owner_history where first_owner_uid = p_uid)
    union all select 'admin_users'::text as tbl where exists (select 1 from public.admin_users where id = p_uid or granted_by = p_uid)
    union all select 'capture_rate_limits'::text as tbl where exists (select 1 from public.capture_rate_limits where account_fence.rate_key_in_scope(install_id_hash))
    union all select 'ai_request_idempotency'::text as tbl where exists (select 1 from public.ai_request_idempotency where account_fence.owner_key_in_scope(owner_key))
    union all select 'account_purge_queue'::text as tbl where account_fence.legacy_queue_has_uid(p_uid)
  ) s limit 1;
  if v_tbl is not null then
    raise exception 'erasure_closure_incomplete' using errcode = 'QD013', detail = 'fence:' || v_tbl;
  end if;
end;
$$;


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
    'merchant_rules_sync', true
  );
$$;

revoke all on function public.qirsh_server_capabilities() from public, anon;
grant execute on function public.qirsh_server_capabilities() to authenticated;

revoke account_fence_owner from current_user;

commit;
