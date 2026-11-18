-- Removes the project-wide AI ceiling (20261117120000). Deploy function code
-- that no longer calls consume_ai_global_budget FIRST: a guard that cannot
-- reach this function fails closed and sends every AI-eligible item to review.
-- The counters hold no personal data; dropping them loses only usage history.
BEGIN;
DROP FUNCTION IF EXISTS public.consume_ai_global_budget(text, integer);
DROP TABLE IF EXISTS public.ai_global_spend;
DROP TABLE IF EXISTS public.ai_global_budget;
COMMIT;
