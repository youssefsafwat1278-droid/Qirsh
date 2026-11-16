-- Optional update banner + "What's new": two more announcement severities.
--
--   update_available — a dismissible banner offering the App Store update.
--                      Target it with max_app_version so only older clients
--                      receive it (catalog-announcements filters on the
--                      X-App-Version header, inclusive).
--   release_notes    — server-side notes the app may show on its What's new
--                      page above the notes bundled in the binary.
--
-- Neither one blocks the app. force_update stays the ONLY blocking severity:
-- public.announcement_blocks_clients() (0089) compares p_severity =
-- 'force_update' exactly, so the arming trigger and arm_force_update() are
-- unaffected and are deliberately not redefined here.

BEGIN;

ALTER TABLE public.announcements
  DROP CONSTRAINT IF EXISTS announcements_severity_check;

ALTER TABLE public.announcements
  ADD CONSTRAINT announcements_severity_check
  CHECK (severity IN ('info', 'warning', 'maintenance', 'force_update',
                      'update_available', 'release_notes'));

COMMIT;
