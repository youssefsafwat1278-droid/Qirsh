-- Admin push broadcasts: a service message composed in the Admin panel, pushed
-- once per eligible device over APNs and stored as an in-app announcement.
--
-- AUDIENCE (v1, service messages only). A device receives a broadcast when ALL hold:
--   * user_settings (the account row: local_id = 'user_settings', not deleted)
--     has cloud_processing_enabled IS TRUE and consent_version > 0. This is the
--     same server-side Cloud choice the app reads (AppSession.readAccountCloudChoice)
--     and the same rule ai_endpoint enforces; NULL/false or an unversioned TRUE = OFF.
--   * the device row is linked to that user AND carries that user's consent
--     projection (consent_owner_uid = user_id), cloud_processing_enabled IS TRUE,
--     is not revoked, and holds an APNs token + environment.
--   * the account is not pending deletion (account_fence.is_pending).
--   * notifications_json.marketingMessages is not false. That key is the app's
--     existing "Messages from Qirsh" toggle (setQirshMessages), default ON; an
--     absent key or malformed blob counts as the default, exactly as
--     _shared/notification_policy.ts treats every other preference.
-- The send function re-checks all of this per device at send time.
--
-- DELIVERY LEDGER. One row per (broadcast, device), UNIQUE, so a re-run of the
-- create RPC or of the sender can never produce a second row. The sender claims
-- rows with FOR UPDATE SKIP LOCKED and only rows that were never delivered
-- (pending, or failed with attempts left); 'sent' and 'skipped' are terminal.
-- Rows hold the install hash only (no user id, no token), and cascade away with
-- the device row.
--
-- AUTHORIZATION. Same shape as admin_apply_feature_flag_changes (0101): the
-- Next.js route checks admin_users with requireAdmin(), then calls these RPCs
-- with the server-only service-role client and the admin's id. Every RPC
-- re-checks that id against admin_users (defense in depth) and is EXECUTE-able
-- by service_role only. Both tables are RLS deny-all with no client grants.

BEGIN;

-- ─── 1. Tables ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.push_broadcasts (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operation_id     UUID NOT NULL UNIQUE,
  -- No FK on purpose (attribution survives the admin account), as in 0101.
  created_by       UUID NOT NULL,
  title_ar         TEXT NOT NULL CHECK (char_length(btrim(title_ar)) BETWEEN 1 AND 120),
  title_en         TEXT NOT NULL CHECK (char_length(btrim(title_en)) BETWEEN 1 AND 120),
  body_ar          TEXT NOT NULL CHECK (char_length(btrim(body_ar)) BETWEEN 1 AND 600),
  body_en          TEXT NOT NULL CHECK (char_length(btrim(body_en)) BETWEEN 1 AND 600),
  -- In-app routes only. Mirrors admin/lib/push-broadcast.mjs and the app's
  -- broadcastRouteFor(); every entry is a GoRouter path the app already opens.
  deep_link        TEXT NULL CHECK (deep_link IS NULL OR deep_link IN (
                     '/announcements', '/budgets', '/goals', '/subscriptions',
                     '/reports', '/achievements', '/settings', '/privacy')),
  announcement_id  UUID NULL REFERENCES public.announcements(id) ON DELETE SET NULL,
  recipient_devices INTEGER NOT NULL CHECK (recipient_devices >= 0),
  recipient_users  INTEGER NOT NULL CHECK (recipient_users >= 0),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.push_broadcast_deliveries (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  broadcast_id    UUID NOT NULL REFERENCES public.push_broadcasts(id) ON DELETE CASCADE,
  install_id_hash TEXT NOT NULL REFERENCES public.capture_devices(install_id_hash) ON DELETE CASCADE,
  status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'sending', 'sent', 'failed', 'skipped')),
  attempt_count   INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  language        TEXT NULL CHECK (language IN ('ar', 'en')),
  error_code      TEXT NULL CHECK (char_length(error_code) <= 120),
  apns_id         TEXT NULL,
  claimed_at      TIMESTAMPTZ NULL,
  -- The sender invocation that last claimed the row: one invocation never
  -- re-claims a row it already attempted (a failure waits for the next run).
  last_run_id     UUID NULL,
  sent_at         TIMESTAMPTZ NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT push_broadcast_deliveries_one_per_device UNIQUE (broadcast_id, install_id_hash)
);

CREATE INDEX IF NOT EXISTS idx_push_broadcast_deliveries_open
  ON public.push_broadcast_deliveries (broadcast_id, created_at)
  WHERE status IN ('pending', 'sending', 'failed');
CREATE INDEX IF NOT EXISTS idx_push_broadcast_deliveries_install
  ON public.push_broadcast_deliveries (install_id_hash);

