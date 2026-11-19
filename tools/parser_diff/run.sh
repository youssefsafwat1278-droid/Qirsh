#!/bin/bash
# Parser differential harness: runs a base commit and the working tree (or a
# second commit) over every case file and prints each message whose outcome
# moved, graded against its label where it has one.
#
#   tools/parser_diff/run.sh [BASE=5dae2e2d] [WORK=working-tree|<commit>]
#
# Needs git, deno, flutter, python3, and `flutter pub get` done in
# app/ (the package config is reused for the extracted versions).
# PARSER_DIFF_SCRATCH sets the scratch folder (default: a new temp folder).
# Exit status 1 when a labelled message the base got right is wrong or silent
# on any path, when any path throws, or when more messages than the review
# budget (PARSER_DIFF_REVIEW_BUDGET, default 336 since review X of Round 5's owner rule: see REVIEW_BUDGET in diff.py) moved from right (labelled)
# or recorded (unlabelled) to a review row; diff.py lists every such move.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BASE=${1:-5dae2e2d}
WORK=${2:-working-tree}
S=${PARSER_DIFF_SCRATCH:-$(mktemp -d -t parser_diff)}
mkdir -p "$S"
echo "scratch: $S"

# Case files: the committed probe sets plus the live shared case table.
python3 "$HERE/diff.py" cases "$HERE/cases" "$REPO/supabase/functions/process-ios-sms/declined_cases.json" "$S/cases.json"

prepare() { # name commit|working-tree -> $S/<name>/root
  local name=$1 rev=$2 root
  if [ "$rev" = working-tree ]; then root=$REPO; else
    root=$S/$name/src; rm -rf "$root"; mkdir -p "$root"
    (cd "$REPO" && git archive "$rev" app/lib app/pubspec.yaml app/assets app/shaders supabase/functions) | tar -x -C "$root"
  fi
  mkdir -p "$S/$name/h"
  if [ "$root" != "$REPO" ]; then
    mkdir -p "$root/app/.dart_tool"
    cp "$REPO/app/.dart_tool/package_graph.json" "$root/app/.dart_tool/package_graph.json"
    # The working tree's package config; every relative package other than
    # the app itself is resolved against the working tree.
    python3 - "$REPO/app/.dart_tool" "$root/app/.dart_tool/package_config.json" <<'PY'
import json, os, sys
src = sys.argv[1]
cfg = json.load(open(os.path.join(src, 'package_config.json')))
for p in cfg['packages']:
    if p['name'] != 'money_companion' and not p['rootUri'].startswith('file:'):
        p['rootUri'] = 'file://' + os.path.normpath(os.path.join(src, p['rootUri'])) + '/'
json.dump(cfg, open(sys.argv[2], 'w'))
PY
  fi
  cp "$HERE/device.dart" "$S/$name/h/device_test.dart"
  # The version shim: its meaning reading and hold (where it has them), and
  # localParseContradictsServer as its import step calls it (the merchant is
  # passed where the version takes it).
  local mer=''
  grep -A8 'bool localParseContradictsServer' "$root/app/lib/domain/capture/validated_capture.dart" | grep -q 'merchant' &&
    mer=', merchant: m'
  {
    echo "import 'package:money_companion/domain/capture/validated_capture.dart';"
    if [ -f "$root/app/lib/engine/parser/message_meaning.dart" ]; then
      echo "import 'package:money_companion/engine/parser/parser_engine.dart';"
      echo "String? meaning(String t) { final m = ParserEngine.meaningOf(t); return '\${m.kind.name}:\${m.reason}'; }"
      echo "String? hold(String t) => meaningHoldReason(t);"
    else
      echo "String? meaning(String t) => null;"
      echo "String? hold(String t) => null;"
    fi
    echo "bool contradicts(String t, String? d, String? ty, String? snd, num? a, String? m) =>"
    echo "    localParseContradictsServer(text: t, direction: d, type: ty, senderId: snd, amount: a$mer);"
  } > "$S/$name/h/shim.dart"
  echo "$root" > "$S/$name/root"
}

leg() { # name
  local name=$1 root; root=$(cat "$S/$name/root")
  deno run -A --no-lock "$HERE/server.ts" "$root" "$S/cases.json" "$S/$name/server.jsonl"
  (cd "$root/app" && PARSER_DIFF_ARGS="$S/cases.json $S/$name/server.jsonl $S/$name/out.jsonl" \
    flutter test --no-pub "$S/$name/h/device_test.dart" > "$S/$name/device.log" 2>&1) || { tail -30 "$S/$name/device.log"; return 1; }
}

prepare base "$BASE"; prepare work "$WORK"
leg base & p1=$!; leg work & p2=$!; wait $p1; wait $p2
python3 "$HERE/diff.py" diff "$S/cases.json" "$S/base/out.jsonl" "$S/work/out.jsonl" | tee "$S/report.txt"
