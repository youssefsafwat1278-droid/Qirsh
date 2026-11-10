#!/bin/bash
# Runs qualification phases against a stack started by up.sh (explicitly owner-approved loopback runtime path;
# run.sh / preflight.sh remain refusal gates and are not used). Connection values are read from the private
# test.env in <rundir> and never printed.
# Usage: phases.sh <rundir> migrate|baseline-pre|apply|acl|concurrency|drain|rollback|baseline-post|compare|refuse-queue|full-chain|all
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tests="$(cd "$here/.." && pwd)"
repo="$(cd "$here/../../../.." && pwd)"
rundir="${1:?usage: phases.sh <rundir> <phase>}"; phase="${2:?phase}"
set -a; . "$rundir/test.env"; set +a
case "$FENCE_DB_URL" in postgres://postgres:*@127.0.0.1:*) ;; *) echo "phases: refusing non-loopback DB URL" >&2; exit 2;; esac
FENCE_MIG_NAME="0117_account_deletion_fence.sql"
FENCE_MIG="$repo/supabase/migrations/$FENCE_MIG_NAME"
FENCE_RB="$repo/supabase/rollback/0117_account_deletion_fence_rollback.sql"
psqlx() { psql -X -q -v ON_ERROR_STOP=1 "$FENCE_DB_URL" "$@"; }
case "$phase" in
  migrate)
    # Omit the fence and its dependent provider extension for the pre-fence baseline.
    n=0
    for f in $(ls "$repo"/supabase/migrations/*.sql | LC_ALL=C sort); do
      case "$(basename "$f")" in "$FENCE_MIG_NAME"|*_deletion_provider_proofs.sql) continue;; esac
      psqlx -f "$f" >/dev/null 2>"$rundir/migrate.err" || { echo "MIGRATION FAILED: $(basename "$f")" >&2; sed -n 1,10p "$rundir/migrate.err" >&2; exit 1; }
      n=$((n + 1))
    done
    echo "migrate: $n migrations applied (excluding $FENCE_MIG_NAME)" ;;
  baseline-pre)  psqlx -f "$tests/baseline.sql" > "$rundir/baseline_pre.txt" 2>&1; echo "baseline-pre: $(wc -l < "$rundir/baseline_pre.txt") lines" ;;
  apply)         psqlx -f "$FENCE_MIG" ;;
  acl)           psqlx -f "$tests/acl.sql" ;;
  concurrency)   cd "$tests" && deno test --cached-only --no-check --allow-env --allow-run --allow-net concurrency_test.ts ;;
  drain)         "$here/drain.sh" "$rundir" ;;
  rollback)      psqlx -f "$FENCE_RB" ;;
  baseline-post) psqlx -f "$tests/baseline.sql" > "$rundir/baseline_post.txt" 2>&1; echo "baseline-post: $(wc -l < "$rundir/baseline_post.txt") lines" ;;
  compare)       diff "$rundir/baseline_pre.txt" "$rundir/baseline_post.txt" && echo "compare: post-rollback baseline identical to pre-fence baseline" ;;
  refuse-queue)
    # Separately migrated stack (migrate phase done, fence NOT applied). A queued legacy purge row must make apply fail with QD096.
    qid="$(psqlx -At -c "insert into public.account_purge_queue (user_id) values (gen_random_uuid()) returning user_id;" | head -1)"
    case "$qid" in ????????-????-????-????-????????????) ;; *) echo "refuse-queue: could not insert the test row" >&2; exit 1;; esac
    rc=0
    out="$(psqlx -v VERBOSITY=verbose -f "$FENCE_MIG" 2>&1)" || rc=$?
    # Always restore the pre-test state, whatever happened above.
    psqlx -c "delete from public.account_purge_queue where user_id = '$qid';" || echo "refuse-queue: WARNING test row cleanup failed" >&2
    [ "$rc" -ne 0 ] || { echo "refuse-queue: FAIL apply unexpectedly succeeded" >&2; exit 1; }
    printf '%s\n' "$out" | grep -q 'QD096' || { echo "refuse-queue: FAIL apply failed without QD096:" >&2; printf '%s\n' "$out" | sed -n 1,10p >&2; exit 1; }
    [ "$(psqlx -At -c "select to_regnamespace('account_fence') is null")" = "t" ] || { echo "refuse-queue: FAIL account_fence schema exists after refused apply" >&2; exit 1; }
    echo "refuse-queue: PASS (apply refused with QD096, account_fence absent, test row removed)" ;;
  full-chain)
    # Separately migrated stack: every migration 0001..0117 in order, as `supabase db push` would.
    n=0
    for f in $(ls "$repo"/supabase/migrations/*.sql | LC_ALL=C sort); do
      psqlx -f "$f" >/dev/null 2>"$rundir/fullchain.err" || { echo "MIGRATION FAILED: $(basename "$f")" >&2; sed -n 1,10p "$rundir/fullchain.err" >&2; exit 1; }
      n=$((n + 1))
    done
    echo "full-chain: PASS ($n migrations applied in order, last: $(ls "$repo"/supabase/migrations/*.sql | LC_ALL=C sort | tail -1 | xargs basename))" ;;
  all) for p in migrate baseline-pre apply acl concurrency drain rollback baseline-post compare; do echo "== $p"; "$0" "$rundir" "$p"; done ;;
  *) echo "phases: unknown phase" >&2; exit 2;;
esac
