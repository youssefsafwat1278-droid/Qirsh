-- Removes shared category learning. Approved mappings already written to
-- merchant_keywords stay (they are ordinary catalog rows; deactivate them there
-- if needed). Contributions, reviews and the salt are dropped.
BEGIN;

DROP TRIGGER IF EXISTS on_auth_user_deleted_erase_merchant_contributions ON auth.users;
DROP FUNCTION IF EXISTS public.erase_merchant_category_contributions();
DROP FUNCTION IF EXISTS public.admin_review_merchant_category_candidate(UUID, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.admin_list_merchant_category_candidates(UUID);
DROP FUNCTION IF EXISTS public.submit_merchant_category_contribution(UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.merchant_contributor_hash(UUID);
DROP FUNCTION IF EXISTS public.merchant_contribution_category_ok(TEXT);
DROP FUNCTION IF EXISTS public.merchant_contribution_key_ok(TEXT);
DROP FUNCTION IF EXISTS public.merchant_category_candidate_min_users();
DROP TABLE IF EXISTS public.merchant_category_reviews;
DROP TABLE IF EXISTS public.merchant_category_contributions;
DROP TABLE IF EXISTS public.merchant_contribution_secret;

COMMIT;
