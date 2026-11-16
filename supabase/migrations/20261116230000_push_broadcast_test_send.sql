-- Admin push: "send a test to one account" before a real broadcast.
--
-- admin_create_push_broadcast_test builds a broadcast whose deliveries are only
-- the devices of ONE account (named by email or user id), through the exact
-- audience rules and sender a real broadcast uses — so a test that arrives
-- proves the real path. Differences from a real broadcast:
--   * no in-app announcement is created (nobody else may see a test);
--   * no typed recipient count (the audience is one account's devices);
--   * push_broadcasts.test_user_id records the target, and the history marks it.
-- The target must currently be in the audience (Cloud on, device registered,
-- "Messages from Qirsh" on); otherwise 'no_recipients', as for a real send.
-- Reversible: rollback/20261116230000_push_broadcast_test_send_rollback.sql.
BEGIN;

ALTER TABLE public.push_broadcasts ADD COLUMN IF NOT EXISTS test_user_id UUID NULL;

CREATE OR REPLACE FUNCTION public.admin_create_push_broadcast_test(
  p_actor        UUID,
  p_operation_id UUID,
  p_title_ar     TEXT,
  p_title_en     TEXT,
  p_body_ar      TEXT,
  p_body_en      TEXT,
  p_deep_link    TEXT,
  p_target       TEXT
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_existing  public.push_broadcasts%ROWTYPE;
  v_target    TEXT := btrim(coalesce(p_target, ''));
  v_user      UUID;
  v_devices   INTEGER;
  v_broadcast UUID;
  v_link      TEXT := nullif(btrim(coalesce(p_deep_link, '')), '');
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

  IF v_target ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    SELECT u.id INTO v_user FROM auth.users u WHERE u.id = v_target::uuid;
  ELSIF v_target LIKE '%@%' THEN
    SELECT u.id INTO v_user FROM auth.users u WHERE lower(u.email) = lower(v_target)
     ORDER BY u.created_at LIMIT 1;
  END IF;
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'test_target_not_found' USING ERRCODE = 'P0422';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('pushb:' || p_operation_id::text, 0));
  SELECT * INTO v_existing FROM public.push_broadcasts WHERE operation_id = p_operation_id;
  IF FOUND THEN
    RETURN jsonb_build_object('replayed', true, 'broadcast_id', v_existing.id,
      'devices', v_existing.recipient_devices, 'users', v_existing.recipient_users, 'test', true);
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _push_broadcast_test_targets (install_id_hash TEXT PRIMARY KEY)
    ON COMMIT DROP;
  TRUNCATE _push_broadcast_test_targets;
  INSERT INTO _push_broadcast_test_targets
  SELECT a.install_id_hash FROM public.push_broadcast_audience_devices() a
   WHERE a.messages_enabled AND a.user_id = v_user;
  SELECT count(*) INTO v_devices FROM _push_broadcast_test_targets;
  IF v_devices = 0 THEN
    RAISE EXCEPTION 'no_recipients' USING ERRCODE = 'P0422';
  END IF;

  INSERT INTO public.push_broadcasts (operation_id, created_by, title_ar, title_en, body_ar, body_en,
         deep_link, announcement_id, recipient_devices, recipient_users, test_user_id)
  VALUES (p_operation_id, p_actor, btrim(p_title_ar), btrim(p_title_en), btrim(p_body_ar), btrim(p_body_en),
          v_link, NULL, v_devices, 1, v_user)
  RETURNING id INTO v_broadcast;

  INSERT INTO public.push_broadcast_deliveries (broadcast_id, install_id_hash)
  SELECT v_broadcast, t.install_id_hash FROM _push_broadcast_test_targets t
  ON CONFLICT ON CONSTRAINT push_broadcast_deliveries_one_per_device DO NOTHING;

  RETURN jsonb_build_object('replayed', false, 'broadcast_id', v_broadcast,
    'devices', v_devices, 'users', 1, 'test', true);
END;
$$;

-- History gains is_test so a test is never mistaken for a broadcast.
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
             b.recipient_devices, b.recipient_users, (b.test_user_id IS NOT NULL) AS is_test,
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

REVOKE ALL ON FUNCTION public.admin_create_push_broadcast_test(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_push_broadcast_test(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  TO service_role;

COMMIT;