ALTER TABLE public.push_broadcasts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.push_broadcast_deliveries ENABLE ROW LEVEL SECURITY;
-- No policies: RLS denies every client role. service_role bypasses RLS.
REVOKE ALL ON TABLE public.push_broadcasts FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.push_broadcast_deliveries FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.push_broadcasts TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.push_broadcast_deliveries TO service_role;

-- ─── 2. Helpers ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.push_broadcast_require_admin(p_actor UUID)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_actor IS NULL OR NOT EXISTS (SELECT 1 FROM public.admin_users a WHERE a.id = p_actor) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501';
  END IF;
END;
$$;

-- "Messages from Qirsh" (NotificationPreferences.marketingMessages), default ON.
CREATE OR REPLACE FUNCTION public.push_broadcast_messages_enabled(p_notifications_json TEXT)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF p_notifications_json IS NULL OR btrim(p_notifications_json) = '' THEN
    RETURN true;
  END IF;
  RETURN coalesce((p_notifications_json::jsonb ->> 'marketingMessages') IS DISTINCT FROM 'false', true);
EXCEPTION WHEN others THEN
  RETURN true;  -- a malformed blob never blocks or crashes; it reads as the default
END;
$$;

-- Every device currently in the v1 audience, BEFORE the preference filter (the
-- preference is reported per row so the sender can record a 'preference_off' skip).
CREATE OR REPLACE FUNCTION public.push_broadcast_audience_devices()
RETURNS TABLE (
  install_id_hash    TEXT,
  user_id            UUID,
  apns_token         TEXT,
  apns_environment   TEXT,
  settings_language  TEXT,
  notifications_json TEXT,
  messages_enabled   BOOLEAN
)
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT d.install_id_hash, d.user_id, d.apns_token, d.apns_environment,
         s.language, s.notifications_json,
         public.push_broadcast_messages_enabled(s.notifications_json)
    FROM public.capture_devices d
    JOIN public.user_settings s
      ON s.user_id = d.user_id AND s.local_id = 'user_settings' AND s.deleted_at IS NULL
   WHERE d.user_id IS NOT NULL
     AND d.consent_owner_uid = d.user_id
     AND d.cloud_processing_enabled IS TRUE
     AND d.revoked_at IS NULL
     AND d.apns_token IS NOT NULL
     AND d.apns_environment IS NOT NULL
     AND s.cloud_processing_enabled IS TRUE
     AND s.consent_version > 0
     AND NOT account_fence.is_pending(d.user_id)
$$;

-- ─── 3. Admin RPCs ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_push_broadcast_dry_run(p_actor UUID)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v jsonb;
BEGIN
  PERFORM public.push_broadcast_require_admin(p_actor);
  SELECT jsonb_build_object(
           'devices', count(*),
           'users', count(DISTINCT a.user_id))
    INTO v
    FROM public.push_broadcast_audience_devices() a
   WHERE a.messages_enabled;
  RETURN v;
END;
$$;

