-- Removes the withdrawal entry point. Contributions already withdrawn stay
-- withdrawn (they were the user's to remove).
BEGIN;
DROP FUNCTION IF EXISTS public.withdraw_merchant_category_contribution(UUID, TEXT);
COMMIT;
