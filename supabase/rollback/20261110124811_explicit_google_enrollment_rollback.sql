-- Reconfigure the Supabase before-user-created hook to the previous
-- qirsh_auth_hooks.require_existing_google_account function before this downgrade.
-- This removes temporary enrollment permits, never registered user accounts.
begin;
drop function qirsh_auth_hooks.require_google_enrollment_intent(jsonb);
drop function public.qirsh_permit_google_enrollment(text);
drop table qirsh_auth_hooks.google_enrollment_permits;
commit;
