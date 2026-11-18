// Round 4 (requirements C and D): what the server stores, returns and sends
// to the model for the labelled leak set, and which merchant key a redacted
// message yields. Synthetic data only; the model and the database are stubs.
//
// The upload is the WORST case: a client that redacted nothing puts the raw
// message in both `smsText` and `sanitizedText`. No tagged third-party name
// or number may then appear in the model request, the stored row, the
// response, the push or a log line.
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { fakeCapture } from '../process-ios-sms/capture_rpc_fake.ts';
import { handleProcessIosSms, merchantRuleKey } from '../process-ios-sms/index.ts';
import { parseSms } from '../process-ios-sms/parse.ts';
import { redactPii, redactThirdPartyNames } from './sms_redaction.ts';

interface Row {
  id: string;
  raw: string;
  expected: string;
  secrets: string[];
  mustKeep: string[];
  merchant?: string;
  pair?: string;
}
const ROWS: Row[] = JSON.parse(
  Deno.readTextFileSync(new URL('./fixtures/sms_leak_labelled_cases.json', import.meta.url)),
);
const sanitize = (t: string) => redactThirdPartyNames(redactPii(t)).trim();
// Letters only, so a tagged number can never collide with it.
const OWNER = 'abcdefab-cdef-4abc-8def-abcdefabcdef';

/** Every string anywhere inside `value`, with its path. */
function strings(value: unknown, path = ''): [string, string][] {
  if (typeof value === 'string') return [[path, value]];
  if (Array.isArray(value)) return value.flatMap((v, i) => strings(v, `${path}[${i}]`));
  if (value && typeof value === 'object') {
    return Object.entries(value).flatMap(([k, v]) => strings(v, path ? `${path}.${k}` : k));
  }
  return [];
}

async function upload(row: Row, mode: 'ai_primary' | 'legacy') {
  const fake = fakeCapture({
    device: { user_id: OWNER, consent_owner_uid: OWNER, ai: true, apns_token: null },
  });
  const modelRequests: unknown[] = [];
  const logs: string[] = [];
  const originalFetch = globalThis.fetch;
  const originalLog = console.log;
  const previousKey = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  globalThis.fetch = ((input: unknown, init?: RequestInit) => {
    modelRequests.push({ url: String(input), body: JSON.parse(String(init?.body ?? 'null')) });
    // A refusal the code does not retry: the request is recorded, nothing waits.
    return Promise.resolve(new Response(JSON.stringify({}), { status: 400 }));
  }) as typeof fetch;
  console.log = (...args: unknown[]) => void logs.push(args.map(String).join(' '));
  try {
    const res = await handleProcessIosSms(
      new Request('https://example.test/process-ios-sms', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          schema_version: 1,
          installId: 'i',
          deviceSecret: 's',
          receivedAt: new Date().toISOString(),
          payloadId: `p-${row.id}`,
          smsText: row.raw,
          sanitizedText: row.raw,
          sender: 'ExampleBank',
          allowAi: true,
          notificationDetails: true,
          ...(mode === 'ai_primary' ? { analysis_mode: 'ai_primary_v1' } : {}),
        }),
      }),
      {
        createServiceClient: (() => fake.client) as never,
        verifyDevice: (() => Promise.resolve({ ok: true, installIdHash: 'h', userId: null })) as never,
      },
    );
    return {
      status: res.status,
      response: await res.json(),
      stored: [...fake.state.rows.values()],
      modelRequests,
      logs,
    };
  } finally {
    globalThis.fetch = originalFetch;
    console.log = originalLog;
    if (previousKey == null) Deno.env.delete('GEMINI_API_KEY');
    else Deno.env.set('GEMINI_API_KEY', previousKey);
  }
}

for (const mode of ['ai_primary', 'legacy'] as const) {
  Deno.test(`outbound (${mode}): no tagged third-party token in the model request, the stored row, the response or a log`, async () => {
    const leaks: string[] = [];
    let modelCalls = 0;
    let storedRows = 0;
    for (const row of ROWS) {
      const sent = await upload(row, mode);
      assert(sent.status < 500, `${row.id}: ${sent.status}`);
      modelCalls += sent.modelRequests.length;
      storedRows += sent.stored.length;
      const fields: [string, string][] = [
        ...strings(sent.modelRequests, 'model'),
        ...strings(sent.stored, 'stored'),
        ...strings(sent.response, 'response'),
        ...sent.logs.map((l, i): [string, string] => [`log[${i}]`, l]),
      ];
      for (const [path, value] of fields) {
        for (const s of row.secrets) if (value.includes(s)) leaks.push(`${row.id}: "${s}" in ${path}`);
      }
      // The model sees exactly the redacted text, never the upload.
      for (const [path, value] of strings(sent.modelRequests, 'model')) {
        if (path.endsWith('.text') && row.secrets.length) assert(!value.includes(row.raw), `${row.id}: raw text in ${path}`);
      }
    }
    assertEquals(leaks, []);
    // The run did reach the model and the store.
    assert(modelCalls > ROWS.length / 2, `${modelCalls} model requests`);
    assert(storedRows >= ROWS.length, `${storedRows} stored rows`);
  });
}

