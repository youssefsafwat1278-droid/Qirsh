// Real-model evaluation, server side. Drives the checkout's OWN Edge Function
// handler (process-ios-sms/index.ts handleProcessIosSms) with the request body
// the App Intent sends when AI is consented (analysis_mode=ai_primary_v1,
// backgroundAnalysis), on the checkout's own in-memory model of the capture_*
// RPCs (process-ios-sms/capture_rpc_fake.ts). Prompt, system instruction,
// request builder, redaction, retry policy, structured-output parsing,
// validators, meaning gate and the stored row are the checkout's code. The
// only thing replaced is `fetch`, and only to (a) refuse any host but the
// Generative Language API, (b) enforce the persistent request cap BEFORE each
// call, (c) record request body, raw answer, tokens and latency.
//
//   deno run --no-lock --allow-read --allow-write --allow-env \
//     --allow-net=generativelanguage.googleapis.com \
//     real_eval.ts <checkoutRoot> <messages.json> <client_sanitized.json> <outDir>
//
// Environment:
//   MESSAGE_EVAL_MODEL_MODE    stub (default) | real | list_models
//   MESSAGE_EVAL_COUNTER_FILE  persistent request counter (required). One HTTP
//                              request = one count, retries and failures too.
//   MESSAGE_EVAL_MAX_REQUESTS  cap for this counter file; never above 300.
//   MESSAGE_EVAL_KEY_FILE      env file holding GEMINI_API_KEY (real modes).
//                              Read in-process; never printed, logged or saved.
//   MESSAGE_EVAL_IDS           optional comma list of message ids (smoke run).
//   MESSAGE_EVAL_PACE_MS       pause between messages (default 300).
//   MESSAGE_EVAL_PRECHECK=0    stub mode only: start messages without the
//                              worst-case check, to prove the wrapper itself
//                              refuses the request that would pass the cap.
//
// Layers written per message (out/server_real.json):
//   attempts[]  each provider request: HTTP status, latency, tokens, the raw
//               structured answer, and the code's verdict on that answer
//               (terminal not-a-transaction, accepted, or the rejection reason,
//               cross-checked against the repair prompt the code then sent).
//   server      what the handler stored: state, status, parserSource,
//               reviewReason, failure_reason, parsed money fields.
//   stored      the row the device later fetches (input of the device import).

type Event = { kind: string; amount: number; currency: string; amount_text: string };
type Msg = {
  id: string; cls: string; text: string; sender: string | null; received_at: string; tz_offset: number;
  disposition: string; events: Event[]; lang: string;
};
// deno-lint-ignore no-explicit-any
type Any = any;

const HARD_CAP = 300;
const GL = 'https://generativelanguage.googleapis.com/';
const [root, inPath, clientPath, outDir] = Deno.args;
if (!root || !inPath || !clientPath || !outDir) {
  throw new Error('usage: real_eval.ts <checkoutRoot> <messages.json> <client_sanitized.json> <outDir>');
}
const modelMode = Deno.env.get('MESSAGE_EVAL_MODEL_MODE') ?? 'stub';
if (!['stub', 'real', 'list_models'].includes(modelMode)) throw new Error('MESSAGE_EVAL_MODEL_MODE: stub | real | list_models');
const counterFile = Deno.env.get('MESSAGE_EVAL_COUNTER_FILE');
if (!counterFile) throw new Error('MESSAGE_EVAL_COUNTER_FILE is required');
const cap = Math.min(HARD_CAP, Math.max(0, Number(Deno.env.get('MESSAGE_EVAL_MAX_REQUESTS') ?? String(HARD_CAP))));
const paceMs = Number(Deno.env.get('MESSAGE_EVAL_PACE_MS') ?? '300');
const onlyIds = (Deno.env.get('MESSAGE_EVAL_IDS') ?? '').split(',').map((s) => s.trim()).filter(Boolean);

