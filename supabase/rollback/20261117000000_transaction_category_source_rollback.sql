-- Rollback for 20261117000000_transaction_category_source.sql.
-- Restores sync_family (20261110044549) and qirsh_server_capabilities
-- (20261116210000) exactly, then drops the trigger, function and column.
-- Dropping the column discards server-side provenance; clients then read
-- every row as unknown (the safe default) and stop sending it once the
-- capability disappears.

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
        'comparison_timestamp', 'comparison_timestamp_source'];
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

DROP TRIGGER IF EXISTS trg_user_transactions_category_source ON public.user_transactions;
DROP FUNCTION IF EXISTS public.guard_transaction_category_source();
ALTER TABLE public.user_transactions DROP COLUMN IF EXISTS category_source;
ALTER TABLE public.user_transactions DROP COLUMN IF EXISTS imported_from_file;
