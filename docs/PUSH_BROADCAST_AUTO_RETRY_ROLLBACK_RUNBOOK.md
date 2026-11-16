# Push broadcast auto-retry: rollback runbook

Removes automatic retries for admin push broadcasts (migration
`20261116200000_push_broadcast_auto_retry.sql` plus the worker-secret mode of
`send-push-broadcast`) and returns to manual retries only, with the function
behind gateway JWT verification again.

Run the steps **in order**. Each one is safe to repeat. Production commands
need the owner's approval, like any production change. Never paste the secret
value into a terminal log, ticket or chat.

`$DB` is the production database URL; `$REF` is the project ref.

## 0. Before you start

- Check whether `20261116230000_push_broadcast_test_send.sql` (admin
  test-send) is applied **after** `20261116200000`. Both define
  `admin_push_broadcast_history`. The SQL rollback in step 5 restores the
  **20261116160000** body, which has no `is_test`. If 230000 is applied, step 6
  is mandatory.
- Save the current definition first, so step 6 has it:

```bash
psql "$DB" -Atc "select pg_get_functiondef('public.admin_push_broadcast_history(uuid,integer)'::regprocedure)||';'" > history_before_rollback.sql
```

## 1. Stop the schedule (immediate effect)

```sql
select cron.unschedule('push-broadcast-retry')
 where exists (select 1 from cron.job where jobname = 'push-broadcast-retry');
```

Verify, expecting `0`:

```sql
select count(*) from cron.job where jobname = 'push-broadcast-retry';
```

## 2. Delete the Vault entry

```sql
delete from vault.secrets where name = 'push_broadcast_worker_secret';
```

Verify, expecting `0`:

```sql
select count(*) from vault.decrypted_secrets where name = 'push_broadcast_worker_secret';
```

From this point the dispatcher fails closed even if its job is re-created: it
logs `worker secret not configured` and makes no HTTP call.

## 3. Unset the function secret

```bash
supabase secrets unset PUSH_BROADCAST_WORKER_SECRET --project-ref "$REF"
supabase secrets list --project-ref "$REF" | grep -c PUSH_BROADCAST_WORKER_SECRET   # expect 0
```

With the secret unset (or weak), `usableWorkerSecret` returns `''` and the
scheduled path can never authenticate.

## 4. Restore gateway JWT verification and redeploy

In `supabase/config.toml`, set `[functions.send-push-broadcast]` back to
`verify_jwt = true`, or delete that block (the default is `true`). Then:

```bash
supabase functions deploy send-push-broadcast --project-ref "$REF"
```

To roll the code back too, deploy the function from the commit before
`75025554` (the worker-secret mode). The admin path is unchanged by that
commit, so either version serves the Admin panel.

Verify that a non-JWT bearer is now refused by the gateway itself, expecting
`401`:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  "https://$REF.supabase.co/functions/v1/send-push-broadcast" \
  -H 'Authorization: Bearer not-a-jwt' -H 'Content-Type: application/json' -d '{}'
```

Then send a real retry from the Admin panel (Push → retry on a broadcast) to
confirm the manual path still works.

## 5. Apply the SQL rollback

```bash
psql "$DB" -v ON_ERROR_STOP=1 -f supabase/rollback/20261116200000_push_broadcast_auto_retry_rollback.sql
```

Verify, expecting `0`, `0` and `0`:

```sql
select count(*) from pg_proc where proname in
  ('run_push_broadcast_retry_dispatch', 'push_broadcast_retry_due', 'claim_push_broadcast_retry_deliveries');
select count(*) from information_schema.columns
 where table_name = 'push_broadcast_deliveries' and column_name = 'next_attempt_at';
select count(*) from cron.job where jobname = 'push-broadcast-retry';
```

The rollback also unschedules the job, so step 1 is a safety net, not a
dependency.

## 6. Re-apply the admin history body (only if 230000 is applied)

```bash
psql "$DB" -v ON_ERROR_STOP=1 -f history_before_rollback.sql
psql "$DB" -c "revoke all on function public.admin_push_broadcast_history(uuid, integer) from public, anon, authenticated;
               grant execute on function public.admin_push_broadcast_history(uuid, integer) to service_role;"
```

`history_before_rollback.sql` still names `next_auto_retry_at`, read from the
dropped `next_attempt_at` column. In that case use the 20261116230000 body
from the repository instead, which has `is_test` and no retry column. Verify,
expecting `1`, then load the Admin panel's Push page:

```sql
select (pg_get_functiondef('public.admin_push_broadcast_history(uuid,integer)'::regprocedure) like '%is_test%')::int;
```

## Local verification (2026-11-16)

Run against the local dev stack (`127.0.0.1:56422`), which already had
20261116230000 applied:

| Step | Result |
|---|---|
| Apply 200000 | applied; cron job 1, dispatcher 1, `next_attempt_at` 1, test Vault secret 1 |
| SQL proof `push_broadcast_auto_retry_20261116.sql` | 40/40 pass (dev device isolated inside the transaction) |
| Older proof `admin_push_broadcasts_20261116.sql` with 200000 applied | 34 pass / 0 fail |
| 1. Unschedule | `t`; job count 0 |
| 2. Vault delete | 1 row deleted; count 0 |
| 5. SQL rollback | applied; retry functions 0, column 0, job 0; a second run is a no-op (NOTICE only) |
| State diff vs. pre-test snapshot | only `admin_push_broadcast_history` differed (160000 body, `is_test` lost): **this is the step 6 case** |
| 6. Restore saved body | function hashes, ACLs, cron jobs, Vault count, columns and indexes identical to the pre-test snapshot; `push_broadcast_test_send_20261116.sql` 12 pass / 0 fail |

Steps 3 and 4 (function secret, `verify_jwt`, deploy) act on the hosted
project and were not run locally. The function's side is covered by the Deno
tests in `supabase/functions/send-push-broadcast/send_test.ts`: a missing,
31-character or weak secret never authenticates, and only a JWT-shaped token
reaches the login check.
