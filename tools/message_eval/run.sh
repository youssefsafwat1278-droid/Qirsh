#!/usr/bin/env bash
# Held-out message-understanding evaluation of one commit, in one command.
#
#   tools/message_eval/run.sh <commit> [<commit> ...]
#
# For each commit: a detached scratch worktree (read-only use; removed at the
# end unless MESSAGE_EVAL_KEEP=1), the commit's own server parser under Deno,
# the commit's own iOS import under `flutter test`, then scoring against the
# held-out labels and the criteria in ACCEPTANCE.md.
#
# Real model (optional, bounded; see README.md):
#   MESSAGE_EVAL_GEMINI_KEY=<authorized test key> MESSAGE_EVAL_MAX_REQUESTS=300 \
#     tools/message_eval/run.sh <commit>
#
# Mixed mode (old client, new server): MESSAGE_EVAL_SERVER_REV=<server commit>
# runs the server parse of that commit and feeds it to <commit>'s client
# import, e.g. build 147's client on a newly deployed server:
#   MESSAGE_EVAL_SERVER_REV=7dd6efa8 tools/message_eval/run.sh b6fc0dad
#
# Output: $MESSAGE_EVAL_OUT (default <scratch>/message_eval/<sha>/) holds
# server.json, device.json and metrics.json/metrics.md. Per-message results
# stay there: do not share them with the tuners.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
SCRATCH="${MESSAGE_EVAL_SCRATCH:-${TMPDIR:-/tmp}/message_eval}"
export PUB_CACHE="${PUB_CACHE_OVERRIDE:-$HOME/.pub-cache}"
[ $# -ge 1 ] || { echo "usage: $0 <commit> [<commit>...]" >&2; exit 2; }

for REV in "$@"; do
  SHA="$(git -C "$REPO" rev-parse --verify "$REV^{commit}")"
  SHORT="${SHA:0:8}"
  WT="$SCRATCH/wt-$SHORT"
  SRV_WT="$WT"
  LABEL="$SHORT"
  if [ -n "${MESSAGE_EVAL_SERVER_REV:-}" ]; then
    SRV_SHA="$(git -C "$REPO" rev-parse --verify "$MESSAGE_EVAL_SERVER_REV^{commit}")"
    SRV_WT="$SCRATCH/wt-${SRV_SHA:0:8}"
    LABEL="$SHORT-client+${SRV_SHA:0:8}-server"
  fi
  OUT="${MESSAGE_EVAL_OUT:-$SCRATCH/$LABEL}"
  mkdir -p "$OUT"
  echo "== $LABEL: worktree $WT (server from $SRV_WT)"
  if [ ! -d "$WT" ]; then git -C "$REPO" worktree add --detach "$WT" "$SHA" >/dev/null; fi
  if [ ! -d "$SRV_WT" ]; then git -C "$REPO" worktree add --detach "$SRV_WT" "$SRV_SHA" >/dev/null; fi

  # MESSAGE_EVAL_SET=<jsonl> runs another labelled set (e.g. dev_siblings.jsonl);
  # its results are development numbers, never held-out numbers.
  python3 "$HERE/expand.py" "${MESSAGE_EVAL_SET:-$HERE/heldout/messages.jsonl}" "$OUT/messages.json"

  echo "== $SHORT: server (Deno, the commit's parse.ts)"
  # LEN-1: does the client under test send textLength to the server?
  CLIENT_LEN=0
  if grep -q "'textLength'" "$WT/app/lib/features/capture/services/capture_backend_client.dart"; then CLIENT_LEN=1; fi
  (cd "$OUT" && MESSAGE_EVAL_CLIENT_TEXT_LENGTH=$CLIENT_LEN deno run --no-lock --allow-read --allow-write --allow-env \
     --allow-net=generativelanguage.googleapis.com \
     "$HERE/deno/server_eval.ts" "$SRV_WT" "$OUT/messages.json" "$OUT/server.json")

  echo "== $SHORT: device (flutter test, the commit's iOS import)"
  T="$WT/app/test/zz_message_eval"
  mkdir -p "$T"
  SHARDS="${MESSAGE_EVAL_SHARDS:-2}"
  for i in $(seq 0 $((SHARDS - 1))); do
    sed -e "s/^const _shard = 0;/const _shard = $i;/" -e "s/^const _shards = 1;/const _shards = $SHARDS;/" \
      "$HERE/dart/message_eval_test.dart" > "$T/message_eval_s${i}_test.dart"
  done
  cp "$OUT/messages.json" "$T/in.json"
  cp "$OUT/server.json" "$T/server.json"
  (cd "$WT/app" && { [ -d .dart_tool ] || flutter pub get --offline >/dev/null; } \
     && flutter test --no-pub -j "$SHARDS" test/zz_message_eval/ -r compact 2>&1 | tr '\r' '\n' | grep -E 'passed|failed|Error|error:' | tail -5)
  python3 - "$T" "$SHARDS" "$OUT/device.json" <<'PY'
import json, sys
t, n, dst = sys.argv[1], int(sys.argv[2]), sys.argv[3]
dev, ms = {}, []
for i in range(n):
    d = json.load(open(f'{t}/out_{i}.json'))
    dev.update(d['device']); ms.append(d['elapsed_ms'])
json.dump({'device': dev, 'elapsed_ms': ms}, open(dst, 'w'))
print(f'device results: {len(dev)} messages, shard times {ms} ms')
PY

  echo "== $SHORT: score"
  python3 "$HERE/score.py" "$OUT/messages.json" "$OUT/server.json" "$OUT/device.json" \
    --label "$LABEL" --out "$OUT/metrics"

  if [ "${MESSAGE_EVAL_KEEP:-0}" != "1" ]; then
    git -C "$REPO" worktree remove --force "$WT"
    if [ "$SRV_WT" != "$WT" ]; then git -C "$REPO" worktree remove --force "$SRV_WT"; fi
  fi
done
