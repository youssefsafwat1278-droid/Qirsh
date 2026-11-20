-- Rolls back 20261120130000_sms_analysis_memory.sql: the shape memory, the
-- merchant memory and the daily counts. Roll process-ios-sms back first (or
-- not at all: a deployed function that finds none of these objects reads
-- "nothing known", calls Gemini for every message and skips every memory
-- write). The dropped tables hold no personal data.

begin;

drop function if exists public.sms_template_observe(text, text, text, jsonb, text, integer, integer);
drop function if exists public.sms_template_drop(text);
drop function if exists public.merchant_code_observe(text, text);
drop function if exists public.merchant_code_claim_lookup(text);
drop function if exists public.merchant_code_resolve(text, text);
drop function if exists public.bump_sms_analysis_daily(text);
drop table if exists public.sms_shape_templates;
drop table if exists public.merchant_code_memory;
drop table if exists public.sms_analysis_daily;

commit;
