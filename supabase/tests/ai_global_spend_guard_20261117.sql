-- SQL proof for 20261117120000_ai_global_spend_guard.
-- Run against a LOCAL Postgres ONLY (the dry-run scaffold with the chain
-- applied, or a local Supabase stack), inside BEGIN ... ROLLBACK.

CREATE TEMP TABLE _c (name text, ok boolean, detail text);

UPDATE public.ai_global_budget SET daily_limit = 3, enabled = true WHERE bucket = 'gemini';
DELETE FROM public.ai_global_spend WHERE bucket = 'gemini';

CREATE TEMP TABLE _r AS
SELECT n, public.consume_ai_global_budget('gemini') AS r FROM generate_series(1, 5) AS n ORDER BY n;

INSERT INTO _c SELECT 'the first three calls are allowed',
  (SELECT bool_and((r->>'allowed')::boolean) FROM _r WHERE n <= 3), (SELECT string_agg(r::text, ' ') FROM _r WHERE n <= 3);
INSERT INTO _c SELECT 'calls past the ceiling are refused with reason ceiling',
  (SELECT bool_and(NOT (r->>'allowed')::boolean AND r->>'reason' = 'ceiling') FROM _r WHERE n > 3), (SELECT string_agg(r::text, ' ') FROM _r WHERE n > 3);
INSERT INTO _c SELECT 'the counter never exceeds the ceiling and counts refusals',
  (SELECT calls = 3 AND denied = 2 FROM public.ai_global_spend WHERE bucket = 'gemini' AND day = (now() at time zone 'utc')::date),
  (SELECT calls || '/' || denied FROM public.ai_global_spend WHERE bucket = 'gemini');

UPDATE public.ai_global_budget SET daily_limit = 100, enabled = false WHERE bucket = 'gemini';
INSERT INTO _c SELECT 'a disabled bucket refuses (server-side kill switch)',
  (SELECT r->>'reason' = 'disabled' AND NOT (r->>'allowed')::boolean FROM (SELECT public.consume_ai_global_budget('gemini') r) x), '';

INSERT INTO _c SELECT 'an unknown bucket refuses',
  (SELECT r->>'reason' = 'unknown_bucket' FROM (SELECT public.consume_ai_global_budget('no_such_bucket') r) x), '';

UPDATE public.ai_global_budget SET daily_limit = 5, enabled = true WHERE bucket = 'places';
DELETE FROM public.ai_global_spend WHERE bucket = 'places';
INSERT INTO _c SELECT 'a reservation larger than the remaining budget is refused whole',
  (SELECT (a->>'allowed')::boolean AND NOT (b->>'allowed')::boolean AND (c->>'allowed')::boolean
   FROM (SELECT public.consume_ai_global_budget('places', 4) a) x,
        LATERAL (SELECT public.consume_ai_global_budget('places', 2) b) y,
        LATERAL (SELECT public.consume_ai_global_budget('places', 1) c) z), '';

DO $$ BEGIN
  PERFORM public.consume_ai_global_budget('places', 0);
  INSERT INTO _c VALUES ('p_units = 0 is rejected', false, 'no error');
EXCEPTION WHEN invalid_parameter_value THEN
  INSERT INTO _c VALUES ('p_units = 0 is rejected', true, '');
END $$;

INSERT INTO _c SELECT 'client roles cannot call or read the guard',
  NOT has_function_privilege('anon', 'public.consume_ai_global_budget(text, integer)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.consume_ai_global_budget(text, integer)', 'EXECUTE')
  AND NOT has_table_privilege('anon', 'public.ai_global_spend', 'SELECT')
  AND NOT has_table_privilege('authenticated', 'public.ai_global_budget', 'UPDATE')
  AND has_function_privilege('service_role', 'public.consume_ai_global_budget(text, integer)', 'EXECUTE'), '';

INSERT INTO _c SELECT 'seeded buckets exist', (SELECT count(*) = 2 FROM public.ai_global_budget WHERE bucket IN ('gemini', 'places')), '';

SELECT name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM _c ORDER BY ok, name;
SELECT CASE WHEN bool_and(ok) THEN 'pass' ELSE 'fail' END AS proof,
       count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _c;
