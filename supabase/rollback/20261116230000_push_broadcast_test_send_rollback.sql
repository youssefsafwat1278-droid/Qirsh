-- Removes the test send. Test broadcasts already made stay as ordinary rows
-- (their deliveries are history); the history function returns to its
-- 20261116160000 shape.
BEGIN;
DROP FUNCTION IF EXISTS public.admin_create_push_broadcast_test(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.admin_push_broadcast_history(p_actor UUID, p_limit INTEGER DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v jsonb;
BEGIN
  PERFORM public.push_broadcast_require_admin(p_actor);
  SELECT coalesce(jsonb_agg(row_to_json(h)::jsonb ORDER BY h.created_at DESC), '[]'::jsonb) INTO v
    FROM (
      SELECT b.id, b.created_at, b.created_by, b.title_ar, b.title_en, b.deep_link, b.announcement_id,
             b.recipient_devices, b.recipient_users,
             count(d.id) FILTER (WHERE d.status IN ('pending', 'sending')) AS pending,
             count(d.id) FILTER (WHERE d.status = 'sent') AS sent,
             count(d.id) FILTER (WHERE d.status = 'failed') AS failed,
             count(d.id) FILTER (WHERE d.status = 'skipped') AS skipped,
             count(d.id) FILTER (WHERE d.status IN ('pending', 'failed') AND d.attempt_count < 5) AS retryable,
             (SELECT d2.error_code FROM public.push_broadcast_deliveries d2
               WHERE d2.broadcast_id = b.id AND d2.status = 'failed' AND d2.error_code IS NOT NULL
               GROUP BY d2.error_code ORDER BY count(*) DESC, d2.error_code LIMIT 1) AS top_error
        FROM public.push_broadcasts b
        LEFT JOIN public.push_broadcast_deliveries d ON d.broadcast_id = b.id
       GROUP BY b.id
       ORDER BY b.created_at DESC
       LIMIT greatest(1, least(coalesce(p_limit, 50), 200))
    ) h;
  RETURN v;
END;
$$;
ALTER TABLE public.push_broadcasts DROP COLUMN IF EXISTS test_user_id;
COMMIT;
