import { assert, assertEquals } from 'jsr:@std/assert@1';
import { geminiRequestBody } from './gemini_request.ts';
import { runPrimaryAi } from './ai_primary.ts';
import { parseSms } from '../process-ios-sms/parse.ts';

// Every SMS-derived Gemini generateContent request must carry the documented
// top-level `store: false` (Logs and Datasets opt-out). These tests capture
// the real outgoing request bodies; no network is used.

Deno.test('geminiRequestBody sets top-level store=false and keeps the request', () => {
  const body = JSON.parse(geminiRequestBody({
    contents: [{ parts: [{ text: 'x' }] }],
    generationConfig: { temperature: 0 },
  }));
  assertEquals(body.store, false);
  assertEquals(body.generationConfig, { temperature: 0 });
  assertEquals(body.contents[0].parts[0].text, 'x');
  assert(!('store' in body.generationConfig), 'store is top-level, not in generationConfig');
});

Deno.test('a caller cannot turn storage back on', () => {
  const sneaky = { contents: [], store: true } as unknown as { contents: unknown };
  assertEquals(JSON.parse(geminiRequestBody(sneaky)).store, false);
});

Deno.test('runPrimaryAi (parse-sms primary + iOS primary) sends store=false on every attempt', async () => {
  const bodies: Record<string, unknown>[] = [];
  await runPrimaryAi({
    prompt: 'p',
    key: 'k',
    model: 'm',
    beforeAttempt: () => Promise.resolve(true),
    validate: () => 'again', // force all attempts, so every retry is checked
    sleep: () => Promise.resolve(),
    fetcher: (_url, init) => {
      bodies.push(JSON.parse(String(init?.body)));
      const text = JSON.stringify({ is_transaction: true });
      return Promise.resolve(
        new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text }] } }] }), { status: 200 }),
      );
    },
  });
  assert(bodies.length > 1);
  for (const b of bodies) assertEquals(b.store, false);
});

async function captureIosBodies(aiPrimary: boolean): Promise<Record<string, unknown>[]> {
  const original = globalThis.fetch;
  const previousKey = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  const bodies: Record<string, unknown>[] = [];
  globalThis.fetch = ((_url: unknown, init?: RequestInit) => {
    bodies.push(JSON.parse(String(init?.body)));
    const text = JSON.stringify({ is_transaction: false });
    return Promise.resolve(
      new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text }] } }] }), { status: 200 }),
    );
  }) as typeof fetch;
  try {
    await parseSms({
      text: 'Purchase of USD 20.00 at SHOP card *1234',
      rawText: 'Purchase of USD 20.00 at SHOP card *1234',
      sender: 'BANK',
      receivedAt: '2026-11-01T10:00:00.000Z',
      tzOffsetMinutes: 180,
      locale: 'en',
      allowAi: true,
      aiPrimary,
    });
  } finally {
    globalThis.fetch = original;
    if (previousKey == null) Deno.env.delete('GEMINI_API_KEY');
    else Deno.env.set('GEMINI_API_KEY', previousKey);
  }
  return bodies;
}

Deno.test('process-ios-sms legacy AI request carries store=false', async () => {
  const bodies = await captureIosBodies(false);
  assertEquals(bodies.length, 1);
  assertEquals(bodies[0].store, false);
});

Deno.test('process-ios-sms primary AI request carries store=false', async () => {
  const bodies = await captureIosBodies(true);
  assert(bodies.length >= 1);
  for (const b of bodies) assertEquals(b.store, false);
});

// parse-sms/index.ts and bank-discovery/index.ts start `Deno.serve` at import
// and need a database for identity/consent, so their bodies are pinned
// structurally: every source file that addresses `:generateContent` must build
// each request body with geminiRequestBody, and no other body builder.
Deno.test('every generateContent call site builds its body with geminiRequestBody', () => {
  const root = new URL('../', import.meta.url);
  const sites: string[] = [];
  const walk = (dir: URL) => {
    for (const entry of Deno.readDirSync(dir)) {
      if (entry.isDirectory) {
        walk(new URL(`${entry.name}/`, dir));
        continue;
      }
      if (!entry.name.endsWith('.ts') || entry.name.endsWith('_test.ts') || entry.name === 'gemini_request.ts') {
        continue;
      }
      const url = new URL(entry.name, dir);
      const src = Deno.readTextFileSync(url);
      if (!src.includes(':generateContent')) continue;
      sites.push(url.pathname);
      const builders = src.match(/geminiRequestBody\(\{/g)?.length ?? 0;
      const contents = src.match(/\bcontents:\s*\[/g)?.length ?? 0;
      assert(builders >= 1, `${url.pathname} calls generateContent without geminiRequestBody`);
      assertEquals(builders, contents, `${url.pathname}: a request body bypasses geminiRequestBody`);
    }
  };
  walk(root);
  for (
    const expected of [
      'parse-sms/index.ts',
      'bank-discovery/index.ts',
      'process-ios-sms/parse.ts',
      '_shared/ai_primary.ts',
    ]
  ) {
    assert(sites.some((s) => s.endsWith(expected)), `expected call site ${expected}`);
  }
});
