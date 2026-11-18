-- Schema fingerprint for comparing a fresh local apply of supabase/migrations
-- with production. READ-ONLY: one SELECT over the system catalogs; it reads no
-- table rows (cron commands are hashed, never printed).
-- Output: one line per object, "kind|key|detail", sorted. Owner names are left
-- out on purpose (platform-owned on the hosted project); client-role access is
-- given as a/u flags (anon / authenticated). service_role is left out: the
-- platform's default privileges grant it EXECUTE, the local scaffold does not.
-- Run with the session time zone set to UTC (PGTZ=UTC): column defaults that
-- hold a timestamptz literal are rendered in the session time zone.
with s(n) as (values ('public'), ('account_fence'), ('qirsh_auth_hooks'))
select line from (
  select 'col|' || c.table_schema || '.' || c.table_name || '.' || c.column_name || '|' ||
         c.data_type || ' null=' || c.is_nullable || ' def=' || coalesce(c.column_default, '') as line
  from information_schema.columns c join s on s.n = c.table_schema
  union all
  select 'fn|' || n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|' ||
         'definer=' || p.prosecdef || ' cfg=' || coalesce(array_to_string(p.proconfig, ','), '') ||
         ' body=' || md5(p.prosrc) || ' ret=' || pg_get_function_result(p.oid) ||
         ' x=' || (case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'a' else '-' end) ||
                  (case when has_function_privilege('authenticated', p.oid, 'EXECUTE') then 'u' else '-' end)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace join s on s.n = n.nspname
  where not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  union all
  select 'pol|' || schemaname || '.' || tablename || '.' || policyname || '|' || cmd || ' ' ||
         array_to_string(roles, ',') || ' ' || permissive || ' q=' || md5(coalesce(qual, '')) ||
         ' c=' || md5(coalesce(with_check, ''))
  from pg_policies join s on s.n = schemaname
  union all
  select 'pol|storage.objects.' || policyname || '|' || cmd || ' ' || array_to_string(roles, ',') ||
         ' q=' || md5(coalesce(qual, '')) || ' c=' || md5(coalesce(with_check, ''))
  from pg_policies where schemaname = 'storage' and tablename = 'objects'
  union all
  select 'idx|' || schemaname || '.' || indexname || '|' || md5(indexdef)
  from pg_indexes join s on s.n = schemaname
  union all
  select 'con|' || n.nspname || '.' || t.relname || '.' || co.conname || '|' || md5(pg_get_constraintdef(co.oid))
  from pg_constraint co join pg_class t on t.oid = co.conrelid join pg_namespace n on n.oid = t.relnamespace
  join s on s.n = n.nspname
  union all
  select 'trg|' || n.nspname || '.' || t.relname || '.' || tg.tgname || '|' || md5(pg_get_triggerdef(tg.oid)) ||
         ' enabled=' || tg.tgenabled::text
  from pg_trigger tg join pg_class t on t.oid = tg.tgrelid join pg_namespace n on n.oid = t.relnamespace
  join s on s.n = n.nspname where not tg.tgisinternal
  union all
  select 'tbl|' || n.nspname || '.' || c.relname || '|' || c.relkind::text || ' rls=' || c.relrowsecurity ||
         ' a=' || (case when has_table_privilege('anon', c.oid, 'SELECT') then 'S' else '-' end) ||
                  (case when has_table_privilege('anon', c.oid, 'INSERT') then 'I' else '-' end) ||
                  (case when has_table_privilege('anon', c.oid, 'UPDATE') then 'U' else '-' end) ||
                  (case when has_table_privilege('anon', c.oid, 'DELETE') then 'D' else '-' end) ||
         ' u=' || (case when has_table_privilege('authenticated', c.oid, 'SELECT') then 'S' else '-' end) ||
                  (case when has_table_privilege('authenticated', c.oid, 'INSERT') then 'I' else '-' end) ||
                  (case when has_table_privilege('authenticated', c.oid, 'UPDATE') then 'U' else '-' end) ||
                  (case when has_table_privilege('authenticated', c.oid, 'DELETE') then 'D' else '-' end)
  from pg_class c join pg_namespace n on n.oid = c.relnamespace join s on s.n = n.nspname
  where c.relkind in ('r', 'v', 'm', 'p')
  union all
  select 'cron|' || jobname || '|' || schedule || ' active=' || active || ' cmd=' || md5(command)
  from cron.job
) x
order by line;