// ── The key: read here, kept in this process, scrubbed from everything written.
let key = '';
if (modelMode !== 'stub') {
  const keyFile = Deno.env.get('MESSAGE_EVAL_KEY_FILE');
  if (!keyFile) throw new Error('MESSAGE_EVAL_KEY_FILE is required for a real run');
  for (const line of Deno.readTextFileSync(keyFile).split('\n')) {
    const m = /^\s*(?:export\s+)?GEMINI_API_KEY\s*=\s*(.*)$/.exec(line);
    if (m) key = m[1].trim().replace(/^['"]|['"]$/g, '');
  }
  if (!key) throw new Error('no GEMINI_API_KEY in the key file');
}
const scrub = (s: string): string => (key ? s.split(key).join('[KEY]') : s);
// The checkout's code reads the key and the model from the environment.
Deno.env.set('GEMINI_API_KEY', modelMode === 'stub' ? 'message-eval-stub-not-a-key' : key);
Deno.env.delete('GEMINI_SMS_MODEL'); // production sets no override: the code default is under test
for (const name of ['ENGAGEMENT_WORKER_SECRET', 'SUPABASE_URL']) Deno.env.delete(name);

// ── Persistent counter. Reserved (written) before the request leaves.
function readCounter(): number {
  try {
    const n = JSON.parse(Deno.readTextFileSync(counterFile!)).requests;
    if (!Number.isInteger(n) || n < 0) throw new Error('bad counter');
    return n;
  } catch (e) {
    if (e instanceof Deno.errors.NotFound) return 0;
    throw new Error('message_eval: unreadable request counter; refusing to send');
  }
}
class CapReached extends Error {}
function reserve(): number {
  const n = readCounter();
  if (n >= cap) throw new CapReached(`message_eval: request cap reached (${n}/${cap})`);
  Deno.writeTextFileSync(counterFile!, JSON.stringify({ requests: n + 1, cap, updated: new Date().toISOString() }));
  return n + 1;
}
const counterBefore = readCounter();

const realFetch = globalThis.fetch;

if (modelMode === 'list_models') {
  // One request, counted. Only used when the API rejects the configured model.
  const seq = reserve();
  const res = await realFetch(`${GL}v1beta/models?pageSize=200`, { headers: { 'x-goog-api-key': key } });
  const text = scrub(await res.text());
  let names: string[] = [];
  try { names = (JSON.parse(text).models ?? []).map((m: Any) => m.name); } catch { /* reported raw below */ }
  await Deno.mkdir(outDir, { recursive: true });
  await Deno.writeTextFile(`${outDir}/models_list.json`,
    JSON.stringify({ seq, status: res.status, models: names, raw: names.length ? undefined : text.slice(0, 2000) }, null, 1));
  console.log(JSON.stringify({ list_models: res.status, count: names.length, counter: readCounter() }));
  Deno.exit(0);
}

const fns = `${root}/supabase/functions`;
const handler = await import(`file://${fns}/process-ios-sms/index.ts`);
const fakeMod = await import(`file://${fns}/process-ios-sms/capture_rpc_fake.ts`);
const parse = await import(`file://${fns}/process-ios-sms/parse.ts`);
const gate = await import(`file://${fns}/process-ios-sms/meaning_gate.ts`);
const validator = await import(`file://${fns}/_shared/ai_candidate_validator.ts`);
const primary = await import(`file://${fns}/_shared/ai_primary.ts`);
const understanding = await import(`file://${fns}/_shared/ai_understanding.ts`);
const MAX_ATTEMPTS: number = primary.MAX_AI_ATTEMPTS;
const redactionMod = await import(`file://${fns}/_shared/sms_redaction.ts`);
/** index.ts reSanitize, for the meaning of a message never sent to the model. */
function parse_bounded(text: string): string {
  return redactionMod.redactThirdPartyNames(redactionMod.redactPii(text)).trim();
}

const all: Msg[] = JSON.parse(await Deno.readTextFile(inPath)).messages;
const clientText: Record<string, string> = JSON.parse(await Deno.readTextFile(clientPath));
const msgs = onlyIds.length ? all.filter((m) => onlyIds.includes(m.id)) : all;
await Deno.mkdir(`${outDir}/requests`, { recursive: true });

// ── Stub model (dry run only): a scripted answer through the same wrapper, so
// the cap, the counter, the repair loop and the accounting are exercised
// without a provider call. It answers the label, with scripted faults.
const TYPE: Record<string, string> = {
  payment: 'payment', fee: 'payment', withdrawal: 'withdrawal', transfer_out: 'transfer',
  transfer_in: 'transfer', own_transfer: 'transfer', income: 'income', refund: 'refund',
};
const DIR: Record<string, string> = {
  payment: 'debit', fee: 'debit', withdrawal: 'debit', transfer_out: 'debit',
  transfer_in: 'credit', income: 'credit', refund: 'credit', own_transfer: 'debit',
};
function stubAnswer(m: Msg, index: number, attempt: number): { status: number; body: Any; headers?: Record<string, string> } {
  if (index % 11 === 5 && attempt === 1) return { status: 429, body: { error: { code: 429, status: 'RESOURCE_EXHAUSTED' } }, headers: { 'Retry-After': '1' } };
  const e = m.events[0];
  let answer: Any;
  if (m.disposition === 'save' && e) {
    answer = {
      is_transaction: true, message_type: 'transaction', status: 'completed',
      amount: e.amount, amount_text: index % 7 === 3 && attempt === 1 ? '999999.99' : e.amount_text,
      currency: e.currency, type: TYPE[e.kind], direction: DIR[e.kind], category: 'other',
    };
  } else if ((m.cls === 'declined' || m.cls === 'pending') && index % 2 === 0) {
    // A wrong model: claims a completed payment of the first figure it sees.
    const fig = /[0-9][0-9,]*(?:\.[0-9]+)?/.exec(m.text)?.[0]?.replaceAll(',', '') ?? '1.00';
    const cur = /\b(SAR|EGP|AED|KWD|QAR|BHD|OMR|USD|EUR)\b/.exec(m.text)?.[1] ??
      (m.text.includes('جنيه') ? 'EGP' : m.text.includes('درهم') ? 'AED' : 'SAR');
    answer = { is_transaction: true, message_type: 'transaction', status: 'completed', amount: Number(fig),
      amount_text: fig, currency: cur, type: 'payment', direction: 'debit', category: 'other' };
  } else {
    answer = { is_transaction: false, message_type: m.cls === 'declined' ? 'declined_or_failed' : 'other_non_transaction' };
  }
  return { status: 200, body: {
    candidates: [{ content: { parts: [{ text: JSON.stringify(answer) }] } }],
    usageMetadata: { promptTokenCount: 600, candidatesTokenCount: 40, thoughtsTokenCount: 10, totalTokenCount: 650 },
    modelVersion: 'stub',
  } };
}

// ── The fetch wrapper.
let current: Msg | null = null;
let currentIndex = 0;
let currentPass = 1;
let attempts: Any[] = [];
let fatal: string | null = null;
let refusedByWrapper = 0;
globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const url = String(input instanceof Request ? input.url : input);
  if (!url.startsWith(`${GL}v1beta/models/`) || !url.endsWith(':generateContent')) {
    throw new Error(`message_eval: unexpected network call to ${new URL(url).host}`);
  }
  let seq: number;
  try { seq = reserve(); } catch (e) { refusedByWrapper++; throw e; } // cap reached: nothing is sent
  const attempt = attempts.length + 1;
  const bodyText = typeof init?.body === 'string' ? init.body : '';
  const rec: Any = { seq, attempt, url, model: url.slice(`${GL}v1beta/models/`.length, -':generateContent'.length) };
  attempts.push(rec);
  // Request body only: never the headers (the key travels in a header).
  rec.request_file = `requests/${current!.id}_p${currentPass}_a${attempt}.json`;
  Deno.writeTextFileSync(`${outDir}/${rec.request_file}`, scrub(bodyText));
  const t0 = performance.now();
  try {
    let status: number, text: string, headers: Headers;
    if (modelMode === 'real') {
      const res = await realFetch(input, init);
      status = res.status; headers = res.headers; text = await res.text();
    } else {
      const s = stubAnswer(current!, currentIndex, attempt);
      status = s.status; headers = new Headers(s.headers ?? {}); text = JSON.stringify(s.body);
    }
    rec.latency_ms = Math.round(performance.now() - t0);
    rec.http_status = status;
    let json: Any = null;
    try { json = JSON.parse(text); } catch { /* recorded as unparseable */ }
    if (status !== 200) {
      rec.error = scrub(JSON.stringify(json?.error ?? text).slice(0, 600));
      rec.retry_after = headers.get('Retry-After');
      // The configured model is refused by the API: stop, never substitute.
      if (status === 404 || (status === 400 && /model/i.test(rec.error))) fatal = `model rejected: HTTP ${status} ${rec.error}`;
      if (status === 401 || status === 403) fatal = `key rejected: HTTP ${status} ${rec.error}`;
    } else {
      const u = json?.usageMetadata ?? {};
      rec.usage = { prompt: u.promptTokenCount ?? 0, output: u.candidatesTokenCount ?? 0,
        thoughts: u.thoughtsTokenCount ?? 0, cached: u.cachedContentTokenCount ?? 0, total: u.totalTokenCount ?? 0 };
      rec.model_version = json?.modelVersion ?? null;
      rec.finish_reason = json?.candidates?.[0]?.finishReason ?? null;
      const raw = json?.candidates?.[0]?.content?.parts?.[0]?.text;
      rec.raw_text = typeof raw === 'string' ? raw : null;
    }
    return new Response(text, { status, headers });
  } catch (e) {
    rec.latency_ms = Math.round(performance.now() - t0);
    rec.transport_error = scrub(String(e)).slice(0, 300);
    throw e;
  }
}) as typeof fetch;

