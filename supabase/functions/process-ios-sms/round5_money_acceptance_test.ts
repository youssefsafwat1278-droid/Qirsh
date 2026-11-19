// Round 5 (owner decision): the frozen money acceptance set
// (tools/acceptance/money_cases.jsonl) through the real handler
// (handleProcessIosSms) on the capture_* RPC model, with the model stubbed:
//   ai_off              AI not allowed (rule parse only);
//   ai_correct          the model answers right (a completed transaction with
//                       the movement's figure, or "not a transaction");
//   ai_wrong_completed  the model answers "completed" with a figure of the
//                       text, whatever the text says;
//   ai_flipped          the model answers the true figure of a completed
//                       debit/credit in the other direction.
// Both analysis modes (rule parse + model, AI-primary). Stored `processed` =
// recorded; `rejected` = kept for review (the device shows it, or reads it
// itself on the rule-parse path). A transfer never reaches the model.
// Acceptance: zero wrong financial entries; unnecessary reviews are counted.
// Round 5 (review X, X-M3): no row is exempt. In ai_flipped, a row recorded
// with the model's flipped direction because the text gives the rule parser no
// direction is still a wrong entry: those rows are listed by hand in
// tools/acceptance/flipped_residual.json (per path) and the test fails on any
// wrong row not listed there and on any listed row that is no longer wrong.
// ACCEPTANCE_OUT=<file> writes the per-row result. Synthetic messages only.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { handleProcessIosSms } from './index.ts';
import { fakeCapture } from './capture_rpc_fake.ts';
import { isTransfer } from './completion_certainty.ts';

type Booking = { class: string; amount: number; currency: string };
// alt: a recorded outcome that is not a wrong entry (the original-currency
// figure of a foreign purchase; the paid total of a tip message).
type Expected = {
  outcome: 'recorded' | 'review' | 'ignored'; class?: string; amount?: number; currency?: string; alt?: Booking[];
};
type Row = {
  id: string;
  text: string;
  truth: string;
  forged: { amount: number; amount_text: string; currency: string; type: string; direction: string } | null;
  expected: Record<'ai_off' | 'ai_correct' | 'ai_wrong_completed', Expected> & { ai_flipped?: Expected };
};

const ROWS: Row[] = (await Deno.readTextFile(new URL('../../../tools/acceptance/money_cases.jsonl', import.meta.url)))
  .split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));

const RESIDUAL: Record<string, Array<{ id: string; text: string }>> = JSON.parse(
  await Deno.readTextFile(new URL('../../../tools/acceptance/flipped_residual.json', import.meta.url)),
);

const OWNER = '00000000-0000-0000-0000-00000000a001';

function stubGemini(answer: Record<string, unknown> | null) {
  const original = globalThis.fetch;
  const previousKey = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  const stub = {
    calls: 0,
    restore: () => {
      globalThis.fetch = original;
      if (previousKey == null) Deno.env.delete('GEMINI_API_KEY');
      else Deno.env.set('GEMINI_API_KEY', previousKey);
    },
  };
  globalThis.fetch = (() => {
    stub.calls++;
    const text = JSON.stringify(answer ?? { is_transaction: false });
    return Promise.resolve(new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text }] } }] })));
  }) as typeof fetch;
  return stub;
}

async function handle(row: Row, id: string, allowAi: boolean, primary: boolean, answer: Record<string, unknown> | null) {
  const fake = fakeCapture({ device: { user_id: OWNER, consent_owner_uid: OWNER, ai: true, apns_token: null } });
  const stub = stubGemini(answer);
  try {
    await handleProcessIosSms(
      new Request('https://example.test/process-ios-sms', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          schema_version: 1, installId: 'i', deviceSecret: 's', receivedAt: '2026-11-17T09:45:00Z',
          payloadId: id, sanitizedText: row.text, sender: 'SNB', allowAi,
          ...(primary ? { analysis_mode: 'ai_primary_v1' } : {}),
        }),
      }),
      {
        createServiceClient: (() => fake.client) as never,
        verifyDevice: (() => Promise.resolve({ ok: true, installIdHash: 'h', userId: null })) as never,
      },
    );
  } finally {
    stub.restore();
  }
  const stored = fake.state.rows.get(id) as { state: string; status?: string; parsed?: Record<string, unknown> } | undefined;
  return { stored, calls: stub.calls };
}

function modelAnswer(f: NonNullable<Row['forged']>, type: string, direction: string) {
  return {
    is_transaction: true, amount: f.amount, amount_text: f.amount_text, currency: f.currency, type, direction,
    category: type === 'payment' ? 'shopping' : type === 'transfer' ? 'transfers' : 'other', merchant: undefined,
  };
}

/** The right answer of a model for [r]. */
function correctAnswer(r: Row): Record<string, unknown> | null {
  const e = r.expected.ai_correct;
  if (e.outcome !== 'recorded' || !r.forged) return null;
  const direction = e.class === 'credit' ? 'credit' : 'debit';
  const type = e.class === 'transfer' ? 'transfer'
    : e.class === 'credit' ? (r.forged.type === 'refund' ? 'refund' : 'income') : 'payment';
  return modelAnswer(r.forged, type, direction);
}

