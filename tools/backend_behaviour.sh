#!/usr/bin/env bash
# Backend behaviour stage (V1-013): apply the WHOLE migration chain to a
# throwaway database on a LOCAL, DEDICATED Postgres and run the SQL behaviour
# proofs in supabase/tests against it (RLS, RPCs, grants, triggers).
#
# Opt-in. tools/ci_gates.sh runs it only when BACKEND_PG_HOST is set; it never
# starts or stops anything (no Docker, no Supabase CLI, no hosted project).
#
#   BACKEND_PG_HOST=127.0.0.1 BACKEND_PG_PORT=55999 bash tools/backend_behaviour.sh
#
# SAFETY
#   * The host must be local: 127.0.0.1, localhost, ::1 or a socket directory.
#   * The cluster must be DEDICATED to this check: it refuses to run if any
#     database other than postgres/template0/template1/qirsh_bb_* exists,
#     because the chain creates a cluster-wide role (account_fence_owner) that
#     this script drops and re-creates. Never point it at a Supabase dev stack.
#   * Start a dedicated cluster yourself, for example:
#       initdb -D /tmp/qbb -U postgres -A trust --locale=C.UTF-8
#       LC_ALL=en_US.UTF-8 pg_ctl -D /tmp/qbb -o "-k '' -c listen_addresses=127.0.0.1 -p 55999" start
#
# WHAT A PASS PROVES: every migration applies in filename order on PostgreSQL
# with the dry-run scaffold (supabase/tools/dryrun_scaffold.sql plus the small
# fidelity prelude below), and each listed proof's assertions hold there.
# WHAT IT DOES NOT PROVE: platform behaviour (pg_cron, pg_net, Vault, Storage
# and Auth are stubs), Edge Functions, or anything about a hosted project.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${BACKEND_PG_HOST:?set BACKEND_PG_HOST to a local, dedicated Postgres (see header)}"
export PGHOST="$HOST" PGPORT="${BACKEND_PG_PORT:-5432}" PGUSER="${BACKEND_PG_USER:-postgres}"
export PGOPTIONS="-c client_min_messages=warning"
unset PGDATABASE PGPASSWORD PGSERVICE
case "$HOST" in
  127.0.0.1|localhost|::1|/*) ;;
  *) echo "REFUSING: BACKEND_PG_HOST must be local (got '$HOST')." >&2; exit 2 ;;
esac
command -v psql >/dev/null 2>&1 || { echo "psql not installed" >&2; exit 2; }
P=(psql -X -q -v ON_ERROR_STOP=1)

others=$("${P[@]}" -d postgres -Atc "select string_agg(datname, ',') from pg_database where datname not in ('postgres','template0','template1') and datname not like 'qirsh_bb_%'") \
  || { echo "cannot connect to $PGHOST:$PGPORT" >&2; exit 2; }
if [ -n "$others" ]; then
  echo "REFUSING: cluster is not dedicated (other databases: $others)." >&2; exit 2
fi

DB="qirsh_bb_$$"
# BB_KEEP_DB=1 keeps the database for tools/prod_compare.sh (schema fingerprint).
cleanup() { [ "${BB_KEEP_DB:-0}" = "1" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" >/dev/null 2>&1; }
trap cleanup EXIT
"${P[@]}" -d postgres -c "drop database if exists $DB" >/dev/null || exit 1
if [ -n "$("${P[@]}" -d postgres -Atc "select 1 from pg_roles where rolname = 'account_fence_owner'")" ]; then
  "${P[@]}" -d postgres -c "drop role account_fence_owner" >/dev/null || { echo "cannot drop stale account_fence_owner" >&2; exit 1; }
fi
"${P[@]}" -d postgres -c "create database $DB" >/dev/null || exit 1

echo "── scaffold + fidelity prelude ──"
"${P[@]}" -d "$DB" < "$ROOT/supabase/tools/dryrun_scaffold.sql" >/dev/null 2>&1 || { echo "  ✗ scaffold"; exit 1; }
# Platform objects the later migrations reference and the scaffold omits, and
# auth.uid()/auth.role() reading the JSON claims GUC the way the platform does.
"${P[@]}" -d "$DB" >/dev/null <<'SQL' || { echo "  ✗ prelude"; exit 1; }
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then create role supabase_auth_admin nologin; end if;
end $$;
alter table auth.users add column if not exists reauthentication_sent_at timestamptz;
alter table auth.users add column if not exists reauthentication_token text;
alter table auth.users add column if not exists email_confirmed_at timestamptz;
create or replace function auth.uid() returns uuid language sql stable as $f$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid
$f$;
create or replace function auth.role() returns text language sql stable as $f$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'), 'anon')
$f$;
SQL
echo "  ok"

echo "── migrations (whole chain, filename order) ──"
applied=0
for f in "$ROOT"/supabase/migrations/*.sql; do
  if ! sed -E 's/^[[:space:]]*(CREATE|create)[[:space:]]+(EXTENSION|extension)[[:space:]]+(IF NOT EXISTS[[:space:]]+|if not exists[[:space:]]+)?(pg_cron|pg_net)[^;]*;/SELECT 1; -- stubbed/I' "$f" \
      | "${P[@]}" -d "$DB" >/dev/null 2>"$DB.err"; then
    echo "  ✗ $(basename "$f")"; grep -m3 -E '^(ERROR|DETAIL|psql)' "$DB.err" | sed 's/^/      /'; rm -f "$DB.err"; exit 1
  fi
  applied=$((applied + 1))
done
rm -f "$DB.err"
echo "  ok: $applied applied"

# Proofs that assert the state of the WHOLE chain. Excluded, with reason:
#   sync_foundation_0103_0114, sync_seed_pre_0103, user_merchant_rules_sync_20261116,
#   awaiting_fx_0102, capture_notifications_p1, feature_flag_admin_audit_0101,
#   revoke_delete_0115 — point-in-time proofs written for a chain stopped at
#     their own migration (driver scripts stage that); later migrations change
#     what they pin (e.g. the capability key list).
#   profile_photo_backup_20261116 — needs the platform Storage schema.
#   rls_two_user_isolation, rls_notification_logs_isolation — templates that
#     need real user ids substituted (<USER_A_ID>).
PROOFS=(
  ai_global_spend_guard_20261117.sql
  admin_push_broadcasts_20261116.sql
  announcement_update_severities_20261116.sql
  capture_expiry_fence.sql
  capture_state_machine_p1.sql
  push_broadcast_auto_retry_20261117.sql
  push_broadcast_test_send_20261116.sql
  shared_contribution_withdraw_20261116.sql
  shared_learning_auto_approve_20261116.sql
  shared_mapping_marker_20261116.sql
  shared_merchant_category_learning_20261116.sql
  tombstones_0116.sql
  transaction_category_source_20261117.sql
)
echo "── behaviour proofs (each in its own rolled-back transaction) ──"
failed=0
for name in "${PROOFS[@]}"; do
  f="$ROOT/supabase/tests/$name"
  [ -f "$f" ] || { echo "  ✗ $name (missing)"; failed=$((failed + 1)); continue; }
  if grep -qiE '^[[:space:]]*begin[[:space:]]*;' "$f"; then out=$("${P[@]}" -d "$DB" -f "$f" 2>&1); rc=$?
  else out=$({ echo 'BEGIN;'; cat "$f"; echo 'ROLLBACK;'; } | "${P[@]}" -d "$DB" 2>&1); rc=$?; fi
  # A proof fails on: a SQL error, any FAIL row, a "fail" verdict, or a
  # non-zero failed count in a "passed | failed" summary. It must also show
  # positive evidence (a PASS row, a "pass" verdict or a zero-failure summary).
  bad_rows=$(printf '%s\n' "$out" | grep -cE '\|[[:space:]]*FAIL[[:space:]]*(\||$)|^[[:space:]]*fail[[:space:]]*(\||$)')
  bad_sum=$(printf '%s\n' "$out" | grep -A2 -E 'passed[[:space:]]*\|[[:space:]]*failed' | grep -E '^[[:space:]]*[0-9]+[[:space:]]*\|[[:space:]]*[1-9]' -c)
  good=$(printf '%s\n' "$out" | grep -cE '\|[[:space:]]*PASS[[:space:]]*(\||$)|^[[:space:]]*pass[[:space:]]*(\||$)')
  good=$((good + $(printf '%s\n' "$out" | grep -A2 -E 'passed[[:space:]]*\|[[:space:]]*failed' | grep -cE '^[[:space:]]*[1-9][0-9]*[[:space:]]*\|[[:space:]]*0[[:space:]]*$')))
  if [ "$rc" -eq 0 ] && [ "$bad_rows" -eq 0 ] && [ "$bad_sum" -eq 0 ] && [ "$good" -gt 0 ]; then
    echo "  ✓ $name"
  else
    echo "  ✗ $name (rc=$rc fail-rows=$bad_rows bad-summary=$bad_sum pass-evidence=$good)"
    printf '%s\n' "$out" | grep -m5 -E 'ERROR|FAIL|fail' | sed 's/^/      /'
    failed=$((failed + 1))
  fi
done
echo
if [ "$failed" -eq 0 ]; then echo "BACKEND BEHAVIOUR PASSED ($applied migrations, ${#PROOFS[@]} proofs)"; exit 0; fi
echo "BACKEND BEHAVIOUR FAILED ($failed of ${#PROOFS[@]} proofs)"; exit 1
