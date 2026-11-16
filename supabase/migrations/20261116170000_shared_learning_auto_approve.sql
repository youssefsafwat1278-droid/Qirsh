-- Shared category learning: auto-approval and revoke.
--
-- OWNER RULE: "if more than 5 users make the same choice, approve it".
-- A (merchant_key, category_key) pair is published WITHOUT an admin when
--   * at least merchant_category_auto_min_users() (6) distinct contributors
--     chose that category for that merchant, AND
--   * that category holds at least merchant_category_auto_min_percent() (75%)
--     of all distinct contributors for that merchant,
-- and none of these is true:
--   * the pair was already reviewed (approved -> nothing to do; rejected or
--     revoked -> never auto-approved),
--   * the merchant already has an approved mapping to another category,
--   * the shared catalog already holds an active global keyword for this
--     merchant with a different category (an admin-curated or enrichment row
--     is never replaced automatically).
-- Anything else at or above the candidate threshold (5) stays a manual
-- candidate exactly as before.
--
-- Evaluation runs from a trigger on every contribution write, so there is no
-- cron. It is idempotent: the review row it writes makes a second evaluation a
-- no-op, and a per-merchant advisory lock serialises concurrent writers.
--
-- Publishing is shared with manual approval (merchant_category_publish), so
-- both write merchant_keywords the same way and bump the catalog version
-- through the 0093 trigger. An auto-approval is recorded with
-- auto_approved = true and reviewed_by NULL.
--
-- REVOKE (manual or auto approval): soft-deletes the merchant_keywords row
-- (is_active = false, is_deleted = true, so catalog-delta sends its id in
-- deletedIds and devices drop it; version bumps) and turns the review into
-- 'rejected', so the pair never auto-approves again.

BEGIN;

-- ── Thresholds ──────────────────────────────────────────────────────────────
-- Next to merchant_category_candidate_min_users() (5) from 20261116150000.
CREATE OR REPLACE FUNCTION public.merchant_category_auto_min_users()
RETURNS INTEGER LANGUAGE sql IMMUTABLE AS $$ SELECT 6 $$;

CREATE OR REPLACE FUNCTION public.merchant_category_auto_min_percent()
RETURNS INTEGER LANGUAGE sql IMMUTABLE AS $$ SELECT 75 $$;

-- ── Reviews: who decided ────────────────────────────────────────────────────
ALTER TABLE public.merchant_category_reviews
  ADD COLUMN IF NOT EXISTS auto_approved BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.merchant_category_reviews
  ALTER COLUMN reviewed_by DROP NOT NULL;
ALTER TABLE public.merchant_category_reviews
  ADD CONSTRAINT merchant_category_reviews_reviewer_shape
  CHECK (reviewed_by IS NOT NULL OR (auto_approved AND decision = 'approved'));

-- ── The one publish path (manual and auto) ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.merchant_category_publish(p_merchant_key TEXT, p_category_key TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_kw_id UUID;
BEGIN
  SELECT k.id INTO v_kw_id
  FROM public.merchant_keywords k
  WHERE upper(k.keyword) = p_merchant_key AND k.country_code = 'ALL' AND NOT k.is_deleted
  ORDER BY k.updated_at DESC
  LIMIT 1
  FOR UPDATE;
  IF v_kw_id IS NULL THEN
    INSERT INTO public.merchant_keywords
      (keyword, category_key, language, country_code, priority, is_active, is_deleted, updated_at)
    VALUES (p_merchant_key, p_category_key, 'any', 'ALL', 0, TRUE, FALSE, now());
  ELSE
    UPDATE public.merchant_keywords
       SET category_key = p_category_key, is_active = TRUE, updated_at = now()
     WHERE id = v_kw_id;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.merchant_category_publish(TEXT, TEXT)
  FROM PUBLIC, anon, authenticated, service_role;

-- Manual approval, unchanged in behaviour, now through the shared publish.
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
    PERFORM public.merchant_category_publish(p_merchant_key, v_final);
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

-- ── Auto evaluation ─────────────────────────────────────────────────────────
-- Returns the published category, or NULL when nothing was auto-approved.
CREATE OR REPLACE FUNCTION public.evaluate_merchant_category_auto_approval(p_merchant_key TEXT)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_total    INTEGER;
  v_category TEXT;
  v_count    INTEGER;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('merchant_category_review:' || coalesce(p_merchant_key, '')));

  SELECT count(*)::INTEGER INTO v_total
  FROM public.merchant_category_contributions c
  WHERE c.merchant_key = p_merchant_key;

  SELECT c.category_key, count(*)::INTEGER INTO v_category, v_count
  FROM public.merchant_category_contributions c
  WHERE c.merchant_key = p_merchant_key
  GROUP BY c.category_key
  ORDER BY count(*) DESC, c.category_key
  LIMIT 1;

  IF v_category IS NULL
     OR v_count < public.merchant_category_auto_min_users()
     OR v_count * 100 < v_total * public.merchant_category_auto_min_percent()
     OR NOT public.merchant_contribution_category_ok(v_category)
     -- reviewed before: approved (idempotent), rejected or revoked (never)
     OR EXISTS (SELECT 1 FROM public.merchant_category_reviews r
                WHERE r.merchant_key = p_merchant_key AND r.category_key = v_category)
     -- an approved mapping to another category stays the admin's call
     OR EXISTS (SELECT 1 FROM public.merchant_category_reviews r
                WHERE r.merchant_key = p_merchant_key AND r.decision = 'approved')
     -- never auto-replace an existing catalog keyword with another category
     OR EXISTS (SELECT 1 FROM public.merchant_keywords k
                WHERE upper(k.keyword) = p_merchant_key AND k.country_code = 'ALL'
                  AND k.is_active AND NOT k.is_deleted AND k.category_key <> v_category)
  THEN
    RETURN NULL;
  END IF;

  PERFORM public.merchant_category_publish(p_merchant_key, v_category);
  INSERT INTO public.merchant_category_reviews
    (merchant_key, category_key, decision, published_category_key,
     user_count_at_review, reviewed_by, auto_approved)
  VALUES (p_merchant_key, v_category, 'approved', v_category, v_count, NULL, TRUE);
  RETURN v_category;
