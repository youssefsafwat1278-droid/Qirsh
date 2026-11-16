-- Restores the 0003 severity list. Fails (by design) while any
-- update_available or release_notes row exists: delete or re-type those rows
-- first. Nothing else depends on the two values.
BEGIN;

ALTER TABLE public.announcements
  DROP CONSTRAINT IF EXISTS announcements_severity_check;

ALTER TABLE public.announcements
  ADD CONSTRAINT announcements_severity_check
  CHECK (severity IN ('info', 'warning', 'maintenance', 'force_update'));

COMMIT;