-- Creates the broadcast, its announcement and one pending delivery per device,
-- in one transaction. Idempotent on p_operation_id. p_confirm_devices is the
-- count the admin typed; it must equal the audience at this instant, so the
-- confirmation can never authorize a different blast radius than it showed.
CREATE OR REPLACE FUNCTION public.admin_create_push_broadcast(
  p_actor           UUID,
  p_operation_id    UUID,
  p_title_ar        TEXT,
  p_title_en        TEXT,
  p_body_ar         TEXT,
  p_body_en         TEXT,
  p_deep_link       TEXT,
  p_confirm_devices INTEGER
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_existing     public.push_broadcasts%ROWTYPE;
  v_devices      INTEGER;
  v_users        INTEGER;
  v_announcement UUID;
  v_broadcast    UUID;
  v_link         TEXT := nullif(btrim(coalesce(p_deep_link, '')), '');
BEGIN
  PERFORM public.push_broadcast_require_admin(p_actor);
  IF p_operation_id IS NULL THEN
    RAISE EXCEPTION 'operation_id_required' USING ERRCODE = 'P0422';
  END IF;
  IF char_length(btrim(coalesce(p_title_ar, ''))) NOT BETWEEN 1 AND 120
     OR char_length(btrim(coalesce(p_title_en, ''))) NOT BETWEEN 1 AND 120
     OR char_length(btrim(coalesce(p_body_ar, ''))) NOT BETWEEN 1 AND 600
     OR char_length(btrim(coalesce(p_body_en, ''))) NOT BETWEEN 1 AND 600 THEN
    RAISE EXCEPTION 'content_invalid' USING ERRCODE = 'P0422';
  END IF;
  IF v_link IS NOT NULL AND v_link NOT IN ('/announcements', '/budgets', '/goals', '/subscriptions',
                                           '/reports', '/achievements', '/settings', '/privacy') THEN
    RAISE EXCEPTION 'deep_link_not_allowed' USING ERRCODE = 'P0422';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('pushb:' || p_operation_id::text, 0));
  SELECT * INTO v_existing FROM public.push_broadcasts WHERE operation_id = p_operation_id;
  IF FOUND THEN
    RETURN jsonb_build_object('replayed', true, 'broadcast_id', v_existing.id,
      'devices', v_existing.recipient_devices, 'users', v_existing.recipient_users);
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _push_broadcast_targets (install_id_hash TEXT PRIMARY KEY, user_id UUID)
    ON COMMIT DROP;
  TRUNCATE _push_broadcast_targets;
  INSERT INTO _push_broadcast_targets
  SELECT a.install_id_hash, a.user_id FROM public.push_broadcast_audience_devices() a WHERE a.messages_enabled;
  SELECT count(*), count(DISTINCT t.user_id) INTO v_devices, v_users FROM _push_broadcast_targets t;

  IF v_devices = 0 THEN
    RAISE EXCEPTION 'no_recipients' USING ERRCODE = 'P0422';
  END IF;
  IF p_confirm_devices IS DISTINCT FROM v_devices THEN
    RAISE EXCEPTION 'recipient_count_changed' USING ERRCODE = 'P0409',
      DETAIL = format('confirmed %s, audience is now %s', p_confirm_devices, v_devices);
  END IF;

  INSERT INTO public.announcements (title_ar, title_en, body_ar, body_en, severity,
         action_label_ar, action_label_en, action_url, valid_from, valid_until,
         is_dismissible, priority, is_active)
  VALUES (btrim(p_title_ar), btrim(p_title_en), btrim(p_body_ar), btrim(p_body_en), 'info',
          CASE WHEN v_link IS NULL THEN NULL ELSE 'افتح' END,
          CASE WHEN v_link IS NULL THEN NULL ELSE 'Open' END,
          v_link, now(), now() + interval '14 days', true, 0, true)
  RETURNING id INTO v_announcement;

  INSERT INTO public.push_broadcasts (operation_id, created_by, title_ar, title_en, body_ar, body_en,
         deep_link, announcement_id, recipient_devices, recipient_users)
  VALUES (p_operation_id, p_actor, btrim(p_title_ar), btrim(p_title_en), btrim(p_body_ar), btrim(p_body_en),
          v_link, v_announcement, v_devices, v_users)
  RETURNING id INTO v_broadcast;

  INSERT INTO public.push_broadcast_deliveries (broadcast_id, install_id_hash)
  SELECT v_broadcast, t.install_id_hash FROM _push_broadcast_targets t
  ON CONFLICT ON CONSTRAINT push_broadcast_deliveries_one_per_device DO NOTHING;

  RETURN jsonb_build_object('replayed', false, 'broadcast_id', v_broadcast,
    'announcement_id', v_announcement, 'devices', v_devices, 'users', v_users);
END;
$$;

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

-- ─── 4. Sender RPCs (called by the send-push-broadcast Edge Function) ───────
-- Claims up to p_limit rows that were never delivered: 'pending', 'failed' with
-- attempts left (< 5), or a 'sending' claim abandoned for 5 minutes. 'sent' and
-- 'skipped' are never claimed again. SKIP LOCKED keeps two concurrent senders
-- off the same row; the row moves to 'sending' in the same statement. p_run_id
-- identifies the calling invocation, which never re-claims its own attempts.
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

-- Records the outcome of one claimed row. Only a row still in 'sending' moves,
-- so a late or duplicate finish can never overwrite a newer outcome.
--   p_count_attempt  false for failures that never reached APNs (apns_not_configured):
--                    the row stays retryable without burning an attempt.
--   p_exhaust        true for a dead token: no further attempt can succeed.
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

-- ─── 5. Privileges ──────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.push_broadcast_require_admin(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.push_broadcast_messages_enabled(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.push_broadcast_audience_devices() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_push_broadcast_dry_run(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_create_push_broadcast(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_push_broadcast_history(UUID, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_push_broadcast_deliveries(UUID, UUID, UUID, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finish_push_broadcast_delivery(UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.admin_push_broadcast_dry_run(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_create_push_broadcast(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_push_broadcast_history(UUID, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_push_broadcast_deliveries(UUID, UUID, UUID, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.finish_push_broadcast_delivery(UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, TEXT)
  TO service_role;

COMMIT;
