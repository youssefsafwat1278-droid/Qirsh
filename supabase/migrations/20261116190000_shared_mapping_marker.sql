-- Shared category learning: mark published mappings so devices can rank them.
--
-- OWNER DECISION: a mapping published by shared learning (auto-approved at
-- 6+ users / 75%, or approved by an admin on the shared-learning page) now
-- outranks the cloud AI's category on the device. Every other
-- merchant_keywords row (admin-curated lists, Google Places enrichment, seed)
-- must NOT: those are substring keywords and stay below the AI.
--
-- The device needs to tell the two apart without a schema change. catalog-delta
-- already sends every merchant_keywords column and the device already stores
-- `priority`, and no writer uses anything but 0 (0006 default, 0009 seed,
-- enrich-merchant). So a shared-learning mapping is published with the
-- RESERVED priority merchant_category_shared_priority() (1000). The device
-- trusts it only as an EXACT match on the normalised merchant name.
--
-- A side effect on devices: the categorizer reads keywords ORDER BY priority
-- DESC, so a shared mapping is now tried before other keywords (ties among
-- priority-0 rows were unordered before).
--
-- The priority column is in the 0093 version trigger's change list, so the
-- backfill below bumps the merchant_keywords catalog version and devices
-- re-download the snapshot with the marker.

BEGIN;

CREATE OR REPLACE FUNCTION public.merchant_category_shared_priority()
RETURNS INTEGER LANGUAGE sql IMMUTABLE AS $$ SELECT 1000 $$;

-- The one publish path (manual and auto), as in 20261116170000 plus the marker.
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
    VALUES (p_merchant_key, p_category_key, 'any', 'ALL',
            public.merchant_category_shared_priority(), TRUE, FALSE, now());
  ELSE
    UPDATE public.merchant_keywords
       SET category_key = p_category_key, is_active = TRUE,
           priority = public.merchant_category_shared_priority(), updated_at = now()
     WHERE id = v_kw_id;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.merchant_category_publish(TEXT, TEXT)
  FROM PUBLIC, anon, authenticated, service_role;

-- Backfill: mappings already published (approved, manual or auto) get the marker.
UPDATE public.merchant_keywords k
   SET priority = public.merchant_category_shared_priority(), updated_at = now()
  FROM public.merchant_category_reviews r
 WHERE r.decision = 'approved'
   AND upper(k.keyword) = r.merchant_key
   AND k.category_key = r.published_category_key
   AND k.country_code = 'ALL'
   AND NOT k.is_deleted
   AND k.priority <> public.merchant_category_shared_priority();

COMMIT;
