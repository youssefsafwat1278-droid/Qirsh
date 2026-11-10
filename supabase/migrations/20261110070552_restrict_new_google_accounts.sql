-- Google is a sign-in method for an existing Qirsh account. Until deletion
-- supports Google-only accounts, enrollment must retain the Apple identity
-- needed by the existing account deletion challenge.
create schema qirsh_auth_hooks;
revoke all on schema qirsh_auth_hooks from public, anon, authenticated;
grant usage on schema qirsh_auth_hooks to supabase_auth_admin;

create function qirsh_auth_hooks.require_existing_google_account(event jsonb)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select case
    when event #>> '{user,app_metadata,provider}' = 'google' then
      jsonb_build_object('error', jsonb_build_object(
        'http_code', 403,
        'message', 'Sign in with Apple and connect Google from Settings to use this account.'
      ))
    else '{}'::jsonb
  end;
$$;

revoke all on function qirsh_auth_hooks.require_existing_google_account(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function qirsh_auth_hooks.require_existing_google_account(jsonb)
  to supabase_auth_admin;
