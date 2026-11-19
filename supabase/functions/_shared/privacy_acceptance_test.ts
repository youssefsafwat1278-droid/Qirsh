// Round 5: the frozen privacy acceptance set (`tools/acceptance/
// privacy_cases.jsonl`): every text quoted in reviews V and W, the round-4
// reproductions and the labelled fixtures. Zero `must_not` substrings may be
// sent and zero `must_keep` substrings may be lost. The Dart test
// (app/test/engine/privacy/privacy_acceptance_test.dart) and the Swift run of
// `BackendCaptureClient.sanitize` read the same file and must give the same
// text byte for byte (`privacy_acceptance_expected.json`, written here).
//
// Regenerate the expected texts after a deliberate rule change:
//   UPDATE_PRIVACY_ACCEPTANCE=1 deno test --allow-read --allow-env --allow-write _shared/privacy_acceptance_test.ts
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { redactPii, redactThirdPartyNames } from './sms_redaction.ts';

interface Case {
  id: string;
  text: string;
  source: string;
  must_not: string[];
  must_keep: string[];
  merchant?: string;
  pair?: string;
}
const DIR = new URL('../../../tools/acceptance/', import.meta.url);
const CASES: Case[] = Deno.readTextFileSync(new URL('privacy_cases.jsonl', DIR)).split('\n').filter((l) => l.trim())
  .map((l) => JSON.parse(l));
const EXPECTED = new URL('privacy_acceptance_expected.json', DIR);
const sanitize = (t: string) => redactThirdPartyNames(redactPii(t)).trim();

Deno.test('privacy acceptance: no forbidden substring sent, no required substring lost', () => {
  assert(CASES.length >= 400, `${CASES.length} cases`);
  const failures: string[] = [];
  for (const c of CASES) {
    const out = sanitize(c.text);
    for (const s of c.must_not) if (out.includes(s)) failures.push(`${c.id}: sent "${s}" in ${JSON.stringify(out)}`);
    for (const s of c.must_keep) if (!out.includes(s)) failures.push(`${c.id}: lost "${s}" in ${JSON.stringify(out)}`);
    if (sanitize(out) !== out) failures.push(`${c.id}: not idempotent ${JSON.stringify(out)}`);
  }
  assertEquals(failures, []);
});

Deno.test('privacy acceptance: the expected texts the device and the Shortcut must reproduce are the server output', () => {
  const out: Record<string, string> = {};
  for (const c of CASES) out[c.id] = sanitize(c.text);
  const text = JSON.stringify(out, null, 1) + '\n';
  if (Deno.env.get('UPDATE_PRIVACY_ACCEPTANCE') === '1') Deno.writeTextFileSync(EXPECTED, text);
  assertEquals(Deno.readTextFileSync(EXPECTED), text);
});