// ── The code's verdict on one raw answer, with the code's own functions in
// the order parse.ts (parsePrimarySms.validate) and ai_primary.ts apply them.
const AI_TYPES = ['payment', 'withdrawal', 'transfer', 'income', 'refund', 'unknown'];
function categoriesOf(prompt: string): string[] {
  const m = /Category must be one of: ([^.]*)\./.exec(prompt);
  return m ? m[1].split(',').map((s) => s.trim()) : [];
}
function judge(rawText: string | null, sms: string, receivedAt: string, prompt: string): Any {
  let value: Any = null;
  try {
    const p = typeof rawText === 'string' ? JSON.parse(rawText.replace(/^```(?:json)?\s*|\s*```$/g, '')) : null;
    if (p && typeof p === 'object' && !Array.isArray(p)) value = p;
  } catch { /* invalid JSON */ }
  if (!value) return { answer: null, decision: 'rejected', reason: 'valid_json_required' };
  const verdict = understanding.nonTransactionVerdict(value);
  if (verdict) return { answer: value, decision: 'terminal_not_transaction', verdict };
  let reason: string | null = null;
  if (value.is_transaction !== true) reason = 'is_transaction_required';
  else {
    const str = (v: unknown) => (typeof v === 'string' ? v : undefined);
    const cand = {
      amount: typeof value.amount === 'number' ? value.amount : undefined, amount_text: str(value.amount_text),
      currency: str(value.currency), merchant: str(value.merchant ?? value.merchant_name),
      category: str(value.category ?? value.category_key), type: str(value.type), direction: str(value.direction),
      occurred_at: str(value.occurredAt ?? value.occurred_at), last4: str(value.last4),
    };
    if (!AI_TYPES.includes(cand.type ?? '')) reason = 'type_required';
    else if (!categoriesOf(prompt).includes(cand.category ?? '')) reason = 'category_required';
    else {
      const checked = validator.validateAiCandidate({ candidate: cand, sanitizedText: sms, receivedAt, local: null });
      reason = checked.accepted ? primary.checkPrimaryAmount(value, sms) : checked.reason;
    }
  }
  return { answer: value, decision: reason ? 'rejected' : 'accepted', reason };
}

