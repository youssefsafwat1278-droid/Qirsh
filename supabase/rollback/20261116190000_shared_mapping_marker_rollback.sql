-- Removes the shared-mapping marker: publishing goes back to priority 0 and
-- marked rows lose the marker (devices then rank them below the AI again;
-- the 0093 trigger bumps the catalog version so they re-download).
BEGIN;

UPDATE public.merchant_keywords
   SET priority = 0, updated_at = now()
 WHERE priority = public.merchant_category_shared_priority();

-- Restore the 20261116170000 publish body.
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

DROP FUNCTION IF EXISTS public.merchant_category_shared_priority();

COMMIT;
