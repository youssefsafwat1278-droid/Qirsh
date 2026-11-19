// Round 5 (coordinator item 1/2): which acceptance rows depend on the model's
// accuracy by construction, read by the server meaning of the final code.
//   wrong_completed: a not-money truth (n / r / i), or a move between own
//     accounts (t), whose text has no doubt and no completed-event form the
//     rules know (uncertain:no_completed_form) — the model decides it, so a
//     wrong "completed" payment/income answer is recorded.
//   flipped: a completed debit/credit whose text names no direction — a model
//     answer in the other direction cannot be told from a right one.
// Transfers never reach the model and are never marked.
//   python3 tools/acceptance/build_money_cases.py > /tmp/unmarked.jsonl
//   deno run --allow-read --allow-write tools/acceptance/mark_model_dependence.ts /tmp/unmarked.jsonl
// writes tools/acceptance/model_dependence.json (keyed by text); rebuild after.
import { messageMeaning, namedDirection } from '../../supabase/functions/process-ios-sms/parse.ts';
import { isTransfer } from '../../supabase/functions/process-ios-sms/completion_certainty.ts';

const rows = (await Deno.readTextFile(Deno.args[0])).split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
const out: Record<string, { wrong_completed?: true; flipped?: true }> = {};
for (const r of rows) {
  if (isTransfer(r.text)) continue;
  const m = messageMeaning(r.text);
  const mark: { wrong_completed?: true; flipped?: true } = {};
  if (['n', 'r', 'i', 't'].includes(r.truth) && m.kind === 'uncertain' && m.reason === 'no_completed_form') {
    mark.wrong_completed = true;
  }
  if (['d', 'c'].includes(r.truth) && namedDirection(r.text, m) === 'unknown') mark.flipped = true;
  if (mark.wrong_completed || mark.flipped) out[r.text] = mark;
}
await Deno.writeTextFile(new URL('./model_dependence.json', import.meta.url),
  JSON.stringify(Object.fromEntries(Object.keys(out).sort().map((k) => [k, out[k]])), null, 1) + '\n');
console.log(`wrong_completed ${Object.values(out).filter((m) => m.wrong_completed).length}, ` +
  `flipped ${Object.values(out).filter((m) => m.flipped).length}`);
Deno.exit(0);