Deno.test('rule key: a merchant that must survive gives the same merchant key from the redacted text as from the raw text', async () => {
  const merchants = ROWS.filter((r) => r.merchant);
  assert(merchants.length >= 20);
  const failures: string[] = [];
  let keyed = 0;
  for (const row of merchants) {
    const input = { sender: 'ExampleBank', receivedAt: '2026-11-17T10:00:00Z', tzOffsetMinutes: 180, locale: 'en', allowAi: false };
    const raw = (await parseSms({ ...input, text: row.raw, rawText: row.raw })).parsed.merchant;
    const redacted = (await parseSms({ ...input, text: sanitize(row.raw), rawText: sanitize(row.raw) })).parsed.merchant;
    const rawKey = raw ? merchantRuleKey(raw) : '';
    const redactedKey = redacted ? merchantRuleKey(redacted) : '';
    if (rawKey !== redactedKey) failures.push(`${row.id}: ${JSON.stringify(rawKey)} became ${JSON.stringify(redactedKey)}`);
    if (rawKey) keyed++;
    // The redacted text itself still carries the merchant, whole.
    if (!sanitize(row.raw).includes(row.merchant!)) failures.push(`${row.id}: lost ${row.merchant}`);
  }
  assertEquals(failures, []);
  assert(keyed >= merchants.length / 2, `the rule parser keyed only ${keyed} of ${merchants.length}`);
});

Deno.test('rule key: no person name becomes a merchant, a merchant key or a duplicate fingerprint input', async () => {
  const people = ROWS.filter((r) => r.secrets.length);
  assert(people.length >= 100);
  const failures: string[] = [];
  for (const row of people) {
    const text = sanitize(row.raw);
    const parsed = (await parseSms({
      text, rawText: text, sender: 'ExampleBank', receivedAt: '2026-11-17T10:00:00Z', tzOffsetMinutes: 180,
      locale: 'en', allowAi: false,
    })).parsed;
    for (const [path, value] of strings(parsed, 'parsed')) {
      for (const s of row.secrets) if (value.includes(s)) failures.push(`${row.id}: "${s}" in ${path}`);
    }
    const key = parsed.merchant ? merchantRuleKey(parsed.merchant) : '';
    for (const s of row.secrets) if (key.includes(s.toUpperCase())) failures.push(`${row.id}: "${s}" in the merchant key`);
  }
  assertEquals(failures, []);
});

Deno.test('pairs: every person row has a merchant twin and the reverse', () => {
  const byId = new Map(ROWS.map((r) => [r.id, r]));
  const paired = ROWS.filter((r) => r.pair && r.id.startsWith('r4_pair_'));
  assert(paired.length >= 36);
  for (const r of paired) {
    const twin = byId.get(r.pair!);
    assert(twin, `${r.id}: twin ${r.pair} is missing`);
    assert(r.secrets.length > 0 || r.merchant, `${r.id}: neither a person nor a merchant row`);
    assert(r.secrets.length > 0 || twin.secrets.length > 0, `${r.id}: no person in the pair`);
    assert(r.merchant || twin.merchant, `${r.id}: no merchant in the pair`);
  }
  for (const lang of [/[A-Za-z]{4}/u, /[؀-ۿ]{3}/u]) {
    assert(paired.filter((r) => r.merchant && lang.test(r.merchant)).length >= 5);
  }
});

Deno.test('pairs: every removed one-time code has a twin where a figure of the same length survives', () => {
  const byId = new Map(ROWS.map((r) => [r.id, r]));
  const codes = ROWS.filter((r) => r.pair && r.id.startsWith('r4_otp_') && r.secrets.length);
  assert(codes.length >= 5);
  for (const r of codes) {
    const twin = byId.get(r.pair!);
    assert(twin && twin.secrets.length === 0, `${r.id}: twin ${r.pair}`);
    const code = r.secrets[0];
    assert(!sanitize(r.raw).includes(code), `${r.id}: the code survived`);
    assert(sanitize(r.raw).includes('[OTP]'), `${r.id}: no [OTP]`);
    // The same digits, as an amount, stay.
    assert(twin.raw.includes(code) && sanitize(twin.raw).includes(code), `${twin.id}: lost ${code}`);
    assert(!sanitize(twin.raw).includes('[OTP]'), `${twin.id}: an amount was read as a code`);
  }
  assert(codes.some((r) => /[\u0600-\u06FF]/u.test(r.raw)) && codes.some((r) => /[A-Za-z]{4}/.test(r.raw)));
});
