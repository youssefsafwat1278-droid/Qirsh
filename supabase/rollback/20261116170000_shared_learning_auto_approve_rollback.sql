-- Removes auto-approval and revoke. Mappings already published stay in
-- merchant_keywords. Fails (by design) while an auto-approved review row
-- exists, because reviewed_by becomes NOT NULL again: delete or re-attribute
-- those rows first.
BEGIN;

DROP TRIGGER IF EXISTS trg_merchant_category_contributions_auto_approve
  ON public.merchant_category_contributions;
DROP FUNCTION IF EXISTS public.trg_merchant_category_auto_approval();
DROP FUNCTION IF EXISTS public.evaluate_merchant_category_auto_approval(TEXT);
DROP FUNCTION IF EXISTS public.admin_revoke_merchant_category_mapping(UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.admin_list_merchant_category_published(UUID);
DROP FUNCTION IF EXISTS public.merchant_category_auto_min_percent();
DROP FUNCTION IF EXISTS public.merchant_category_auto_min_users();

-- Restore the 20261116150000 manual review body (publish inlined).
CREATE OR REPLACE FUNCTION public.admin_review_merchant_category_candidate(
  p_actor                  UUID,
  p_merchant_key           TEXT,
  p_category_key           TEXT,
  p_decision               TEXT,
  p_published_category_key TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count INTEGER;
  v_final TEXT;
  v_kw_id UUID;
BEGIN
  IF p_actor IS NULL OR NOT EXISTS (SELECT 1 FROM public.admin_users a WHERE a.id = p_actor) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = 'P0403';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'decision_invalid' USING ERRCODE = 'P0422';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('merchant_category_review:' || coalesce(p_merchant_key, '')));
  IF EXISTS (SELECT 1 FROM public.merchant_category_reviews r
             WHERE r.merchant_key = p_merchant_key AND r.category_key = p_category_key) THEN
    RAISE EXCEPTION 'already_reviewed' USING ERRCODE = 'P0409';
  END IF;
  SELECT count(*)::INTEGER INTO v_count
  FROM public.merchant_category_contributions c
  WHERE c.merchant_key = p_merchant_key AND c.category_key = p_category_key;
  IF v_count < public.merchant_category_candidate_min_users() THEN
    RAISE EXCEPTION 'not_a_candidate' USING ERRCODE = 'P0409';
  END IF;
  IF p_decision = 'approved' THEN
    v_final := coalesce(nullif(btrim(p_published_category_key), ''), p_category_key);
    IF NOT public.merchant_contribution_category_ok(v_final) THEN
      RAISE EXCEPTION 'category_key_invalid' USING ERRCODE = 'P0422';
    END IF;
    SELECT k.id INTO v_kw_id
    FROM public.merchant_keywords k
    WHERE upper(k.keyword) = p_merchant_key AND k.country_code = 'ALL' AND NOT k.is_deleted
    ORDER BY k.updated_at DESC
    LIMIT 1
    FOR UPDATE;
    IF v_kw_id IS NULL THEN
      INSERT INTO public.merchant_keywords
        (keyword, category_key, language, country_code, priority, is_active, is_deleted, updated_at)
      VALUES (p_merchant_key, v_final, 'any', 'ALL', 0, TRUE, FALSE, now());
    ELSE
      UPDATE public.merchant_keywords
         SET category_key = v_final, is_active = TRUE, updated_at = now()
       WHERE id = v_kw_id;
    END IF;
  END IF;
  INSERT INTO public.merchant_category_reviews
    (merchant_key, category_key, decision, published_category_key, user_count_at_review, reviewed_by)
  VALUES (p_merchant_key, p_category_key, p_decision, v_final, v_count, p_actor);
  RETURN jsonb_build_object(
    'decision', p_decision,
    'published_category_key', v_final,
    'user_count', v_count
  );
END;
$$;
REVOKE ALL ON FUNCTION public.admin_review_merchant_category_candidate(UUID, TEXT, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_review_merchant_category_candidate(UUID, TEXT, TEXT, TEXT, TEXT)
  TO service_role;

DROP FUNCTION IF EXISTS public.merchant_category_publish(TEXT, TEXT);

ALTER TABLE public.merchant_category_reviews
  DROP CONSTRAINT IF EXISTS merchant_category_reviews_reviewer_shape;
ALTER TABLE public.merchant_category_reviews
  ALTER COLUMN reviewed_by SET NOT NULL;
ALTER TABLE public.merchant_category_reviews
  DROP COLUMN IF EXISTS auto_approved;

COMMIT;