END;
$$;
REVOKE ALL ON FUNCTION public.evaluate_merchant_category_auto_approval(TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evaluate_merchant_category_auto_approval(TEXT) TO service_role;

CREATE OR REPLACE FUNCTION public.trg_merchant_category_auto_approval()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.evaluate_merchant_category_auto_approval(NEW.merchant_key);
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.trg_merchant_category_auto_approval() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_merchant_category_contributions_auto_approve
  ON public.merchant_category_contributions;
CREATE TRIGGER trg_merchant_category_contributions_auto_approve
  AFTER INSERT OR UPDATE ON public.merchant_category_contributions
  FOR EACH ROW EXECUTE FUNCTION public.trg_merchant_category_auto_approval();

-- ── Admin: published mappings (manual and auto) ─────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_list_merchant_category_published(p_actor UUID)
RETURNS TABLE (
  merchant_key           TEXT,
  category_key           TEXT,
  published_category_key TEXT,
  auto_approved          BOOLEAN,
  user_count_at_review   INTEGER,
  reviewed_at            TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_actor IS NULL OR NOT EXISTS (SELECT 1 FROM public.admin_users a WHERE a.id = p_actor) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = 'P0403';
  END IF;
  RETURN QUERY
  SELECT r.merchant_key, r.category_key, r.published_category_key, r.auto_approved,
         r.user_count_at_review, r.reviewed_at
  FROM public.merchant_category_reviews r
  WHERE r.decision = 'approved'
  ORDER BY r.reviewed_at DESC, r.merchant_key;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_list_merchant_category_published(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_merchant_category_published(UUID) TO service_role;

-- ── Admin: revoke an approved mapping (manual or auto) ──────────────────────
-- Errors: P0403 not an admin, P0409 not an approved mapping.
CREATE OR REPLACE FUNCTION public.admin_revoke_merchant_category_mapping(
  p_actor        UUID,
  p_merchant_key TEXT,
  p_category_key TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_published TEXT;
  v_auto      BOOLEAN;
BEGIN
  IF p_actor IS NULL OR NOT EXISTS (SELECT 1 FROM public.admin_users a WHERE a.id = p_actor) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = 'P0403';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('merchant_category_review:' || coalesce(p_merchant_key, '')));

  SELECT r.published_category_key, r.auto_approved INTO v_published, v_auto
  FROM public.merchant_category_reviews r
  WHERE r.merchant_key = p_merchant_key AND r.category_key = p_category_key
    AND r.decision = 'approved'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_published' USING ERRCODE = 'P0409';
  END IF;

  UPDATE public.merchant_keywords
     SET is_active = FALSE, is_deleted = TRUE, updated_at = now()
   WHERE upper(keyword) = p_merchant_key AND country_code = 'ALL'
     AND category_key = v_published AND NOT is_deleted;

  UPDATE public.merchant_category_reviews
     SET decision = 'rejected', published_category_key = NULL,
         reviewed_by = p_actor, reviewed_at = now()
   WHERE merchant_key = p_merchant_key AND category_key = p_category_key;

  RETURN jsonb_build_object('revoked', v_published, 'was_auto_approved', v_auto);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_revoke_merchant_category_mapping(UUID, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_revoke_merchant_category_mapping(UUID, TEXT, TEXT) TO service_role;

COMMIT;
