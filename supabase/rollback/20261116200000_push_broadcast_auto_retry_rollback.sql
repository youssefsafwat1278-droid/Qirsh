-- Removes automatic push-broadcast retries (20261116200000). Restores the
-- 20261116160000 claim / finish / history bodies verbatim, so retries are
-- manual-only again. Rows the new sender recorded as 'skipped' for a dead token
-- go back to the old representation (failed, exhausted); other rows keep their
-- status. Vault 'push_broadcast_worker_secret' and the Edge secret
-- PUSH_BROADCAST_WORKER_SECRET are left for the operator to remove.
BEGIN;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_cron')
     AND EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'push-broadcast-retry') THEN
    PERFORM cron.unschedule('push-broadcast-retry');
  END IF;
END
$cron$;

DROP FUNCTION IF EXISTS public.run_push_broadcast_retry_dispatch();
DROP FUNCTION IF EXISTS public.push_broadcast_retry_due(INTEGER);
DROP FUNCTION IF EXISTS public.claim_push_broadcast_retry_deliveries(UUID, UUID, INTEGER);

UPDATE public.push_broadcast_deliveries
   SET status = 'failed', attempt_count = greatest(attempt_count, 5), updated_at = now()
 WHERE status = 'skipped'
   AND (error_code LIKE 'apns\_410\_%'
        OR error_code IN ('apns_400_BadDeviceToken', 'apns_400_Unregistered', 'apns_400_ExpiredToken',
                          'apns_400_DeviceTokenNotForTopic'));

-- 20261116160000 bodies, verbatim.
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

CREATE OR REPLACE FUNCTION public.claim_push_broadcast_deliveries(
  p_actor        UUID,
  p_broadcast_id UUID,
  p_run_id       UUID,
  p_limit        INTEGER DEFAULT 100
) RETURNS TABLE (
  delivery_id        UUID,
  device_hash        TEXT,
  attempts           INTEGER,
  in_audience        BOOLEAN,
  token              TEXT,
  environment        TEXT,
  settings_language  TEXT,
  notifications_json TEXT
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
BEGIN
  PERFORM public.push_broadcast_require_admin(p_actor);
  RETURN QUERY
  WITH picked AS (
    SELECT x.id
      FROM public.push_broadcast_deliveries x
     WHERE x.broadcast_id = p_broadcast_id
       AND ((x.status IN ('pending', 'failed') AND x.attempt_count < 5)
            OR (x.status = 'sending' AND x.claimed_at < now() - interval '5 minutes'))
       AND x.last_run_id IS DISTINCT FROM p_run_id
     ORDER BY x.created_at, x.id
     LIMIT greatest(1, least(coalesce(p_limit, 100), 500))
     FOR UPDATE SKIP LOCKED
  ), claimed AS (
    UPDATE public.push_broadcast_deliveries x
       SET status = 'sending', claimed_at = now(), last_run_id = p_run_id, updated_at = now()
      FROM picked
     WHERE x.id = picked.id
    RETURNING x.id, x.install_id_hash, x.attempt_count
  )
  SELECT c.id, c.install_id_hash, c.attempt_count, a.install_id_hash IS NOT NULL,
         a.apns_token, a.apns_environment, a.settings_language, a.notifications_json
    FROM claimed c
    LEFT JOIN public.push_broadcast_audience_devices() a ON a.install_id_hash = c.install_id_hash;
END;
$$;

CREATE OR REPLACE FUNCTION public.finish_push_broadcast_delivery(
  p_delivery_id   UUID,
  p_status        TEXT,
  p_error_code    TEXT,
  p_count_attempt BOOLEAN,
  p_exhaust       BOOLEAN,
  p_language      TEXT,
  p_apns_id       TEXT
) RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_status NOT IN ('sent', 'failed', 'skipped') THEN
    RAISE EXCEPTION 'status_invalid' USING ERRCODE = 'P0422';
  END IF;
  UPDATE public.push_broadcast_deliveries
     SET status = p_status,
         error_code = CASE WHEN p_status = 'sent' THEN NULL ELSE left(p_error_code, 120) END,
         attempt_count = CASE WHEN p_exhaust THEN greatest(attempt_count, 5)
                              WHEN p_count_attempt THEN attempt_count + 1
                              ELSE attempt_count END,
         language = coalesce(p_language, language),
         apns_id = coalesce(p_apns_id, apns_id),
         sent_at = CASE WHEN p_status = 'sent' THEN now() ELSE sent_at END,
         claimed_at = NULL,
         updated_at = now()
   WHERE id = p_delivery_id AND status = 'sending';
  RETURN FOUND;
END;
$$;

DROP FUNCTION IF EXISTS public.push_broadcast_claim_rows(UUID, UUID, INTEGER, BOOLEAN);
DROP FUNCTION IF EXISTS public.push_broadcast_delivery_claimable(TEXT, INTEGER, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN);
DROP FUNCTION IF EXISTS public.push_broadcast_retry_backoff(INTEGER);
ALTER TABLE public.push_broadcast_deliveries DROP COLUMN IF EXISTS next_attempt_at;

REVOKE ALL ON FUNCTION public.admin_push_broadcast_history(UUID, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_push_broadcast_deliveries(UUID, UUID, UUID, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finish_push_broadcast_delivery(UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_push_broadcast_history(UUID, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_push_broadcast_deliveries(UUID, UUID, UUID, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.finish_push_broadcast_delivery(UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, TEXT)
  TO service_role;

COMMIT;
