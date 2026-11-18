-- Removes the project-wide AI ceiling (20261117120000). The deployed callers
-- (_shared/ai_budget_gate.ts) treat a MISSING function (PGRST202 / 42883) as
-- "guard absent" and call the provider anyway: running this file while they
-- are deployed causes no outage but REMOVES THE CEILING silently. To keep a
-- ceiling, use `update public.ai_global_budget set daily_limit = …` instead of
-- rolling back; roll back only together with redeploying the previous
-- function versions (functions first, then this file).
-- The counters hold no personal data; dropping them loses only usage history.
BEGIN;
DROP FUNCTION IF EXISTS public.consume_ai_global_budget(text, integer);
DROP TABLE IF EXISTS public.ai_global_spend;
DROP TABLE IF EXISTS public.ai_global_budget;
COMMIT;
