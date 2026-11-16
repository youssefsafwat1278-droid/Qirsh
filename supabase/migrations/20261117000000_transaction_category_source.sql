-- Transaction category provenance (auto | rule | user | unknown).
--
-- Why a column and not a metadata key: every client write REPLACES
-- user_transactions.metadata wholesale, so a key added by a new app version is
-- silently dropped the next time an older version writes the row. A dedicated
-- column survives that, and this trigger keeps it honest:
--
--   * A value is accepted only from a write carrying a FRESH token
--     metadata.cs_op = {"n": nonce, "s": source, "c": category key} whose
--     nonce differs from the stored one AND whose "c" equals the row's
--     category_id. The value applied is the token's "s".
--   * Any other write (an older app, a server-side job, a stale echoed token)
--     that changes category_id or user_category_id records 'unknown'; one that
--     leaves the category alone keeps the stored value.
--   * Any other INSERT records 'unknown'.
--
-- 'unknown' is the conservative state: clients exclude it from bulk category
-- updates by default. Existing rows stay NULL (read as unknown) — nothing is
-- rewritten. Additive only; RLS, grants and every other trigger are untouched.

ALTER TABLE public.user_transactions
  ADD COLUMN IF NOT EXISTS category_source text
  CHECK (category_source IN ('auto', 'rule', 'user', 'unknown'));
-- File-import marker, separate from `source` (which keeps the original
-- bank/SMS/manual origin) and from category_source. Sticky: once true it is
-- never cleared by any write, so an older app version (which never sends it)
-- or a stale write cannot drop the protection. Imported rows are excluded
-- from bulk category updates unless the user explicitly opts in to them.
ALTER TABLE public.user_transactions
  ADD COLUMN IF NOT EXISTS imported_from_file boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.user_transactions.imported_from_file IS
  'Came in through a file import. Sticky (never cleared). Guarded by guard_transaction_category_source().';

COMMENT ON COLUMN public.user_transactions.category_source IS
  'Who chose the category: auto | rule | user | unknown. NULL = recorded before 20261117000000 (unknown). Guarded by guard_transaction_category_source().';

CREATE OR REPLACE FUNCTION public.guard_transaction_category_source()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_tok jsonb := CASE WHEN jsonb_typeof(NEW.metadata) = 'object'
                      THEN NEW.metadata -> 'cs_op' END;
  v_old_tok jsonb;
  v_trusted boolean;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    NEW.imported_from_file := OLD.imported_from_file
      OR coalesce(NEW.imported_from_file, false);
  ELSE
    NEW.imported_from_file := coalesce(NEW.imported_from_file, false);
  END IF;

  IF TG_OP = 'UPDATE' AND jsonb_typeof(OLD.metadata) = 'object' THEN
    v_old_tok := OLD.metadata -> 'cs_op';
  END IF;

  v_trusted := jsonb_typeof(v_tok) = 'object'
    AND coalesce(v_tok ->> 'n', '') <> ''
    AND (v_old_tok IS NULL OR (v_tok ->> 'n') IS DISTINCT FROM (v_old_tok ->> 'n'))
    AND (v_tok ->> 's') IN ('auto', 'rule', 'user', 'unknown')
    AND coalesce(v_tok ->> 'c', '') = coalesce(NEW.category_id, '');

  IF v_trusted THEN
    NEW.category_source := v_tok ->> 's';
  ELSIF TG_OP = 'INSERT' THEN
    NEW.category_source := 'unknown';
  ELSIF NEW.category_id IS DISTINCT FROM OLD.category_id
     OR NEW.user_category_id IS DISTINCT FROM OLD.user_category_id THEN
    NEW.category_source := 'unknown';
  ELSE
    NEW.category_source := OLD.category_source;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_transaction_category_source() FROM public, anon, authenticated;

DROP TRIGGER IF EXISTS trg_user_transactions_category_source ON public.user_transactions;
CREATE TRIGGER trg_user_transactions_category_source
  BEFORE INSERT OR UPDATE ON public.user_transactions
  FOR EACH ROW EXECUTE FUNCTION public.guard_transaction_category_source();

