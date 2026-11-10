begin;

create table qirsh_auth_hooks.google_enrollment_permits (
  subject text primary key check (subject ~ '^[0-9]{1,255}$'),
  expires_at timestamptz not null
);
revoke all on qirsh_auth_hooks.google_enrollment_permits from public, anon, authenticated, service_role;

create function public.qirsh_permit_google_enrollment(p_subject text) returns void
language sql volatile security definer set search_path = pg_catalog, pg_temp
as $$
  delete from qirsh_auth_hooks.google_enrollment_permits where expires_at <= clock_timestamp();
  insert into qirsh_auth_hooks.google_enrollment_permits(subject, expires_at)
  values(p_subject, clock_timestamp() + interval '90 seconds')
  on conflict(subject) do update set expires_at = excluded.expires_at;
$$;
revoke all on function public.qirsh_permit_google_enrollment(text) from public, anon, authenticated, service_role;
grant execute on function public.qirsh_permit_google_enrollment(text) to service_role;

create function qirsh_auth_hooks.require_google_enrollment_intent(event jsonb) returns jsonb
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp
as $$
begin
  if event #>> '{user,app_metadata,provider}' = 'google' then
    delete from qirsh_auth_hooks.google_enrollment_permits
    where subject = event #>> '{user,user_metadata,sub}' and expires_at > clock_timestamp();
    if not found then
      return jsonb_build_object('error', jsonb_build_object(
        'http_code', 403, 'message', 'Use Create an account to register with Google.'
      ));
    end if;
  end if;
  return '{}'::jsonb;
end;
$$;
revoke all on function qirsh_auth_hooks.require_google_enrollment_intent(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function qirsh_auth_hooks.require_google_enrollment_intent(jsonb) to supabase_auth_admin;

commit;
