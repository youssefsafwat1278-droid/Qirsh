-- Cross-user category learning (shared learning).
--
-- A signed-in user with BOTH Cloud and AI consent who taps "Remember for this
-- merchant" contributes ONE pair: a normalised merchant key and a category key.
-- Nothing else reaches this schema: no amount, date, message, account, card,
-- free text, device or install id.
--
-- DE-DUPLICATION
-- Each user counts once per merchant. The row key is (merchant_key,
-- contributor_hash) where contributor_hash = HMAC-SHA256(user id, server salt).
-- A repeat contribution from the same user overwrites their earlier category
-- for that merchant; it never adds a second vote. The salt lives in a table no
-- API role can read (not even service_role), so the hash cannot be reversed or
-- recomputed through PostgREST. Someone with database-owner access CAN recompute
-- the hash for a known user id and see which merchant/category pairs that user
-- contributed; that is the residual link de-duplication needs. No timestamps
-- are stored per contribution.
--
-- REVIEW
-- A (merchant, category) pair with at least merchant_category_candidate_min_users()
-- distinct users is a CANDIDATE shown to admins. That number is a starting
-- threshold for review, not a privacy guarantee and not publication: nothing
-- reaches devices until an admin approves it. Approval writes the mapping into
-- merchant_keywords (the shared catalog devices already pull through
-- catalog-delta; its version trigger from 0093 bumps the catalog). A rejected
-- pair is remembered and not shown again.
--
-- ERASURE
-- Deleting the auth user deletes that user's contributions (trigger below).

BEGIN;

-- ── Salt for contributor pseudonyms ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.merchant_contribution_secret (
  id   BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
  salt BYTEA NOT NULL CHECK (octet_length(salt) >= 32)
);
INSERT INTO public.merchant_contribution_secret (id, salt)
VALUES (TRUE, extensions.gen_random_bytes(32))
ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.merchant_contribution_secret ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.merchant_contribution_secret
  FROM PUBLIC, anon, authenticated, service_role;

-- ── Contributions: one row per (merchant, user) ────────────────────────────
CREATE TABLE IF NOT EXISTS public.merchant_category_contributions (
  merchant_key     TEXT NOT NULL,
  contributor_hash TEXT NOT NULL CHECK (contributor_hash ~ '^[0-9a-f]{64}$'),
  category_key     TEXT NOT NULL,
  PRIMARY KEY (merchant_key, contributor_hash)
);
CREATE INDEX IF NOT EXISTS idx_merchant_category_contributions_pair
  ON public.merchant_category_contributions (merchant_key, category_key);
ALTER TABLE public.merchant_category_contributions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.merchant_category_contributions
  FROM PUBLIC, anon, authenticated, service_role;

-- ── Admin decisions ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.merchant_category_reviews (
  merchant_key           TEXT NOT NULL,
  category_key           TEXT NOT NULL,
  decision               TEXT NOT NULL CHECK (decision IN ('approved', 'rejected')),
  published_category_key TEXT NULL,
  user_count_at_review   INTEGER NOT NULL,
  reviewed_by            UUID NOT NULL,
  reviewed_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (merchant_key, category_key),
  CHECK ((decision = 'approved') = (published_category_key IS NOT NULL))
);
ALTER TABLE public.merchant_category_reviews ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.merchant_category_reviews
  FROM PUBLIC, anon, authenticated, service_role;

-- ── Helpers ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.merchant_category_candidate_min_users()
RETURNS INTEGER LANGUAGE sql IMMUTABLE AS $$ SELECT 5 $$;

