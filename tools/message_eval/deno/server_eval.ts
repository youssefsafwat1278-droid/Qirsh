// Held-out evaluation, server side. Runs the given checkout's OWN
// process-ios-sms/parse.ts (parseSms) and _shared/ai_candidate_validator.ts
// on every message; nothing here re-implements a parser rule.
//
//   deno run --no-lock --allow-read --allow-write --allow-env \
//     --allow-net=generativelanguage.googleapis.com \
//     server_eval.ts <checkoutRoot> <run/messages.json> <out.json>
//
// Modes (each message, each mode):
//   det            allowAi=false (Cloud on, AI off)
//   hybrid_oracle  allowAi=true, non-primary; the model is a stub that answers
//                  the ground truth ("perfect model" upper bound)
//   primary_oracle allowAi=true, analysis_mode=ai_primary_v1; same stub
//   hybrid_real / primary_real  the configured Gemini model, ONLY when
//                  MESSAGE_EVAL_GEMINI_KEY is set and MESSAGE_EVAL_MAX_REQUESTS>0
// Text handed to parseSms is what process-ios-sms/index.ts hands it:
// redactThirdPartyNames(redactPii(text)).trim().
// The outcome → stored capture mapping copies index.ts:335-378 (status, state).

type Event = { kind: string; amount: number; currency: string; amount_text: string };
type Msg = {
  id: string; text: string; sender: string | null; received_at: string; tz_offset: number;
  disposition: string; acceptable: string[]; events: Event[]; policy_dependent: string | null;
};

const [root, inPath, outPath] = Deno.args;
if (!root || !inPath || !outPath) throw new Error('usage: server_eval.ts <checkoutRoot> <in.json> <out.json>');
const fns = `${root}/supabase/functions`;
const parse = await import(`file://${fns}/process-ios-sms/parse.ts`);
const redaction = await import(`file://${fns}/_shared/sms_redaction.ts`);
const validator = await import(`file://${fns}/_shared/ai_candidate_validator.ts`);
const primary = await import(`file://${fns}/_shared/ai_primary.ts`);

const msgs: Msg[] = JSON.parse(await Deno.readTextFile(inPath)).messages;
const realKey = Deno.env.get('MESSAGE_EVAL_GEMINI_KEY') ?? '';
const maxRequests = Number(Deno.env.get('MESSAGE_EVAL_MAX_REQUESTS') ?? '0');
const realModes = (Deno.env.get('MESSAGE_EVAL_REAL_MODES') ?? 'primary_real').split(',').filter(Boolean);
const realSample = Number(Deno.env.get('MESSAGE_EVAL_REAL_SAMPLE') ?? '0'); // 0 = as many as the cap allows

const TYPE: Record<string, string> = {
  payment: 'payment', fee: 'payment', withdrawal: 'withdrawal', transfer_out: 'transfer',
  transfer_in: 'transfer', own_transfer: 'transfer', income: 'income', refund: 'refund',
};
const DIR: Record<string, string> = {
  payment: 'debit', fee: 'debit', withdrawal: 'debit', transfer_out: 'debit',
  transfer_in: 'credit', income: 'credit', refund: 'credit', own_transfer: 'debit',
};
const CAT: Record<string, string> = {
  payment: 'shopping', fee: 'bills', withdrawal: 'cash', transfer_out: 'transfers',
  transfer_in: 'transfers', own_transfer: 'transfers', income: 'income', refund: 'other',
};

/** The ground-truth answer, in the model's JSON shape (both prompts). */
function oracle(m: Msg): Record<string, unknown> {
  const saves = m.disposition === 'save';
  const e = m.events[0];
  if (!saves || !e) return { is_transaction: false };
  return {
    is_transaction: true, amount: e.amount, amount_text: e.amount_text, currency: e.currency,
    type: TYPE[e.kind], direction: DIR[e.kind], category: CAT[e.kind],
  };
}

const realFetch = globalThis.fetch;
let current: Msg | null = null;
let mode = '';
const usage = { requests: 0, prompt: 0, output: 0, thoughts: 0, latencyMs: [] as number[], errors: 0, refusedByCap: 0 };

globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const url = String(input instanceof Request ? input.url : input);
  if (!url.startsWith('https://generativelanguage.googleapis.com/')) {
    throw new Error(`message_eval: unexpected network call to ${new URL(url).host}`);
  }
  if (mode.endsWith('_oracle')) {
    const body = { candidates: [{ content: { parts: [{ text: JSON.stringify(oracle(current!)) }] } }] };
    return new Response(JSON.stringify(body), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }
  if (mode.endsWith('_real')) {
    if (usage.requests >= maxRequests) {
      usage.refusedByCap++;
      throw new Error('message_eval: request cap reached');
    }
    usage.requests++;
    const t0 = performance.now();
    try {
      const res = await realFetch(input, init);
      usage.latencyMs.push(performance.now() - t0);
      if (!res.ok) { usage.errors++; return res; }
      const json = await res.json();
      const u = json?.usageMetadata ?? {};
      usage.prompt += u.promptTokenCount ?? 0;
      usage.output += u.candidatesTokenCount ?? 0;
      usage.thoughts += u.thoughtsTokenCount ?? 0;
      return new Response(JSON.stringify(json), { status: 200, headers: { 'Content-Type': 'application/json' } });
    } catch (e) {
      usage.errors++;
      throw e;
    }
  }
  throw new Error('message_eval: network call in a no-AI mode');
}) as typeof fetch;

