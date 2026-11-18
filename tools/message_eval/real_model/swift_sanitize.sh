#!/usr/bin/env bash
# The App Intent's OWN redaction, run on macOS: extracts
# `BackendCaptureClient.sanitize` (and the word lists it reads) verbatim from
# the checkout's ios/BankMessageShortcuts/BankMessageShortcuts.swift, compiles
# it as a command-line tool and applies it to every message text. Nothing in
# the function is rewritten: the extracted lines are the commit's lines.
#
#   swift_sanitize.sh <checkoutRoot> <messages.json> <out.json> <buildDir>
#
# out.json: { "<id>": "<text as the App Intent would upload it>" }
set -euo pipefail
ROOT="$1"; IN="$2"; OUT="$3"; BUILD="$4"
SRC="$ROOT/app/ios/BankMessageShortcuts/BankMessageShortcuts.swift"
mkdir -p "$BUILD"

python3 - "$SRC" "$BUILD/main.swift" <<'PY'
import sys
src, dst = sys.argv[1:3]
lines = open(src, encoding='utf-8').read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.startswith('  static func sanitize(_ text: String) throws -> String {'))
# The enclosing struct ends at the first column-0 closing brace after it.
end = next(i for i in range(start, len(lines)) if lines[i] == '}')
body = '\n'.join(lines[start:end])
open(dst, 'w', encoding='utf-8').write('''import Foundation

enum BackendCaptureError: Error { case sanitizerUnavailable }

struct BackendCaptureClient {
''' + body + '''
}

let input = try JSONSerialization.jsonObject(
  with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
var out: [String: String] = [:]
for case let m as [String: Any] in input["messages"] as! [Any] {
  out[m["id"] as! String] = try BackendCaptureClient.sanitize(m["text"] as! String)
}
try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
  .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
''')
PY
swiftc -O -o "$BUILD/swift_sanitize" "$BUILD/main.swift" 2>"$BUILD/swiftc.log" || {
  tail -20 "$BUILD/swiftc.log" >&2; exit 1; }
"$BUILD/swift_sanitize" "$IN" "$OUT"