const OWNER = '00000000-0000-0000-0000-00000000a001';
function requestFor(m: Msg): Request {
  const sanitized = clientText[m.id];
  // BackendCaptureClient.process (BankMessageShortcuts.swift) with allowAi.
  return new Request('https://eval.invalid/functions/v1/process-ios-sms', {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      payloadId: m.id, installId: 'eval-install', deviceSecret: 'eval-secret',
      smsText: sanitized, sanitizedText: sanitized, textLength: m.text.trim().length,
      sender: m.sender ?? '', senderName: '', senderId: m.sender ?? '',
      receivedAt: m.received_at, tzOffsetMinutes: m.tz_offset, locale: m.lang === 'ar' ? 'ar' : 'en',
      source: 'ios_shortcut', notificationDetails: true, allowAi: true,
      owner_uid: OWNER, owner_generation: 1, schema_version: 2,
      analysis_mode: 'ai_primary_v1', backgroundAnalysis: true, localNotification: false,
    }),
  });
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const out: Record<string, Any> = {};
const fakes = new Map<string, Any>();
const skippedByCap: string[] = [];

async function runOnce(m: Msg, index: number, pass: number) {
  current = m; currentIndex = index; currentPass = pass; attempts = [];
  const fake = fakes.get(m.id) ?? fakeMod.fakeCapture({
    device: { user_id: OWNER, consent_owner_uid: OWNER, ai: true, apns_token: null },
  });
  fakes.set(m.id, fake);
  let background: Promise<unknown> | null = null;
  const t0 = performance.now();
  const res: Response = await handler.handleProcessIosSms(requestFor(m), {
    createServiceClient: () => fake.client,
    verifyDevice: () => Promise.resolve({ ok: true, installIdHash: 'eval-install-hash', userId: OWNER }),
    waitUntil: (work: Promise<unknown>) => { background = work; },
  });
  if (background) await background;
  const elapsed = Math.round(performance.now() - t0);
  const row = fake.state.rows.get(m.id) ?? {};
  // The text the model was given: the tail of the first request's prompt.
  let prompt = '', sms = '';
  if (attempts.length) {
    const first = JSON.parse(Deno.readTextFileSync(`${outDir}/${attempts[0].request_file}`));
    prompt = first?.contents?.[0]?.parts?.[0]?.text ?? '';
    sms = prompt.slice(prompt.lastIndexOf('\nSMS:\n') + 6);
  }
  for (let i = 0; i < attempts.length; i++) {
    const a = attempts[i];
    if (a.http_status === 200) a.code = judge(a.raw_text, sms, m.received_at, prompt);
    if (i > 0) {
      // What the code itself said about the previous answer (the repair turn).
      const body = JSON.parse(Deno.readTextFileSync(`${outDir}/${a.request_file}`));
      const c = /Correction required: ([a-z_]+)\./.exec(body?.contents?.[0]?.parts?.[0]?.text ?? '');
      attempts[i - 1].code_reason_in_repair_prompt = c ? c[1] : null;
    }
  }
  const parsed = (row.parsed ?? {}) as Any;
  const serverText = row.sanitized_text ?? parsed.rawMessage ?? null;
  const meaningText = sms || parse_bounded(clientText[m.id]);
  const meaning = parse.messageMeaning(meaningText);
  const gated = gate.gatedMeaning(meaningText, meaning, typeof parsed.amount === 'number' ? parsed.amount : null);
  const entry = out[m.id] ?? { passes: [] };
  entry.passes.push({ pass, http_status: res.status, elapsed_ms: elapsed, attempts });
  Object.assign(entry, {
    client_text: clientText[m.id],
    model_text: sms || null,
    attempts: entry.passes.flatMap((p: Any) => p.attempts),
    server: {
      state: row.state ?? null, status: row.status ?? null, failure_reason: row.failure_reason ?? null,
      parser_source: parsed.parserSource ?? null, review_reason: parsed.reviewReason ?? null,
      ai_requested: entry.passes.some((p: Any) => p.attempts.length > 0),
      meaning: { kind: meaning.kind, disposition: meaning.disposition, reason: meaning.reason },
      gated_meaning: { kind: gated.kind, disposition: gated.disposition, reason: gated.reason },
      meaning_rejection: gate.meaningRejectionOf(meaningText, typeof parsed.amount === 'number' ? parsed.amount : null, gated),
      money: { amount: parsed.amount ?? null, amount_text: parsed.amount_text ?? null, currency: parsed.currency ?? null,
        direction: parsed.direction ?? null, type: parsed.type ?? null, merchant: parsed.merchant ?? null,
        category: parsed.category ?? null, ai_model: parsed.aiModel ?? null },
      stored_text_present: serverText != null,
    },
    // What the device fetches (processed_captures row).
    stored: {
      status: row.status ?? 'rejected', state: row.state ?? null, parsed,
      notification: row.notification ?? {}, failure_reason: row.failure_reason ?? null,
      sanitized_text: row.sanitized_text ?? null,
    },
  });
  out[m.id] = entry;
}

