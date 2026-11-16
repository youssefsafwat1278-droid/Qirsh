-- Shared category learning: deleting a learned rule withdraws its vote.
--
-- Before this, a user who deleted a "Remember for this merchant" rule kept
-- counting towards that merchant→category pair forever. The device now asks
-- the merchant-category-contribution function to withdraw when a rule is
-- deleted; this removes that user's one row for the merchant (whatever
-- category it was). Nothing else changes:
--   * a pair already published stays published — the admin revokes it if the
--     remaining agreement no longer justifies it (auto-approval only fires on
--     INSERT/UPDATE, so a withdrawal never publishes anything);
--   * withdrawing a vote that does not exist is a no-op (returns false), so
--     the device can ask without knowing whether it ever contributed.
-- Reversible: rollback/20261116220000_shared_contribution_withdraw_rollback.sql.
BEGIN;

CREATE OR REPLACE FUNCTION public.withdraw_merchant_category_contribution(
  p_user_id      UUID,
  p_merchant_key TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_hash TEXT;
  v_n    INTEGER;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_required' USING ERRCODE = 'P0422';
  END IF;
  IF NOT public.merchant_contribution_key_ok(p_merchant_key) THEN
    RAISE EXCEPTION 'merchant_key_invalid' USING ERRCODE = 'P0422';
  END IF;
  v_hash := public.merchant_contributor_hash(p_user_id);
  IF v_hash IS NULL THEN
    RAISE EXCEPTION 'contribution_secret_missing' USING ERRCODE = 'P0500';
  END IF;
  DELETE FROM public.merchant_category_contributions
   WHERE merchant_key = p_merchant_key AND contributor_hash = v_hash;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END;
$$;
REVOKE ALL ON FUNCTION public.withdraw_merchant_category_contribution(UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.withdraw_merchant_category_contribution(UUID, TEXT)
  TO service_role;

COMMIT;
