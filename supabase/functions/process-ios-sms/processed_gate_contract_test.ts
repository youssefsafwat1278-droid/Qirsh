// Follow-up 15 (VAL-1): no path in index.ts marks a capture `processed`
// without passing the single meaning rule (`meaningRejectionOf`, not-completed
// first). index.ts starts its server on import, so the wiring is pinned from
// source; the rule itself is exercised in meaning_gate_test.ts.
import { assert, assertEquals } from 'jsr:@std/assert@1';

const src = Deno.readTextFileSync(new URL('./index.ts', import.meta.url));
const at = (needle: string) => {
  const i = src.indexOf(needle);
  assert(i >= 0, `missing: ${needle}`);
  return i;
};

Deno.test('index.ts: every processed capture has passed meaningRejectionOf', () => {
  // Exactly one place can set `status` to 'processed' (the parse outcome)…
  const sets = [...src.matchAll(/\bstatus\s*=(?!=)[^;]*'processed'/g)];
  assertEquals(sets.length, 1, sets.map((m) => m[0]).join('\n'));
  const born = sets[0].index!;
  // …and the single rule runs on it before anything is looked up, stored or
  // pushed. The stored state is derived from that status only.
  const gate = at("if (status === 'processed' && meaningRejectionOf(sanitizedText, parsed.amount ?? null, meaning) != null) {");
  assert(born < gate);
  assert(at("import { gatedMeaning, meaningRejectionOf } from './meaning_gate.ts';") < born);
  assert(gate < at('const duplicate = await detectDuplicate('));
  const stored = at("state: transient ? 'retryable' : status === 'rejected' ? 'rejected' : 'processed',");
  assert(gate < stored);
  assert(gate < at("if (status === 'processed' && ownerUid) {"));
  // No other stored-state value can say processed (the type declaration
  // `state: 'processed' | …` aside).
  assertEquals([...src.matchAll(/state:(?!\s*'processed' \|)[^,\n]*'processed'/g)].length, 1);
  // The gate's meaning is the server gate's (gatedMeaning), which also goes
  // through the rule.
  assert(at('let meaning = gatedMeaning(sanitizedText,') < gate);
});