type Observed = { outcome: 'recorded' | 'review'; cls?: string; amount?: number; currency?: string };

function observe(stored: { state: string; parsed?: Record<string, unknown> } | undefined): Observed {
  if (!stored || stored.state !== 'processed') return { outcome: 'review' };
  const p = stored.parsed ?? {};
  return {
    outcome: 'recorded',
    cls: p.direction === 'credit' ? 'credit' : p.direction === 'debit' ? 'debit' : String(p.direction),
    amount: Number(p.amount),
    currency: String(p.currency),
  };
}

/** ok / wrong / unnecessary_review (the server keeps every non-processed capture). */
function grade(e: Expected, o: Observed, truth: string): string {
  if (o.outcome === 'recorded' && e.alt?.some((a) =>
    a.class === o.cls && a.currency === o.currency && Math.abs(a.amount - o.amount!) < 0.005
  )) return 'ok_alt';
  if (e.outcome === 'recorded') {
    if (o.outcome === 'review') return 'unnecessary_review';
    // An own-account move the server processes is booked neutral by the
    // device (capture_sync_service); a direction is not a wrong total there.
    if (e.class !== 'transfer' && o.cls !== e.class) return 'wrong';
    if (e.amount != null && Math.abs(o.amount! - e.amount) > 0.005) return 'wrong';
    if (e.currency != null && o.currency !== e.currency) return 'wrong';
    return truth === 't' ? 'ok_transfer' : 'ok';
  }
  if (o.outcome === 'recorded') return 'wrong';
  return e.outcome === 'ignored' ? 'ok_ignored' : 'ok';
}

const results: Record<string, Record<string, string>> = {};
const out = Deno.env.get('ACCEPTANCE_OUT');

/** The true figure in the other direction (a completed debit/credit row). */
function flippedAnswer(r: Row): Record<string, unknown> | 'skip' {
  if (!r.forged || !r.expected.ai_flipped) return 'skip';
  return r.forged.direction === 'credit'
    ? modelAnswer(r.forged, 'payment', 'debit')
    : modelAnswer(r.forged, 'refund', 'credit');
}

type Mode = 'ai_off' | 'ai_correct' | 'ai_wrong_completed' | 'ai_flipped';
const MODES: Array<{ name: string; mode: Mode; allowAi: boolean; answer: (r: Row) => Record<string, unknown> | null | 'skip' }> = [
  { name: 'ai_off', mode: 'ai_off', allowAi: false, answer: () => null },
  { name: 'ai_correct', mode: 'ai_correct', allowAi: true, answer: correctAnswer },
  {
    name: 'ai_wrong_completed', mode: 'ai_wrong_completed', allowAi: true,
    answer: (r) => r.forged ? modelAnswer(r.forged, r.forged.type, r.forged.direction) : 'skip',
  },
  { name: 'ai_flipped', mode: 'ai_flipped', allowAi: true, answer: flippedAnswer },
];

for (const m of MODES) {
  for (const primary of [false, true]) {
    if (m.mode === 'ai_off' && primary) continue;
    const name = `${m.name} (${primary ? 'AI-primary' : 'rule parse + model'})`;
    Deno.test(`acceptance set — ${name}: no wrong entry; a transfer never reaches the model`, async () => {
      const counts: Record<string, number> = {};
      const failures: string[] = [];
      const residual = new Set((RESIDUAL[`server ${name}`] ?? []).map((x) => x.id));
      const wrongIds = new Set<string>();
      let modelCalls = 0;
      for (const [i, r] of ROWS.entries()) {
        const answer = m.answer(r);
        if (answer === 'skip') continue;
        const { stored, calls } = await handle(r, `r5-${i}`, m.allowAi, primary, answer);
        modelCalls += calls;
        const o = observe(stored);
        const g = grade(r.expected[m.mode]!, o, r.truth);
        counts[g] = (counts[g] ?? 0) + 1;
        (results[r.id] ??= {})[name] = `${g} ${o.outcome}${o.cls ? ` ${o.cls} ${o.amount} ${o.currency}` : ''}`;
        if (g === 'wrong') wrongIds.add(r.id);
        if (g === 'wrong' && !residual.has(r.id)) {
          failures.push(`${r.id}: expected ${JSON.stringify(r.expected[m.mode])}, got ${JSON.stringify(o)} — ${r.text}`);
        }
        if (calls > 0 && (isTransfer(r.text) || r.truth === 't')) {
          failures.push(`${r.id}: a transfer or own-account move reached the model — ${r.text}`);
        }
      }
      for (const id of residual) if (!wrongIds.has(id)) failures.push(`${id}: listed as residual but no longer wrong`);
      console.log(`ROUND5 SERVER ${name}: ${JSON.stringify(counts)} model requests ${modelCalls}` +
        ` residual (recorded with the model's flipped direction: the text gives the rule parser no direction) ${residual.size}`);
      if (out) await Deno.writeTextFile(out, JSON.stringify(results));
      assertEquals(failures, []);
    });
  }
}