const precheck = !(modelMode === 'stub' && Deno.env.get('MESSAGE_EVAL_PRECHECK') === '0');
// The handler logs metadata events per capture; keep the run output short.
const say = console.log;
console.log = () => {};
const started = new Date().toISOString();
for (let i = 0; i < msgs.length && !fatal; i++) {
  const m = msgs[i];
  // A message is started only if its worst case still fits under the cap.
  if (precheck && cap - readCounter() < MAX_ATTEMPTS) { skippedByCap.push(m.id); continue; }
  await runOnce(m, all.indexOf(m), 1);
  const a = out[m.id].attempts;
  if (a.some((x: Any) => x.http_status === 429)) await sleep(modelMode === 'real' ? 15000 : 0); // back off after a rate limit
  else if (a.length) await sleep(paceMs);
}
// The client replays a capture the server left retryable (provider not
// reached). Two bounded replays, after the server's own 30 s retry delay.
for (let pass = 2; pass <= 3 && !fatal; pass++) {
  const waiting = msgs.filter((m) => out[m.id]?.server.state === 'retryable');
  if (!waiting.length) break;
  if (modelMode === 'real') await sleep(31000);
  else for (const m of waiting) fakes.get(m.id).state.rows.get(m.id).next_attempt_at = 0;
  for (const m of waiting) {
    if (fatal) break;
    if (cap - readCounter() < MAX_ATTEMPTS) { skippedByCap.push(`${m.id}(replay)`); continue; }
    await runOnce(m, all.indexOf(m), pass);
    await sleep(paceMs);
  }
}
globalThis.fetch = realFetch;
Deno.env.delete('GEMINI_API_KEY');

