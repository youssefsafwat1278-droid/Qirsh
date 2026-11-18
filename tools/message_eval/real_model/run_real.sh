#!/usr/bin/env bash
# Real-model evaluation of one commit on sample A: local-only vs the normal
# AI-enabled path (App Intent redaction -> process-ios-sms handler -> the
# configured Gemini model -> validators / meaning gate -> stored row -> device
# import), with three layers recorded per message. See README.md here.
#
#   MESSAGE_EVAL_SCRATCH=<scratch dir> \
#   MESSAGE_EVAL_KEY_FILE=<env file with GEMINI_API_KEY> \
#   MESSAGE_EVAL_MODEL_MODE=real \
#     tools/message_eval/real_model/run_real.sh <commit> [<out name>]
#
# MESSAGE_EVAL_MODEL_MODE=stub (default) makes no provider call (dry run).
# The request counter is $MESSAGE_EVAL_SCRATCH/gemini_request_counter.json for
# real runs (hard cap 300 across ALL invocations; never delete it between
# runs) and <out>/stub_counter.json for stub runs.
# MESSAGE_EVAL_IDS=A001,A021 limits the run to those messages (smoke run).
# MESSAGE_EVAL_REUSE_SERVER=1 keeps an existing <out>/server_real.json (no
# provider call) and only re-runs the device import and the report.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EVAL="$(dirname "$HERE")"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
SCRATCH="${MESSAGE_EVAL_SCRATCH:?set MESSAGE_EVAL_SCRATCH}"
export PUB_CACHE="${PUB_CACHE_OVERRIDE:-$HOME/.pub-cache}"
[ $# -ge 1 ] || { echo "usage: $0 <commit> [<out name>]" >&2; exit 2; }
MODE="${MESSAGE_EVAL_MODEL_MODE:-stub}"
SHA="$(git -C "$REPO" rev-parse --verify "$1^{commit}")"
SHORT="${SHA:0:8}"
WT="$SCRATCH/wt-$SHORT"
OUT="$SCRATCH/${2:-$MODE-$SHORT}"
SAMPLE="$HERE/sample_a.jsonl"   # sample B is the unopened confirmation set
mkdir -p "$OUT"
[ -d "$WT" ] || git -C "$REPO" worktree add --detach "$WT" "$SHA" >/dev/null

if [ "$MODE" = real ]; then
  export MESSAGE_EVAL_COUNTER_FILE="$SCRATCH/gemini_request_counter.json"
else
  export MESSAGE_EVAL_COUNTER_FILE="${MESSAGE_EVAL_COUNTER_FILE:-$OUT/stub_counter.json}"
fi

if [ "${MESSAGE_EVAL_REUSE_SERVER:-0}" != 1 ] || [ ! -f "$OUT/server_real.json" ]; then
  python3 "$EVAL/expand.py" "$SAMPLE" "$OUT/messages.json"
  echo "== $SHORT: App Intent redaction (the commit's Swift sanitize)"
  "$HERE/swift_sanitize.sh" "$WT" "$OUT/messages.json" "$OUT/client_sanitized.json" "$SCRATCH/swift-build-$SHORT"
  echo "== $SHORT: server (the commit's process-ios-sms handler, model: $MODE)"
  (cd "$OUT" && MESSAGE_EVAL_MODEL_MODE="$MODE" deno run --no-lock --allow-read --allow-write --allow-env \
     --allow-net=generativelanguage.googleapis.com \
     "$HERE/real_eval.ts" "$WT" "$OUT/messages.json" "$OUT/client_sanitized.json" "$OUT")
fi

echo "== $SHORT: device (flutter test, the commit's iOS import)"
T="$WT/app/test/zz_message_eval"
rm -rf "$T"; mkdir -p "$T"
cp "$HERE/real_model_eval_test.dart" "$T/real_model_eval_test.dart"
cp "$OUT/messages.json" "$T/in.json"
python3 - "$OUT/server_real.json" "$T/server.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
json.dump({'server': {k: {'stored': v['stored']} for k, v in d['server'].items()}}, open(sys.argv[2], 'w'))
PY
(cd "$WT/app" && { [ -d .dart_tool ] || flutter pub get --offline >/dev/null; } \
   && flutter test --no-pub test/zz_message_eval/ -r compact 2>&1 | tr '\r' '\n' | grep -E 'passed|failed|Error|error:' | tail -5)
cp "$T/out_0.json" "$OUT/device.json"

echo "== $SHORT: report"
python3 "$HERE/report.py" "$OUT" --label "$SHORT/$MODE"

if [ "${MESSAGE_EVAL_KEEP:-0}" != "1" ]; then git -C "$REPO" worktree remove --force "$WT"; fi