function sanitize(text: string): string {
  return redaction.redactThirdPartyNames(redaction.redactPii(text)).trim();
}

// deno-lint-ignore no-explicit-any
function stored(outcome: any, aiPrimary: boolean) {
  const parsed = { ...(outcome.parsed ?? {}) };
  const status = outcome.accepted && parsed.amount && parsed.currency ? 'processed' : 'rejected';
  if (status !== 'rejected') parsed.duplicateStatus = 'normal';
  const transient = outcome.aiTransientFailure === true &&
    (!aiPrimary || outcome.aiProviderUnavailable === true);
  return {
    status,
    state: transient ? 'retryable' : status === 'rejected' ? 'rejected' : 'processed',
    parsed,
    failure_reason: transient ? 'ai_unavailable' : status === 'rejected' ? 'not_parseable' : null,
    ai_invoked: outcome.aiInvoked ?? false,
  };
}

async function runMode(m: Msg, name: string) {
  current = m;
  mode = name;
  const aiPrimary = name.startsWith('primary');
  const allowAi = name !== 'det';
  const text = sanitize(m.text);
  const t0 = performance.now();
  try {
    const outcome = await parse.parseSms({
      text, rawText: text, sender: m.sender ?? '', receivedAt: m.received_at,
      tzOffsetMinutes: m.tz_offset, locale: 'en', allowAi, aiPrimary,
      beforeAi: () => Promise.resolve(true),
    });
    return { ...stored(outcome, aiPrimary), ms: Math.round(performance.now() - t0) };
  } catch (e) {
    return { status: 'error', state: 'error', parsed: {}, error: String(e).slice(0, 200) };
  }
}

const out: Record<string, unknown> = {};
const modes = ['det', 'hybrid_oracle', 'primary_oracle'];
Deno.env.set('GEMINI_API_KEY', 'message-eval-oracle-not-a-key');
for (const m of msgs) {
  const r: Record<string, unknown> = { sanitized: sanitize(m.text) };
  for (const name of modes) r[name] = await runMode(m, name);
  // Validators on the correct candidate (completed messages only).
  const o = oracle(m);
  if (o.is_transaction === true) {
    const cand = {
      amount: o.amount as number, amount_text: o.amount_text as string, currency: o.currency as string,
      type: o.type as string, direction: o.direction as string, category: o.category as string,
    };
    const v = validator.validateAiCandidate({ candidate: cand, sanitizedText: r.sanitized as string,
      receivedAt: m.received_at, local: null });
    const p = v.accepted ? primary.checkPrimaryAmount(o, r.sanitized as string) : null;
    r.validator = { accepted: v.accepted && !p, reason: v.accepted ? p : v.reason };
  }
  out[m.id] = r;
}

// Real model: bounded. Never printed: the key; never sent: anything but the
// sanitized text parseSms itself sends.
const real = { ran: false, model: Deno.env.get('GEMINI_SMS_MODEL') ?? 'gemini-3.8-flash (code default)', modes: realModes,
  maxRequests, messages: 0, skipped: 0, usage };
if (realKey && maxRequests > 0) {
  real.ran = true;
  Deno.env.set('GEMINI_API_KEY', realKey);
  const perMsg = realModes.reduce((n, x) => n + (x.startsWith('primary') ? primary.MAX_AI_ATTEMPTS : 1), 0);
  const pool = realSample > 0 ? sample(msgs, realSample) : msgs;
  for (const m of pool) {
    if (usage.requests + perMsg > maxRequests) { real.skipped++; continue; }
    real.messages++;
    for (const name of realModes) (out[m.id] as Record<string, unknown>)[name] = await runMode(m, name);
  }
}
Deno.env.delete('GEMINI_API_KEY');
globalThis.fetch = realFetch;

await Deno.writeTextFile(outPath, JSON.stringify({ server: out, real }, null, 0));
console.log(JSON.stringify({ messages: msgs.length, real: { ...real, usage: { ...usage, latencyMs: usage.latencyMs.length } } }));

/** Deterministic, class-stratified sample (every k-th message per class). */
function sample(all: Msg[], n: number): Msg[] {
  const byCls = new Map<string, Msg[]>();
  for (const m of all) {
    const k = `${m.disposition}`;
    byCls.set(k, [...(byCls.get(k) ?? []), m]);
  }
  const pick: Msg[] = [];
  for (const [, list] of byCls) {
    const share = Math.max(1, Math.round(n * list.length / all.length));
    const step = list.length / share;
    for (let i = 0; i < share && pick.length < n; i++) pick.push(list[Math.floor(i * step)]);
  }
  return pick;
}
