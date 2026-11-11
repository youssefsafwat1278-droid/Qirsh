-- Run after rolling back explicit Google enrollment. Disable the corresponding
-- Supabase before-user-created hook before dropping its SQL function.
begin;
drop function qirsh_auth_hooks.require_existing_google_account(jsonb);
revoke usage on schema qirsh_auth_hooks from supabase_auth_admin;
drop schema qirsh_auth_hooks;
commit;
