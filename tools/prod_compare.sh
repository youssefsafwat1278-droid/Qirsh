#!/usr/bin/env bash
# Read-only comparison of production with a commit (RELEASE-PLAN P0 / (a)).
#
#   SUPABASE_PROJECT_REF=<ref> bash tools/prod_compare.sh <git-ref> [<git-ref> ...]
#
# 1. Edge Functions: lists the deployed functions (`supabase functions list`),
#    downloads each one's SOURCE (`supabase functions download --use-api`, which
#    returns the files as uploaded) into a temporary folder, and compares every
#    function, file by file, with the import closure of the same function at
#    each <git-ref>. Prints one line per function and ref: IDENTICAL, or
#    DIFFERS with the files that differ / are missing on either side.
# 2. Schema: when BACKEND_PG_HOST is set (a LOCAL, DEDICATED Postgres — see
#    tools/backend_behaviour.sh), applies the FIRST <git-ref>'s migrations to a
#    throwaway database, computes tools/schema_fingerprint.sql there, and prints
#    per-kind hashes plus the read-only query that yields the same hashes on
#    production (paste it into the SQL editor or the read-only connector).
#
# Only read commands touch production: functions list / download. The CLI's
# database commands are NOT used (they create a temporary login role there).
# Nothing is written to the repository; downloads go to a temp folder.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF_PROJECT="${SUPABASE_PROJECT_REF:?set SUPABASE_PROJECT_REF to the production project ref}"
[ "$#" -ge 1 ] || { echo "usage: SUPABASE_PROJECT_REF=<ref> $0 <git-ref> [<git-ref> ...]" >&2; exit 2; }
command -v supabase >/dev/null 2>&1 || { echo "supabase CLI not installed" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/prod_compare.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

for ref in "$@"; do
  git -C "$ROOT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || { echo "unknown ref: $ref" >&2; exit 2; }
  mkdir -p "$WORK/ref/$ref"
  git -C "$ROOT" archive "$ref" supabase/functions | tar -x -C "$WORK/ref/$ref"
done

supabase functions list --project-ref "$REF_PROJECT" --workdir "$WORK" -o json 2>/dev/null > "$WORK/list.json" || { echo "functions list failed" >&2; exit 1; }
python3 -I - "$WORK/list.json" > "$WORK/slugs.txt" <<'PY'
import json, sys, datetime
for f in sorted(json.load(open(sys.argv[1])), key=lambda f: f['slug']):
    t = datetime.datetime.fromtimestamp(f['updated_at'] / 1000, datetime.timezone.utc).strftime('%Y-%m-%d %H:%M')
    print(f['slug'], 'v%d' % f['version'], t, 'verify_jwt=%s' % str(f['verify_jwt']).lower())
PY
echo "── deployed functions (project $REF_PROJECT) ──"
cat "$WORK/slugs.txt"

echo
echo "── function sources vs each ref ──"
while read -r slug _; do
  mkdir -p "$WORK/dl/$slug"
  if ! (cd "$WORK/dl/$slug" && supabase functions download "$slug" --project-ref "$REF_PROJECT" --use-api --workdir . >/dev/null 2>&1); then
    echo "$slug: DOWNLOAD FAILED"; continue
  fi
  for ref in "$@"; do
    python3 -I - "$WORK/dl/$slug/supabase/functions" "$WORK/ref/$ref/supabase/functions" "$slug" "$ref" <<'PY'
import os, re, sys
dep_root, ref_root, slug, ref = sys.argv[1:5]
IMPORT = re.compile(r"""(?:import|export)\s[^'"]*?from\s*['"](\.{1,2}/[^'"]+)['"]|import\s*\(?\s*['"](\.{1,2}/[^'"]+)['"]""")
def closure(root, entry):
    seen, todo = set(), [entry]
    while todo:
        rel = os.path.normpath(todo.pop())
        if rel in seen: continue
        p = os.path.join(root, rel)
        if not os.path.isfile(p): seen.add(rel); continue
        seen.add(rel)
        if rel.endswith(('.ts', '.js', '.mjs', '.tsx')):
            src = open(p, encoding='utf-8', errors='replace').read()
            for m in IMPORT.finditer(src):
                todo.append(os.path.join(os.path.dirname(rel), m.group(1) or m.group(2)))
    return seen
dep = set()
for d, _, files in os.walk(dep_root):
    for f in files:
        rel = os.path.relpath(os.path.join(d, f), dep_root)
        if rel != 'deno.json' and not rel.startswith('.'):
            dep.add(rel)
entry = os.path.join(slug, 'index.ts')
want = closure(ref_root, entry)
diffs = []
for rel in sorted(dep | want):
    a, b = os.path.join(dep_root, rel), os.path.join(ref_root, rel)
    if not os.path.isfile(a): diffs.append(rel + ' (not deployed)')
    elif not os.path.isfile(b): diffs.append(rel + ' (not at ref)')
    elif open(a, 'rb').read() != open(b, 'rb').read(): diffs.append(rel)
print(f"{slug} vs {ref}: " + ('IDENTICAL (%d files)' % len(dep) if not diffs else 'DIFFERS: ' + ', '.join(diffs)))
PY
  done
done < "$WORK/slugs.txt"

if [ -n "${BACKEND_PG_HOST:-}" ]; then
  ref="$1"
  echo
  echo "── schema fingerprint of a fresh apply of $ref (local) ──"
  mkdir -p "$WORK/schema/supabase" "$WORK/schema/tools"
  git -C "$ROOT" archive "$ref" supabase/migrations supabase/tools supabase/tests | tar -x -C "$WORK/schema"
  cp "$ROOT/tools/backend_behaviour.sh" "$ROOT/tools/schema_fingerprint.sql" "$WORK/schema/tools/"
  BB_KEEP_DB=1 bash "$WORK/schema/tools/backend_behaviour.sh" >/dev/null 2>"$WORK/bb.err" || true
  db=$(PGHOST="$BACKEND_PG_HOST" PGPORT="${BACKEND_PG_PORT:-5432}" psql -X -U "${BACKEND_PG_USER:-postgres}" -d postgres -Atc \
       "select datname from pg_database where datname like 'qirsh_bb_%' order by oid desc limit 1")
  if [ -z "$db" ]; then echo "local apply failed:"; head -5 "$WORK/bb.err"; exit 1; fi
  body=$(sed -n '/^with s(n)/,$p' "$ROOT/tools/schema_fingerprint.sql" | sed '$ s/;[[:space:]]*$//')
  query="with fpx as ($body) select split_part(line,'|',1) k, count(*) n, left(md5(string_agg(line, E'\\n' order by line collate \"C\")),12) h from fpx group by 1 order by 1;"
  PGTZ=UTC PGHOST="$BACKEND_PG_HOST" PGPORT="${BACKEND_PG_PORT:-5432}" psql -X -U "${BACKEND_PG_USER:-postgres}" -d "$db" -At -c "$query"
  PGHOST="$BACKEND_PG_HOST" PGPORT="${BACKEND_PG_PORT:-5432}" psql -X -U "${BACKEND_PG_USER:-postgres}" -d postgres -qc "drop database $db" >/dev/null
  echo
  echo "Run this READ-ONLY query on production (session time zone UTC) and compare per kind:"
  echo "$query"
  echo "(Known non-drift differences: 'cron' — the local scaffold has no pg_cron, so jobs guarded"
  echo " by an extension check are absent locally; a 'fn' line for public._dryrun_noop is scaffold-only.)"
fi
