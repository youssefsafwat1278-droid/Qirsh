#!/usr/bin/env bash
# Derive the Edge Function deploy set from import closures (no production access).
#
#   bash tools/deploy_set.sh <base-ref> [<target-ref>]
#
# For every function at <target-ref> (default HEAD) — a directory under
# supabase/functions with an index.ts — computes the import closure (relative
# imports, including JSON) at both refs and prints one line per function:
#   CHANGED  <fn>  <files whose bytes differ / that exist on one side only>
#   NEW      <fn>  (no index.ts at <base-ref>)
#   SAME     <fn>
# Use <base-ref> = the commit production was deployed from (b6fc0dad for the
# parser functions). Functions whose deployed source matches no commit are
# found by tools/prod_compare.sh, which compares with the downloaded source;
# the release set is the union of both.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${1:?usage: deploy_set.sh <base-ref> [<target-ref>]}"
TARGET="${2:-HEAD}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/deploy_set.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
for side in base:"$BASE" target:"$TARGET"; do
  name="${side%%:*}"; ref="${side#*:}"
  git -C "$ROOT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || { echo "unknown ref: $ref" >&2; exit 2; }
  mkdir -p "$WORK/$name"
  git -C "$ROOT" archive "$ref" supabase/functions | tar -x -C "$WORK/$name"
done
python3 -I - "$WORK/base/supabase/functions" "$WORK/target/supabase/functions" <<'PY'
import os, re, sys
base, target = sys.argv[1:3]
IMPORT = re.compile(r"""(?:import|export)\s[^'"]*?from\s*['"](\.{1,2}/[^'"]+)['"]|import\s*\(?\s*['"](\.{1,2}/[^'"]+)['"]""")
def closure(root, entry):
    seen, todo = set(), [entry]
    while todo:
        rel = os.path.normpath(todo.pop())
        if rel in seen: continue
        seen.add(rel)
        p = os.path.join(root, rel)
        if os.path.isfile(p) and rel.endswith(('.ts', '.js', '.mjs', '.tsx')):
            for m in IMPORT.finditer(open(p, encoding='utf-8', errors='replace').read()):
                todo.append(os.path.join(os.path.dirname(rel), m.group(1) or m.group(2)))
    return seen
def read(root, rel):
    p = os.path.join(root, rel)
    return open(p, 'rb').read() if os.path.isfile(p) else None
for fn in sorted(os.listdir(target)):
    if fn.startswith('_') or not os.path.isfile(os.path.join(target, fn, 'index.ts')): continue
    entry = os.path.join(fn, 'index.ts')
    if not os.path.isfile(os.path.join(base, entry)):
        print(f"NEW      {fn}"); continue
    files = closure(target, entry) | closure(base, entry)
    diff = sorted(f for f in files if read(target, f) != read(base, f))
    print(f"CHANGED  {fn}  {', '.join(diff)}" if diff else f"SAME     {fn}")
PY