-- The device normalises with TransactionDedup.normalizeMerchant (upper-case,
-- digits stripped, spaces collapsed). Anything still carrying a digit of any
-- script is an identifier, not a business name.
CREATE OR REPLACE FUNCTION public.merchant_contribution_key_ok(p_key TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
  SELECT p_key IS NOT NULL
     AND char_length(p_key) BETWEEN 3 AND 64
     AND p_key = upper(p_key)
     AND p_key = btrim(regexp_replace(p_key, '\s+', ' ', 'g'))
     AND p_key !~ '[0-9٠-٩۰-۹@]'
     AND p_key ~ '[[:alpha:]]'
$$;

-- Only real, active spending categories. People-shaped and catch-all keys
-- (transfers, income, cash, other) are never learned from users.
CREATE OR REPLACE FUNCTION public.merchant_contribution_category_ok(p_key TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
  SELECT p_key IS NOT NULL
     AND p_key NOT IN ('transfers', 'income', 'cash', 'other', 'all_expenses')
     AND EXISTS (SELECT 1 FROM public.categories c
                 WHERE c.key = p_key AND c.is_active AND NOT c.is_deleted)
$$;
REVOKE ALL ON FUNCTION public.merchant_contribution_category_ok(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.merchant_contribution_category_ok(TEXT) TO service_role;

CREATE OR REPLACE FUNCTION public.merchant_contributor_hash(p_user_id UUID)
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
  SELECT encode(extensions.hmac(convert_to(p_user_id::text, 'UTF8'), s.salt, 'sha256'), 'hex')
  FROM public.merchant_contribution_secret s
  WHERE s.id
$$;
REVOKE ALL ON FUNCTION public.merchant_contributor_hash(UUID) FROM PUBLIC, anon, authenticated, service_role;

-- ── Ingress (Edge Function merchant-category-contribution, service role) ────
CREATE OR REPLACE FUNCTION public.submit_merchant_category_contribution(
  p_user_id      UUID,
  p_merchant_key TEXT,
  p_category_key TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_hash TEXT;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_required' USING ERRCODE = 'P0422';
  END IF;
  IF NOT public.merchant_contribution_key_ok(p_merchant_key) THEN
    RAISE EXCEPTION 'merchant_key_invalid' USING ERRCODE = 'P0422';
  END IF;
  IF NOT public.merchant_contribution_category_ok(p_category_key) THEN
    RAISE EXCEPTION 'category_key_invalid' USING ERRCODE = 'P0422';
  END IF;
  v_hash := public.merchant_contributor_hash(p_user_id);
  IF v_hash IS NULL THEN
    RAISE EXCEPTION 'contribution_secret_missing' USING ERRCODE = 'P0500';
  END IF;
  INSERT INTO public.merchant_category_contributions (merchant_key, contributor_hash, category_key)
  VALUES (p_merchant_key, v_hash, p_category_key)
  ON CONFLICT (merchant_key, contributor_hash)
  DO UPDATE SET category_key = EXCLUDED.category_key;
END;
$$;
REVOKE ALL ON FUNCTION public.submit_merchant_category_contribution(UUID, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.submit_merchant_category_contribution(UUID, TEXT, TEXT)
  TO service_role;

-- ── Admin: list candidates ──────────────────────────────────────────────────
-- p_actor is the admin the Next.js route verified; it is checked again here so
-- a service-role caller with a non-admin actor still gets nothing.
CREATE OR REPLACE FUNCTION public.admin_list_merchant_category_candidates(p_actor UUID)
RETURNS TABLE (
  merchant_key        TEXT,
  category_key        TEXT,
  user_count          INTEGER,
  merchant_user_count INTEGER
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_actor IS NULL OR NOT EXISTS (SELECT 1 FROM public.admin_users a WHERE a.id = p_actor) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = 'P0403';
  END IF;
  RETURN QUERY
  WITH pairs AS (
    SELECT c.merchant_key, c.category_key, count(*)::INTEGER AS n
    FROM public.merchant_category_contributions c
    GROUP BY c.merchant_key, c.category_key
  ), merchants AS (
    SELECT c.merchant_key, count(*)::INTEGER AS n
    FROM public.merchant_category_contributions c
    GROUP BY c.merchant_key
  )
  SELECT p.merchant_key, p.category_key, p.n, m.n
  FROM pairs p
  JOIN merchants m ON m.merchant_key = p.merchant_key
  WHERE p.n >= public.merchant_category_candidate_min_users()
    AND NOT EXISTS (SELECT 1 FROM public.merchant_category_reviews r
                    WHERE r.merchant_key = p.merchant_key
                      AND r.category_key = p.category_key)
  ORDER BY p.n DESC, p.merchant_key, p.category_key;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_list_merchant_category_candidates(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_merchant_category_candidates(UUID) TO service_role;

-- ── Admin: approve (optionally with another category) or reject ─────────────
-- Errors: P0403 not an admin, P0422 invalid input, P0409 not a candidate
-- (below threshold) or already reviewed.
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

  -- Serialise reviews of one pair.
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

    -- Into the shared catalog devices pull. Re-uses an existing global row for
    -- the same keyword instead of adding a duplicate.
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

-- ── Erasure with the account ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.erase_merchant_category_contributions()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  DELETE FROM public.merchant_category_contributions
   WHERE contributor_hash = public.merchant_contributor_hash(OLD.id);
  RETURN OLD;
END;
$$;
REVOKE ALL ON FUNCTION public.erase_merchant_category_contributions() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS on_auth_user_deleted_erase_merchant_contributions ON auth.users;
CREATE TRIGGER on_auth_user_deleted_erase_merchant_contributions
  AFTER DELETE ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.erase_merchant_category_contributions();

COMMIT;
