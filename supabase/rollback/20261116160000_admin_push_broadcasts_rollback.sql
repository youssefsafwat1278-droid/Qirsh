-- Drops the admin push broadcast ledger and its RPCs. The announcements that
-- broadcasts created stay (they are ordinary 'info' rows); delete them in the
-- Admin panel if they should disappear from the app too.
BEGIN;

DROP FUNCTION IF EXISTS public.finish_push_broadcast_delivery(UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.claim_push_broadcast_deliveries(UUID, UUID, UUID, INTEGER);
DROP FUNCTION IF EXISTS public.admin_push_broadcast_history(UUID, INTEGER);
DROP FUNCTION IF EXISTS public.admin_create_push_broadcast(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER);
DROP FUNCTION IF EXISTS public.admin_push_broadcast_dry_run(UUID);
DROP FUNCTION IF EXISTS public.push_broadcast_audience_devices();
DROP FUNCTION IF EXISTS public.push_broadcast_messages_enabled(TEXT);
DROP FUNCTION IF EXISTS public.push_broadcast_require_admin(UUID);
DROP TABLE IF EXISTS public.push_broadcast_deliveries;
DROP TABLE IF EXISTS public.push_broadcasts;

COMMIT;