const allAttempts = Object.values(out).flatMap((e: Any) => e.attempts as Any[]);
const lat = allAttempts.filter((a) => a.latency_ms != null).map((a) => a.latency_ms as number).sort((x, y) => x - y);
const pct = (p: number) => (lat.length ? lat[Math.min(lat.length - 1, Math.ceil(p * lat.length) - 1)] : null);
const sum = (f: (a: Any) => number) => allAttempts.reduce((n, a) => n + (a.usage ? f(a) : 0), 0);
const statuses: Record<string, number> = {};
for (const a of allAttempts) {
  const k = a.http_status != null ? String(a.http_status) : 'transport_error';
  statuses[k] = (statuses[k] ?? 0) + 1;
}
const meta = {
  mode: modelMode, commit_root: root, started, finished: new Date().toISOString(),
  endpoint: `${GL}v1beta/models/<model>:generateContent`,
  models_called: [...new Set(allAttempts.map((a) => a.model))],
  model_versions_returned: [...new Set(allAttempts.map((a) => a.model_version).filter(Boolean))],
  cap, hard_cap: HARD_CAP, counter_before: counterBefore, counter_after: readCounter(),
  requests_this_run: allAttempts.length, messages_run: Object.keys(out).length,
  messages_sent_to_model: Object.values(out).filter((e: Any) => e.attempts.length > 0).length,
  skipped_by_cap: skippedByCap, fatal,
  refused_by_wrapper: refusedByWrapper,
  http_statuses: statuses,
  latency_ms: { n: lat.length, p50: pct(0.5), p95: pct(0.95), max: lat.length ? lat[lat.length - 1] : null },
  tokens: { prompt: sum((a) => a.usage.prompt), output: sum((a) => a.usage.output), thoughts: sum((a) => a.usage.thoughts),
    cached: sum((a) => a.usage.cached), total: sum((a) => a.usage.total) },
};
await Deno.writeTextFile(`${outDir}/server_real.json`, scrub(JSON.stringify({ meta, server: out })));
say(scrub(JSON.stringify(meta)));
if (fatal) Deno.exit(3);
