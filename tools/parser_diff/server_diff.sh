#!/bin/bash
# Server-side differential: the deployed server build (default b6fc0dad, the
# server that build 147 talks to) against the working tree's server, over
# every case file and the shared case table. Lists every message that moved
# from rejected to processed (each must be a completed movement), from
# processed to rejected, and every processed row whose booking changed.
#
#   tools/parser_diff/server_diff.sh [BASE=b6fc0dad] [WORK=working-tree|<commit>]
#
# Needs git, deno, python3. PARSER_DIFF_SCRATCH sets the scratch folder.
# Exit status 1 when the work server throws, or a labelled message the base
# server got right is wrong or silent on the work server.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BASE=${1:-b6fc0dad}
WORK=${2:-working-tree}
S=${PARSER_DIFF_SCRATCH:-$(mktemp -d -t server_diff)}
mkdir -p "$S"
echo "scratch: $S"
python3 "$HERE/diff.py" cases "$HERE/cases" "$REPO/supabase/functions/process-ios-sms/declined_cases.json" "$S/cases.json"
root() { # name commit|working-tree -> version root
  if [ "$2" = working-tree ]; then echo "$REPO"; return; fi
  rm -rf "$S/$1"; mkdir -p "$S/$1"
  (cd "$REPO" && git archive "$2" supabase/functions) | tar -x -C "$S/$1"
  echo "$S/$1"
}
B=$(root server_base "$BASE"); W=$(root server_work "$WORK")
deno run -A --no-lock "$HERE/server.ts" "$B" "$S/cases.json" "$S/server_base.jsonl"
deno run -A --no-lock "$HERE/server.ts" "$W" "$S/cases.json" "$S/server_work.jsonl"
python3 "$HERE/diff.py" server "$S/cases.json" "$S/server_base.jsonl" "$S/server_work.jsonl" | tee "$S/server_report.txt"