-- The CAS write path (sync RPC) may carry the column too; the trigger above
-- governs it exactly as it governs the PostgREST path.
CREATE OR REPLACE FUNCTION public.sync_family(
  p_table text,
  OUT id_col text,
  OUT write_cols text[],
  OUT insert_cols text[],
  OUT cmp_cols text[],
  OUT can_delete boolean
)
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
BEGIN
  insert_cols := '{}';
  can_delete := true;
  id_col := 'local_id';
  CASE p_table
    WHEN 'user_transactions' THEN
      id_col := 'client_request_id';
      write_cols := ARRAY['amount', 'currency', 'direction', 'transaction_type', 'source',
        'occurred_at', 'merchant', 'description', 'status', 'local_account_id',
        'server_account_id', 'category_id', 'user_category_id', 'confidence',
        'balance_after', 'foreign_amount', 'foreign_currency', 'metadata',
        'comparison_timestamp', 'comparison_timestamp_source', 'category_source',
        'imported_from_file'];
      cmp_cols := ARRAY['amount', 'currency', 'transaction_type', 'direction', 'status',
        'occurred_at', 'merchant', 'description', 'category_id', 'server_account_id',
        'foreign_amount', 'foreign_currency'];
    WHEN 'user_accounts' THEN
      write_cols := ARRAY['name', 'currency', 'type', 'initial_balance', 'current_balance',
        'sort_order', 'metadata', 'bank_account_number', 'credit_limit', 'available_credit',
        'payment_due_day', 'wallet_provider', 'exclude_from_totals'];
    WHEN 'user_budgets' THEN
      write_cols := ARRAY['local_account_id', 'server_account_id', 'category_id', 'amount',
        'period', 'start_date', 'is_active', 'show_on_header', 'metadata',
        'user_category_id', 'currency', 'alert_threshold_percent'];
    WHEN 'user_goals' THEN
      write_cols := ARRAY['local_account_id', 'server_account_id', 'name', 'target_amount',
        'deadline', 'vault_skin', 'status', 'auto_save_amount', 'auto_save_period',
        'auto_save_last_run', 'metadata', 'currency'];
      insert_cols := ARRAY['saved_amount'];
    WHEN 'user_plans' THEN
      write_cols := ARRAY['name', 'budget_amount', 'currency', 'start_date', 'end_date',
        'local_account_ids', 'card_last4s', 'status', 'icon', 'metadata', 'server_account_ids'];
    WHEN 'user_subscriptions' THEN
      write_cols := ARRAY['local_account_id', 'server_account_id', 'merchant_id', 'name',
        'amount', 'currency', 'type', 'frequency', 'next_due_date', 'reminder_on',
        'is_confirmed', 'custom_interval_days', 'note', 'status', 'total_installments',
        'manual_paid_amount', 'total_purchase_amount', 'lender_name', 'interest_rate',
        'metadata'];
      insert_cols := ARRAY['paid_count'];
    WHEN 'user_cards' THEN
      write_cols := ARRAY['local_account_id', 'nickname', 'last4', 'network', 'source',
        'color_theme', 'accent_hex'];
    WHEN 'user_categories' THEN
      write_cols := ARRAY['key', 'name_ar', 'icon', 'color', 'is_income', 'sort_order'];
      can_delete := false;
    ELSE
      RAISE EXCEPTION 'sync_unsupported_table' USING ERRCODE = '22023';
  END CASE;
  IF cmp_cols IS NULL THEN
    cmp_cols := array_remove(write_cols, 'metadata');
  END IF;
END;
$$;

-- Advertise both columns (one capability) so new clients start sending them. Every existing key is
-- kept verbatim (20261116210000).
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
    'profile_photo_backup', true,
    'transaction_category_source', true
  );
$$;

revoke all on function public.qirsh_server_capabilities() from public, anon;
grant execute on function public.qirsh_server_capabilities() to authenticated;
