-- SQL proof for 20261117000000_transaction_category_source.
-- Run against a LOCAL Postgres ONLY, inside BEGIN ... ROLLBACK.
-- Writes run as an ordinary authenticated user (the PostgREST path).

CREATE TEMP TABLE _c (name text, ok boolean, detail text);
GRANT ALL ON _c TO authenticated;
CREATE OR REPLACE FUNCTION pg_temp.src(r text) RETURNS text LANGUAGE sql AS $$
  SELECT category_source FROM public.user_transactions WHERE client_request_id = r
$$;
GRANT EXECUTE ON FUNCTION pg_temp.src(text) TO authenticated;
CREATE OR REPLACE FUNCTION pg_temp.tok(n text, s text, c text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('transaction_source', 'sms', 'cs_op',
                            jsonb_build_object('n', n, 's', s, 'c', c))
$$;
GRANT EXECUTE ON FUNCTION pg_temp.tok(text,text,text) TO authenticated;

INSERT INTO auth.users (id) VALUES ('00000000-0000-0000-0000-00000000c517');
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000c517","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

-- Inserts
INSERT INTO public.user_transactions (user_id, amount, currency, occurred_at, source, category_id, client_request_id, metadata)
VALUES ('00000000-0000-0000-0000-00000000c517', 10, 'EGP', '2026-11-01', 'ios_shortcut', 'groceries', 'cs-plain', '{"transaction_source":"sms"}');
INSERT INTO _c SELECT 'an insert without a token is unknown', pg_temp.src('cs-plain') = 'unknown', pg_temp.src('cs-plain');

INSERT INTO public.user_transactions (user_id, amount, currency, occurred_at, source, category_id, client_request_id, metadata, category_source)
VALUES ('00000000-0000-0000-0000-00000000c517', 10, 'EGP', '2026-11-01', 'ios_shortcut', 'groceries', 'cs-forged', '{}', 'user');
INSERT INTO _c SELECT 'a bare column value without a token is not trusted', pg_temp.src('cs-forged') = 'unknown', pg_temp.src('cs-forged');

INSERT INTO public.user_transactions (user_id, amount, currency, occurred_at, source, category_id, client_request_id, metadata, category_source)
VALUES ('00000000-0000-0000-0000-00000000c517', 10, 'EGP', '2026-11-01', 'ios_shortcut', 'groceries', 'cs-tok', pg_temp.tok('n1', 'rule', 'groceries'), 'rule');
INSERT INTO _c SELECT 'an insert with a matching token takes its value', pg_temp.src('cs-tok') = 'rule', pg_temp.src('cs-tok');

INSERT INTO public.user_transactions (user_id, amount, currency, occurred_at, source, category_id, client_request_id, metadata)
VALUES ('00000000-0000-0000-0000-00000000c517', 10, 'EGP', '2026-11-01', 'ios_shortcut', 'cafes', 'cs-mismatch', pg_temp.tok('n2', 'user', 'groceries'));
INSERT INTO _c SELECT 'a token minted for another category is not trusted', pg_temp.src('cs-mismatch') = 'unknown', pg_temp.src('cs-mismatch');

INSERT INTO public.user_transactions (user_id, amount, currency, occurred_at, source, category_id, client_request_id, metadata)
VALUES ('00000000-0000-0000-0000-00000000c517', 10, 'EGP', '2026-11-01', 'ios_shortcut', 'groceries', 'cs-bogus', pg_temp.tok('n3', 'bogus', 'groceries'));
INSERT INTO _c SELECT 'a token with an invalid value is not trusted', pg_temp.src('cs-bogus') = 'unknown', pg_temp.src('cs-bogus');

-- Updates
UPDATE public.user_transactions SET metadata = pg_temp.tok('u1', 'user', 'cafes'), category_id = 'cafes'
 WHERE client_request_id = 'cs-tok';
INSERT INTO _c SELECT 'a fresh token records a user choice', pg_temp.src('cs-tok') = 'user', pg_temp.src('cs-tok');

UPDATE public.user_transactions SET description = 'a note', metadata = '{"transaction_source":"sms"}'
 WHERE client_request_id = 'cs-tok';
INSERT INTO _c SELECT 'an older app editing a note (metadata replaced, no token) keeps the value', pg_temp.src('cs-tok') = 'user', pg_temp.src('cs-tok');

UPDATE public.user_transactions SET amount = 12 WHERE client_request_id = 'cs-tok';
INSERT INTO _c SELECT 'an amount edit keeps the value', pg_temp.src('cs-tok') = 'user', pg_temp.src('cs-tok');

UPDATE public.user_transactions SET category_source = 'auto' WHERE client_request_id = 'cs-tok';
INSERT INTO _c SELECT 'setting the column alone cannot overwrite it', pg_temp.src('cs-tok') = 'user', pg_temp.src('cs-tok');

UPDATE public.user_transactions SET category_id = 'travel' WHERE client_request_id = 'cs-tok';
INSERT INTO _c SELECT 'a category change without a token becomes unknown', pg_temp.src('cs-tok') = 'unknown', pg_temp.src('cs-tok');

UPDATE public.user_transactions SET metadata = pg_temp.tok('u2', 'user', 'travel') WHERE client_request_id = 'cs-tok';
INSERT INTO _c SELECT 'a fresh matching token restores a known value', pg_temp.src('cs-tok') = 'user', pg_temp.src('cs-tok');

UPDATE public.user_transactions SET category_id = 'cafes' WHERE client_request_id = 'cs-tok';
INSERT INTO _c SELECT 'the same token kept while the category changes becomes unknown', pg_temp.src('cs-tok') = 'unknown', pg_temp.src('cs-tok');

UPDATE public.user_transactions SET metadata = pg_temp.tok('u3', 'rule', 'cafes') WHERE client_request_id = 'cs-tok';
UPDATE public.user_transactions SET metadata = pg_temp.tok('u1', 'user', 'cafes'), category_id = 'restaurants'
 WHERE client_request_id = 'cs-tok';
INSERT INTO _c SELECT 'a stale echoed token cannot vouch for a different category', pg_temp.src('cs-tok') = 'unknown', pg_temp.src('cs-tok');

UPDATE public.user_transactions SET metadata = pg_temp.tok('u4', 'auto', 'restaurants') WHERE client_request_id = 'cs-tok';
INSERT INTO public.user_categories (id, user_id, key, name_ar, icon, color)
VALUES ('00000000-0000-0000-0000-0000000c5c01', '00000000-0000-0000-0000-00000000c517', 'custom_cs', 'تجربة', 'tag', '#888888');
UPDATE public.user_transactions SET user_category_id = '00000000-0000-0000-0000-0000000c5c01' WHERE client_request_id = 'cs-tok';
INSERT INTO _c SELECT 'a custom-category change without a token becomes unknown', pg_temp.src('cs-tok') = 'unknown', pg_temp.src('cs-tok');

-- File-import marker: separate from source, sticky
INSERT INTO public.user_transactions (user_id, amount, currency, occurred_at, source, category_id, client_request_id, metadata, imported_from_file)
VALUES ('00000000-0000-0000-0000-00000000c517', 10, 'EGP', '2026-11-01', 'ios_shortcut', 'groceries', 'cs-imp', '{}', true);
INSERT INTO _c SELECT 'an imported row keeps its original source and is marked imported',
  (SELECT imported_from_file AND source = 'ios_shortcut' FROM public.user_transactions WHERE client_request_id = 'cs-imp'), '';
UPDATE public.user_transactions SET imported_from_file = false, description = 'x' WHERE client_request_id = 'cs-imp';
INSERT INTO _c SELECT 'the import marker cannot be cleared',
  (SELECT imported_from_file FROM public.user_transactions WHERE client_request_id = 'cs-imp'), '';
UPDATE public.user_transactions SET metadata = pg_temp.tok('i1', 'rule', 'cafes'), category_id = 'cafes' WHERE client_request_id = 'cs-imp';
INSERT INTO _c SELECT 'an older-style write without the marker keeps it',
  (SELECT imported_from_file FROM public.user_transactions WHERE client_request_id = 'cs-imp'), '';
INSERT INTO _c SELECT 'rows default to not imported',
  NOT (SELECT imported_from_file FROM public.user_transactions WHERE client_request_id = 'cs-plain'), '';
UPDATE public.user_transactions SET imported_from_file = true WHERE client_request_id = 'cs-plain';
INSERT INTO _c SELECT 'a row can be marked imported later',
  (SELECT imported_from_file FROM public.user_transactions WHERE client_request_id = 'cs-plain'), '';

RESET ROLE;

-- Contract
INSERT INTO _c SELECT 'sync_family carries category_source alongside every earlier column',
  (SELECT write_cols FROM public.sync_family('user_transactions')) @>
  ARRAY['amount','currency','direction','transaction_type','source','occurred_at','merchant',
        'description','status','local_account_id','server_account_id','category_id',
        'user_category_id','confidence','balance_after','foreign_amount','foreign_currency',
        'metadata','comparison_timestamp','comparison_timestamp_source','category_source',
        'imported_from_file'], '';
INSERT INTO _c SELECT 'capabilities keep every earlier key and add transaction_category_source',
  public.qirsh_server_capabilities() = jsonb_build_object(
    'awaiting_fx_transactions', true, 'capture_contract_v2', false, 'sync_seq', false,
    'revision_cas', false, 'replica_epoch', false, 'min_supported_seq', false,
    'min_client_build', false, 'merchant_rules_sync', true, 'profile_photo_backup', true,
    'transaction_category_source', true), public.qirsh_server_capabilities()::text;
INSERT INTO _c SELECT 'anon cannot read capabilities; authenticated can',
  NOT has_function_privilege('anon', 'public.qirsh_server_capabilities()', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.qirsh_server_capabilities()', 'EXECUTE'), '';

SELECT name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM _c ORDER BY ok, name;
SELECT CASE WHEN bool_and(ok) THEN 'pass' ELSE 'fail' END AS proof,
       count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _c;
